# macOS 开发调试壳

这是一个普通 AppKit 应用，用来验证 Swift、C ABI、Rust 核心和 librime 的完整链路。
它不是 InputMethodKit 输入法，不会注册系统输入源，也不会替换当前安装的 Feather
Input。

## 构建

本机需要 Swift 工具链、Rust 工具链、`pkg-config` 和 librime。构建脚本默认尝试读取
旧版开发包中的 Rime 共享数据：

```sh
scripts/build-macos-dev-harness.sh
```

也可以显式指定另一份已经部署的共享数据：

```sh
FEATHER_RIME_SHARED_DATA_DIR=/absolute/path/to/rime \
  scripts/build-macos-dev-harness.sh
```

生成的应用位于：

```text
.build/macos-dev-harness/FeatherInputDevHarness.app
```

构建脚本会把共享数据复制进开发应用，不会在源目录内写入部署文件。应用的用户学习
数据固定写入：

```text
~/Library/Application Support/FeatherInputRustDev/Rime
```

该目录与正式输入法隔离。删除它只会重置开发调试壳。

## 验证和运行

不启动 GUI 的真实链路测试：

```sh
scripts/test-macos-dev-harness.sh
```

手动运行普通应用：

```sh
open .build/macos-dev-harness/FeatherInputDevHarness.app
```

点击按键捕获区域后可以输入拼音；空格、回车、退格、方向键和翻页键会发送给 Rust
核心。单击候选行会按 `(revision, candidate_id)` 选择候选。`Control-Space` 只切换
调试壳内部的直输模式，不修改系统输入法设置。

当前开发构建仍然依赖本机 Homebrew librime。消除绝对动态库依赖、通用二进制、签名
和发布打包属于后续 portable build 阶段。
