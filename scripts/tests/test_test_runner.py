import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import signal
import sys
import tempfile
import time
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location('wing_test_runner', Path(__file__).parents[1] / 'test.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class TestCadence(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='wing-cadence-git-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git('init', '-q')
        self.write('lib/value.dart', 'class Value {}')
        self.write('tools/architecture/rules/example.dart', 'void main() {}')
        self.git('add', '.')
        self.git('commit', '-qm', 'Initial inputs')
        self.reference = self.git('rev-parse', 'HEAD').strip()

    def git(self, *arguments):
        return subprocess.check_output([
            'git', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Test',
            '-c', 'user.email=test@example.invalid', *arguments,
        ], cwd=self.root, text=True, stderr=subprocess.PIPE)

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def test_product_changes_stay_routine(self):
        self.write('lib/value.dart', 'class Value { int count = 1; }')
        self.write('test/message_recovery_test.dart', 'void main() {}')
        self.write('docs/usage.md', 'Updated journey')
        self.assertFalse(runner.full_for_changes(self.root, self.reference))

    def test_checker_changes_force_full_including_uncommitted_inputs(self):
        self.write('tools/architecture/rules/example.dart', 'void main() { throw StateError("broken"); }')
        self.assertTrue(runner.full_for_changes(self.root, self.reference))

    def test_new_dependency_runner_workflow_and_proof_inputs_force_full(self):
        for name in [
            'pubspec.lock', 'analysis_options.yaml', 'dart_test.yaml',
            'tools/architecture/fixtures/new.json', 'tools/testing/new.dart',
            'scripts/test.py', 'scripts/check_commit_linters.py',
            '.github/workflows/nightly-tests.yml', '.github/actions/setup-flutter/action.yml',
            'test/new_guard_test.dart', 'test/architecture_contract_test.dart',
            'test/architecture_proof_process_test.dart', 'test/test_batches_test.dart',
            'test/support/new_fixture.dart', 'test/subfolder/flutter_test_config.dart',
            'test/fixtures/new.json', 'test/helpers/new.dart',
        ]:
            with self.subTest(name=name):
                self.write(name, 'new input')
                self.assertTrue(runner.full_for_changes(self.root, self.reference))
                (self.root / name).unlink()

    def test_missing_invalid_or_option_like_history_fails_closed(self):
        for reference in ['', '0' * 40, 'missing-reference', '--help', '--stat']:
            with self.subTest(reference=reference):
                self.assertTrue(runner.full_for_changes(self.root, reference))
        self.assertTrue(runner.full_for_changes(self.root / 'missing', self.reference))

    def test_deleted_checker_forces_full(self):
        (self.root / 'tools/architecture/rules/example.dart').unlink()
        self.assertTrue(runner.full_for_changes(self.root, self.reference))

    def test_renamed_checker_cannot_hide_old_tool_path(self):
        self.git('mv', 'tools/architecture/rules/example.dart', 'lib/renamed.dart')
        self.assertTrue(runner.full_for_changes(self.root, self.reference))

    def run_verification(self, lint_exit, test_exit, mutate_source=False, skip_linters=False,
                         full=False, events=None):
        self.write('.gitignore', 'build/\n')
        self.write('test/example_test.dart', 'void main() {}')
        self.write('scripts/check_commit_linters.py', '''
from pathlib import Path
import sys, time
Path('build/linter-started').touch()
started = Path('build/test-started')
for _ in range(300):
    if started.exists(): break
    time.sleep(.01)
else:
    sys.exit(99)
print('fixture linter result', file=sys.stderr)
sys.exit(''' + str(lint_exit) + ''')
''')
        self.write('bin/dart', '''#!/usr/bin/env python3
import json, sys
if '--version' in sys.argv:
    print('Fixture Dart SDK')
else:
    print(json.dumps(dict(files=['test/example_test.dart'],
        isolated=['test/example_test.dart'], batches=[], scheduled=[],
        targets=['test/example_test.dart'], dart_executable=sys.argv[0], proof_commands=[])))
''')
        self.write('bin/flutter', '''#!/usr/bin/env python3
import json, sys
from pathlib import Path
if '--version' in sys.argv:
    print('{}')
else:
    Path('build/test-started').touch()
    events = ''' + repr(events) + '''
    if events is not None:
        for event in events:
            print(json.dumps(event))
        sys.exit(''' + str(test_exit) + ''')
    if ''' + str(mutate_source) + ''':
        Path('lib/value.dart').write_text('class ChangedDuringTests {}')
    print(json.dumps(dict(type='testStart', test=dict(id=1, name='fixture behavior'))))
    code = ''' + str(test_exit) + '''
    if code:
        print(json.dumps(dict(type='print', testID=1, message='Expected one button, found none')))
        print(json.dumps(dict(type='error', testID=1, error='See exception logs above.')))
    print(json.dumps(dict(type='testDone', testID=1, result='error' if code else 'success')))
    print(json.dumps(dict(type='done', success=not code)))
    sys.exit(code)
''')
        for name in ('flutter', 'dart'):
            (self.root / 'bin' / name).chmod(0o700)
        output, error = io.StringIO(), io.StringIO()
        with (mock.patch.object(runner, 'ROOT', self.root),
              mock.patch('sys.argv', ['test.py', '--concurrency=2'] +
                         (['--skip-linters'] if skip_linters else []) +
                         (['--full'] if full else [])),
              mock.patch.object(runner, 'prepare_proof_commands',
                                side_effect=lambda *_: dict(os.environ)),
              mock.patch.dict(os.environ, {'PATH': str(self.root / 'bin') + os.pathsep + os.environ['PATH']}),
              contextlib.redirect_stdout(output), contextlib.redirect_stderr(error)):
            result = runner.main()
        self.assertTrue((self.root / 'build/test-started').exists())
        if 'evidence ' in output.getvalue():
            archive = Path(output.getvalue().rsplit('evidence ', 1)[-1].strip())
            self.addCleanup(shutil.rmtree, archive)
        return result, output.getvalue(), error.getvalue()

    def test_empty_success_event_cannot_certify_a_test_run(self):
        result, _, error = self.run_verification(
            0, 0, events=[dict(type='done', success=True)])
        self.assertEqual(result, 1)
        self.assertIn('empty or skipped run', error)

    def test_all_skipped_tests_cannot_certify_behavior(self):
        result, output, _ = self.run_verification(0, 0, events=[
            dict(type='testStart', test=dict(id=1, name='requires live backend')),
            dict(type='testDone', testID=1, result='success', skipped=True),
            dict(type='done', success=True),
        ])
        self.assertEqual(result, 1)
        archive = Path(output.rsplit('evidence ', 1)[-1].strip())
        summary = json.loads((archive / 'summary.json').read_text())
        self.assertEqual(summary['skipped_tests'], ['requires live backend'])

    def test_test_failure_is_not_overruled_by_successful_process_exit(self):
        result, _, _ = self.run_verification(0, 0, events=[
            dict(type='testDone', testID=1, result='failure'),
            dict(type='testDone', testID=2, result='success'),
            dict(type='done', success=True),
        ])
        self.assertEqual(result, 1)

    def test_reported_error_is_not_overruled_by_success_summary(self):
        result, _, error = self.run_verification(0, 0, events=[
            dict(type='error', error='Loading failed'),
            dict(type='testDone', testID=1, result='success'),
            dict(type='done', success=True),
        ])
        self.assertEqual(result, 1)
        self.assertIn('Loading failed', error)

    def test_linter_failure_fails_even_when_product_tests_pass(self):
        result, output, error = self.run_verification(lint_exit=23, test_exit=0)
        self.assertEqual(result, 23)
        self.assertIn('fixture linter result', error)
        self.assertNotIn('Current-source linters passed.', output)
        self.assertTrue((self.root / 'build/linter-started').exists())

    def test_full_run_cannot_omit_failing_current_source_linters(self):
        result, output, error = self.run_verification(23, 0, full=True)
        self.assertEqual(result, 23)
        self.assertIn('fixture linter result', error)
        self.assertTrue((self.root / 'build/linter-started').exists())
        archive = Path(output.rsplit('evidence ', 1)[-1].strip())
        summary = json.loads((archive / 'summary.json').read_text())
        self.assertEqual(summary['suite'], 'full')
        self.assertEqual(summary['linters'], 'local')

    def test_full_run_records_passing_source_linters(self):
        result, output, error = self.run_verification(0, 0, full=True)
        self.assertEqual(result, 0, error)
        self.assertIn('Current-source linters passed.', output)
        self.assertTrue((self.root / 'build/linter-started').exists())

    def test_full_run_can_use_explicit_external_linter_gate(self):
        result, output, error = self.run_verification(23, 0, full=True, skip_linters=True)
        self.assertEqual(result, 0, error)
        self.assertFalse((self.root / 'build/linter-started').exists())
        archive = Path(output.rsplit('evidence ', 1)[-1].strip())
        self.assertEqual(json.loads((archive / 'summary.json').read_text())['linters'], 'external')

    def test_ci_external_linters_do_not_require_native_tooling_before_tests(self):
        result, output, error = self.run_verification(23, 0, skip_linters=True)
        self.assertEqual(result, 0)
        self.assertFalse((self.root / 'build/linter-started').exists())
        self.assertIn('current-source linters must run separately', output)
        archive = Path(output.rsplit('evidence ', 1)[-1].strip())
        self.assertEqual(json.loads((archive / 'summary.json').read_text())['linters'], 'external')

    def test_external_linters_cannot_hide_product_failure(self):
        result, output, error = self.run_verification(0, 7, skip_linters=True)
        self.assertEqual(result, 7)
        self.assertIn('Expected one button, found none', error)

    def test_product_failure_and_assertion_details_survive_passing_linters(self):
        result, output, error = self.run_verification(lint_exit=0, test_exit=7)
        self.assertEqual(result, 7)
        self.assertIn('Expected one button, found none', error)
        self.assertIn('Current-source linters passed.', output)

    def test_changed_source_invalidates_passing_tests_and_recorded_result(self):
        result, output, error = self.run_verification(0, 0, mutate_source=True)
        self.assertEqual(result, 1)
        self.assertIn('Sources changed during verification', error)
        archive = Path(output.rsplit('evidence ', 1)[-1].strip())
        summary = json.loads((archive / 'summary.json').read_text())
        self.assertEqual(summary['exit_code'], result)
        self.assertNotEqual(summary['source_before'], summary['source_after'])

    def test_cleanup_terminates_descendant_that_ignores_term(self):
        pid_file = self.root / 'owned-child.pid'
        child = '''
import os, signal, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(30)
'''
        leader = subprocess.Popen([
            sys.executable, '-c',
            'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",sys.argv[1],sys.argv[2]]); time.sleep(30)',
            child, str(pid_file),
        ], start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(pid_file.exists(), 'owned descendant must be ready before cleanup')
            child_pid = int(pid_file.read_text())
            runner.stop_process_group(leader)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                state = Path(f'/proc/{child_pid}/stat')
                try:
                    stopped = state.read_text().split()[2] == 'Z'
                except (FileNotFoundError, ProcessLookupError):
                    stopped = True
                if stopped:
                    break
                time.sleep(.01)
            else:
                self.fail('owned descendant survived cleanup')
        finally:
            try:
                os.killpg(leader.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            leader.wait()


class TestProofCompilation(unittest.TestCase):
    def test_compilation_failure_is_visible_and_retains_evidence(self):
        with tempfile.TemporaryDirectory(prefix='wing-proof-error-') as scratch:
            directory = Path(scratch)
            dart = directory / 'dart'
            (directory / 'dartaotruntime').touch()
            error = io.StringIO()
            with (mock.patch.object(runner.subprocess, 'run', return_value=
                  subprocess.CompletedProcess([], 1, 'compiler output\n', 'specific compiler error\n')),
                  contextlib.redirect_stderr(error),
                  self.assertRaisesRegex(ValueError, 'dispatcher did not compile')):
                runner.prepare_proof_commands(str(dart), directory, [], directory)
            self.assertIn('specific compiler error', error.getvalue())
            self.assertEqual((directory / 'proof-compilation.stdout').read_text(), 'compiler output\n')
            self.assertEqual((directory / 'proof-compilation.stderr').read_text(), 'specific compiler error\n')

    @unittest.skipUnless(shutil.which('dart'), 'activate the project Dart SDK')
    def test_current_dispatcher_compiles_and_runs_task_intent_probe(self):
        with tempfile.TemporaryDirectory(prefix='wing-proof-compilation-') as scratch:
            directory = Path(scratch)
            planning = subprocess.run([
                shutil.which('dart'), '--packages=.dart_tool/package_config.json',
                'tools/testing/test_batches.dart', str(directory), '2', 'full',
            ], cwd=runner.ROOT, capture_output=True, text=True)
            self.assertEqual(planning.returncode, 0, planning.stderr)
            plan = json.loads(planning.stdout)
            environment = runner.prepare_proof_commands(
                plan['dart_executable'], directory, plan['proof_commands'], directory,
            )
            result = subprocess.run([
                str(directory / 'bin/dart'), 'run',
                'tools/architecture/tests/task_edit_intent_test.dart',
            ], cwd=runner.ROOT, capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('checks passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
