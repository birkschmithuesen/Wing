"""Native drivers reject disabled assertions and incomplete journey matrices."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
from scripts.test_native_bots import input_view_visible, require_completed_cases
from scripts.test_native_recents import require_completed_cases as require_recents
from tools.qa.check_background_monitoring import require_single_monitoring_card
from tools.qa import check_notification_revamp as notification_ui

ROOT = Path(__file__).resolve().parents[2]
DRIVERS = (
    'scripts/test_native_notification_counts.py',
    'scripts/test_native_cold_notification.py',
    'scripts/test_native_config_backup.py',
    'scripts/test_native_notification_restore.py',
    'tools/qa/check_activity_reentry.py',
    'tools/qa/check_background_monitoring.py',
    'tools/qa/check_external_share.py',
    'tools/qa/check_notification_revamp.py',

)


class NativeVoiceAdbdOwnership(unittest.TestCase):
    def driver(self, prior='2000', *, root_error=False, root_denied=False,
               restore_bad=False, unroot_error=False, root_reply_error=False):
        from scripts import test_native_voice as voice
        driver = voice.Driver('emulator-5562', Path('/unused'), 30)
        clock = [0.0]
        self.enterContext(patch.object(voice.time, 'monotonic', side_effect=lambda: clock[0]))
        self.enterContext(patch.object(voice.time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)))
        state = {'uid': prior}
        calls = []

        def shell(*command):
            calls.append(command)
            if command == ('getprop', 'ro.kernel.qemu'):
                return '1'
            if command == ('getprop', 'ro.build.version.sdk'):
                return '36'
            if command == ('id', '-u'):
                return state['uid']
            raise AssertionError(command)

        def adb(*command):
            calls.append(command)
            if command == ('root',):
                if not root_denied:
                    state['uid'] = '0'
                if root_reply_error:
                    raise subprocess.CalledProcessError(
                        1, ['adb', '-s', driver.serial, 'root'], stderr='error: closed')
                if root_error:
                    raise RuntimeError('lost root receipt')
            elif command == ('unroot',):
                state['uid'] = '0' if restore_bad else '2000'
                if unroot_error:
                    raise subprocess.CalledProcessError(
                        1, ['adb', '-s', driver.serial, 'unroot'], stderr='error: closed')
            elif command == ('get-serialno',):
                return driver.serial
            elif command != ('wait-for-device',):
                raise AssertionError(command)
            return ''

        driver.shell = shell
        driver.adb = adb
        return driver, state, calls

    def test_only_owned_root_transition_is_restored_after_native_work(self):
        for prior in ('0', '2000'):
            with self.subTest(prior=prior):
                driver, state, calls = self.driver(prior)
                with driver.rooted_emulator():
                    self.assertEqual(state['uid'], '0')
                    calls.append(('native-capability-restored',))
                self.assertEqual(state['uid'], prior)
                self.assertTrue(driver.evidence['adbd']['restored'])
                transitions = [c for c in calls if c in {('root',), ('unroot',)}]
                self.assertEqual(transitions, [] if prior == '0' else [('root',), ('unroot',)])
                if prior != '0':
                    self.assertLess(calls.index(('native-capability-restored',)), calls.index(('unroot',)))

    def test_failed_or_lost_root_receipt_still_restores_prior_authority(self):
        for kwargs in ({'root_error': True}, {'root_denied': True}):
            with self.subTest(kwargs=kwargs):
                driver, state, calls = self.driver(**kwargs)
                with self.assertRaises(RuntimeError):
                    with driver.rooted_emulator():
                        self.fail('Failed root admitted native work')
                self.assertEqual(state['uid'], '2000')
                self.assertIn(('unroot',), calls)
                self.assertTrue(driver.evidence['adbd']['restored'])

    def test_native_failure_still_unroots(self):
        driver, state, _ = self.driver()
        with self.assertRaisesRegex(RuntimeError, 'native failure'):
            with driver.rooted_emulator():
                raise RuntimeError('native failure')
        self.assertEqual(state['uid'], '2000')
        self.assertTrue(driver.evidence['adbd']['restored'])

    def test_failed_adbd_restore_cannot_report_success(self):
        driver, _, _ = self.driver(restore_bad=True)
        with self.assertRaisesRegex(RuntimeError, 'authority was not restored'):
            with driver.rooted_emulator():
                pass
        self.assertFalse(driver.evidence['adbd']['restored'])
        self.assertIn('cleanup_error', driver.evidence['adbd'])

    def test_lost_root_reply_observes_authority_before_admitting_or_restoring(self):
        driver, state, calls = self.driver(root_reply_error=True)
        with driver.rooted_emulator():
            self.assertEqual(state['uid'], '0')
            self.assertIn(('wait-for-device',), calls[calls.index(('root',)) + 1:])
        self.assertEqual(state['uid'], '2000')
        self.assertTrue(driver.evidence['adbd']['restored'])
        self.assertEqual(calls.count(('root',)), 1)
        self.assertEqual(driver.evidence['adbd']['root_reply_error'],
                         {'returncode': 1, 'stderr': 'error: closed'})

    def test_lost_unroot_reply_reconnects_and_verifies_restored_authority(self):
        driver, state, calls = self.driver(unroot_error=True)
        with driver.rooted_emulator():
            self.assertEqual(state['uid'], '0')
        self.assertEqual(state['uid'], '2000')
        self.assertTrue(driver.evidence['adbd']['restored'])
        self.assertEqual(calls.count(('unroot',)), 1)
        self.assertIn(('wait-for-device',), calls[calls.index(('unroot',)) + 1:])
        self.assertEqual(driver.evidence['adbd']['unroot_reply_error'],
                         {'returncode': 1, 'stderr': 'error: closed'})

    def test_lost_unroot_reply_with_wrong_authority_still_fails(self):
        driver, _, _ = self.driver(unroot_error=True, restore_bad=True)
        with self.assertRaisesRegex(RuntimeError, 'authority was not restored'):
            with driver.rooted_emulator():
                pass
        self.assertFalse(driver.evidence['adbd']['restored'])

    def test_lost_unroot_reply_with_changed_identity_still_fails(self):
        driver, _, _ = self.driver(unroot_error=True)
        adb = driver.adb
        with self.assertRaisesRegex(RuntimeError, 'identity changed'):
            with driver.rooted_emulator():
                driver.adb = lambda *args: ('emulator-9999' if args == ('get-serialno',)
                                            else adb(*args))
        self.assertFalse(driver.evidence['adbd']['restored'])

    def test_delayed_root_and_unroot_replies_do_not_settle_the_transition(self):
        driver, state, calls = self.driver()
        adb, shell = driver.adb, driver.shell
        pending = [None, 0]

        def dispatch(*command):
            result = adb(*command)
            if command in {('root',), ('unroot',)}:
                pending[:] = [state['uid'], 3]
                state['uid'] = '2000' if command == ('root',) else '0'
                raise subprocess.CalledProcessError(1, ['adb', *command], stderr='closed')
            return result

        def observe(*command):
            if command == ('id', '-u') and pending[1]:
                pending[1] -= 1
                if pending[1] == 2:
                    raise subprocess.CalledProcessError(1, ['adb', 'shell'], stderr='offline')
                if not pending[1]:
                    state['uid'] = pending[0]
            return shell(*command)

        driver.adb, driver.shell = dispatch, observe
        with driver.rooted_emulator():
            self.assertEqual(state['uid'], '0')
            self.assertNotIn(('unroot',), calls)
        self.assertEqual(state['uid'], '2000')
        self.assertEqual(calls.count(('root',)), 1)
        self.assertEqual(calls.count(('unroot',)), 1)
        self.assertTrue(driver.evidence['adbd']['restored'])

    def test_root_reply_error_does_not_admit_work_without_root_authority(self):
        driver, _, calls = self.driver(root_reply_error=True, root_denied=True)
        with self.assertRaisesRegex(RuntimeError, 'root authority was not established'):
            with driver.rooted_emulator():
                self.fail('Unconfirmed root admitted native work')
        self.assertEqual(calls.count(('root',)), 1)
        self.assertTrue(driver.evidence['adbd']['restored'])

    def test_physical_identity_is_rejected_before_adb_root(self):
        driver, _, calls = self.driver()
        driver.serial = 'physical-device'
        with self.assertRaisesRegex(RuntimeError, 'disposable emulator'):
            with driver.rooted_emulator():
                self.fail('Physical device admitted')
        self.assertNotIn(('root',), calls)


class NativeVoiceRecognitionIsolation(unittest.TestCase):
    def driver(self, *, uid='0', baseline='original/Recognizer\n',
               failure=None, restore_mismatch=False):
        from scripts import test_native_voice as voice
        driver = voice.Driver('emulator-5562', Path('/unused'), 30)
        state = {'registered': False, 'enabled': False, 'identifier': None}
        calls = []

        def shell(*command):
            calls.append(command)
            if command == ('getprop', 'ro.kernel.qemu'):
                return '1\n'
            if command == ('id', '-u'):
                return uid + '\n'
            if command == ('getprop', 'ro.build.version.sdk'):
                return '36\n'
            if command[:3] == ('cmd', 'overlay', 'lookup'):
                if state['enabled']:
                    return '\n' if failure != 'unapplied' else baseline
                return 'different/Recognizer\n' if restore_mismatch and state['registered'] else baseline
            if command[:3] == ('cmd', 'overlay', 'list'):
                return (('[x] ' if state['enabled'] else '[ ] ') + state['identifier'] + '\n'
                        if state['registered'] else '')
            if command[:3] == ('cmd', 'overlay', 'fabricate'):
                state['registered'] = True
                state['identifier'] = 'com.android.shell:' + command[6]
                if failure == 'fabricate-receipt':
                    raise RuntimeError('lost fabricate receipt')
            if command[:3] == ('cmd', 'overlay', 'enable'):
                state['enabled'] = True
                if failure == 'enable-receipt':
                    raise RuntimeError('lost enable receipt')
            if command[:3] == ('cmd', 'overlay', 'disable'):
                self.assertEqual(command[-1], state['identifier'])
                state['enabled'] = False
            return ''

        driver.shell = shell
        return driver, state, calls

    def test_owned_overlay_is_disabled_and_exact_baseline_restored(self):
        for baseline in ('original/Recognizer\n', '\n'):
            with self.subTest(baseline=baseline):
                driver, state, calls = self.driver(baseline=baseline)
                with driver.unavailable_recognition():
                    self.assertTrue(state['enabled'])
                self.assertFalse(state['enabled'])
                self.assertTrue(driver.evidence['recognition_isolation']['restored'])
                self.assertEqual(driver.evidence['recognition_isolation']['baseline_resource'], baseline)
                self.assertEqual(len([c for c in calls if c[:3] == ('cmd', 'overlay', 'disable')]), 1)
                self.assertIn('AVD storage deletion',
                              driver.evidence['recognition_isolation']['registration_cleanup'])

    def test_test_failure_still_restores_its_overlay(self):
        driver, state, _ = self.driver()
        with self.assertRaisesRegex(RuntimeError, 'native assertion failed'):
            with driver.unavailable_recognition():
                raise RuntimeError('native assertion failed')
        self.assertFalse(state['enabled'])
        self.assertTrue(driver.evidence['recognition_isolation']['restored'])

    def test_process_cleanup_failure_still_restores_android_configuration(self):
        driver, state, _ = self.driver()
        with patch.object(driver, 'stop_process', side_effect=RuntimeError('process stop failed')):
            with self.assertRaisesRegex(RuntimeError, 'process stop failed'):
                with driver.unavailable_recognition():
                    pass
        self.assertFalse(state['enabled'])
        self.assertTrue(driver.evidence['recognition_isolation']['restored'])

    def test_lost_mutation_receipts_still_cleanup_exact_owned_registration(self):
        for failure in ('fabricate-receipt', 'enable-receipt', 'unapplied'):
            with self.subTest(failure=failure):
                driver, state, calls = self.driver(failure=failure)
                with self.assertRaises(RuntimeError):
                    with driver.unavailable_recognition():
                        self.fail('Invalid isolation admitted native execution')
                self.assertFalse(state['enabled'])
                self.assertTrue(driver.evidence['recognition_isolation']['restored'])
                self.assertEqual(len([c for c in calls if c[:3] == ('cmd', 'overlay', 'disable')]), 1)

    def test_restoration_mismatch_is_failure_with_cleanup_evidence(self):
        driver, state, _ = self.driver(restore_mismatch=True)
        with self.assertRaisesRegex(RuntimeError, 'was not restored'):
            with driver.unavailable_recognition():
                pass
        self.assertFalse(state['enabled'])
        self.assertFalse(driver.evidence['recognition_isolation']['restored'])
        self.assertIn('cleanup_error', driver.evidence['recognition_isolation'])

    def test_nonroot_and_physical_devices_cannot_mutate_overlay(self):
        for uid, serial in (('2000', 'emulator-5562'), ('0', 'physical-device')):
            with self.subTest(uid=uid, serial=serial):
                driver, _, calls = self.driver(uid=uid)
                driver.serial = serial
                with self.assertRaisesRegex(RuntimeError, 'rooted disposable emulator'):
                    with driver.unavailable_recognition():
                        self.fail('Invalid device admitted native execution')
                self.assertFalse(any(c[:2] == ('cmd', 'overlay') for c in calls))

    def test_native_observation_is_required_and_must_match_once(self):
        driver, _, _ = self.driver()
        for transcript in ('', 'VOICE_UNAVAILABLE_LOCAL_INPUT true',
                           'VOICE_UNAVAILABLE_LOCAL_INPUT false\nVOICE_UNAVAILABLE_LOCAL_INPUT false'):
            with self.subTest(transcript=transcript), self.assertRaises(RuntimeError):
                driver.verify_recognition_observation(transcript, 'VOICE_UNAVAILABLE_LOCAL_INPUT', False)
        driver.verify_recognition_observation(
            'VOICE_UNAVAILABLE_LOCAL_INPUT false', 'VOICE_UNAVAILABLE_LOCAL_INPUT', False)
        driver.verify_recognition_observation(
            'VOICE_RESTORED_LOCAL_INPUT true', 'VOICE_RESTORED_LOCAL_INPUT', True)


class NativeMonitoringForwardOwnership(unittest.TestCase):
    def test_failed_attempt_removes_its_allocated_forward_once(self):
        from tools.qa import check_background_monitoring as monitoring
        calls = []

        def adb(command, **kwargs):
            parts = command[3:]
            calls.append(parts)
            if parts == ['forward', '--no-rebind', 'tcp:0', 'tcp:18765']:
                return '43123\n'
            if parts == ['shell', 'cmd', 'statusbar', 'collapse']:
                raise RuntimeError('primary fixture failure')
            return ''

        with tempfile.TemporaryDirectory() as directory, \
             patch.object(sys, 'argv', ['monitoring', '--serial', 'emulator-5562', '--output', directory]), \
             patch.object(monitoring.subprocess, 'check_output', side_effect=adb), \
             patch.object(monitoring.urllib.request, 'urlopen', side_effect=RuntimeError('fixture not started')):
            with self.assertRaisesRegex(RuntimeError, 'primary fixture failure'):
                monitoring.main()
        self.assertEqual([c for c in calls if c[0] == 'forward'], [
            ['forward', '--no-rebind', 'tcp:0', 'tcp:18765'],
            ['forward', '--remove', 'tcp:43123'],
        ])

    def test_occupied_explicit_port_is_neither_rebound_nor_removed(self):
        from tools.qa import check_background_monitoring as monitoring
        calls = []

        def adb(command, **kwargs):
            parts = command[3:]
            calls.append(parts)
            if parts[0] == 'forward':
                raise subprocess.CalledProcessError(1, command, 'port already bound')
            return ''

        with tempfile.TemporaryDirectory() as directory, \
             patch.object(sys, 'argv', ['monitoring', '--serial', 'emulator-5562', '--port', '43210', '--output', directory]), \
             patch.object(monitoring.subprocess, 'check_output', side_effect=adb):
            with self.assertRaises(subprocess.CalledProcessError):
                monitoring.main()
        self.assertEqual([c for c in calls if c[0] == 'forward'], [
            ['forward', '--no-rebind', 'tcp:43210', 'tcp:18765'],
        ])


class ColdNotificationPrerequisites(unittest.TestCase):
    def test_failure_restores_only_the_exemption_and_forward_it_owned(self):
        from scripts import test_native_cold_notification as cold
        for already_exempt in (False, True):
            calls = []

            def adb(command, **kwargs):
                parts = command[3:]
                calls.append(parts)
                if parts == ['shell', 'dumpsys', 'deviceidle', 'whitelist']:
                    return cold.PACKAGE if already_exempt else ''
                if parts == ['forward', '--no-rebind', 'tcp:0', 'tcp:18766']:
                    return '43123\n'
                return ''

            with self.subTest(already_exempt=already_exempt), \
                 patch.object(sys, 'argv', ['cold', '--serial', 'emulator-5562']), \
                 patch.object(cold.subprocess, 'check_output', side_effect=adb), \
                 patch.object(cold.urllib.request, 'urlopen', side_effect=RuntimeError('fixture failed')):
                with self.assertRaisesRegex(RuntimeError, 'fixture failed'):
                    cold.main()
            mutations = [call for call in calls if len(call) == 5 and call[:4] ==
                         ['shell', 'dumpsys', 'deviceidle', 'whitelist']]
            self.assertEqual(mutations, [] if already_exempt else [
                ['shell', 'dumpsys', 'deviceidle', 'whitelist', '+' + cold.PACKAGE],
                ['shell', 'dumpsys', 'deviceidle', 'whitelist', '-' + cold.PACKAGE],
            ])
            self.assertEqual([call for call in calls if call[0] == 'forward'], [
                ['forward', '--no-rebind', 'tcp:0', 'tcp:18766'],
                ['forward', '--remove', 'tcp:43123'],
            ])


class MonitoringCardCardinality(unittest.TestCase):
    package = 'com.tarkilhk.wing.dev'

    def record(self, identifier=214601, package=None, channel='hermes_monitoring', foreground=True):
        flags = 'FOREGROUND_SERVICE|ONGOING_EVENT' if foreground else 'ONGOING_EVENT'
        return (f'  NotificationRecord(0x1: pkg={package or self.package} '
                f'user=UserHandle{{0}} id={identifier} tag=null '
                f'Notification(channel={channel} flags={flags}))\n')

    def test_one_foreground_card_ignores_other_packages_and_channels(self):
        dump = (self.record() + self.record(214603, package=self.package + '.other')
                + self.record(240001, channel='wing_attention_notifications')
                + self.record(240002, channel='hermes_monitoring_other'))
        require_single_monitoring_card(dump, self.package)

    def test_unknown_duplicate_monitoring_id_cannot_hide_behind_the_known_summary_check(self):
        with self.assertRaisesRegex(AssertionError, 'Expected one monitoring card, got 2'):
            require_single_monitoring_card(self.record() + self.record(214603), self.package)

    def test_missing_monitoring_card_is_not_success(self):
        with self.assertRaisesRegex(AssertionError, 'Expected one monitoring card, got 0'):
            require_single_monitoring_card('', self.package)

    def test_an_ordinary_notification_cannot_stand_in_for_the_foreground_card(self):
        with self.assertRaises(AssertionError):
            require_single_monitoring_card(self.record(foreground=False), self.package)

    def test_the_only_card_must_have_the_monitoring_identity(self):
        with self.assertRaises(AssertionError):
            require_single_monitoring_card(self.record(214603), self.package)


class NativeNotificationPresentation(unittest.TestCase):
    def card(self, text='3 questions', *, title='Outside task', app='Wing Dev', expanded=True):
        row = ET.Element('node', {'resource-id': 'com.android.systemui:id/expandableNotificationRow'})
        if app is not None:
            ET.SubElement(row, 'node', {'resource-id': 'android:id/app_name_text', 'text': app})
        ET.SubElement(row, 'node', {'resource-id': 'android:id/conversation_text', 'text': title})
        ET.SubElement(row, 'node', {'resource-id': 'android:id/message_text', 'text': text})
        ET.SubElement(row, 'node', {
            'resource-id': 'android:id/expand_button', 'enabled': 'true',
            'content-desc': 'Collapse' if expanded else 'Expand', 'bounds': '[10,20][50,60]',
        })
        return row

    def test_content_on_another_conversation_cannot_satisfy_the_target(self):
        other = self.card(title='Another task')
        self.assertIsNone(notification_ui.notification_card(list(other.iter()), 'Outside task'))

    def test_matching_content_in_another_apps_card_is_not_the_qa_notification(self):
        other = self.card(app='Another app')
        self.assertIsNone(notification_ui.notification_card(list(other.iter()), 'Outside task'))

    def test_duplicate_target_cards_are_rejected(self):
        rows = [self.card(), self.card()]
        with self.assertRaisesRegex(AssertionError, 'More than one native notification'):
            notification_ui.notification_card(rows, 'Outside task')

    def test_headerless_card_requires_independent_package_ownership(self):
        card = self.card(app=None, expanded=False)
        self.assertIsNone(notification_ui.notification_card([card], 'Outside task'))
        self.assertIs(notification_ui.notification_card(
            [card], 'Outside task', headerless_owner=True), card)
        self.assertIsNone(notification_ui.notification_card(
            [self.card(app='Another app')], 'Outside task', headerless_owner=True))

    def notification_record(self, package=notification_ui.PACKAGE):
        return (f'    NotificationRecord(0x1: pkg={package} user=UserHandle{{0}} id=42)\n'
                '      extras={\n        android.title=String (Outside task: Outside task)\n'
                '        android.conversationTitle=String (Outside task)\n      }\n')

    def test_only_one_active_owned_title_can_identify_a_headerless_card(self):
        owned = self.notification_record()
        other = self.notification_record('another.app')
        for records, expected in ((owned, True), (other, False),
                                  (owned + other, False), (owned + owned, False)):
            with self.subTest(records=records):
                self.assertEqual(notification_ui.notification_title_owned(
                    '  Notification List:\n' + records + '  Historical notifications:\n',
                    'Outside task'), expected)
        self.assertFalse(notification_ui.notification_title_owned(
            '  Notification List:\n  Historical notifications:\n' + owned, 'Outside task'))

    def test_real_collapse_can_remove_the_header_without_losing_owned_content(self):
        expanded = self.card()
        collapsed = self.card(app=None, expanded=False)
        dump = '  Notification List:\n' + self.notification_record()
        with patch.object(notification_ui, 'shade'), \
             patch.object(notification_ui, 'nodes', side_effect=[[expanded], [collapsed]]), \
             patch.object(notification_ui, 'adb', return_value=dump) as adb:
            result = notification_ui.shown_notification('Outside task', expanded=False, required=['3 questions'])
        self.assertIs(result, collapsed)
        self.assertEqual(adb.call_args_list[0].args, ('shell', 'input', 'tap', '30', '40'))
        self.assertEqual(adb.call_args_list[1].args, ('shell', 'dumpsys', 'notification', '--noredact'))

    def test_question_count_cannot_match_the_suffix_of_a_different_number(self):
        self.assertFalse(notification_ui.notification_text_matches(self.card('13 questions'), ['3 questions']))
        self.assertTrue(notification_ui.notification_text_matches(self.card('3 questions\nEnvironment?'), ['3 questions']))

    def test_private_preview_cannot_leak_in_an_accessibility_label(self):
        card = self.card('1 question')
        ET.SubElement(card, 'node', {'content-desc': 'Summary'})
        self.assertFalse(notification_ui.notification_text_matches(card, ['1 question'], ['Summary']))

    def test_expanded_check_waits_for_both_actual_mode_and_current_content(self):
        collapsed = self.card(expanded=False)
        stale = self.card('2 questions')
        current = self.card()
        with patch.object(notification_ui, 'shade'), \
             patch.object(notification_ui, 'nodes', side_effect=[[collapsed], [collapsed], [stale], [current]]), \
             patch.object(notification_ui.time, 'sleep'), patch.object(notification_ui, 'adb') as adb:
            result = notification_ui.shown_notification('Outside task', expanded=True, required=['3 questions'])
        self.assertIs(result, current)
        adb.assert_called_once_with('shell', 'input', 'tap', '30', '40')

    def test_collapsed_check_uses_the_real_collapse_control(self):
        expanded = self.card()
        collapsed = self.card(expanded=False)
        with patch.object(notification_ui, 'shade'), \
             patch.object(notification_ui, 'nodes', side_effect=[[expanded], [collapsed]]), \
             patch.object(notification_ui, 'adb') as adb:
            result = notification_ui.shown_notification('Outside task', expanded=False, required=['3 questions'])
        self.assertIs(result, collapsed)
        adb.assert_called_once_with('shell', 'input', 'tap', '30', '40')


class NativeDriverGuards(unittest.TestCase):
    def test_optimized_invocation_refuses_before_device_access(self):
        for driver in DRIVERS:
            for mode in ('flag', 'environment'):
                with self.subTest(driver=driver, mode=mode):
                    environment = dict(os.environ)
                    environment.pop('PYTHONOPTIMIZE', None)
                    flags = ['-O'] if mode == 'flag' else []
                    if mode == 'environment':
                        environment['PYTHONOPTIMIZE'] = '1'
                    result = subprocess.run(
                        [sys.executable, *flags, str(ROOT / driver), '--help'],
                        capture_output=True, text=True, timeout=10, env=environment,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Native acceptance requires Python assertions', result.stderr)


class NativeBotsKeyboard(unittest.TestCase):
    def test_stale_show_request_does_not_make_hidden_input_view_visible(self):
        self.assertFalse(input_view_visible(
            'mInputShown=true\n  mWindowVisible=false mIsInputViewShown=false mStatusIcon=0'))

    def test_retained_input_view_does_not_make_hidden_ime_window_visible(self):
        self.assertFalse(input_view_visible(
            'mInputShown=false\n  mWindowVisible=false mIsInputViewShown=true mStatusIcon=0'))

    def test_actual_input_view_is_visible(self):
        self.assertTrue(input_view_visible(
            'mInputShown=true\n  mWindowVisible=true mIsInputViewShown=true mStatusIcon=0'))

    def test_missing_actual_view_state_is_not_assumed_hidden(self):
        with self.assertRaises(RuntimeError):
            input_view_visible('mInputShown=false')


class NativeBotsCompletion(unittest.TestCase):
    def records(self):
        return [{'name': f'{theme}-{size}-complete'}
                for theme in ('dark', 'light') for size in ('normal', 'large')]

    def test_full_matrix_requires_all_four_completed_journeys(self):
        self.assertEqual(len(require_completed_cases(self.records())), 4)

    def test_empty_success_is_rejected(self):
        with self.assertRaises(RuntimeError):
            require_completed_cases([])

    def test_each_missing_configuration_is_rejected(self):
        records = self.records()
        for missing in records:
            with self.subTest(missing=missing):
                with self.assertRaises(RuntimeError):
                    require_completed_cases([r for r in records if r != missing])

    def test_duplicate_completion_cannot_replace_a_missing_configuration(self):
        with self.assertRaises(RuntimeError):
            require_completed_cases([self.records()[0]] * 4)

    def test_named_recovery_only_requires_its_selected_journey(self):
        self.assertEqual(require_completed_cases([{'name': 'light-large-complete'}],
                                                'Android Bots light-large'),
                         ['light-large-complete'])

    def test_unknown_filter_cannot_accept_an_empty_run(self):
        with self.assertRaises(RuntimeError):
            require_completed_cases([], 'nonexistent journey')


class NativeRecentsTouchTiming(unittest.TestCase):
    """Exercise the real Java injector with a stalled Android input boundary."""

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='wing-recents-touch-')
        cls.addClassCleanup(cls.directory.cleanup)
        directory = Path(cls.directory.name)
        stubs = {
            'android/os/SystemClock.java': """package android.os;
