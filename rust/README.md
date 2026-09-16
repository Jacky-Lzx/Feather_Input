# Feather Input Rust 核心

这个 workspace 是下一代 Feather Input 架构中与平台无关的基础。目前它与现有
Swift/InputMethodKit 应用并行存在：当前应用继续作为行为基准，Rust 实现则在独立
分支上接受审核并逐步接入。

包含以下 crate：

- `feather-core`：标准化输入事件、平台效果、候选身份以及输入引擎边界。
- `feather-engine-lexicon`：一个小型纯 Rust 参考引擎，用来验证不依赖 librime 的
  完整组合、候选和上屏链路。
- `feather-ffi`：面向 Swift、Windows TSF 和 Linux 输入法适配层的 C ABI。目前
  内置参考引擎。

运行整个 workspace 的测试：

```sh
cargo test --manifest-path rust/Cargo.toml
```

运行与提交前 hook 相同的格式和代码检查：

```sh
scripts/check-rust.sh
```

参考词典有意保持很小。它是用于验证架构的可执行样例，不用于替代现有 Rime 词库。
