#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=im.feather.inputmethod.rustdev.FeatherInput
status_output=$("$repo_root/scripts/status-macos-input-method.sh")
printf '%s\n' "$status_output"

case "$status_output" in
    *"$bundle_id.Hans"*"enabled=true"*) ;;
    *)
        echo "Feather Rust Dev 尚未启用，请先运行 scripts/enable-macos-input-method.sh。" >&2
        exit 1
        ;;
esac

"$repo_root/scripts/build-macos-client-acceptance.sh"
open -n "$repo_root/.build/macos-client-acceptance/FeatherInputClientAcceptance.app"
