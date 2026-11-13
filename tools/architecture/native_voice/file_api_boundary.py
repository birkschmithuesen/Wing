#!/usr/bin/env python3
"""Scoped parsed-Kotlin file dependency guard, not a thread/dataflow proof."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'native_share'))
from provider_boundary import ROOT, tooling
SOURCE = Path(__file__).with_name('VoiceFileApiGuard.kt')


def command(*, source=SOURCE, companions=(), main_class="VoiceFileApiGuardKt", cache_name="native-voice-guard"):
    sources = [source, *companions]
    java, jars = tooling()
    version = subprocess.check_output([str(java), '-version'], stderr=subprocess.STDOUT)
    fingerprint = hashlib.sha256(b"".join(item.read_bytes() for item in sources) + main_class.encode() + version + b''.join(hashlib.sha256(jar.read_bytes()).digest() for jar in jars)).hexdigest()
    destination = ROOT / 'build' / cache_name / fingerprint
    classpath = os.pathsep.join(map(str, jars))
    if not (destination / (main_class + '.class')).is_file():
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(java), '-cp', classpath, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', classpath, '-jvm-target', '17', '-d', str(destination), *map(str, sources)], check=True)
    return [str(java), '-cp', str(destination) + os.pathsep + classpath, main_class]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, action='append')
    args = parser.parse_args()
    native = ROOT / 'android/app/src/main/kotlin/com/tarkilhk/wing'
    paths = args.source or [native / (name + '.kt') for name in ['VoiceChannel', 'VoiceCapture', 'VoicePlayback']]
    try:
        return subprocess.run(command() + list(map(str, paths))).returncode
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'[NATIVE_VOICE_FILE_API_BOUNDARY] Invalid input: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
