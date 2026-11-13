#!/usr/bin/env python3
"""Prove exact standalone parsed-Kotlin notification action CLI exits 0/1/2."""
from pathlib import Path
import subprocess
import tempfile
import sys
from retired_action import command, ID


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fixture_contract import read_cases, require


def main():
    cases = read_cases(Path(__file__).with_name('contract.fixture.json'))
    run = command()
    for case in cases:
        with tempfile.TemporaryDirectory(prefix='wing-notification-action-') as scratch:
            path = Path(scratch) / 'ChatNotifications.kt'
            path.write_text(case['source'])
            result = subprocess.run(run + [str(path)], capture_output=True, text=True)
            require(result.returncode == case['exit'], (case['name'], result.returncode))
            diagnostic = f'[{ID}]'
            if case['exit'] == 2:
                require(diagnostic in result.stderr, 'Proof failed: diagnostic in result.stderr')
            else:
                require(result.stdout.count(diagnostic) == case['count'], case['name'])
                if case['exit'] == 1:
                    require(f":{case['line']} {diagnostic}" in result.stdout, case['name'])
    print(f'{ID}: {len(cases)} actual CLI fixtures passed (0/1/2)')


if __name__ == '__main__':
    main()
