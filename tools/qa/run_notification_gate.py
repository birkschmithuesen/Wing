#!/usr/bin/env python3
"""Build and run the real shade-tap regression on an isolated API36 emulator.

With no serial, own an ephemeral AVD (SDK image must already be installed).
--serial reuses an operator-owned emulator; only the notification QA app is reset.
"""
import argparse
import json
from contextlib import contextmanager
from datetime import datetime
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import tempfile
import xml.etree.ElementTree as ET
from zipfile import BadZipFile, ZipFile
from zlib import error as ZipDataError

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
    anr = False
    report = None
    for name, args in {
        'failure-logcat.txt': ('logcat', '-d', '-t', '3000'),
        'failure-window.txt': ('shell', 'dumpsys', 'window'),
        'failure-input-method.txt': ('shell', 'dumpsys', 'input_method'),
        'failure-activity.txt': ('shell', 'dumpsys', 'activity', 'activities'),
        'failure-notifications.txt': ('shell', 'dumpsys', 'notification', '--noredact'),
        'failure-services.txt': ('shell', 'dumpsys', 'activity', 'services'),
    }.items():
        try:
            evidence = device(serial, *args)
            (output / name).write_text(evidence)
            if name in ('failure-logcat.txt', 'failure-window.txt'):
                anr |= 'ANR in ' in evidence or 'Application Not Responding:' in evidence
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
    if anr:
        # Logcat identifies the ANR but omits the saved Java/native thread traces.
        # The Android bugreport retains those after the failed app has stopped.
        try:
            destination = output / 'failure-bugreport.zip'
            destination.unlink(missing_ok=True)
            with (output / 'failure-bugreport-command.log').open('w') as log:
                subprocess.run([adb_path(), '-s', serial, 'bugreport',
                                str(destination)],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
            report = destination
        except (OSError, subprocess.SubprocessError) as error:
            errors.append('failure-bugreport.zip: ' + str(error))
    if errors:
        try:
            (output / 'capture-errors.json').write_text(json.dumps(errors, indent=2) + '\n')
        except OSError as error:
            print('Could not record capture errors: ' + str(error), file=sys.stderr)
    return report


def has_graphics_input_anr(report, input_timeout_at):
    """Match a recent input ANR whose blocked process is waiting on gfxstream."""
    if report is None:
        return False
    try:
        with ZipFile(report) as archive:
            for entry in archive.infolist():
                if (entry.filename.startswith('FS/data/anr/anr_') and
                        entry.file_size <= 2 * 1024 * 1024 and
                        _graphics_input_trace(archive.read(entry).decode(errors='replace'),
                                              input_timeout_at)):
                    return True
    except (OSError, BadZipFile, EOFError, RuntimeError, ZipDataError):
        return False
    return False


def _graphics_input_trace(trace, input_timeout_at):
    # Only the ANR victim's first process dump is authoritative. Bugreports
    # can also contain graphics stacks for unrelated processes.
    header, _, dump = trace.partition('\n----- pid ')
    process, end, _ = dump.partition('\n----- end ')
    subject = re.search(r'^Subject: Input dispatching timed out \((.*)$', header, re.M)
    package = re.search(r'^Cmd line: (\S+)$', process, re.M)
    timestamp = re.match(r'\d+ at (.+) -----\n', process)
    if not (end and subject and package and timestamp and f' {package[1]}/' in subject[1]):
        return False
    try:
        dumped_at = datetime.fromisoformat(timestamp[1])
    except ValueError:
        return False
    if dumped_at.tzinfo is None or not -5 <= input_timeout_at - dumped_at.timestamp() <= 60:
        return False
    blocks = re.split(r'(?m)^"([^"\n]+)"[^\n]*\n', process)
    threads = dict(zip(blocks[1::2], blocks[2::2]))
    return ('DrawFrameTask::drawFrame' in threads.get('main', '') and
            'vulkan.ranchu.so (gfxstream::vk::VkEncoder::vkQueueWaitIdle+' in
            threads.get('RenderThread', ''))


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


def host_memory_snapshot():
    snapshot = {}
    for name, path in {
        'memory': '/proc/meminfo',
        'pressure': '/proc/pressure/memory',
        'oom_kills': '/proc/vmstat',
        'cgroup_events': '/sys/fs/cgroup/memory.events',
        'cgroup_limit': '/sys/fs/cgroup/memory.max',
        'cgroup_current': '/sys/fs/cgroup/memory.current',
    }.items():
        try:
            text = Path(path).read_text()
            if name == 'memory':
                text = '\n'.join(line for line in text.splitlines()
                                 if line.partition(':')[0] in
                                 ('MemTotal', 'MemAvailable', 'SwapTotal', 'SwapFree'))
            elif name == 'oom_kills':
                text = '\n'.join(line for line in text.splitlines()
                                 if line.startswith('oom_kill '))
            snapshot[name] = text.strip()
        except OSError as error:
            snapshot[name] = {'error': str(error)}
    return snapshot


def emulator_registered(serial, *, timeout=25):
    connected = subprocess.check_output(
        [adb_path(), 'devices'], text=True, timeout=timeout)
    return any(line.split()[0] == serial
               for line in connected.splitlines()[1:] if line.split())


@contextmanager
def owned_emulator():
    sdk = Path(os.environ['ANDROID_HOME'])
    serial = 'emulator-5562'
    if emulator_registered(serial):
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
    lifecycle = {'before_start': host_memory_snapshot(), 'retirement_confirmed': False}
    with (OUTPUT / 'emulator.log').open('w') as log:
        process = subprocess.Popen([
            str(sdk / 'emulator/emulator'), '-avd', 'wing_notification_gate',
            '-port', serial.removeprefix('emulator-'), '-no-window', '-no-audio', '-no-boot-anim',
            '-no-snapshot', '-gpu', 'lavapipe', '-feature', 'Vulkan,VulkanNativeSwapchain',
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
            lifecycle.update(pid=process.pid, exit_before_cleanup=process.poll())
            try:
                process.terminate()
                try:
                    lifecycle['exit_after_cleanup'] = process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    lifecycle['exit_after_cleanup'] = process.wait(timeout=15)
                # Process exit and ADB transport retirement are separate events.
                # Release this context only once the next owner can admit its slot.
                deadline = time.monotonic() + 30
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError(f'{serial} remained registered after emulator exit')
                    if not emulator_registered(serial, timeout=min(25, remaining)):
                        lifecycle['retirement_confirmed'] = True
                        break
                    time.sleep(min(0.25, remaining))
            finally:
                lifecycle['after_cleanup'] = host_memory_snapshot()
                try:
                    (OUTPUT / 'emulator-lifecycle.json').write_text(
                        json.dumps(lifecycle, indent=2) + '\n')
                except OSError as error:
                    print('Could not record emulator lifecycle: ' + str(error),
                          file=sys.stderr)


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
