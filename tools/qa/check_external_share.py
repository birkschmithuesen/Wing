#!/usr/bin/env python3
"""Check production inbound URI handling with another UID on a disposable emulator.

Build/install/launch notification_revamp_device.dart first, or the opt-in
share_intake_device.dart for --provider-faults. This check sends no Hermes
messages. It builds a standalone SDK-only sender/provider APK, inspects
only synthetic intake bytes, and removes its helper and owned files afterward.
"""
# Optimization would remove the verdict assertions below.
if not __debug__:
    raise RuntimeError("Native acceptance requires Python assertions; remove -O/PYTHONOPTIMIZE")


import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time
import uuid
import urllib.request
import xml.etree.ElementTree as ET
import zipfile


PACKAGE = 'com.tarkilhk.wing.notificationqa'
HELPER = 'com.tarkilhk.wing.shareqa.fixture'
CONTENTS = 'Wing external share boundary — ✓\n'.encode()
MARKER = 'cache/delivered_outputs/share-boundary-marker.txt'
PREFERENCES = 'shared_prefs/pending_share_intake.xml'
REPO = Path(__file__).resolve().parents[2]


def focused_window_component(window_dump):
    """Return the current input window component, never the focused app.

    API36 prints mCurrentFocus in the display section, so callers must request
    the complete `dumpsys window` output. ANR/system windows have no component.
    """
    field = re.search(r'^\s*mCurrentFocus=([^\n]*)$', window_dump, re.MULTILINE)
    if not field:
        return None
    match = re.search(r' ([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)(?:[ }]|$)', field.group(1))
    return match.group(1) if match else None


def camera_components(text):
    return set(re.findall(r'^\s*([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)\s*$', text, re.MULTILINE))


def host_has_saved_stopped_state(activity_dump):
    """Require the owned activity's actual saved state before process death.

    A launched camera can be active before Android finishes stopping/saving its
    caller. Killing at that point removes the caller, so no ActivityResult can
    restore it. Inspect the exact history record rather than elapsed time.
    """
    records = re.split(r'^\s*\* Hist\s+#\d+: ', activity_dump, flags=re.MULTILINE)
    component = PACKAGE + '/com.tarkilhk.wing.MainActivity'
    owned = [record for record in records[1:]
             if re.match(r'ActivityRecord\{[^\n]* u0 ' + re.escape(component)
                         + r' t\d+\}', record)]
    return (len(owned) == 1
            and re.search(r'^\s*mHaveState=true mIcicle=Bundle\[', owned[0], re.MULTILINE)
            is not None
            and re.search(r'^\s*state=STOPPED\b', owned[0], re.MULTILINE) is not None)


def retire_owned_host(device, pid):
    # am kill can retain a stopped activity's process while a camera/provider
    # binding raises its importance. SIGKILL from the app's own UID models
    # process death without force-stop's suppression of ActivityResult delivery.
    if not re.fullmatch(r'[1-9][0-9]*', pid):
        raise ValueError('Expected one captured owned host PID')
    process = device.shell('run-as', PACKAGE, 'cat', '/proc/' + pid + '/cmdline')
    if process.rstrip('\x00') != PACKAGE:
        raise ValueError('Captured PID is not the isolated QA host')
    device.shell('run-as', PACKAGE, 'kill', '-9', pid)


def provider_released(device, previous):
    # A manifest receiver wakes an Android cached/frozen helper. The receiver
    # ignores this action: it neither cancels I/O nor changes camera state.
    # Without the wakeup, a timed-out remote Binder caller may leave this helper
    # frozen before its 45-second producer can actually return.
    device.shell('am', 'broadcast', '-n', HELPER + '/.CameraCommandReceiver',
                 '-a', HELPER + '.PROBE')
    return int(device.preferences(HELPER, 'probe').get('released', '0')) > previous


def execute(command, **kwargs):
    return subprocess.run([str(part) for part in command], check=True, timeout=90, **kwargs)


