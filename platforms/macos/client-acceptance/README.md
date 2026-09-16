# macOS 真实客户端验收应用

该应用是普通 AppKit 文本客户端，不链接 Feather Swift bridge、Rust 核心或 librime。按键
只有经过 macOS Text Input Services 和已安装的 InputMethodKit bundle 后，才会在文本框
中形成预编辑或上屏文本。

运行：

```sh
scripts/run-macos-client-acceptance.sh
```

运行脚本只在检测到 `FeatherInputRustDev.app` 已安装且 Hans 输入模式已启用时启动应用，
不会自动切换当前输入源。应用中的检查框只是人工记录，不会把观察结果伪装成自动测试。

该应用能够稳定复现普通 AppKit 文本框、密码框和快捷键放行行为，但仍不能代替
TextEdit、终端、浏览器和代码编辑器的最终验收。
