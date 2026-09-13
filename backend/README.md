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

Select **MLX 概率候选** as the continuation backend in Feather settings and enable
**上屏后 AI 短语续写**. Candidate recommendation remains a separate LM Studio option.
The MLX test button uses synthetic text. Enable debug mode before a request to
inspect context, the top 10 next tokens and their log probabilities/probabilities,
and up to five continuation candidates. Clicking a candidate inserts that text;
new input cancels the UI request and stale responses are discarded.

The algorithm reads the unmodified model distribution from `generate_step`,
branches on high-probability first tokens, then greedily extends each branch.
Candidates rank by **mean token log probability**, not calibrated phrase
probability. This is bounded first-token branching, not exhaustive beam search
and does not guarantee the globally best phrases. Token probabilities are
approximate due to model quantization/numerical precision. Top 10 need not sum to
one. Raw continuation has no chat/JSON template and can be imperfect with chat
models. No pinyin constraint or MLX Swift migration is implemented in this stage.

Each request has an approximately 2.4-second generation budget checked between
tokens, up to 10 additional tokens per branch, and at most 24 characters per
candidate. In-flight Metal work cannot be interrupted mid-step. A busy worker
rejects requests instead of queuing them. The app times out after 3 seconds.
A disconnected client can leave up to the remaining generation budget running.
No persistent KV cache reuse between requests yet. Cold model load happens before
listening. Backend loss never blocks Rime keyboard handling.

Health: `GET /health`. Prediction: `POST /continuations` with a JSON `context`
string of 1–80 characters. Browser-origin requests are rejected. The loopback
endpoint is available to other local processes; it is not an authentication boundary.
