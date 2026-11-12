import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/dart_sdk.dart';
import '../tools/architecture/rules/required_quality_gates.dart';

const qaCommand = "python3 -m unittest discover -s tools/qa -p 'test_*.py' -v";
const fixtureDependencyCommand =
    'python3 -m pip install -r tools/fake_gateway/requirements.txt';
const fixtureTransportCommand =
    'python3 -m unittest tools.fake_gateway.test_fixture_boundaries -v';
const sourceCommand = 'python3 scripts/check_commit_linters.py --dart-only';
const boundSourceCommand =
    '$sourceCommand --baseline-reference "build/architecture-baseline-reference.json"';
const changedTestsCommand =
    r'python3 scripts/test.py --changed-since "$TEST_BASE_REF" --skip-linters';
const testBaseRef =
    r'${{ github.event.pull_request.base.sha || github.event.before }}';
const nativeBoundaryCommand =
    'python3 tools/architecture/native_share/provider_boundary.py';
const nativeFixtureCommand =
    'python3 tools/architecture/native_share/prove_boundary.py';
const voiceBoundaryCommand =
    'python3 tools/architecture/native_voice/file_api_boundary.py';
const voicePermissionCommand =
    'python3 tools/architecture/native_voice/permission_lifecycle.py';
const voiceFixtureCommand =
    'python3 tools/architecture/native_voice/prove_boundary.py';
const notificationBoundaryCommand =
    'python3 tools/architecture/native_notification/retired_action.py';
const notificationFixtureCommand =
    'python3 tools/architecture/native_notification/prove_boundary.py';
const notificationDeviceCommand = 'python3 tools/qa/run_notification_gate.py';
const androidJourneyCommand = 'python3 scripts/test_journeys.py';
const declarationBoundaryCommand =
    'python3 tools/architecture/native_notification/retired_declaration.py';
const declarationFixtureCommand =
    'python3 tools/architecture/native_notification/prove_declarations.py';
const allBranchPushTriggers = '''on:
  push:
    branches:
      - '**'
''';
const nativeCommands = [
  androidJourneyCommand,
  notificationBoundaryCommand,
  notificationFixtureCommand,
  declarationBoundaryCommand,
  declarationFixtureCommand,
  nativeBoundaryCommand,
  nativeFixtureCommand,
  voiceBoundaryCommand,
  voicePermissionCommand,
  voiceFixtureCommand,
];

const fixtureCommands = [
  'dart run tools/architecture/tests/workspace_search_owner_test.dart',
  'dart run tools/architecture/tests/profile_discovery_writer_test.dart',
  'dart run tools/architecture/tests/saved_prompt_journal_admission_test.dart',
  'dart run tools/architecture/tests/current_tool_events_test.dart',
  'dart run tools/architecture/tests/activity_density_test.dart',
  'dart run tools/architecture/tests/retired_answer_versions_namespace_test.dart',
];
final independentCommands = [
  fixtureTransportCommand,
  notificationDeviceCommand,
  ...fixtureCommands,
  'python3 tools/architecture/rules/authored_census.py',
  'python3 tools/architecture/rules/native_retired_resources.py',
  'python3 tools/architecture/rules/fixture_model_catalog.py',
  'python3 tools/architecture/rules/retired_fixture_recovery.py',
];

