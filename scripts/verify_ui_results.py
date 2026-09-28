"""Reject empty, failed, skipped or partial XCUITest release runs."""
import argparse
import json
from pathlib import Path
import re


def validate(summary, test_source, details=None):
    names = re.findall(r'\bfunc\s+(test\w+)\s*\(', test_source)
    if not names or len(names) != len(set(names)):
        raise ValueError('UI test inventory is empty or ambiguous')
    required = {'testProductReopensMainWindowAfterLastWindowCloses'}
    if not required.issubset(names):
        raise ValueError('Required product window reopening regression is missing')
    if summary.get('result') != 'Passed':
        raise ValueError('UI result is not Passed')
    for field in ('failedTests', 'skippedTests', 'expectedFailures'):
        if summary.get(field) != 0:
            raise ValueError(f'UI release requires zero {field}')
    if summary.get('passedTests') != len(names) or summary.get('totalTestCount') != len(names):
        raise ValueError('UI run does not cover the entire current test inventory')
    if details is not None:
        cases = []
        def visit(nodes):
            for node in nodes:
                if node.get('nodeType') == 'Test Case':
                    cases.append(node)
                visit(node.get('children', []))
        visit(details.get('testNodes', []))
        executed = [node.get('name', '').split('/')[-1].removesuffix('()') for node in cases]
        if len(executed) != len(names) or set(executed) != set(names):
            raise ValueError('UI case names do not match the current test inventory')
        if any(node.get('result') != 'Passed' for node in cases):
            raise ValueError('Every required UI case must pass')
    return len(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('summary', type=Path)
    parser.add_argument('--source', type=Path, default=Path('UITests/ApexTermUITests.swift'))
    parser.add_argument('--details', type=Path, required=True)
    args = parser.parse_args()
    try:
        count = validate(json.loads(args.summary.read_text()), args.source.read_text(), json.loads(args.details.read_text()))
    except (ValueError, OSError) as error:
        raise SystemExit(f'UI release gate rejected: {error}')
    print(f'UI result verified: {count} tests passed; no failures or skips')


if __name__ == '__main__':
    main()
