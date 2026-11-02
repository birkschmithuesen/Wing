#!/usr/bin/env python3
"""Install CI SDK packages with bounded retries and retained failure evidence."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import zipfile


def archive_details(path, sdk):
    record = {'path': str(path.relative_to(sdk))}
    try:
        record['bytes'] = path.stat().st_size
        # Match the checksum published in Google's SDK repository metadata.
        digest = hashlib.sha1()
        with path.open('rb') as stream:
            record['prefix_hex'] = stream.read(128).hex()
            stream.seek(0)
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        record['sha1'] = digest.hexdigest()
        try:
            with zipfile.ZipFile(path):
                record['valid_zip'] = True
        except zipfile.BadZipFile as error:
            record['valid_zip'] = False
            record['zip_error'] = str(error)
    except OSError as error:
        record['diagnostic_error'] = str(error)
    return record


def install(packages, output):
    sdk = Path(os.environ['ANDROID_HOME'])
    manager = sdk / 'cmdline-tools/latest/bin/sdkmanager'
    output.mkdir(parents=True, exist_ok=True)
    properties = manager.parent.parent / 'source.properties'
    context = {
        'packages': packages,
        'sdkmanager': str(manager),
        'sdk_tools': properties.read_text() if properties.exists() else None,
        'java_home': os.environ.get('JAVA_HOME'),
        'runner_image': os.environ.get('ImageVersion'),
        'revision': os.environ.get('GITHUB_SHA'),
        'run_id': os.environ.get('GITHUB_RUN_ID'),
    }
    (output / 'context.json').write_text(json.dumps(context, indent=2) + '\n')
    for attempt in range(1, 4):
        print(f'Android SDK install attempt {attempt}/3; diagnostics: {output}', flush=True)
        log_path = output / f'attempt-{attempt}.log'
        started = time.time()
        with log_path.open('w') as log:
            try:
                result = subprocess.run([str(manager), '--verbose', *packages],
                                        stdout=log, stderr=subprocess.STDOUT)
                code = result.returncode
            except OSError as error:
                log.write(str(error) + '\n')
                code = 1
        print(log_path.read_text(errors='replace'), end='', flush=True)
        report = {'exit_code': code, 'started_at': started,
                  'elapsed_seconds': round(time.time() - started, 2),
                  'disk_free_bytes': shutil.disk_usage(sdk).free, 'archives': []}
        if code:
            # Capture before the next invocation checks/replaces the previous ZIP.
            report['archives'] = [archive_details(path, sdk)
                                  for path in sorted((sdk / '.temp').rglob('*.zip'))]
        (output / f'attempt-{attempt}.json').write_text(json.dumps(report, indent=2) + '\n')
        if code == 0:
            return 0
        print(f'Android SDK install failed (exit {code}); evidence saved in {output}', flush=True)
        if attempt < 3:
            time.sleep(5 * attempt)
    return code


def main(packages):
    # Release tooling can live outside the selected build source. Read the same
    # source-owned version as Gradle, before a build can trigger implicit setup.
    properties = Path('android/gradle.properties').read_text()
    versions = [line.partition('=')[2].strip() for line in properties.splitlines()
                if line.partition('=')[0].strip() == 'wing.ndkVersion']
    if len(versions) != 1 or not re.fullmatch(r'\d+\.\d+\.\d+', versions[0]):
        raise ValueError('Selected source must declare one valid wing.ndkVersion')
    return install([*packages, 'ndk;' + versions[0]], Path('build/sdk-install'))


if __name__ == '__main__':
    if not sys.argv[1:]:
        sys.exit('Usage: install_android_sdk.py <sdk-package> [...]')
    sys.exit(main(sys.argv[1:]))
