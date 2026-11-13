#!/usr/bin/env python3
"""Run offline native voice acceptance on an already booted disposable phone AVD.

Requires Flutter/adb on PATH and com.tarkilhk.wing.dev already installed. Resets
only that package's RECORD_AUDIO grant/user flags, then drives Android's actual
deny/grant dialogs and Home cancellation. Runs Flutter suites sequentially with
--no-uninstall --no-pub. Does not contact Hermes or invoke a speech provider.
Screens, native UI trees, Flutter logs and acceptance.json go under --output.
Requires a root-capable, freshly owned disposable AVD. A uniquely named Android
resource overlay makes local recognition unavailable for its mandatory rejection
case. Cleanup disables that overlay and verifies the original resource and native
capability; the enclosing AVD owner deletes its disabled registration with storage.
The disposable AVD retains microphone permission granted after a successful run.
"""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
PACKAGE = 'com.tarkilhk.wing.dev'
PERMISSION = 'android.permission.RECORD_AUDIO'
RECOGNIZER_RESOURCE = 'android:string/config_defaultOnDeviceSpeechRecognitionService'
UNAVAILABLE_TAG = 'recognition-unavailable'
RESTORED_TAG = 'recognition-restored'
PERMISSION_STEPS = {
    'VOICE_DENY_READY', 'VOICE_GRANT_READY', 'VOICE_BACKGROUND_READY',
    'VOICE_BACKGROUND_CANCELLED',
}

DUPLEX_ORDER = ['VOICE_DUPLEX_READY', 'VOICE_DUPLEX_BACKGROUND', 'VOICE_DUPLEX_RESUMED', 'VOICE_DUPLEX_MUTED', 'VOICE_DUPLEX_ENDED']


