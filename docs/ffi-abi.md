# Feather C ABI v2

## 设计目标

C ABI 是平台适配层与 Rust 输入核心之间唯一稳定的二进制边界。它不暴露 Rust、
Swift、C++、AppKit 或 librime 对象，并把成功结果、失败状态和资源所有权明确分开。

当前 ABI 版本是 `2`。调用方必须在创建会话前检查
`feather_ime_abi_version()`，并通过 `feather_ime_capabilities()` 确认所需能力。
版本不匹配时不得继续调用其他接口。

## 返回值与错误

除查询和释放函数外，每个接口都返回 `FeatherStatus`：

- `FEATHER_STATUS_OK` 表示成功；
- 非零状态表示参数、线程、生命周期、引擎或内部错误；
- 若调用方提供 `out_error`，失败时会得到包含状态码和 UTF-8 消息的
  `FeatherError`；
- 调用前必须把 `out_error` 指向的槽位初始化为 `NULL`，已有错误必须先释放；
- `FeatherError` 必须且只能由 `feather_error_free()` 释放；
- 成功时输出错误指针为 `NULL`，失败时普通输出指针为 `NULL`；
- Rust panic 会在 ABI 边界被转换成 `FEATHER_STATUS_INTERNAL_ERROR`，不会穿过 C
  调用栈。

`FEATHER_STATUS_ABI_MISMATCH` 保留给平台包装层表达版本协商失败；当前 Rust 动态库
不会自行返回该状态，因为版本检查发生在创建会话之前。

## 会话生命周期

推荐顺序如下：

```text
检查版本和能力
       ↓
new / new_rime
       ↓
activate → key / select / set_mode
             ↘ candidate_slice
       ↓
deactivate（可选）
       ↓
close（幂等）
       ↓
free（仅一次）
```

`feather_ime_close()` 会关闭引擎资源，但保留 handle，以便重复关闭能够安全成功。
关闭后的业务调用返回 `FEATHER_STATUS_SESSION_CLOSED`。
`feather_ime_free()` 只释放 handle，调用后指针立即失效；重复释放或继续使用属于调用方
错误。

创建、业务调用、`close` 和 `free` 必须在创建会话的同一线程执行。能够返回状态的
接口会把跨线程调用报告为 `FEATHER_STATUS_WRONG_THREAD`。`free` 没有错误返回值，因此
调用方必须在进入它之前保证线程正确。

多个 `new_rime` 会话可以同时存在。使用相同规范化共享数据目录和用户数据目录的会话
在进程内共享一个 librime runtime，但组合状态、候选和 revision 由各自的 Rime
session 独立持有。关闭一个 ABI session 不会关闭其他 session。只要已有会话仍然
存活，使用不同数据目录创建会话就会返回引擎初始化错误。

## 响应所有权

每次成功的业务调用都会返回独立的 `FeatherResponse`：

- 调用方使用完毕后必须调用 `feather_ime_response_free()`；
- `commit`、`preedit`、候选数组和候选文字都由响应对象拥有；
- 上述指针只在响应被释放前有效；
- 响应释放不影响 session，也不影响其他响应；
- 候选选择使用 `(revision, value)` 不透明身份，不能用显示文字或数组下标替代。

`feather_ime_candidate_slice()` 用同一个 revision 按 `offset`、`limit` 分批读取完整
候选列表。`limit` 必须在 `1...256` 内。成功返回的 `FeatherCandidateSlice` 及其候选
文字由该对象独立拥有，必须用 `feather_ime_candidate_slice_free()` 释放。组合状态
变化后继续使用旧 revision 会返回 `FEATHER_STATUS_STALE_REVISION`，调用方应丢弃旧批次，
而不是把新旧候选拼接起来。

所有传入字符串和按键文字均使用 UTF-8。`cursor_utf8` 也是 UTF-8 字节偏移，平台层
负责转换成原生文本 API 所要求的坐标单位。

## 异步 MLX 请求

`feather_ai_generate_start()` 创建一个独立的异步请求，并立即返回
`FeatherAiRequest`。平台层不得在按键处理路径中等待模型；应按下面的顺序管理请求：

