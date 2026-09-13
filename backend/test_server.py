import unittest
from server import token_candidates

class TokenTests(unittest.TestCase):
    def test_exact_single_tokens_preserve_rank_and_punctuation(self):
        tokens = [{'id': i, 'text': t, 'logprob': -float(i+1), 'probability': 0.1}
                  for i, t in enumerate(['，', ' ', '你好', ' world', '<'])]
        result = token_candidates(tokens, set())
        self.assertEqual([r['text'] for r in result], [t['text'] for t in tokens])
        self.assertEqual([r['token_ids'] for r in result], [[i] for i in range(5)])

    def test_special_control_and_incomplete_bytes_are_skipped(self):
        tokens = [{'id': i, 'text': t, 'logprob': -1, 'probability': 0.1}
                  for i, t in enumerate(['<eos>', '\n', '\ufffd', '，', '，', '。'])]
        self.assertEqual([r['text'] for r in token_candidates(tokens, {0})], ['，', '。'])

    def test_configured_candidate_count(self):
        tokens = [{'id': i, 'text': str(i), 'logprob': -float(i+1), 'probability': 0.01} for i in range(30)]
        for count in [1, 9, 20]:
            self.assertEqual(len(token_candidates(tokens, set(), count)), count)

if __name__ == '__main__':
    unittest.main()
