"""Synthetic diagnostic only. Candidates must come from isolated EngineCheck export."""
import argparse
import json
import math
import statistics
from server import Predictor


def evaluate(model, fixtures):
    predictor = Predictor(model)
    predictor.score('预热', ['测试', '文本'])
    rows, latency, reference_latency, errors = [], [], [], []
    strategies = ('rime', 'lm_token', 'lm_character', 'fusion')
    hits = {name: [0, 0] for name in strategies}
    for case in fixtures:
        candidates = case['candidates']
        cached = predictor.score(case['context'], candidates)
        reference = predictor.score(case['context'], candidates, reuse_context=False)
        latency.append(cached['elapsed_ms'])
        reference_latency.append(reference['elapsed_ms'])
        by_id = {r['id']: r for r in reference['candidates']}
        errors.extend(abs(a - b) for r in cached['candidates'] for a, b in zip(r['token_logprobs'], by_id[r['id']]['token_logprobs']))
        scores = cached['candidates']
        orders = {'rime': candidates,
                  'lm_token': [r['text'] for r in sorted(scores, key=lambda r: (-r['logprob'] / len(r['token_ids']), r['id']))],
                  'lm_character': [r['text'] for r in sorted(scores, key=lambda r: (-r['lm_score'], r['id']))],
                  'fusion': [r['text'] for r in scores]}
        for name, texts in orders.items():
            hits[name][0] += case['target'] in texts[:1]
            hits[name][1] += case['target'] in texts[:5]
        rows.append({**case, 'orders': orders, 'cached_ms': cached['elapsed_ms'], 'uncached_ms': reference['elapsed_ms'], 'uncached_fusion': [r['text'] for r in reference['candidates']]})
    def timing(values):
        return {'median_ms': statistics.median(values), 'p95_ms': sorted(values)[math.ceil(.95 * len(values)) - 1]}
    return {'model': model, 'samples': len(rows), 'scope': '20 hand-written full-pinyin diagnostics; isolated Rime first page (9); no personal learning; no tuning; not a held-out benchmark',
            'weight': .35, 'normalization': 'character',
            'target_in_page': sum(r['target'] in r['candidates'] for r in rows),
            'hits': hits, 'hit_columns': ['top1', 'top5'],
            'cached': timing(latency), 'uncached': timing(reference_latency),
            'max_cache_logprob_difference': max(errors),
            'cache_top1_agreement': sum(r['orders']['fusion'][0] == r['uncached_fusion'][0] for r in rows),
            'cache_full_order_agreement': sum(r['orders']['fusion'] == r['uncached_fusion'] for r in rows), 'rows': rows}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True)
    parser.add_argument('--fixtures', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    with open(args.fixtures) as f:
        fixtures = json.load(f)
    result = evaluate(args.model, fixtures)
    with open(args.output, 'w') as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}, ensure_ascii=False, indent=2))
