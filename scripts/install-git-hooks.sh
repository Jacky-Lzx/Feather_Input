#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

git config --local core.hooksPath .githooks
echo "已启用仓库内的 Git hooks：.githooks"
