#!/usr/bin/env python3
"""Build and run the real shade-tap regression on an isolated API36 emulator.

With no serial, own an ephemeral AVD (SDK image must already be installed).
--serial reuses an operator-owned emulator; only the notification QA app is reset.
"""
import argparse
import json
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tempfile
import xml.etree.ElementTree as ET

IMAGE = 'system-images;android-36;google_apis;x86_64'
OUTPUT = Path('build/notification-gate')


def adb_path():
    return str(Path(os.environ['ANDROID_HOME']) / 'platform-tools/adb')


def command(*args, **kwargs):
    return subprocess.run(args, check=True, timeout=600, **kwargs)


def device(serial, *args):
    return subprocess.check_output(
        [adb_path(), '-s', serial, *args], text=True, timeout=25,
        stderr=subprocess.PIPE).strip()


def require_emulator(serial):
    if not serial.startswith('emulator-') or device(serial, 'shell', 'getprop', 'ro.kernel.qemu') != '1':
        raise ValueError('Notification gate requires a disposable Android emulator')


def capture_failure(serial, output):
    """Preserve owned-emulator evidence without replacing the original failure."""
    try:
        output.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        print('Could not create failure evidence directory: ' + str(error), file=sys.stderr)
        return
    errors = []
    for name, args in {
        'failure-logcat.txt': ('logcat', '-d', '-t', '3000'),
        'failure-window.txt': ('shell', 'dumpsys', 'window'),
        'failure-input-method.txt': ('shell', 'dumpsys', 'input_method'),
        'failure-activity.txt': ('shell', 'dumpsys', 'activity', 'activities'),
        'failure-notifications.txt': ('shell', 'dumpsys', 'notification', '--noredact'),
        'failure-services.txt': ('shell', 'dumpsys', 'activity', 'services'),
    }.items():
        try:
            (output / name).write_text(device(serial, *args))
        except (OSError, subprocess.SubprocessError) as error:
            errors.append(name + ': ' + str(error))
    try:
        device(serial, 'shell', 'uiautomator', 'dump', '/sdcard/wing-failure.xml')
        (output / 'failure-ui.xml').write_text(device(serial, 'shell', 'cat', '/sdcard/wing-failure.xml'))
    except (OSError, subprocess.SubprocessError) as error:
        errors.append('failure-ui.xml: ' + str(error))
    try:
        with (output / 'failure.png').open('wb') as capture:
            subprocess.run([adb_path(), '-s', serial, 'exec-out', 'screencap', '-p'],
                           stdout=capture, check=True, timeout=25)
    except (OSError, subprocess.SubprocessError) as error:
        errors.append('failure.png: ' + str(error))
    if errors:
        try:
            (output / 'capture-errors.json').write_text(json.dumps(errors, indent=2) + '\n')
        except OSError as error:
            print('Could not record capture errors: ' + str(error), file=sys.stderr)


