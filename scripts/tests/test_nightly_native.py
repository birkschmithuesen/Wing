import contextlib
from datetime import datetime, timedelta, timezone
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from zipfile import ZipFile

from scripts import test_nightly_native as nightly
from scripts import test_native_notification_counts as counts


def events(*, skipped=False, failed=False, omitted=False):
    rows = [{'type': 'testStart', 'test': {'id': 1, 'name': 'owning outcome'}}]
    if not omitted:
        rows.append({'type': 'testDone', 'testID': 1, 'hidden': False,
                     'skipped': skipped, 'result': 'failure' if failed else 'success'})
    rows.append({'type': 'done', 'success': True})
    return '\n'.join(json.dumps(row) for row in rows)


class NativeExecution(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        self.runner = nightly.Runner(self.output)

    def command(self, text, code=0):
        return [sys.executable, '-c', f'print({text!r}); raise SystemExit({code})']

    def test_stock_source_is_admitted_before_emulator_boot_can_advance_upstream(self):
        from scripts import test_vanilla_hermes as vanilla
        order = []
        upstream = ['a' * 40]

        @contextlib.contextmanager
        def emulator():
            order.append('emulator boot')
            upstream[0] = 'b' * 40  # Official main advances while Android starts.
            try:
                yield 'emulator-5562'
            finally:
                order.append('emulator retired')

        class StockRunner(nightly.Runner):
            def driver(self, script, *args):
                order.append('source admission')
                vanilla.validate_source(Path('/prepared-stock'))
                context = (contextlib.nullcontext(self.device) if '--device' in args
                           else nightly.android.owned_emulator())
                with context:
                    self.steps.append({'name': 'stock journeys', 'passed': True})

        with patch.object(sys, 'argv', ['nightly', 'stock-hermes', '--hermes-source',
                                       '/prepared-stock', '--output', str(self.output)]), \
             patch.object(nightly, 'Runner', StockRunner), \
             patch.object(nightly, 'fingerprint', return_value='stable'), \
             patch.object(nightly.android, 'owned_emulator', side_effect=emulator), \
             patch.object(nightly.android, 'require_emulator'), \
             patch.object(nightly.android, 'capture_failure'), \
             patch.object(vanilla, 'checkout_revision', return_value='a' * 40), \
             patch.object(vanilla, 'current_upstream_revision', side_effect=lambda: upstream[0]), \
             contextlib.redirect_stdout(io.StringIO()):
            code = nightly.main()
        self.assertEqual(code, 0)
        self.assertEqual(order, ['source admission', 'emulator boot', 'emulator retired'])

    def test_counts_retires_its_work_lease_when_a_native_assertion_fails(self):
        requests = []
        def post(request, **kwargs):
            requests.append(request.full_url.rsplit('/', 1)[-1])
            return io.BytesIO(b'{}')
        with patch.object(sys, 'argv', ['counts', '--serial', 'emulator-5562']), \
             patch.object(counts.native, 'SERIAL', 'emulator-5562'), \
             patch.object(counts.urllib.request, 'urlopen', side_effect=post), \
             patch.object(counts.native, 'adb', side_effect=lambda *a: requests.append('foreground')), \
             patch.object(counts.native, 'wait_for_monitoring_notification'), \
             patch.object(counts.native, 'shown_notification', side_effect=AssertionError('wrong card')):
            with self.assertRaisesRegex(AssertionError, 'wrong card'):
                counts.main()
        self.assertEqual(requests, ['work', 'preview', 'question', 'foreground', 'stop'])

    def test_completed_exact_case_and_registered_wrapper_pass(self):
        for expected in (frozenset({'owning outcome'}), 'registered'):
            self.runner.run('complete', self.command(events()), expected=expected)
            self.assertTrue(self.runner.steps[-1]['passed'])

    def test_skipped_failed_missing_empty_and_nonzero_cannot_pass(self):
        cases = [(events(skipped=True), 0), (events(failed=True), 0),
                 (events(omitted=True), 0), ('{"type":"done","success":true}', 0),
                 (events(), 1)]
        for expected in (frozenset({'owning outcome'}), 'registered'):
            for text, code in cases:
                with self.subTest(expected=expected, text=text, code=code), \
                     contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(RuntimeError):
                        self.runner.run('incomplete', self.command(text, code), expected=expected)
                    self.assertFalse(self.runner.steps[-1]['passed'])

    def test_unknown_or_duplicate_case_cannot_replace_expected_outcome(self):
        for text in (events().replace('owning outcome', 'different outcome'),
                     events().replace('{"type": "done", "success": true}',
                                      '{"type":"testDone","testID":1,"result":"success"}\n'
                                      '{"type":"done","success":true}')):
            with self.subTest(text=text), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    self.runner.run('wrong', self.command(text), expected=frozenset({'owning outcome'}))

    def test_deadline_stops_owned_process(self):
        with patch.object(nightly, 'stop_process_group', wraps=nightly.stop_process_group) as stop:
            with self.assertRaises(TimeoutError):
                self.runner.run('timeout', [sys.executable, '-c', 'import time;time.sleep(60)'], timeout=.01)
            self.assertIsNotNone(stop.call_args.args[0].poll())
        self.assertFalse(self.runner.steps[-1]['passed'])

    def test_driver_cancellation_runs_its_cleanup(self):
        marker = self.output / 'retired'
        ready = self.output / 'ready'
        script = self.output / 'driver.py'
        script.write_text('from pathlib import Path\nimport time\ntry:\n'
                          f' Path({str(ready)!r}).touch()\n time.sleep(60)\n'
                          f'finally:\n Path({str(marker)!r}).touch()\n')
        with patch.object(self.runner, 'run') as run:
            self.runner.driver(str(script))
        command = run.call_args.args[1]
        child = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(ready.exists())
            child.send_signal(signal.SIGTERM)
            self.assertNotEqual(child.wait(timeout=5), 0)
            self.assertTrue(marker.exists())
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    def test_forward_is_removed_after_failure(self):
        with patch.object(self.runner, 'adb', return_value='43123') as adb:
            with self.assertRaisesRegex(RuntimeError, 'test failure'):
                with self.runner.forward('tcp:18766'):
                    raise RuntimeError('test failure')
        self.assertEqual(adb.call_args_list[-1].args, ('forward', '--remove', 'tcp:43123'))

    def test_diagnostic_failures_are_recorded_without_replacing_the_test_error(self):
        with patch.object(nightly.android, 'device', side_effect=OSError('device unavailable')), \
             patch.object(nightly.android, 'adb_path', return_value='/owned/sdk/adb'), \
             patch.object(nightly.subprocess, 'run', side_effect=OSError('capture unavailable')):
            self.runner.capture_failure()
        errors = json.loads((self.output / 'capture-errors.json').read_text())
        self.assertEqual(len(errors), 8)
        self.assertTrue(any('failure-window.txt' in error for error in errors))
        self.assertTrue(any('failure.png' in error for error in errors))

    def test_clipboard_foreign_fixture_is_retired_after_test_failure(self):
        with patch.object(nightly.android, 'adb_path', return_value='/owned/sdk/adb'), \
             patch.object(self.runner, 'run'), patch.object(self.runner, 'shell'), \
             patch.object(self.runner, 'adb', return_value='') as adb, \
             patch.object(self.runner, 'flutter', side_effect=RuntimeError('Paste failed')):
            with self.assertRaisesRegex(RuntimeError, 'Paste failed'):
                self.runner.clipboard()
            self.assertEqual(adb.call_args.args, ('uninstall', 'com.tarkilhk.wing.shareqa.fixture'))

    def test_checkpoint_reader_waits_for_a_complete_record(self):
        stages = [subprocess.CompletedProcess([], code, text) for code, text in (
            (1, ''), (0, ''), (0, '{"token":'), (0, '{"token":"ready"}'))]
        with patch.object(nightly.android, 'adb_path', return_value='/owned/sdk/adb'), \
             patch.object(nightly.subprocess, 'run', side_effect=stages):
            for _ in range(3):
                self.assertIsNone(self.runner.read_checkpoint(nightly.QA, 'stage.json'))
            self.assertEqual(self.runner.read_checkpoint(nightly.QA, 'stage.json'), {'token': 'ready'})

    def test_complete_invalid_checkpoint_fails_instead_of_waiting(self):
        for text in ('null', '[]', '1'):
            with self.subTest(text=text), \
                 patch.object(nightly.android, 'adb_path', return_value='/owned/sdk/adb'), \
                 patch.object(nightly.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, text)):
                with self.assertRaisesRegex(ValueError, 'JSON object'):
                    self.runner.read_checkpoint(nightly.QA, 'stage.json')

    def test_retention_ack_follows_real_home_interval_and_reopen_once(self):
        checkpoint = self.runner.retention_checkpoint()
        stage = {'token': 'background-30', 'action': 'background', 'seconds': 30}
        order = []
        with patch.object(self.runner, 'read_checkpoint', return_value=stage), \
             patch.object(self.runner, 'shell', side_effect=lambda *a: order.append(a)), \
             patch.object(nightly.time, 'sleep', side_effect=lambda s: order.append(('wait', s))), \
             patch.object(nightly.android, 'adb_path', return_value='/owned/sdk/adb'), \
             patch.object(nightly.subprocess, 'run', side_effect=lambda *a, **kw: order.append(('ack', kw['input']))):
            checkpoint()
            checkpoint()
        self.assertEqual(order, [
            ('input', 'keyevent', 'KEYCODE_HOME'), ('wait', 30),
            ('am', 'start', '-W', '-n', nightly.QA + '/com.tarkilhk.wing.MainActivity'),
            ('ack', 'background-30'),
        ])

    def test_slash_native_checkpoints_configure_type_capture_and_ack_once(self):
        with patch.object(self.runner, 'flutter') as flutter:
            self.runner.slash()
        checkpoint = flutter.call_args.kwargs['checkpoint']
        for theme, scale in (('dark', '1.0'), ('light', '2.0')):
            for action in ('configure', 'type-inline', 'picker-ready', 'selected',
                           'type-suffix', 'suffix-ready', 'backspace'):
                name = f'{theme}-{scale}-{action}'
                stage = subprocess.CompletedProcess([], 0, json.dumps({'name': name, 'token': name}))
                with self.subTest(name=name), \
                     patch.object(nightly.android, 'adb_path', return_value='/owned/sdk/adb'), \
                     patch.object(nightly.subprocess, 'run', return_value=stage) as run, \
                     patch.object(nightly.time, 'sleep'), \
                     patch.object(self.runner, 'shell', return_value='mWindowVisible=true mIsInputViewShown=true') as shell:
                    checkpoint()
                    self.assertEqual(run.call_args.kwargs['input'], name)
                    if action == 'configure':
                        shell.assert_any_call('wm', 'size', '840x2215' if scale == '2.0' else '1024x2215')
                    if action == 'type-inline':
                        shell.assert_any_call('input', 'text', 'Please%suse%s/a-')
                    if action == 'type-suffix':
                        shell.assert_any_call('input', 'text', 'for%sthis%stask')
                    if action == 'backspace':
                        shell.assert_any_call('input', 'keyevent', 'KEYCODE_DEL')
                    run.reset_mock()
                    shell.reset_mock()
                    checkpoint()
                    self.assertEqual(run.call_count, 1)  # Only read; never repeat input/ack.
                    shell.assert_not_called()

    def test_slash_hidden_keyboard_cannot_be_acknowledged_as_success(self):
        with patch.object(self.runner, 'flutter') as flutter:
            self.runner.slash()
        stage = subprocess.CompletedProcess([], 0, json.dumps({'name': 'dark-1.0-picker-ready', 'token': 'held'}))
        with patch.object(nightly.android, 'adb_path', return_value='/owned/sdk/adb'), \
             patch.object(nightly.subprocess, 'run', return_value=stage) as run, \
             patch.object(self.runner, 'shell', return_value='mWindowVisible=false mIsInputViewShown=true'):
            with self.assertRaisesRegex(RuntimeError, 'visible Android keyboard'):
                flutter.call_args.kwargs['checkpoint']()
            self.assertEqual(run.call_count, 1)

    def test_administration_requires_all_captured_views(self):
        with patch.object(self.runner, 'flutter'):
            with self.assertRaisesRegex(RuntimeError, 'Missing administration captures'):
                self.runner.administration()

    def test_administration_hidden_keyboard_cannot_be_acknowledged(self):
        stage = {'name': 'hosted-account-light-1.0-keyboard', 'token': 'held', 'keyboard': True}
        def flutter(*args, **kwargs):
            kwargs['checkpoint']()
        with patch.object(self.runner, 'flutter', side_effect=flutter), \
             patch.object(self.runner, 'read_checkpoint', return_value=stage), \
             patch.object(self.runner, 'shell', return_value='mWindowVisible=false mIsInputViewShown=true'), \
             patch.object(nightly.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'visible keyboard'):
                self.runner.administration()
            run.assert_not_called()


