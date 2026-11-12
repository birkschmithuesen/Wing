#!/usr/bin/env python3
"""Assert native notification delivery on an emulator, including forced Doze.

Build/install integration_test/background_monitoring_device.dart first.
This fixture must never be installed over a user's production app.
"""
# Optimization would remove the verdict assertions below.
if not __debug__:
    raise RuntimeError("Native acceptance requires Python assertions; remove -O/PYTHONOPTIMIZE")

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


def require_single_monitoring_card(dump, package):
    """Every active monitoring-channel record belongs to the one FGS card."""
    records = []
    for block in re.split(r'(?=NotificationRecord\()', dump):
        if not block:
            continue
        header = block.splitlines()[0]
        if (re.match(r'NotificationRecord\([^\n]*pkg=' + re.escape(package) + r'(?:\s|$)', header)
                and re.search(r'\bchannel=hermes_monitoring\b', header)):
            records.append(header)
    assert len(records) == 1, f'Expected one monitoring card, got {len(records)}: {records}'
    assert re.search(r'\bid=214601\b', records[0]), records
    assert 'FOREGROUND_SERVICE' in records[0], records
    return records[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', default='emulator-5554')
    parser.add_argument('--port', type=int, default=0,
                        help='Host forward port; zero allocates an owned ephemeral port.')
    parser.add_argument('--output', type=Path, required=True,
                        help='Attempt-owned status and failure diagnostics directory.')
    parser.add_argument('--resource-dir', type=Path,
                        help='Optional CPU/PSS diagnostics during the two 35s polling windows; no battery verdict.')
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        raise SystemExit('This test changes device power settings; use an emulator.')
    if not 0 <= args.port <= 65535:
        raise SystemExit('Forward port must be between 0 and 65535')
    args.output.mkdir(parents=True, exist_ok=True)
    package = 'com.tarkilhk.wing.dev'

    def adb(*parts):
        return subprocess.check_output(['adb', '-s', args.serial, *parts], text=True, timeout=30)

    def shell(*parts):
        return adb('shell', *parts)

    def request(path='/status', body=None):
        return json.load(urllib.request.urlopen(urllib.request.Request(
            f'http://127.0.0.1:{args.port}{path}',
            data=body.encode() if body is not None else None,
        ), timeout=15))

    def until(action, message, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = action()
                if value:
                    return value
            except (OSError, ValueError):
                pass
            time.sleep(.25)
        raise AssertionError(message)

    def foreground():
        return 'isForeground=true' in shell('dumpsys', 'activity', 'services', package)

    def notification_present(number):
        dump = shell('dumpsys', 'notification', '--noredact')
        return bool(re.search(
            rf'NotificationRecord\([^\n]*pkg={re.escape(package)}[^\n]*id={number}\b', dump))

    def notification_record(number):
        dump = shell('dumpsys', 'notification', '--noredact')
        for record in re.split(r'(?=^[ \t]*NotificationRecord\()', dump, flags=re.MULTILINE):
            if not re.search(
                    rf'NotificationRecord\([^\n]*pkg={re.escape(package)}[^\n]*id={number}\b',
                    record):
                continue
            return record
        return None

    def notification_icon(number):
        record = notification_record(number)
        icon = re.search(r'icon=Icon\([^\n]*id=([^\s)]+)', record or '')
        return icon.group(1) if icon else None

    def monitoring_started():
        until(foreground, 'Working chat did not start monitoring')
        icon = until(lambda: notification_icon(214601), 'Monitoring card missing')
        assert not notification_present(214602), 'Obsolete monitoring summary was posted'
        dump = shell('dumpsys', 'notification', '--noredact')
        capture = args.output / f'monitoring-cards-{time.monotonic_ns()}.txt'
        capture.write_text(dump)
        require_single_monitoring_card(dump, package)
        locks = shell('dumpsys', 'power').split('Wake Locks:', 1)[1].split('Suspend Blockers:', 1)[0]
        assert 'hermes-monitoring' in locks, 'Working chat has no monitoring wake lock'
        return icon

    def launch():
        shell('am', 'start', '-n', f'{package}/com.tarkilhk.wing.MainActivity')
        until(lambda: request()['lifecycle'] == 'resumed', 'Wing did not resume')

    def background():
        shell('input', 'keyevent', 'KEYCODE_HOME')
        until(lambda: request()['lifecycle'] == 'paused',
              'Wing did not finish entering the background')

    def event(profile, state):
        status = request('/event', json.dumps({'profile': profile, 'state': state}))
        with (args.output / 'events.jsonl').open('a') as stream:
            stream.write(json.dumps({'profile': profile, 'requested_state': state,
                                     'observed': status}) + '\n')
        return status

    def capture_failure():
        # Keep the original verdict; diagnostics cannot replace or mask it.
        try:
            (args.output / 'failure-status.json').write_text(json.dumps(request(), indent=2))
        except Exception as error:
            (args.output / 'failure-status-error.txt').write_text(repr(error))
        probes = {
            'services': ('dumpsys', 'activity', 'services', package),
            'activities': ('dumpsys', 'activity', 'activities'),
            'window': ('dumpsys', 'window', 'windows'),
            'power': ('dumpsys', 'power'),
            'notifications': ('dumpsys', 'notification', '--noredact'),
            'deviceidle': ('dumpsys', 'deviceidle'),
            'fixture-logcat': ('logcat', '-d', '-t', '300', '-s', 'flutter', 'MonitoringRuntime'),
        }
        for name, command in probes.items():
            try:
                value = shell(*command)
            except Exception as error:
                value = repr(error)
            (args.output / (name + '.txt')).write_text(value)


    def alert(number):
        until(lambda: notification_present(240000 + number), 'Chat notification missing')

    def stopped():
        until(lambda: not foreground(), 'Service did not stop after work ended')
        until(lambda: not notification_present(214601), 'Monitoring notification remained')
        until(lambda: not notification_present(214602), 'Monitoring summary remained')
        locks = shell('dumpsys', 'power').split('Wake Locks:', 1)[1].split('Suspend Blockers:', 1)[0]
        assert 'hermes-monitoring' not in locks, 'Wake lock leaked after work ended'

    def polling_status():
        status = request()
        assert status.get('fixture') == 'background-monitoring-native', 'Wrong native fixture'
        assert status.get('buildMode') in {'debug', 'profile'}, 'Use a diagnostic debug/profile build'
        probe = status.get('notificationPoll')
        assert isinstance(probe, dict), 'Polling instrumentation missing'
        assert probe.get('schema') == 1 and probe.get('periodSeconds') == 30, 'Wrong polling probe'
        assert all(type(probe.get(field)) is int and probe[field] >= 0
                   for field in ('created', 'active', 'ticks')), 'Invalid polling instrumentation'
        assert probe['active'] <= probe['created'], 'Invalid active polling timer count'
        return status

    def observe_polling(active):
        baseline = polling_status()
        expected = 1 if active else 0
        assert baseline['notificationPoll']['active'] == expected, 'Wrong initial polling timer count'
        label = 'active background' if active else 'settled background'
        print(f'Observing {label} polling for 35s ({baseline["buildMode"]} emulator diagnostics)', flush=True)
        recorder = None
        output = None
        if args.resource_dir is not None:
            output = args.resource_dir / ('active-background.json' if active else 'settled-background.json')
            recorder = subprocess.Popen([
                sys.executable, str(Path(__file__).with_name('record_phone_resources.py')),
                '--serial', args.serial, '--package', package,
                '--label', f'emulator-{baseline["buildMode"]}-{label.replace(" ", "-")}',
                '--samples', '6', '--interval', '5', '--output', str(output),
            ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 35
            while True:
                status = polling_status()
                probe = status['notificationPoll']
                assert status['generation'] == baseline['generation'], 'Fixture engine restarted during polling capture'
                assert status['lifecycle'] != 'resumed', 'Polling scenario returned to foreground'
                assert probe['active'] == expected, 'Polling timer did not match background work'
                assert probe['created'] == baseline['notificationPoll']['created'], 'Polling timer restarted during stable capture'
                if not active:
                    assert probe['ticks'] == baseline['notificationPoll']['ticks'], 'Settled background polling continued'
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                time.sleep(min(1, remaining))
            if active:
                assert probe['ticks'] > baseline['notificationPoll']['ticks'], 'Production notification poll never fired'
            if recorder is not None:
                _, error = recorder.communicate(timeout=20)
                assert recorder.returncode == 0, f'Resource capture failed: {error}'
                report = json.loads(output.read_text())
                assert report['app_present_every_sample'], 'Resource capture lost the fixture process'
                assert report['start']['app_pids'] == report['end']['app_pids'], 'Fixture process changed during resource capture'
                print(f'DIAGNOSTIC: {label} mean CPU={report["app_mean_cpu_percent"]}% '
                      f'end memory KiB={report["end"]["app_memory_kb"]}; {output}', flush=True)
        finally:
            if recorder is not None and recorder.poll() is None:
                recorder.terminate()
                recorder.communicate(timeout=5)
        print(f'PASS: {label} polling active={probe["active"]} '
              f'ticks={probe["ticks"] - baseline["notificationPoll"]["ticks"]}', flush=True)

    prior_exempt = package in shell('dumpsys', 'deviceidle', 'whitelist')
    allocated = adb('forward', '--no-rebind', f'tcp:{args.port}', 'tcp:18765').strip()
    if args.port == 0:
        args.port = int(allocated)
    try:
        shell('cmd', 'statusbar', 'collapse')
        shell('am', 'force-stop', package)
        shell('pm', 'grant', package, 'android.permission.POST_NOTIFICATIONS')
        # Wing's startup microphone prompt otherwise takes foreground focus
        # before this monitoring-only fixture starts work. Permission denial and
        # retry are exercised separately by the native voice-permission driver.
        shell('pm', 'grant', package, 'android.permission.RECORD_AUDIO')
        # Completed onboarding is required before working-state/Doze checks.
        # Otherwise Android's startup battery dialog leaves the app inactive.
        # Startup prompting is a separate acceptance boundary.
        shell('dumpsys', 'deviceidle', 'whitelist', f'+{package}')
        shell('input', 'keyevent', 'KEYCODE_WAKEUP')
        shell('wm', 'dismiss-keyguard')
        launch()
        until(lambda: request()['ready'] and request()['lifecycle'] == 'resumed',
              'Fixture did not establish its gateway in the foreground')
        generation = request()['generation']
        stopped()
        assert polling_status()['notificationPoll']['active'] == 0, 'Idle startup scheduled notification polling'
        print('PASS: idle startup has no monitoring icon, wake lock or polling timer', flush=True)

        event('a', 'working')
        monitoring_icon = monitoring_started()
        event('b', 'working')
        assert monitoring_started() == monitoring_icon, 'Second chat changed the monitoring icon'
        background()
        until(lambda: polling_status()['notificationPoll']['active'] == 1, 'Working chats did not schedule polling')
        observe_polling(active=True)
        event('a', 'waiting')
        alert(1)
        assert monitoring_started() == monitoring_icon, 'Waiting chat changed monitoring'
        question_icon = until(lambda: notification_icon(240001), 'Question icon missing')
        assert question_icon != monitoring_icon, 'Connection/chat icons match'
        event('b', 'idle')
        alert(2)
        stopped()
        until(lambda: polling_status()['notificationPoll']['active'] == 0, 'Last finish did not cancel polling')
        observe_polling(active=False)
        assert notification_present(240001), 'Question disappeared when monitoring stopped'
        assert notification_present(240002), 'Reply disappeared when monitoring stopped'
        print('PASS: multiple chats share monitoring; last finish stops it and retains alerts', flush=True)

        launch()
        assert not foreground(), 'Opening a waiting chat restarted monitoring'
        event('a', 'working')
        monitoring_started()
        background()
        event('a', 'idle')
        alert(3)
        stopped()
        print('PASS: answering resumes monitoring; final reply releases it', flush=True)

        launch()
        event('a', 'working')
        monitoring_started()
        request('/close-activity', '')
        until(lambda: request()['lifecycle'] == 'detached', 'Activity was not destroyed')
        launch()
        assert request()['generation'] == generation, 'Running work lost its retained engine'
        request('/close-activity', '')
        until(lambda: request()['lifecycle'] == 'detached', 'Activity was not destroyed')
        try:
            event('a', 'waiting')
        except OSError:
            # With no Activity or working chats, Android can release this engine
            # after posting the question, before the fixture replies over HTTP.
            pass
        alert(4)
        stopped()
        assert notification_present(240004), 'Question was lost during engine release'
        launch()
        assert request()['generation'] != generation, 'Idle detached engine was not released'
        stopped()
        print('PASS: running work retains the engine; final question survives engine release', flush=True)

        shell('dumpsys', 'deviceidle', 'whitelist', f'+{package}')
        event('a', 'working')
        event('b', 'working')
        monitoring_started()
        background()
        shell('input', 'keyevent', 'KEYCODE_SLEEP')
        shell('dumpsys', 'battery', 'unplug')
        shell('dumpsys', 'deviceidle', 'force-idle')
        assert 'mState=IDLE' in shell('dumpsys', 'deviceidle')
        event('a', 'waiting')
        until(lambda: request()['alerts'] == 1, 'Question lost in Doze')
        monitoring_started()
        event('b', 'idle')
        until(lambda: request()['alerts'] == 2, 'Reply lost in Doze')
        stopped()
        assert notification_present(240001) and notification_present(240002)
        print('PASS: question/reply delivery and automatic shutdown work during Doze', flush=True)

        shell('dumpsys', 'deviceidle', 'unforce')
        shell('dumpsys', 'battery', 'reset')
        shell('input', 'keyevent', 'KEYCODE_WAKEUP')
        shell('wm', 'dismiss-keyguard')
        launch()
        event('a', 'working')
        monitoring_started()
        request('/alerts', 'false')
        stopped()
        request('/alerts', 'true')
        monitoring_started()
        background()
        event('a', 'idle')
        until(lambda: request()['alerts'] == 3, 'Final reply did not post')
        stopped()
        records = re.split(
            r'(?=^[ \t]*NotificationRecord\()',
            shell('dumpsys', 'notification', '--noredact'), flags=re.MULTILINE)
        rich = next(record for record in records if re.search(
            rf'NotificationRecord\([^\n]*pkg={re.escape(package)}[^\n]*id=240003\b', record))
        assert 'First task' in rich, 'Chat title missing'
        assert 'android.bigText' in rich and 'More readable context.' in rich, 'Expanded text missing'
        assert 'Monitoring fixture / a' in rich, 'Connection/profile missing'
        assert 'vis=PRIVATE' in rich, 'Chat content is not private on the lock screen'
        print('PASS: alert preferences and rich private notifications are preserved', flush=True)
    except BaseException:
        capture_failure()
        raise
    finally:
        failed = sys.exc_info()[0] is not None
        cleanup_errors = []
        cleanup = [
            ('deviceidle', lambda: shell('dumpsys', 'deviceidle', 'unforce')),
            ('battery', lambda: shell('dumpsys', 'battery', 'reset')),
            *([] if prior_exempt else [
                ('whitelist', lambda: shell('dumpsys', 'deviceidle', 'whitelist', f'-{package}'))]),
            ('forward', lambda: adb('forward', '--remove', f'tcp:{args.port}')),
        ]
        for name, action in cleanup:
            try:
                action()
            except Exception as error:
                cleanup_errors.append({'resource': name, 'error': repr(error)})
        (args.output / 'cleanup.json').write_text(json.dumps({
            'forward_port': args.port, 'errors': cleanup_errors,
        }, indent=2) + '\n')
        if cleanup_errors:
            if failed:
                print('Additional cleanup failures: ' + repr(cleanup_errors), file=sys.stderr)
            else:
                raise RuntimeError('Native cleanup failed: ' + repr(cleanup_errors))


if __name__ == '__main__':
    main()
