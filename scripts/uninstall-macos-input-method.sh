#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=im.feather.inputmethod.rustdev.FeatherInput
app_name=FeatherInputRustDev.app
install_root="${HOME:?}/Library/Input Methods"
destination="$install_root/$app_name"
launch_services=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
manager=$("$repo_root/scripts/build-macos-input-source-manager.sh")

"$manager" disable "$bundle_id"
pkill -x FeatherInputRustDev 2>/dev/null || true

if [ -e "$destination" ]; then
    installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
    if [ "$installed_id" != "$bundle_id" ]; then
        echo "拒绝删除目标位置的其他应用：$installed_id" >&2
        exit 1
    fi
    "$launch_services" -u "$destination" >/dev/null 2>&1 || true
    rm -rf "$destination"
    echo "已删除：$destination"
else
    echo "开发输入法未安装，无需删除。"
fi

echo "用户词库仍保留在 ${HOME:?}/Library/Application Support/FeatherInputRustDev/Rime。"
