#!/usr/bin/env python3
"""Informational local-feedback timings; never changes guard correctness."""
import argparse
import json
import platform
from pathlib import Path
import statistics
import subprocess
import time
from file_api_boundary import ROOT, command
from provider_boundary import kotlin_version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/native-voice-guard/timings.json')
    args = parser.parse_args()
    paths = [ROOT / 'android/app/src/main/kotlin/com/tarkilhk/wing' / (name + '.kt') for name in ['VoiceChannel', 'VoiceCapture', 'VoicePlayback']]
    setup = time.monotonic(); run = command(); setup = time.monotonic() - setup
    durations = []
    for _ in range(4):
        clock = time.monotonic()
        result = subprocess.run(run + list(map(str, paths)), capture_output=True, text=True)
        result.check_returncode()
        durations.append(time.monotonic() - clock)
    data = {'host': platform.platform(), 'compiler': f'Kotlin{kotlin_version()}', 'files': len(paths), 'source_bytes': sum(p.stat().st_size for p in paths), 'cache_validation_or_compile_seconds': setup, 'fresh_JVM_seconds': durations, 'repeated_median_seconds': statistics.median(durations[1:]), 'limitation': 'Host informational feedback; not Android main-thread latency or heap acceptance.'}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2) + '\n')
    print(json.dumps(data))


if __name__ == '__main__':
    main()
