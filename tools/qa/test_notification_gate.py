"""Keep the notification regression harness fail-closed at its OS boundary."""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET

import check_notification_revamp as driver
import run_notification_gate as gate


class NotificationCaptureTest(unittest.TestCase):
    def test_long_review_reveals_actions_through_input_needed_without_deciding(self):
        cue = ET.Element('node', {'content-desc': 'Input needed', 'enabled': 'true',
                                  'bounds': '[100,600][150,650]'})
        choices = [ET.Element('node', {'content-desc': label, 'enabled': 'true'})
                   for label in ('Approve once', 'Approve for session', 'Always approve', 'Reject')]
        with patch.object(driver, 'nodes', side_effect=[[cue], choices]), \
             patch.object(driver, 'tap_notification_node') as tap, \
             patch.object(driver.time, 'sleep'):
            driver.wait_for_approval_choices()
        tap.assert_called_once_with(cue)

    def test_failed_dump_cannot_reuse_a_previous_successful_capture(self):
        with patch.object(driver, 'adb', side_effect=[
            'ERROR: null root node', '<hierarchy><node text="stale reply"/></hierarchy>',
        ]) as adb:
            with self.assertRaises(ValueError):
                driver.nodes()
        self.assertEqual(adb.call_count, 1, 'Failed dump must not read stale XML')

    def test_successful_dump_reads_current_hierarchy(self):
        with patch.object(driver, 'adb', side_effect=[
            'UI hierchary dumped to: /sdcard/wing-notification-ui.xml',
            '<hierarchy><node text="current reply"/></hierarchy>',
        ]):
            self.assertEqual(driver.nodes()[0].get('text'), 'current reply')


class NotificationShadeNavigationTest(unittest.TestCase):
    def test_pull_waits_until_quick_settings_has_closed_to_the_launcher(self):
        shown = None
        quick = [ET.Element('node', {'package': 'com.android.systemui'})]
        home = [ET.Element('node', {'package': 'owned.launcher'})]
        notice = [ET.Element('node', {'resource-id': 'android:id/app_name_text'})]
        captures = iter([quick, home, notice])
        pulls = []

        def capture():
            nonlocal shown
            shown = next(captures)
            return shown

        def adb(*args):
            if args == ('shell', 'wm', 'size'):
                return 'Physical size: 1080x1920'
            if 'resolve-activity' in args:
                return 'owned.launcher/.Home'
            if 'swipe' in args:
                self.assertIs(shown, home, 'Do not pull again while Quick Settings still owns the screen')
                pulls.append(args)
            return ''

        with patch.object(driver, 'adb', side_effect=adb), \
             patch.object(driver, 'nodes', side_effect=capture), \
             patch.object(driver.time, 'sleep'):
            driver.shade(expand=False)
        self.assertEqual(len(pulls), 1)
        self.assertIs(shown, notice)


class ColdChatPublicationTest(unittest.TestCase):
    def exercise(self, never_publishes=False):
        answer = 'This exact individual answer must survive cold startup.'
        reads = 0
        killed = False
        clock = [0.0]
        def state(path='/', data=None):
            nonlocal reads
            if path == '/':
                reads += 1
            preview = answer if reads >= 2 and not never_publishes else 'Previous reply'
            return {'selected_profile': 'a', 'notices': json.dumps({
                json.dumps({'profile': 'a'}): {
                    'result': {'content': {'preview': preview}},
                    'rendered': json.dumps({'id': 42}),
                }})}
        def adb(*args):
            nonlocal killed
            if args[:3] == ('shell', 'run-as', driver.PACKAGE):
                self.assertGreaterEqual(reads, 2,
                    'Cold tap must not kill Wing before the exact new reply is published')
                self.assertFalse(never_publishes)
                killed = True
            if args[:2] == ('shell', 'pidof'):
                return '99'
            return ''
        def tap(**kwargs):
            self.assertTrue(killed)
            self.assertEqual(kwargs['text'], answer)
        def sleep(seconds):
            clock[0] += seconds
        try:
            with patch.object(driver, 'state', side_effect=state), \
                 patch.object(driver, 'adb', side_effect=adb), \
                 patch.object(driver, 'tap', side_effect=tap), \
                 patch.object(driver, 'shade'), patch.object(driver, 'screenshot'), \
                 patch.object(driver, 'nodes', return_value=[ET.Element('node', text=answer)]), \
                 patch.object(driver.time, 'sleep', side_effect=sleep), \
                 patch.object(driver.time, 'monotonic', side_effect=lambda: clock[0]):
                driver.check_cold_chat_body_tap(Path('unused'))
        finally:
            if never_publishes:
                self.assertFalse(killed)
        self.assertTrue(killed)

    def test_exact_new_reply_is_published_before_process_death(self):
        self.exercise()

    def test_old_published_reply_cannot_admit_killing_the_process(self):
        with self.assertRaisesRegex(AssertionError, '^Exact reply notification was not published$'):
            self.exercise(never_publishes=True)


