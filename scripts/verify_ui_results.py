"""Reject empty, failed, skipped or partial XCUITest release runs."""
import argparse
import json
from pathlib import Path
import re


def validate(summary, test_source):
    names = re.findall(r'\bfunc\s+(test\w+)\s*\(', test_source)
    if not names or len(names) != len(set(names)):
        raise ValueError('UI test inventory is empty or ambiguous')
    if summary.get('result') != 'Passed':
        raise ValueError('UI result is not Passed')
    for field in ('failedTests', 'skippedTests', 'expectedFailures'):
        if summary.get(field) != 0:
            raise ValueError(f'UI release requires zero {field}')
    if summary.get('passedTests') != len(names) or summary.get('totalTestCount') != len(names):
        raise ValueError('UI run does not cover the entire current test inventory')
    return len(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('summary', type=Path)
    parser.add_argument('--source', type=Path, default=Path('UITests/ApexTermUITests.swift'))
    args = parser.parse_args()
    try:
        count = validate(json.loads(args.summary.read_text()), args.source.read_text())
    except (ValueError, OSError) as error:
        raise SystemExit(f'UI release gate rejected: {error}')
    print(f'UI result verified: {count} tests passed; no failures or skips')


if __name__ == '__main__':
    main()
