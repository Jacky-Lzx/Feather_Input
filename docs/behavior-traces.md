# 输入法行为 Trace

行为 Trace 使用平台无关的 JSON 描述输入事件和语义断言。它用于约束 Feather 核心、
librime 适配器和未来原生 Rust 引擎，而不是模拟 AppKit、InputMethodKit 或候选窗口。

## 设计原则

- JSON 不保存 librime 候选索引或引擎内部对象。
- `select_candidate` 按候选文字和可选的 `occurrence` 查找当前候选，再使用其不透明
  ID 选择；文字只用于定位 Trace 目标，不会作为选择身份发送给核心。
- `save_candidate` 保存当时的 `(revision, engine_id)`；
  `select_saved_candidate` 可以验证旧 revision 被拒绝。
- 每一步自动检查候选 revision、候选 ID 唯一性、UTF-8 光标边界和高亮范围。
- 跨引擎场景比较用户可见语义，不要求不同引擎产生相同 revision 数字。

## 示例

```json
{
  "name": "输入完整拼音并按稳定候选身份提交",
  "steps": [
    { "action": "activate" },
    {
      "action": "text",
      "value": "nihao",
      "expect": { "candidates_contain": ["你好"] }
    },
    {
      "action": "select_candidate",
      "text": "你好",
      "expect": { "commit": "你好", "preedit": "" }
    }
  ]
}
```

支持的动作包括：

- `activate`、`deactivate`；
- `text`；
- `key`：退格、删除、空格、回车、Escape、方向键、翻页键和模式切换；
- `set_mode`；
- `save_candidate`；
- `select_candidate`、`select_saved_candidate`；
- `assert`。

断言可以检查 handled、激活状态、模式、提交、预编辑、UTF-8 光标、候选集合、候选
数量和高亮候选。`no_commit` 用来明确要求某一步不得产生提交。
同名候选默认选择第一个；`occurrence` 从 0 开始，用于指定第几个同名候选。

## 运行

默认测试使用纯 Rust 参考词典，不需要外部数据：

```sh
cargo test --manifest-path rust/Cargo.toml --workspace
```

使用真实 librime 和已经部署的共享数据：

```sh
FEATHER_RIME_SHARED_DATA_DIR=/absolute/path/to/rime \
  scripts/test-rime-traces.sh
```

脚本不会读取正式输入法或 Harness 的用户词库。每个场景使用一个新的临时用户目录，
场景完成且 librime runtime 释放后再删除该目录。

测试不会加入 pre-commit。提交钩子仍然只运行格式化和静态代码检查。

## 添加场景

能够在多个引擎上表达的行为放在 `rust/traces/common`。依赖参考引擎固定词典或其他
实现细节的场景放入对应引擎目录。新增字段时保持 JSON 严格解析；拼写错误和未知字段
必须直接失败，不能被静默忽略。