class NotificationFixtureSetupTest(unittest.TestCase):
    def test_provisions_only_qa_permissions_before_first_launch(self):
        calls = []
        with patch.object(driver, 'SERIAL', 'emulator-5562'), \
             patch.object(driver, 'adb', side_effect=lambda *args: calls.append(args)), \
             patch.object(driver, 'until'), patch.object(driver, 'state'), \
             patch.object(driver, 'check_content_tap_clear', side_effect=RuntimeError('journey reached')):
            with self.assertRaisesRegex(RuntimeError, 'journey reached'):
                driver.run(Path('unused'), tap_only=True)
        clear = calls.index(('shell', 'pm', 'clear', driver.PACKAGE))
        grant = calls.index(('shell', 'pm', 'grant', driver.PACKAGE,
                             'android.permission.POST_NOTIFICATIONS'))
        exempt = calls.index(('shell', 'dumpsys', 'deviceidle', 'whitelist', '+' + driver.PACKAGE))
        launch = calls.index(('shell', 'am', 'start', '-n',
                              driver.PACKAGE + '/com.tarkilhk.wing.MainActivity'))
        self.assertLess(clear, grant)
        self.assertLess(grant, launch)
        self.assertLess(exempt, launch)


class MonitoringPublicationTest(unittest.TestCase):
    @staticmethod
    def record(package=driver.PACKAGE, slot=214601, channel='hermes_monitoring'):
        return (f'    NotificationRecord(0x123: pkg={package} user=UserHandle{{0}} '
                f'id={slot} tag=null: Notification(channel={channel} shortcut=null))\n')

    def test_only_the_active_owned_monitoring_slot_establishes_readiness(self):
        for package, slot, channel in [(driver.PACKAGE, 214601, 'hermes_monitoring'),
                                      ('other.app', 214601, 'hermes_monitoring'),
                                      (driver.PACKAGE, 214602, 'hermes_monitoring'),
                                      (driver.PACKAGE, 214601, 'wing_attention_notifications')]:
            with self.subTest(package=package, slot=slot, channel=channel):
                dump = '  Notification List:\n' + self.record(package, slot, channel)
                with patch.object(driver, 'adb', return_value=dump):
                    self.assertEqual(driver.monitoring_notification_posted(),
                                     package == driver.PACKAGE and slot == 214601
                                     and channel == 'hermes_monitoring')

    def test_archived_or_snoozed_monitoring_is_not_posted(self):
        for heading in ('mArchive=Archive (1 notifications)', 'Snoozed notifications:'):
            with self.subTest(heading=heading), patch.object(driver, 'adb', return_value=(
                    '  Notification List:\n  ' + heading + '\n' + self.record())):
                self.assertFalse(driver.monitoring_notification_posted())

    def test_waits_for_publication_after_the_service_has_started(self):
        with patch.object(driver, 'adb', side_effect=[
                '  Notification List:\n  mArchive=Archive (0 notifications)\n',
                '  Notification List:\n' + self.record(),
        ]) as adb, patch.object(driver.time, 'sleep'):
            driver.wait_for_monitoring_notification()
        self.assertEqual(adb.call_count, 2)

    def test_missing_publication_fails_within_the_existing_deadline(self):
        with patch.object(driver, 'adb', return_value='  Notification List:\n'), \
             patch.object(driver.time, 'monotonic', side_effect=[0, 0, 46]), \
             patch.object(driver.time, 'sleep'):
            with self.assertRaisesRegex(AssertionError, 'not posted before leaving'):
                driver.wait_for_monitoring_notification()


