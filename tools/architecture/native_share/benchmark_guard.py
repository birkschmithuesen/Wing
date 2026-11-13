#!/usr/bin/env python3
"""Observe cold setup and three warm runs; timing never changes correctness."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import statistics
import subprocess
import tempfile
import time
from provider_boundary import ROOT, command, kotlin_version, tooling


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    native = ROOT / 'android/app/src/main/kotlin/com/tarkilhk/wing'
    inputs = [native / name for name in
              ('MainActivity.kt', 'BoundedProviderWork.kt', 'BoundedIntakeQueue.kt')]
    inputs.append(ROOT / 'android/app/build.gradle.kts')
    result = {}
    with tempfile.TemporaryDirectory(prefix='wing-native-guard-cold-') as scratch:
        started = time.perf_counter()
        run = command(Path(scratch))
        subprocess.run(run + ['--rule=all', *map(str, inputs)], check=True)
        result['cold_compile_plus_cli_seconds'] = time.perf_counter() - started
    # Prime the normal source/SDK-aware cache separately from measurements.
    command()
    wrapper = Path(__file__).with_name('provider_boundary.py')
    for rule in ('provider-boundary', 'bounded-queues', 'qa-isolation', 'all'):
        timings = []
        for _ in range(3):
            started = time.perf_counter()
            subprocess.run(['python3', str(wrapper), '--rule', rule], check=True)
            timings.append(time.perf_counter() - started)
        result[rule] = {'warm_seconds': timings,
                        'median_seconds': statistics.median(timings)}
    java, _ = tooling()
    result.update({'host': platform.platform(), 'compiler': kotlin_version(),
                   'jdk': subprocess.check_output([str(java), '-version'],
                       stderr=subprocess.STDOUT, text=True),
                   'files': [{'path': str(path.relative_to(ROOT)),
                              'bytes': len(path.read_bytes()),
                              'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                             for path in inputs]})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
