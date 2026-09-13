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
inspect context, the top 10 next tokens and their log probabilities/probabilities,
and up to five continuation candidates. Clicking a candidate inserts that text;
new input cancels the UI request and stale responses are discarded.

The algorithm reads the unmodified next-token distribution from one
`generate_step(..., max_tokens=1)` call. It does not extend branches, generate
phrases, trim whitespace, or remove repeated context. Up to five unique displayable
tokens from the raw top ten are shown in probability order, including punctuation
and spaces. Space is displayed as ␠ in the candidate label but inserted unchanged.
Special tokens, control characters and incomplete Unicode fragments are excluded
from selectable candidates; raw top-ten values remain visible in debug output.

Each candidate has exactly one token ID and its real log probability. Probabilities
are approximate due to quantization/numerical precision; top ten need not sum to
one. No pinyin constraint or MLX Swift migration is implemented. Raw continuation
can be imperfect with chat models; the output is not forced to be a comma.

In-flight Metal work cannot be interrupted mid-step. A busy worker rejects requests
instead of queuing them. The app times out after 3 seconds and discards stale
responses. No persistent KV cache reuse between requests yet. Cold model load
happens before listening. Backend loss never blocks Rime keyboard handling.

Health: `GET /health`. Prediction: `POST /continuations` with a JSON `context`
string of 1–80 characters. Browser-origin requests are rejected. The loopback
endpoint is available to other local processes; it is not an authentication boundary.
