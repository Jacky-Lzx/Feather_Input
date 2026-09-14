"""Pinyin-constrained byte/token beam search, independent of the Rime word list."""
import copy
import re
import time
from functools import lru_cache


def flypy_code(syllable):
    # Same transforms as bundled double_pinyin_flypy.schema.yaml; reverse by enumeration.
    s = syllable
    s = re.sub(r'^([aoe])(ng)?$', r'\1\1\2', s)
    rules = [(r'iu$', 'Q'), (r'(.)ei$', r'\1W'), (r'uan$', 'R'),
             (r'[uv]e$', 'T'), (r'un$', 'Y'), (r'^sh', 'U'), (r'^ch', 'I'),
             (r'^zh', 'V'), (r'uo$', 'O'), (r'ie$', 'P'), (r'i?ong$', 'S'),
             (r'ing$|uai$', 'K'), (r'(.)ai$', r'\1D'), (r'(.)en$', r'\1F'),
             (r'(.)eng$', r'\1G'), (r'[iu]ang$', 'L'), (r'(.)ang$', r'\1H'),
             (r'ian$', 'M'), (r'(.)an$', r'\1J'), (r'(.)ou$', r'\1Z'),
             (r'[iu]a$', 'X'), (r'iao$', 'N'), (r'(.)ao$', r'\1C'),
             (r'ui$', 'V'), (r'in$', 'B')]
    for pattern, replacement in rules:
        s = re.sub(pattern, replacement, s)
    return s.lower()


class Pronunciations:
    def __init__(self):
        from pypinyin.pinyin_dict import pinyin_dict
        from pypinyin.contrib.tone_convert import to_normal
        self.chars = {}
        for codepoint, readings in pinyin_dict.items():
            # Include extensions (rare characters), exclude non-Han dictionary entries.
            if not (0x3400 <= codepoint <= 0x9fff or 0x20000 <= codepoint <= 0x323af):
                continue
            for reading in readings.split(','):
                syllable = to_normal(reading).replace('ü', 'v')
                if re.fullmatch('[a-z]+', syllable):
                    self.chars.setdefault(syllable, set()).add(chr(codepoint))
        self.flypy = {}
        for syllable in self.chars:
            code = flypy_code(syllable)
            if len(code) == 2:
                self.flypy.setdefault(code, set()).add(syllable)
            if re.fullmatch(r'[aoe][ioun]', syllable):
                self.flypy.setdefault(flypy_code(syllable[0] + syllable), set()).add(syllable)
        # Rime derives jv/qv/xv/yv aliases for ju/qu/xu/yu.
        for initial in 'jqxy':
            if initial + 'u' in self.chars:
                self.flypy.setdefault(initial + 'v', set()).add(initial + 'u')

    def parse(self, raw, scheme):
        if not isinstance(raw, str) or not re.fullmatch("[a-z' ]{2,36}", raw):
            return []
        if scheme not in ('luna_pinyin_simp', 'double_pinyin_flypy'):
            return []
        parts = raw.replace(' ', "'").split("'")
        if any(not p for p in parts):
            return []
        @lru_cache(None)
        def segment(part):
            if not part:
                return [()]
            results = []
            sizes = [2] if scheme == 'double_pinyin_flypy' else range(min(6, len(part)), 0, -1)
            for size in sizes:
                head = part[:size]
                options = sorted(self.flypy.get(head, [])) if scheme == 'double_pinyin_flypy' else ([head] if head in self.chars else [])
                for syllable in options:
                    for tail in segment(part[size:]):
                        if len(tail) < 6:
                            results.append((syllable,) + tail)
            return sorted(set(results), key=lambda p: (len(p), p))[:8]
        paths = [()]
        for part in parts:
            paths = [a + b for a in paths for b in segment(part) if len(a + b) <= 6]
            paths = sorted(set(paths), key=lambda p: (len(p), p))[:8]
        return [p for p in paths if 2 <= len(p) <= 6][:4]

    def matches(self, text, paths):
        return any(len(text) == len(path) and all(c in self.chars[s] for c, s in zip(text, path)) for path in paths)


