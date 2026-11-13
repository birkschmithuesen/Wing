#!/usr/bin/env python3
"""Reject two exact retired Kotlin declarations using the cached Android PSI parser."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'native_share'))
from provider_boundary import tooling

ROOT = Path(__file__).resolve().parents[3]
ID = 'NATIVE_RETIRED_DECLARATION'
SOURCE = Path(__file__).with_name('RetiredDeclarationGuard.kt')
NATIVE = Path('android/app/src/main/kotlin/com/tarkilhk/wing')


def command(output=None):
    java, jars = tooling()
    version = subprocess.check_output([str(java), '-version'], stderr=subprocess.STDOUT)
    fingerprint = hashlib.sha256(SOURCE.read_bytes() + version + b''.join(
        hashlib.sha256(jar.read_bytes()).digest() for jar in jars)).hexdigest()
    destination = (output or ROOT / 'build/native-retired-declaration-guard') / fingerprint
    classpath = os.pathsep.join(map(str, jars))
    if not (destination / 'RetiredDeclarationGuardKt.class').is_file():
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(java), '-cp', classpath,
                        'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                        '-no-stdlib', '-no-reflect', '-classpath', classpath,
                        '-jvm-target', '17', '-d', str(destination), str(SOURCE)], check=True)
    return [str(java), '-cp', str(destination) + os.pathsep + classpath,
            'RetiredDeclarationGuardKt']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--cache-dir', type=Path)
    args = parser.parse_args()
    try:
        paths = [args.root / NATIVE / name for name in
                 ('BackgroundMonitoringService.kt', 'NotificationInteractionSecurity.kt')]
        return subprocess.run(command(args.cache_dir) + list(map(str, paths))).returncode
    except (OSError, ValueError, subprocess.CalledProcessError):
        print(f'[{ID}] Invalid native declaration tooling/input; inspect existing compiler prerequisites.',
              file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
