#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
preview_root="$repo_root/platforms/macos/candidate-preview"
input_method_root="$repo_root/platforms/macos/input-method"
build_root="$repo_root/.build/macos-candidate-preview"
app="$build_root/FeatherCandidatePreview.app"
executable="$app/Contents/MacOS/FeatherCandidatePreview"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$build_root/module-cache"
cp "$preview_root/Info.plist" "$app/Contents/Info.plist"

swiftc \
    -parse-as-library \
    -module-cache-path "$build_root/module-cache" \
    -framework AppKit \
    "$input_method_root/Sources/CandidateLayoutSettings.swift" \
    "$input_method_root/Sources/CandidateWindowStyle.swift" \
    "$input_method_root/Sources/CandidateWindowController.swift" \
    "$preview_root"/Sources/*.swift \
    -o "$executable"

codesign --force --sign - "$app" >/dev/null
codesign --verify --deep --strict "$app"
echo "构建完成：$app"
echo "启动命令：open -n '$app'"
