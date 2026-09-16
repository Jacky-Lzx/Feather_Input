#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$repo_root/platforms/macos/input-method/Tools/InputSourceManager.swift"
build_root="$repo_root/.build/macos-input-source-manager"
executable="$build_root/input-source-manager"

mkdir -p "$build_root/module-cache"
swiftc \
    -parse-as-library \
    -module-cache-path "$build_root/module-cache" \
    -framework Carbon \
    "$source_file" \
    -o "$executable"

echo "$executable"
