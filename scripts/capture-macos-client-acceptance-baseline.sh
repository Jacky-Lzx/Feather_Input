#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:-"$repo_root/.build/macos-client-acceptance-baseline/baseline.md"}
output_dir=$(dirname -- "$output")
log_dir="$output_dir/logs"
bundle_name=FeatherInputRustDev.app
installed_bundle="${HOME:?}/Library/Input Methods/$bundle_name"
built_bundle="$repo_root/.build/macos-input-method/$bundle_name"
built_executable="$built_bundle/Contents/MacOS/FeatherInputRustDev"
installed_executable="$installed_bundle/Contents/MacOS/FeatherInputRustDev"

mkdir -p "$log_dir"

run_check() {
    label=$1
    log=$2
    shift 2
    printf '正在执行：%s……\n' "$label"
    if "$@" >"$log" 2>&1; then
        return 0
    fi
    printf '%s失败，日志：%s\n' "$label" "$log" >&2
    return 1
}

check_result=通过
smoke_result=通过
build_result=通过
status_result=通过

run_check "macOS 静态检查" "$log_dir/check-macos.log" \
    "$repo_root/scripts/check-macos.sh" || check_result=失败
run_check "InputMethodKit smoke tests" "$log_dir/test-macos-input-method.log" \
    "$repo_root/scripts/test-macos-input-method.sh" || smoke_result=失败
run_check "开发输入法构建" "$log_dir/build-macos-input-method.log" \
    "$repo_root/scripts/build-macos-input-method.sh" || build_result=失败
run_check "开发输入法安装状态" "$log_dir/status-macos-input-method.log" \
    "$repo_root/scripts/status-macos-input-method.sh" || status_result=失败

built_hash=不可用
installed_hash=不可用
artifact_result=失败
if [ -f "$built_executable" ]; then
    built_hash=$(shasum -a 256 "$built_executable" | cut -d ' ' -f 1)
fi
if [ -f "$installed_executable" ]; then
    installed_hash=$(shasum -a 256 "$installed_executable" | cut -d ' ' -f 1)
fi
if [ "$built_hash" = "$installed_hash" ] && [ "$built_hash" != "不可用" ]; then
    artifact_result=通过
fi

git_status=$(git -C "$repo_root" status --porcelain)
if [ -z "$git_status" ]; then
    worktree_state=干净
else
    worktree_state=有未提交修改
fi

generated_at=$(date '+%Y-%m-%d %H:%M:%S %z')
commit=$(git -C "$repo_root" rev-parse HEAD)
branch=$(git -C "$repo_root" branch --show-current)
macos_version=$(sw_vers -productVersion)
macos_build=$(sw_vers -buildVersion)
architecture=$(uname -m)
swift_version=$(swiftc --version 2>&1 | sed -n '/Apple Swift version/p')
rust_version=$(rustc --version)
cargo_version=$(cargo --version)

{
    printf '# Feather Rust Dev macOS 客户端验收基线\n\n'
    printf '> 本文件由 `scripts/capture-macos-client-acceptance-baseline.sh` 生成。'
    printf '自动检查不能替代真实客户端中的人工观察。\n\n'
    printf '## 环境\n\n'
    printf -- '- 生成时间：`%s`\n' "$generated_at"
    printf -- '- Git 分支：`%s`\n' "$branch"
    printf -- '- Git 提交：`%s`\n' "$commit"
    printf -- '- 工作区：%s\n' "$worktree_state"
    printf -- '- macOS：`%s (%s)`\n' "$macos_version" "$macos_build"
    printf -- '- 架构：`%s`\n' "$architecture"
    printf -- '- Swift：`%s`\n' "$swift_version"
    printf -- '- Rust：`%s`\n' "$rust_version"
    printf -- '- Cargo：`%s`\n\n' "$cargo_version"
    printf '## 自动验证\n\n'
    printf '| 项目 | 结果 | 日志 |\n'
    printf '| --- | --- | --- |\n'
    printf '| macOS 静态检查 | %s | `logs/check-macos.log` |\n' "$check_result"
    printf '| InputMethodKit smoke tests | %s | `logs/test-macos-input-method.log` |\n' "$smoke_result"
    printf '| 开发输入法构建 | %s | `logs/build-macos-input-method.log` |\n' "$build_result"
    printf '| 安装状态与签名 | %s | `logs/status-macos-input-method.log` |\n' "$status_result"
    printf '| 构建／安装产物一致 | %s | 见下方 SHA-256 |\n\n' "$artifact_result"
    printf '## 安装产物\n\n'
    printf -- '- 构建路径：`%s`\n' "$built_bundle"
    printf -- '- 安装路径：`%s`\n' "$installed_bundle"
    printf -- '- 构建 SHA-256：`%s`\n' "$built_hash"
    printf -- '- 安装 SHA-256：`%s`\n\n' "$installed_hash"
    printf '## 人工验收\n\n'
    printf '按照 `docs/macos-client-acceptance-matrix.md` 执行。每项必须记录客户端版本、'
    printf '通过／失败和复现说明；未执行的项目保持“未测”，不能记为通过。\n'
} >"$output"

printf '基线报告：%s\n' "$output"

if [ "$check_result" != 通过 ] || [ "$smoke_result" != 通过 ] \
    || [ "$build_result" != 通过 ] || [ "$status_result" != 通过 ] \
    || [ "$artifact_result" != 通过 ]; then
    exit 1
fi
