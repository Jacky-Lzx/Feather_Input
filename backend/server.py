"""Loopback-only MLX continuation worker; no user text is logged or persisted."""
import argparse
import json
import math
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def token_candidates(top, special_ids, count=5):
    candidates = []
    for token in top:
        text = token['text']
        if (token['id'] in special_ids or not text or '\ufffd' in text
                or any(ord(c) < 32 or c in '\u2028\u2029' for c in text)
                or text in [c['text'] for c in candidates]):
            continue
        candidates.append({'text': text, 'token_ids': [token['id']],
                           'token_logprobs': [token['logprob']],
                           'logprob': token['logprob'], 'score': token['logprob'],
                           'probability': token['probability']})
        if len(candidates) == count:
            break
    return candidates


class Predictor:
    def __init__(self, path):
        import mlx.core as mx
        from mlx_lm import load
        from mlx_lm.generate import generate_step
        self.mx, self.generate = mx, generate_step
        self.model, self.tokenizer = load(path)

    def predict(self, context, count=5):
        mx, tokenizer = self.mx, self.tokenizer
        # Raw continuation: no chat template, reasoning, or JSON grammar tokens.
        prompt = tokenizer.encode(context, add_special_tokens=False)
        started = time.monotonic()
        step = self.generate(mx.array(prompt), self.model, max_tokens=1)
        _, probs = next(step)
        mx.eval(probs)
        ids = mx.argsort(probs)[-max(40, count * 4):][::-1].tolist()
        top = [{'id': i, 'text': tokenizer.decode([i]), 'logprob': probs[i].item(),
                'probability': math.exp(probs[i].item())} for i in ids]
        step.close()
        special_ids = set(tokenizer.eos_token_ids) | set(getattr(tokenizer, 'all_special_ids', []))
        candidates = token_candidates(top, special_ids, count)
        return {'candidates': candidates, 'top_tokens': top,
                'score_kind': 'single next-token logprob (unmodified model distribution)',
                'elapsed_ms': round((time.monotonic() - started) * 1000)}


def serve(model_path, port):
    predictor = Predictor(model_path)
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def log_message(self, *args):
            pass

        def reply(self, status, payload):
            data = json.dumps(payload, ensure_ascii=False).encode()
            try:
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            self.reply(200 if self.path == '/health' else 404,
                       {'ready': True, 'backend': 'mlx-lm'} if self.path == '/health' else {})

        def do_POST(self):
            # Reject browser-origin requests and never expose a network listener.
            if self.path != '/continuations' or self.headers.get('Origin'):
                self.reply(403, {'error': 'unsupported request'})
                return
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 4096:
                    raise ValueError()
                payload = json.loads(self.rfile.read(size))
                context = payload['context']
                count = payload.get('count', 5)
                if type(count) is not int or not 1 <= count <= 20:
                    raise ValueError()
                if not isinstance(context, str) or not context.strip() or len(context) > 80:
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                self.reply(400, {'error': 'invalid context'})
                return
            if not lock.acquire(blocking=False):
                self.reply(503, {'error': 'busy'})
                return
            try:
                self.reply(200, predictor.predict(context, count))
            except Exception:
                self.reply(500, {'error': 'inference failed'})
            finally:
                lock.release()

    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.daemon_threads = True
    print('Feather MLX ready on loopback port', port, flush=True)
    server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True)
    parser.add_argument('--port', type=int, default=1235)
    args = parser.parse_args()
    serve(args.model, args.port)
