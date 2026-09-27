#!/usr/bin/env python3
"""Sample one existing process without inspecting its arguments or user data."""
import argparse
import json
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--pid', type=int, required=True)
parser.add_argument('--seconds', type=int, default=60)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.seconds < 60:
    parser.error('Use at least 60 seconds for idle sampling')

def sample():
    fields = subprocess.check_output(['ps', '-p', str(args.pid), '-o', 'time=', '-o', 'rss='], text=True).split()
    if len(fields) != 2:
        raise RuntimeError('Target process stopped during measurement')
    parts = [float(x) for x in fields[0].replace('-', ':').split(':')]
    cpu = 0.0
    for part in parts:
        cpu = cpu * 60 + part
    return cpu, int(fields[1]) / 1024

start_cpu, rss = sample()
start = time.monotonic()
readings = [{'elapsed': 0, 'rss_mb': rss}]
while time.monotonic() - start < args.seconds:
    time.sleep(1)
    cpu, rss = sample()
    readings.append({'elapsed': round(time.monotonic() - start, 3), 'rss_mb': rss})
elapsed = time.monotonic() - start
report = {'pid': args.pid, 'elapsed_seconds': round(elapsed, 3), 'cpu_percent_of_one_core': round((cpu - start_cpu) / elapsed * 100, 3), 'rss_min_mb': min(x['rss_mb'] for x in readings), 'rss_max_mb': max(x['rss_mb'] for x in readings), 'samples': readings}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, indent=2))
print(json.dumps({k: v for k, v in report.items() if k != 'samples'}))
