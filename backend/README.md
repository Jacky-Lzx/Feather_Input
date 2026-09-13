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

While Rime candidates are visible, a read-only companion panel shows the entire
frozen prediction list used for ranking, including tokens with no Rime match. Rows
are ordered by original LLM rank; spaces are displayed as ␠. It follows the main
candidate panel, moves to the left if the right edge has insufficient room, and
hides with the main panel. Long lists scroll without taking keyboard focus. No
ready prediction means no companion window for that composition.

The companion panel shows request round-trip delay in milliseconds. Timing uses a
monotonic clock around the request and response parsing, includes local transport
and inference, and is frozen with that prediction. It excludes the user's wait
before typing the next composition and is not pure model compute time.

## Candidate probability scoring (experimental)

Enable **用 MLX 给当前拼音候选打分**. It takes precedence over cached top-k ranking,
independent continuation, and legacy recommendation. Rime supplies the current
page of pinyin-compatible candidates (both full pinyin and Flypy); the model does
not interpret raw pinyin. `POST /score` accepts `context`, `preedit` (debug metadata),
and 1–9 candidate strings (up to 64 characters/tokens each).

For each candidate the worker evaluates `encode(context) + encode(candidate)`
with an explicit token boundary and teacher-forced causal logits. Only candidate
positions contribute. Responses include original candidate ID, token IDs, each
conditional log probability, their sum, and their mean. Ranking uses mean token log
probability to mitigate the raw sum's short-sequence bias; it is a heuristic that
can favor longer predictable strings, not a calibrated probability of an intended
word. Ties retain Rime order. No EOS probability is included. Context is limited to
80 characters. Each candidate currently recomputes its context without KV sharing.

The app immediately displays Rime's page, waits 120 ms after input, then requests
scores. A response can reorder only the unchanged page and context within 700 ms
of request start. Further input, navigation, selection, focus change, disabled
settings, or cancellation invalidates the response. Hovering either candidate
window also prevents a pending reorder. Up/down selection locks scoring for that
page. This differs from frozen next-token mode: a stationary page may update once
when scoring arrives. The side window is titled **LLM · 候选评分**; its ranks are
among the supplied candidates, not full-vocabulary token ranks. Request delay
remains visible; all per-token scores are available in the opt-in debug window.

Timeouts, busy service, invalid responses, and missing context leave Rime usable.
The 2.4 s worker budget is checked between candidates; one Metal call cannot be
interrupted. No cross-page ranking or automatic insertion is performed. Disable
this option to return to the previous cached top-k mode.
