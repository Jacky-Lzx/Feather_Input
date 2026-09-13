# Feather Input

macOS 原生中文输入法，Swift / InputMethodKit 前端与 librime 引擎。支持全拼、小鹤双拼、简体输出、用户词频学习、原生候选窗口和设置窗口。

## 构建

需要 Xcode 命令行工具、Homebrew、Python 3 和 Git：

```sh
brew install librime
scripts/build-app.sh
swift test
```

产物为 `dist/FeatherInput.app`。脚本下载固定版本的官方 Rime 方案与词频数据，打包动态库及 OpenCC 数据，预编译词库，并执行两种方案的真实输入测试。首次构建需要网络。当前验证环境为 Apple Silicon / macOS 26；Swift 源码最低目标为 macOS 13，但 Homebrew 动态库可能要求更新系统，当前生成的包最低为 macOS 26，仅含本机构建的 arm64 架构。打包脚本会按依赖的实际最低版本设置应用元数据。

## 安装与使用

```sh
scripts/install.sh
```

安装脚本会注册、启用输入源并校验系统枚举结果。安装成功后，从菜单栏输入法菜单选择 Feather Input。也可在系统设置 → 键盘 → 文字输入 → 编辑中查看。若系统设置已打开，请关闭后重新打开以刷新列表。输入法使用系统输入接口，无需辅助功能权限。

- 系统输入法菜单：选择全拼、小鹤双拼，或打开设置调整候选字号。
- `Control + Shift + Space`：中英文切换，也可使用菜单。
- `1`–`5` 选词，空格上屏，Page Up / Page Down 翻页，Esc 取消。
- 小鹤双拼使用 `nihc` 输入“你好”；不包含小鹤音形。
- 数据位置：`~/Library/Application Support/FeatherInput`；方案和字号保存在应用偏好设置中。

更新前切换到其他输入法并退出 FeatherInput 进程，将旧应用移开后重新安装。卸载时先在系统设置中移除输入源，再删除 `~/Library/Input Methods/FeatherInput.app`。用户词库不会被自动删除。

当前为开发预览版，使用本机 ad-hoc 签名；正式分发还需 Developer ID 签名、公证及更多应用兼容性验证。输入时的点击选词、模糊音、词库管理界面暂未实现。

见 [验证记录](docs/verification.md) 和 [第三方来源](THIRD_PARTY_NOTICES.md)。
