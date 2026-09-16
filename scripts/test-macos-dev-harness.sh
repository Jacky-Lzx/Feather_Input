#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
app="$repo_root/.build/macos-dev-harness/FeatherInputDevHarness.app"

"$repo_root/scripts/build-macos-dev-harness.sh"
"$app/Contents/MacOS/FeatherInputDevHarness" --smoke-test
