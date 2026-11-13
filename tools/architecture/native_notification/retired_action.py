#!/usr/bin/env python3
"""Finite parsed-Kotlin guard for the retired notification cancelAll action."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'native_share'))
from provider_boundary import ROOT, tooling

ID = 'NATIVE_NOTIFICATION_RETIRED_ACTION'
SOURCE = Path(__file__).with_name('RetiredActionGuard.kt')
NATIVE = ROOT / 'android/app/src/main/kotlin/com/tarkilhk/wing/ChatNotifications.kt'


def command():
    java, jars = tooling()
    version = subprocess.check_output([str(java), '-version'], stderr=subprocess.STDOUT)
    fingerprint = hashlib.sha256(SOURCE.read_bytes() + version + b''.join(
        hashlib.sha256(jar.read_bytes()).digest() for jar in jars)).hexdigest()
    destination = ROOT / 'build/native-notification-action-guard' / fingerprint
    classpath = os.pathsep.join(map(str, jars))
    if not (destination / 'RetiredActionGuardKt.class').is_file():
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(java), '-cp', classpath,
                        'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                        '-no-stdlib', '-no-reflect', '-classpath', classpath,
                        '-jvm-target', '17', '-d', str(destination), str(SOURCE)],
                       check=True)
    return [str(java), '-cp', str(destination) + os.pathsep + classpath,
            'RetiredActionGuardKt']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=NATIVE)
    args = parser.parse_args()
    try:
        return subprocess.run(command() + [str(args.source)]).returncode
    except (OSError, ValueError, subprocess.CalledProcessError):
        print(f'[{ID}] Invalid native action tooling/input; inspect existing compiler prerequisites.',
              file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
