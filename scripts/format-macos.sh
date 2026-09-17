#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

xcrun swift-format format \
    --in-place \
    --recursive \
    platforms/macos/shared/Sources \
    platforms/macos/candidate-preview/Sources \
    platforms/macos/client-acceptance/Sources \
    platforms/macos/dev-harness/Sources \
    platforms/macos/input-method/Sources \
    platforms/macos/input-method/Tests \
    platforms/macos/input-method/Tools
