import math
import unittest
import mlx.core as mx
from server import Predictor

class ScoringTests(unittest.TestCase):
    def test_scores_only_candidate_tokens_at_correct_positions(self):
        class Tokenizer:
            def encode(self, text, **kwargs):
                return {'上文': [0, 1], '词': [2], '词语': [2, 3]}[text]
        class Model:
            def __init__(self): self.seen = []
            def __call__(self, inputs):
                ids = inputs.tolist()[0]
                self.seen.append(ids)
                return mx.array([[[0., 0., 0., 0.], [0., 0., 2., 0.], [0., 0., 0., 3.]][:len(ids)]])
        p = Predictor.__new__(Predictor)
        p.mx, p.tokenizer, p.model = mx, Tokenizer(), Model()
        results = {r['text']: r for r in p.score('上文', ['词', '词语'], weight=1, normalization='token', reuse_context=False)['candidates']}
        first = 2 - math.log(math.exp(2) + 3)
        second = 3 - math.log(math.exp(3) + 3)
        self.assertAlmostEqual(results['词']['score'], first, places=5)
        self.assertAlmostEqual(results['词语']['logprob'], first + second, places=5)
        self.assertAlmostEqual(results['词语']['score'], (first + second) / 2, places=5)
        self.assertEqual(p.model.seen, [[0, 1], [0, 1, 2]])

    def test_cache_branch_isolation_and_fusion_endpoints(self):
        class Tokenizer:
            def encode(self, text, **kwargs):
                return {'上下文': [0, 1], '甲': [2, 3], '乙': [3, 2], '丙': [1]}[text]
        class Model:
            def __init__(self): self.seen = []
            def make_cache(self): return [{'history': []}]
            def __call__(self, inputs, cache=None):
                history = cache[0]['history'] if cache is not None else []
                self.seen.append((list(history), inputs.tolist()[0]))
                rows = []
                for token in inputs.tolist()[0]:
                    history.append(token)
                    rows.append([float((sum(history) + i) % 5) for i in range(4)])
                return mx.array([rows])
        p = Predictor.__new__(Predictor)
        p.mx, p.tokenizer, p.model = mx, Tokenizer(), Model()
        cached = p.score('上下文', ['甲', '乙', '丙'], weight=0)
        self.assertEqual([r['text'] for r in cached['candidates']], ['甲', '乙', '丙'])
        self.assertEqual(p.model.seen, [([], [0, 1]), ([0, 1], [2]), ([0, 1], [3])])
        reference = p.score('上下文', ['甲', '乙', '丙'], weight=0, reuse_context=False)
        for a, b in zip(cached['candidates'], reference['candidates']):
            for x, y in zip(a['token_logprobs'], b['token_logprobs']):
                self.assertAlmostEqual(x, y, places=6)
        for normalization in ['character', 'token', 'none']:
            pure = p.score('上下文', ['甲', '乙', '丙'], weight=1, normalization=normalization)
            for row in pure['candidates']:
                divisor = len(row['token_ids']) if normalization == 'token' else 1
                self.assertAlmostEqual(row['score'], row['logprob'] / divisor)
        mixed = p.score('上下文', ['甲', '乙', '丙'])
        for row in mixed['candidates']:
            self.assertAlmostEqual(row['score'], -.65 * math.log(row['id'] + 1) + .35 * row['lm_score'])
