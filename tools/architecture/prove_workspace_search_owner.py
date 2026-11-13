#!/usr/bin/env python3
"""Run the finite search-owner fixtures and record actual-checkout CLI timing."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dart', type=Path)
    parser.add_argument('--original-root', type=Path)
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    app = Path(__file__).resolve().parents[2]
    dart = args.dart or shutil.which('dart')
    if dart is None:
        parser.error('Supply --dart with the existing pinned SDK executable')
    dart = str(Path(dart).resolve())
    if not Path(dart).is_file():
        parser.error('--dart must be an existing executable')
    records = []

    def run(name, command, expected):
        start = time.perf_counter()
        result = subprocess.run(command, cwd=app, text=True, capture_output=True)
        record = {'case': name, 'command': command, 'exit': result.returncode,
                  'elapsed_seconds': time.perf_counter() - start,
                  'stdout': result.stdout, 'stderr': result.stderr}
        records.append(record)
        if args.evidence:
            args.evidence.parent.mkdir(parents=True, exist_ok=True)
            args.evidence.write_text(json.dumps(records, indent=2) + '\n')
        if result.returncode != expected:
            raise RuntimeError(f'{name}: expected exit {expected}, got {result.returncode}')
        return result

    run('finite-fixtures', [dart, 'run',
        'tools/architecture/tests/workspace_search_owner_test.dart'], 0)
    cli = [dart, 'run', 'tools/architecture/rules/workspace_search_owner.dart']
    if args.original_root:
        result = run('original-red', [*cli, '--root',
                     str(args.original_root.resolve()), '--json'], 1)
        problems = json.loads(result.stdout)['problems']
        if len(problems) != 1 or problems[0]['id'] != 'ARCH_WORKSPACE_SEARCH_OWNER':
            raise RuntimeError('Original must have exactly one search-owner diagnostic')
    # Timings are evidence only; they cannot alter the deterministic verdict.
    for index in range(3):
        result = run(f'current-{index}', [*cli, '--json'], 0)
        if json.loads(result.stdout)['problems']:
            raise RuntimeError('Current checkout must have zero findings')
    print('ARCH_WORKSPACE_SEARCH_OWNER: fixtures and current CLI passed')


if __name__ == '__main__':
    main()
