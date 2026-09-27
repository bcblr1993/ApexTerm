#!/usr/bin/env python3
"""Stream macOS process RSS outside the measured application, without retaining samples."""
import argparse
import json
import subprocess
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--seconds', type=float, default=1800)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or args.seconds <= 0 or args.interval <= 0:
        parser.error('PID, duration and interval must be positive')
    initial = subprocess.check_output(['ps', '-p', str(args.pid), '-o', 'lstart=,comm='], text=True).strip()
    if not initial:
        parser.error('Target process does not exist')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    # Exclusive creation protects previous diagnostic evidence.
    with args.output.open('x') as file:
        file.write(json.dumps({'type': 'metadata', 'pid': args.pid, 'identity': initial,
                               'measurement': 'ps RSS KiB; sampler runs outside target'}) + '\n')
        while time.monotonic() - started < args.seconds:
            state = subprocess.run(['ps', '-p', str(args.pid), '-o', 'lstart=,comm='], capture_output=True, text=True)
            if state.stdout.strip() != initial:
                file.write(json.dumps({'type': 'end', 'reason': 'target exited or identity changed'}) + '\n')
                break
            rss = subprocess.run(['ps', '-p', str(args.pid), '-o', 'rss='], capture_output=True, text=True)
            if not rss.stdout.strip():
                break
            file.write(json.dumps({'type': 'sample', 'elapsed': time.monotonic() - started,
                                   'rssMB': int(rss.stdout.strip()) / 1024}) + '\n')
            file.flush()
            time.sleep(min(args.interval, max(0, args.seconds - (time.monotonic() - started))))


if __name__ == '__main__':
    main()
