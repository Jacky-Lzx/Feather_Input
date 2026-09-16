#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=im.feather.inputmethod.rustdev.FeatherInput
app_name=FeatherInputRustDev.app
destination="${HOME:?}/Library/Input Methods/$app_name"

if [ ! -d "$destination" ]; then
    echo "开发输入法尚未安装，请先运行 scripts/install-macos-input-method.sh。" >&2
    exit 1
fi
installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
if [ "$installed_id" != "$bundle_id" ]; then
    echo "拒绝启用目标位置的其他应用：$installed_id" >&2
    exit 1
fi

manager=$("$repo_root/scripts/build-macos-input-source-manager.sh")
"$manager" register "$destination"
"$manager" enable "$bundle_id"
"$manager" status "$bundle_id"

echo '已启用“Feather Rust Dev”，但没有切换当前输入源。'
