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

Smoke Test 会同时创建两个 Swift/ABI/Rime 会话，分别保留组合状态；关闭第一个会话后，
第二个仍须能够提交文字。

手动运行普通应用：

```sh
open .build/macos-dev-harness/FeatherInputDevHarness.app
```

点击按键捕获区域后可以输入拼音；空格、回车、退格、方向键和翻页键会发送给 Rust
核心。单击候选行会按 `(revision, candidate_id)` 选择候选。`Control-Space` 只切换
调试壳内部的直输模式，不修改系统输入法设置。

调试壳要求 Feather C ABI v2 的全部基础能力。Rust 返回的结构化状态码和诊断消息会
由 Swift 桥接层转换成可读错误；退出时先关闭 librime 会话，再释放 ABI handle。

开发构建会把 librime 的非系统动态库闭包复制到 app，并重写为 `@rpath`，运行时不再
依赖目标机器的 Homebrew。当前产物仍只包含构建主机的单一 CPU 架构；通用二进制、
正式签名和发布打包属于后续 portable build 阶段。
