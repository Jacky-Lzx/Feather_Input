#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "用法：$0 <上游共享数据目录> <目标目录>" >&2
    exit 2
fi

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
shared_data=$1
target=$2
overlay="$repo_root/platforms/macos/input-method/Resources/rime"

for required in essay.txt easy_en.dict.yaml; do
    if [ ! -f "$shared_data/$required" ]; then
        echo "Rime 共享数据缺少英文候选依赖 $required：$shared_data" >&2
        exit 1
    fi
done

mkdir -p "$target"
ditto "$shared_data" "$target"
ditto "$overlay" "$target"

for required in \
    feather_english.schema.yaml \
    feather_english.dict.yaml \
    luna_pinyin_simp.custom.yaml \
    double_pinyin_flypy.custom.yaml; do
    if [ ! -f "$target/$required" ]; then
        echo "暂存后的 Rime 数据缺少 $required：$target" >&2
        exit 1
    fi
done
