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
        results = {r['text']: r for r in p.score('上文', ['词', '词语'])['candidates']}
        first = 2 - math.log(math.exp(2) + 3)
        second = 3 - math.log(math.exp(3) + 3)
        self.assertAlmostEqual(results['词']['score'], first, places=5)
        self.assertAlmostEqual(results['词语']['logprob'], first + second, places=5)
        self.assertAlmostEqual(results['词语']['score'], (first + second) / 2, places=5)
        self.assertEqual(p.model.seen, [[0, 1], [0, 1, 2]])