void main() {
  late Directory root;
  late Directory cliDirectory;
  late String cliKernel;
  final sdk = dartSdkPath(Directory.current.path);

  setUpAll(() async {
    cliDirectory = await Directory.systemTemp.createTemp('wing-quality-cli-');
    cliKernel = '${cliDirectory.path}/required_quality_gates.dill';
    final compilation = await Process.run('$sdk/bin/dart', [
      'compile',
      'kernel',
      'tools/architecture/rules/required_quality_gates.dart',
      '-o',
      cliKernel,
    ]);
    expect(
      compilation.exitCode,
      0,
      reason: '${compilation.stdout}${compilation.stderr}',
    );
  });

  tearDownAll(() async => cliDirectory.delete(recursive: true));

  // Compile the current command once, then run its real main in a fresh process
  // for every workflow mutation. The source-launch provider proof below stays
  // independent; only repeated compilation is removed from the remaining cases.
  Future<ProcessResult> runCli() =>
      Process.run('$sdk/bin/dart', [cliKernel, root.path]);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wing-quality-gates-');
    await Directory('${root.path}/.github/workflows').create(recursive: true);
    _writeWorkflows(root);
  });

  tearDown(() async => root.delete(recursive: true));

  test('normal mandatory QA and architecture gates are accepted', () {
    expect(checkRequiredQualityGates(root), isEmpty);
  });

  test('Gradle cache has a main-push writer, not only readers', () {
    final file = File('${root.path}/.github/workflows/pr-quality.yml');
    final original = file.readAsStringSync();
    for (final replacement in [
      'true',
      'false',
      "\${{ github.ref != 'refs/heads/main' }}",
    ]) {
      file.writeAsStringSync(
        original.replaceFirst(gradleCacheReadOnly, replacement),
      );
      expect(
        checkRequiredQualityGates(root),
        contains(contains('gradle-cache-writer')),
        reason: replacement,
      );
    }
    for (final disabled in [
      '        if: false\n',
      '        continue-on-error: true\n',
    ]) {
      file.writeAsStringSync(
        original.replaceFirst('        with:\n', '$disabled        with:\n'),
      );
      expect(
        checkRequiredQualityGates(root),
        contains(contains('gradle-cache-writer')),
      );
    }
    file.writeAsStringSync(
      original.replaceFirst(
        'cache-provider: basic',
        'cache-provider: basic\n          cache-disabled: true',
      ),
    );
    expect(
      checkRequiredQualityGates(root),
      contains(contains('gradle-cache-writer')),
    );
  });

  test('transport fixture tests require their dependency setup first', () {
    final file = File('${root.path}/.github/workflows/pr-quality.yml');
    const setup =
        '      - name: Fixture dependencies\n'
        '        run: $fixtureDependencyCommand\n';
    final original = file.readAsStringSync();
    expect(original, contains(setup));
    file.writeAsStringSync(original.replaceFirst(setup, '') + setup);
    expect(
      checkRequiredQualityGates(root),
      contains(contains('transport-fixture')),
    );
  });

  for (final workflow in ['pr-quality.yml', 'release.yml']) {
    for (final replacement in [
      'echo Android journeys skipped',
      '$androidJourneyCommand || true',
      'echo "$androidJourneyCommand"',
    ]) {
      test(
        '$workflow rejects substituted Android journey gate: $replacement',
        () async {
          final file = File('${root.path}/.github/workflows/$workflow');
          file.writeAsStringSync(
            file.readAsStringSync().replaceFirst(
              'run: $androidJourneyCommand',
              'run: $replacement',
            ),
          );
          final result = await runCli();
          expect(result.exitCode, 1);
          expect(result.stderr, contains('android-journeys'));
        },
      );
    }
  }

  test(
    'real notification shade gate cannot be omitted or soft-failed',
    () async {
      for (final workflow in ['pr-quality.yml', 'release.yml']) {
        for (final replacement in [
          'echo notification checks skipped',
          '$notificationDeviceCommand || true',
          'echo "$notificationDeviceCommand"',
        ]) {
          _writeWorkflows(root);
          final file = File('${root.path}/.github/workflows/$workflow');
          file.writeAsStringSync(
            file.readAsStringSync().replaceFirst(
              'run: $notificationDeviceCommand',
              'run: $replacement',
            ),
          );
          final result = await runCli();
          expect(result.exitCode, 1, reason: '$workflow: $replacement');
          expect(result.stderr, contains('notification-device'));
        }
      }
    },
  );

  test('PR quality must run on pushes to every branch without filters', () {
    for (final triggers in [
      '''on:
  push:
    branches:
      - main
''',
      '''on:
  pull_request:
''',
      '''on:
  push:
    paths:
      - lib/**
''',
      '''on:
  push:
    paths-ignore:
      - docs/**
''',
      '''on:
  push:
    branches:
      - '**'
      - '!main'
''',
      '''on:
  push:
    branches-ignore:
      - main
''',
      '''on:
  push:
    branches:
      - '*'
''',
    ]) {
      _writeWorkflows(root, prTriggers: triggers);
      expect(
        checkRequiredQualityGates(root),
        contains(contains('pr-quality.yml:on:push REQUIRED_QUALITY_GATE:')),
        reason: triggers,
      );
    }

    _writeWorkflows(root, prTriggers: allBranchPushTriggers);
    expect(checkRequiredQualityGates(root), isEmpty);
  });

  test('each independent production guard is mandatory and hard-failing', () {
    for (final command in independentCommands) {
      for (final invalid in [
        'echo "$command"',
        '$command || true',
        'echo fixture-only',
      ]) {
        _writeWorkflows(root);
        final workflow = fixtureCommands.contains(command)
            ? 'release.yml'
            : 'pr-quality.yml';
        final file = File('${root.path}/.github/workflows/$workflow');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(
            'run: $command',
            'run: $invalid',
          ),
        );
        expect(checkRequiredQualityGates(root), hasLength(1));
      }
      for (final prefix in ['continue-on-error: true', 'if: false']) {
        _writeWorkflows(root);
        final file = File('${root.path}/.github/workflows/release.yml');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(
            'run: $command',
            '$prefix\n        run: $command',
          ),
        );
        expect(checkRequiredQualityGates(root), hasLength(1));
      }
    }
  });

  test(
    'consolidated source checks cannot be omitted or replaced by fixtures',
    () async {
      for (final workflow in ['pr-quality.yml', 'release.yml']) {
        final command = workflow == 'pr-quality.yml'
            ? boundSourceCommand
            : sourceCommand;
        for (final replacement in [
          'echo omitted source checks',
          'dart run tools/architecture/tests/provider_view_protocol_test.dart',
          '$command || true',
          'echo "$command"',
        ]) {
          _writeWorkflows(root);
          final file = File('${root.path}/.github/workflows/$workflow');
          file.writeAsStringSync(
            file.readAsStringSync().replaceFirst(
              'run: $command',
              'run: $replacement',
            ),
          );
          final invalid = await runCli();
          expect(invalid.exitCode, 1);
          expect(invalid.stderr, contains('source-contracts'));
          expect(invalid.stderr, contains(workflow));
        }
        _writeWorkflows(root);
        final valid = await runCli();
        expect(valid.exitCode, 0, reason: '${valid.stdout}\n${valid.stderr}');
      }
      // Keep literal source launches as independent acceptance/failure controls.
      _writeWorkflows(root);
      final sourceValid = await Process.run('$sdk/bin/dart', [
        'run',
        'tools/architecture/rules/required_quality_gates.dart',
        root.path,
      ]);
      expect(sourceValid.exitCode, 0);
      final file = File('${root.path}/.github/workflows/pr-quality.yml');
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
          'run: $boundSourceCommand',
          'run: echo omitted source checks',
        ),
      );
      final sourceInvalid = await Process.run('$sdk/bin/dart', [
        'run',
        'tools/architecture/rules/required_quality_gates.dart',
        root.path,
      ]);
      expect(sourceInvalid.exitCode, 1);
      expect(sourceInvalid.stderr, contains('source-contracts'));
    },
  );

  test('PR source checks require the preceding baseline and Dart-only scope', () {
    final file = File('${root.path}/.github/workflows/pr-quality.yml');
    for (final replacement in [
      sourceCommand,
      '$sourceCommand --baseline-reference "elsewhere.json"',
      'python3 scripts/check_commit_linters.py --baseline-reference "build/architecture-baseline-reference.json"',
      'continue-on-error: true\n        run: $boundSourceCommand',
      'if: false\n        run: $boundSourceCommand',
    ]) {
      _writeWorkflows(root);
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
          'run: $boundSourceCommand',
          replacement.startsWith('continue') || replacement.startsWith('if:')
              ? replacement
              : 'run: $replacement',
        ),
      );
      expect(
        checkRequiredQualityGates(root),
        contains(contains('source-contracts')),
      );
    }
  });

  test('external CI linters must precede the host tests', () {
    final file = File('${root.path}/.github/workflows/pr-quality.yml');
    const step =
        '      - name: Source contracts\n        run: $boundSourceCommand\n';
    final original = file.readAsStringSync();
    expect(original, contains(step));
    file.writeAsStringSync(original.replaceFirst(step, '') + step);
    expect(checkRequiredQualityGates(root), contains(contains('host-tests')));
  });

  test(
    'the shared linter runner proofs remain mandatory in both workflows',
    () {
      for (final workflow in ['pr-quality.yml', 'release.yml']) {
        final command = workflow == 'pr-quality.yml'
            ? 'python3 -m unittest discover -s scripts/tests -v'
            : r'python3 -m unittest discover -s "$RELEASE_TOOLS/tests" -v';
        for (final prefix in ['', 'continue-on-error: true', 'if: false']) {
          _writeWorkflows(root);
          final file = File('${root.path}/.github/workflows/$workflow');
          file.writeAsStringSync(
            file.readAsStringSync().replaceFirst(
              'run: $command',
              prefix.isEmpty
                  ? 'run: echo omitted runner proofs'
                  : '$prefix\n        run: $command',
            ),
          );
          expect(
            checkRequiredQualityGates(root),
            contains(contains('linter-runner-tests')),
          );
        }
      }
    },
  );

  test('both native commands must be real hard-failing steps', () {
    for (final command in nativeCommands) {
      for (final invalid in ['echo "$command"', '$command || true']) {
        _writeWorkflows(root);
        for (final name in ['pr-quality.yml', 'release.yml']) {
          final file = File('${root.path}/.github/workflows/$name');
          file.writeAsStringSync(
            file.readAsStringSync().replaceFirst(
              'run: $command',
              'run: $invalid',
            ),
          );
        }
        expect(checkRequiredQualityGates(root), hasLength(2));
      }
    }
  });

  test('native steps cannot be softened or conditionally omitted', () {
    for (final command in nativeCommands) {
      for (final prefix in ['continue-on-error: true', 'if: false']) {
        _writeWorkflows(root);
        final file = File('${root.path}/.github/workflows/pr-quality.yml');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(
            'run: $command',
            '$prefix\n        run: $command',
          ),
        );
        expect(checkRequiredQualityGates(root), hasLength(1));
      }
    }
  });

  test('native guards follow cache-ready Gradle setup', () {
    _writeWorkflows(root, nativeSetup: false);
    expect(
      checkRequiredQualityGates(root),
      hasLength(nativeCommands.length * 2),
    );
    _writeWorkflows(root, nativeSetup: true);
    final file = File('${root.path}/.github/workflows/pr-quality.yml');
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(
        'run: ./android/gradlew -p android :app:testDebugUnitTest --no-daemon',
        'if: false\n        run: ./android/gradlew -p android :app:testDebugUnitTest --no-daemon',
      ),
    );
    expect(checkRequiredQualityGates(root), hasLength(nativeCommands.length));
    _writeWorkflows(root);
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst(
        'run: ./android/gradlew -p android :app:testDebugUnitTest --no-daemon',
        'continue-on-error: true\n        run: ./android/gradlew -p android :app:testDebugUnitTest --no-daemon',
      ),
    );
    expect(checkRequiredQualityGates(root), hasLength(nativeCommands.length));
    _writeWorkflows(root);
    final contents = file.readAsStringSync();
    const setup =
        '      - name: Native dependency setup\n'
        '        run: ./android/gradlew -p android :app:testDebugUnitTest --no-daemon\n';
    file.writeAsStringSync(contents.replaceFirst(setup, '') + setup);
    expect(checkRequiredQualityGates(root), hasLength(nativeCommands.length));
  });

  test('PR test selection is hard-failing and bound to the event base', () {
    final file = File('${root.path}/.github/workflows/pr-quality.yml');
    for (final mutation in [
      (changedTestsCommand, 'python3 scripts/test.py'),
      (changedTestsCommand, '$changedTestsCommand || true'),
      (
        'run: $changedTestsCommand',
        'continue-on-error: true\n        run: $changedTestsCommand',
      ),
      (
        'run: $changedTestsCommand',
        'if: false\n        run: $changedTestsCommand',
      ),
      ('TEST_BASE_REF: $testBaseRef', 'TEST_BASE_REF: HEAD'),
      ('TEST_BASE_REF:', 'IGNORED_BASE_REF:'),
    ]) {
      _writeWorkflows(root);
      final source = file.readAsStringSync();
      expect(source, contains(mutation.$1));
      file.writeAsStringSync(source.replaceFirst(mutation.$1, mutation.$2));
      expect(
        checkRequiredQualityGates(root),
        contains(contains('pr-quality.yml:quality:host-tests')),
      );
    }
  });

  test('release always retains complete hard-failing test coverage', () {
    final file = File('${root.path}/.github/workflows/release.yml');
    for (final replacement in [
      'run: python3 scripts/test.py',
      'run: echo "python3 scripts/test.py --full"',
      'run: python3 scripts/test.py --full || true',
      'continue-on-error: true\n        run: python3 scripts/test.py --full',
      'if: false\n        run: python3 scripts/test.py --full',
    ]) {
      _writeWorkflows(root);
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
          'run: python3 scripts/test.py --full',
          replacement,
        ),
      );
      expect(
        checkRequiredQualityGates(root),
        contains(contains('release.yml:build:host-tests')),
      );
    }
  });

  test('nightly and manual exhaustive execution cannot be removed', () {
    final file = File('${root.path}/.github/workflows/nightly-tests.yml');
    for (final mutation in [
      ("cron: '0 19 * * *'", "cron: '0 19 * * 0'"),
      ('schedule:', 'ignored_schedule:'),
      ('workflow_dispatch:', 'ignored_dispatch:'),
      ('  exhaustive:', '  exhaustive:\n    if: false'),
      ('  exhaustive:', '  exhaustive:\n    continue-on-error: true'),
      ('run: python3 scripts/test.py --full', 'run: python3 scripts/test.py'),
      (
        'run: python3 scripts/test.py --full',
        'run: python3 scripts/test.py --full || true',
      ),
      (
        'run: python3 scripts/test.py --full',
        'continue-on-error: true\n        run: python3 scripts/test.py --full',
      ),
      (
        'run: python3 scripts/test.py --full',
        'if: false\n        run: python3 scripts/test.py --full',
      ),
      ('run: flutter pub get', 'run: echo dependencies'),
      ('run: flutter pub get', 'if: false\n        run: flutter pub get'),
      (
        'run: flutter pub get',
        'continue-on-error: true\n        run: flutter pub get',
      ),
    ]) {
      _writeWorkflows(root);
      final source = file.readAsStringSync();
      expect(source, contains(mutation.$1));
      file.writeAsStringSync(source.replaceFirst(mutation.$1, mutation.$2));
      expect(
        checkRequiredQualityGates(root),
        contains(contains('nightly-tests.yml')),
      );
    }
  });

  test(
    'nightly cannot omit, filter or soft-fail native and tooling families',
    () {
      final file = File('${root.path}/.github/workflows/nightly-tests.yml');
      for (final mutation in [
        ('  catalog:', '  catalog:\n    if: false'),
        ('  native:', '  native:\n    continue-on-error: true'),
        ('fail-fast: false', 'fail-fast: true'),
        (r'${{ fromJSON(needs.catalog.outputs.families) }}', '[backup]'),
        ('--matrix', '--matrix || true'),
        (
          r'echo "$ANDROID_HOME/platform-tools" >> "$GITHUB_PATH"',
          'echo omitted Android tools',
        ),
        (r'NIGHTLY_FAMILY: ${{ matrix.family }}', 'NIGHTLY_FAMILY: backup'),
        ("python-version: '3.14'", "python-version: '3.12'"),
        ('actions/setup-python@', 'actions/unused@'),
        (
          'python3 -m pm.build_env --source . --out .venv --extra web',
          'python3 -m pip install -e ".[web]"',
        ),
        ('--out .venv --extra web', '--out .venv --extra web || true'),
        ("if: matrix.family == 'stock-hermes'", 'if: false'),
        ('  platform:', '  platform:\n    if: false'),
        ('  renderer:', '  renderer:\n    continue-on-error: true'),
        ('scripts/tests -v', 'scripts/tests -v || true'),
        ('prove_declarations.py', 'prove_declarations.py || true'),
      ]) {
        _writeWorkflows(root);
        final source = file.readAsStringSync();
        expect(source, contains(mutation.$1));
        file.writeAsStringSync(source.replaceFirst(mutation.$1, mutation.$2));
        expect(
          checkRequiredQualityGates(root),
          contains(contains('nightly-tests.yml')),
          reason: mutation.$2,
        );
      }
    },
  );

  test('standalone checker fixtures remain enforced nightly', () {
    final file = File('${root.path}/.github/workflows/nightly-tests.yml');
    for (final command in fixtureCommands) {
      _writeWorkflows(root);
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
          'run: $command',
          'run: echo missing',
        ),
      );
      expect(checkRequiredQualityGates(root), hasLength(1));
    }
  });

  test('nightly external source checking cannot be omitted or softened', () {
    final file = File('${root.path}/.github/workflows/nightly-tests.yml');
    for (final replacement in [
      'run: echo source checks',
      'run: python3 scripts/check_commit_linters.py --dart-only || true',
      'if: false\n        run: python3 scripts/check_commit_linters.py --dart-only',
      'continue-on-error: true\n        run: python3 scripts/check_commit_linters.py --dart-only',
    ]) {
      _writeWorkflows(root);
      expect(checkRequiredQualityGates(root), isEmpty);
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
          'run: python3 scripts/check_commit_linters.py --dart-only',
          replacement,
        ),
      );
      expect(
        checkRequiredQualityGates(root),
        contains(contains('nightly-tests.yml')),
      );
    }
  });

  test('nightly dependencies must precede the complete suite', () {
    final file = File('${root.path}/.github/workflows/nightly-tests.yml');
    const setup = '      - name: Dependencies\n        run: flutter pub get\n';
    final contents = file.readAsStringSync();
    expect(contents, contains(setup));
    file.writeAsStringSync(contents.replaceFirst(setup, '') + setup);
    final failures = checkRequiredQualityGates(root);
    for (final command in [
      sourceCommand,
      'python3 scripts/test.py --full --skip-linters',
      ...fixtureCommands,
    ]) {
      expect(
        failures,
        contains(allOf(contains(command), contains('after dependencies'))),
      );
    }
  });

  test('nightly source checks must precede externally checked host tests', () {
    final file = File('${root.path}/.github/workflows/nightly-tests.yml');
    const source =
        '      - name: Current source\n'
        '        run: python3 scripts/check_commit_linters.py --dart-only\n';
    final contents = file.readAsStringSync();
    expect(contents, contains(source));
    file.writeAsStringSync(contents.replaceFirst(source, '') + source);
    expect(
      checkRequiredQualityGates(root),
      contains(contains('Run python3 scripts/test.py --full --skip-linters')),
    );
  });

  test('missing and malformed nightly workflows fail closed', () {
    final file = File('${root.path}/.github/workflows/nightly-tests.yml');
    file.deleteSync();
    expect(
      checkRequiredQualityGates(root),
      contains(contains('nightly-tests.yml QUALITY_WORKFLOW_INPUT:')),
    );
    file.writeAsStringSync('[[');
    expect(
      checkRequiredQualityGates(root),
      contains(contains('nightly-tests.yml QUALITY_WORKFLOW_INPUT:')),
    );
  });

  test('a command in a comment or echo cannot stand in for a gate', () {
    _writeWorkflows(root, qa: '# $qaCommand\n          echo "$qaCommand"');
    expect(
      checkRequiredQualityGates(root),
      contains(contains('REQUIRED_QUALITY_GATE:')),
    );
  });

  test('a soft failure cannot protect quality', () {
    _writeWorkflows(root, softFailure: true);
    expect(
      checkRequiredQualityGates(root),
      contains(contains('REQUIRED_QUALITY_GATE:')),
    );
  });

  test('a conditionally skipped gate is not mandatory', () {
    _writeWorkflows(root, conditional: true);
    expect(
      checkRequiredQualityGates(root),
      contains(contains('REQUIRED_QUALITY_GATE:')),
    );
  });

  test('a skipped job cannot hide otherwise mandatory steps', () {
    _writeWorkflows(root, jobCondition: 'false');
    expect(
      checkRequiredQualityGates(root),
      contains(contains('REQUIRED_QUALITY_GATE:')),
    );
  });

  test('release checks accept their explicit main and push scope', () {
    _writeWorkflows(root);
    final release = File('${root.path}/.github/workflows/release.yml');
    release.writeAsStringSync(
      release.readAsStringSync().replaceFirst(
        '  build:',
        "  build:\n    if: github.event_name == 'push' || github.ref == 'refs/heads/main'",
      ),
    );
    expect(checkRequiredQualityGates(root), isEmpty);
  });

  test('a later shell success does not hide a failed command', () {
    _writeWorkflows(root, qa: '$qaCommand || true');
    expect(
      checkRequiredQualityGates(root),
      contains(contains('REQUIRED_QUALITY_GATE:')),
    );
  });

  test('an unreachable command cannot stand in for a gate', () {
    _writeWorkflows(root, qa: 'exit 0\n          $qaCommand');
    expect(
      checkRequiredQualityGates(root),
      contains(contains('REQUIRED_QUALITY_GATE:')),
    );
  });

  test('missing and malformed workflows fail closed', () {
    File('${root.path}/.github/workflows/pr-quality.yml').deleteSync();
    expect(
      checkRequiredQualityGates(root),
      contains(contains('QUALITY_WORKFLOW_INPUT:')),
    );
    File(
      '${root.path}/.github/workflows/pr-quality.yml',
    ).writeAsStringSync('[[');
    expect(
      checkRequiredQualityGates(root),
      contains(contains('QUALITY_WORKFLOW_INPUT:')),
    );
  });

  test(
    'individual CLI rejects missing gate and accepts repaired workflow',
    () async {
      _writeWorkflows(root, qa: 'echo missing');
      final invalid = await runCli();
      expect(invalid.exitCode, 1);
      expect(invalid.stderr, contains('REQUIRED_QUALITY_GATE:'));
      _writeWorkflows(root);
      final valid = await runCli();
      expect(valid.exitCode, 0);
      expect(valid.stderr, isNot(contains('REQUIRED_QUALITY_GATE:')));
      expect(valid.stderr, isNot(contains('QUALITY_WORKFLOW_INPUT:')));
      for (final command in [nativeBoundaryCommand, nativeFixtureCommand]) {
        _writeWorkflows(root);
        final file = File('${root.path}/.github/workflows/pr-quality.yml');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(
            'run: $command',
            'run: echo missing',
          ),
        );
        final omittedNative = await runCli();
        expect(omittedNative.exitCode, 1);
        expect(omittedNative.stderr, contains('native-share-'));
      }
    },
  );
}