public class SystemClock {
 public static long now = 10000;
 public static long uptimeMillis() { return now; }
 public static void sleep(long ms) { now += ms; }
}""",
            'android/view/InputDevice.java': """package android.view; public class InputDevice { public static int SOURCE_TOUCHSCREEN = 4098; }""",
            'android/view/InputEvent.java': """package android.view; public class InputEvent {}""",
            'android/view/MotionEvent.java': """package android.view;
public class MotionEvent extends InputEvent {
 public static final int ACTION_DOWN=0, ACTION_UP=1, ACTION_MOVE=2, ACTION_POINTER_DOWN=5, ACTION_POINTER_UP=6, ACTION_POINTER_INDEX_SHIFT=8, TOOL_TYPE_FINGER=1;
 public static class PointerProperties { public int id, toolType; }
 public static class PointerCoords { public float x,y,pressure,size; }
 public int action; public long time; public float x;
 public static MotionEvent obtain(long down, long time, int action, int count, PointerProperties[] props, PointerCoords[] coords, int meta, int buttons, float xp, float yp, int device, int edge, int source, int flags) {
  MotionEvent e = new MotionEvent(); e.action = action; e.time = time; e.x = coords[0].x; return e;
 }
 public void recycle() {}
}""",
            'android/hardware/input/InputManagerGlobal.java': """package android.hardware.input;
