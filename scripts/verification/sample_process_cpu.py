#!/usr/bin/env python3
"""Stream external cumulative CPU samples; never certify UI or scene conditions."""
import argparse
import json
import math
import subprocess
import time
from pathlib import Path


def cpu_seconds(value):
    fields = value.strip().split(':')
    if len(fields) not in (2, 3):
        raise ValueError('Unexpected ps cumulative CPU time: ' + value)
    total = 0.0
    for field in fields:
        component = float(field)
        if not math.isfinite(component) or component < 0:
            raise ValueError('Invalid ps cumulative CPU time: ' + value)
        total = total * 60 + component
    return total


def read(pid, fields):
    result = subprocess.run(['ps', '-p', str(pid), '-o', fields], capture_output=True, text=True)
    if result.returncode == 1 and not result.stdout.strip():
        return ''
    result.check_returncode()
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--seconds', type=float, default=60)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error('PID and duration must be positive')
    identity = read(args.pid, 'lstart=,comm=')
    if not identity:
        parser.error('Target is not running')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as file:
        def write(record):
            file.write(json.dumps(record) + '\n')
            file.flush()
        write({'type': 'metadata', 'pid': args.pid, 'identity': identity,
               'measurement': 'ps cumulative CPU time delta / monotonic elapsed; percent of one core',
               'sceneVerified': False, 'requestedSeconds': args.seconds})
        first_cpu = cpu_seconds(read(args.pid, 'time='))
        start = time.monotonic()
        while True:
            if read(args.pid, 'lstart=,comm=') != identity:
                write({'type': 'end', 'valid': False, 'reason': 'Process identity changed'})
                raise SystemExit(1)
            raw_cpu = read(args.pid, 'time=')
            if not raw_cpu:
                write({'type': 'end', 'valid': False, 'reason': 'Process exited before CPU sample'})
                raise SystemExit(1)
            cpu = cpu_seconds(raw_cpu)
            elapsed = time.monotonic() - start
            if cpu < first_cpu:
                raise ValueError('Cumulative CPU counter decreased')
            write({'type': 'sample', 'elapsedSeconds': elapsed, 'cpuSeconds': cpu})
            if elapsed >= args.seconds:
                if read(args.pid, 'lstart=,comm=') != identity:
                    raise ValueError('Process identity changed at measurement end')
                write({'type': 'end', 'valid': True, 'elapsedSeconds': elapsed,
                       'cpuDeltaSeconds': cpu - first_cpu,
                       'averageSingleCorePercent': 100 * (cpu - first_cpu) / elapsed,
                       'durationAtLeast60Seconds': elapsed >= 60,
                       'acceptancePassed': False})
                break
            time.sleep(min(1, args.seconds - elapsed))


if __name__ == '__main__':
    main()
