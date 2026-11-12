#!/usr/bin/env python3
"""Verify an unread QA reply is restored silently after Android force-stop.

Install integration_test/notification_revamp_device.dart built with
notificationQa=true on an emulator. The driver resets only that isolated QA
package, grants notifications and launches the fixture before generating the
test reply. Never targets Wing's production package or a personal device.
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
import time
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.qa import check_notification_revamp as native

PACKAGE = 'com.tarkilhk.wing.notificationqa'
ACTIVITY = f'{PACKAGE}/com.tarkilhk.wing.MainActivity'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--port', type=int, default=0,
                        help='Owned host forward port; 0 asks ADB for a free port')
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        parser.error('Use an isolated emulator, never a personal device.')
    adb = ['adb', '-s', args.serial]
    native.SERIAL = args.serial

    def command(*parts):
        return subprocess.check_output(adb + list(parts), text=True, timeout=20)

    if not 0 <= args.port <= 65535:
        parser.error('--port must be between 0 and 65535')
    # Never replace another run's mapping. An allocated port belongs to this run.
    allocated = command('forward', '--no-rebind', f'tcp:{args.port}', 'tcp:18766').strip()
    args.port = int(allocated or args.port)
    try:
        command('shell', 'pm', 'clear', PACKAGE)
        command('shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
        command('shell', 'am', 'start', '-n', ACTIVITY)

        def request(path, body):
            req = urllib.request.Request(
                f'http://127.0.0.1:{args.port}/{path}',
                data=json.dumps(body).encode(),
                headers={'Content-Type': 'application/json'},
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                return json.load(response)

        # A distinct event avoids reusing any previous run's dismissal/read ledger.
        answer = f'WING-RESTORE-QA-{time.time_ns()}: Unread result ready.'

        def notices(only_answer=True):
            dump = command('shell', 'dumpsys', 'notification', '--noredact')
            result = {}
            for block in re.split(r'(?=NotificationRecord\()', dump):
                if not re.match(
                    r'NotificationRecord\([^\n]*pkg=' + re.escape(PACKAGE) + r'\b',
                    block,
                ):
                    continue
                head = block.splitlines()[0]
                if 'channel=wing_turn_notifications' not in head:
                    continue
                fields = {}
                for field in ['text']:
                    found = re.search(
                        r'android\.' + field + r'=String \((.*?)\)\n', block, re.S,
                    )
                    if found:
                        fields[field] = found.group(1)
                if not only_answer or fields.get('text') == answer:
                    identifier = int(re.search(r'\bid=(\d+)', head).group(1))
                    result[identifier] = {'head': head, **fields}
            return result

        def wait_for_notice():
            for _ in range(60):
                found = notices()
                if found:
                    return found
                time.sleep(.25)
            return {}

        def ready():
            for _ in range(30):
                try:
                    return request('', {})
                except OSError:
                    time.sleep(.5)
            raise AssertionError('QA fixture did not restart')

        ready()
        request('preview', {'enabled': True})
        request('reply', {'text': answer})
        before = wait_for_notice()
        assert len(before) == 1, f'Expected one newly posted QA reply: {before}'
        identifier = next(iter(before))
        for expanded in (False, True):
            native.shown_notification('Website refresh', expanded=expanded, required=[answer])
        print('PASS: fresh unread QA reply appears in one notification slot', flush=True)

        command('shell', 'am', 'force-stop', PACKAGE)
        assert not notices(), 'Android did not remove the notification on force-stop'
        command('shell', 'am', 'start', '-n', ACTIVITY)
        restored = wait_for_notice()
        assert set(restored) == {identifier}, (
            f'Unread reply not restored to its original slot after relaunch: {restored}'
        )
        for expanded in (False, True):
            native.shown_notification('Website refresh', expanded=expanded, required=[answer])
        head = restored[identifier]['head']
        assert 'ONLY_ALERT_ONCE' in head and 'SILENT' in head, head
        print('PASS: relaunch restores the same unread reply and ID silently', flush=True)

        def shade_target():
            card = native.shown_notification('Website refresh', expanded=True, required=[answer])
            target = next((node for node in card.iter('node') if node.get('text') == answer), None)
            assert target is not None, 'Exact restored answer is not exposed on the owning card'
            return list(map(int, re.findall(r'\d+', target.get('bounds'))))

        # Shade inspection backgrounds the idle fixture, which Android may
        # freeze. Reenter it before this explicit list command. The subsequent
        # body tap must still establish its own exact destination unaided.
        command('shell', 'am', 'start', '-n', ACTIVITY)
        ready()
        request('list', {})
        assert identifier in notices(), 'Opening only the list marked the answer read'
        x1, y1, x2, y2 = shade_target()
        command('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
        native.until(lambda: ready()['chat_visible'] and ready()['read_guards']['selected_is_target'],
                     'Restored notification did not open its exact owner')
        opened = ready()
        assert opened['read_acks'] == [], 'Opening alone acknowledged the restored answer'
        assert any(value['result'] is not None for value in json.loads(opened['notices']).values()), \
            'Opening alone marked the restored answer read'
        native.scroll_through_answer(answer)
        def read_completed():
            current = ready()
            return (all(value['result'] is None for value in json.loads(current['notices']).values())
                    and current['read_acks'] == [{'profile': 'a', 'session': 'same'}]
                    and not current['mark_read_failed'])
        native.until(read_completed, 'Scrolling did not acknowledge the restored answer')
        assert identifier not in notices(only_answer=False), 'Read notification is still posted'
        print('PASS: tap preserves unread answer; scrolling acknowledges its exact owner and clears the result', flush=True)
        command('shell', 'am', 'force-stop', PACKAGE)
        command('shell', 'am', 'start', '-n', ACTIVITY)
        ready()
        for _ in range(12):
            assert identifier not in notices(only_answer=False), 'Read reply resurrected'
            time.sleep(.25)
        print('PASS: read reply stays absent after another launch', flush=True)

        # A separate fresh result tests the actual Android delete intent.
        answer = f'WING-DISMISS-QA-{time.time_ns()}: Swipe this fresh result.'
        request('reply', {'text': answer})
        dismissal = wait_for_notice()
        assert len(dismissal) == 1, 'Exactly one fresh dismissal sample must arrive'
        identifier = next(iter(dismissal))
        x1, y1, x2, y2 = shade_target()
        width = int(re.search(r'(\d+)x\d+', command('shell', 'wm', 'size')).group(1))
        command(
            'shell', 'input', 'swipe', str(width // 8), str((y1 + y2) // 2),
            str(width - 5), str((y1 + y2) // 2), '300',
        )
        for _ in range(20):
            if identifier not in notices(only_answer=False):
                break
            time.sleep(.25)
        else:
            raise AssertionError('Swipe did not remove the QA notification')
        command('shell', 'cmd', 'statusbar', 'collapse')
        command('shell', 'am', 'force-stop', PACKAGE)
        command('shell', 'am', 'start', '-n', ACTIVITY)
        for _ in range(30):
            try:
                request('', {})
                break
            except OSError:
                time.sleep(.5)
        else:
            raise AssertionError('QA fixture did not restart')
        for _ in range(12):
            assert identifier not in notices(only_answer=False), (
                'Explicitly dismissed reply resurrected after relaunch'
            )
            time.sleep(.25)
        print('PASS: explicitly swiped reply stays absent after another relaunch', flush=True)
    finally:
        command('forward', '--remove', f'tcp:{args.port}')


if __name__ == '__main__':
    main()
