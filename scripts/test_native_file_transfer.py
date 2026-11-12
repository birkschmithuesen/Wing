#!/usr/bin/env python3
"""Exercise real Android file/share dialogs on a disposable, already booted AVD.

Usage: python3 scripts/test_native_file_transfer.py --device emulator-5580
Requires Flutter and adb on PATH. Screenshots and logs go to --output.
Never targets a physical device or connects to a Hermes server.
"""

import argparse
import json
import os
import pathlib
import re
import shlex
import signal
import struct
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET
import zlib

REPO = pathlib.Path(__file__).resolve().parents[1]
STEPS = {'backup-select', 'backup-cancel', 'document-select',
         'photo-select', 'document-cancel', 'share-cancel'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('/tmp/wing-file-transfer'))
    parser.add_argument('--timeout', type=int, default=900,
                        help='Maximum seconds for the Flutter suite, including its build')
    parser.add_argument('--verbose', action='store_true',
                        help='Include Flutter VM discovery and integration-runner diagnostics')
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.device):
        parser.error('Use a disposable Android emulator, not a physical device.')
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    suite_deadline = None
    process = None
    dump_path = '/sdcard/wing-file-transfer-' + uuid.uuid4().hex + '.xml'

    def remaining(maximum=30):
        if suite_deadline is None:
            return maximum
        duration = suite_deadline - time.monotonic()
        if duration <= 0:
            raise TimeoutError('Flutter/native file transfer exceeded its bounded timeout')
        return min(maximum, duration)

    def adb(*command, binary=False):
        return subprocess.check_output(
            ['adb', '-s', args.device, *command], text=not binary, timeout=remaining()
        )

    def exists(path):
        script = 'if [ -e ' + shlex.quote(path) + ' ]; then echo yes; fi'
        return adb('shell', shlex.join(['sh', '-c', script])).strip() == 'yes'

    def tap(node):
        left, top, right, bottom = map(int, re.findall(r'\d+', node.get('bounds')))
        adb('shell', 'input', 'tap', str((left + right) // 2), str((top + bottom) // 2))

    def capture(label):
        (args.output / f'{label}.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))

    def drive(marker):
        filename = 'wing-native-probe.png' if marker == 'photo-select' else 'wing-native-probe.json'
        deadline = time.monotonic() + remaining(50)
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('Flutter exited while waiting for native dialog: ' + marker)
            # Android can return success with no hierarchy while its native
            # picker is opening. Wait within this step's existing deadline and
            # remove the previous capture so it cannot be mistaken for readiness.
            adb('shell', 'rm', '-f', dump_path)
            adb('shell', 'uiautomator', 'dump', dump_path)
            if not exists(dump_path):
                time.sleep(0.5)
                continue
            xml = adb('shell', 'cat', dump_path)
            (args.output / f'{marker}.xml').write_text(xml)
            nodes = list(ET.fromstring(xml).iter('node'))
            if any(n.get('resource-id') in {'android:id/aerr_close', 'android:id/aerr_wait'} for n in nodes):
                capture(f'{marker}-anr')
                raise RuntimeError('Android reported an ANR; inspect the captured dialog before retrying.')
            external = [n for n in nodes if n.get('package') in {
                'com.google.android.documentsui', 'com.android.documentsui',
                'com.android.intentresolver', 'com.google.android.providers.media.module',
                'com.android.providers.media.module', 'com.google.android.photopicker', 'android',
            }]
            if not external:
                time.sleep(0.5)
                continue
            if marker.endswith('cancel'):
                if marker == 'share-cancel' and not any(
                    'wing-config-' in n.get('text', '') or 'Sharing' in n.get('text', '')
                    or 'share' in n.get('resource-id', '').lower() for n in external
                ):
                    time.sleep(0.5)
                    continue
                capture(marker)
                adb('shell', 'input', 'keyevent', '4')
                return
            match = next((n for n in external if n.get('text') == filename
                          or n.get('content-desc', '').startswith(filename + ', ')), None)
            if match is not None:
                capture(marker)
                tap(match)
                return
            if marker == 'photo-select':
                browse = next((n for n in external if n.get('text', '').startswith('Browse')), None)
                more = next((n for n in external if n.get('content-desc') == 'More'), None)
                if browse is not None or more is not None:
                    tap(browse if browse is not None else more)
                    time.sleep(0.5)
                    continue
            # Images may first open the Android source chooser.
            choice = next((n for n in external if n.get('text') in {'Files', 'Downloads'}), None)
            if choice is not None:
                tap(choice)
            else:
                drawer = next((n for n in external if n.get('content-desc') == 'Show roots'), None)
                if drawer is not None:
                    tap(drawer)
            time.sleep(0.5)
        capture(f'{marker}-failed')
        raise RuntimeError(f'Could not complete native dialog: {marker}')

    probe = args.output / 'wing-native-probe.json'
    probe.write_text('{"probe":"Wing native file transfer — ✓"}', encoding='utf-8')
    png = args.output / 'wing-native-probe.png'

    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))

    png.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 32, 32, 8, 2, 0, 0, 0))
                   + chunk(b'IDAT', zlib.compress((b'\x00' + b'\x20\x90\xc0' * 32) * 32)) + chunk(b'IEND', b''))
    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('Target is not an emulator; refusing fixture writes')
    remote_paths = ['/sdcard/Download/' + path.name for path in (probe, png)]
    # The Dart assertions require these exact names. Refuse to overwrite existing
    # documents, then track every attempted write, including partial adb pushes.
    for remote in remote_paths:
        if exists(remote):
            raise RuntimeError('Native probe already exists; refusing to overwrite: ' + remote)
    owned_paths = []
    command = ['flutter', 'test', 'integration_test/file_transfer_native_test.dart',
               '-d', args.device, '--reporter', 'expanded', '--no-uninstall', '--no-pub']
    if args.verbose:
        command.append('--verbose')
    completed = set()
    try:
        for path, remote in zip((probe, png), remote_paths):
            owned_paths.append(remote)
            adb('push', str(path), remote)
            adb('shell', 'am', 'broadcast', '-a', 'android.intent.action.MEDIA_SCANNER_SCAN_FILE',
                '-d', 'file://' + remote)
        # Clear activities left by an interrupted run, only on the requested AVD.
        for package in ['com.tarkilhk.wing.dev', 'com.google.android.documentsui',
                        'com.android.documentsui', 'com.google.android.photopicker']:
            adb('shell', 'am', 'force-stop', package)
        suite_deadline = time.monotonic() + args.timeout
        transcript = ''
        log_path = args.output / 'flutter.log'
        # Read a regular log file rather than a blocking stdout pipe so silence
        # during a stalled build or native plugin cannot defeat the deadline.
        with log_path.open('w') as log, log_path.open() as reader:
            process = subprocess.Popen(command, cwd=REPO, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            while True:
                remaining()
                exited = process.poll() is not None
                chunk_text = reader.read()
                if chunk_text:
                    print(chunk_text, end='', flush=True)
                    transcript += chunk_text
                    for marker in re.findall(r'FILE_TRANSFER:([a-z-]+)(?=[\r\n])', transcript):
                        if marker not in STEPS:
                            raise RuntimeError('Unexpected native file transfer stage: ' + marker)
                        if marker not in completed:
                            drive(marker)
                            completed.add(marker)
                if exited:
                    break
                time.sleep(.15)
        result = process.wait(timeout=5)
        if result:
            raise RuntimeError('Flutter file transfer assertions failed; inspect ' + str(log_path))
        if completed != STEPS:
            raise RuntimeError('Missing native stages: ' + str(sorted(STEPS - completed)))
        if 'All tests passed!' not in transcript:
            raise RuntimeError('Flutter did not report successful file transfer assertions')
    finally:
        suite_deadline = None
        if process is not None:
            # Kill the group even if Flutter exited: Gradle or a native-test
            # subprocess may outlive the original process after a failed run.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=10)
            # An already exited parent cannot be waited on to observe surviving
            # descendants. Ensure none in its owned process group remain.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        cleanup_errors = []
        for remote in [*owned_paths, dump_path]:
            try:
                adb('shell', 'rm', '-f', remote)
                if exists(remote):
                    raise RuntimeError('Owned native fixture remained: ' + remote)
            except Exception as error:
                cleanup_errors.append(str(error))
        if cleanup_errors:
            raise RuntimeError('Native fixture cleanup failed: ' + '; '.join(cleanup_errors))
    (args.output / 'acceptance.json').write_text(json.dumps({
        'device': args.device, 'package': 'com.tarkilhk.wing.dev',
        'backend': 'none; offline fixtures', 'status': 'passed',
        'native_steps': sorted(completed), 'flutter_exit': result,
        'owned_device_files_removed': True,
    }, indent=2) + '\n')
    print('PASS: native file/photo selection, cancellation and share sheet; owned probe files removed')


if __name__ == '__main__':
    main()
