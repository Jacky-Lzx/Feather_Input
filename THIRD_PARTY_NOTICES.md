# Third-party components

- [librime](https://github.com/rime/librime): BSD-3-Clause. C API header is retained with its upstream copyright notice. Runtime comes from Homebrew; this build used 1.17.0_2.
- [luna-pinyin](https://github.com/rime/rime-luna-pinyin), [double-pinyin](https://github.com/rime/rime-double-pinyin), [stroke](https://github.com/rime/rime-stroke), [essay](https://github.com/rime/rime-essay), [prelude](https://github.com/rime/rime-prelude): upstream licenses and pinned revisions are collected by `scripts/prepare-data.sh`. Their licensing is separate from librime, including LGPL/GPL data packages. Preserve source, attribution, and applicable redistribution obligations when publishing.
- [OpenCC](https://github.com/BYVoid/OpenCC), glog, gflags, yaml-cpp, leveldb, snappy, marisa: bundled runtime dependencies. License and author files are copied from the installed distributions to `Contents/Resources/licenses`.

Downloaded Rime data source remains available under `.deps`. The app carries the YAML/text data, OpenCC data, and precompiled dictionaries. Build scripts retain the exact data revisions so their upstream source can be retrieved. Runtime dylibs are copied from Homebrew and relocated; they are not modified at source level. Runtime dependency versions depend on the local Homebrew installation.

The vendored `rime_api.h` was fetched from upstream master on 2026-09-13. The application does not bundle or derive its UI code from Squirrel.

## Optional local backend: pypinyin 0.55.0

The pinyin-constrained generation backend uses the single-character pronunciation data from
[pypinyin](https://github.com/mozillazg/python-pinyin), licensed under MIT.
The license text is retained in `backend/licenses/pypinyin-MIT.txt` and in the installed package.
This Python dependency is installed in the local worker environment, not bundled into the input-method executable.
