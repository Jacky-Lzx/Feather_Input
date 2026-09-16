#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

xcrun swift-format format \
    --in-place \
    --recursive \
    platforms/macos/dev-harness/Sources
