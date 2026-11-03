#!/usr/bin/env python3
"""Install CI SDK packages with bounded retries and retained failure evidence."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.test import stop_process_group  # noqa: E402

# Three attempts plus cleanup and diagnostics fit within CI's 15-minute step.
ATTEMPT_TIMEOUT_SECONDS = 240


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
        report_path = output / f'attempt-{attempt}.json'
        report = {'exit_code': None, 'started_at': started,
                  'timeout_seconds': ATTEMPT_TIMEOUT_SECONDS, 'timed_out': False}
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        code = None
        try:
            with log_path.open('w') as log:
                log.write(f'SDK attempt {attempt}; deadline {ATTEMPT_TIMEOUT_SECONDS}s\n')
                log.flush()
                process = None
                try:
                    process = subprocess.Popen([str(manager), '--verbose', *packages],
                                               stdout=log, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                    report['pid'] = process.pid
                    report_path.write_text(json.dumps(report, indent=2) + '\n')
                    try:
                        code = process.wait(timeout=ATTEMPT_TIMEOUT_SECONDS)
                    except subprocess.TimeoutExpired:
                        code = 124
                        report['timed_out'] = True
                        log.write('SDK manager exceeded the attempt deadline.\n')
                except OSError as error:
                    log.write(str(error) + '\n')
                    code = 1
                finally:
                    if process is not None:
                        stop_process_group(process)
        finally:
            report.update(exit_code=code, interrupted=code is None,
                          elapsed_seconds=round(time.time() - started, 2),
                          disk_free_bytes=shutil.disk_usage(sdk).free, archives=[])
            if code != 0:
                # Capture before the next invocation checks/replaces the previous ZIP.
                report['archives'] = [archive_details(path, sdk)
                                      for path in sorted((sdk / '.temp').rglob('*.zip'))]
            report_path.write_text(json.dumps(report, indent=2) + '\n')
        print(log_path.read_text(errors='replace'), end='', flush=True)
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
    def cancelled(signum, frame):
        raise KeyboardInterrupt('SDK installation cancelled')

    signal.signal(signal.SIGTERM, cancelled)
    sys.exit(main(sys.argv[1:]))
