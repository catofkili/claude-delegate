#!/usr/bin/env python3
"""Measure context reads and approximate growth, not currency or invoice cost."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys


def tool_category(name, inputs, handoff):
    if name != 'Bash':
        return name
    command = inputs.get('command', '') if isinstance(inputs, dict) else ''
    if handoff.search(command):
        return 'Bash:handoff'
    if re.search(r'\b(?:npm|npx|pytest|unittest|cargo|go test|make|tsc|vitest)\b', command):
        return 'Bash:build/test'
    if re.search(r'\bgit\b', command):
        return 'Bash:git'
    if re.search(r'\b(?:rg|grep|cat|sed|head|tail|find|ls)\b', command):
        return 'Bash:read/search'
    return 'Bash:other'


def analyze(path, pattern):
    turns = {}
    compactions = set()
    compact_since_turn = False
    for line_number, line in enumerate(path.open(encoding='utf-8'), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError as error:
            raise ValueError(f'line {line_number}: invalid JSON') from error
        if not isinstance(record, dict):
            continue
        if record.get('isSidechain'):
            continue
        if record.get('type') == 'system' and record.get('subtype') == 'compact_boundary':
            compactions.add(record.get('uuid') or f'line:{line_number}')
            compact_since_turn = True
            continue
        if record.get('type') != 'assistant':
            continue
        message = record.get('message') or {}
        if not isinstance(message, dict):
            continue
        identity = message.get('id') or record.get('uuid') or f'line:{line_number}'
        turn = turns.get(identity)
        if turn is None:
            turn = turns[identity] = {'context': None, 'tools': set(), 'handoff': False,
                                     'compacted': compact_since_turn}
            compact_since_turn = False
        usage = message.get('usage')
        keys = ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')
        if isinstance(usage, dict) and any(key in usage for key in keys):
            context = sum(usage.get(key, 0) or 0 for key in keys)
            # Streaming records can repeat an id with partial usage and tool blocks.
            turn['context'] = max(turn['context'] or 0, context)
        content = message.get('content') or []
        if isinstance(content, str):
            content = [{'type': 'text', 'text': content}]
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get('type') == 'tool_use':
                name = block.get('name', 'unknown')
                inputs = block.get('input', {})
                turn['tools'].add(tool_category(name, inputs, pattern))
                searchable = name + ' ' + json.dumps(inputs, ensure_ascii=False)
            elif block.get('type') == 'text':
                searchable = block.get('text', '')
            else:
                continue
            turn['handoff'] |= bool(pattern.search(searchable))
    sequence = list(turns.values())
    measured = [turn for turn in sequence if turn['context'] is not None]
    if not measured:
        raise ValueError('no assistant turns with input-token usage found')
    growth = Counter()
    resets = 0
    for before, after in zip(sequence, sequence[1:]):
        if before['context'] is None or after['context'] is None:
            continue
        if after['compacted']:
            continue
        delta = after['context'] - before['context']
        # A drop may be a branch, resume, or reset; it does not prove compaction.
        if delta < 0:
            resets += 1
            continue
        categories = before['tools']
        category = next(iter(categories)) if len(categories) == 1 else (
            'mixed tools' if categories else 'text/user/system')
        growth[category] += delta
    total = sum(turn['context'] for turn in measured)
    matched = [turn for turn in measured if turn['handoff']]
    matched_context = sum(turn['context'] for turn in matched)
    return sequence, measured, compactions, resets, growth, total, matched, matched_context


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        'A turn is one unique assistant message id. Context = input_tokens + '
        'cache_read_input_tokens + cache_creation_input_tokens. Handoff matches '
        'assistant text and tool names/inputs (not returned logs). Growth assigns '
        'the next nonnegative context delta to the preceding turn; mixed tools '
        'stay mixed. Only explicit compact_boundary records count as compactions.'))
    parser.add_argument('session', type=Path, help='Claude Code session JSONL file')
    parser.add_argument('--handoff-pattern', default='codex|delegate',
                        help='case-insensitive regular expression (default: codex|delegate)')
    args = parser.parse_args()
    try:
        pattern = re.compile(args.handoff_pattern, re.IGNORECASE)
        sequence, measured, compactions, resets, growth, total, matched, matched_context = analyze(args.session, pattern)
    except (OSError, ValueError, re.error) as error:
        parser.error(str(error))
    print(f'Turns: {len(sequence)} ({len(measured)} with usage; sidechains excluded)')
    print(f'Opening fixed context (first measured input, proxy): {measured[0]["context"]:,} tokens')
    print(f'Peak context: {max(turn["context"] for turn in measured):,} tokens')
    print(f'Compactions: {len(compactions)} (explicit boundaries)')
    print(f'Other context drops excluded from growth: {resets}')
    print(f'Total context read: {total:,} tokens')
    print('Context net growth by preceding tool category (approximate):')
    for category, tokens in growth.most_common():
        print(f'  {category}: {tokens:+,} tokens')
    if not growth:
        print('  no comparable adjacent turns')
    proportion = 100 * matched_context / total if total else 0
    print(f'Handoff turns / measured turns: {len(matched)}/{len(measured)}')
    print(f'Handoff context read / total: {matched_context:,}/{total:,} tokens ({proportion:.2f}%)')
    print('Not a bill: cache reads, cache writes, outputs and provider prices differ.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
