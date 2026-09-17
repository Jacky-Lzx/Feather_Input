#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

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

staged_data=$(mktemp -d /tmp/feather-rime-traces.XXXXXX)
trap 'rm -rf "$staged_data"' EXIT HUP INT TERM
"$repo_root/scripts/stage-rime-data.sh" "$shared_data" "$staged_data"

echo "Rime 共享数据：$staged_data"
if command -v pkg-config >/dev/null 2>&1; then
    echo "librime 版本：$(pkg-config --modversion rime)"
fi
echo "真实 Trace 将为每个场景创建独立临时用户目录。"
FEATHER_RIME_SHARED_DATA_DIR=$staged_data \
    cargo test \
    --manifest-path "$repo_root/rust/Cargo.toml" \
    -p feather-trace \
    --test rime_traces \
    -- \
    --ignored \
    --nocapture \
