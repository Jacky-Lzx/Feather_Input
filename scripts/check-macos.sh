#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_root/.build/swift-module-cache"
cd "$repo_root"

echo "正在检查 Swift 格式……"
xcrun swift-format lint \
    --strict \
    --recursive \
    platforms/macos/shared/Sources \
    platforms/macos/dev-harness/Sources \
    platforms/macos/input-method/Sources \
    platforms/macos/input-method/Tests

echo "正在检查 Harness Swift 类型……"
mkdir -p "$module_cache"
swiftc \
    -typecheck \
    -parse-as-library \
    -module-cache-path "$module_cache" \
    -I platforms/macos/shared/CFeatherIME \
    -framework AppKit \
    platforms/macos/shared/Sources/*.swift \
    platforms/macos/dev-harness/Sources/*.swift

echo "正在检查 InputMethodKit Swift 类型……"
swiftc \
    -typecheck \
    -parse-as-library \
    -module-cache-path "$module_cache" \
    -I platforms/macos/shared/CFeatherIME \
    -framework AppKit \
    -framework Carbon \
    -framework InputMethodKit \
    platforms/macos/shared/Sources/*.swift \
    platforms/macos/input-method/Sources/*.swift

echo "正在检查 C ABI 头文件……"
xcrun clang \
    -std=c11 \
    -fsyntax-only \
    -I rust/crates/feather-ffi/include \
    rust/crates/feather-ffi/tests/header_smoke.c
xcrun clang++ \
    -std=c++17 \
    -x c++ \
    -fsyntax-only \
    -I rust/crates/feather-ffi/include \
    rust/crates/feather-ffi/tests/header_smoke.c

echo "正在检查 shell 脚本……"
sh -n \
    scripts/build-macos-dev-harness.sh \
    scripts/build-macos-input-method.sh \
    scripts/test-macos-dev-harness.sh \
    scripts/test-macos-input-method.sh \
    scripts/test-rime-traces.sh \
    scripts/format-macos.sh \
    scripts/check-macos.sh
shellcheck \
    scripts/build-macos-dev-harness.sh \
    scripts/build-macos-input-method.sh \
    scripts/test-macos-dev-harness.sh \
    scripts/test-macos-input-method.sh \
    scripts/test-rime-traces.sh \
    scripts/format-macos.sh \
    scripts/check-macos.sh

echo "正在检查应用元数据……"
plutil -lint \
    platforms/macos/dev-harness/Info.plist \
    platforms/macos/input-method/Info.plist

development_identifier=$(
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        platforms/macos/input-method/Info.plist
)
if [ "$development_identifier" != "im.feather.inputmethod.rustdev.FeatherInput" ]; then
    echo "InputMethodKit 开发包必须使用隔离的 Bundle ID。" >&2
    exit 1
fi
