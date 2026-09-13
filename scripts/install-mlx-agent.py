#!/usr/bin/env python3
"""Install the development MLX worker as a per-user launch agent."""
import os
import pathlib
import plistlib
import subprocess
import sys
root = pathlib.Path(__file__).resolve().parent.parent
model = pathlib.Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else pathlib.Path.home() / '.lmstudio/models/lmstudio-community/Qwen3-0.6B-MLX-4bit'
if not (root / '.venv-mlx/bin/python').exists() or not (model / 'config.json').exists():
    raise SystemExit('Create .venv-mlx and provide a local MLX model directory first.')
label = 'im.feather.mlx-worker'
path = pathlib.Path.home() / 'Library/LaunchAgents' / (label + '.plist')
path.parent.mkdir(parents=True, exist_ok=True)
config = {'Label': label, 'ProgramArguments': [str(root / '.venv-mlx/bin/python'), str(root / 'backend/server.py'), '--model', str(model)],
          'WorkingDirectory': str(root), 'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
          'EnvironmentVariables': {'HF_HUB_OFFLINE': '1', 'TOKENIZERS_PARALLELISM': 'false'}}
path.write_bytes(plistlib.dumps(config))
domain = 'gui/' + str(os.getuid())
subprocess.run(['launchctl', 'bootout', domain + '/' + label], capture_output=True)
subprocess.run(['launchctl', 'bootstrap', domain, str(path)], check=True)
print('Installed MLX worker launch agent:', path)
