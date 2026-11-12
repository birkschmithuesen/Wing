#!/usr/bin/env python3
"""Prove the independent QA isolation Kotlin PSI rule through its actual CLI."""
from pathlib import Path
import subprocess
import tempfile
import sys

from provider_boundary import command

ID = 'NATIVE_SHARE_QA_ISOLATION'


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fixture_contract import read_cases, require


def main():
    cases = read_cases(Path(__file__).with_name('qa_isolation.fixture.json'),
                       required_names=('missing-debug-fence', 'native-parse-error'))
    run = command()
    for case in cases:
        with tempfile.TemporaryDirectory(prefix='wing-qa-isolation-') as scratch:
            native = Path(scratch) / 'MainActivity.kt'
            gradle = Path(scratch) / 'build.gradle.kts'
            native.write_text(case['native'])
            gradle.write_text(case['gradle'])
            result = subprocess.run(run + ['--rule=qa-isolation', str(native), str(gradle)],
                                    text=True, capture_output=True)
            require(result.returncode == case['exit'], (case['name'], result.stdout, result.stderr))
            if case['exit']:
                require(ID in result.stdout + result.stderr, case['name'])
            if case['exit'] == 1:
                require(':' + str(case['line']) + ' [' + ID + ']' in result.stdout, (case['name'], result.stdout))
    with tempfile.TemporaryDirectory(prefix='wing-qa-isolation-') as scratch:
        result = subprocess.run(run + ['--rule=qa-isolation', str(Path(scratch) / 'missing.kt'),
                                      str(Path(scratch) / 'build.gradle.kts')], text=True, capture_output=True)
        require(result.returncode == 2 and ID in result.stderr, result.stderr)
    # Exercise the contributor/CI wrapper too: argument routing cannot omit the rule.
    wrapper = Path(__file__).with_name('provider_boundary.py')
    with tempfile.TemporaryDirectory(prefix='wing-qa-wrapper-') as scratch:
        native = Path(scratch) / 'MainActivity.kt'
        gradle = Path(scratch) / 'build.gradle.kts'
        for case in (cases[0], next(case for case in cases if case['name'] == 'missing-debug-fence'),
                     next(case for case in cases if case['name'] == 'native-parse-error')):
            native.write_text(case['native'])
            gradle.write_text(case['gradle'])
            result = subprocess.run([sys.executable, str(wrapper), '--rule', 'qa-isolation',
                                     '--source', str(native), '--gradle', str(gradle)],
                                    text=True, capture_output=True)
            require(result.returncode == case['exit'], (case['name'], result.stdout, result.stderr))
            if case['exit']:
                require(ID in result.stdout + result.stderr, 'Proof failed: ID in result.stdout + result.stderr')
    print(f'{ID}: {len(cases) + 4} actual CLI fixture exits proved (1/0/2)')


if __name__ == '__main__':
    main()
