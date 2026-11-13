#!/usr/bin/env python3
"""Run native backup round trips through Android's actual share/save/open UI.

Requires a booted disposable emulator, Flutter/adb on PATH and SDK 36/JDK 17.
Uses synthetic credentials and isolated preferences/Keystore; contacts no server.
The temporary share receiver and every owned Downloads/cache file are removed.
"""

# These acceptance checks use assertions; optimization would remove their verdict.
if not __debug__:
    raise RuntimeError("Native acceptance requires Python assertions; remove -O/PYTHONOPTIMIZE")

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'tools/qa'))
from check_external_share import Device, HELPER, build_helper  # noqa: E402

PACKAGE = 'com.tarkilhk.wing.dev'
STAGE = '/sdcard/Android/data/' + PACKAGE + '/files/backup-qa-stage'
DOCUMENTS = {'com.google.android.documentsui', 'com.android.documentsui'}
STEPS = {'share-plain', 'pick-plain', 'share-encrypted',
         'pick-encrypted-wrong', 'pick-encrypted'}


class HierarchyUnavailable(RuntimeError):
    """The current Android transition has not yielded a fresh UI hierarchy."""


class Driver:
    def __init__(self, device, output, prefix):
        self.device = device
        self.output = output
        self.prefix = prefix
        self.dump_path = '/sdcard/' + prefix + 'ui.xml'
        self.exports = {}
        self.owned_names = set()
        self.cleanup_evidence = None
        self.process = None

    def nodes(self, label):
        captured = self.device.shell('uiautomator', 'dump', self.dump_path)
        if 'dumped to:' not in captured:
            raise HierarchyUnavailable(
                'Android UI capture failed; discard the previous hierarchy: ' + repr(captured))
        raw = self.device.shell('cat', self.dump_path)
        (self.output / (label + '.xml')).write_text(raw)
        nodes = list(ET.fromstring(raw).iter('node'))
        if any(n.get('resource-id') in {'android:id/aerr_close', 'android:id/aerr_wait'}
               for n in nodes):
            self.capture(label + '-android-error')
            raise RuntimeError('Android reported a crash/ANR; inspect captured evidence')
        return nodes

    def capture(self, label):
        (self.output / (label + '.png')).write_bytes(
            self.device.adb('exec-out', 'screencap', '-p', binary=True))

    def tap(self, node):
        bounds = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
        assert len(bounds) == 4, 'Missing native UI bounds'
        self.device.shell('input', 'tap', str((bounds[0] + bounds[2]) // 2),
                          str((bounds[1] + bounds[3]) // 2))

    def reveal_share_targets(self, nodes):
        """Expand the actual Android chooser, then scroll its visible target list."""
        chooser = [node for node in nodes
                   if node.get('package') == 'com.android.intentresolver']
        panel = next((node for node in chooser
                      if node.get('resource-id') == 'android:id/contentPanel'), None)
        if panel is None:
            return False

        def bounds(node):
            values = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
            assert len(values) == 4 and values[2] > values[0] and values[3] > values[1], \
                'Native chooser has no reachable bounds'
            return values

        left, top, right, bottom = bounds(panel)
        drag = next((node for node in chooser
                     if node.get('resource-id') == 'android:id/drag'), None)
        if drag is not None:
            x1, y1, x2, y2 = bounds(drag)
            start = (y1 + y2) // 2
            # A half-open sheet exposes suggested apps only. Drag its own
            # handle upward before trying to scroll the remaining destinations.
            if start > top + (bottom - top) // 4:
                self.device.shell('input', 'swipe', str((x1 + x2) // 2), str(start),
                                  str((x1 + x2) // 2), str(top + (bottom - top) // 8), '400')
                return True
        listing = next((node for node in chooser
                        if node.get('resource-id') == 'android:id/resolver_list'), None)
        if listing is None:
            return False
        left, top, right, bottom = bounds(listing)
        self.device.shell('input', 'swipe', str((left + right) // 2),
                          str(top + (bottom - top) * 4 // 5),
                          str((left + right) // 2), str(top + (bottom - top) // 5), '400')
        return True

    def status(self):
        status = self.device.preferences(HELPER, 'backup_save')
        name = status.get('pending_name')
        if name:
            assert name.startswith(self.prefix) and re.fullmatch(r'[a-zA-Z0-9.-]+', name)
            self.owned_names.add(name)
        assert not status.get('error'), 'Share save fixture failed: ' + str(status.get('error'))
        return status

    def drive(self, stage):
        label = stage.replace('-', '_')
        deadline = time.monotonic() + 70
        downloads = False
        drawer_open = False
        save_tapped = False
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('Flutter exited while waiting for ' + stage)
            status = self.status()
            previous_names = {entry['name'] for entry in self.exports.values()}
            if (stage.startswith('share-') and status.get('saved_name')
                    and status.get('saved_name') == status.get('pending_name')
                    and status['saved_name'] not in previous_names):
                name = status['saved_name']
                assert name.startswith(self.prefix)
                self.owned_names.add(name)
                path = '/sdcard/Download/' + name
                contents = self.device.adb('exec-out', 'cat', path, binary=True)
                source = name.removeprefix(self.prefix)
                original = self.device.private_read(PACKAGE, 'cache/share_plus/' + source)
                assert contents == original, 'Saved document differs from the shared cache bytes'
                parsed = json.loads(contents)
                encrypted = stage == 'share-encrypted'
                assert parsed['format'] == ('wing-config-encrypted' if encrypted else 'wing-config')
                if encrypted:
                    assert b'qa-api-key' not in contents, 'Encrypted export contains plaintext credentials'
                assert int(status['saved_bytes']) == len(contents)
                self.exports[stage.removeprefix('share-')] = {
                    'name': name, 'bytes': len(contents), 'format': parsed['format'],
                    'source': source,
                }
                self.capture(label + '_saved')
                return
            try:
                nodes = self.nodes(label)
            except HierarchyUnavailable as error:
                # A stage marker precedes the Android chooser transition. Never
                # read its previous dump; retry a fresh capture within this stage's
                # existing deadline, as the notification driver does.
                print(str(error), flush=True)
                time.sleep(.3)
                continue
            if stage.startswith('share-'):
                target = next((n for n in nodes if n.get('text') == 'Save Wing QA backup'
                               and n.get('package') == 'com.android.intentresolver'
                               and n.get('enabled') == 'true'), None)
                if target is not None:
                    self.capture(label + '_chooser')
                    self.tap(target)
                    time.sleep(.4)
                    continue
            external = [n for n in nodes if n.get('package') in DOCUMENTS]
            if not external:
                if stage.startswith('share-'):
                    self.reveal_share_targets(nodes)
                time.sleep(.3)
                continue
            if not downloads:
                if drawer_open:
                    root = next((n for n in external if n.get('text') == 'Downloads'
                                 and (n.get('clickable') == 'true'
                                      or n.get('resource-id') == 'android:id/title')), None)
                    if root is not None:
                        self.tap(root)
                        downloads = True
                        time.sleep(.4)
                        continue
                drawer = next((n for n in external if n.get('content-desc') == 'Show roots'), None)
                if drawer is not None:
                    self.tap(drawer)
                    drawer_open = True
                    time.sleep(.3)
                    continue
                # Some emulator DocumentsUI versions open directly at Downloads.
                if any(n.get('text') == 'Downloads' for n in external):
                    downloads = True
                else:
                    time.sleep(.3)
                    continue
            if stage.startswith('share-'):
                save = next((n for n in external if n.get('text', '').lower() == 'save'
                             and n.get('enabled') == 'true'), None)
                if save is not None and not save_tapped:
                    assert status.get('pending_name'), 'Save picker opened before fixture ownership'
                    self.capture(label + '_save_picker')
                    self.tap(save)
                    save_tapped = True
            else:
                kind = 'encrypted' if 'encrypted' in stage else 'plain'
                filename = self.exports[kind]['name']
                document = next((n for n in external if n.get('text') == filename
                                 or n.get('content-desc', '').startswith(filename + ', ')), None)
                if document is not None:
                    self.capture(label + '_open_picker')
                    self.tap(document)
                    return
                # Switch list/grid-independent sorting via DocumentsUI search.
                search = next((n for n in external if n.get('content-desc') == 'Search'), None)
                field = next((n for n in external if n.get('class') == 'android.widget.EditText'), None)
                if field is not None and field.get('text') != filename:
                    self.tap(field)
                    self.device.shell('input', 'text', filename)
                    self.device.shell('input', 'keyevent', '66')
                elif search is not None and field is None:
                    self.tap(search)
            time.sleep(.3)
        self.capture(label + '_failed')
        raise RuntimeError('Could not complete native dialog: ' + stage)

    def cleanup(self):
        # Only filenames carrying this run's random prefix can be removed.
        removed_cache = []
        for name in self.owned_names:
            assert name.startswith(self.prefix) and re.fullmatch(r'[a-zA-Z0-9.-]+', name)
            path = '/sdcard/Download/' + name
            self.device.shell('rm', '-f', path)
            assert not self.exists(path), 'Owned Downloads document remained: ' + name
            source = name.removeprefix(self.prefix)
            assert re.fullmatch(r'wing-config-[a-zA-Z0-9-]+\.json', source)
            for cache_path in ['cache/' + source, 'cache/share_plus/' + source]:
                if self.device.private_exists(PACKAGE, cache_path):
                    self.device.shell('run-as', PACKAGE, 'rm', '-f', cache_path)
                    removed_cache.append(cache_path)
                assert not self.device.private_exists(PACKAGE, cache_path), 'Owned cache export remained'
        picker_files = self.device.shell('run-as', PACKAGE, 'sh', '-c',
                                         'if [ -d cache/file_picker ]; then find cache/file_picker -type f; fi')
        for cache_path in picker_files.splitlines():
            if Path(cache_path).name not in self.owned_names:
                continue
            assert re.fullmatch(r'cache/file_picker/[0-9]+/[a-zA-Z0-9.-]+', cache_path), 'Unexpected owned picker cache path'
            self.device.shell('run-as', PACKAGE, 'rm', '-f', cache_path)
            assert not self.device.private_exists(PACKAGE, cache_path), 'Owned picker cache remained'
            removed_cache.append(cache_path)
            self.device.shell('run-as', PACKAGE, 'sh', '-c',
                              'rmdir ' + shlex.quote(str(Path(cache_path).parent)) + ' 2>/dev/null || true')
        remaining = self.device.shell('run-as', PACKAGE, 'sh', '-c',
                                      'if [ -d cache/file_picker ]; then find cache/file_picker -type f; fi')
        assert not any(Path(path).name in self.owned_names for path in remaining.splitlines()), 'Owned picker caches remained'
        self.device.shell('rm', '-f', self.dump_path)
        self.device.shell('rm', '-f', STAGE)
        assert not self.exists(STAGE), 'Owned stage marker remained'
        self.cleanup_evidence = {'downloads_removed': len(self.owned_names),
                                 'owned_plugin_cache_removed': removed_cache,
                                 'stage_removed': True}

    def exists(self, path):
        return self.device.shell('sh', '-c', 'if [ -e ' + shlex.quote(path)
                                 + ' ]; then echo yes; fi').strip() == 'yes'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--sdk', type=Path, default=Path(os.environ.get(
        'ANDROID_HOME', REPO.parent / '.toolchain/android-sdk')))
    parser.add_argument('--java-home', type=Path, default=Path(os.environ.get(
        'JAVA_HOME', REPO.parent / '.toolchain/jdk')))
    parser.add_argument('--output', type=Path, default=REPO / 'build/native-backup-review')
    parser.add_argument('--timeout', type=int, default=900)
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.device):
        parser.error('--device must be a disposable emulator, never a physical device')
    device = Device(args.device)
    assert device.shell('getprop', 'ro.kernel.qemu').strip() == '1', 'Device is not an emulator'
    assert not device.installed(HELPER), 'Previous share fixture is installed; finish its owned check first'
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    prefix = 'wing-backup-qa-' + uuid.uuid4().hex + '-'
    driver = Driver(device, output, prefix)
    assert not driver.exists(STAGE), 'A previous backup stage exists; clean up its owned test first'
    apk = build_helper(args.sdk.resolve(), args.java_home.resolve(), output)
    installed = False
    completed = set()
    cleanup_errors = []
    try:
        device.adb('install', '--no-incremental', str(apk))
        installed = True
        device.shell('am', 'start', '-W', '-n', HELPER + '/.BackupSaveActivity',
                     '--es', 'qa_prefix', prefix)
        assert driver.status().get('prefix') == prefix, 'Save fixture ownership was not configured'
        for package in [PACKAGE, *sorted(DOCUMENTS)]:
            device.shell('am', 'force-stop', package)
        command = ['flutter', 'test', '--no-pub', 'integration_test/config_backup_native_test.dart',
                   '-d', args.device, '--no-uninstall', '--reporter', 'expanded',
                   '--dart-define=CONFIG_BACKUP_NATIVE=true']
        with (output / 'flutter.log').open('w') as log:
            driver.process = subprocess.Popen(command, cwd=REPO, stdout=log,
                                              stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + args.timeout
            while driver.process.poll() is None:
                if time.monotonic() > deadline:
                    raise TimeoutError('Flutter/native backup run exceeded its bounded timeout')
                stage = device.shell('sh', '-c', 'cat ' + shlex.quote(STAGE)
                                     + ' 2>/dev/null || true').strip()
                if stage in STEPS and stage not in completed:
                    print('Driving Android UI: ' + stage, flush=True)
                    driver.drive(stage)
                    completed.add(stage)
                    print('PASS native UI: ' + stage, flush=True)
                time.sleep(.3)
            result = driver.process.wait()
        assert result == 0, 'Flutter backup assertions failed; inspect ' + str(output / 'flutter.log')
        assert completed == STEPS, 'Missing native stages: ' + str(sorted(STEPS - completed))
        for exported in driver.exports.values():
            assert not device.private_exists(PACKAGE, 'cache/' + exported['source']), 'Owned export cache remained'
        assert not driver.exists(STAGE), 'Integration test did not clean its stage marker'
        evidence = {'device': args.device, 'package': PACKAGE, 'native_steps': sorted(completed),
                    'exports': driver.exports, 'flutter_exit': result}
    finally:
        if driver.process is not None and driver.process.poll() is None:
            os.killpg(driver.process.pid, signal.SIGTERM)
            try:
                driver.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(driver.process.pid, signal.SIGKILL)
                driver.process.wait(timeout=10)
        if installed:
            try:
                # Retain partial-save ownership even if Flutter failed mid-dialog.
                driver.status()
            except Exception as error:
                cleanup_errors.append(str(error))
            try:
                driver.cleanup()
            except Exception as error:
                cleanup_errors.append(str(error))
            finally:
                device.adb('uninstall', HELPER)
                assert not device.installed(HELPER), 'Owned share helper remained installed'
        if cleanup_errors:
            raise RuntimeError('Cleanup/fixture failures: ' + '; '.join(cleanup_errors))
    evidence['cleanup'] = driver.cleanup_evidence
    evidence['cleanup']['helper_uninstalled'] = True
    (output / 'acceptance.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('PASS: native plain Merge, encrypted Replace and wrong-passphrase backup round trips; owned files/helper cleaned', flush=True)


if __name__ == '__main__':
    main()
