#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "用法：$0 <arm64-app> <x86_64-app> <output-app>" >&2
    exit 1
fi

arm_app=$1
x86_app=$2
output_app=$3

for app in "$arm_app" "$x86_app"; do
    if [ ! -d "$app/Contents/MacOS" ] || [ ! -d "$app/Contents/Frameworks" ]; then
        echo "应用 bundle 结构无效：$app" >&2
        exit 1
    fi
done

case "$output_app" in
    "$arm_app" | "$arm_app"/* | "$x86_app" | "$x86_app"/*)
        echo "Universal 输出不能覆盖或位于输入 bundle 内：$output_app" >&2
        exit 1
        ;;
esac

arm_files=$(mktemp /tmp/feather-arm-files.XXXXXX)
x86_files=$(mktemp /tmp/feather-x86-files.XXXXXX)
trap 'rm -f "$arm_files" "$x86_files"' EXIT HUP INT TERM

collect_macho_files() {
    app=$1
    destination=$2
    find "$app/Contents/MacOS" "$app/Contents/Frameworks" -type f -print |
        while IFS= read -r binary; do
            if file "$binary" | grep -q 'Mach-O'; then
                printf '%s\n' "${binary#"$app"/}"
            fi
        done | LC_ALL=C sort >"$destination"
}

collect_macho_files "$arm_app" "$arm_files"
collect_macho_files "$x86_app" "$x86_files"
if ! cmp -s "$arm_files" "$x86_files"; then
    echo "两个切片的 Mach-O 文件集合不一致：" >&2
    diff -u "$arm_files" "$x86_files" >&2 || true
    exit 1
fi

if ! cmp -s "$arm_app/Contents/Info.plist" "$x86_app/Contents/Info.plist"; then
    echo "两个切片的 Info.plist 不一致。" >&2
    exit 1
fi
if ! diff -qr \
    "$arm_app/Contents/Resources/ThirdPartyLicenses" \
    "$x86_app/Contents/Resources/ThirdPartyLicenses" >/dev/null; then
    echo "两个切片的第三方许可证集合不一致。" >&2
    exit 1
fi

rm -rf "$output_app"
mkdir -p "$(dirname "$output_app")"
ditto "$arm_app" "$output_app"

while IFS= read -r relative; do
    arm_binary="$arm_app/$relative"
    x86_binary="$x86_app/$relative"
    output_binary="$output_app/$relative"
    if ! lipo -verify_arch arm64 "$arm_binary"; then
        echo "arm64 切片架构错误：$arm_binary" >&2
        exit 1
    fi
    if ! lipo -verify_arch x86_64 "$x86_binary"; then
        echo "x86_64 切片架构错误：$x86_binary" >&2
        exit 1
    fi
    lipo -create "$arm_binary" "$x86_binary" -output "$output_binary"
done <"$arm_files"

while IFS= read -r relative; do
    codesign --force --sign - "$output_app/$relative" >/dev/null
done <"$arm_files"
codesign --force --sign - "$output_app" >/dev/null
codesign --verify --deep --strict "$output_app"

while IFS= read -r relative; do
    if ! lipo -verify_arch arm64 "$output_app/$relative" ||
        ! lipo -verify_arch x86_64 "$output_app/$relative"; then
        echo "Universal 文件缺少目标架构：$output_app/$relative" >&2
        exit 1
    fi
done <"$arm_files"

echo "Universal bundle 合并完成：$output_app"
