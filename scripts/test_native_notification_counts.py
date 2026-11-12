#!/usr/bin/env python3
"""Check real Android rendering against the isolated notification QA fixture.

Build integration_test/notification_revamp_device.dart with notificationQa=true,
install only on an emulator, grant notifications, launch it, and forward the
fixture's port 18766. This script never targets the production Wing package.
"""

# These acceptance checks use assertions; optimization would remove their verdict.
if not __debug__:
    raise RuntimeError("Native acceptance requires Python assertions; remove -O/PYTHONOPTIMIZE")

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.qa import check_notification_revamp as native


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--port', type=int, default=18767)
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        parser.error('Use an isolated emulator, never a personal device.')
    native.SERIAL = args.serial

    def post(path, body):
        request = urllib.request.Request(
            f'http://127.0.0.1:{args.port}/{path}',
            data=json.dumps(body).encode(),
            headers={'Content-Type': 'application/json'},
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.load(response)

    def assert_single_attention_notice():
        dump = subprocess.check_output(
            ['adb', '-s', args.serial, 'shell', 'dumpsys', 'notification', '--noredact'],
            text=True, timeout=15,
        )
        records = [block for block in re.split(r'(?=NotificationRecord\()', dump)
                   if re.match(r'NotificationRecord\([^\n]*pkg=com\.tarkilhk\.wing\.notificationqa\s', block)
                   and 'channel=wing_attention_notifications' in block.splitlines()[0]]
        assert len(records) == 1, f'Expected one attention notification, got {len(records)}'

    # Keep the loopback fixture available while Android owns the shade. The
    # independent profile's real work lease prevents the QA process being cached.
    try:
        post('work', {})
        native.wait_for_monitoring_notification()
        post('preview', {'enabled': True})
        for count in [3, 2, 1]:
            post('question', {'count': count})
            expected = f'{count} question' + ('s' if count != 1 else '')
            for expanded in (False, True):
                content = [expected]
                if expanded:
                    content += ['Which sample output should I prepare?', 'Summary', 'Checklist']
                native.shown_notification('Website refresh', expanded=expanded, required=content)
                assert_single_attention_notice()
            print(f'PASS: actual collapsed and expanded card show {expected}', flush=True)

        post('preview', {'enabled': False})
        for expanded in (False, True):
            native.shown_notification('Website refresh', expanded=expanded,
                                      required=['1 question'],
                                      forbidden=['Which sample', 'Summary', 'Checklist'])
            assert_single_attention_notice()
        print('PASS: actual private cards retain the count without exposing question content')
    finally:
        # Stop the final background lease only while the fixture is foreground;
        # otherwise Android may freeze it before the HTTP reply is delivered.
        native.adb('shell', 'am', 'start', '-W', '-n',
                   native.PACKAGE + '/com.tarkilhk.wing.MainActivity')
        post('stop', {})


if __name__ == '__main__':
    main()
