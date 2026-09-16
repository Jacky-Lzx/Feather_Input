#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=im.feather.inputmethod.rustdev.FeatherInput
app_name=FeatherInputRustDev.app
install_root="${HOME:?}/Library/Input Methods"
source_app="$repo_root/.build/macos-input-method/$app_name"
destination="$install_root/$app_name"
staging_root=
backup_root=
new_installed=false
install_complete=false

cleanup() {
    if [ -n "$staging_root" ] && [ -d "$staging_root" ]; then
        rm -rf "$staging_root"
    fi
    if [ "$install_complete" != true ] && [ "$new_installed" = true ] && [ -d "$destination" ]; then
        new_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)
        if [ "$new_id" = "$bundle_id" ]; then
            rm -rf "$destination"
        fi
    fi
    if [ "$install_complete" != true ] && [ -n "$backup_root" ] && [ -d "$backup_root/$app_name" ]; then
        mv "$backup_root/$app_name" "$destination"
    fi
    if [ -n "$backup_root" ] && [ -d "$backup_root" ]; then
        rm -rf "$backup_root"
    fi
}
trap cleanup EXIT HUP INT TERM

"$repo_root/scripts/build-macos-input-method.sh"
source_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")
if [ "$source_id" != "$bundle_id" ]; then
    echo "拒绝安装非开发 Bundle ID：$source_id" >&2
    exit 1
fi
codesign --verify --deep --strict "$source_app"

mkdir -p "$install_root"
staging_root=$(mktemp -d "$install_root/.feather-rust-dev-install.XXXXXX")
staged_app="$staging_root/$app_name"
ditto "$source_app" "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [ -e "$destination" ]; then
    installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
    if [ "$installed_id" != "$bundle_id" ]; then
        echo "拒绝覆盖目标位置的其他应用：$installed_id" >&2
        exit 1
    fi
    pkill -x FeatherInputRustDev 2>/dev/null || true
    backup_root=$(mktemp -d "$install_root/.feather-rust-dev-backup.XXXXXX")
    mv "$destination" "$backup_root/$app_name"
fi
mv "$staged_app" "$destination"
new_installed=true
rmdir "$staging_root"
staging_root=

manager=$("$repo_root/scripts/build-macos-input-source-manager.sh")
if ! "$manager" register "$destination"; then
    echo "输入源注册失败，正在恢复安装前状态。" >&2
    exit 1
fi
install_complete=true
if [ -n "$backup_root" ] && [ -d "$backup_root" ]; then
    rm -rf "$backup_root"
    backup_root=
fi
if ! "$manager" status "$bundle_id"; then
    echo "警告：已注册输入源，但当前进程无法读取注册状态。" >&2
fi

echo "安装完成：$destination"
echo '“Feather Rust Dev”已可选择；脚本没有切换当前输入源。'