const gradleCacheReadOnly =
    r"${{ github.event_name != 'push' || github.ref != 'refs/heads/main' }}";

void _writeWorkflows(
  Directory root, {
  String qa = qaCommand,
  String prTriggers = allBranchPushTriggers,
  bool softFailure = false,
  bool conditional = false,
  String? jobCondition,
  bool nativeSetup = true,
}) {
  for (final item in [
    ('pr-quality.yml', 'quality'),
    ('release.yml', 'build'),
  ]) {
    File('${root.path}/.github/workflows/${item.$1}').writeAsStringSync('''
${item.$1 == 'pr-quality.yml' ? prTriggers : ''}
jobs:
  ${item.$2}:
    ${jobCondition == null ? '# mandatory job' : 'if: $jobCondition'}
    steps:
${item.$1 == 'pr-quality.yml' ? '''      - uses: gradle/actions/setup-gradle@3f5f9adaf7d9fecd50b5935e54106014257a94e6
        with:
          cache-provider: basic
          cache-read-only: $gradleCacheReadOnly
''' : ''}
      - name: Linter runner proofs
        run: ${item.$1 == 'pr-quality.yml' ? 'python3 -m unittest discover -s scripts/tests -v' : r'python3 -m unittest discover -s "$RELEASE_TOOLS/tests" -v'}
      - name: Offline QA
        ${softFailure ? 'continue-on-error: true' : '# mandatory'}
        ${conditional ? "if: github.ref == 'refs/heads/example'" : '# unconditional'}
        run: |
          $qa
      - name: Source contracts
        run: ${item.$1 == 'pr-quality.yml' ? boundSourceCommand : sourceCommand}
      - name: Fixture dependencies
        run: $fixtureDependencyCommand
${independentCommands.where((command) => item.$1 == 'release.yml' || !fixtureCommands.contains(command) || command.contains('workspace_search_owner_test.dart')).map((command) => '      - name: Independent production guard\n        run: $command').join('\n')}
      - name: Host tests
        ${item.$1 == 'pr-quality.yml' ? 'env:\n          TEST_BASE_REF: $testBaseRef' : '# exhaustive release'}
        run: ${item.$1 == 'pr-quality.yml' ? changedTestsCommand : 'python3 scripts/test.py --full --skip-linters'}
      ${nativeSetup ? '- name: Native dependency setup\n        run: ./android/gradlew -p android :app:testDebugUnitTest --no-daemon' : '# no dependency setup'}
${nativeCommands.map((command) => '      - name: Native guard\n        run: $command').join('\n')}
''');
  }
  File('${root.path}/.github/workflows/nightly-tests.yml').writeAsStringSync('''
on:
  schedule:
    - cron: '0 19 * * *'
  workflow_dispatch:
jobs:
  exhaustive:
    steps:
      - name: Dependencies
        run: flutter pub get
      - run: python3 -m unittest discover -s scripts/tests -v
      - run: python3 -m unittest discover -s tools/qa -p 'test_*.py' -v
      - run: python3 -m pip install -r tools/fake_gateway/requirements.txt
      - run: python3 -m unittest tools.fake_gateway.test_fixture_boundaries -v
      - name: Current source
        run: python3 scripts/check_commit_linters.py --dart-only
      - name: Exhaustive tests
        run: python3 scripts/test.py --full --skip-linters
${fixtureCommands.map((command) => '      - name: Proof fixtures\n        run: $command').join('\n')}
  catalog:
    outputs:
      families: \${{ steps.catalog.outputs.families }}
    steps:
      - id: catalog
        run: python3 scripts/test_nightly_native.py --matrix
  native:
    needs: catalog
    strategy:
      fail-fast: false
      matrix:
        family: \${{ fromJSON(needs.catalog.outputs.families) }}
    steps:
      - run: echo "\$ANDROID_HOME/platform-tools" >> "\$GITHUB_PATH"
      - uses: actions/setup-python@e797f83bcb11b83ae66e0230d6156d7c80228e7c
        if: matrix.family == 'stock-hermes'
        with:
          python-version: '3.14'
      - run: python3 -m pm.build_env --source . --out .venv --extra web
      - env:
          NIGHTLY_FAMILY: \${{ matrix.family }}
        run: python3 scripts/test_nightly_native.py "\$NIGHTLY_FAMILY" --hermes-source "\$RUNNER_TEMP/hermes"
  platform:
    steps:
      - run: ./android/gradlew -p android :app:testDebugUnitTest --no-daemon
      - run: python3 scripts/check_commit_linters.py
      - run: python3 tools/architecture/native_share/prove_boundary.py
      - run: python3 tools/architecture/native_notification/prove_boundary.py
      - run: python3 tools/architecture/native_notification/prove_declarations.py
      - run: python3 tools/architecture/native_voice/prove_boundary.py
  renderer:
    steps:
      - uses: ./.github/actions/test-diagram-preview
''');
}
