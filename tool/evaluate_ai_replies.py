#!/usr/bin/env python3
"""Small paid DeepSeek regression evaluation; key is read only from environment.

Export current app prompts first:
  dart run tool/export_ai_reply_prompts.dart > /tmp/ai-reply-protocol.json
Then set DEEPSEEK_API_KEY in your environment and run:
  python3 tool/evaluate_ai_replies.py --protocol /tmp/ai-reply-protocol.json
Use --seed to check order sensitivity. This is a calibration set, not an
unbiased measure of real-world accuracy. No credentials are saved or printed.
"""
import argparse
import json
import os
from pathlib import Path
import random
import re
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--protocol', type=Path, required=True)
    parser.add_argument('--cases', type=Path, default=Path(__file__).resolve().parents[1] / 'test/fixtures/ai_reply_cases.json')
    parser.add_argument('--model', default='deepseek-flash')
    parser.add_argument('--batch-size', type=int, choices=range(1, 51), default=20)
    parser.add_argument('--seed', type=int)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    key = os.environ.get('DEEPSEEK_API_KEY')
    if not key:
        parser.error('Set DEEPSEEK_API_KEY in the process environment.')
    protocol = json.loads(args.protocol.read_text())
    cases = json.loads(args.cases.read_text())
    order = list(range(len(cases)))
    if args.seed is not None:
        random.Random(args.seed).shuffle(order)
    results = []
    for offset in range(0, len(order), args.batch_size):
        indices = order[offset:offset + args.batch_size]
        values = {'count': str(len(indices)), 'title': '', 'desc': '', 'comments': json.dumps(
            [[i, cases[index]['text']] for i, index in enumerate(indices)], ensure_ascii=False, separators=(',', ':'))}
        user = re.sub(r'\{(count|title|desc|comments)\}', lambda match: values[match[1]], protocol['user'])
        body = {'model': args.model, 'messages': [{'role': 'system', 'content': protocol['system']},
            {'role': 'user', 'content': user}], 'thinking': {'type': 'disabled'}, 'temperature': 0,
            'response_format': {'type': 'json_object'}, 'max_tokens': 1024, 'stream': False}
        request = urllib.request.Request('https://api.deepseek.com/chat/completions',
            data=json.dumps(body).encode(), headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                data = json.load(response)
            choice = data['choices'][0]
            if choice.get('finish_reason') != 'stop':
                raise ValueError('Response did not finish normally')
            decoded = json.loads(choice['message']['content'])
            coded = 'c' in decoded
            if coded and 'v' in decoded:
                raise ValueError('Conflicting result formats')
            verdicts = decoded['c' if coded else 'v']
            if not isinstance(verdicts, dict) or set(verdicts) != {str(i) for i in range(len(indices))}:
                raise ValueError('Missing or unexpected verdict IDs')
            if any(type(value) is not int or not 0 <= value <= (6 if coded else 1) for value in verdicts.values()):
                raise ValueError('Invalid verdict value')
            mismatches = [{'case': index, 'text': cases[index]['text'], 'expected': int(cases[index]['unsafe']),
                'actual': int(verdicts[str(i)] > 0)} for i, index in enumerate(indices)
                if (verdicts[str(i)] > 0) != cases[index]['unsafe']]
            results.append({'indices': indices, 'model': data.get('model'), 'seconds': round(time.monotonic() - started, 3),
                'usage': data.get('usage'), 'mismatches': mismatches})
        except urllib.error.HTTPError as error:
            raise SystemExit(f'DeepSeek returned HTTP {error.code}; no automatic retry.') from None
        except (ValueError, KeyError, urllib.error.URLError) as error:
            raise SystemExit(f'Evaluation failed ({type(error).__name__}); no automatic retry.') from None
    summary = {'cases': len(cases), 'seed': args.seed, 'batch_size': args.batch_size,
        'correct': len(cases) - sum(len(result['mismatches']) for result in results), 'batches': results}
    serialized = json.dumps(summary, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(serialized + '\n')
    print(serialized)


if __name__ == '__main__':
    main()
