#!/usr/bin/env python3
"""Validate optimized benchmark output against the documented release SOP."""
import re
import sys

text = open(sys.argv[1], encoding='utf-8').read()
checks = [
    ('RingBuffer lines/s', r'吞吐速率:\s*([\d.]+) 行/秒', 50_000, False),
    ('RingBuffer MB/s', r'行/秒 \(([\d.]+) MB/秒\)', 5, False),
    ('ANSI spans/s', r'解析速度:\s*([\d.]+) spans/秒', 150_000, False),
    ('Peak RSS MB', r'峰值内存 \(RSS\):\s*([\d.]+) MB', 250, True),
    ('Concurrent writes/s', r'并发写入吞吐:\s*([\d.]+) writes/秒', 1_000_000, False),
    ('Metrics parses/s', r'解析速度:\s*([\d.]+) 次/秒', 8_000, False),
    ('SSH hosts/s', r'解析速率:\s*([\d.]+) hosts/秒', 80_000, False),
    ('SFTP tasks/s', r'处理吞吐量:\s*([\d.]+) tasks/秒', 800, False),
    ('Keystroke microseconds', r'单键平均全链路:\s*([\d.]+) 微秒', 15, True),
]
failed = False
for name, pattern, limit, maximum in checks:
    match = re.search(pattern, text)
    if match is None:
        print(f'FAIL {name}: missing result'); failed = True; continue
    value = float(match.group(1))
    passed = value <= limit if maximum else value >= limit
    print(f'{"PASS" if passed else "FAIL"} {name}: {value} ({"<=" if maximum else ">="} {limit})')
    failed |= not passed
sys.exit(int(failed))