```text
generate_start
      ↓
poll(current request_id, current revision) ──→ READY + FeatherAiResult
      │                                             ↓
      ├─ PENDING                              result_free
      ├─ FAILED
      ├─ CANCELLED
      └─ STALE
      ↓
request_free
```

每次 `poll` 都必须传入当前组合的 `request_id` 和 `revision`。任一值已经变化时，请求会
永久进入 `FEATHER_AI_REQUEST_STALE`，迟到的生成结果不会重新变为可用。显式取消后则永久
进入 `FEATHER_AI_REQUEST_CANCELLED`。底层网络或 Metal 工作不保证能够立即停止，但其结果
不会再被返回给平台层。

`READY` 是唯一会返回 `FeatherAiResult` 的状态；结果及其中的候选文字必须由
`feather_ai_result_free()` 释放。`FAILED`、`CANCELLED` 和 `STALE` 都不返回结果，平台层应
静默保留 Rime 候选，不改变当前组合。`FeatherAiRequest` 的 `poll`、`cancel` 和 `free`
必须在创建它的同一线程执行。

候选评分使用独立的 `feather_ai_score_start()` 和 `FeatherAiScoringRequest`，避免改变已有
生成结构的 ABI 布局。输入候选由不透明 `value` 和 UTF-8 文字组成；结果返回同一个
`value`、纯模型 `lm_score` 和最终融合 `score`。评分请求使用独立的 poll、cancel、free
函数，并遵循相同的 request ID、revision、线程所有权和终态规则。

上屏续写使用 `feather_ai_continuation_start()` 创建普通 `FeatherAiRequest`，并复用生成
请求的 poll、cancel、free 与 `FeatherAiResult`。独立入口固定调用 `/continuations`，平台
无需构造虚假的拼音输入或方案值。

## 能力位

ABI v2 当前公开以下能力：

- `FEATHER_CAP_RIME_ENGINE`：可以创建 librime 会话；
- `FEATHER_CAP_OPAQUE_CANDIDATE_ID`：候选使用 revision 与不透明 ID；
- `FEATHER_CAP_EXPLICIT_CLOSE`：支持显式、幂等关闭；
- `FEATHER_CAP_STRUCTURED_ERROR`：支持结构化状态和错误对象；
- `FEATHER_CAP_MULTI_SESSION`：相同数据目录的 Rime 会话可以重叠存活并相互隔离。
- `FEATHER_CAP_CANDIDATE_SLICES`：支持按 revision 分批读取完整候选列表。
- `FEATHER_CAP_SCHEMA_SELECTION`：支持在现有会话内切换已允许的输入方案；
- `FEATHER_CAP_PAGE_SIZE`：支持将引擎的真实候选页大小设置为 1–9。
- `FEATHER_CAP_ENGLISH_CANDIDATE_MINIMUM`：支持将混合英文候选的最少输入长度设置为 1–12。
- `FEATHER_CAP_ASYNC_MLX_GENERATION`：支持带 request ID 与 revision 校验的异步 MLX
  生成请求。
- `FEATHER_CAP_MLX_BACKEND_STATUS`：支持有界的本机 MLX 健康检查。
- `FEATHER_CAP_ASYNC_MLX_SCORING`：支持保留 Rime 不透明候选 ID 的异步 MLX 评分请求。
- `FEATHER_CAP_ASYNC_MLX_CONTINUATION`：支持上屏后异步 MLX 续写请求。

平台层只应要求自身实际依赖的能力。新增可选能力时增加新的位，不改变已有位的含义。

## 兼容性规则

- 破坏函数签名、字段含义、枚举值或所有权规则时必须提升 ABI 版本；
- 同一 ABI 版本内不重排或删除公开结构字段；
- 跨 ABI 传递的整数宽度使用 `<stdint.h>` 类型；
- C 头文件必须同时通过 C11 和 C++17 语法检查；
- Swift Harness 是当前首个消费者，但接口设计不得依赖 Swift importer 的特有行为。
