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
InputMethodKit，也不会安装、注册或切换输入源。

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
