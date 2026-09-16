# macOS InputMethodKit 开发输入法

这个目录包含 Rust 架构的第一个真实操作系统适配层。它使用 InputMethodKit 接收按键，
通过 Feather C ABI 驱动 Rust 核心和 librime，再把预编辑与提交文字写回 macOS 文本
客户端。

## 隔离边界

- Bundle ID 固定为 `im.feather.inputmethod.rustdev.FeatherInput`；
- 显示名称为 `Feather Input Rust Dev`；
- 用户数据写入 `~/Library/Application Support/FeatherInputRustDev/Rime`；
- 构建脚本只生成并签名 bundle，不注册、不安装，也不切换系统输入源；
- 它不会覆盖现有 `im.feather.inputmethod.FeatherInput`。

## 构建

```sh
scripts/build-macos-input-method.sh
```

输出位于：

```text
.build/macos-input-method/FeatherInputRustDev.app
```

当前阶段实现每个 IMK 客户端独立 Feather/Rime session、快捷键放行、安全输入绕过、
预编辑、候选窗口和上屏。候选窗口跟随文本插入位置，使用系统动态颜色适配明暗模式；
点击候选使用 ABI 提供的不透明候选 ID；上下方向键逐项移动高亮，左右方向键翻页，具体
候选状态仍由 librime 处理。安装注册和真实客户端验收将在后续独立提交中完成。

不安装 bundle 的进程内 IMK 客户端测试：

```sh
scripts/test-macos-input-method.sh
```

该测试不会注册输入源，也不会写入正式或开发输入法的用户数据目录。

## 安装生命周期

开发输入法使用固定目标 `~/Library/Input Methods/FeatherInputRustDev.app`。安装脚本会先
重新构建、校验签名和 Bundle ID，再替换该精确目标，并通过
`TISRegisterInputSource` 通知系统刷新输入源缓存：

```sh
scripts/install-macos-input-method.sh
scripts/status-macos-input-method.sh
```

注册后开发输入模式会进入可选择状态，但脚本不会调用 `TISSelectInputSource`，因此不会
切换当前输入源。可以直接从菜单栏输入法菜单选择“Feather Rust Dev”。

如果升级旧安装后仍未显示，可以显式重新注册并启用它：

```sh
scripts/enable-macos-input-method.sh
```

该脚本只调用 `TISEnableInputSource`，不会调用 `TISSelectInputSource`，因此不会切换当前
输入源。启用后可从菜单栏输入法菜单选择“Feather Rust Dev”。

卸载时只会禁用并删除开发 Bundle ID 对应的 bundle，不删除用户词库，也不会触碰
`im.feather.inputmethod.FeatherInput`：

```sh
scripts/uninstall-macos-input-method.sh
```

所有会覆盖或删除 bundle 的路径都会先读取目标 `Info.plist`，Bundle ID 不匹配时立即
停止。

## 真实客户端验收

安装并启用后，从菜单栏选择“Feather Rust Dev”，只在验收期间切换到该输入源。至少
检查以下行为：

```sh
scripts/run-macos-client-acceptance.sh
```

1. 在 TextEdit 输入 `shijie`，确认出现预编辑和“世界”候选；
2. 使用上下键改变高亮，使用翻页键切换候选页；
3. 分别用空格和鼠标点击候选完成上屏；
4. 在终端或代码编辑器中确认 Command、Control 和 Option 快捷键仍由客户端接收；
5. 在密码框中确认输入法不消费按键，也不显示候选窗口；
6. 在浅色和深色外观下确认候选文字、选中状态和窗口边界清晰可见；
7. 运行状态脚本确认正式 Bundle ID 和正式用户数据目录没有被修改。

完成后可切回原输入源并运行卸载脚本。进程内 smoke test、bundle 构建成功和注册成功都
不能替代以上真实客户端验收。
