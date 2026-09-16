#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=im.feather.inputmethod.rustdev.FeatherInput
app_name=FeatherInputRustDev.app
install_root="${HOME:?}/Library/Input Methods"
destination="$install_root/$app_name"
manager=$("$repo_root/scripts/build-macos-input-source-manager.sh")

if [ -d "$destination" ]; then
    installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
    if [ "$installed_id" = "$bundle_id" ]; then
        echo "Bundle 已安装：$destination"
        codesign --verify --deep --strict "$destination"
    else
        echo "目标位置存在其他 Bundle ID：$installed_id" >&2
        exit 1
    fi
else
    echo "Bundle 未安装：$destination"
fi

"$manager" status "$bundle_id"