def check_on_emulator(serial):
    require_emulator(serial)
    # Fresh SDK AVDs start behind the keyguard. The fixture awaits its first
    # frame, and the real shade gesture requires an unlocked display.
    device(serial, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    device(serial, 'shell', 'wm', 'dismiss-keyguard')
    command(adb_path(), '-s', serial, 'install', '--no-incremental', '-r', '-g',
            'build/app/outputs/flutter-apk/app-debug.apk')
    try:
        command(sys.executable, 'tools/qa/check_notification_revamp.py',
                '--serial', serial, '--output', str(OUTPUT), '--tap-only')
    except subprocess.CalledProcessError:
        capture_failure(serial, OUTPUT)
        raise


def prepare_owned_android(serial):
    """Require a healthy launcher before installing Wing on a fresh AVD."""
    if device(serial, 'shell', 'pm', 'list', 'packages',
              'com.tarkilhk.wing.notificationqa'):
        raise ValueError('Boot provisioning requires an AVD without the Wing fixture')
    launcher = device(serial, 'shell', 'cmd', 'package', 'resolve-activity',
                      '--brief', '-a', 'android.intent.action.MAIN',
                      '-c', 'android.intent.category.HOME').splitlines()[-1].split('/')[0]
    if '.' not in launcher:
        raise ValueError('Android did not resolve its home launcher')
    device(serial, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    device(serial, 'shell', 'wm', 'dismiss-keyguard')
    device(serial, 'shell', 'input', 'keyevent', 'KEYCODE_HOME')
    waited = False
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        try:
            result = device(serial, 'shell', 'uiautomator', 'dump',
                            '/sdcard/wing-boot-ui.xml')
            if 'dumped to:' not in result:
                time.sleep(1)
                continue
            xml = device(serial, 'shell', 'cat', '/sdcard/wing-boot-ui.xml')
            (OUTPUT / 'boot-ui.txt').write_text(xml)
            nodes = list(ET.fromstring(xml).iter('node'))
            alerts = [node for node in nodes
                      if node.get('resource-id') == 'android:id/alertTitle']
            if alerts:
                if waited or any(node.get('text') != "System UI isn't responding"
                                 for node in alerts):
                    raise RuntimeError('Android boot has an unexpected or repeated ANR')
                button = next(node for node in nodes
                              if node.get('resource-id') == 'android:id/aerr_wait')
                coordinates = button.get('bounds').replace('][', ',').strip('[]')
                left, top, right, bottom = map(int, coordinates.split(','))
                print('Fresh Android boot: waiting once for System UI before installing Wing',
                      flush=True)
                device(serial, 'shell', 'input', 'tap',
                       str((left + right) // 2), str((top + bottom) // 2))
                waited = True
            elif any(node.get('package') == launcher for node in nodes):
                device(serial, 'shell', 'settings', 'put', 'secure',
                       'show_ime_with_hard_keyboard', '1')
                if device(serial, 'shell', 'settings', 'get', 'secure',
                          'show_ime_with_hard_keyboard').strip() != '1':
                    raise RuntimeError('Owned Android must display the software keyboard')
                return
        except subprocess.SubprocessError:
            pass
        time.sleep(1)
    raise TimeoutError('Android launcher did not become healthy before Wing installation')


@contextmanager
def owned_emulator():
    sdk = Path(os.environ['ANDROID_HOME'])
    serial = 'emulator-5562'
    connected = subprocess.check_output([adb_path(), 'devices'], text=True, timeout=25)
    if any(line.split()[0] == serial for line in connected.splitlines()[1:] if line.split()):
        raise ValueError(f'{serial} is occupied; refusing to replace another emulator')
    with tempfile.TemporaryDirectory(prefix='avd-', dir=OUTPUT.resolve()) as directory:
        with start_owned_emulator(sdk, serial, Path(directory)) as started:
            yield started


@contextmanager
def start_owned_emulator(sdk, serial, avds):
    env = {**os.environ, 'ANDROID_AVD_HOME': str(avds)}
    command(str(sdk / 'cmdline-tools/latest/bin/avdmanager'), 'create', 'avd',
            '--force', '--name', 'wing_notification_gate', '--package', IMAGE,
            '--device', 'pixel_2', input='no\n', text=True, env=env)
    disk = shutil.disk_usage(avds)
    (OUTPUT / 'emulator-storage.json').write_text(json.dumps({
        'total_bytes': disk.total, 'used_bytes': disk.used, 'free_bytes': disk.free,
    }, indent=2) + '\n')
    with (OUTPUT / 'emulator.log').open('w') as log:
        process = subprocess.Popen([
            str(sdk / 'emulator/emulator'), '-avd', 'wing_notification_gate',
            '-port', serial.removeprefix('emulator-'), '-no-window', '-no-audio', '-no-boot-anim',
            '-no-snapshot', '-gpu', 'swiftshader', '-feature', '-Vulkan',
            '-memory', '4096', '-cores', '4',
            '-no-metrics', '-show-kernel',
        ], stdout=log, stderr=subprocess.STDOUT, env=env)
        try:
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f'Emulator exited; see {OUTPUT}/emulator.log')
                try:
                    if device(serial, 'shell', 'getprop', 'sys.boot_completed') == '1':
                        break
                except subprocess.CalledProcessError:
                    pass
                time.sleep(1)
            else:
                raise TimeoutError('Notification emulator did not boot within 300 seconds')
            prepare_owned_android(serial)
            yield serial
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', help='Reuse this disposable emulator instead of starting an AVD')
    args = parser.parse_args()
    if args.serial:
        require_emulator(args.serial)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    # Build before booting the owned AVD to keep CI memory pressure bounded.
    command('flutter', 'build', 'apk', '--debug', '--no-pub',
            '--target-platform', 'android-x64', '-t',
            'integration_test/notification_revamp_device.dart',
            env={**os.environ, 'ORG_GRADLE_PROJECT_notificationQa': 'true'})
    if args.serial:
        check_on_emulator(args.serial)
    else:
        with owned_emulator() as serial:
            check_on_emulator(serial)


if __name__ == '__main__':
    main()
