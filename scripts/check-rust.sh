#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

echo "正在检查 Rust 格式……"
cargo fmt --manifest-path rust/Cargo.toml --all -- --check

echo "正在运行 Clippy……"
cargo clippy \
    --manifest-path rust/Cargo.toml \
    --workspace \
    --all-targets \
    -- \
    -D warnings
