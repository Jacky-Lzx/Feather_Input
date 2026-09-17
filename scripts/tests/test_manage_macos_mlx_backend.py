import importlib.util
import os
import pathlib
import plistlib
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "manage-macos-mlx-backend.py"
SPEC = importlib.util.spec_from_file_location("manage_mlx_backend", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ManageMLXBackendTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.environment = mock.patch.dict(
            os.environ,
            {
                "FEATHER_MLX_RUNTIME_DIR": str(self.root / "runtime"),
                "FEATHER_MLX_LAUNCH_AGENTS_DIR": str(self.root / "agents"),
                "FEATHER_MLX_LOG_DIR": str(self.root / "logs"),
            },
        )
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temporary.cleanup()

    def test_plist_uses_stable_runtime_and_loopback_port(self):
        runtime = MODULE.application_support_root()
        model = self.root / "model"
        configuration = MODULE.plist_configuration(runtime, model, 4321)

        self.assertEqual(configuration["Label"], MODULE.LABEL)
        self.assertEqual(configuration["ProgramArguments"][0], str(runtime / ".venv/bin/python"))
        self.assertEqual(configuration["ProgramArguments"][1], str(runtime / "backend/server.py"))
        self.assertEqual(configuration["ProgramArguments"][-2:], ["--port", "4321"])
        self.assertEqual(configuration["WorkingDirectory"], str(runtime / "backend"))

    def test_atomic_plist_write_produces_valid_permissions_and_data(self):
        path = MODULE.agent_path()
        configuration = {"Label": MODULE.LABEL, "RunAtLoad": True}

        MODULE.write_plist_atomically(path, configuration)

        with path.open("rb") as handle:
            self.assertEqual(plistlib.load(handle), configuration)
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_source_validation_reports_all_missing_files(self):
        source = self.root / "source"
        source.mkdir()
        (source / "server.py").write_text("", encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "pinyin_generation.py, requirements.txt"):
            MODULE.validate_source(source)

    def test_status_distinguishes_legacy_agent_path(self):
        path = MODULE.agent_path()
        MODULE.write_plist_atomically(
            path,
            {"ProgramArguments": ["/tmp/repository/.venv/bin/python", "/tmp/repository/backend/server.py"]},
        )
        with mock.patch.object(MODULE, "health", return_value=(True, "mlx-lm")):
            with mock.patch("builtins.print") as output:
                result = MODULE.status(MODULE.DEFAULT_PORT)

        self.assertEqual(result, 0)
        self.assertIn("LaunchAgent：已安装（旧路径）", [call.args[0] for call in output.call_args_list])

    def test_failed_activation_restores_and_reloads_previous_agent(self):
        path = MODULE.agent_path()
        previous = {"Label": MODULE.LABEL, "ProgramArguments": ["/old/python", "/old/server.py"]}
        replacement = {"Label": MODULE.LABEL, "ProgramArguments": ["/new/python", "/new/server.py"]}
        MODULE.write_plist_atomically(path, previous)
        failure = MODULE.subprocess.CalledProcessError(5, ["launchctl", "bootstrap"])

        with mock.patch.object(MODULE, "stop_agent", return_value=True) as stop:
            with mock.patch.object(MODULE, "start_agent", side_effect=[failure, None]) as start:
                with self.assertRaises(MODULE.subprocess.CalledProcessError):
                    MODULE.activate_agent(replacement)

        with path.open("rb") as handle:
            self.assertEqual(plistlib.load(handle), previous)
        self.assertEqual(stop.call_count, 2)
        self.assertEqual(start.call_count, 2)

    def test_install_stages_backend_before_activating_agent(self):
        source = self.root / "source"
        source.mkdir()
        for name in ("server.py", "pinyin_generation.py", "requirements.txt"):
            (source / name).write_text(name, encoding="utf-8")
        model = self.root / "model"
        model.mkdir()
        (model / "config.json").write_text("{}", encoding="utf-8")

        with mock.patch.object(MODULE.shutil, "which", return_value="/usr/local/bin/uv"):
            with mock.patch.object(MODULE, "run") as run:
                with mock.patch.object(MODULE, "activate_agent") as activate:
                    runtime = MODULE.install_runtime(source, model, 1235)

        self.assertEqual((runtime / "backend/server.py").read_text(encoding="utf-8"), "server.py")
        self.assertEqual(run.call_count, 2)
        configuration = activate.call_args.args[0]
        self.assertEqual(configuration["ProgramArguments"][0], str(runtime / ".venv/bin/python"))
        self.assertFalse((runtime / ".backend-staging").exists())
        self.assertFalse((runtime / ".backend-backup").exists())


if __name__ == "__main__":
    unittest.main()
