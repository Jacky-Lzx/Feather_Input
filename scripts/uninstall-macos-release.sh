#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=im.feather.inputmethod.FeatherInput
app_name=FeatherInput.app
default_install_root="${HOME:?}/Library/Input Methods"
install_root=${FEATHER_INSTALL_ROOT:-$default_install_root}
default_data_root="${HOME:?}/Library/Application Support"
data_root=${FEATHER_APPLICATION_SUPPORT_ROOT:-$default_data_root}
skip_registration=${FEATHER_SKIP_INPUT_SOURCE_REGISTRATION:-false}
manager_override=${FEATHER_INPUT_SOURCE_MANAGER:-}
purge_data=false

if [ "$#" -gt 1 ]; then
    echo "用法：$0 [--purge-user-data]" >&2
    exit 1
fi
if [ "$#" -eq 1 ]; then
    if [ "$1" != --purge-user-data ]; then
        echo "用法：$0 [--purge-user-data]" >&2
        exit 1
    fi
    purge_data=true
fi
case "$install_root" in
    /*) ;;
    *)
        echo "安装根目录必须是绝对路径：$install_root" >&2
        exit 1
        ;;
esac
case "$data_root" in
    /*) ;;
    *)
        echo "用户数据根目录必须是绝对路径：$data_root" >&2
        exit 1
        ;;
esac
mkdir -p "$install_root" "$data_root"
install_root=$(realpath "$install_root")
data_root=$(realpath "$data_root")
home_root=$(realpath "${HOME:?}")
default_install_root="$home_root/Library/Input Methods"
default_data_root="$home_root/Library/Application Support"
if [ -d "$default_install_root" ]; then
    default_install_root=$(realpath "$default_install_root")
fi
if [ -d "$default_data_root" ]; then
    default_data_root=$(realpath "$default_data_root")
fi
case "$install_root" in
    / | "$home_root")
        echo "拒绝使用不安全的安装根目录：$install_root" >&2
        exit 1
        ;;
esac
case "$data_root" in
    / | "$home_root")
        echo "拒绝使用不安全的用户数据根目录：$data_root" >&2
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
if [ "$purge_data" = true ] && [ "$data_root" != "$default_data_root" ] &&
    [ -z "${FEATHER_APPLICATION_SUPPORT_ROOT:-}" ]; then
    echo "非默认用户数据目录必须显式设置 FEATHER_APPLICATION_SUPPORT_ROOT。" >&2
    exit 1
fi

destination="$install_root/$app_name"
user_data="$data_root/FeatherInput"
if [ -L "$destination" ] || [ -L "$user_data" ]; then
    echo "拒绝移除符号链接目标。" >&2
    exit 1
fi
if [ ! -d "$destination/Contents" ]; then
    echo "没有找到正式输入法：$destination" >&2
    exit 1
fi
installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
installed_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$destination/Contents/Info.plist")
if [ "$installed_id" != "$bundle_id" ] || [ "$installed_executable" != FeatherInput ]; then
    echo "拒绝移除目标位置的其他应用：$installed_id" >&2
    exit 1
fi

manager=
was_enabled=false
sources_disabled=false
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
    status=$("$manager" require "$bundle_id")
    if printf '%s\n' "$status" | grep -q 'enabled=true'; then
        was_enabled=true
    fi
fi

app_removal_root=$(mktemp -d "$install_root/.feather-release-remove.XXXXXX")
data_removal_root=
app_moved=false
data_moved=false
uninstall_complete=false

cleanup() {
    trap - EXIT HUP INT TERM
    set +e
    if [ "$uninstall_complete" != true ]; then
        if [ "$data_moved" = true ] && [ -n "$data_removal_root" ] &&
            [ -d "$data_removal_root/FeatherInput" ] && [ ! -e "$user_data" ]; then
            mv "$data_removal_root/FeatherInput" "$user_data"
        fi
        if [ "$app_moved" = true ] && [ -d "$app_removal_root/$app_name" ] &&
            [ ! -e "$destination" ]; then
            mv "$app_removal_root/$app_name" "$destination"
        fi
        if [ "$sources_disabled" = true ] && [ -n "$manager" ]; then
            "$manager" register "$destination" >/dev/null 2>&1 || true
            if [ "$was_enabled" = true ]; then
                "$manager" enable "$bundle_id" >/dev/null 2>&1 || true
            fi
        fi
    fi
    if [ -d "$app_removal_root" ]; then
        rm -rf "$app_removal_root"
    fi
    if [ -n "$data_removal_root" ] && [ -d "$data_removal_root" ]; then
        rm -rf "$data_removal_root"
    fi
}
trap cleanup EXIT HUP INT TERM

if [ -n "$manager" ]; then
    sources_disabled=true
    "$manager" disable "$bundle_id"
    if "$manager" status "$bundle_id" | grep -q 'enabled=true'; then
        echo "输入源仍处于启用状态，拒绝继续卸载。" >&2
        exit 1
    fi
fi
if [ "$install_root" = "$default_install_root" ]; then
    pkill -x FeatherInput 2>/dev/null || true
fi

app_moved=true
mv "$destination" "$app_removal_root/$app_name"
if [ "$purge_data" = true ] && [ -d "$user_data" ]; then
    data_removal_root=$(mktemp -d "$data_root/.feather-data-remove.XXXXXX")
    data_moved=true
    mv "$user_data" "$data_removal_root/FeatherInput"
fi

uninstall_complete=true
rm -rf "$app_removal_root"
if [ -n "$data_removal_root" ] && [ -d "$data_removal_root" ]; then
    rm -rf "$data_removal_root"
fi
echo "正式输入法已卸载：$destination"
if [ "$purge_data" = true ]; then
    echo "用户数据已明确清除：$user_data"
else
    echo "用户数据已保留：$user_data"
fi