class Driver:
    def __init__(self, serial, output, timeout):
        self.serial = serial
        self.output = output
        self.timeout = timeout
        self.deadline = None
        self.process = None
        self.dump_path = '/sdcard/wing-voice-qa-' + uuid.uuid4().hex + '.xml'
        self.evidence = {
            'device': serial, 'package': PACKAGE, 'backend': 'none; offline fixtures',
            'status': 'running', 'suites': {}, 'native_actions': [],
            'limitations': [
                'Synthetic capture/playback does not establish transcription or speech quality.',
                'Local recognition quality, Hermes voice and live providers were not exercised.',
                'TTS start callbacks do not measure first audible speech or intelligibility.',
                'Physical phone acceptance remains separate.',
            ],
        }

    def remaining(self, maximum=25):
        if self.deadline is None:
            return maximum
        seconds = self.deadline - time.monotonic()
        if seconds <= 0:
            raise TimeoutError('Native voice suite exceeded its bounded timeout')
        return min(maximum, seconds)

    def adb(self, *command, binary=False):
        return subprocess.check_output(
            ['adb', '-s', self.serial, *command], text=not binary,
            stderr=subprocess.PIPE, timeout=self.remaining(),
        )

    def shell(self, *command):
        return self.adb('shell', shlex.join(command))

    def require_emulator(self):
        if (not re.fullmatch(r'emulator-\d+', self.serial)
                or self.shell('getprop', 'ro.kernel.qemu').strip() != '1'):
            raise RuntimeError('Recognition isolation requires a rooted disposable emulator')
        if int(self.shell('getprop', 'ro.build.version.sdk').strip()) < 31:
            raise RuntimeError('Recognition isolation requires Android API 31 or later')

    def require_rooted_emulator(self):
        self.require_emulator()
        if self.shell('id', '-u').strip() != '0':
            raise RuntimeError('Recognition isolation requires a rooted disposable emulator')

    def transition_adbd(self, command, uid, record):
        """Dispatch once, then observe the daemon restart before changing direction."""
        previous_deadline = self.deadline
        self.deadline = time.monotonic() + self.remaining()
        try:
            self.adb('wait-for-device')
            if self.adb('get-serialno').strip() != self.serial:
                raise RuntimeError('The admitted emulator identity changed before adb ' + command)
            try:
                self.adb(command)
            except subprocess.CalledProcessError as error:
                record[command + '_reply_error'] = {
                    'returncode': error.returncode, 'stderr': error.stderr,
                }
            while True:
                self.remaining()
                try:
                    self.adb('wait-for-device')
                    if self.adb('get-serialno').strip() != self.serial:
                        raise RuntimeError('The admitted emulator identity changed after adb ' + command)
                    if self.shell('id', '-u').strip() == uid:
                        return
                except subprocess.CalledProcessError:
                    # wait-for-device can observe the old transport just before
                    # it closes. Only a read of the requested UID settles this.
                    pass
                time.sleep(min(.1, self.remaining()))
        except (TimeoutError, subprocess.TimeoutExpired) as error:
            raise RuntimeError('Emulator adbd authority was not restored' if command == 'unroot'
                               else 'Emulator adbd root authority was not established') from error
        finally:
            self.deadline = previous_deadline

    @contextmanager
    def rooted_emulator(self):
        self.require_emulator()
        prior_uid = self.shell('id', '-u').strip()
        if prior_uid not in {'0', '2000'}:
            raise RuntimeError('Could not determine the emulator adbd authority')
        record = self.evidence['adbd'] = {
            'prior_uid': prior_uid, 'root_requested': prior_uid != '0', 'restored': False,
        }
        try:
            if record['root_requested']:
                self.transition_adbd('root', '0', record)
            if self.adb('get-serialno').strip() != self.serial:
                raise RuntimeError('The admitted emulator identity changed after adb root')
            self.require_rooted_emulator()
            yield
        finally:
            try:
                self.stop_process()
            finally:
                self.deadline = None
                try:
                    if record['root_requested']:
                        self.transition_adbd('unroot', prior_uid, record)
                    if (self.adb('get-serialno').strip() != self.serial
                            or self.shell('id', '-u').strip() != prior_uid):
                        raise RuntimeError('Original emulator adbd authority was not restored')
                    record['restored'] = True
                except Exception as error:
                    record['cleanup_error'] = str(error)
                    raise

    def recognizer_resource(self):
        return self.shell('cmd', 'overlay', 'lookup', '--user', '0',
                          'android', RECOGNIZER_RESOURCE)

    @contextmanager
    def unavailable_recognition(self):
        self.require_rooted_emulator()
        name = 'WingVoiceUnavailable' + uuid.uuid4().hex
        identifier = 'com.android.shell:' + name
        baseline = self.recognizer_resource()
        overlays = self.shell('cmd', 'overlay', 'list', '--user', '0', 'android')
        if any(line.split()[-1:] == [identifier] for line in overlays.splitlines()):
            raise RuntimeError('Refusing to borrow an existing recognition overlay')
        record = self.evidence['recognition_isolation'] = {
            'overlay': identifier, 'baseline_resource': baseline,
            'restored': False,
            'registration_cleanup': 'Enclosing owned disposable AVD storage deletion',
        }
        try:
            # Mark ownership before dispatch: an adb failure may lose a successful receipt.
            self.shell('cmd', 'overlay', 'fabricate', '--target', 'android',
                       '--name', name, RECOGNIZER_RESOURCE, '0x03', '')
            self.shell('cmd', 'overlay', 'enable', '--user', '0', identifier)
            if self.recognizer_resource().strip():
                raise RuntimeError('Android did not apply the empty recognition configuration')
            self.shell('am', 'force-stop', PACKAGE)
            yield
        finally:
            try:
                self.stop_process()
            finally:
                self.deadline = None
                try:
                    overlays = self.shell('cmd', 'overlay', 'list', '--user', '0', 'android')
                    if any(line.split()[-1:] == [identifier] for line in overlays.splitlines()):
                        self.shell('cmd', 'overlay', 'disable', '--user', '0', identifier)
                    if self.recognizer_resource() != baseline:
                        raise RuntimeError('Original Android recognition configuration was not restored')
                    overlays = self.shell('cmd', 'overlay', 'list', '--user', '0', 'android')
                    if any(line.strip() == '[x] ' + identifier for line in overlays.splitlines()):
                        raise RuntimeError('Owned recognition overlay is still enabled')
                    self.shell('am', 'force-stop', PACKAGE)
                    record['restored'] = True
                except Exception as error:
                    record['cleanup_error'] = str(error)
                    raise

    def verify_recognition_observation(self, transcript, marker, expected):
        observations = re.findall(re.escape(marker) + r' (true|false)', transcript)
        if observations != [str(expected).lower()]:
            raise RuntimeError('Missing or incorrect native recognition observation: ' + marker)

    def capture(self, label):
        (self.output / (label + '.png')).write_bytes(
            self.adb('exec-out', 'screencap', '-p', binary=True))

    def nodes(self, label):
        self.shell('uiautomator', 'dump', self.dump_path)
        raw = self.shell('cat', self.dump_path)
        (self.output / (label + '.xml')).write_text(raw)
        nodes = list(ET.fromstring(raw).iter('node'))
        if any(n.get('resource-id') in {'android:id/aerr_close', 'android:id/aerr_wait'}
               for n in nodes):
            self.capture(label + '-android-error')
            raise RuntimeError('Android reported a crash/ANR; inspect native captures')
        return nodes

    def granted(self):
        details = self.shell('dumpsys', 'package', PACKAGE)
        matches = re.findall(re.escape(PERMISSION) + r': granted=(true|false)', details)
        if len(matches) != 1:
            raise RuntimeError('Could not determine the dev app microphone permission')
        return matches[0] == 'true'

    def drive_permission(self, grant):
        label = 'microphone-grant' if grant else 'microphone-deny'
        button_id = ('permission_allow_foreground_only_button' if grant
                     else 'permission_deny_button')
        deadline = time.monotonic() + min(40, self.remaining(40))
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('Flutter exited while waiting for ' + label)
            nodes = self.nodes(label)
            controller = [n for n in nodes
                          if n.get('package', '').endswith('.permissioncontroller')]
            if not any(re.search(r'microphone|record audio', n.get('text', '').lower())
                       for n in controller):
                time.sleep(.25)
                continue
            node = next((n for n in controller
                         if n.get('resource-id', '').split(':id/')[-1] == button_id
                         and n.get('enabled') == 'true'), None)
            if node is None:
                time.sleep(.25)
                continue
            bounds = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds', ''))
            if bounds is None:
                raise RuntimeError('Permission button has no native tap bounds')
            left, top, right, bottom = map(int, bounds.groups())
            self.capture(label)
            self.shell('input', 'tap', str((left + right) // 2), str((top + bottom) // 2))
            while time.monotonic() < deadline:
                if self.granted() == grant:
                    self.evidence['native_actions'].append({
                        'action': label, 'button': node.get('text'),
                        'resource_id': node.get('resource-id'), 'granted_after': grant,
                    })
                    return
                time.sleep(.2)
            break
        self.capture(label + '-failed')
        raise RuntimeError('Could not complete actual Android microphone dialog: ' + label)

    def permission_marker(self, marker):
        if marker == 'VOICE_DENY_READY':
            self.drive_permission(False)
        elif marker == 'VOICE_GRANT_READY':
            self.drive_permission(True)
        elif marker == 'VOICE_BACKGROUND_READY':
            self.nodes('capture-before-home')
            self.capture('capture-before-home')
            self.shell('input', 'keyevent', 'KEYCODE_HOME')
            time.sleep(.25)
            self.capture('capture-backgrounded')
            self.evidence['native_actions'].append({'action': 'Home during AAC capture'})
        elif marker == 'VOICE_BACKGROUND_CANCELLED':
            self.evidence['native_actions'].append({'action': 'Flutter verified foreground-loss cancellation'})
            component = self.shell('cmd', 'package', 'resolve-activity', '--brief',
                                   '-a', 'android.intent.action.MAIN',
                                   '-c', 'android.intent.category.LAUNCHER', PACKAGE).strip().splitlines()[-1]
            if not re.fullmatch(re.escape(PACKAGE) + r'/[\w.$]+', component):
                raise RuntimeError('Could not resolve the dev app launcher for resume')
            self.shell('am', 'start', '-W', '-n', component)
            self.capture('capture-cancelled-resumed')

    def duplex_marker(self, marker):
        if marker == 'VOICE_DUPLEX_READY':
            self.shell('input', 'keyevent', 'KEYCODE_HOME')
            self.shell('input', 'keyevent', 'KEYCODE_SLEEP')
        elif marker == 'VOICE_DUPLEX_BACKGROUND':
            services = self.shell('dumpsys', 'activity', 'services', PACKAGE)
            if 'LiveVoiceService' not in services or 'isForeground=true' not in services:
                raise RuntimeError('Voice foreground service did not survive Home/lock')
            self.evidence['native_actions'].append({'action': 'Duplex audio packets continued during Home and lock'})
            self.capture('duplex-locked')
            self.shell('input', 'keyevent', 'KEYCODE_WAKEUP')
            self.shell('wm', 'dismiss-keyguard')
            self.shell('am', 'start', '-W', '-n', PACKAGE + '/com.tarkilhk.wing.MainActivity')
        elif marker in {'VOICE_DUPLEX_RESUMED', 'VOICE_DUPLEX_MUTED'}:
            label = 'Mute' if marker == 'VOICE_DUPLEX_RESUMED' else 'End voice'
            self.shell('cmd', 'statusbar', 'expand-notifications')
            deadline = time.monotonic() + min(15, self.remaining(15))
            while time.monotonic() < deadline:
                nodes = self.nodes('duplex-notification-' + label.replace(' ', '-'))
                node = next((n for n in nodes if n.get('text', '').lower() == label.lower()), None)
                if node is not None:
                    bounds = [int(v) for v in re.findall(r'\d+', node.get('bounds', ''))]
                    if len(bounds) != 4:
                        raise RuntimeError('Voice notification action has no bounds')
                    self.shell('input', 'tap', str((bounds[0]+bounds[2])//2), str((bounds[1]+bounds[3])//2))
                    return
                time.sleep(.2)
            raise RuntimeError('Voice notification action was not reachable: ' + label)
        elif marker == 'VOICE_DUPLEX_ENDED':
            deadline = time.monotonic() + min(10, self.remaining(10))
            while time.monotonic() < deadline:
                if 'LiveVoiceService' not in self.shell('dumpsys', 'activity', 'services', PACKAGE):
                    self.evidence['native_actions'].append({'action': 'Notification mute/end released the voice service'})
                    self.shell('cmd', 'statusbar', 'collapse')
                    return
                time.sleep(.1)
            raise RuntimeError('Ended voice still owns a service')

    def stop_process(self):
        if self.process is None or self.process.poll() is not None:
            return
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            self.process.wait(timeout=10)
            return
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=10)

    def run_suite(self, name, target, required_markers=None, extra_arguments=()):
        command = ['flutter', 'test', target, '-d', self.serial, '--no-uninstall',
                   '--no-pub', '--reporter', 'expanded', *extra_arguments]
        log_path = self.output / (name + '-flutter.log')
        seen = set()
        transcript = ''
        started = time.monotonic()
        self.process = None
        self.deadline = time.monotonic() + self.timeout
        self.evidence['suites'][name] = {'command': command, 'log': log_path.name}
        try:
            with log_path.open('w') as log, log_path.open() as reader:
                self.process = subprocess.Popen(
                    command, cwd=REPO, stdout=log, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                while True:
                    self.remaining()
                    exited = self.process.poll() is not None
                    chunk = reader.read()
                    if chunk:
                        print(chunk, end='', flush=True)
                        transcript += chunk
                        if required_markers:
                            for marker in re.findall(r'VOICE_[A-Z_]+', transcript):
                                if marker in required_markers and marker not in seen:
                                    order = DUPLEX_ORDER if name == 'duplex' else PERMISSION_ORDER
                                    expected = order[len(seen)]
                                    if marker != expected:
                                        raise RuntimeError('Unexpected native permission marker order: ' + marker)
                                    if name == 'duplex':
                                        self.duplex_marker(marker)
                                    else:
                                        self.permission_marker(marker)
                                    seen.add(marker)
                    if exited:
                        break
                    time.sleep(.15)
            result = self.process.wait(timeout=5)
            record = self.evidence['suites'][name]
            record.update({'flutter_exit': result, 'observed_markers': sorted(seen)})
            if result:
                raise RuntimeError('Flutter ' + name + ' suite exited unsuccessfully; inspect ' + str(log_path))
            if required_markers and seen != required_markers:
                raise RuntimeError('Missing permission stages: ' + str(sorted(required_markers - seen)))
            if 'All tests passed!' not in transcript:
                raise RuntimeError('Flutter did not report successful assertions for ' + name)
            self.capture(name + '-completed')
            leftovers = self.shell('run-as', PACKAGE, 'sh', '-c',
                                   'if [ -d cache/voice ]; then ls -A cache/voice; fi').strip()
            record['voice_cache_empty'] = not leftovers
            if leftovers:
                raise RuntimeError('Voice temporary files remained after ' + name + ': ' + leftovers)
            return transcript
        finally:
            self.stop_process()
            self.deadline = None
            self.evidence['suites'][name]['duration_seconds'] = round(time.monotonic() - started, 2)
            if self.process is not None:
                self.evidence['suites'][name]['flutter_exit'] = self.process.returncode


PERMISSION_ORDER = ('VOICE_DENY_READY', 'VOICE_GRANT_READY',
                    'VOICE_BACKGROUND_READY', 'VOICE_BACKGROUND_CANCELLED')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, default=REPO / 'build/native-voice-review')
    parser.add_argument('--timeout', type=int, default=900,
                        help='Maximum seconds per Flutter suite, including its build (default: 900)')
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.device):
        parser.error('--device must be a disposable phone emulator, never a phone or TV')
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    driver = Driver(args.device, output, args.timeout)
    try:
        with driver.rooted_emulator():
            characteristics = driver.shell('getprop', 'ro.build.characteristics').strip()
            features = driver.shell('pm', 'list', 'features')
            if 'tv' in characteristics.lower() or 'android.software.leanback' in features:
                raise RuntimeError('TV emulator is outside this phone-native voice check')
            if not driver.shell('pm', 'path', PACKAGE).strip().startswith('package:'):
                raise RuntimeError('Install the normal debug dev APK on the disposable AVD first')
            driver.evidence.update({
                'source_revision': subprocess.check_output(
                    ['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True, timeout=10).strip(),
                'source_dirty': bool(subprocess.check_output(
                    ['git', 'status', '--porcelain'], cwd=REPO, text=True, timeout=10).strip()),
                'android_release': driver.shell('getprop', 'ro.build.version.release').strip(),
                'android_sdk': driver.shell('getprop', 'ro.build.version.sdk').strip(),
                'device_model': driver.shell('getprop', 'ro.product.model').strip(),
                'characteristics': characteristics,
            })
            driver.shell('am', 'force-stop', PACKAGE)
            driver.shell('pm', 'revoke', PACKAGE, PERMISSION)
            driver.shell('pm', 'clear-permission-flags', PACKAGE, PERMISSION, 'user-set', 'user-fixed')
            if driver.granted():
                raise RuntimeError('Microphone permission reset did not take effect')
            driver.evidence['microphone_reset'] = True
            driver.run_suite('permission', 'integration_test/voice_permission_native_test.dart', PERMISSION_STEPS)
            driver.shell('pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
            driver.shell('pm', 'grant', PACKAGE, 'android.permission.BLUETOOTH_CONNECT')
            driver.run_suite('duplex', 'integration_test/live_voice_native_test.dart', set(DUPLEX_ORDER))
            driver.shell('pm', 'grant', PACKAGE, PERMISSION)
            if not driver.granted():
                raise RuntimeError('Microphone permission is not granted before native capture suite')
            target = 'integration_test/voice_native_test.dart'
            transcript = driver.run_suite(
                'native', target, extra_arguments=(
                    '--exclude-tags', UNAVAILABLE_TAG + ' || ' + RESTORED_TAG))
            capabilities = re.search(
                r'VOICE_CAPABILITIES localInput=(true|false) languages=(.*?) offlineVoices=(\d+)', transcript)
            offline = re.search(r'VOICE_OFFLINE_VOICES (\d+)', transcript)
            if capabilities is None or offline is None:
                raise RuntimeError('Native voice capability evidence was not emitted')
            samples = re.findall(
                r'VOICE_LOCAL_TTS sample=(\d+) firstAudioMs=(\d+) completedMs=(\d+) voice=([^\r\n]+)', transcript)
            driver.evidence['capabilities'] = {
                'recognition_available': capabilities[1] == 'true',
                'installed_languages': capabilities[2], 'offline_voice_count': int(offline[1]),
            }
            driver.evidence['tts_callbacks'] = [
                {'sample': int(sample), 'start_callback_ms': int(start),
                 'completed_ms': int(completed), 'voice': voice}
                for sample, start, completed, voice in samples
            ]
            if int(offline[1]) == 0:
                raise RuntimeError('Offline speech acceptance requires an installed Android voice')
            if sorted(int(s[0]) for s in samples) != list(range(5)):
                raise RuntimeError('Installed offline voice did not complete all five TTS samples')
            try:
                with driver.unavailable_recognition():
                    unavailable = driver.run_suite(
                        'recognition-unavailable', target,
                        extra_arguments=('--tags', UNAVAILABLE_TAG))
                    driver.verify_recognition_observation(
                        unavailable, 'VOICE_UNAVAILABLE_LOCAL_INPUT', False)
                    if 'VOICE_LOCAL_UNAVAILABLE_VERIFIED' not in unavailable:
                        raise RuntimeError('Native missing-recognizer rejection did not complete')
            finally:
                if driver.evidence.get('recognition_isolation', {}).get('restored'):
                    restored = driver.run_suite(
                        'recognition-restored', target, extra_arguments=(
                            '--tags', RESTORED_TAG,
                            '--dart-define=VOICE_BASELINE_LOCAL_INPUT=' + capabilities[1]))
                    driver.verify_recognition_observation(
                        restored, 'VOICE_RESTORED_LOCAL_INPUT', capabilities[1] == 'true')
                    driver.evidence['recognition_isolation']['native_capability_restored'] = True
            driver.evidence['limitations'].extend(re.findall(r'VOICE_LIMITATION ([^\r\n]+)', transcript))
        driver.evidence['status'] = 'passed'
        print('PASS: native microphone, capture, playback and missing-local-recognition boundaries; Android configuration restored')
    except Exception as error:
        driver.evidence['status'] = 'failed'
        driver.evidence['error'] = str(error)
        raise
    finally:
        driver.stop_process()
        try:
            if driver.evidence.get('microphone_reset'):
                driver.shell('rm', '-f', driver.dump_path)
        except Exception as error:
            driver.evidence['status'] = 'failed'
            driver.evidence['cleanup_error'] = str(error)
            raise
        finally:
            (output / 'acceptance.json').write_text(json.dumps(driver.evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()