class TokenGrammar:
    def __init__(self, tokenizer):
        # Qwen ByteLevel BPE token spellings preserve incomplete UTF-8 pieces.
        import json
        decoder = json.loads(tokenizer.backend_tokenizer.to_str())['decoder']
        if decoder.get('type') != 'ByteLevel':
            raise ValueError('pinyin generation requires a ByteLevel tokenizer')
        # Build explicitly to avoid relying on tokenizer.decode's replacement character.
        visible = list(range(33, 127)) + list(range(161, 173)) + list(range(174, 256))
        byte_decoder = {chr(b): b for b in visible}
        extra = 0
        for b in range(256):
            if b not in visible:
                byte_decoder[chr(256 + extra)] = b
                extra += 1
        self.root = {}
        self.bytes = {}
        special = set(tokenizer.all_special_ids)
        for spelling, token in tokenizer.get_vocab().items():
            if token in special or not spelling or any(c not in byte_decoder for c in spelling):
                continue
            data = bytes(byte_decoder[c] for c in spelling)
            self.bytes[token] = data
            node = self.root
            for b in data:
                node = node.setdefault(b, {})
            node.setdefault(None, []).append(token)

    def constraint(self, paths, pronunciations):
        nodes = [{}]
        roots = {}
        for syllable in set(s for path in paths for s in path):
            roots[syllable] = len(nodes)
            nodes.append({})
            for char in pronunciations.chars[syllable]:
                node = roots[syllable]
                for b in char.encode():
                    if b not in nodes[node]:
                        nodes[node][b] = len(nodes)
                        nodes.append({})
                    node = nodes[node][b]
                nodes[node][None] = True
        initial = tuple((p, 0, roots[path[0]]) for p, path in enumerate(paths))

        @lru_cache(None)
        def advance(states, byte):
            result = set()
            for path, position, node in states:
                if node < 0 or byte not in nodes[node]:
                    continue
                following = nodes[node][byte]
                if None in nodes[following]:
                    position += 1
                    following = roots[paths[path][position]] if position < len(paths[path]) else -1
                result.add((path, position, following))
            return tuple(sorted(result))

        @lru_cache(None)
        def allowed(states):
            result = {}
            def visit(token_node, current):
                for token in token_node.get(None, []):
                    result[token] = current
                for byte, child in token_node.items():
                    if byte is not None:
                        following = advance(current, byte)
                        if following:
                            visit(child, following)
            visit(self.root, states)
            return result
        return initial, allowed


def generate(predictor, context, raw, scheme, count=3, budget=1.8, beam_width=6):
    from mlx_lm.models.cache import make_prompt_cache
    started = time.monotonic()
    pronunciations = predictor.pronunciations
    paths = pronunciations.parse(raw, scheme)
    reply = {'candidates': [], 'syllables': [list(p) for p in paths], 'elapsed_ms': 0, 'truncated': False}
    if not paths:
        return reply
    mx = predictor.mx
    prefix = predictor.tokenizer.encode(context, add_special_tokens=False)
    if not prefix:
        return reply
    initial, allowed = predictor.token_grammar.constraint(paths, pronunciations)
    cache = make_prompt_cache(predictor.model)
    def forward(tokens, cache):
        logits = predictor.model(mx.array([tokens]), cache=cache)[:, -1, :].astype(mx.float32).reshape(-1)
        probs = logits - mx.logsumexp(logits)
        mx.eval(probs)
        return probs
    probs = forward(prefix, cache)
    beams = [(0.0, [], initial, cache, probs)]
    finished = {}
    for _ in range(4 * max(map(len, paths))):
        if time.monotonic() - started > budget:
            reply['truncated'] = True
            break
        proposals = []
        for score, tokens, states, cache, probs in beams:
            transitions = allowed(states)
            ids = list(transitions)
            if not ids:
                continue
            values = probs[mx.array(ids)]
            best = mx.argsort(values)[-beam_width:][::-1].tolist()
            for index in best:
                token = ids[index]
                total = score + values[index].item()
                following = transitions[token]
                sequence = tokens + [token]
                if any(node == -1 for _, _, node in following):
                    text = predictor.tokenizer.decode(sequence)
                    if pronunciations.matches(text, paths):
                        row = {'text': text, 'score': total, 'token_ids': sequence}
                        if text not in finished or total > finished[text]['score']:
                            finished[text] = row
                ongoing = tuple(state for state in following if state[2] != -1)
                if ongoing:
                    proposals.append((total, sequence, ongoing, cache))
        proposals.sort(key=lambda row: (-row[0], row[1]))
        best_finished = sorted(finished.values(), key=lambda row: -row['score'])
        if not proposals or (len(best_finished) >= count and proposals[0][0] <= best_finished[count - 1]['score']):
            break
        beams = []
        for score, tokens, states, parent_cache in proposals[:beam_width]:
            if time.monotonic() - started > budget:
                reply['truncated'] = True
                break
            branch_cache = copy.deepcopy(parent_cache)
            beams.append((score, tokens, states, branch_cache, forward(tokens[-1:], branch_cache)))
        if not beams:
            break
    reply['candidates'] = sorted(finished.values(), key=lambda row: (-row['score'], row['text']))[:count]
    reply['elapsed_ms'] = round((time.monotonic() - started) * 1000)
    return reply
