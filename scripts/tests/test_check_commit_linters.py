import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('wing_commit_linters', ROOT / 'scripts/check_commit_linters.py')
linters = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linters)


class CommitLintersTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='wing-linter-contract-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.write('tools/architecture/baseline.json', '{"schema":1,"entries":[]}')
        self.write('tools/architecture/model.dart', '''
typedef Rule = Future<void> Function(Object);
Future<T> withSharedSourceParses<T>(Future<T> Function() action) => action();
''')
        self.write('tools/architecture/semantic_context.dart', '''
Future<T> withSharedAnalysisSummaries<T>(Future<T> Function() action) => action();
''')
        self.aggregate()
        # Release discovers workflow-tooling tests from its separate checkout,
        # while flutter pub get prepares only the current source working tree.
        config = Path.cwd() / '.dart_tool/package_config.json'
        (self.root / '.dart_tool').mkdir()
        shutil.copy2(config, self.root / '.dart_tool/package_config.json')
        for guard in linters.PYTHON_GUARDS:
            self.write(guard, 'from pathlib import Path\n'
                       f'with Path("python-events").open("a") as log: log.write({guard!r} + "\\n")\n')
        sdk = ROOT.parent / '.toolchain/flutter/bin/cache/dart-sdk/bin/dart'
        self.dart = shutil.which('dart') or str(sdk)
        self.assertTrue(Path(self.dart).is_file(), 'Activate the project Dart SDK before running linter process tests.')

    def write(self, name, contents):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        return path

    def aggregate(self, imports='', entries='', real_baseline=False):
        # Only baseline-validation cases load the real parser and its analyzer
        # dependencies; discovery/process controls use a small standalone VM.
        baseline_import = f"import '{(ROOT / 'tools/architecture/cli.dart').as_uri()}' as baseline;" if real_baseline else ''
        read_baseline = 'baseline.readBaseline(args.last);' if real_baseline else 'File(args.last).readAsStringSync();'
        self.write('tools/architecture/cli.dart', f'''
import 'dart:convert';
import 'dart:io';
import 'model.dart';
{baseline_import}
Future<void> run(List<String> args, Map<String, Rule> rules) async {{
  try {{
    if (args.isNotEmpty) {{
      if (args.length != 2 || args.first != '--baseline-reference') {{
        throw FormatException('Invalid aggregate arguments');
      }}
      {read_baseline}
    }}
    File('dart-events').writeAsStringSync(jsonEncode(['architecture', args]) + '\\n', mode: FileMode.append);
    for (final rule in rules.values) {{ await rule(Object()); }}
  }} catch (_) {{
    stderr.writeln('[ARCH_INPUT] Invalid architecture input');
    exitCode = 2;
  }}
}}
''')
        self.write('tools/architecture/check_all.dart', f'''
import 'model.dart';
import 'cli.dart';
{imports}
final allRules = <String, Rule>{{
{entries}
}};
Future<void> main(List<String> args) => run(args, allRules);
''')

    def rule(self, name, failure=0):
        return self.write(f'tools/architecture/rules/{name}.dart', f'''
import 'dart:convert';
import 'dart:io';
const id = '{name}';
Future<void> check(Object snapshot) async {{
  File('dart-events').writeAsStringSync(jsonEncode(['{name}', []]) + '\\n', mode: FileMode.append);
}}
Future<void> main(List<String> args) async {{
  File('dart-events').writeAsStringSync(jsonEncode(['{name}', args]) + '\\n', mode: FileMode.append);
  if ({failure} != 0) {{ stderr.writeln('fixture rule failure: {name}'); exitCode = {failure}; }}
}}
''')

    def run_main(self, *arguments):
        output, error = io.StringIO(), io.StringIO()
        with mock.patch.object(linters, '__file__', str(self.root / 'scripts/check_commit_linters.py')), \
                mock.patch.object(linters.shutil, 'which', return_value=self.dart), \
                mock.patch.object(sys, 'argv', ['check_commit_linters.py', *arguments]), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            result = linters.main()
        return result, output.getvalue(), error.getvalue()

    def events(self):
        return [json.loads(line) for line in (self.root / 'dart-events').read_text().splitlines()]

    def test_rule_discovery_covers_registered_new_and_unregistered_imports(self):
        self.rule('covered')
        self.rule('unregistered')
        self.rule('new_rule')
        self.aggregate("import 'rules/covered.dart' as covered;\n"
                       "import 'rules/unregistered.dart' as unregistered;",
                       '  covered.id: covered.check,')
        driver = self.root / 'driver.dart'
        self.assertEqual(linters.dart_driver(self.root, driver), 3)
        result, output, error = self.run_main('--dart-only')
        self.assertEqual(result, 0, output + error)
        self.assertEqual(self.events(), [['architecture', []], ['covered', []],
                                        ['new_rule', []], ['unregistered', []]])
        self.assertNotIn('rules/covered.dart', driver.read_text())

    def test_commented_registration_does_not_remove_standalone_check(self):
        self.rule('unregistered')
        for comment in ['// unregistered.id: unregistered.check,',
                        '/* outer /* nested */ unregistered.id: unregistered.check, */']:
            with self.subTest(comment=comment):
                self.aggregate("import 'rules/unregistered.dart' as unregistered;", comment)
                self.assertEqual(linters.dart_driver(self.root, self.root / 'driver.dart'), 2)

    def test_unsupported_aggregate_and_rule_entry_points_fail_closed(self):
        self.write('tools/architecture/rules/unsupported.dart', 'Future<int> main(List<String> args) async => 0;')
        result, _, error = self.run_main('--dart-only')
        self.assertEqual(result, 2)
        self.assertIn('unsupported linter entry point', error)
        (self.root / 'tools/architecture/rules/unsupported.dart').unlink()
        self.write('tools/architecture/check_all.dart', 'Future<void> main(List<String> args) async {}')
        result, _, error = self.run_main('--dart-only')
        self.assertEqual(result, 2)
        self.assertIn('aggregate registrations are unsupported', error)

    def test_unused_aggregate_registrations_cannot_exclude_source_rules(self):
        self.rule('covered')
        self.aggregate("import 'rules/covered.dart' as covered;", '  covered.id: covered.check,')
        path = self.root / 'tools/architecture/check_all.dart'
        path.write_text(path.read_text().replace('=> run(args, allRules);', 'async {}'))
        result, _, error = self.run_main('--dart-only')
        self.assertEqual(result, 2)
        self.assertIn('aggregate execution is unsupported', error)
        self.assertFalse((self.root / 'dart-events').exists())

    def test_baseline_reference_is_literal_and_only_forwarded_to_aggregate(self):
        self.rule('ordinary')
        reference = self.write('reference "${notInterpolated}" back\\slash.json', '{"schema":1,"entries":[]}')
        result, output, error = self.run_main('--dart-only', '--baseline-reference', str(reference))
        self.assertEqual(result, 0, output + error)
        self.assertEqual(self.events(), [['architecture', ['--baseline-reference', str(reference)]],
                                        ['ordinary', []]])

    def test_real_dart_failure_keeps_exit_diagnostic_and_stops_later_checks(self):
        self.rule('a_failure', failure=7)
        self.rule('z_later')
        result, output, error = self.run_main()
        self.assertEqual(result, 7)
        self.assertIn('fixture rule failure: a_failure', error)
        self.assertIn('Wing commit lint failed: a_failure', error)
        self.assertEqual(self.events(), [['architecture', []], ['a_failure', []]])
        self.assertFalse((self.root / 'python-events').exists())
        self.assertNotIn('Wing linters passed', output)

    def test_dart_only_avoids_python_native_guards_but_default_retains_them(self):
        result, output, error = self.run_main('--dart-only')
        self.assertEqual(result, 0, output + error)
        self.assertFalse((self.root / 'python-events').exists())
        self.assertIn('0 Python/native checks', output)
        result, output, error = self.run_main()
        self.assertEqual(result, 0, output + error)
        self.assertEqual((self.root / 'python-events').read_text().splitlines(), list(linters.PYTHON_GUARDS))
        self.assertIn(f'{len(linters.PYTHON_GUARDS)} Python/native checks', output)

    def test_default_python_guard_failure_is_preserved(self):
        self.write(linters.PYTHON_GUARDS[0], 'import sys\nprint("census failure", file=sys.stderr)\nsys.exit(9)\n')
        result, output, error = self.run_main()
        self.assertEqual(result, 9)
        self.assertIn('census failure', error)
        self.assertFalse((self.root / 'python-events').exists())
        self.assertNotIn('Wing linters passed', output)

    def test_missing_and_malformed_reference_fail_real_baseline_validation(self):
        self.aggregate(real_baseline=True)
        invalid = self.write('invalid-reference.json', '{"schema":1,"entries":[{"id":"hidden"}]}')
        for reference in [self.root / 'missing-reference.json', invalid]:
            with self.subTest(reference=reference):
                result, output, error = self.run_main('--dart-only', '--baseline-reference', str(reference))
                self.assertEqual(result, 2, output + error)
                self.assertIn('[ARCH_INPUT]', error)
                self.assertNotIn('Wing linters passed', output)
                self.assertFalse((self.root / 'dart-events').exists())

    def test_nonempty_current_baseline_is_rejected_before_any_rule_executes(self):
        self.write('tools/architecture/baseline.json', '{"schema":1,"entries":[{}]}')
        result, _, error = self.run_main('--dart-only')
        self.assertEqual(result, 2)
        self.assertIn('Architecture baseline must remain empty', error)
        self.assertFalse((self.root / 'dart-events').exists())

    def test_external_tooling_uses_prepared_source_package_config(self):
        tooling = self.root / 'external-tooling'
        for name in ['scripts/tests/test_check_commit_linters.py',
                     'scripts/check_commit_linters.py',
                     'tools/architecture/cli.dart', 'tools/architecture/model.dart']:
            destination = tooling / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        self.assertFalse((tooling / '.dart_tool').exists())
        environment = dict(os.environ)
        environment['PATH'] = str(Path(self.dart).parent) + os.pathsep + environment.get('PATH', '')
        result = subprocess.run(
            [sys.executable, str(tooling / 'scripts/tests/test_check_commit_linters.py'),
             'CommitLintersTest.test_missing_and_malformed_reference_fail_real_baseline_validation'],
            cwd=self.root, env=environment, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Ran 1 test', result.stderr)
        self.assertFalse((tooling / '.dart_tool').exists())


if __name__ == '__main__':
    unittest.main()
