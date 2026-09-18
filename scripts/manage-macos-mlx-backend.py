#!/usr/bin/env python3
"""Install and manage FeatherInput's per-user MLX backend."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


LABEL = "im.feather.mlx-worker"
DEFAULT_PORT = 1235
BOOTSTRAP_ATTEMPTS = 12
BOOTSTRAP_RETRY_DELAY = 0.5


def repository_backend() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent.parent / "backend"


def application_support_root() -> pathlib.Path:
    override = os.environ.get("FEATHER_MLX_RUNTIME_DIR")
    if override:
        return pathlib.Path(override).expanduser().resolve()
    return pathlib.Path.home() / "Library/Application Support/FeatherInput/MLXBackend"


def launch_agents_root() -> pathlib.Path:
    override = os.environ.get("FEATHER_MLX_LAUNCH_AGENTS_DIR")
    if override:
        return pathlib.Path(override).expanduser().resolve()
    return pathlib.Path.home() / "Library/LaunchAgents"


def log_root() -> pathlib.Path:
    override = os.environ.get("FEATHER_MLX_LOG_DIR")
    if override:
        return pathlib.Path(override).expanduser().resolve()
    return pathlib.Path.home() / "Library/Logs/FeatherInput"


def launchctl() -> str:
    return os.environ.get("FEATHER_MLX_LAUNCHCTL", "launchctl")


def agent_path() -> pathlib.Path:
    return launch_agents_root() / f"{LABEL}.plist"


def launch_domain() -> str:
    return f"gui/{os.getuid()}"


def run(
    command: list[str], *, check: bool = True, quiet: bool = False
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=check, text=True, capture_output=quiet)


def validate_source(source: pathlib.Path) -> None:
    required = ("server.py", "pinyin_generation.py", "requirements.txt")
    missing = [name for name in required if not (source / name).is_file()]
    if missing:
        raise ValueError(f"后端源码不完整，缺少：{', '.join(missing)}")


def validate_model(model: pathlib.Path) -> None:
    if not model.is_dir() or not (model / "config.json").is_file():
        raise ValueError(f"模型目录无效（缺少 config.json）：{model}")


def plist_configuration(runtime: pathlib.Path, model: pathlib.Path, port: int) -> dict:
    python = runtime / ".venv/bin/python"
    server = runtime / "backend/server.py"
    logs = log_root()
    return {
        "Label": LABEL,
        "ProgramArguments": [
            str(python),
            str(server),
            "--model",
            str(model),
            "--port",
            str(port),
        ],
        "WorkingDirectory": str(runtime / "backend"),
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "ProcessType": "Interactive",
        "StandardOutPath": str(logs / "mlx-worker.log"),
        "StandardErrorPath": str(logs / "mlx-worker-error.log"),
        "EnvironmentVariables": {
            "HF_HUB_OFFLINE": "1",
            "TOKENIZERS_PARALLELISM": "false",
            "PYTHONUNBUFFERED": "1",
        },
    }


def write_bytes_atomically(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.chmod(0o644)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def write_plist_atomically(path: pathlib.Path, configuration: dict) -> None:
    data = plistlib.dumps(configuration, fmt=plistlib.FMT_XML, sort_keys=True)
    write_bytes_atomically(path, data)


def stop_agent() -> bool:
    result = run(
        [launchctl(), "bootout", f"{launch_domain()}/{LABEL}"],
        check=False,
        quiet=True,
    )
    return result.returncode == 0


def start_agent() -> None:
    path = agent_path()
    if not path.is_file():
        raise ValueError(f"LaunchAgent 尚未安装：{path}")
    command = [launchctl(), "bootstrap", launch_domain(), str(path)]
    for attempt in range(BOOTSTRAP_ATTEMPTS):
        result = run(command, check=False, quiet=True)
        if result.returncode == 0:
            return
        if result.returncode != 5 or attempt == BOOTSTRAP_ATTEMPTS - 1:
            raise subprocess.CalledProcessError(
                result.returncode,
                command,
                output=result.stdout,
                stderr=result.stderr,
            )
        time.sleep(BOOTSTRAP_RETRY_DELAY)


def activate_agent(configuration: dict) -> None:
    path = agent_path()
    previous = path.read_bytes() if path.is_file() else None
    stop_agent()
    write_plist_atomically(path, configuration)
    try:
        start_agent()
    except Exception:
        stop_agent()
        if previous is None:
            path.unlink(missing_ok=True)
        else:
            write_bytes_atomically(path, previous)
            try:
                start_agent()
            except Exception:
                pass
        raise


def install_runtime(source: pathlib.Path, model: pathlib.Path, port: int) -> pathlib.Path:
    source = source.expanduser().resolve()
    model = model.expanduser().resolve()
    validate_source(source)
    validate_model(model)
    if shutil.which("uv") is None:
        raise ValueError("未找到 uv；请先安装 uv 后再部署 MLX 后端。")

    runtime = application_support_root()
    runtime.mkdir(parents=True, exist_ok=True)
    backend = runtime / "backend"
    staged_backend = runtime / ".backend-staging"
    backup_backend = runtime / ".backend-backup"
    if staged_backend.exists():
        shutil.rmtree(staged_backend)
    if backup_backend.exists():
        shutil.rmtree(backup_backend)
    shutil.copytree(source, staged_backend, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))

    virtual_environment = runtime / ".venv"
    try:
        if not (virtual_environment / "bin/python").is_file():
            run(["uv", "venv", str(virtual_environment)])
        run(
            [
                "uv",
                "pip",
                "install",
                "--python",
                str(virtual_environment / "bin/python"),
                "-r",
                str(staged_backend / "requirements.txt"),
            ]
        )
        if backend.exists():
            backend.replace(backup_backend)
        staged_backend.replace(backend)
    except Exception:
        shutil.rmtree(staged_backend, ignore_errors=True)
        if backup_backend.exists() and not backend.exists():
            backup_backend.replace(backend)
        raise

    log_root().mkdir(parents=True, exist_ok=True)
    configuration = plist_configuration(runtime, model, port)
    try:
        activate_agent(configuration)
    except Exception:
        shutil.rmtree(backend, ignore_errors=True)
        if backup_backend.exists():
            backup_backend.replace(backend)
        raise
    shutil.rmtree(backup_backend, ignore_errors=True)
    return runtime


def read_agent() -> dict | None:
    path = agent_path()
    if not path.is_file():
        return None
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return None
    return value if isinstance(value, dict) else None


def health(port: int) -> tuple[bool, str]:
    try:
        request = urllib.request.Request(f"http://127.0.0.1:{port}/health")
        with urllib.request.urlopen(request, timeout=0.5) as response:
            payload = json.load(response)
        if response.status == 200 and payload.get("ready") is True:
            return True, str(payload.get("backend", "unknown"))
        return False, "响应未就绪"
    except (OSError, ValueError, urllib.error.URLError):
        return False, "无法连接"


def status(port: int) -> int:
    configuration = read_agent()
    ready, backend_name = health(port)
    if configuration is None:
        print(f"LaunchAgent：未安装（{agent_path()}）")
    else:
        arguments = configuration.get("ProgramArguments", [])
        stable = bool(arguments) and pathlib.Path(str(arguments[0])).is_relative_to(
            application_support_root()
        )
        print(f"LaunchAgent：已安装（{'稳定目录' if stable else '旧路径'}）")
        if arguments:
            print(f"Python：{arguments[0]}")
        if len(arguments) > 1:
            print(f"服务：{arguments[1]}")
    print(f"健康检查：{'就绪，' + backend_name if ready else backend_name}")
    return 0 if configuration is not None and ready else 1


def uninstall() -> None:
    stopped = stop_agent()
    path = agent_path()
    path.unlink(missing_ok=True)
    print(f"LaunchAgent 已移除：{path}")
    print("后端运行目录和模型均已保留。" if stopped else "服务原本未加载；后端运行目录和模型均已保留。")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)

    install = subparsers.add_parser("install", help="部署稳定运行目录并安装 LaunchAgent")
    install.add_argument(
        "--source",
        type=pathlib.Path,
        default=repository_backend(),
        help="后端源码目录；默认使用当前仓库的 backend/",
    )
    install.add_argument("--model", type=pathlib.Path, required=True, help="本地 MLX 模型目录")
    install.add_argument("--port", type=int, default=DEFAULT_PORT)

    status_parser = subparsers.add_parser("status", help="显示 LaunchAgent 与健康状态")
    status_parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    subparsers.add_parser("start", help="加载已安装的 LaunchAgent")
    subparsers.add_parser("stop", help="停止 LaunchAgent")
    subparsers.add_parser("restart", help="重新加载 LaunchAgent")
    subparsers.add_parser("uninstall", help="移除 LaunchAgent，保留运行目录和模型")
    return result


def main(arguments: list[str] | None = None) -> int:
    options = parser().parse_args(arguments)
    try:
        if options.command == "install":
            if not 1 <= options.port <= 65535:
                raise ValueError("端口必须在 1–65535 之间。")
            runtime = install_runtime(options.source, options.model, options.port)
            print(f"MLX 后端已部署：{runtime}")
            print(f"LaunchAgent 已加载：{agent_path()}")
        elif options.command == "status":
            return status(options.port)
        elif options.command == "start":
            start_agent()
            print("MLX 后端已启动。")
        elif options.command == "stop":
            print("MLX 后端已停止。" if stop_agent() else "MLX 后端原本未加载。")
        elif options.command == "restart":
            stop_agent()
            start_agent()
            print("MLX 后端已重新启动。")
        elif options.command == "uninstall":
            uninstall()
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
