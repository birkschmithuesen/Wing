#!/usr/bin/env python3
"""Run Android-independent voice file/lifetime tests using existing cached tools.

No Gradle, Flutter, network or device. Optional --red-growth reproduces the
original unbounded readBytes body in an isolated temporary copy; live source
is never rolled back or modified.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'native_share'))
from provider_boundary import ROOT, tooling


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--red-growth', action='store_true')
    parser.add_argument('--compile-boundary', action='store_true', help='Compile actual VoiceChannel/Capture/Playback against cached Android36 and Flutter embedding APIs; no Android runtime execution.')
    args = parser.parse_args()
    java, jars = tooling()
    cache = Path(os.environ.get('GRADLE_USER_HOME', Path.home() / '.gradle')) / 'caches/modules-2/files-2.1'
    for module, version in [('junit/junit', '4.12'), ('org.hamcrest/hamcrest-core', '1.3')]:
        found = sorted((cache / module / version).glob('*/*.jar'))
        if len(found) != 1:
            raise ValueError('Existing JUnit prerequisite missing: ' + module)
        jars += found
    classpath = os.pathsep.join(map(str, jars))
    native = ROOT / 'android/app/src/main/kotlin/com/tarkilhk/wing'
    tests = ROOT / 'android/app/src/test/kotlin/com/tarkilhk/wing'
    with tempfile.TemporaryDirectory(prefix='wing-native-voice-jvm-') as scratch:
        destination = Path(scratch)
        owner = native / 'VoiceFileWork.kt'
        if args.red_growth:
            text = owner.read_text()
            start = text.index('    override fun read(file: File, check: () -> Unit): ByteArray {')
            end = text.index('    override fun delete(', start)
            text = text[:start] + '    override fun read(file: File, check: () -> Unit): ByteArray = file.readBytes()\n' + text[end:]
            owner = destination / 'VoiceFileWork.kt'
            owner.write_text(text)
        sources = [owner, native / 'VoiceOperation.kt', tests / 'VoiceFileWorkTest.kt', tests / 'VoiceOperationTest.kt']
        subprocess.run([str(java), '-cp', classpath, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', classpath, '-jvm-target', '17', '-d', scratch, *map(str, sources)], check=True)
        if args.compile_boundary:
            sdk = Path(os.environ.get('ANDROID_SDK_ROOT', os.environ.get('ANDROID_HOME', ROOT.parent / '.toolchain/android-sdk')))
            android = sdk / 'platforms/android-36/android.jar'
            embedding = sorted((cache / 'io.flutter/flutter_embedding_debug').glob('*/*/*.jar'))
            if not android.is_file() or len(embedding) != 1:
                raise ValueError('Existing Android36 and Flutter embedding caches required')
            boundary_cp = classpath + os.pathsep + str(android) + os.pathsep + str(embedding[0])
            boundary = [native / (name + '.kt') for name in ['VoiceChannel', 'VoiceCapture', 'VoicePlayback', 'VoiceFileWork', 'VoiceOperation']]
            subprocess.run([str(java), '-cp', classpath, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', boundary_cp, '-jvm-target', '17', '-d', str(destination / 'boundary'), *map(str, boundary)], check=True)
        result = subprocess.run([str(java), '-cp', scratch + os.pathsep + classpath, 'org.junit.runner.JUnitCore', 'com.tarkilhk.wing.VoiceFileWorkTest', 'com.tarkilhk.wing.VoiceOperationTest'])
        return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
