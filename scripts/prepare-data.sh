#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .deps dist/rime dist/licenses
fetch() {
  local name="$1" revision="$2"
  local path=".deps/$name"
  if [ ! -d "$path/.git" ]; then git clone "https://github.com/rime/rime-$name.git" "$path"; fi
  if ! git -C "$path" cat-file -e "$revision^{commit}" 2>/dev/null; then git -C "$path" fetch origin "$revision"; fi
  git -C "$path" checkout --detach "$revision"
  if [ "$name" = essay ]; then cp "$path/essay.txt" dist/rime/; else cp "$path"/*.yaml dist/rime/; fi
  cp "$path/LICENSE" "dist/licenses/rime-$name.txt"
}
fetch luna-pinyin 56b934b099dfbeab842320f13aa8b461a6ab3e42
fetch double-pinyin 01a13287cbd27819be1c34fa1ddc1b3643d5001b
fetch prelude 082425ea0684bca36474415d4a0e8db9b016487e
# stroke revision is pinned alongside the other data repositories.
fetch stroke 1e8fff9b9494ddec23b0cbc526bcfd8171a6fd48
fetch essay e9b1a374a6ea015fca5bdd04318924b4483ac35a
cp Resources/default.custom.yaml dist/rime/
mkdir -p dist/rime/opencc
cp -R "$(brew --prefix opencc)/share/opencc/"* dist/rime/opencc/

for formula in librime glog gflags yaml-cpp leveldb snappy marisa opencc; do
  prefix=$(brew --prefix "$formula")
  mkdir -p "dist/licenses/$formula"
  for file in "$prefix"/LICENSE* "$prefix"/COPYING* "$prefix"/AUTHORS*; do
    [ ! -f "$file" ] || cp "$file" "dist/licenses/$formula/"
  done
done
