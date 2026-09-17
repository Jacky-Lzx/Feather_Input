#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
release_plist="$repo_root/platforms/macos/input-method/Info.release.plist"
release_root=${FEATHER_RELEASE_OUTPUT_DIR:-"$repo_root/.build/macos-release"}
app="$release_root/FeatherInput.app"
notarize=false

if [ "$#" -gt 1 ]; then
    echo "用法：$0 [--notarize]" >&2
    exit 1
fi
if [ "$#" -eq 1 ]; then
    if [ "$1" != --notarize ]; then
        echo "用法：$0 [--notarize]" >&2
        exit 1
    fi
    notarize=true
fi

default_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$release_plist")
default_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$release_plist")
release_version=${FEATHER_RELEASE_VERSION:-$default_version}
release_build=${FEATHER_RELEASE_BUILD:-$default_build}
codesign_identity=${FEATHER_CODESIGN_IDENTITY:--}
notary_profile=${FEATHER_NOTARY_PROFILE:-}

case "$release_version" in
    '' | *[!0-9.]* | .* | *. | *..*)
        echo "发布版本必须由数字和点组成：$release_version" >&2
        exit 1
        ;;
esac
case "$release_build" in
    '' | *[!0-9]*)
        echo "构建号必须是正整数：$release_build" >&2
        exit 1
        ;;
esac
if [ "$release_build" -eq 0 ]; then
    echo "构建号必须大于零。" >&2
    exit 1
fi
if [ "$notarize" = true ] && [ "$codesign_identity" = - ]; then
    echo "公证构建必须通过 FEATHER_CODESIGN_IDENTITY 提供 Developer ID Application 证书。" >&2
    exit 1
fi
if [ "$notarize" = true ] && [ -z "$notary_profile" ]; then
    echo "公证构建必须通过 FEATHER_NOTARY_PROFILE 提供 notarytool 钥匙串配置名。" >&2
    exit 1
fi

echo "正在构建 Universal 正式输入法……"
FEATHER_MACOS_UNIVERSAL_BUILD_ROOT=$release_root \
    "$repo_root/scripts/build-macos-universal.sh" input-method-release

plist="$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$release_version" "$plist"
plutil -replace CFBundleVersion -string "$release_build" "$plist"

sign_macho() {
    binary=$1
    if [ "$codesign_identity" = - ]; then
        codesign --force --sign - --options runtime --timestamp=none "$binary" >/dev/null
    else
        codesign --force --sign "$codesign_identity" --options runtime --timestamp "$binary" >/dev/null
    fi
}

echo "正在使用签名身份 '$codesign_identity' 签名……"
find "$app/Contents/Frameworks" "$app/Contents/MacOS" -type f -print |
    while IFS= read -r binary; do
        file "$binary" | grep -q 'Mach-O' || continue
        sign_macho "$binary"
    done
sign_macho "$app"

"$repo_root/scripts/check-macos-bundle-dependencies.sh" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")
user_data=$(/usr/libexec/PlistBuddy -c 'Print :FeatherUserDataDirectory' "$plist")
if [ "$bundle_id" != im.feather.inputmethod.FeatherInput ] ||
    [ "$executable" != FeatherInput ] ||
    [ "$user_data" != FeatherInput ]; then
    echo "正式 bundle 元数据不符合发布约定。" >&2
    exit 1
fi

if [ "$codesign_identity" = - ]; then
    artifact="$release_root/FeatherInput-$release_version-$release_build-local.zip"
else
    artifact="$release_root/FeatherInput-$release_version-$release_build-signed.zip"
fi
if [ "$notarize" = true ]; then
    authority=$(codesign -d --verbose=4 "$app" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
    case "$authority" in
        'Developer ID Application:'*) ;;
        *)
            echo "公证构建没有使用 Developer ID Application 证书：$authority" >&2
            exit 1
            ;;
    esac
    artifact="$release_root/FeatherInput-$release_version-$release_build.zip"
fi

create_archive() {
    rm -f "$artifact"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$artifact"
}

create_archive
if [ "$notarize" = true ]; then
    echo "正在提交 Apple 公证服务……"
    xcrun notarytool submit "$artifact" \
        --keychain-profile "$notary_profile" \
        --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
    create_archive
fi
checksum="$artifact.sha256"
shasum -a 256 "$artifact" >"$checksum"

echo "发布归档完成：$artifact"
echo "SHA-256 校验文件：$checksum"
if [ "$codesign_identity" = - ]; then
    echo "注意：这是 ad-hoc 签名的本地验证包，不是可公开分发的公证版本。"
elif [ "$notarize" != true ]; then
    echo "注意：归档已经签名，但尚未提交 Apple 公证。"
fi
