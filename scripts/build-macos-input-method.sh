#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_root="$repo_root/platforms/macos/input-method"
shared_root="$repo_root/platforms/macos/shared"
profile=${FEATHER_MACOS_PROFILE:-development}
case "$profile" in
    development)
        info_plist="$source_root/Info.plist"
        app_name=FeatherInputRustDev.app
        executable_name=FeatherInputRustDev
        product_label="InputMethodKit 开发输入法"
        default_build_root="$repo_root/.build/macos-input-method"
        ;;
    release)
        info_plist="$source_root/Info.release.plist"
        app_name=FeatherInput.app
        executable_name=FeatherInput
        product_label="InputMethodKit 正式输入法"
        default_build_root="$repo_root/.build/macos-input-method-release"
        ;;
    *)
        echo "不支持的 macOS 构建配置：$profile" >&2
        exit 1
        ;;
esac
build_root=${FEATHER_MACOS_BUILD_ROOT:-$default_build_root}
app="$build_root/$app_name"
executable="$app/Contents/MacOS/$executable_name"
frameworks="$app/Contents/Frameworks"
resources="$app/Contents/Resources"
macos_arch=${FEATHER_MACOS_ARCH:-$(uname -m)}
deployment_target=${FEATHER_MACOS_DEPLOYMENT_TARGET:-13.0}

case "$macos_arch" in
    arm64)
        rust_target=aarch64-apple-darwin
        ;;
    x86_64)
        rust_target=x86_64-apple-darwin
        ;;
    *)
        echo "不支持的 macOS 架构：$macos_arch" >&2
        exit 1
        ;;
esac

rust_target_root=${FEATHER_RUST_TARGET_DIR:-"$repo_root/.build/rust-targets"}
rust_output="$rust_target_root/$rust_target/release"
rust_library="$rust_output/libfeather_ffi.dylib"

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

echo "正在构建 $macos_arch Rust C ABI……"
CARGO_TARGET_DIR=$rust_target_root \
    cargo build \
    --manifest-path "$repo_root/rust/Cargo.toml" \
    --release \
    --target "$rust_target" \
    -p feather-ffi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$frameworks" "$resources"
mkdir -p "$build_root/module-cache"
cp "$info_plist" "$app/Contents/Info.plist"
cp "$rust_library" "$frameworks/libfeather_ffi.dylib"
install_name_tool -id @rpath/libfeather_ffi.dylib "$frameworks/libfeather_ffi.dylib"

echo "正在编译 ${product_label}……"
swiftc \
    -parse-as-library \
    -target "$macos_arch-apple-macosx$deployment_target" \
    -module-cache-path "$build_root/module-cache" \
    -I "$shared_root/CFeatherIME" \
    -L "$rust_output" \
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

echo "正在收集便携动态库……"
"$repo_root/scripts/bundle-macos-dylibs.sh" \
    "$frameworks/libfeather_ffi.dylib" \
    "$frameworks" \
    "$resources/ThirdPartyLicenses"

echo "正在复制 Rime 共享数据……"
ditto "$shared_data" "$resources/rime"

find "$frameworks" -type f -name '*.dylib' -exec codesign --force --sign - {} \; >/dev/null
"$repo_root/scripts/check-macos-bundle-dependencies.sh" "$app"
codesign --force --sign - "$app" >/dev/null
codesign --verify --deep --strict "$app"
echo "构建完成（未安装）：$app"
