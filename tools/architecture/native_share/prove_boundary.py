#!/usr/bin/env python3
"""Actual standalone Kotlin PSI CLI exit proofs on raw synthetic artifacts."""
from pathlib import Path
import subprocess
import tempfile
import sys
from provider_boundary import command


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fixture_contract import read_cases, require


def main():
    cases = read_cases(Path(__file__).with_name('contract.fixture.json'))
    run = command()
    for case in cases:
        with tempfile.TemporaryDirectory(prefix='wing-provider-boundary-') as scratch:
            path = Path(scratch) / 'MainActivity.kt'
            path.write_text(case['code'])
            rule = 'bounded-queues' if case.get('id') == 'NATIVE_SHARE_BOUNDED_QUEUE' else 'provider-boundary'
            result = subprocess.run(run + ['--rule=' + rule, str(path)], text=True, capture_output=True)
            require(result.returncode == case['exit'], (case['name'], result.stdout, result.stderr))
            if case['exit']:
                require(case.get('id', 'NATIVE_SHARE_PROVIDER_BOUNDARY') in result.stdout + result.stderr, "Proof failed: case.get('id', 'NATIVE_SHARE_PROVIDER_BOUNDARY') in result.stdout + result.stderr")
            if case['exit'] == 1:
                require(':' + str(case.get('line', 1)) + ' [' + case.get('id', 'NATIVE_SHARE_PROVIDER_BOUNDARY') + ']' in result.stdout, "Proof failed: ':' + str(case.get('line', 1)) + ' [' + case.get('id', 'NATIVE_SHARE_PROVIDER_BOUNDARY') + ']' in result.stdout")
    from prove_qa_isolation import main as prove_qa_isolation
    prove_qa_isolation()
    print(f'NATIVE_SHARE_PROVIDER_BOUNDARY: {len(cases)} CLI fixture exits proved (1/0/2)')


if __name__ == '__main__':
    main()
