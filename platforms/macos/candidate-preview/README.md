# macOS 候选窗预览器

这个 App 只编译候选窗视图和一组固定的示例候选，不链接 Rust、librime 或
InputMethodKit，也不会安装、注册或切换系统输入源。因此可以在不影响当前输入法的前提下
验收界面。

构建并启动：

```sh
scripts/build-macos-candidate-preview.sh
open -n .build/macos-candidate-preview/FeatherCandidatePreview.app
```

这里使用 `open -n` 强制 LaunchServices 启动刚构建的新实例。普通 `open` 可能在 App 被原地
重建后继续引用旧实例记录，并错误报告 `LSNoExecutableErr`。

预览器支持：

- 跟随系统、浅色和深色三种外观；
- 竖排和横排两种紧凑候选排列；
- 常规、长文本和全词候选三种内容；
- 切换高亮候选；
- 调整 14–24 的候选字号并观察窗口重新测量；
- 点击候选；
- 使用方向键、Page Up / Page Down、数字键、空格、回车和 Esc 模拟输入法操作；
- 移动或缩放主窗口，检查候选窗是否持续跟随锚点。

这里的按键只模拟候选窗状态，不经过系统 Text Input Services。真实输入、上屏以及不同
客户端中的插入点定位仍需使用客户端验收程序和已隔离安装的 `Feather Rust Dev` 输入法验证。
