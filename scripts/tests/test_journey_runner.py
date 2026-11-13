import json
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from scripts import test_journeys
from scripts.test_journeys import CRITICAL, ROADMAP, verdict


def events(expected=CRITICAL, *, skipped=None, failed=None, omitted=None):
    result = []
    for index, name in enumerate(sorted(expected)):
        if name == omitted:
            continue
        result.extend([
            {'type': 'testStart', 'test': {'id': index, 'name': name}},
            {'type': 'testDone', 'testID': index, 'hidden': False,
             'skipped': name == skipped, 'result': 'failure' if name == failed else 'success'},
        ])
    result.append({'type': 'done', 'success': True})
    return [json.dumps(item) for item in result]


class CompletedOnboardingOwnership(unittest.TestCase):
    package = 'com.tarkilhk.wing.notificationqa'

    def device(self, granted=False):
        def run(serial, *args):
            if args[:3] == ('shell', 'pm', 'path'):
                return 'package:/fixture/base.apk'
            if args[:3] == ('shell', 'dumpsys', 'package'):
                return ('android.permission.POST_NOTIFICATIONS: granted=true\n'
                        'android.permission.RECORD_AUDIO: granted=true') if granted else ''
            if args == ('shell', 'dumpsys', 'deviceidle', 'whitelist'):
                return self.package if granted else ''
            return ''
        return run

    def test_failure_restores_only_prerequisites_this_attempt_added(self):
        evidence = {}
        with patch.object(test_journeys.android, 'device', side_effect=self.device()) as device:
            with self.assertRaisesRegex(RuntimeError, 'journey failed'):
                with test_journeys.completed_onboarding('emulator-5562', evidence):
                    raise RuntimeError('journey failed')
        actions = [call.args[1:] for call in device.call_args_list]
        for permission in ('android.permission.POST_NOTIFICATIONS', 'android.permission.RECORD_AUDIO'):
            self.assertIn(('shell', 'pm', 'grant', self.package, permission), actions)
            self.assertIn(('shell', 'pm', 'revoke', self.package, permission), actions)
        self.assertIn(('shell', 'dumpsys', 'deviceidle', 'whitelist', '-' + self.package), actions)
        self.assertNotIn('restored', evidence)

    def test_existing_grants_and_exemption_survive_the_attempt(self):
        evidence = {}
        with patch.object(test_journeys.android, 'device', side_effect=self.device(granted=True)) as device:
            with test_journeys.completed_onboarding('emulator-5562', evidence):
                pass
        actions = [call.args[1:] for call in device.call_args_list]
        self.assertFalse(any('grant' in action or 'revoke' in action for action in actions))
        self.assertFalse(any('-' + self.package in action or '+' + self.package in action for action in actions))
        self.assertTrue(evidence['restored'])


class AndroidJourneyVerdict(unittest.TestCase):
    def test_parent_stream_completion_is_a_required_native_journey(self):
        name = 'completed child stays in current work while the parent streams'
        self.assertIn(name, ROADMAP)
        result = verdict(events(ROADMAP, omitted=name), 0, ROADMAP)
        self.assertFalse(result['passed'])
        self.assertEqual(result['missing'], [name])
        self.assertTrue(verdict(events(ROADMAP), 0, ROADMAP)['passed'])

    def test_all_required_journeys_must_complete(self):
        self.assertTrue(verdict(events(), 0, CRITICAL)['passed'])

    def test_successful_empty_run_is_not_acceptance(self):
        self.assertFalse(verdict(['{"type":"done","success":true}'], 0, CRITICAL)['passed'])

    def test_each_missing_journey_fails_even_when_flutter_claims_success(self):
        for name in CRITICAL:
            with self.subTest(name=name):
                self.assertFalse(verdict(events(omitted=name), 0, CRITICAL)['passed'])

    def test_skipping_a_required_journey_fails(self):
        self.assertFalse(verdict(events(skipped=sorted(CRITICAL)[0]), 0, CRITICAL)['passed'])

    def test_assertion_failure_overrides_success_summary(self):
        self.assertFalse(verdict(events(failed=sorted(CRITICAL)[0]), 0, CRITICAL)['passed'])

    def test_build_failure_overrides_test_success(self):
        self.assertFalse(verdict(events(), 1, CRITICAL)['passed'])

    def test_loading_error_overrides_test_success(self):
        lines = events() + [json.dumps({'type': 'error', 'testID': -1})]
        self.assertFalse(verdict(lines, 0, CRITICAL)['passed'])

    def test_interrupted_stream_fails(self):
        self.assertFalse(verdict(events()[:-1], 0, CRITICAL)['passed'])

    def test_duplicate_journeys_are_rejected(self):
        self.assertFalse(verdict(events() + events(), 0, CRITICAL)['passed'])

    def test_build_diagnostics_do_not_hide_real_verdict(self):
        self.assertTrue(verdict(['Installing APK...', '[]'] + events(), 0, CRITICAL)['passed'])

    def test_empty_enrollment_cannot_certify_a_run(self):
        self.assertFalse(verdict(events(), 0, frozenset())['passed'])

    def test_unenrolled_successful_journey_is_rejected(self):
        result = verdict(events(CRITICAL | {'unapproved workflow'}), 0, CRITICAL)
        self.assertFalse(result['passed'])
        self.assertEqual(result['unexpected'], ['unapproved workflow'])

    def test_later_success_summary_cannot_erase_a_failed_summary(self):
        lines = [json.dumps({'type': 'done', 'success': False})] + events()
        self.assertFalse(verdict(lines, 0, CRITICAL)['passed'])