class Catalog(unittest.TestCase):
    def test_large_health_runs_at_320_dp_with_enlarged_system_text(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = nightly.Runner(Path(directory))
            with patch.object(runner, 'install'), patch.object(runner, 'flutter'), \
                 patch.object(runner, 'shell') as shell:
                runner.family('health-large')
            shell.assert_any_call('wm', 'density', '420')
            shell.assert_any_call('wm', 'size', '840x2215')
            shell.assert_any_call('settings', 'put', 'system', 'font_scale', '2.0')

    def test_cold_notification_provisions_monitoring_before_launch(self):
        order = []
        with tempfile.TemporaryDirectory() as directory:
            runner = nightly.Runner(Path(directory))
            with patch.object(runner, 'install'), \
                 patch.object(runner, 'shell', side_effect=lambda *a: order.append(a)), \
                 patch.object(runner, 'launch', side_effect=lambda p: order.append(('launch', p))), \
                 patch.object(runner, 'driver'):
                runner.family('notification-cold')
            self.assertEqual(order, [('dumpsys', 'deviceidle', 'whitelist', '+' + nightly.QA),
                                     ('launch', nightly.QA)])

    def test_keyboard_and_clipboard_apks_are_prepared_before_emulator_boot(self):
        order = []
        @contextlib.contextmanager
        def emulator():
            order.append('boot')
            yield 'emulator-5562'
            order.append('retire')
        def family(runner, *args):
            order.append('test')
            runner.steps.append({'name': 'clipboard', 'passed': True})
        for family_name in ('clipboard', 'queue-editing', 'slash'):
            order.clear()
            with tempfile.TemporaryDirectory() as directory, \
                 patch.object(sys, 'argv', ['nightly', family_name, '--output', directory]), \
                 patch.object(nightly.android, 'owned_emulator', side_effect=emulator), \
                 patch.object(nightly.android, 'require_emulator'), \
                 patch.object(nightly, 'fingerprint', return_value='stable'), \
                 patch.object(nightly.Runner, 'build', side_effect=lambda *a, **kw: order.append('build')), \
                 patch.object(nightly.Runner, 'family', family), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(nightly.main(), 0)
                self.assertEqual(order, ['build', 'boot', 'test', 'retire'])

    def test_reviewed_native_boundaries_are_all_enrolled(self):
        self.assertTrue({
            'journeys', 'health-normal', 'health-large', 'backup', 'background',
            'recents', 'recents-code', 'recents-events', 'recents-momentum',
            'notification-actions', 'notification-restore', 'notification-counts',
            'notification-cold', 'voice', 'file-transfer', 'stock-hermes', 'external-share', 'clipboard',
        }.issubset(nightly.FAMILIES))

    def test_empty_and_duplicate_catalogs_fail_before_publishing_outputs(self):
        for families in ((), ('backup', 'backup')):
            with self.subTest(families=families), \
                 patch.object(nightly, 'FAMILIES', families), \
                 patch.object(sys, 'argv', ['nightly', '--matrix']):
                with self.assertRaises(ValueError):
                    nightly.main()

    def test_matrix_contains_each_enrolled_family_once(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'output'
            result = subprocess.run([sys.executable, 'scripts/test_nightly_native.py', '--matrix'],
                                    cwd=nightly.ROOT, capture_output=True, text=True,
                                    env={**os.environ, 'GITHUB_OUTPUT': str(destination)}, check=True)
            families = json.loads(result.stdout)
            self.assertEqual(families, list(nightly.FAMILIES))
            self.assertEqual(len(families), len(set(families)))
            self.assertEqual(json.loads(destination.read_text().split('=', 1)[1]), families)

    def test_unknown_family_is_rejected_before_any_command(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = nightly.Runner(Path(directory))
            with patch.object(runner, 'run') as run:
                with self.assertRaises(ValueError):
                    runner.family('not-enrolled')
                run.assert_not_called()

    def test_every_enrolled_family_dispatches_a_real_suite(self):
        @contextlib.contextmanager
        def forward(_):
            yield '43123'
        with tempfile.TemporaryDirectory() as directory:
            runner = nightly.Runner(Path(directory))
            runner.device = 'emulator-5562'
            for family in nightly.FAMILIES:
                def run_suite(*args, **kwargs):
                    if family != 'administration' or 'checkpoint' not in kwargs:
                        return
                    for theme in ('dark', 'light'):
                        for scale in ('1.0', '2.0'):
                            for surface, states in (
                                ('hosted-account', ('-keyboard', '-pending', '-failed')),
                                ('delegation', ('-keyboard', '-pending')),
                                ('prepared-compression', ('',)),
                                ('connection-request', ('-request', '-pending', '-failed')),
                                ('connection-mcp-enable',
                                 ('-request', '-menu', '-pending', '-failed', '-enabled')),
                            ):
                                for state in states:
                                    name = f'{surface}-{theme}-{scale}{state}'
                                    stage = {'name': name, 'token': name, 'keyboard': state == '-keyboard'}
                                    with patch.object(runner, 'read_checkpoint', return_value=stage), \
                                         patch.object(nightly.subprocess, 'run'), \
                                         patch.object(runner, 'shell', return_value='mWindowVisible=true mIsInputViewShown=true'):
                                        kwargs['checkpoint']()
                with self.subTest(family=family), \
                     patch.object(nightly.android, 'adb_path', return_value='/owned/sdk/adb'), \
                     patch.object(runner, 'run', side_effect=run_suite) as run, \
                     patch.object(runner, 'adb', return_value=''), \
                     patch.object(runner, 'shell', side_effect=lambda *args:
                                  '123' if args[0] == 'pidof' else 'webview_devtools_remote_123'), \
                     patch.object(runner, 'forward', side_effect=forward), \
                     patch.object(runner, 'wait_fixture'):
                    runner.family(family, Path('/owned/hermes'))
                    self.assertTrue(run.called, family)
                    for call in run.call_args_list:
                        if '--reporter=json' in call.args[1]:
                            self.assertTrue(call.kwargs['expected'])

    def test_new_family_cannot_silently_run_another_family(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = nightly.Runner(Path(directory))
            for family in ('new-family', 'notification-new'):
                with self.subTest(family=family), \
                     patch.object(nightly, 'FAMILIES', (*nightly.FAMILIES, family)), \
                     patch.object(runner, 'install'), patch.object(runner, 'driver') as driver:
                    with self.assertRaises(KeyError):
                        runner.family(family)
                    driver.assert_not_called()

    def test_recents_modes_cannot_collapse_to_standard_only(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = nightly.Runner(Path(directory))
            runner.device = 'emulator-5562'
            for mode in ('code', 'events', 'momentum'):
                with patch.object(runner, 'install'), patch.object(runner, 'driver') as driver:
                    runner.family('recents-' + mode)
                self.assertIn('--' + mode + '-only', driver.call_args.args)

    def test_main_failure_retires_emulator_and_records_failed_receipt(self):
        for changing_source in (False, True):
            retired = []
            @contextlib.contextmanager
            def emulator():
                try:
                    yield 'emulator-5562'
                finally:
                    retired.append(True)
            with tempfile.TemporaryDirectory() as directory, \
                 patch.object(sys, 'argv', ['nightly', 'backup', '--output', directory]), \
                 patch.object(nightly.android, 'owned_emulator', side_effect=emulator), \
                 patch.object(nightly.android, 'require_emulator'), \
                 patch.object(nightly, 'fingerprint', side_effect=['before', 'after' if changing_source else 'before']), \
                 patch.object(nightly.Runner, 'family', side_effect=RuntimeError('driver failed')), \
                 patch.object(nightly.Runner, 'capture_failure') as capture, \
                 contextlib.redirect_stdout(io.StringIO()):
                original_output = nightly.android.OUTPUT
                self.assertEqual(nightly.main(), 1)
                result = json.loads((Path(directory) / 'backup/receipt.json').read_text())
                self.assertFalse(result['passed'])
                self.assertEqual(result['error'], 'driver failed')
                self.assertEqual(retired, [True])
                self.assertEqual(nightly.android.OUTPUT, original_output)
                capture.assert_called_once()

    def test_ci_replays_only_a_current_graphics_input_stall_on_a_fresh_emulator(self):
        for scenario, expected_attempts, expected_code in (
            ('graphics', 2, 0),
            ('repeated stall', 2, 1),
            ('stale trace', 1, 1),
            ('unrelated thread', 1, 1),
            ('unrelated timeout', 1, 1),
            ('product assertion', 1, 1),
            ('retirement failed', 1, 1),
            ('local execution', 1, 1),
        ):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                driver = root / 'driver.py'
                action = 'screencap' if scenario == 'unrelated timeout' else 'input'
                failure = (
                    'raise AssertionError("wrong notification count")'
                    if scenario == 'product assertion' else
                    "raise subprocess.TimeoutExpired("
                    f"['adb', '-s', 'emulator-5562', 'shell', {action!r}, 'keyevent', '4'], 20)"
                )
                driver.write_text('import subprocess\n' + failure + '\n')
                events = []

                @contextlib.contextmanager
                def emulator():
                    events.append('boot')
                    try:
                        yield 'emulator-5562'
                    finally:
                        events.append('retire')
                        if scenario == 'retirement failed':
                            raise RuntimeError('The ADB slot remained occupied')

                def family(runner, *_):
                    if events.count('boot') == 1 or scenario == 'repeated stall':
                        runner.driver(str(driver))
                    else:
                        runner.steps.append({'name': 'native journey', 'passed': True})

                def capture(runner):
                    now = datetime.now(timezone.utc)
                    if scenario == 'stale trace':
                        now -= timedelta(minutes=5)
                    package = 'com.google.android.apps.nexuslauncher'
                    thread = 'OtherThread' if scenario == 'unrelated thread' else 'RenderThread'
                    report = runner.output / 'failure-bugreport.zip'
                    with ZipFile(report, 'w') as archive:
                        archive.writestr('FS/data/anr/anr_fixture', (
                            f'Subject: Input dispatching timed out (window {package}/.Activity)\n'
                            f'----- pid 1 at {now.isoformat(sep=" ")} -----\n'
                            f'Cmd line: {package}\n'
                            '"main" prio=5 tid=1 Native\n'
                            '  native: libhwui.so (DrawFrameTask::drawFrame+1)\n'
                            f'"{thread}" daemon prio=7 tid=2 Native\n'
                            '  native: vulkan.ranchu.so (gfxstream::vk::VkEncoder::vkQueueWaitIdle+1)\n'
                            '----- end 1 -----\n'
                        ))
                    return report

                hosted = 'false' if scenario == 'local execution' else 'true'
                with patch.dict(os.environ, {'GITHUB_ACTIONS': hosted}), \
                     patch.object(sys, 'argv', ['nightly', 'notification-counts', '--output', directory]), \
                     patch.object(nightly.android, 'owned_emulator', side_effect=emulator), \
                     patch.object(nightly.android, 'require_emulator'), \
                     patch.object(nightly, 'fingerprint', return_value='stable'), \
                     patch.object(nightly.Runner, 'family', family), \
                     patch.object(nightly.Runner, 'capture_failure', capture), \
                     contextlib.redirect_stdout(io.StringIO()), \
                     contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(nightly.main(), expected_code)

                self.assertEqual(events, ['boot', 'retire'] * expected_attempts)
                output = root / 'notification-counts'
                receipt = json.loads((output / 'receipt.json').read_text())
                self.assertEqual(receipt['passed'], expected_code == 0)
                if expected_attempts == 2:
                    first = output / receipt['graphics_recovery']['first_receipt']
                    self.assertFalse(json.loads(first.read_text())['passed'])
                    self.assertTrue((output / 'failure-bugreport.zip').is_file())

    def test_source_change_invalidates_successful_steps(self):
        def successful(runner, *args):
            runner.steps.append({'name': 'owned driver', 'passed': True})
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(sys, 'argv', ['nightly', 'backup', '--output', directory]), \
             patch.object(nightly.android, 'owned_emulator', return_value=contextlib.nullcontext('emulator-5562')), \
             patch.object(nightly.android, 'require_emulator'), \
             patch.object(nightly, 'fingerprint', side_effect=['before', 'after']), \
             patch.object(nightly.Runner, 'family', successful), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(nightly.main(), 1)
            result = json.loads((Path(directory) / 'backup/receipt.json').read_text())
            self.assertTrue(result['source_changed'])
            self.assertFalse(result['passed'])


if __name__ == '__main__':
    unittest.main()
