#!/usr/bin/env python3
"""Check first structured notification without opening its chat, on QA emulator."""
# These acceptance checks use assertions; optimization would remove their verdict.
if not __debug__:
    raise RuntimeError("Native acceptance requires Python assertions; remove -O/PYTHONOPTIMIZE")

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.qa import check_notification_revamp as native

PACKAGE = 'com.tarkilhk.wing.notificationqa'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--port', type=int, default=0,
                        help='Owned host forward port; 0 asks ADB for a free port')
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        parser.error('This check only runs on an isolated QA emulator.')
    adb = ['adb', '-s', args.serial]
    native.SERIAL = args.serial

    def command(*parts):
        return subprocess.check_output(adb + list(parts), text=True, timeout=20)

    if not 0 <= args.port <= 65535:
        parser.error('--port must be between 0 and 65535')
    exempt_before = PACKAGE in command('shell', 'dumpsys', 'deviceidle', 'whitelist')
    # Never replace another run's mapping. An allocated port belongs to this run.
    allocated = command('forward', '--no-rebind', f'tcp:{args.port}', 'tcp:18766').strip()
    args.port = int(allocated or args.port)
    try:
        if not exempt_before:
            command('shell', 'dumpsys', 'deviceidle', 'whitelist', '+' + PACKAGE)

        def post(path):
            req = urllib.request.Request(f'http://127.0.0.1:{args.port}/{path}', data=b'{}')
            with urllib.request.urlopen(req, timeout=15) as response:
                return json.load(response)

        deadline = time.monotonic() + 20
        while True:
            try:
                initial = post('state')
                break
            except (urllib.error.URLError, ConnectionError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.25)
        assert initial['openedChat'] is None
        assert initial['restoredOffline'] and initial['restoredRuntime'] == 'outside', initial
        assert initial['cachedHistoryPresent'], initial
        post('work')
        for _ in range(30):
            services = command('shell', 'dumpsys', 'activity', 'services', PACKAGE)
            if 'BackgroundMonitoringService' in services:
                break
            time.sleep(.25)
        else:
            raise AssertionError('Monitoring did not start during the unopened task')
        command('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        state = post('question')
        assert state['openedChat'] is None, state
        notice = None
        for _ in range(30):
            raw = command('shell', 'dumpsys', 'notification', '--noredact')
            matching = [block for block in re.split(r'(?=NotificationRecord\()', raw)
                        if re.match(r'NotificationRecord\([^\n]*pkg=' + re.escape(PACKAGE) + r'\b', block)
                        and 'channel=wing_attention_notifications' in block.splitlines()[0]]
            if matching:
                assert len(matching) == 1, 'More than one input notice'
                notice = matching[0]
                break
            time.sleep(.25)
        assert notice is not None, f'No first input notification; client state: {state}'
        native.shown_notification('Outside task', expanded=False, required=['3 questions'])
        card = native.shown_notification(
            'Outside task', expanded=True,
            required=['3 questions', 'WING-COLD-QA', 'Preview', 'Production'],
        )
        assert any(node.get('resource-id') == 'android:id/action0'
                   and 'Review' in (node.get('text'), node.get('content-desc'))
                   and node.get('enabled') == 'true' for node in card.iter('node')), \
            'Missing enabled Review action on the owning native card'
        assert 'ONLY_ALERT_ONCE' not in notice.splitlines()[0], 'Fresh request was rendered silently'
        final = post('state')
        assert final['openedChat'] is None
        assert final['retainedCache'] and final['cachedHistoryPresent'], final
        assert final['loaded'][0]['runtime'] == 'outside-runtime', final
        assert final['loaded'][0]['offline'] is False, final
        print('PASS: cached unopened chat posts one fresh native notification with 3 questions, real text/options and Review')
        for _ in range(30):
            services = command('shell', 'dumpsys', 'activity', 'services', PACKAGE)
            if 'BackgroundMonitoringService' not in services:
                break
            time.sleep(.25)
        else:
            raise AssertionError('Monitoring stayed alive after input became pending')
        print('PASS: monitoring stopped after posting the pending request')
    finally:
        try:
            if not exempt_before:
                command('shell', 'dumpsys', 'deviceidle', 'whitelist', '-' + PACKAGE)
        finally:
            command('forward', '--remove', f'tcp:{args.port}')


if __name__ == '__main__':
    main()