class NotificationDismissalTest(unittest.TestCase):
    def exercise(self, notification_dump, selected_is_target=True, delayed_publication=False):
        replied = False
        publication_reads = 0
        held = False
        released = False

        def state(path='/', data=None):
            nonlocal held, released, replied, publication_reads
            if path == '/reply':
                replied = True
            elif path == '/' and replied and not held:
                publication_reads += 1
            if path == '/hold-history':
                held = True
            if path == '/release-history':
                released = True
            return {'notices': json.dumps({json.dumps({'profile': 'a'}): {
                        'result': {'content': {'preview': (
                            'Read this notification while history is held.'
                            if not delayed_publication or publication_reads >= 2
                            else 'A previously published reply')}},
                        'rendered': json.dumps({'id': 42001}),
                    }}), 'lifecycle': 'resumed' if held else 'paused',
                    'chat_visible': held, 'history_held': held,
                    'read_guards': {'selected_is_target': selected_is_target}}

        def adb(*args):
            if args[:2] == ('shell', 'dumpsys'):
                self.assertTrue(held)
                self.assertFalse(released, 'Check Android before releasing history')
                return notification_dump
            return ''

        try:
            with patch.object(driver, 'state', side_effect=state), \
                 patch.object(driver, 'adb', side_effect=adb), \
                 patch.object(driver, 'shade'), patch.object(driver, 'tap'), \
                 patch.object(driver, 'nodes', return_value=[ET.Element(
                     'node', text='Read this notification while history is held.')]):
                driver.check_content_tap_clear()
        finally:
            self.assertTrue(released, 'Release held history even after assertion failure')
        return publication_reads

    def test_waits_for_actual_publication_before_opening_the_shade(self):
        self.assertGreaterEqual(self.exercise('', delayed_publication=True), 2)

    def test_same_native_slot_remaining_is_a_failure(self):
        with self.assertRaisesRegex(AssertionError, 'left its notification'):
            self.exercise(f'NotificationRecord(pkg={driver.PACKAGE} id=42001 tag=null)')

    def test_other_apps_and_other_chat_slots_are_allowed(self):
        self.exercise('NotificationRecord(pkg=other.app id=42001 tag=null)\n'
                      f'NotificationRecord(pkg={driver.PACKAGE} id=42002 tag=null)')

    def test_opening_an_unrelated_chat_is_not_success(self):
        with self.assertRaisesRegex(AssertionError, 'different chat'):
            self.exercise('', selected_is_target=False)


class DirectActionConfigurationTest(unittest.TestCase):
    def test_restores_normal_text_before_posting_direct_action_request(self):
        calls = []
        def state(path='/', data=None):
            if path == '/approval':
                calls.append(('approval',))
                raise RuntimeError('request reached')
            return {'decisions': []}
        with patch.object(driver, 'adb', side_effect=lambda *args: calls.append(args)), \
             patch.object(driver, 'state', side_effect=state), \
             patch.object(driver, 'until'), patch.object(driver.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'request reached'):
                driver.check_direct_actions(Path('unused'))
        self.assertLess(calls.index(('shell', 'settings', 'put', 'system', 'font_scale', '1.0')),
                        calls.index(('approval',)))


class ColdActionReceiptTest(unittest.TestCase):
    def test_atomic_preference_write_is_retried_before_accepting_exact_receipt(self):
        reads = 0

        def adb(*args):
            nonlocal reads
            if args[-1] == 'shared_prefs/FlutterSharedPreferences.xml':
                reads += 1
                if reads == 1:
                    raise subprocess.CalledProcessError(1, 'cat')
                return ('<map><string name="flutter.notification_qa_decisions">'
                        '[{"params":{"prompt_id":"cold-request","execution_generation":0}}]'
                        '</string></map>')
            return ''

        def until(check, message, **kwargs):
            for _ in range(3):
                observed = check()
                if observed:
                    return observed
            raise AssertionError(message)

        with patch.object(driver, 'adb', side_effect=adb), \
             patch.object(driver, 'state', return_value={
                 'decisions': [], 'pending': [{'request_id': 'cold-request'}],
             }), patch.object(driver, 'until', side_effect=until), \
             patch.object(driver, 'shade'), patch.object(driver, 'tap'), \
             patch.object(driver, 'screenshot'), patch.object(driver, 'nodes', return_value=[]):
            driver.check_cold_action(Path('unused'))
        self.assertGreaterEqual(reads, 2)


class GroupBodyDestinationTest(unittest.TestCase):
    def exercise(self, visible_answer):
        def until(check, message, **kwargs):
            if not check():
                raise AssertionError(message)
        def adb(*args):
            return '' if 'pidof' not in args or len(args) == 2 else '123'
        with tempfile.TemporaryDirectory() as output, \
             patch.object(driver, 'adb', side_effect=adb), \
             patch.object(driver, 'state', return_value={
                 'lifecycle': 'paused', 'group_notification_id': 42, 'decisions': [],
             }), patch.object(driver, 'until', side_effect=until), \
             patch.object(driver, 'shade') as shade, patch.object(driver, 'tap'), \
             patch.object(driver, 'screenshot'), \
             patch.object(driver, 'nodes', return_value=[ET.Element('node', text=visible_answer)]):
            driver.check_group_body_taps(Path(output))
            self.assertEqual(shade.call_count, 3)
            for call in shade.call_args_list:
                self.assertEqual(call.kwargs, {'expand': False})

    def test_a_running_app_or_an_unrelated_chat_is_not_group_tap_success(self):
        with self.assertRaisesRegex(AssertionError, 'NATIVE_GROUP_BODY_TAP'):
            self.exercise('Some other chat')

    def test_default_shade_warm_approval_and_cold_taps_require_the_shared_answer(self):
        self.exercise('The shared discussion reached its exact destination.')


