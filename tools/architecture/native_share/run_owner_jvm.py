#!/usr/bin/env python3
"""Compile/run only the two Android-independent owners and their JUnit tests.

Uses existing pinned Kotlin/JDK/JUnit caches. No Gradle/Flutter/network/device.
"""
import os
from pathlib import Path
import subprocess
import tempfile
from provider_boundary import ROOT, tooling


def main():
    java, jars = tooling()
    cache = Path(os.environ.get('GRADLE_USER_HOME', Path.home() / '.gradle')) / 'caches/modules-2/files-2.1'
    for module, version in [('junit/junit', '4.12'), ('org.hamcrest/hamcrest-core', '1.3')]:
        found = sorted((cache / module / version).glob('*/*.jar'))
        if len(found) != 1:
            raise ValueError(f'Existing JUnit prerequisite missing: {module}/{version}')
        jars += found
    classpath = os.pathsep.join(map(str, jars))
    sources = [ROOT / f'android/app/src/{area}/kotlin/com/tarkilhk/wing/{name}.kt'
               for area, name in [('main', 'BoundedProviderWork'), ('main', 'BoundedIntakeQueue'),
                                  ('test', 'BoundedProviderWorkTest'), ('test', 'BoundedIntakeQueueTest')]]
    with tempfile.TemporaryDirectory(prefix='wing-native-owner-jvm-') as directory:
        subprocess.run([str(java), '-cp', classpath, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                        '-no-stdlib', '-no-reflect', '-classpath', classpath, '-jvm-target', '17',
                        '-d', directory, *map(str, sources)], check=True)
        subprocess.run([str(java), '-cp', directory + os.pathsep + classpath, 'org.junit.runner.JUnitCore',
                        'com.tarkilhk.wing.BoundedProviderWorkTest',
                        'com.tarkilhk.wing.BoundedIntakeQueueTest'], check=True)


if __name__ == '__main__':
    main()
