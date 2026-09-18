import unittest
from pinyin_generation import Pronunciations, TokenGrammar, flypy_code

class PinyinTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.readings = Pronunciations()

    def test_segmentation_and_flypy(self):
        p = self.readings
        self.assertIn(('gu', 'wu'), p.parse('guwu', 'luna_pinyin_simp'))
        self.assertIn(('xi', 'an'), p.parse("xi'an", 'luna_pinyin_simp'))
        self.assertIn(('luo', 'xia'), p.parse('loxx', 'double_pinyin_flypy'))
        self.assertEqual(flypy_code('shuang'), 'ul')
        self.assertEqual(flypy_code('ai'), 'ai')
        self.assertIn(('ai', 'ni'), p.parse('aini', 'double_pinyin_flypy'))
        self.assertIn(('ai', 'ni'), p.parse('adni', 'double_pinyin_flypy'))
        self.assertIn(('ju', 'zi'), p.parse('jvzi', 'double_pinyin_flypy'))
        for raw in ['g', 'guw', 'guWU', 'gu1wu', 'gu👀', 'g' * 37]:
            self.assertEqual(p.parse(raw, 'luna_pinyin_simp'), [])
        self.assertEqual(p.parse('gul', 'double_pinyin_flypy'), [])

    def test_rare_character_and_exact_coverage(self):
        paths = [('gu', 'wu')]
        self.assertTrue(self.readings.matches('孤鹜', paths))
        self.assertTrue(self.readings.matches('鼓舞', paths))
        for text in ['孤', '落霞与孤鹜', '孤鹜齐飞', '孤鹜，', '你好']:
            self.assertFalse(self.readings.matches(text, paths))

    def test_byte_fragments_and_multiple_hanzi_in_one_token(self):
        grammar = TokenGrammar.__new__(TokenGrammar)
        grammar.root = {}
        words = [b'\xe9', b'\xb9\x9c', '孤'.encode(), '鼓舞'.encode(), '孤鹜，'.encode(), '坏'.encode()]
        for token, data in enumerate(words):
            node = grammar.root
            for byte in data:
                node = node.setdefault(byte, {})
            node.setdefault(None, []).append(token)
        initial, allowed = grammar.constraint([('gu', 'wu')], self.readings)
        first = allowed(initial)
        self.assertIn(2, first)
        self.assertIn(3, first)
        self.assertNotIn(4, first)
        self.assertNotIn(5, first)
        after_gu = allowed(first[2])
        self.assertIn(0, after_gu)
        after_fragment = allowed(after_gu[0])
        self.assertIn(1, after_fragment)
        self.assertTrue(all(node == -1 for _, _, node in after_fragment[1]))
        self.assertEqual(allowed(after_fragment[1]), {})

if __name__ == '__main__':
    unittest.main()
