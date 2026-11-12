"""Checker proofs must reject missing coverage and survive optimized Python."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from tools.architecture.fixture_contract import validate_cases


ROOT = Path(__file__).resolve().parents[2]
CASES = [dict(name='valid', exit=0), dict(name='invalid', exit=1),
         dict(name='input', exit=2)]


class FixtureContractTest(unittest.TestCase):
    def test_complete_corpus_retains_case_payloads(self):
        cases = copy.deepcopy(CASES)
        cases[0]['source'] = 'valid fixture'
        self.assertIs(validate_cases(cases, required_names=('valid',)), cases)

    def test_empty_corpus_cannot_prove_a_checker(self):
        for cases in ([], None, {}):
            with self.subTest(cases=cases), self.assertRaises(ValueError):
                validate_cases(cases)

    def test_each_exit_category_is_required(self):
        for status in (0, 1, 2):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, 'exit categories'):
                validate_cases([case for case in CASES if case['exit'] != status])

    def test_named_cli_representative_cannot_silently_disappear(self):
        with self.assertRaisesRegex(ValueError, 'CLI representatives'):
            validate_cases(CASES, required_names=('deleted-cli-case',))

    def test_names_must_identify_distinct_cases(self):
        for name in ('', ' ', None, 'invalid'):
            cases = copy.deepcopy(CASES)
            cases[0]['name'] = name
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'names'):
                validate_cases(cases)

    def test_exit_must_be_an_explicit_supported_integer(self):
        for status in (False, True, '1', None, 3):
            cases = copy.deepcopy(CASES)
            cases[0]['exit'] = status
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, 'explicit exit'):
                validate_cases(cases)


class NativeProofHarnessTest(unittest.TestCase):
    HARNESSES = (
        ('native_share/prove_boundary.py', 'contract.fixture.json'),
        ('native_share/prove_qa_isolation.py', 'qa_isolation.fixture.json'),
        ('native_notification/prove_boundary.py', 'contract.fixture.json'),
        ('native_notification/prove_declarations.py', 'declaration.fixture.json'),
        ('native_voice/prove_boundary.py', 'contract.fixture.json'),
    )

    def run_harness(self, relative, fixture, *, empty=False):
        with tempfile.TemporaryDirectory(prefix='wing-proof-self-test-') as temporary:
            architecture = Path(temporary) / 'architecture'
            script = architecture / relative
            script.parent.mkdir(parents=True)
            original = ROOT / 'tools/architecture' / relative
            shutil.copy2(original, script)
            shutil.copy2(ROOT / 'tools/architecture/fixture_contract.py', architecture)
            corpus = json.loads(original.with_name(fixture).read_text())
            if empty:
                corpus['cases'] = []
            else:
                # A lying guard reports success for the first prohibited case.
                corpus['cases'].sort(key=lambda case: case['exit'] != 1)
            script.with_name(fixture).write_text(json.dumps(corpus))
            # Test only harness verdict propagation; no Kotlin/Android tooling.
            dependency = ('import sys\nfrom pathlib import Path\n'
                          "ID = 'FIXTURE_DIAGNOSTIC'\nNATIVE = Path('native')\n"
                          "def command(): return [sys.executable, '-c', 'pass']\n"
                          'lifecycle_command = command\n')
            for module in ('provider_boundary', 'retired_action', 'retired_declaration',
                           'file_api_boundary', 'permission_lifecycle'):
                script.with_name(module + '.py').write_text(dependency)
            return subprocess.run([sys.executable, '-O', str(script)],
                                  cwd=temporary, capture_output=True, text=True,
                                  env={**os.environ, 'PYTHONOPTIMIZE': '1'}, timeout=10)

    def test_each_native_harness_rejects_a_lying_guard_under_optimization(self):
        for relative, fixture in self.HARNESSES:
            with self.subTest(harness=relative):
                result = self.run_harness(relative, fixture)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('AssertionError', result.stderr)
                self.assertNotIn('CLI fixture', result.stdout)

    def test_each_native_harness_rejects_empty_fixture_discovery(self):
        for relative, fixture in self.HARNESSES:
            with self.subTest(harness=relative):
                result = self.run_harness(relative, fixture, empty=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('nonempty case list', result.stderr)


class AdministrationSeedGuardTest(unittest.TestCase):
    def test_optimized_seed_rejects_a_non_disposable_home_before_network(self):
        result = subprocess.run(
            [sys.executable, '-O', str(ROOT / 'tools/qa/prepare_administration_live.py'),
             '--home', str(ROOT), '--port', '1'],
            capture_output=True, text=True, timeout=3,
            env={**os.environ, 'PYTHONOPTIMIZE': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Requires an existing disposable admin-live- home', result.stderr)

    def test_valid_temporary_home_still_rejects_invalid_port_before_network(self):
        with tempfile.TemporaryDirectory(prefix='admin-live-') as temporary:
            (Path(temporary) / 'config.yaml').write_text('model: {}\n')
            result = subprocess.run(
                [sys.executable, '-O', str(ROOT / 'tools/qa/prepare_administration_live.py'),
                 '--home', temporary, '--port', '0'],
                capture_output=True, text=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Requires a valid disposable gateway port', result.stderr)


class NativeBenchmarkGuardTest(unittest.TestCase):
    def test_optimized_benchmark_does_not_record_failed_guard_timings(self):
        with tempfile.TemporaryDirectory(prefix='wing-benchmark-self-test-') as temporary:
            root = Path(temporary)
            script = root / 'benchmark_guard.py'
            shutil.copy2(ROOT / 'tools/architecture/native_voice/benchmark_guard.py', script)
            (root / 'file_api_boundary.py').write_text(
                'import sys\nfrom pathlib import Path\n'
                'ROOT = Path(__file__).parent\n'
                "def command(): return [sys.executable, '-c', 'raise SystemExit(7)']\n")
            (root / 'provider_boundary.py').write_text(
                'def kotlin_version():\n'
                "    raise AssertionError('Failed guard must not report compiler metadata')\n")
            native = root / 'android/app/src/main/kotlin/com/tarkilhk/wing'
            native.mkdir(parents=True)
            for name in ('VoiceChannel', 'VoiceCapture', 'VoicePlayback'):
                (native / (name + '.kt')).write_text('class ' + name + ' {}\n')
            output = root / 'timings.json'
            result = subprocess.run(
                [sys.executable, '-O', str(script), '--output', str(output)],
                capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('CalledProcessError', result.stderr)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