def build_helper(sdk, java_home, output):
    tools = sdk / 'build-tools/36.0.0'
    android_jar = sdk / 'platforms/android-36/android.jar'
    fixture = REPO / 'integration_test/fixtures/external_share'
    for path in [android_jar, *[tools / name for name in ('aapt2', 'd8', 'zipalign', 'apksigner')],
                 *[java_home / 'bin' / name for name in ('java', 'javac', 'keytool')]]:
        if not path.is_file():
            raise RuntimeError(f'Required SDK/JDK tool is missing: {path}')
    env = dict(os.environ, JAVA_HOME=str(java_home))
    env['PATH'] = str(java_home / 'bin') + os.pathsep + env.get('PATH', '')
    output.mkdir(parents=True, exist_ok=True)
    apk = output / 'external-share-fixture.apk'
    with tempfile.TemporaryDirectory(prefix='external-share-build-', dir=output) as temporary:
        scratch = Path(temporary)
        classes = scratch / 'classes'
        dex = scratch / 'dex'
        classes.mkdir()
        dex.mkdir()
        execute([java_home / 'bin/javac', '-encoding', 'UTF-8', '-source', '8', '-target', '8',
                 '-classpath', android_jar, '-d', classes, *sorted(fixture.glob('*.java'))], env=env)
        jar = scratch / 'classes.jar'
        with zipfile.ZipFile(jar, 'w') as archive:
            for path in classes.rglob('*.class'):
                archive.write(path, path.relative_to(classes))
        execute([tools / 'd8', '--lib', android_jar, '--min-api', '24', '--output', dex, jar], env=env)
        unsigned = scratch / 'unsigned.apk'
        execute([tools / 'aapt2', 'link', '-I', android_jar, '--manifest', fixture / 'AndroidManifest.xml',
                 '--min-sdk-version', '24', '--target-sdk-version', '36', '--version-code', '1',
                 '--version-name', '1', '-o', unsigned], env=env)
        with zipfile.ZipFile(unsigned, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in dex.glob('*.dex'):
                archive.write(path, path.name)
        aligned = scratch / 'aligned.apk'
        execute([tools / 'zipalign', '-f', '4', unsigned, aligned], env=env)
        key = scratch / 'fixture.jks'
        password = uuid.uuid4().hex
        execute([java_home / 'bin/keytool', '-genkeypair', '-keystore', key, '-storepass', password,
                 '-keypass', password, '-alias', 'fixture', '-dname', 'CN=Disposable Wing QA',
                 '-keyalg', 'RSA', '-keysize', '2048', '-validity', '2', '-noprompt'], env=env,
                stdout=subprocess.DEVNULL)
        execute([tools / 'apksigner', 'sign', '--ks', key, '--ks-key-alias', 'fixture',
                 '--ks-pass', 'pass:' + password, '--key-pass', 'pass:' + password,
                 '--out', apk, aligned], env=env)
        execute([tools / 'apksigner', 'verify', apk], env=env)
    return apk


class Device:
    def __init__(self, serial):
        self.serial = serial

    def adb(self, *parts, binary=False, input_bytes=None):
        result = execute(['adb', '-s', self.serial, *parts], capture_output=True,
                         input=input_bytes)
        return result.stdout if binary else result.stdout.decode()

    def shell(self, *parts):
        return self.adb('shell', shlex.join(parts))

    def host_pid(self):
        try:
            return self.shell('pidof', PACKAGE).strip()
        except subprocess.CalledProcessError as error:
            if error.returncode == 1 and not error.stdout and not error.stderr:
                return ''  # pidof's expected process-absent result.
            raise

    def private_read(self, package, path):
        return self.adb('exec-out', 'run-as', package, 'cat', path, binary=True)

    def installed(self, package):
        return 'package:' + package in self.shell('pm', 'list', 'packages', package).splitlines()

    def private_exists(self, package, path):
        return self.shell('run-as', package, 'sh', '-c',
                          'if [ -e ' + shlex.quote(path) + ' ]; then echo yes; fi').strip() == 'yes'

    def private_write(self, path, data):
        # run-as receives its own shell script as one argument; stdin is bytes.
        command = shlex.join(['run-as', PACKAGE, 'sh', '-c', 'cat > ' + shlex.quote(path)])
        self.adb('shell', command, input_bytes=data)

    def preferences(self, package, name):
        path = 'shared_prefs/' + name + '.xml'
        if not self.private_exists(package, path):
            return {}
        deadline = time.monotonic() + 5
        while True:
            try:
                root = ET.fromstring(self.private_read(package, path))
            except ET.ParseError:
                # SharedPreferences can expose an empty/partial file during a
                # commit. Observe a complete snapshot before evaluating state;
                # persistent corruption and transport failures still fail.
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise
                time.sleep(min(.1, remaining))
            else:
                return {entry.get('name'): entry.text if entry.tag == 'string' else entry.get('value')
                        for entry in root}

    def intake(self):
        preferences = self.preferences(PACKAGE, 'pending_share_intake')
        queue = json.loads(preferences.get('queue', '[]'))
        files = self.shell('run-as', PACKAGE, 'sh', '-c',
                           'if [ -d files/pending_intake ]; then find files/pending_intake -type f; fi')
        return queue, sorted(files.splitlines()), preferences.get('pending_camera')

    def observations(self):
        prefs = self.preferences(HELPER, 'probe')
        return {operation: int(prefs.get(operation, '0')) for operation in ('type', 'query', 'open')}


def until(check, message, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.2)
    raise AssertionError(message)


def run(serial, apk, output, provider_faults=False):
    if not re.fullmatch(r'emulator-\d+', serial):
        raise RuntimeError('Use a disposable emulator, never a physical device.')
    device = Device(serial)
    assert device.shell('getprop', 'ro.kernel.qemu').strip() == '1', 'Device is not an emulator'
    assert device.shell('am', 'get-current-user').strip() == '0', 'Use the disposable emulator owner user0'
    assert device.installed(PACKAGE), 'Install the isolated notification QA target first'
    assert not device.installed(HELPER), 'Remove the previous owned share fixture first'
    # The native QA entry point is intentionally kept running: warm SEND reaches
    # MainActivity's real intake path even though this target has no share UI.
    pid = device.host_pid()
    assert pid, 'Launch notification_revamp_device.dart before running this check'
    initial = device.intake()
    assert initial == ([], [], None), 'QA intake must be empty, with no pending camera or files'
    initial_directories = device.shell('run-as', PACKAGE, 'sh', '-c',
                                      'if [ -d files/pending_intake ]; then find files/pending_intake -mindepth 1; fi')
    assert not initial_directories.strip(), 'QA intake directory must have no previous fixture entries'
    staging_existed = device.private_exists(PACKAGE, 'cache/provider_share_staging')
    stages = device.shell('run-as', PACKAGE, 'sh', '-c',
                          'if [ -d cache/provider_share_staging ]; then find cache/provider_share_staging -mindepth 1; fi')
    assert not stages.strip(), 'Previous provider stages must be cleared before this owned fixture'
    assert not device.private_exists(PACKAGE, MARKER), 'Owned marker path already exists'
    prefs_existed = device.private_exists(PACKAGE, PREFERENCES)
    previous_prefs = device.private_read(PACKAGE, PREFERENCES) if prefs_existed else None
    intake_existed = device.private_exists(PACKAGE, 'files/pending_intake')
    marker_directory_existed = device.private_exists(PACKAGE, 'cache/delivered_outputs')
    installed = False
    marker_created = False
    forwarded = False
    evidence = []
    try:
        device.adb('install', '--no-incremental', apk.as_posix())
        installed = True
        if provider_faults:
            handlers = camera_components(device.shell('cmd', 'package', 'query-activities', '--components',
                                                       '-a', 'android.media.action.IMAGE_CAPTURE', '-p', HELPER))
            assert handlers == {HELPER + '/.ControlledCameraActivity'}, 'Explicit QA camera target must resolve'
        assert device.shell('run-as', HELPER, 'id', '-u').strip() != device.shell('run-as', PACKAGE, 'id', '-u').strip(), 'Provider must run under a foreign UID'
        device.shell('run-as', PACKAGE, 'mkdir', '-p', 'cache/delivered_outputs')
        device.private_write(MARKER, b'Owned Wing private-file rejection marker\n')
        marker_created = True

        def unchanged(label, previous_intake, previous_counts):
            # Native intake is asynchronous. Repeated checks also catch deferred
            # copies; the subsequent granted case proves the same path executes.
            for _ in range(6):
                time.sleep(.35)
                assert device.intake() == previous_intake, label + ': intake changed'
                assert device.observations() == previous_counts, label + ': provider was touched'
                assert device.host_pid() == pid, label + ': Wing crashed/restarted'
            evidence.append({'scenario': label, 'provider': previous_counts, 'accepted': False})
            print('PASS: ' + label + ' rejected before provider access or intake changes', flush=True)

        def send(mode):
            nonce = uuid.uuid4().hex
            device.shell('am', 'start', '-W', '-n', HELPER + '/.ShareSenderActivity',
                         '--es', 'mode', mode, '--es', 'nonce', nonce)
            def sent():
                status = device.preferences(HELPER, 'sender')
                assert not status.get('error'), 'Android rejected fixture dispatch: ' + str(status)
                return status.get('sent') == mode + ':' + nonce
            until(sent, 'Fixture did not dispatch ' + mode)

        counts = device.observations()
        for label, uri in [
            ('file URI', 'file:///data/user/0/' + PACKAGE + '/' + MARKER),
            ('own provider URI', 'content://' + PACKAGE + '.fileprovider/delivered_outputs/share-boundary-marker.txt'),
        ]:
            device.shell('am', 'start', '-W', '-n', PACKAGE + '/com.tarkilhk.wing.MainActivity',
                         '-a', 'android.intent.action.SEND', '-t', 'text/plain',
                         '--eu', 'android.intent.extra.STREAM', uri)
            unchanged(label, initial, counts)

        send('no-grant')
        unchanged('foreign URI without read grant', initial, counts)
        send('mixed')
        unchanged('granted foreign plus own-provider batch', initial, counts)

        send('grant')
        accepted = until(lambda: device.intake()[0], 'Granted foreign URI was not imported')
        assert len(accepted) == 1 and len(accepted[0]['files']) == 1, 'Unexpected intake records/files'
        incoming = accepted[0]['files'][0]
        assert incoming['name'] == 'wing-share-probe.txt'
        assert incoming['mediaType'] == 'text/plain'
        assert incoming['byteLength'] == len(CONTENTS)
        assert device.private_read(PACKAGE, incoming['path']) == CONTENTS, 'Imported bytes differ'
        counts = device.observations()
        assert counts['query'] > 0 and counts['open'] == 1 and counts['type'] > 0, counts
        evidence.append({'scenario': 'granted foreign URI', 'provider': counts,
                         'accepted': True, 'bytes': len(CONTENTS)})
        assert device.private_read(PACKAGE, MARKER) == b'Owned Wing private-file rejection marker\n'
        print('PASS: granted foreign URI imports exact UTF-8 bytes through the real provider', flush=True)
        if provider_faults:
            assert 'tcp:19307' not in device.adb('forward', '--list'), 'QA bridge port already forwarded'
            device.adb('forward', 'tcp:19307', 'tcp:19307')
            forwarded = True
            local_requests = []
            camera_cancellations = []

            def bridge(path):
                request_boot_ms = int(float(device.shell('cat', '/proc/uptime').split()[0]) * 1000)
                started = time.monotonic()
                with urllib.request.urlopen('http://127.0.0.1:19307' + path, timeout=3) as response:
                    value = json.load(response)
                elapsed = time.monotonic() - started
                local_requests.append({'path': path.split('?', 1)[0],
                                       'requested_at_boot_ms': request_boot_ms,
                                       'response_seconds': elapsed})
                assert elapsed < 3, 'Local channel command waited behind provider work'
                return value

            def intake_snapshot(boundary, phase):
                current = device.intake()
                stages = device.shell('run-as', PACKAGE, 'sh', '-c',
                                      'if [ -d cache/provider_share_staging ]; then find cache/provider_share_staging -type f; fi')
                # Only this owned synthetic fixture's queue/path/counter data;
                # capture before finally restores preferences and removes files.
                snapshot = {'boundary': boundary, 'phase': phase,
                            'initial_intake': initial, 'current_intake': current,
                            'staging_files': sorted(stages.splitlines()),
                            'intake_entries': device.shell('run-as', PACKAGE, 'sh', '-c',
                                'if [ -d files/pending_intake ]; then find files/pending_intake -mindepth 1; fi').splitlines(),
                            'foreground_activity': foreground_activity(),
                            'focused_window': focused_activity(),
                            'sender_observations': device.preferences(HELPER, 'sender'),
                            'local_requests': local_requests[-8:],
                            'camera_cancellations': camera_cancellations[-12:],
                            'provider_counters': device.preferences(HELPER, 'probe'),
                            'controlled_camera': device.preferences(HELPER, 'controlled_camera')}
                (output / ('held-' + boundary + '-' + phase + '.json')).write_text(
                    json.dumps(snapshot, indent=2) + '\n')
                return current

            def foreground_activity():
                activities = device.shell('dumpsys', 'activity', 'activities')
                match = re.search(r'(?:mResumedActivity:|topResumedActivity=).*? ([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)', activities)
                if not match:
                    (output / 'foreground-resume-fields.txt').write_text('\n'.join(
                        line for line in activities.splitlines()
                        if 'ResumedActivity' in line or 'mFocusedApp' in line) + '\n')
                return match.group(1) if match else None

            def focused_activity():
                windows = device.shell('dumpsys', 'window')
                component = focused_window_component(windows)
                if component is None:
                    (output / 'focused-window-fields.txt').write_text('\n'.join(
                        line for line in windows.splitlines()
                        if 'mCurrentFocus=' in line or 'mFocusedWindow=' in line or 'mFocusedApp=' in line) + '\n')
                return component

            camera_nonce = uuid.uuid4().hex

            def camera_command(command, mode=None):
                before = int(device.preferences(HELPER, 'controlled_camera').get('command_seq', '0'))
                arguments = ['am', 'broadcast', '--receiver-foreground', '-n',
                             HELPER + '/.CameraCommandReceiver', '-a', HELPER + '.CAMERA_COMMAND',
                             '--es', 'command', command, '--es', 'nonce', camera_nonce]
                if mode is not None:
                    arguments += ['--es', 'mode', mode]
                device.shell(*arguments)
                def applied():
                    status = device.preferences(HELPER, 'controlled_camera')
                    assert not status.get('error'), 'Controlled camera error: ' + str(status)
                    return (int(status.get('command_seq', '0')) > before
                            and status.get('last_command') == command)
                until(applied, 'Controlled camera command was not received: ' + command)

            def held_camera():
                status = device.preferences(HELPER, 'controlled_camera')
                assert not status.get('error'), 'Controlled camera failed: ' + str(status)
                pending = device.intake()[2]
                if status.get('active') != 'true' or pending is None:
                    return False
                descriptor = json.loads(pending)
                expected = 'content://' + PACKAGE + '.fileprovider/pending_intake/' + descriptor['record_id'] + '/camera.jpg'
                assert status.get('output_uri') == expected, 'Camera opened another reservation'
                return status

            def cancel_camera(boundary):
                try:
                    status = until(held_camera, 'Owned camera did not open its actual output grant')
                    before = int(status.get('cancelled', '0'))
                    camera_command('cancel')
                    until(lambda: int(device.preferences(HELPER, 'controlled_camera').get('cancelled', '0')) > before
                          and device.intake()[2] is None,
                          'Real camera cancellation did not clear its reservation')
                    camera_cancellations.append({'boundary': boundary, 'controlled': True,
                                                 'output_uri': status['output_uri']})
                except (AssertionError, RuntimeError):
                    intake_snapshot(boundary, 'camera-cancel-timeout')
                    raise

            def wait_bridge():
                def ready():
                    try:
                        return bridge('/pending').get('ok')
                    except (OSError, ValueError):
                        return False
                until(ready, 'Owned QA bridge did not restart', timeout=30)

            camera_command('configure', mode='held')
            # Use the actual queued record for real acknowledgment, then each
            # held foreign boundary must leave the independent actor usable.
            assert bridge('/ack?id=' + accepted[0]['id'])['ok']
            assert device.intake() == initial
            assert bridge('/camera')['ok']
            held_camera_status = until(held_camera, 'Controlled camera was not launched')
            before_recreated = int(held_camera_status.get('recreated', '0'))
            camera_command('recreate')
            until(lambda: int(device.preferences(HELPER, 'controlled_camera').get('recreated', '0')) > before_recreated
                  and held_camera(), 'Recreated helper camera lost output ownership')
            cancel_camera('helper-recreation')
            assert device.intake() == initial
            evidence.append({'scenario': 'controlled-camera-recreation-cancel', 'accepted': False,
                             'real_activity_result': True, 'output_grant_opened': True})
            print('PASS: controlled camera recreation and real cancellation clear the reservation', flush=True)
            assert bridge('/camera')['ok']
            until(held_camera, 'Controlled success camera was not launched')
            camera_command('success')
            photo = until(lambda: device.intake()[0], 'Real successful camera result did not enqueue')
            assert len(photo) == 1 and device.intake()[2] is None
            record = photo[0]
            assert record['fingerprint'] == 'camera:' + record['id']
            assert record['target'] == {'connection': 'share-intake-qa', 'connection_identity': 'share-intake-qa',
                                         'profile': 'synthetic-profile', 'session': 'synthetic-session'}
            assert len(record['files']) == 1 and record['files'][0]['mediaType'] == 'image/jpeg'
            camera_status = device.preferences(HELPER, 'controlled_camera')
            image = device.private_read(PACKAGE, record['files'][0]['path'])
            assert image[:2] == b'\xff\xd8' and image[-2:] == b'\xff\xd9'
            assert len(image) == int(camera_status['bytes']) == record['files'][0]['byteLength'] <= 4096
            assert hashlib.sha256(image).hexdigest() == camera_status['sha256']
            persisted = device.intake()
            device.shell('am', 'force-stop', PACKAGE)
            device.shell('am', 'start', '-W', '-n', PACKAGE + '/com.tarkilhk.wing.MainActivity')
            wait_bridge()
            assert device.intake() == persisted, 'Committed camera record did not survive owned host restart'
            assert bridge('/ack?id=' + record['id'])['ok']
            assert device.intake() == initial
            evidence.append({'scenario': 'controlled-camera-success-restart-ack', 'accepted': True,
                             'bytes': len(image), 'target_preserved': True,
                             'host_process_restart_persistence': True, 'acknowledged_once': True})
            print('PASS: controlled JPEG success preserves target/bytes across host restart and acknowledgment', flush=True)
            for boundary in ('type', 'query', 'open', 'read'):
                observations = device.preferences(HELPER, 'probe')
                stalled_before = int(observations.get('stalled', '0'))
                released_before = int(observations.get('released', '0'))
                send('stall-' + boundary)
                until(lambda: int(device.preferences(HELPER, 'probe').get('stalled', '0')) > stalled_before,
                      'Provider did not enter held ' + boundary)
                # Start all local commands together: Android's type lookup may
                # return null after its own short timeout while the remote
                # provider continues. Other boundaries remain held for45s.
                query_before = int(device.preferences(HELPER, 'probe').get('query', '0'))
                with ThreadPoolExecutor(max_workers=3) as local:
                    pending_request = local.submit(bridge, '/pending')
                    ack_request = local.submit(bridge, '/ack?id=' + str(uuid.uuid4()))
                    camera_request = local.submit(bridge, '/camera')
                    assert pending_request.result()['ok']
                    assert ack_request.result()['ok']
                    camera = camera_request.result()
                assert camera.get('ok'), camera
                cancel_camera(boundary)
                time.sleep(16)  # Past production's absolute15s admission deadline.
                after_deadline = intake_snapshot(boundary, 'after-deadline')
                accepted_type = False
                if boundary == 'type' and after_deadline[0]:
                    # getTypeAsync may still be held remotely after ContentResolver
                    # returned null. A completed read using the supplied intent
                    # MIME is legitimate; it is not a late Wing lease publication.
                    provider = device.preferences(HELPER, 'probe')
                    assert len(after_deadline[0]) == 1 and after_deadline[2] is None
                    record = after_deadline[0][0]
                    uri = provider['type_uri']
                    expected = hashlib.sha256(('android.intent.action.SEND\0text/plain\0\0' + uri + '\0').encode()).hexdigest()
                    assert record['fingerprint'] == expected, 'Type completion belongs to another intent'
                    assert int(provider['query_at_ms']) - int(provider['stalled_at_ms']) < 15_000, 'Type import was not completed within the Wing deadline'
                    assert int(provider['type_caller_uid']) == int(device.shell('run-as', PACKAGE, 'id', '-u').strip()), 'Held type callback was not requested by Wing'
                    assert int(provider['query']) > query_before, 'No actual client type-to-query progression'
                    assert all(call['requested_at_boot_ms'] < int(provider['query_at_ms'])
                               for call in local_requests[-3:]), 'Local requests missed the client type-call window'
                    assert len(record['files']) == 1 and record['files'][0]['byteLength'] == len(CONTENTS)
                    assert device.private_read(PACKAGE, record['files'][0]['path']) == CONTENTS
                    assert bridge('/ack?id=' + record['id'])['ok']
                    assert device.intake() == initial
                    accepted_type = True
                else:
                    assert after_deadline == initial, 'Timed-out provider changed intake; inspect owned snapshot'
                until(lambda: provider_released(device, released_before),
                      'Owned provider failed to leave fault gate', timeout=55)
                time.sleep(1)
                assert intake_snapshot(boundary, 'after-release') == initial, 'Provider returned after timeout and changed intake; inspect owned snapshot'
                stages = device.shell('run-as', PACKAGE, 'sh', '-c',
                                      'if [ -d cache/provider_share_staging ]; then find cache/provider_share_staging -type f; fi')
                assert not stages.strip(), 'Retired provider stage did not clean after release'
                evidence.append({'scenario': 'held-' + boundary, 'accepted': accepted_type,
                                 'early_type_completion_acknowledged': accepted_type,
                                 'local_pending_ack_camera': True, 'late_publish': False})
                print('PASS: held ' + boundary + ' deadlines and local channel independence', flush=True)
            # A separate process-death case: the old background host cannot
            # retain authority over a delayed foreign result after recreation.
            before = device.preferences(HELPER, 'probe')
            stalled_before = int(before.get('stalled', '0'))
            released_before = int(before.get('released', '0'))
            send('stall-query')
            until(lambda: int(device.preferences(HELPER, 'probe').get('stalled', '0')) > stalled_before,
                  'Old-host query did not enter its fault gate')
            assert bridge('/camera')['ok']
            until(held_camera, 'Old-host camera did not open its output')
            def saved_host():
                activities = device.shell('dumpsys', 'activity', 'activities')
                if not host_has_saved_stopped_state(activities):
                    return False
                (output / 'old-host-before-process-death-activities.txt').write_text(activities)
                return True
            until(saved_host, 'Owned host did not stop with restorable Activity state', timeout=30)
            assert int(device.preferences(HELPER, 'probe').get('released', '0')) == released_before, \
                'Old provider returned before the controlled process-death boundary'
            old_pid = device.host_pid()
            assert old_pid
            retire_owned_host(device, old_pid)
            until(lambda: device.host_pid() != old_pid,
                  'Owned background host process did not retire', timeout=10)
            camera_command('cancel')
            until(lambda: bool(device.host_pid()),
                  'ActivityResult did not recreate the owned host', timeout=30)
            wait_bridge()
            assert device.host_pid() != old_pid
            assert intake_snapshot('old-host', 'after-recreation') == initial
            until(lambda: provider_released(device, released_before),
                  'Old-host provider did not leave its fault gate', timeout=55)
            time.sleep(1)
            assert intake_snapshot('old-host', 'after-release') == initial, 'Old host published into recreated intake'
            # New-process foreign admission clears abandoned private stages;
            # it must not resurrect the dead process's delayed intent.
            send('grant')
            recovered = until(lambda: device.intake()[0], 'Recreated host did not accept a fresh granted import')
            assert len(recovered) == 1 and recovered[0]['fingerprint'] != 'camera:' + recovered[0]['id']
            assert device.private_read(PACKAGE, recovered[0]['files'][0]['path']) == CONTENTS
            assert bridge('/ack?id=' + recovered[0]['id'])['ok']
            assert device.intake() == initial
            stages = device.shell('run-as', PACKAGE, 'sh', '-c',
                                  'if [ -d cache/provider_share_staging ]; then find cache/provider_share_staging -mindepth 1; fi')
            assert not stages.strip(), 'Recreated host retained abandoned provider stages'
            evidence.append({'scenario': 'held-query-old-host-process-death-camera-cancel',
                             'host_process_recreated': True, 'real_activity_result': True,
                             'late_publish': False})
            print('PASS: old-host process recreation rejects delayed provider publication', flush=True)
        (output / 'acceptance.json').write_text(json.dumps(evidence, indent=2) + '\n')
    finally:
        # Stop only the synthetic QA process before restoring its native prefs,
        # so its cached SharedPreferences cannot overwrite the restored file.
        try:
            if installed or marker_created:
                device.shell('am', 'force-stop', PACKAGE)
                directories = device.shell('run-as', PACKAGE, 'sh', '-c',
                                           'if [ -d files/pending_intake ]; then find files/pending_intake -mindepth 1 -maxdepth 1 -type d; fi')
                for directory in directories.splitlines():
                    assert re.fullmatch(r'files/pending_intake/[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}', directory), 'Unexpected owned intake path'
                    device.shell('run-as', PACKAGE, 'rm', '-rf', directory)
                if previous_prefs is None:
                    device.shell('run-as', PACKAGE, 'rm', '-f', PREFERENCES)
                else:
                    device.private_write(PREFERENCES, previous_prefs)
                if marker_created:
                    device.shell('run-as', PACKAGE, 'rm', '-f', MARKER)
                device.shell('run-as', PACKAGE, 'rm', '-rf', 'cache/provider_share_staging')
                if staging_existed:
                    device.shell('run-as', PACKAGE, 'mkdir', '-p', 'cache/provider_share_staging')
                if not intake_existed:
                    device.shell('run-as', PACKAGE, 'sh', '-c', 'rmdir files/pending_intake 2>/dev/null || true')
                if not marker_directory_existed:
                    device.shell('run-as', PACKAGE, 'sh', '-c', 'rmdir cache/delivered_outputs 2>/dev/null || true')
                assert device.intake() == initial, 'Native intake cleanup did not restore its empty baseline'
        finally:
            try:
                if installed:
                    device.adb('uninstall', HELPER)
                    assert not device.installed(HELPER), 'Helper remained installed'
            finally:
                if forwarded:
                    device.adb('forward', '--remove', 'tcp:19307')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--provider-faults', action='store_true',
                        help='Use opt-in share_intake_device.dart; held boundaries take several minutes')
    parser.add_argument('--sdk', type=Path, default=Path(os.environ.get('ANDROID_HOME', REPO.parent / '.toolchain/android-sdk')))
    parser.add_argument('--java-home', type=Path, default=Path(os.environ.get('JAVA_HOME', REPO.parent / '.toolchain/jdk')))
    parser.add_argument('--output', type=Path, default=REPO / 'build/external-share-review')
    args = parser.parse_args()
    if not args.build_only and (not args.serial or not re.fullmatch(r'emulator-\d+', args.serial)):
        parser.error('--serial must identify a disposable emulator')
    apk = build_helper(args.sdk.resolve(), args.java_home.resolve(), args.output.resolve())
    print('Built owned fixture: ' + str(apk), flush=True)
    if not args.build_only:
        run(args.serial, apk, args.output.resolve(), args.provider_faults)


if __name__ == '__main__':
    main()
