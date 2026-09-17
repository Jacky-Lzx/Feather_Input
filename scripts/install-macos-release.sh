#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=im.feather.inputmethod.FeatherInput
app_name=FeatherInput.app
default_install_root="${HOME:?}/Library/Input Methods"
install_root=${FEATHER_INSTALL_ROOT:-$default_install_root}
source_app="$repo_root/.build/macos-release/$app_name"
allow_local=false
skip_registration=${FEATHER_SKIP_INPUT_SOURCE_REGISTRATION:-false}
manager_override=${FEATHER_INPUT_SOURCE_MANAGER:-}

if [ "$#" -gt 0 ] && [ "$1" = --allow-local ]; then
    allow_local=true
    shift
fi
if [ "$#" -gt 1 ]; then
    echo "用法：$0 [--allow-local] [FeatherInput.app]" >&2
    exit 1
fi
if [ "$#" -eq 1 ]; then
    source_app=$1
fi

case "$install_root" in
    /*) ;;
    *)
        echo "安装根目录必须是绝对路径：$install_root" >&2
        exit 1
        ;;
esac
case "$install_root" in
    / | "${HOME:?}")
        echo "拒绝使用不安全的安装根目录：$install_root" >&2
        exit 1
        ;;
esac
mkdir -p "$install_root"
install_root=$(realpath "$install_root")
home_root=$(realpath "${HOME:?}")
default_install_root="$home_root/Library/Input Methods"
if [ -d "$default_install_root" ]; then
    default_install_root=$(realpath "$default_install_root")
fi
case "$install_root" in
    / | "$home_root")
        echo "拒绝使用 canonicalize 后不安全的安装根目录：$install_root" >&2
        exit 1
        ;;
esac
if [ "$skip_registration" = true ] || [ -n "$manager_override" ]; then
    if [ "$install_root" = "$default_install_root" ]; then
        echo "真实安装目录不允许跳过或替换输入源注册工具。" >&2
        exit 1
    fi
fi
if [ "$skip_registration" != true ] && [ "$skip_registration" != false ]; then
    echo "FEATHER_SKIP_INPUT_SOURCE_REGISTRATION 只能是 true 或 false。" >&2
    exit 1
fi

destination="$install_root/$app_name"
if [ "$source_app" = "$destination" ]; then
    echo "源 bundle 不能与安装目标相同。" >&2
    exit 1
fi
if [ ! -d "$source_app/Contents/MacOS" ]; then
    echo "正式输入法 bundle 不存在或结构无效：$source_app" >&2
    exit 1
fi
if [ -L "$destination" ]; then
    echo "拒绝覆盖符号链接安装目标：$destination" >&2
    exit 1
fi

read_plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2/Contents/Info.plist"
}

verify_bundle() {
    candidate=$1
    candidate_id=$(read_plist CFBundleIdentifier "$candidate")
    candidate_executable=$(read_plist CFBundleExecutable "$candidate")
    candidate_data=$(read_plist FeatherUserDataDirectory "$candidate")
    if [ "$candidate_id" != "$bundle_id" ] ||
        [ "$candidate_executable" != FeatherInput ] ||
        [ "$candidate_data" != FeatherInput ]; then
        echo "拒绝安装身份或数据目录不符合约定的 bundle：$candidate" >&2
        exit 1
    fi
    codesign --verify --deep --strict --verbose=2 "$candidate"
    "$repo_root/scripts/check-macos-bundle-dependencies.sh" "$candidate"
    find "$candidate/Contents/MacOS" "$candidate/Contents/Frameworks" -type f -print |
        while IFS= read -r binary; do
            file "$binary" | grep -q 'Mach-O' || continue
            lipo -verify_arch arm64 "$binary"
            lipo -verify_arch x86_64 "$binary"
        done
}

verify_bundle "$source_app"
if [ "$allow_local" != true ]; then
    authority=$(codesign -d --verbose=4 "$source_app" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
    case "$authority" in
        'Developer ID Application:'*) ;;
        *)
            echo "正式安装要求 Developer ID Application 签名：$authority" >&2
            exit 1
            ;;
    esac
    xcrun stapler validate "$source_app"
    spctl --assess --type execute --verbose=2 "$source_app"
else
    echo "警告：--allow-local 仅用于本机验收，跳过 Developer ID、公证和 Gatekeeper 要求。"
fi

manager=
if [ "$skip_registration" != true ]; then
    if [ -n "$manager_override" ]; then
        manager=$manager_override
    else
        manager=$("$repo_root/scripts/build-macos-input-source-manager.sh")
    fi
    if [ ! -x "$manager" ]; then
        echo "输入源管理工具不可执行：$manager" >&2
        exit 1
    fi
fi

staging_root=$(mktemp -d "$install_root/.feather-release-stage.XXXXXX")
backup_root=
old_moved=false
new_moved=false
install_complete=false

cleanup() {
    trap - EXIT HUP INT TERM
    set +e
    if [ "$install_complete" != true ]; then
        if [ "$new_moved" = true ] && [ -d "$destination" ]; then
            rm -rf "$destination"
        fi
        if [ "$old_moved" = true ] && [ -n "$backup_root" ] &&
            [ -d "$backup_root/$app_name" ]; then
            mv "$backup_root/$app_name" "$destination"
            if [ -n "$manager" ]; then
                "$manager" register "$destination" >/dev/null 2>&1 || true
            fi
            echo "安装失败，已恢复原有 FeatherInput.app。" >&2
        fi
    fi
    if [ -n "$staging_root" ] && [ -d "$staging_root" ]; then
        rm -rf "$staging_root"
    fi
    if [ -n "$backup_root" ] && [ -d "$backup_root" ]; then
        rm -rf "$backup_root"
    fi
}
trap cleanup EXIT HUP INT TERM

staged_app="$staging_root/$app_name"
ditto "$source_app" "$staged_app"
verify_bundle "$staged_app"

if [ -e "$destination" ]; then
    if [ ! -d "$destination/Contents" ]; then
        echo "安装目标不是有效 app bundle：$destination" >&2
        exit 1
    fi
    installed_id=$(read_plist CFBundleIdentifier "$destination")
    installed_executable=$(read_plist CFBundleExecutable "$destination")
    if [ "$installed_id" != "$bundle_id" ] || [ "$installed_executable" != FeatherInput ]; then
        echo "拒绝覆盖目标位置的其他应用：$installed_id" >&2
        exit 1
    fi
    if [ "$install_root" = "$default_install_root" ]; then
        pkill -x FeatherInput 2>/dev/null || true
    fi
    backup_root=$(mktemp -d "$install_root/.feather-release-backup.XXXXXX")
    old_moved=true
    mv "$destination" "$backup_root/$app_name"
fi

new_moved=true
mv "$staged_app" "$destination"
rmdir "$staging_root"
staging_root=

if [ -n "$manager" ]; then
    if ! "$manager" register "$destination"; then
        echo "输入源注册失败，正在恢复安装前状态。" >&2
        exit 1
    fi
    if ! "$manager" require "$bundle_id"; then
        echo "注册后未发现正式输入源，正在恢复安装前状态。" >&2
        exit 1
    fi
fi

install_complete=true
if [ -n "$backup_root" ] && [ -d "$backup_root" ]; then
    rm -rf "$backup_root"
    backup_root=
fi
echo "正式输入法安装完成：$destination"
echo "用户数据保持在 ${HOME:?}/Library/Application Support/FeatherInput/Rime。"
if [ "$skip_registration" = true ]; then
    echo "隔离验收模式：未向 Text Input Sources 注册。"
fi
