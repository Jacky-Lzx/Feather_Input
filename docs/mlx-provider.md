# Rust MLX Provider

`feather-ai` 是可选模型服务与输入核心之间的第一层边界。首个实现兼容旧版 `main` 的
拼音约束生成接口，但不复制旧 Swift 输入控制器的状态管理。

## 当前范围

当前只实现 `POST http://127.0.0.1:1235/generate`：

```json
{
  "context": "落霞与",
  "input": "guwu",
  "scheme": "luna_pinyin_simp",
  "count": 3
}
```

响应示例：

```json
{
  "candidates": [{"text": "孤鹜", "score": -0.47}],
  "syllables": [["gu", "wu"]],
  "elapsed_ms": 359,
  "truncated": false
}
```

Provider 不修改 Rime 候选，也不把生成文字当作 Rime candidate ID。结果携带发起请求时的
`request_id` 和输入 `revision`，后续协调层只有在两者仍有效时才能显示或提交推荐。

## 边界与校验

- 传输固定使用 loopback IPv4，不解析主机名，也不允许配置远程地址。
- 上下文只发送最后 80 个字符；原始拼音最多 36 个 ASCII 字符。
- 只接受全拼和小鹤双拼两个明确的方案值。
- 返回候选最多 3 个、互不重复，只能包含 2–6 个汉字。
- 分数必须是有限的非正数；音节路径、文字长度和后端耗时都要通过边界检查。
- 响应最大 64 KiB，请求最大 4 KiB。
- 后端返回 `503 {"error":"busy"}` 时使用 40、60、100、160、240、300 ms 的有界退避；
  其他 HTTP 错误不会重试。

MLX 调用是阻塞操作，必须在按键主线程之外运行。即使工作线程中的网络或 Metal 操作不能
立即中断，输入、退格、翻页、模式切换或客户端变化仍会推进 revision，使迟到结果无法被
采用。后端不可用时必须静默保留 Rime 的正常输入路径。

## C ABI 接入状态

C ABI 已提供异步的 `generate_start`、`poll`、`cancel` 和释放接口，macOS 共享层也已用
`FeatherGenerationRequest` 封装句柄所有权与结果复制。请求在 Rust 工作线程中访问 1235
端口，平台层每次轮询都要提交当前 request ID 与 revision；组合变化、取消或身份不匹配
后，迟到结果不会被返回。后端失败只产生终态，不会阻断或替换 Rime 候选。

macOS 已有进程级共享的独立 AI 推荐窗，并可在候选窗预览器中验收其布局、点击和屏幕边界
定位。它最多显示三个竖排候选；InputMethodKit 控制器之间通过所有权令牌隔离，旧控制器
不能隐藏或选择新控制器的推荐窗。

推荐窗可见时，`Option + 1/2/3` 选择相应候选，`Option + Space` 选择第一个候选。这些
按键由输入法优先消费，包括欧路词典 LightPeek；推荐窗隐藏后不再拦截，快捷键会继续交给
客户端。按住快捷键产生的重复 key-down 也会被消费，直到 Option 松开，避免首次上屏后
重复事件落入客户端。

InputMethodKit 控制器尚未发起 MLX 请求，因此当前安装的输入法仍不会主动访问 1235
端口。下一阶段会把上下文读取、请求调度、取消和专用选择键接入控制器，随后再处理 MLX
后端的安装、启动与健康检查。`/score` 和 `/continuations` 仍不在当前范围内，避免在生成
候选的选择语义稳定之前改变 Rime 排序。
