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
预编辑、候选窗口和上屏。所有控制器共享一个进程级候选窗口，活跃控制器通过所有权
代理独占更新和点击回调，已失活控制器不能隐藏或修改新控制器的内容。候选窗口跟随文本
插入位置，使用系统动态颜色适配明暗模式；
点击候选使用 ABI 提供的不透明候选 ID；上下方向键逐项移动高亮，左右方向键翻页，具体
候选状态仍由 librime 处理。安装注册和真实客户端验收将在后续独立提交中完成。

紧凑候选窗中按右方向键可以展开全词候选窗。展开状态采用五列网格：
左右键切列，上下键切换行。只有当前列显示数字，数字键选择当前列对应行；空格或回车
提交当前候选。`Tab`
不参与展开或关闭，并继续交给宿主应用。`Esc` 会取消本次输入并关闭候选窗口，而不是
仅收起全词候选。
窗口先读取 40 个候选，并在继续向右到达已加载末尾时读取下一批；每一批都绑定当前
revision，输入变化后不会混用旧候选。紧凑候选窗仍可用左键返回上一页，并可用
Page Down 前往下一页。

## 中英文切换

单击右 Control，或按 `Control + Shift + Space`，可以在中文输入和英文直输之间切换。
切换会取消尚未提交的组合并关闭候选窗，同时在当前插入位置短暂显示“中文”或“英文”。
英文模式不把普通文字按键发送给 Rust 引擎，而是交还宿主应用处理。输入法菜单也提供
相同的切换命令。

默认在不同应用之间记住最近一次全局模式。底层同时支持按应用记忆、切换应用时恢复
中文和切换应用时恢复英文；后续设置界面可以直接选择这些策略，而不需要修改平台事件
处理逻辑。所有 InputMethodKit 控制器共享一个模式提示窗口，避免客户端增多时累积隐藏
面板。

## 全拼与小鹤双拼

输入法菜单可以在“全拼”和“小鹤双拼”之间切换，当前方案带有勾选标记。全拼使用
`luna_pinyin_simp`，小鹤双拼使用 `double_pinyin_flypy`；选择会持久化，并在下一次创建
输入控制器时恢复。输入方案与中英文模式互相独立，因此在英文直输状态切换方案不会
自动回到中文。

方案切换由 Rust 核心和 C ABI 原子执行：现有组合会被取消，候选 revision 随即推进，
切换前取得的不透明候选 ID 不能用于新方案。C ABI 只接受上述两个已打包 schema，不允许
平台层传入任意 schema 名称或路径。

## 设置窗口

输入法菜单中的“设置…”会打开一个进程级单例窗口，可以选择默认中文输入方案和
中英文模式记忆策略，并可将拼音每页候选设置为 1–9 个，默认 7 个。打开设置前会取消
尚未提交的组合并关闭候选窗，不会把半成品拼音写入客户端。设置会立即保存；输入方案和
每页候选数量会在返回文本客户端时通过 C ABI 同步到对应 librime session。若设置在组合
期间发生变化，则保留当前页，完成当前拼音后再应用新数量，无需重启。

文本客户端获得输入法焦点时，会在真实插入点旁显示当前“中文”或“英文”状态。默认显示
3.0 秒；设置中可以在 0.1–5.0 秒之间调整，也可以改为一直显示到开始按键或失焦。光标布局
尚未完成时会在短时间内重试；开始按键、安全输入、失焦或打开设置都会取消尚未触发的提示，
且多个 InputMethodKit 控制器仍共享同一个模式提示浮层。

构建脚本会递归收集 librime 的非系统动态库依赖到 `Contents/Frameworks`，并将加载路径
改为 `@rpath`，同时把每项依赖的许可证复制到 `Resources/ThirdPartyLicenses`。生成的
bundle 不再要求目标 Mac 安装 Homebrew；当前产物仍只包含构建主机的单一 CPU 架构，
正式发布签名属于后续阶段。

同时安装 arm64 与 x86_64 Rust target 和对应架构的 librime 后，可以构建 Universal
输入法：

```sh
scripts/build-macos-universal.sh input-method
```

默认从 `/opt/homebrew/opt/librime` 读取 arm64 依赖，从
`/usr/local/opt/librime` 读取 x86_64 依赖。非默认安装位置可以分别通过
`FEATHER_RIME_ARM64_PREFIX` 和 `FEATHER_RIME_X86_64_PREFIX` 指定。构建器先生成两个
完整的单架构 bundle，再合并其中的所有 Mach-O；缺少 target、依赖架构错误或两个
bundle 的文件集合不一致都会中止构建。

## 发布构建

正式包使用 `FeatherInput.app`、稳定 Bundle ID
`im.feather.inputmethod.FeatherInput` 和独立的
`~/Library/Application Support/FeatherInput/Rime` 用户数据目录。生成
本地 ad-hoc 签名的 Universal 验证归档：

