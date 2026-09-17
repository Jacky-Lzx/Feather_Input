#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
product=${1:-input-method}
slice_root="$repo_root/.build/macos-universal-slices/$product"

case "$product" in
    input-method)
        builder="$repo_root/scripts/build-macos-input-method.sh"
        app_name=FeatherInputRustDev.app
        macos_profile=development
        final_root=${FEATHER_MACOS_UNIVERSAL_BUILD_ROOT:-"$repo_root/.build/macos-input-method"}
        ;;
    input-method-release)
        builder="$repo_root/scripts/build-macos-input-method.sh"
        app_name=FeatherInput.app
        macos_profile=release
        final_root=${FEATHER_MACOS_UNIVERSAL_BUILD_ROOT:-"$repo_root/.build/macos-release"}
        ;;
    dev-harness)
        builder="$repo_root/scripts/build-macos-dev-harness.sh"
        app_name=FeatherInputDevHarness.app
        macos_profile=development
        final_root=${FEATHER_MACOS_UNIVERSAL_BUILD_ROOT:-"$repo_root/.build/macos-dev-harness"}
        ;;
    *)
        echo "用法：$0 [input-method|input-method-release|dev-harness]" >&2
        exit 1
        ;;
esac

arm_prefix=${FEATHER_RIME_ARM64_PREFIX:-/opt/homebrew/opt/librime}
x86_prefix=${FEATHER_RIME_X86_64_PREFIX:-/usr/local/opt/librime}
installed_targets=$(rustup target list --installed)

validate_toolchain() {
    arch=$1
    rust_target=$2
    prefix=$3
    prefix_variable=$4
    if ! printf '%s\n' "$installed_targets" | grep -Fqx "$rust_target"; then
        echo "缺少 Rust target：${rust_target}；请先运行 rustup target add $rust_target" >&2
        exit 1
    fi
    if [ ! -f "$prefix/include/rime_api.h" ] || [ ! -f "$prefix/lib/librime.dylib" ]; then
        echo "缺少 $arch librime：$prefix" >&2
        echo "可以通过 $prefix_variable 指定对应架构的安装前缀。" >&2
        exit 1
    fi
    if ! lipo -verify_arch "$arch" "$prefix/lib/librime.dylib"; then
        echo "librime 不包含 $arch 切片：$prefix/lib/librime.dylib" >&2
        exit 1
    fi
}

validate_toolchain arm64 aarch64-apple-darwin "$arm_prefix" FEATHER_RIME_ARM64_PREFIX
validate_toolchain x86_64 x86_64-apple-darwin "$x86_prefix" FEATHER_RIME_X86_64_PREFIX

build_slice() {
    arch=$1
    prefix=$2
    echo "正在构建 $product 的 $arch 切片……"
    FEATHER_MACOS_ARCH=$arch \
        FEATHER_MACOS_BUILD_ROOT="$slice_root/$arch" \
        FEATHER_MACOS_PROFILE=$macos_profile \
        FEATHER_DYLIB_SEARCH_DIRS="$prefix/lib" \
        RIME_INCLUDE_DIR="$prefix/include" \
        RIME_LIB_DIR="$prefix/lib" \
        "$builder"
}

build_slice arm64 "$arm_prefix"
build_slice x86_64 "$x86_prefix"

"$repo_root/scripts/merge-macos-app-slices.sh" \
    "$slice_root/arm64/$app_name" \
    "$slice_root/x86_64/$app_name" \
    "$final_root/$app_name"
"$repo_root/scripts/check-macos-bundle-dependencies.sh" "$final_root/$app_name"