import android.os.SystemClock;
import android.view.InputEvent;
import android.view.MotionEvent;
public class InputManagerGlobal {
 private static MotionEvent pending;
 public static InputManagerGlobal getInstance() { return new InputManagerGlobal(); }
 private static void deliver(MotionEvent e) {
  System.out.println("event=" + e.action + "," + e.time + "," + e.x + "," + SystemClock.uptimeMillis());
 }
 public boolean injectInputEvent(InputEvent event, int mode) {
  MotionEvent e = (MotionEvent) event;
  if (mode == 0 && e.action == MotionEvent.ACTION_MOVE) { pending = e; return true; }
  if (pending != null) { deliver(pending); pending = null; }
  deliver(e);
  if (mode == 2) SystemClock.sleep(Long.getLong("touch.delayMs", 0)); // Waiting for the app can stall injection.
  return true;
 }
}""",
        }
        for name, source in stubs.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
        subprocess.run([
            'javac', '-d', str(directory), *map(str, directory.rglob('*.java')),
            str(ROOT / 'integration_test/fixtures/recents_touch/NativeRecentsTouch.java'),
        ], check=True, capture_output=True, text=True)

    def test_injection_delays_preserve_requested_movement_and_release_timing(self):
        for mode, duration in (('one', 100), ('two', 320), ('interrupt', 320)):
            for delay in (0, 12, 40):
                with self.subTest(mode=mode, delay=delay):
                    contacts = ['900', '500', '100', '500']
                    if mode != 'one':
                        contacts += ['950', '500', '150', '500']
                    args = [mode, *contacts, str(duration)]
                    if mode == 'interrupt':
                        args.append('-24')
                    result = subprocess.run([
                        'java', f'-Dtouch.delayMs={delay}', '-cp',
                        self.directory.name, 'NativeRecentsTouch', *args,
                    ], check=True, capture_output=True, text=True)
                    events = [line.split('=')[1].split(',')
                              for line in result.stdout.splitlines()
                              if line.startswith('event=')]
                    times = [int(event[1]) for event in events]
                    self.assertEqual(times, sorted(times))
                    moves = [event for event in events if event[0] == '2'][-24:]
                    self.assertEqual(len(moves), 24)
                    self.assertEqual(int(moves[-1][1]) - int(moves[0][1]),
                                     duration - duration // 24,
                                     'Injection latency changed the requested swipe velocity')
                    self.assertEqual(events[-1][0], '1')
                    self.assertEqual(int(events[-1][1]), int(moves[-1][1]),
                                     'Injection latency introduced a pause before release')

    def test_flick_delivers_multiple_samples_without_a_pause_before_release(self):
        result = subprocess.run([
            'java', '-Dtouch.delayMs=80', '-cp', self.directory.name,
            'NativeRecentsTouch', 'one', '900', '500', '100', '500', '100',
        ], check=True, capture_output=True, text=True)
        events = [line.split('=')[1].split(',') for line in result.stdout.splitlines()
                  if line.startswith('event=')]
        moves = [event for event in events if event[0] == '2']
        self.assertGreaterEqual(len(moves), 3,
                                'Android coalesced the flick into too few velocity samples')
        self.assertEqual(int(events[-1][3]), int(moves[-1][3]),
                         'Waiting for app processing introduced a stop before finger release')


class NativeRecentsCompletion(unittest.TestCase):
    def records(self, mode='standard'):
        prefix = 'events-' if mode == 'events' else ''
        suffix = '-code' if mode == 'code' else ''
        return [{'name': f'{prefix}{theme}-{size}{suffix}-complete'}
                for theme in ('dark', 'light') for size in ('normal', 'large')]

    def test_each_mode_requires_its_own_complete_matrix(self):
        for mode in ('standard', 'code', 'events'):
            with self.subTest(mode=mode):
                self.assertEqual(len(require_recents(self.records(mode), mode=mode)), 4)
                with self.assertRaises(RuntimeError):
                    require_recents(self.records(mode)[:-1], mode=mode)

    def test_momentum_requires_its_explicit_completion(self):
        self.assertEqual(require_recents([{'name': 'dark-normal-momentum-complete'}], mode='momentum'),
                         ['dark-normal-momentum-complete'])
        with self.assertRaises(RuntimeError):
            require_recents([{'name': 'dark-normal-momentum-select'}], mode='momentum')

    def test_wrong_mode_completion_does_not_count(self):
        with self.assertRaises(RuntimeError):
            require_recents(self.records('code'))

    def test_duplicate_completion_does_not_count(self):
        with self.assertRaises(RuntimeError):
            require_recents(self.records() + [self.records()[0]])

    def test_selected_recovery_case_can_complete_alone(self):
        self.assertEqual(require_recents([{'name': 'events-light-large-complete'}],
                                        name='native incoming messages light large', mode='events'),
                         ['events-light-large-complete'])

    def test_unknown_name_cannot_accept_an_empty_run(self):
        with self.assertRaises(RuntimeError):
            require_recents([], name='not a journey')


class NativeBackupChooser(unittest.TestCase):
    def node(self, resource, bounds, *, text='', package='com.android.intentresolver'):
        from scripts import test_native_config_backup as backup
        return backup.ET.Element('node', {'resource-id': resource, 'bounds': bounds,
                                         'text': text, 'package': package, 'enabled': 'true'})

    def driver(self, directory):
        from scripts import test_native_config_backup as backup

        class Device:
            def __init__(self):
                self.calls = []

            def shell(self, *args):
                self.calls.append(args)
                return ''

        return backup.Driver(Device(), Path(directory), 'wing-backup-qa-test-')

    def test_hidden_share_destination_is_revealed_before_the_actual_target_is_tapped(self):
        from unittest.mock import patch
        from scripts import test_native_config_backup as backup
        driver = self.driver('unused')
        hidden = [self.node('android:id/contentPanel', '[0,0][1080,1920]'),
                  self.node('android:id/drag', '[456,921][624,932]')]
        target = [self.node('android:id/text1', '[20,1200][500,1250]', text='Save Wing QA backup')]
        snapshots = iter([hidden, target])
        driver.nodes = lambda _: next(snapshots)
        driver.status = lambda: {}
        driver.capture = lambda _: None
        driver.process = type('Process', (), {'poll': lambda _: None})()

        class TargetTapped(Exception):
            pass

        def tap(node):
            self.assertIs(node, target[0])
            raise TargetTapped()

        driver.tap = tap
        with patch.object(backup.time, 'sleep'), self.assertRaises(TargetTapped):
            driver.drive('share-plain')
        command = driver.device.calls[0]
        self.assertEqual(command[:2], ('input', 'swipe'))
        self.assertGreater(int(command[3]), int(command[5]))

    def test_unavailable_transition_retries_a_fresh_capture_before_tapping(self):
        from unittest.mock import patch
        from scripts import test_native_config_backup as backup
        driver = self.driver('unused')
        target = self.node('android:id/text1', '[20,1200][500,1250]',
                           text='Save Wing QA backup')
        driver.status = lambda: {}
        driver.capture = lambda _: None
        driver.process = type('Process', (), {'poll': lambda _: None})()

        class TargetTapped(Exception):
            pass

        def tap(node):
            self.assertIs(node, target)
            raise TargetTapped()

        driver.tap = tap
        with patch.object(driver, 'nodes', side_effect=[
                backup.HierarchyUnavailable('transition not ready'), [target]]) as capture, \
                patch.object(backup.time, 'sleep'), self.assertRaises(TargetTapped):
            driver.drive('share-plain')
        self.assertEqual(capture.call_count, 2)
        self.assertEqual(driver.device.calls, [])

    def test_expanded_chooser_scrolls_its_target_list_upward(self):
        driver = self.driver('unused')
        shown = [self.node('android:id/contentPanel', '[0,0][1080,1920]'),
                 self.node('android:id/drag', '[456,50][624,60]'),
                 self.node('android:id/resolver_list', '[0,600][1080,1800]')]
        self.assertTrue(driver.reveal_share_targets(shown))
        command = driver.device.calls[0]
        self.assertEqual(command[:2], ('input', 'swipe'))
        start, end = int(command[3]), int(command[5])
        self.assertTrue(600 < end < start < 1800)

    def test_another_apps_similar_controls_do_not_receive_a_chooser_gesture(self):
        driver = self.driver('unused')
        shown = [self.node('android:id/contentPanel', '[0,0][1080,1920]', package='other.app'),
                 self.node('android:id/drag', '[456,921][624,932]', package='other.app')]
        self.assertFalse(driver.reveal_share_targets(shown))
        self.assertEqual(driver.device.calls, [])

    def test_failed_ui_capture_never_reads_the_previous_hierarchy(self):
        driver = self.driver('unused')
        with self.assertRaisesRegex(RuntimeError, 'discard the previous hierarchy'):
            driver.nodes('failed')
        self.assertEqual(driver.device.calls, [('uiautomator', 'dump', driver.dump_path)])


if __name__ == '__main__':
    unittest.main()