```sh
FEATHER_RELEASE_VERSION=0.1.0 \
FEATHER_RELEASE_BUILD=1 \
scripts/package-macos-release.sh
```

该命令生成名称带 `-local` 的 ZIP，不能作为已公证版本公开分发。正式签名与公证需要
先用 `xcrun notarytool store-credentials` 保存钥匙串配置，然后运行：

```sh
FEATHER_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
FEATHER_NOTARY_PROFILE='feather-notary' \
scripts/package-macos-release.sh --notarize
```

脚本会按从内到外的顺序使用 hardened runtime 和时间戳重新签名，验证动态库闭包，
提交公证、staple ticket、执行 Gatekeeper 检查，并在 stapling 后重新生成最终 ZIP。
每个归档旁边都会生成 `.sha256` 校验文件。发布脚本只生成归档，不会安装或覆盖当前
正式输入法。

## 正式版安装与升级

正式安装脚本默认只接受包含 arm64、x86_64、有效 Developer ID Application 签名、
stapled 公证票据并通过 Gatekeeper 的 `FeatherInput.app`：

```sh
scripts/install-macos-release.sh /path/to/FeatherInput.app
```

脚本会在 `~/Library/Input Methods` 内创建同卷暂存目录，验证暂存副本后才停止旧进程；
已有目标必须是相同正式 Bundle ID 和可执行文件名。旧 bundle 会先移动到同卷备份目录，
新 bundle 就位并通过 Text Input Sources 注册验证后才删除备份。任何一步失败都会删除
新 bundle、恢复并重新注册旧 bundle。用户数据始终保留在
`~/Library/Application Support/FeatherInput/Rime`，不会把其他输入法可能使用的
`~/Library/Rime` 自动合并进来。

隔离验收可以显式允许 ad-hoc 包，并把安装根目录指向临时目录，同时跳过系统注册：

```sh
FEATHER_INSTALL_ROOT=/private/tmp/feather-install-check \
FEATHER_SKIP_INPUT_SOURCE_REGISTRATION=true \
scripts/install-macos-release.sh --allow-local
```

安装器按 `CFBundleShortVersionString` 的数字段比较版本；版本相同时再比较数字
`CFBundleVersion`。默认拒绝降级，确需回退时必须显式添加 `--allow-downgrade`。例如当前
正式版是 `0.1.0 (60)`，构建号为 1 的本地验证包不会覆盖它。

正式卸载默认保留用户词库和配置：

```sh
scripts/uninstall-macos-release.sh
```

只有显式指定以下参数才会同时清除
`~/Library/Application Support/FeatherInput`：

```sh
scripts/uninstall-macos-release.sh --purge-user-data
```

卸载器会先确认目标身份并禁用输入源，再把 app 和可选用户数据移动到各自文件系统内的
临时移除目录；全部移动成功后才真正删除。中途失败会恢复 app、用户数据和原启用状态。

不安装 bundle 的进程内 IMK 客户端测试：

```sh
scripts/test-macos-input-method.sh
```

该测试不会注册输入源，也不会写入正式或开发输入法的用户数据目录。

只验收候选窗视觉、不启动输入法引擎时，可以运行独立预览器：

```sh
scripts/build-macos-candidate-preview.sh
open -n .build/macos-candidate-preview/FeatherCandidatePreview.app
```

它使用固定示例数据，可切换明暗外观、长文本和多候选场景；不会链接 Rust、librime 或
InputMethodKit，也不会安装、注册或切换输入源。预览窗口获得焦点后会模拟正式输入法的
候选快捷键：紧凑窗右键展开，左键、Page Up 和 Page Down 翻页；展开后方向键移动、
数字键或空格/回车模拟选择。
`Esc` 模拟取消本次输入并关闭候选窗，`Tab` 不处理。状态栏会显示每次模拟操作；取消后
重新选择任一“内容”场景即可恢复示例组合。

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

1. 输入 `shijie`，确认出现预编辑和“世界”候选；
2. 在紧凑候选窗中使用上下键改变高亮，使用左键或 Page Up / Page Down 翻页；
3. 按右方向键展开全词候选，确认四个方向键可以跨行、跨列移动，且只有当前列显示数字；
4. 用数字键选择当前列候选，分别用空格、回车和鼠标点击完成上屏；
5. 在全词候选窗中按 Tab，确认客户端收到 Tab；按 Esc，确认组合取消且没有文字上屏；
6. 输入 `shi` 并持续向右移动，确认越过第 40 项后仍能继续加载候选；
7. 在终端或代码编辑器中确认 Command、Control 和 Option 快捷键仍由客户端接收；
8. 在密码框中确认输入法不消费按键，也不显示候选窗口；
9. 在浅色和深色外观下确认候选文字、选中状态和窗口边界清晰可见；
10. 运行状态脚本确认正式 Bundle ID 和正式用户数据目录没有被修改。

完成后可切回原输入源并运行卸载脚本。进程内 smoke test、bundle 构建成功和注册成功都
不能替代以上真实客户端验收。