class NotificationGateTest(unittest.TestCase):
    def setUp(self):
        output = tempfile.TemporaryDirectory(prefix='wing-notification-unit-')
        self.addCleanup(output.cleanup)
        location = patch.object(gate, 'OUTPUT', Path(output.name))
        location.start()
        self.addCleanup(location.stop)
        sdk = patch.dict(os.environ, {'ANDROID_HOME': output.name})
        sdk.start()
        self.addCleanup(sdk.stop)

    @unittest.skipUnless(os.name == 'posix', 'Exercises the Linux CI SDK executables')
    def test_real_ci_entry_point_propagates_device_driver_failure(self):
        with tempfile.TemporaryDirectory(prefix='wing-notification-cli-') as directory:
            root = Path(directory)

            def executable(relative, source):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f'#!{sys.executable}\n' + source)
                path.chmod(0o700)

            executable('bin/flutter', 'print("QA fixture build reached")\n')
            executable('sdk/platform-tools/adb', '''import sys
if sys.argv[1:] == ['devices']:
    print('List of devices attached')
elif sys.argv[3:] in (['shell', 'getprop', 'ro.kernel.qemu'],
                       ['shell', 'getprop', 'sys.boot_completed'],
                       ['shell', 'settings', 'get', 'secure', 'show_ime_with_hard_keyboard']):
    print('1')
elif sys.argv[3:] == ['shell', 'cmd', 'package', 'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.HOME']:
    print('com.android.launcher/.Home')
elif sys.argv[3:6] == ['shell', 'uiautomator', 'dump']:
    print('UI hierarchy dumped to: /sdcard/wing-boot-ui.xml')
elif sys.argv[3:5] == ['shell', 'cat']:
    print('<hierarchy><node package="com.android.launcher"/></hierarchy>')
elif sys.argv[3] == 'forward':
    sys.exit(23)
''')
            executable('sdk/cmdline-tools/latest/bin/avdmanager', 'pass\n')
            executable('sdk/emulator/emulator', 'import time\ntime.sleep(30)\n')
            (root / 'tools/qa').mkdir(parents=True)
            shutil.copyfile(driver.__file__, root / 'tools/qa/check_notification_revamp.py')
            result = subprocess.run(
                [sys.executable, str(Path(gate.__file__).resolve())], cwd=root,
                env={**os.environ, 'ANDROID_HOME': str(root / 'sdk'),
                     'PATH': str(root / 'bin')},
                capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('QA fixture build reached', result.stdout)
            self.assertIn('forward', result.stderr)
            self.assertIn('exit status 23', result.stderr)

    def test_never_installs_or_resets_a_phone(self):
        with patch.object(gate, 'device') as device, patch.object(gate, 'command') as command:
            with self.assertRaises(ValueError):
                gate.check_on_emulator('physical-phone')
        device.assert_not_called()
        command.assert_not_called()

    def test_emulator_name_alone_is_insufficient(self):
        with patch.object(gate, 'device', return_value='0'), patch.object(gate, 'command') as command:
            with self.assertRaises(ValueError):
                gate.check_on_emulator('emulator-5562')
        command.assert_not_called()

    def test_failure_capture_tolerates_unwritable_evidence_directory(self):
        with patch.object(Path, 'mkdir', side_effect=OSError('disk full')), \
             patch.object(gate, 'device') as device, \
             contextlib.redirect_stderr(io.StringIO()) as errors:
            gate.capture_failure('emulator-5562', Path('/unwritable'))
        device.assert_not_called()
        self.assertIn('disk full', errors.getvalue())

    def test_failure_capture_tolerates_unwritable_error_report(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(gate, 'device', side_effect=OSError('device unavailable')), \
             patch.object(gate.subprocess, 'run', side_effect=OSError('capture unavailable')), \
             patch.object(Path, 'write_text', side_effect=OSError('disk full')), \
             contextlib.redirect_stderr(io.StringIO()) as errors:
            gate.capture_failure('emulator-5562', Path(directory))
        self.assertIn('disk full', errors.getvalue())

    def test_only_observed_anr_captures_owned_android_bugreport(self):
        cases = [
            (('logcat', '-d', '-t', '3000'), 'ANR in com.tarkilhk.wing.dev'),
            (('shell', 'dumpsys', 'window'),
             'mCurrentFocus=Application Not Responding: com.android.systemui'),
            (None, 'ordinary assertion failure'),
        ]
        for trigger, evidence in cases:
            with self.subTest(trigger=trigger), tempfile.TemporaryDirectory() as directory:
                def device(serial, *args):
                    self.assertEqual(serial, 'emulator-5562')
                    return evidence if args == trigger else 'ordinary diagnostics'

                with patch.object(gate, 'device', side_effect=device), \
                     patch.object(gate, 'adb_path', return_value='/sdk/adb'), \
                     patch.object(gate.subprocess, 'run') as run:
                    gate.capture_failure('emulator-5562', Path(directory))
                reports = [call for call in run.call_args_list
                           if 'bugreport' in call.args[0]]
                self.assertEqual(len(reports), 0 if trigger is None else 1)
                if reports:
                    self.assertEqual(reports[0].args[0], [
                        '/sdk/adb', '-s', 'emulator-5562', 'bugreport',
                        str(Path(directory) / 'failure-bugreport.zip')])
                    self.assertTrue(reports[0].kwargs['check'])
                    self.assertEqual(reports[0].kwargs['timeout'], 120)

    def test_anr_bugreport_timeout_does_not_replace_original_failure(self):
        def run(command, **kwargs):
            if 'bugreport' in command:
                raise subprocess.TimeoutExpired(command, 120)

        with tempfile.TemporaryDirectory() as directory, \
             patch.object(gate, 'device', return_value='ANR in com.tarkilhk.wing.dev'), \
             patch.object(gate, 'adb_path', return_value='/sdk/adb'), \
             patch.object(gate.subprocess, 'run', side_effect=run):
            output = Path(directory)
            gate.capture_failure('emulator-5562', output)
            errors = json.loads((output / 'capture-errors.json').read_text())
            self.assertTrue(any('failure-bugreport.zip' in error for error in errors))
            self.assertIn('ANR in', (output / 'failure-logcat.txt').read_text())

    def test_shade_driver_failure_fails_the_gate(self):
        calls = []

        def command(*args, **kwargs):
            calls.append(args)
            if 'tools/qa/check_notification_revamp.py' in args:
                self.assertIn('--tap-only', args)
                raise subprocess.CalledProcessError(1, args)

        with tempfile.TemporaryDirectory() as directory, \
             patch.object(gate, 'OUTPUT', Path(directory)), \
             patch.object(gate, 'device', return_value='1'), \
             patch.object(gate, 'command', side_effect=command), \
             patch.object(gate.subprocess, 'run') as capture:
            with self.assertRaises(subprocess.CalledProcessError):
                gate.check_on_emulator('emulator-5562')
            self.assertEqual({p.name for p in Path(directory).iterdir()},
                             {'failure-logcat.txt', 'failure-activity.txt', 'failure-notifications.txt',
                              'failure-services.txt', 'failure-window.txt', 'failure-input-method.txt',
                              'failure-ui.xml', 'failure.png'})
        self.assertEqual(capture.call_args.args[0][-3:], ['exec-out', 'screencap', '-p'])


class OwnedEmulatorRetirementTest(unittest.TestCase):
    @contextlib.contextmanager
    def transport(self, *, disappears=True, occupied=False, query_failure=False):
        clock = [0.0]
        registered_until = [float('inf') if occupied else -1.0]
        processes = []

        def launch(*args, **kwargs):
            registered_until[0] = float('inf')
            process = Mock()
            process.pid = 123
            process.poll.return_value = None
            def stopped(*args, **kwargs):
                registered_until[0] = clock[0] + 0.5 if disappears else float('inf')
                return process.poll.return_value if process.poll.return_value is not None else 0
            process.wait.side_effect = stopped
            processes.append(process)
            return process

        def devices(*args, **kwargs):
            if query_failure and processes:
                raise subprocess.CalledProcessError(1, args[0])
            rows = 'List of devices attached\nother-device\tdevice\n'
            if clock[0] < registered_until[0]:
                rows += 'emulator-5562\toffline\n'
            return rows

        def advance(seconds):
            clock[0] += seconds

        with tempfile.TemporaryDirectory() as directory, \
             patch.object(gate, 'OUTPUT', Path(directory)), \
             patch.dict(os.environ, {'ANDROID_HOME': directory}), \
             patch.object(gate, 'command'), \
             patch.object(gate, 'device', return_value='1'), \
             patch.object(gate, 'prepare_owned_android'), \
             patch.object(gate.subprocess, 'Popen', side_effect=launch), \
             patch.object(gate.subprocess, 'check_output', side_effect=devices), \
             patch.object(gate.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(gate.time, 'sleep', side_effect=advance):
            yield processes, clock

    def test_next_suite_can_own_slot_after_process_exits_before_adb_unregisters(self):
        with self.transport() as (processes, clock):
            for _ in range(2):
                with gate.owned_emulator() as serial:
                    self.assertEqual(serial, 'emulator-5562')
            self.assertEqual(len(processes), 2)
            self.assertGreaterEqual(clock[0], 1.0)
            for process in processes:
                process.terminate.assert_called_once_with()
                process.kill.assert_not_called()

    def test_unexpected_exit_retains_signal_and_host_memory_evidence(self):
        with self.transport() as (processes, _):
            with gate.owned_emulator():
                processes[0].poll.return_value = -9
            evidence = json.loads((gate.OUTPUT / 'emulator-lifecycle.json').read_text())
            self.assertEqual(evidence['exit_before_cleanup'], -9)
            self.assertEqual(evidence['exit_after_cleanup'], -9)
            self.assertIn('before_start', evidence)
            self.assertIn('after_cleanup', evidence)
            self.assertIn('memory', evidence['before_start'])

    def test_unwritable_lifecycle_evidence_does_not_replace_native_failure(self):
        write_text = Path.write_text
        def write(path, *args, **kwargs):
            if path.name == 'emulator-lifecycle.json':
                raise PermissionError('evidence denied')
            return write_text(path, *args, **kwargs)
        with self.transport(), patch.object(Path, 'write_text', new=write), \
             contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaisesRegex(RuntimeError, 'native failure'):
                with gate.owned_emulator():
                    raise RuntimeError('native failure')
        self.assertIn('Could not record emulator lifecycle', errors.getvalue())

    def test_still_registered_after_deadline_fails_retirement(self):
        with self.transport(disappears=False) as (processes, clock):
            with self.assertRaisesRegex(TimeoutError, 'emulator-5562.*registered'):
                with gate.owned_emulator():
                    pass
            self.assertLessEqual(clock[0], 30)
            processes[0].kill.assert_not_called()

    def test_preexisting_serial_is_still_rejected_without_starting_or_stopping(self):
        with self.transport(occupied=True) as (processes, _):
            with self.assertRaisesRegex(ValueError, 'occupied'):
                with gate.owned_emulator():
                    self.fail('An occupied emulator is not ours')
            self.assertEqual(processes, [])

    def test_failed_adb_observation_cannot_establish_retirement(self):
        with self.transport(query_failure=True):
            with self.assertRaises(subprocess.CalledProcessError):
                with gate.owned_emulator():
                    pass


class OwnedAndroidBootTest(unittest.TestCase):
    def exercise(self, title=None, installed=False, repeat=False, failed_dump=False,
                 keyboard_enabled=True):
        launcher = '<hierarchy><node package="com.android.launcher"/></hierarchy>'
        alert = ('<hierarchy><node resource-id="android:id/alertTitle" text="' +
                 (title or '') + '"/><node resource-id="android:id/aerr_wait" '
                 'bounds="[0,0][100,100]"/></hierarchy>')
        reads = iter([alert, alert if repeat else launcher] if title else [launcher])
        calls = []
        dumped = False

        def device(serial, *args):
            nonlocal dumped
            calls.append(args)
            if args[:4] == ('shell', 'pm', 'list', 'packages'):
                return 'package:com.tarkilhk.wing.notificationqa' if installed else ''
            if args[:4] == ('shell', 'cmd', 'package', 'resolve-activity'):
                return 'com.android.launcher/.Home'
            if args[:3] == ('shell', 'uiautomator', 'dump'):
                if failed_dump and not dumped:
                    dumped = True
                    return 'ERROR: null root node'
                return 'UI hierarchy dumped to: /sdcard/wing-boot-ui.xml'
            if args[:2] == ('shell', 'cat'):
                return next(reads)
            if args == ('shell', 'settings', 'get', 'secure',
                        'show_ime_with_hard_keyboard'):
                return '1' if keyboard_enabled else '0'
            return ''

        with tempfile.TemporaryDirectory() as directory, \
             patch.object(gate, 'OUTPUT', Path(directory)), \
             patch.object(gate, 'device', side_effect=device), \
             patch.object(gate.time, 'sleep'):
            gate.prepare_owned_android('emulator-5562')
        return calls

    def test_requires_a_healthy_launcher_and_rejects_stale_dump(self):
        calls = self.exercise(failed_dump=True)
        self.assertEqual(sum(args[:3] == ('shell', 'uiautomator', 'dump') for args in calls), 2)
        self.assertEqual(sum(args[:2] == ('shell', 'cat') for args in calls), 1)

    def test_system_ui_boot_wait_is_allowed_once_before_fixture_installation(self):
        calls = self.exercise(title="System UI isn't responding")
        self.assertEqual(sum(args[:3] == ('shell', 'input', 'tap') for args in calls), 1)

    def test_never_recovers_a_fixture_anr_or_a_repeated_system_ui_anr(self):
        for title, repeat in [("Wing isn't responding", False),
                              ("System UI isn't responding", True)]:
            with self.subTest(title=title, repeat=repeat), self.assertRaises(RuntimeError):
                self.exercise(title=title, repeat=repeat)

    def test_never_runs_boot_recovery_when_fixture_is_installed(self):
        with self.assertRaises(ValueError):
            self.exercise(installed=True)

    def test_requires_real_software_keyboard_availability(self):
        with self.assertRaisesRegex(RuntimeError, 'software keyboard'):
            self.exercise(keyboard_enabled=False)


class GroupApprovalControlsTest(unittest.TestCase):
    def controls(self, *names):
        return [ET.Element('node', {'resource-id': 'android:id/action0',
                                  'text': name.title()})
                for name in names]

    def test_expands_the_exact_group_card_when_another_chat_is_first(self):
        root = ET.fromstring('''<hierarchy><node><node>
            <node text="Other chat"/>
            <node resource-id="android:id/expand_button" content-desc="Expand" bounds="[0,0][100,100]"/>
            </node><node><node text="Native group approval"/>
            <node resource-id="android:id/expand_button" content-desc="Expand" bounds="[200,200][300,300]"/>
            </node></node></hierarchy>''')
        shown = list(root.iter('node'))
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(driver, 'state'), patch.object(driver, 'shade'), \
             patch.object(driver, 'screenshot'), \
             patch.object(driver.time, 'sleep'), patch.object(driver, 'adb') as adb, \
             patch.object(driver, 'nodes', side_effect=[shown, self.controls('once', 'deny'),
                                                       shown, self.controls('review', 'deny')]):
            driver.check_group_approval_rendering(Path(directory))
        taps = [call.args for call in adb.call_args_list
                if call.args[:3] == ('shell', 'input', 'tap')]
        self.assertEqual(taps, [('shell', 'input', 'tap', '250', '250')] * 2)

    def test_supported_short_and_review_layouts_are_accepted(self):
        driver.assert_group_approval_controls(self.controls('once', 'deny'), False)
        driver.assert_group_approval_controls(self.controls('review', 'deny'), True)

    def test_unsupported_session_and_always_are_rejected(self):
        with self.assertRaisesRegex(AssertionError, 'NATIVE_GROUP_APPROVAL_RENDER'):
            driver.assert_group_approval_controls(self.controls('once', 'deny', 'session', 'always'), False)

    def test_missing_decision_or_wrong_layout_is_rejected(self):
        for names, review in [(('once',), False), (('once', 'deny'), True)]:
            with self.subTest(names=names, review=review), self.assertRaisesRegex(AssertionError, 'NATIVE_GROUP_APPROVAL_RENDER'):
                driver.assert_group_approval_controls(self.controls(*names), review)


class ColdActionPreferenceReadTest(unittest.TestCase):
    def test_cold_action_verdict_uses_the_receipt_returned_by_its_poll(self):
        receipt = [{'params': {'prompt_id': 'captured-request', 'execution_generation': 0}}]
        with patch.object(driver, 'state', return_value={
                'decisions': [], 'pending': [{'request_id': 'captured-request'}],
        }), patch.object(driver, 'adb', side_effect=lambda *args:
                '123' if args == ('shell', 'pidof', driver.PACKAGE) else ''), \
             patch.object(driver, 'shade'), patch.object(driver, 'tap'), \
             patch.object(driver, 'nodes', return_value=[]), \
             patch.object(driver, 'screenshot'), \
             patch.object(driver, 'saved_notification_decisions',
                          side_effect=[receipt, []]) as observations:
            driver.check_cold_action(Path('unused'))
        self.assertEqual(observations.call_count, 1)

    def test_atomic_replacement_retries_empty_and_partial_xml_until_exact_receipt(self):
        receipt = [{'params': {'prompt_id': 'captured-request', 'execution_generation': 0}}]
        complete = ET.Element('map')
        ET.SubElement(complete, 'string', {
            'name': 'flutter.notification_qa_decisions',
        }).text = json.dumps(receipt)
        with patch.object(driver, 'adb', side_effect=[
                '', '<map><string', ET.tostring(complete, encoding='unicode'),
        ]), patch.object(driver.time, 'sleep'):
            observed = driver.until(driver.saved_notification_decisions,
                                    'Cold action acknowledgement missing')
        self.assertEqual(observed, receipt)

    def test_complete_snapshot_without_acknowledgement_key_is_not_accepted(self):
        with patch.object(driver, 'adb', return_value='<map/>'):
            with self.assertRaises(StopIteration):
                driver.saved_notification_decisions()


class RestoredFixtureLifecycleTest(unittest.TestCase):
    def test_list_preparation_foregrounds_a_fixture_frozen_by_the_shade(self):
        path = Path(__file__).resolve().parents[2] / 'scripts/test_native_notification_restore.py'
        spec = importlib.util.spec_from_file_location('restore_driver_lifecycle', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        frozen = False
        stopped = False
        answer = None

        def command(argv, **kwargs):
            nonlocal frozen, stopped
            args = argv[3:]
            if args == ['forward', '--no-rebind', 'tcp:0', 'tcp:18766']:
                return '34819\n'
            if args[:3] == ['shell', 'am', 'force-stop']:
                stopped = True
            if args[:3] == ['shell', 'am', 'start']:
                frozen = stopped = False
            if args == ['shell', 'dumpsys', 'notification', '--noredact']:
                return '' if stopped else (
                    f'NotificationRecord(x: pkg={module.PACKAGE} id=42 '
                    'Notification(channel=wing_turn_notifications ONLY_ALERT_ONCE SILENT))\n'
                    f'android.text=String ({answer})\n')
            return ''

        def shown(*args, **kwargs):
            nonlocal frozen
            frozen = True

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self):
                return b'{}'

        def request(value, **kwargs):
            nonlocal answer
            if frozen:
                raise TimeoutError('Android froze the background QA server')
            if value.full_url.endswith('/reply'):
                answer = json.loads(value.data)['text']
            if value.full_url.endswith('/list'):
                raise RuntimeError('Foreground list preparation reached')
            return Response()

        with patch.object(sys, 'argv', [str(path), '--serial', 'emulator-5562']), \
             patch.object(module.subprocess, 'check_output', side_effect=command), \
             patch.object(module.urllib.request, 'urlopen', side_effect=request), \
             patch.object(module.native, 'shown_notification', side_effect=shown), \
             patch.object(module.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'Foreground list preparation reached'):
                module.main()


class NotificationForwardOwnershipTest(unittest.TestCase):
    def standalone_drivers(self):
        root = Path(__file__).resolve().parents[2]
        for name in ('test_native_notification_restore', 'test_native_cold_notification'):
            path = root / 'scripts' / (name + '.py')
            spec = importlib.util.spec_from_file_location(name, path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            yield name, module

    def test_standalone_failure_releases_only_its_allocated_forward(self):
        for name, module in self.standalone_drivers():
            with self.subTest(driver=name):
                calls = []

                def command(argv, **kwargs):
                    arguments = argv[3:]
                    calls.append(arguments)
                    if arguments == ['shell', 'dumpsys', 'deviceidle', 'whitelist']:
                        return module.PACKAGE
                    if arguments == ['forward', '--no-rebind', 'tcp:0', 'tcp:18766']:
                        return '34819\n'
                    if arguments == ['forward', '--remove', 'tcp:34819']:
                        return ''
                    raise RuntimeError('Fixture failed after forward acquisition')

                with patch.object(sys, 'argv', [name, '--serial', 'emulator-5562']), \
                     patch.object(subprocess, 'check_output', side_effect=command), \
                     patch.object(module.urllib.request, 'urlopen', side_effect=RuntimeError('Fixture failed')):
                    with self.assertRaisesRegex(RuntimeError, 'Fixture failed'):
                        module.main()
                removed = [args for args in calls if args[:2] == ['forward', '--remove']]
                self.assertEqual(removed, [['forward', '--remove', 'tcp:34819']])

    def test_port_collision_never_removes_another_runs_forward(self):
        for name, module in self.standalone_drivers():
            with self.subTest(driver=name):
                calls = []

                def collision(argv, **kwargs):
                    calls.append(argv[3:])
                    if argv[3:] == ['shell', 'dumpsys', 'deviceidle', 'whitelist']:
                        return module.PACKAGE
                    raise subprocess.CalledProcessError(1, argv)

                with patch.object(sys, 'argv', [name, '--serial', 'emulator-5562', '--port', '34819']), \
                     patch.object(subprocess, 'check_output', side_effect=collision):
                    with self.assertRaises(subprocess.CalledProcessError):
                        module.main()
                self.assertEqual([call for call in calls if call[0] == 'forward'],
                                 [['forward', '--no-rebind', 'tcp:34819', 'tcp:18766']])

    def test_shade_failure_removes_owned_forward_even_when_settings_cleanup_fails(self):
        calls = []

        def command(argv, **kwargs):
            arguments = argv[3:]
            calls.append(arguments)
            if arguments == ['forward', 'tcp:0', 'tcp:18766']:
                return '34819\n'
            if arguments == ['forward', '--remove', 'tcp:34819']:
                return ''
            raise RuntimeError('Android operation failed')

        with patch.object(sys, 'argv', [driver.__file__, '--serial', 'emulator-5562', '--tap-only']), \
             patch.dict(os.environ, {'ANDROID_HOME': '/unused'}), \
             patch.object(subprocess, 'check_output', side_effect=command):
            with self.assertRaisesRegex(RuntimeError, 'Android operation failed'):
                runpy.run_path(driver.__file__, run_name='__main__')
        removed = [args for args in calls if args[:2] == ['forward', '--remove']]
        self.assertEqual(removed, [['forward', '--remove', 'tcp:34819']])

    def test_shade_fixture_requests_use_the_allocated_host_port(self):
        class Response:
            def read(self):
                return b'{}'

        with patch.object(driver, 'LOCAL_PORT', 34819), \
             patch.object(driver._fixture_http, 'open', return_value=Response()) as request:
            driver.state('/state')
        self.assertEqual(request.call_args.args[0].full_url, 'http://127.0.0.1:34819/state')


if __name__ == '__main__':
    unittest.main()
