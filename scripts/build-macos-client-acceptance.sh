#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_root="$repo_root/platforms/macos/client-acceptance"
build_root="$repo_root/.build/macos-client-acceptance"
app="$build_root/FeatherInputClientAcceptance.app"
executable="$app/Contents/MacOS/FeatherInputClientAcceptance"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$build_root/module-cache"
cp "$source_root/Info.plist" "$app/Contents/Info.plist"

swiftc \
    -parse-as-library \
    -module-cache-path "$build_root/module-cache" \
    -framework AppKit \
    "$source_root"/Sources/*.swift \
    -o "$executable"

codesign --force --sign - "$app" >/dev/null
codesign --verify --deep --strict "$app"
echo "构建完成：$app"
