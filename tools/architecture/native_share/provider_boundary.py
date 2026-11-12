#!/usr/bin/env python3
"""Run the scoped Kotlin PSI boundary guard using the project's cached compiler.

Android dependency setup must have populated its pinned compiler; this never
installs/downloads tooling. Compile cache binds source, full jar hashes and JDK.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
SOURCE = Path(__file__).with_name('ProviderBoundaryGuard.kt')
QA_SOURCE = SOURCE.with_name('QaIsolationGuard.kt')


def kotlin_version():
    settings = (ROOT / 'android/settings.gradle.kts').read_text()
    versions = re.findall(
        r'^\s*id\("org\.jetbrains\.kotlin\.android"\)\s+version\s+"([^"\r\n]+)"\s+apply\s+false\s*$',
        settings, re.MULTILINE)
    if len(versions) != 1:
        raise ValueError('Expected one literal Android Kotlin plugin version')
    return versions[0]


def tooling():
    compiler_version = kotlin_version()
    cache = Path(os.environ.get('GRADLE_USER_HOME', Path.home() / '.gradle')) / 'caches/modules-2/files-2.1'
    jars = []
    for group, module, version in [
        ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', compiler_version),
        ('org.jetbrains.kotlin', 'kotlin-stdlib', compiler_version),
        ('org.jetbrains.kotlin', 'kotlin-script-runtime', compiler_version),
        ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
        ('org.jetbrains', 'annotations', '13.0'),
    ]:
        found = sorted((cache / group / module / version).glob('*/*.jar'))
        if len(found) != 1:
            raise ValueError(f'Cached Android compiler prerequisite missing: {module}/{version}')
        jars.append(found[0])
    java_home = Path(os.environ.get('JAVA_HOME', ROOT.parent / '.toolchain/jdk'))
    java = java_home / 'bin/java'
    if not java.is_file():
        raise ValueError('Existing project JDK required')
    return java, jars


def command(output=None):
    java, jars = tooling()
    version = subprocess.check_output([str(java), '-version'], stderr=subprocess.STDOUT)
    fingerprint = hashlib.sha256(SOURCE.read_bytes() + QA_SOURCE.read_bytes() + version + b''.join(
        hashlib.sha256(jar.read_bytes()).digest() for jar in jars)).hexdigest()
    destination = output or ROOT / 'build/native-share-guard' / fingerprint
    classpath = os.pathsep.join(map(str, jars))
    if not (destination / 'ProviderBoundaryGuardKt.class').is_file():
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(java), '-cp', classpath, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                        '-no-stdlib', '-no-reflect', '-classpath', classpath,
                        '-jvm-target', '17', '-d', str(destination), str(SOURCE), str(QA_SOURCE)], check=True)
    return [str(java), '-cp', str(destination) + os.pathsep + classpath, 'ProviderBoundaryGuardKt']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rule', choices=['all', 'provider-boundary', 'bounded-queues', 'qa-isolation'], default='all')
    parser.add_argument('--source', type=Path, default=ROOT / 'android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt')
    parser.add_argument('--gradle', type=Path, default=ROOT / 'android/app/build.gradle.kts')
    args = parser.parse_args()
    try:
        paths = [args.source]
        if args.source == parser.get_default("source"):
            native = ROOT / "android/app/src/main/kotlin/com/tarkilhk/wing"
            paths += [native / "BoundedProviderWork.kt", native / "BoundedIntakeQueue.kt"]
        if args.rule in {'all', 'qa-isolation'}:
            paths += [args.gradle]
        return subprocess.run(command() + ["--rule=" + args.rule] + list(map(str, paths))).returncode
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        diagnostic = 'NATIVE_SHARE_QA_ISOLATION' if args.rule == 'qa-isolation' else 'NATIVE_SHARE_PROVIDER_BOUNDARY'
        print(f'{diagnostic}: input error: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
