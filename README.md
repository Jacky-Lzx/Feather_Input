# Feather Input

Feather Input 是一个从零开始设计的跨平台输入法项目。

`main-human` 是人工审核后的稳定主线。新实现必须从独立实现分支提交，经人工审核后
才能进入该分支。旧版 Swift/InputMethodKit 项目不属于这条新历史。

项目将采用平台适配层、跨平台输入核心和可选模型服务相互分离的架构。输入核心以
Rust 编写，并通过稳定的 C ABI 服务于 macOS、Windows 和 Linux 平台前端。

## 开发检查

首次克隆后运行：

```sh
scripts/install-git-hooks.sh
```

启用后，每次提交都会自动格式化 Rust 代码，并运行格式检查和严格 Clippy。
如果格式化产生修改，提交会中止，以便先审核并重新暂存格式化结果。

也可以手动运行：

```sh
scripts/format-rust.sh
scripts/check-rust.sh
```
