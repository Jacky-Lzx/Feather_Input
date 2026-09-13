# Feather MLX worker (prototype)

Apple Silicon only. Model stays in a separate process; HTTP listens only on
127.0.0.1:1235. No API key is required. No input text is logged or persisted.

Setup from the repository root:

```sh
uv venv .venv-mlx
uv pip install --python .venv-mlx/bin/python -r backend/requirements.txt
scripts/start-mlx.sh /absolute/path/to/MLX-model
```

For login startup instead of a foreground process:

```sh
python3 scripts/install-mlx-agent.py /absolute/path/to/MLX-model
```

The launch agent points to this checkout and virtual environment. Keep both in
place. Uninstall with `launchctl bootout gui/$(id -u)/im.feather.mlx-worker`, then
remove `~/Library/LaunchAgents/im.feather.mlx-worker.plist`.

Select **MLX 下一 token** as the continuation backend in Feather settings and enable
**上屏后 AI 预测**. Candidate recommendation remains a separate LM Studio option.
The MLX test button uses synthetic text. Enable debug mode before a request to
inspect context, the top next tokens and their log probabilities/probabilities,
and the configured number of token candidates. Clicking a candidate inserts that text;
new input cancels the UI request and stale responses are discarded.

The algorithm reads the unmodified next-token distribution from one
`generate_step(..., max_tokens=1)` call. It does not extend branches, generate
phrases, trim whitespace, or remove repeated context. The configured 1–20 unique displayable
tokens from a larger raw probability pool are shown in probability order, including punctuation
and spaces. Space is displayed as ␠ in the candidate label but inserted unchanged.
Special tokens, control characters and incomplete Unicode fragments are excluded
from selectable candidates; raw probability values remain visible in debug output.

Each candidate has exactly one token ID and its real log probability. Probabilities
are approximate due to quantization/numerical precision; top ten need not sum to
one. No pinyin constraint or MLX Swift migration is implemented. Raw continuation
can be imperfect with chat models; the output is not forced to be a comma.

In-flight Metal work cannot be interrupted mid-step. A busy worker rejects requests
instead of queuing them. The app times out after 3 seconds and discards stale
responses. No persistent KV cache reuse between requests yet. Cold model load
happens before listening. Backend loss never blocks Rime keyboard handling.

Health: `GET /health`. Prediction: `POST /continuations` with a JSON `context`
string of 1–80 characters and optional integer `count` (1–20, default 5). Browser-origin requests are rejected. The loopback
endpoint is available to other local processes; it is not an authentication boundary.

## Rime candidate ranking

Enable **用 MLX 下一 token 给拼音候选排序** in Feather settings. This takes
precedence over the separate prediction popup and legacy LM Studio recommendation.
After a commit the app immediately requests top-k tokens in the background. At the
start of the next lowercase-pinyin composition it freezes the ready cache (or an
empty cache). Later replies cannot move the current candidates. Predictions are
scoped to the active input context; input source/focus changes invalidate them.

Within each Rime page, exact token matches move first in model probability order;
unmatched entries and equal matches retain Rime order. No prefix/substring match,
new candidate insertion, or cross-page promotion. Space, digits and clicks map back
to original Rime indices; up/down selects within the reordered page. Page Up/Down
retains Rime paging. There is no inference wait in the keyboard handler.

Matched Rime entries display `LLM #N`, where N is the one-based rank in the raw
model token list (including filtered special tokens), not the displayed candidate
number. The label is UI metadata and is never inserted into the client text.
