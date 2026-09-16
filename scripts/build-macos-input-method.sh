#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_root="$repo_root/platforms/macos/input-method"
shared_root="$repo_root/platforms/macos/shared"
build_root="$repo_root/.build/macos-input-method"
app="$build_root/FeatherInputRustDev.app"
executable="$app/Contents/MacOS/FeatherInputRustDev"
frameworks="$app/Contents/Frameworks"
resources="$app/Contents/Resources"
rust_library="$repo_root/rust/target/release/libfeather_ffi.dylib"

if [ -n "${FEATHER_RIME_SHARED_DATA_DIR:-}" ]; then
    shared_data=$FEATHER_RIME_SHARED_DATA_DIR
else
    shared_data="$repo_root/dist/FeatherInput.app/Contents/Resources/rime"
fi

if [ ! -f "$shared_data/essay.txt" ]; then
    echo "Rime 共享数据无效或缺少 essay.txt：$shared_data" >&2
    echo "请设置 FEATHER_RIME_SHARED_DATA_DIR。" >&2
    exit 1
fi

echo "正在构建 Rust C ABI……"
cargo build --manifest-path "$repo_root/rust/Cargo.toml" --release -p feather-ffi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$frameworks" "$resources"
mkdir -p "$build_root/module-cache"
cp "$source_root/Info.plist" "$app/Contents/Info.plist"
cp "$rust_library" "$frameworks/libfeather_ffi.dylib"
install_name_tool -id @rpath/libfeather_ffi.dylib "$frameworks/libfeather_ffi.dylib"

echo "正在编译 InputMethodKit 开发输入法……"
swiftc \
    -parse-as-library \
    -module-cache-path "$build_root/module-cache" \
    -I "$shared_root/CFeatherIME" \
    -L "$repo_root/rust/target/release" \
    -lfeather_ffi \
    -framework AppKit \
    -framework Carbon \
    -framework InputMethodKit \
    -Xlinker -rpath \
    -Xlinker @executable_path/../Frameworks \
    "$shared_root"/Sources/*.swift \
    "$source_root"/Sources/*.swift \
    -o "$executable"

rust_install_name=$(otool -D "$rust_library" | tail -n 1 | sed 's/^[[:space:]]*//')
install_name_tool -change "$rust_install_name" @rpath/libfeather_ffi.dylib "$executable"

echo "正在复制 Rime 共享数据……"
ditto "$shared_data" "$resources/rime"

codesign --force --sign - "$app" >/dev/null
codesign --verify --strict "$app"
echo "构建完成（未安装）：$app"
