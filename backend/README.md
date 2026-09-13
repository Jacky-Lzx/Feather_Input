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

Rime candidate buttons display only their selection number and text. Model ranks
are shown exclusively in the companion panel; ranking and selection mapping are
unchanged. Rank metadata is never inserted into the client text.

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
conditional log probability, their sum, normalized LLM score, Rime rank prior,
and final fusion score. Settings expose LLM weight (0–100%, default 35%) and
normalization (character average, token average, or raw sum; default character).

`score = (1 - weight) * -log(original_rank) + weight * normalized_logprob`

The Rime term is a rank proxy, **not** Rime's actual probability. Weight 0 preserves
Rime order; weight 1 uses only LLM scores. The default is an initial heuristic,
not a fitted/calibrated optimum. Normalization may favor longer predictable strings;
no EOS probability is included. Ties retain original order. The exposed Rime API
does not provide consumed pinyin spans, so candidates are not claimed to cover an
equal span. Strict span grouping and cross-page retrieval remain future work.

Context is limited to 80 characters. Each request prefills it once, reuses the
first-token distribution, and deep-copies its KV cache for each multi-token
candidate. Candidate branches cannot modify each other's prefix. There is no
persistent cache or reuse across requests.

Before starting a new pinyin composition, the app reads up to 80 characters before
the current selection from the host's IMK text interface (bounded UTF-16 range).
Thus candidate scoring can resume after cursor movement or document deletion,
using the updated document rather than only locally committed text. Selected text,
text after the cursor, and the new preedit are excluded. Hosts that do not expose
surrounding text still fall back to local commit history; navigation clears that
history, so restoration is unavailable there. This does not use Accessibility or
read other applications. Legacy cached next-token mode still requires a ready
prediction before composition; it does not wait for a new request at this point.

The app immediately displays Rime's page, waits 120 ms after input, then requests
scores. A response can reorder only the unchanged page and context within 700 ms
of request start. Further input, navigation, selection, focus change, disabled
settings, or cancellation invalidates the response. Hovering either candidate
window also prevents a pending reorder. Up/down selection locks scoring for that
page. This differs from frozen next-token mode: a stationary page may update once
when scoring arrives. The side window is titled **Rime + LLM · 融合排序**; its ranks are
among the supplied candidates, not full-vocabulary token ranks. Request delay
remains visible; all per-token scores are available in the opt-in debug window.

Timeouts, busy service, invalid responses, and missing context leave Rime usable.
The 2.4 s worker budget is checked between candidates; one Metal call cannot be
interrupted. No cross-page ranking or automatic insertion is performed. Disable
this option to return to the previous cached top-k mode.

## Reproducible diagnostic evaluation

`evaluation_cases.json` contains 20 hand-written context/pinyin/target cases,
including homophone pairs. Export actual first-page Rime candidates (9 each)
using an isolated user directory, then evaluate the installed model:

```sh
scratch=$(mktemp -d /tmp/feather-eval.XXXXXX)
.build/release/EngineCheck "$PWD/dist/FeatherInput.app/Contents/Frameworks/librime.dylib" \
  "$PWD/dist/FeatherInput.app/Contents/Resources/rime" "$scratch" \
  backend/evaluation_cases.json > /tmp/feather-evaluation-candidates.json
.venv-mlx/bin/python backend/evaluate.py \
  --model "$HOME/Library/Application Support/FeatherInput/models/Qwen3-1.7B-Base-MLX-8bit" \
  --fixtures /tmp/feather-evaluation-candidates.json --output /tmp/feather-evaluation-results.json
```

Reports Top-1/Top-5 counts for original Rime, pure token/character scores, and
35% fusion, with all cases in the denominator (missing targets count as misses).
Also reports target coverage, per-request cached/uncached median and nearest-rank
P95 after a warm-up, and maximum per-token score difference. Timings exclude HTTP
and UI, run cached before uncached for each case, and are only diagnostic samples.
The set is synthetic, full-pinyin only, without personal learning; it is not a
held-out benchmark or evidence of production accuracy. No weights are tuned on it.

Recorded run: [2026-09-14 results](evaluations/2026-09-14-qwen17-fusion.json).
On these 20 cases, Rime hit 11/20 Top-1 and 18/20 Top-5; pure LLM token and
character means both hit 20/20; 35% fusion hit 19/20 and 20/20. This set therefore
does **not** demonstrate fusion outperforming pure LLM scoring. Cached median/P95
was 41.5/88 ms versus 85/109 ms without caching. BF16 computation changed some
scores (maximum absolute token log-probability difference 0.13455): first choices
agreed in 20/20 cases, full orders in 18/20. A single FP32 control case reduced the
maximum difference to 0.00000763; caching is not claimed to be bitwise equivalent.
