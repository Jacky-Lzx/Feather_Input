#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_root/.build/swift-module-cache"
cd "$repo_root"

echo "正在检查 Swift 格式……"
xcrun swift-format lint \
    --strict \
    --recursive \
    platforms/macos/dev-harness/Sources

echo "正在检查 Swift 类型……"
mkdir -p "$module_cache"
swiftc \
    -typecheck \
    -parse-as-library \
    -module-cache-path "$module_cache" \
    -I platforms/macos/dev-harness/CFeatherIME \
    -framework AppKit \
    platforms/macos/dev-harness/Sources/*.swift

echo "正在检查 shell 脚本……"
sh -n \
    scripts/build-macos-dev-harness.sh \
    scripts/test-macos-dev-harness.sh \
    scripts/format-macos.sh \
    scripts/check-macos.sh
shellcheck \
    scripts/build-macos-dev-harness.sh \
    scripts/test-macos-dev-harness.sh \
    scripts/format-macos.sh \
    scripts/check-macos.sh

echo "正在检查应用元数据……"
plutil -lint platforms/macos/dev-harness/Info.plist