class RequiredProcessRecovery(unittest.TestCase):
    def exercise(self, recovery, *, ordinary_events=None, roadmap_events=None, recovery_error=None,
                 environments=None, captures=None, wait_error=None, exports=None, frame_error=None, capture_error=None, retirements=None):
        with tempfile.TemporaryDirectory(prefix='wing-journey-gate-') as temporary:
            output = Path(temporary)
            log = output / 'critical.jsonl'

            def run_flutter(*args, **kwargs):
                if environments is not None:
                    environments.append(kwargs['env'])
                expected = ROADMAP if args[0][-1].endswith('roadmap_emulator_test.dart') else CRITICAL
                supplied = roadmap_events if expected == ROADMAP else ordinary_events
                kwargs['stdout'].write('\n'.join(events(expected) if supplied is None else supplied))
                return Mock(wait=Mock(return_value=0, side_effect=wait_error))

            def capture(device, path):
                if captures is not None:
                    captures.append((device, path.name))
                if capture_error is not None:
                    raise capture_error

            with patch.object(test_journeys.sys, 'argv', [
                    'test_journeys.py', '--device', 'emulator-5562', '--output', temporary]), \
                 patch.object(test_journeys.os, 'chdir'), \
                 patch.object(test_journeys, 'fingerprint', return_value={'source': 'fixed'}), \
                 patch.object(test_journeys.android, 'OUTPUT', output), \
                 patch.object(test_journeys.android, 'require_emulator'), \
                 patch.object(test_journeys.android, 'device', side_effect=lambda serial, *args: 'package:/fixture/base.apk' if args[:2] == ('shell', 'pm') and args[2] == 'path' else ''), \
                 patch.object(test_journeys.subprocess, 'Popen', side_effect=run_flutter), \
                 patch.object(test_journeys, 'stop_process_group',
                              side_effect=lambda process: retirements.append(process) if retirements is not None else None), \
                 patch.object(test_journeys.subprocess, 'run', side_effect=frame_error) as export, \
                 patch.object(test_journeys.android, 'adb_path', return_value='/owned/sdk/adb'), \
                 patch.object(test_journeys.android, 'capture_failure',
                              side_effect=capture), \
                 patch.object(test_journeys.process_recovery, 'run', return_value=recovery,
                              side_effect=recovery_error) as run, \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = test_journeys.main()
                if exports is not None:
                    exports.extend(export.call_args_list)
            self.assertTrue(log.exists())
            return code, json.loads((output / 'receipt.json').read_text()), run.call_args_list

    def test_failure_frame_is_exported_without_opt_in_capture_flag(self):
        exports = []
        lines = events(failed=sorted(CRITICAL)[0]) + [json.dumps({
            'type': 'print', 'message': 'Journey frame: /data/user/0/qa/failure.png'})]
        code, receipt, _ = self.exercise(None, ordinary_events=lines, exports=exports)
        self.assertEqual(code, 1)
        self.assertEqual(len(exports), 1)
        self.assertIn('/data/user/0/qa/failure.png', exports[0].args[0])
        self.assertEqual(len(receipt['suites']['critical']['frames']), 1)
        self.assertTrue(receipt['suites']['critical']['failed'])

    def test_frame_export_error_keeps_original_failure(self):
        lines = events(failed=sorted(CRITICAL)[0]) + [json.dumps({
            'type': 'print', 'message': 'Journey frame: /data/user/0/qa/failure.png'})]
        code, receipt, _ = self.exercise(None, ordinary_events=lines,
            frame_error=OSError('device unavailable'))
        self.assertEqual(code, 1)
        self.assertTrue(receipt['suites']['critical']['failed'])
        self.assertEqual(receipt['suites']['critical']['capture_errors'], ['device unavailable'])

    def test_failed_suite_captures_owned_device_without_running_next_suite(self):
        captures = []
        code, receipt, _ = self.exercise({'passed': True}, ordinary_events=[], captures=captures)
        self.assertEqual(code, 1)
        self.assertEqual(captures, [('emulator-5562', 'critical-failure')])
        # Flutter 3.44 crashes its native LiveTest runner with --fail-fast.
        self.assertNotIn('--fail-fast', receipt['suites']['critical']['command'])
        self.assertNotIn('roadmap', receipt['suites'])

    def test_timeout_keeps_failed_receipt_and_captures_before_retirement(self):
        captures = []
        code, receipt, calls = self.exercise(None, captures=captures,
            wait_error=test_journeys.subprocess.TimeoutExpired('flutter', 900))
        self.assertEqual(code, 1)
        self.assertFalse(receipt['passed'])
        self.assertIn('timed out', receipt['suites']['critical']['error'])
        self.assertEqual(captures, [('emulator-5562', 'critical-failure')])
        self.assertEqual(calls, [])

    def test_capture_exception_preserves_timeout_and_retires_flutter(self):
        for error in [OSError('disk full'), RuntimeError('capture failed')]:
            with self.subTest(error=error):
                retired = []
                code, receipt, calls = self.exercise(None, capture_error=error, retirements=retired,
                    wait_error=test_journeys.subprocess.TimeoutExpired('flutter', 900))
                self.assertEqual(code, 1)
                self.assertEqual(len(retired), 1)
                self.assertIn('timed out', receipt['error'])
                self.assertEqual(receipt['suites']['critical']['capture_errors'], [str(error)])
                self.assertEqual(calls, [])

    def test_success_requires_completed_process_recovery_on_same_emulator(self):
        code, receipt, calls = self.exercise({'passed': True})
        self.assertEqual(code, 0)
        self.assertTrue(receipt['passed'])
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].args[0], 'emulator-5562')
        self.assertEqual(calls[0].args[1].name, 'process-recovery')

    def test_journeys_override_conflicting_inherited_android_variants(self):
        flavors = {'ORG_GRADLE_PROJECT_' + name: value for name, value in {
            'notificationQa': 'true', 'performanceQa': 'false',
            'nativeShareQa': 'false', 'wingDevelopment': 'false',
        }.items()}
        environments = []
        with patch.dict(test_journeys.os.environ,
                        {name: 'false' if value == 'true' else 'true'
                         for name, value in flavors.items()}):
            code, _, _ = self.exercise({'passed': True}, environments=environments)
        self.assertEqual(code, 0)
        self.assertEqual(len(environments), 2)
        for environment in environments:
            self.assertEqual({name: environment[name] for name in flavors}, flavors)

    def test_failed_process_recovery_blocks_otherwise_passing_journeys(self):
        code, receipt, _ = self.exercise({'passed': False, 'error': 'restoration failed'})
        self.assertEqual(code, 1)
        self.assertFalse(receipt['passed'])
        self.assertEqual(receipt['process_recovery']['error'], 'restoration failed')

    def test_missing_or_non_boolean_recovery_success_cannot_pass(self):
        for recovery in ({}, {'passed': 'true'}, {'passed': 1}):
            with self.subTest(recovery=recovery):
                code, receipt, _ = self.exercise(recovery)
                self.assertEqual(code, 1)
                self.assertFalse(receipt['passed'])

    def test_failed_initial_journey_never_runs_additional_device_work(self):
        code, receipt, calls = self.exercise({'passed': True}, ordinary_events=[])
        self.assertEqual(code, 1)
        self.assertFalse(receipt['passed'])
        self.assertEqual(calls, [])

    def test_each_missing_roadmap_journey_blocks_recovery_and_acceptance(self):
        for missing in ROADMAP:
            with self.subTest(missing=missing):
                code, receipt, calls = self.exercise(
                    {'passed': True}, roadmap_events=events(ROADMAP, omitted=missing))
                self.assertEqual(code, 1)
                self.assertFalse(receipt['passed'])
                self.assertEqual(receipt['suites']['roadmap']['missing'], [missing])
                self.assertEqual(calls, [])

    def test_recovery_exception_cannot_leave_a_successful_receipt(self):
        code, receipt, _ = self.exercise(None, recovery_error=RuntimeError('device stopped'))
        self.assertEqual(code, 1)
        self.assertFalse(receipt['passed'])
        self.assertEqual(receipt['error'], 'device stopped')
