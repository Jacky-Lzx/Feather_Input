#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec .venv-mlx/bin/python backend/server.py --model "${1:-$HOME/.lmstudio/models/lmstudio-community/Qwen3-0.6B-MLX-4bit}"
