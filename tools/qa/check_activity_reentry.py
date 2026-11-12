#!/usr/bin/env python3
"""Check Wing rendering after competing launcher tasks, without clearing app data.

Restarts the selected app and navigates through its launcher/Recents shortcut.
Does not send messages, change settings, or read conversation contents.
Requires an unlocked device. Captures stay in memory; only pixel counts are logged.
"""
# Optimization would remove the verdict assertions below.
if not __debug__:
    raise RuntimeError("Native acceptance requires Python assertions; remove -O/PYTHONOPTIMIZE")


import argparse
import collections
import re
import struct
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--package', default='com.tarkilhk.wing.dev')
    args = parser.parse_args()
    adb = ['adb', '-s', args.serial]
    component = f'{args.package}/com.tarkilhk.wing.MainActivity'

    def shell(*parts):
        return subprocess.check_output(
            adb + ['shell', *parts], text=True, timeout=20,
        )

    def current_activity():
        dump = shell('dumpsys', 'activity', 'activities')
        resumed = re.search(
            r'(?:topResumedActivity|mResumedActivity)=ActivityRecord\{(\S+) [^\n]*'
            + re.escape(args.package) + r'/[^\n]* t(\d+)\}', dump,
        )
        assert resumed, 'Wing is not the foreground activity; unlock the device'
        return resumed.groups()

    def single_recent_task():
        dump = shell('dumpsys', 'activity', 'recents')
        tasks = [
            block for block in re.split(r'\* Recent #\d+:', dump)[1:]
            if re.search(
                r'mActivityComponent=' + re.escape(args.package)
                + r'/(?:com\.tarkilhk\.wing)?\.MainActivity\b', block,
            )
        ]
        assert len(tasks) == 1, f'Expected one Wing card in Android Recents, found {len(tasks)}'
        print('PASS: exactly one Wing task in Android Recents')

    def rendered(stage):
        current_activity()
        # Wait for transitions, then require visible content in the central area.
        # Sample app content rather than Android system bars.
        for _ in range(8):
            time.sleep(0.5)
            raw = subprocess.check_output(adb + ['exec-out', 'screencap'], timeout=20)
            width, height, fmt = struct.unpack_from('<III', raw)
            assert fmt in (1, 2, 3), f'Unsupported screenshot format: {fmt}'
            stride = 3 if fmt == 3 else 4
            pixels = raw[len(raw) - width * height * stride:]
            colors = collections.Counter(
                pixels[(y * width + x) * stride:(y * width + x) * stride + 3]
                for y in range(height // 5, height * 3 // 5, 4)
                for x in range(width // 10, width * 9 // 10, 4)
            )
            coverage = max(colors.values()) / sum(colors.values())
            if coverage < .995:
                print(f'PASS {stage}: content rendered ({coverage:.2%} dominant color)')
                return
        raise AssertionError(f'{stage}: blank app content ({coverage:.2%} dominant color)')

    shell('am', 'force-stop', args.package)
    shell('am', 'start', '-W', '-n', component, '-a', 'android.intent.action.MAIN',
          '-c', 'android.intent.category.LAUNCHER')
    original_activity = current_activity()
    original = original_activity[1]
    rendered('cold launch')
    single_recent_task()
    for index in range(3):
        shell('input', 'keyevent', 'KEYCODE_HOME')
        # Model a launcher creating a distinct shortcut task while Wing is stopped.
        shell('am', 'start', '-W', '-n', component,
              '-a', 'com.tarkilhk.wing.action.ACTIVITY', '-f', '0x18000000')
        rendered(f'shortcut {index + 1}')
        assert current_activity() == original_activity, 'Shortcut replaced the original activity'
        shell('am', 'start', '-W', '--task', original, '-n', component,
              '-f', '0x20000000')
        rendered(f'original task {index + 1}')
        assert current_activity() == original_activity, 'Launcher replaced the original activity'
        single_recent_task()
    # Both notification entry points use NEW_TASK | SINGLE_TOP. Exercise their
    # MainActivity launch shape without manufacturing a real chat notification.
    shell('input', 'keyevent', 'KEYCODE_HOME')
    shell('am', 'start', '-W', '-n', component, '-f', '0x30000000')
    rendered('notification-style launch')
    assert current_activity() == original_activity, 'Notification launch replaced the activity'
    single_recent_task()

    pid = shell('pidof', args.package).strip()
    log = subprocess.check_output(adb + ['logcat', '-d', '--pid=' + pid], text=True, timeout=20)
    assert 'evicted by another attaching activity' not in log, 'Another activity took the Flutter engine'
    print('PASS: original activity retained throughout; no Flutter engine eviction')
    print('PASS: repeated shortcut/task reentry retains a rendered Wing activity')


if __name__ == '__main__':
    main()
