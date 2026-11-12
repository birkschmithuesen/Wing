import 'dart:io';

import 'package:yaml/yaml.dart';

const _qaCommand = "python3 -m unittest discover -s tools/qa -p 'test_*.py' -v";
const _fixtureDependencyCommand =
    'python3 -m pip install -r tools/fake_gateway/requirements.txt';
const _fixtureTransportCommand =
    'python3 -m unittest tools.fake_gateway.test_fixture_boundaries -v';
const _sourceCommand = 'python3 scripts/check_commit_linters.py --dart-only';
const _boundSourceCommand =
    '$_sourceCommand --baseline-reference "build/architecture-baseline-reference.json"';
const _changedTestsCommand =
    r'python3 scripts/test.py --changed-since "$TEST_BASE_REF" --skip-linters';
const _fullTestsCommand = 'python3 scripts/test.py --full --skip-linters';
const _testBaseRef =
    r'${{ github.event.pull_request.base.sha || github.event.before }}';
const _fixtureNames = [
  'workspace_search_owner',
  'profile_discovery_writer',
  'saved_prompt_journal_admission',
  'retired_answer_versions_namespace',
  'current_tool_events',
  'activity_density',
];

const _nativeBoundaryCommand =
    'python3 tools/architecture/native_share/provider_boundary.py';
const _nativeFixtureCommand =
    'python3 tools/architecture/native_share/prove_boundary.py';
const _voiceBoundaryCommand =
    'python3 tools/architecture/native_voice/file_api_boundary.py';
const _voicePermissionCommand =
    'python3 tools/architecture/native_voice/permission_lifecycle.py';
const _voiceFixtureCommand =
    'python3 tools/architecture/native_voice/prove_boundary.py';

const _notificationBoundaryCommand =
    'python3 tools/architecture/native_notification/retired_action.py';
const _notificationFixtureCommand =
    'python3 tools/architecture/native_notification/prove_boundary.py';
const _notificationDeviceCommand = 'python3 tools/qa/run_notification_gate.py';
const _androidJourneyCommand = 'python3 scripts/test_journeys.py';
const _declarationBoundaryCommand =
    'python3 tools/architecture/native_notification/retired_declaration.py';
const _declarationFixtureCommand =
    'python3 tools/architecture/native_notification/prove_declarations.py';

/// Protect mandatory gates in their actual workflow/job structure.
/// Commands must be plain single shell commands: comments, echo, soft-failing
/// steps and shell failure-swallowing suffixes cannot satisfy this contract.
List<String> checkRequiredQualityGates(Directory root) {
  final failures = <String>[];
  for (final target in [
    ('.github/workflows/pr-quality.yml', 'quality'),
    ('.github/workflows/release.yml', 'build'),
  ]) {
    try {
      final document = loadYaml(
        File('${root.path}/${target.$1}').readAsStringSync(),
      );
      if (document is! Map || document['jobs'] is! Map) {
        throw const FormatException('Expected workflow jobs.');
      }
      if (target.$2 == 'quality' && !_allBranchPushes(document['on'])) {
        failures.add(
          '${target.$1}:on:push REQUIRED_QUALITY_GATE: '
          'Run quality checks on pushes to every branch without path filters.',
        );
      }
      final job = (document['jobs'] as Map)[target.$2];
      if (job is! Map || job['steps'] is! List) {
        throw FormatException('Expected job ${target.$2} with steps.');
      }
      final steps = (job['steps'] as List).whereType<Map>().toList();
      if (target.$2 == 'quality' && !steps.any(_mainGradleCacheWriter)) {
        failures.add(
          '${target.$1}:quality:gradle-cache-writer REQUIRED_QUALITY_GATE: '
          'Publish the basic Gradle cache on main pushes; keep other events read-only.',
        );
      }
      for (final gate in [
        ('offline-qa', _qaCommand),
        ('transport-fixture', _fixtureTransportCommand),
        (
          'linter-runner-tests',
          target.$2 == 'quality'
              ? 'python3 -m unittest discover -s scripts/tests -v'
              : r'python3 -m unittest discover -s "$RELEASE_TOOLS/tests" -v',
        ),
        (
          'source-contracts',
          target.$2 == 'quality' ? _boundSourceCommand : _sourceCommand,
        ),
        (
          'authored-census',
          'python3 tools/architecture/rules/authored_census.py',
        ),
        (
          'native-retired-resources',
          'python3 tools/architecture/rules/native_retired_resources.py',
        ),
        (
          'fixture-model-catalog',
          'python3 tools/architecture/rules/fixture_model_catalog.py',
        ),
        (
          'retired-fixture-recovery',
          'python3 tools/architecture/rules/retired_fixture_recovery.py',
        ),
        for (final name in _fixtureNames)
          if (target.$2 == 'build' || name == 'workspace_search_owner')
            (
              'fixture-$name',
              'dart run tools/architecture/tests/${name}_test.dart',
            ),
        (
          'host-tests',
          target.$2 == 'quality' ? _changedTestsCommand : _fullTestsCommand,
        ),
        ('native-share-boundary', _nativeBoundaryCommand),
        ('native-share-fixtures', _nativeFixtureCommand),
        ('native-notification-action', _notificationBoundaryCommand),
        ('native-notification-fixtures', _notificationFixtureCommand),
        ('notification-device', _notificationDeviceCommand),
        ('android-journeys', _androidJourneyCommand),
        ('native-retired-declarations', _declarationBoundaryCommand),
        ('native-retired-declaration-fixtures', _declarationFixtureCommand),
        ('native-voice-boundary', _voiceBoundaryCommand),
        ('native-voice-permission-lifecycle', _voicePermissionCommand),
        ('native-voice-fixtures', _voiceFixtureCommand),
      ]) {
        final native =
            gate.$2 == _androidJourneyCommand ||
            gate.$2 == _nativeBoundaryCommand ||
            gate.$2 == _nativeFixtureCommand ||
            gate.$2 == _notificationBoundaryCommand ||
            gate.$2 == _notificationFixtureCommand ||
            gate.$2 == _declarationBoundaryCommand ||
            gate.$2 == _declarationFixtureCommand ||
            gate.$2 == _voiceBoundaryCommand ||
            gate.$2 == _voicePermissionCommand ||
            gate.$2 == _voiceFixtureCommand;
        final protected =
            _hardFailure(job['continue-on-error']) &&
            _mandatoryJob(job['if'], target.$2) &&
            steps.indexed.any(
              (entry) =>
                  _hardFailure(entry.$2['continue-on-error']) &&
                  _mandatory(entry.$2['if']) &&
                  _runsFinalCommand(entry.$2['run'], gate.$2) &&
                  (gate.$2 != _fixtureTransportCommand ||
                      steps
                          .take(entry.$1)
                          .any(
                            (setup) =>
                                _hardFailure(setup['continue-on-error']) &&
                                _mandatory(setup['if']) &&
                                _runsFinalCommand(
                                  setup['run'],
                                  _fixtureDependencyCommand,
                                ),
                          )) &&
                  (gate.$2 != _changedTestsCommand ||
                      (_boundTestBase(entry.$2['env']) &&
                          steps
                              .take(entry.$1)
                              .any(
                                (setup) =>
                                    _hardFailure(setup['continue-on-error']) &&
                                    _mandatory(setup['if']) &&
                                    _runsFinalCommand(
                                      setup['run'],
                                      _boundSourceCommand,
                                    ),
                              ))) &&
                  (!native || steps.take(entry.$1).any(_nativeToolingReady)),
            );
        if (!protected) {
          failures.add(
            '${target.$1}:${target.$2}:${gate.$1} REQUIRED_QUALITY_GATE: '
            'Run ${gate.$2} as a mandatory hard-failing step'
            '${native ? ' after native Gradle dependency setup' : ''}.',
          );
        }
      }
    } on FileSystemException catch (error) {
      failures.add('${target.$1} QUALITY_WORKFLOW_INPUT: ${error.message}');
    } on YamlException catch (error) {
      failures.add('${target.$1} QUALITY_WORKFLOW_INPUT: ${error.message}');
    } on FormatException catch (error) {
      failures.add('${target.$1} QUALITY_WORKFLOW_INPUT: ${error.message}');
    }
  }
  failures.addAll(_checkNightly(root));
  return failures..sort();
}

bool _boundTestBase(Object? environment) =>
    environment is Map && environment['TEST_BASE_REF'] == _testBaseRef;

bool _mainGradleCacheWriter(Map step) {
  final inputs = step['with'];
  return step['uses'] is String &&
      (step['uses'] as String).startsWith('gradle/actions/setup-gradle@') &&
      _mandatory(step['if']) &&
      _hardFailure(step['continue-on-error']) &&
      inputs is Map &&
      inputs['cache-provider'] == 'basic' &&
      _hardFailure(inputs['cache-disabled']) &&
      inputs['cache-read-only'] ==
          r"${{ github.event_name != 'push' || github.ref != 'refs/heads/main' }}";
}

List<String> _checkNightly(Directory root) {
  const path = '.github/workflows/nightly-tests.yml';
  final failures = <String>[];
  try {
    final document = loadYaml(File('${root.path}/$path').readAsStringSync());
    if (document is! Map || document['jobs'] is! Map) {
      throw const FormatException('Expected workflow jobs.');
    }
    final events = document['on'];
    final schedules = events is Map ? events['schedule'] : null;
    if (schedules is! List ||
        !schedules.any(
          (entry) => entry is Map && entry['cron'] == '0 19 * * *',
        ) ||
        events is! Map ||
        !events.containsKey('workflow_dispatch')) {
      failures.add(
        '$path:on REQUIRED_QUALITY_GATE: '
        'Run exhaustive proofs nightly and support manual verification.',
      );
    }
    final job = (document['jobs'] as Map)['exhaustive'];
    if (job is! Map || job['steps'] is! List) {
      throw const FormatException('Expected exhaustive job with steps.');
    }
    final steps = (job['steps'] as List).whereType<Map>().toList();
    for (final command in [
      _sourceCommand,
      _fullTestsCommand,
      'python3 -m unittest discover -s scripts/tests -v',
      _qaCommand,
      _fixtureDependencyCommand,
      _fixtureTransportCommand,
      for (final name in _fixtureNames)
        'dart run tools/architecture/tests/${name}_test.dart',
    ]) {
      final protected =
          _hardFailure(job['continue-on-error']) &&
          _mandatory(job['if']) &&
          steps.indexed.any(
            (entry) =>
                _hardFailure(entry.$2['continue-on-error']) &&
                _mandatory(entry.$2['if']) &&
                _runsFinalCommand(entry.$2['run'], command) &&
                (command != _fullTestsCommand ||
                    steps
                        .take(entry.$1)
                        .any(
                          (setup) =>
                              _hardFailure(setup['continue-on-error']) &&
                              _mandatory(setup['if']) &&
                              _runsFinalCommand(setup['run'], _sourceCommand),
                        )) &&
                steps
                    .take(entry.$1)
                    .any(
                      (setup) =>
                          _hardFailure(setup['continue-on-error']) &&
                          _mandatory(setup['if']) &&
                          _runsFinalCommand(setup['run'], 'flutter pub get'),
                    ),
          );
      if (!protected) {
        failures.add(
          '$path:exhaustive REQUIRED_QUALITY_GATE: '
          'Run $command as a mandatory hard-failing step after dependencies.',
        );
      }
    }
    final jobs = document['jobs'] as Map;
    bool hardCommand(String name, String command) {
      final value = jobs[name];
      return value is Map &&
          _hardFailure(value['continue-on-error']) &&
          _mandatory(value['if']) &&
          value['steps'] is List &&
          (value['steps'] as List).whereType<Map>().any(
            (step) =>
                _hardFailure(step['continue-on-error']) &&
                _mandatory(step['if']) &&
                _runsFinalCommand(step['run'], command),
          );
    }

    final catalog = jobs['catalog'];
    final native = jobs['native'];
    const matrixCommand = 'python3 scripts/test_nightly_native.py --matrix';
    const nativeCommand =
        r'python3 scripts/test_nightly_native.py "$NIGHTLY_FAMILY" --hermes-source "$RUNNER_TEMP/hermes"';
    final strategy = native is Map ? native['strategy'] : null;
    final matrix = strategy is Map ? strategy['matrix'] : null;
    final outputs = catalog is Map ? catalog['outputs'] : null;
    final nativeSteps = native is Map && native['steps'] is List
        ? (native['steps'] as List).whereType<Map>()
        : <Map>[];
    bool runsForStock(Map step) {
      final condition = step['if']?.toString().replaceAll(RegExp(r'\s+'), '');
      return _hardFailure(step['continue-on-error']) &&
          (_mandatory(step['if']) ||
              condition == "matrix.family=='stock-hermes'" ||
              condition == "\${{matrix.family=='stock-hermes'}}");
    }

    final stockSteps = nativeSteps.toList();
    final pythonIndex = stockSteps.indexWhere(
      (step) =>
          runsForStock(step) &&
          step['uses'].toString().startsWith('actions/setup-python@') &&
          step['with'] is Map &&
          (step['with'] as Map)['python-version'] == '3.14',
    );
    final bootstrapIndex = stockSteps.indexWhere(
      (step) =>
          runsForStock(step) &&
          step['run'] is String &&
          (step['run'] as String).trim().split('\n').last.trim() ==
              'python3 -m pm.build_env --source . --out .venv --extra web',
    );
    if (pythonIndex < 0 || bootstrapIndex <= pythonIndex) {
      failures.add(
        '$path:native REQUIRED_QUALITY_GATE: Provision supported Python 3.14 before building the current stock Hermes environment through upstream PM.',
      );
    }
    if (!hardCommand('catalog', matrixCommand) ||
        outputs is! Map ||
        outputs['families'] != r'${{ steps.catalog.outputs.families }}' ||
        catalog is! Map ||
        !(catalog['steps'] as List).whereType<Map>().any(
          (step) =>
              step['id'] == 'catalog' &&
              _runsFinalCommand(step['run'], matrixCommand),
        ) ||
        !hardCommand('native', nativeCommand) ||
        !hardCommand(
          'native',
          r'echo "$ANDROID_HOME/platform-tools" >> "$GITHUB_PATH"',
        ) ||
        native is! Map ||
        native['needs'] != 'catalog' ||
        strategy is! Map ||
        strategy['fail-fast'] != false ||
        matrix is! Map ||
        matrix.length != 1 ||
        matrix['family'] !=
            r'${{ fromJSON(needs.catalog.outputs.families) }}' ||
        !nativeSteps.any(
          (step) =>
              _runsFinalCommand(step['run'], nativeCommand) &&
              step['env'] is Map &&
              (step['env'] as Map)['NIGHTLY_FAMILY'] == r'${{ matrix.family }}',
        )) {
      failures.add(
        '$path:native REQUIRED_QUALITY_GATE: Run every enrolled native family independently; do not filter, replace or soft-fail the matrix.',
      );
    }
    for (final command in [
      './android/gradlew -p android :app:testDebugUnitTest --no-daemon',
      'python3 scripts/check_commit_linters.py',
      _nativeFixtureCommand,
      _notificationFixtureCommand,
      _declarationFixtureCommand,
      _voiceFixtureCommand,
    ]) {
      if (!hardCommand('platform', command)) {
        failures.add(
          '$path:platform REQUIRED_QUALITY_GATE: Run $command as a mandatory hard-failing step.',
        );
      }
    }
    final renderer = jobs['renderer'];
    if (renderer is! Map ||
        !_hardFailure(renderer['continue-on-error']) ||
        !_mandatory(renderer['if']) ||
        renderer['steps'] is! List ||
        !(renderer['steps'] as List).whereType<Map>().any(
          (step) =>
              step['uses'] == './.github/actions/test-diagram-preview' &&
              _hardFailure(step['continue-on-error']) &&
              _mandatory(step['if']),
        )) {
      failures.add(
        '$path:renderer REQUIRED_QUALITY_GATE: Run real browser renderer isolation.',
      );
    }
  } on FileSystemException catch (error) {
    failures.add('$path QUALITY_WORKFLOW_INPUT: ${error.message}');
  } on YamlException catch (error) {
    failures.add('$path QUALITY_WORKFLOW_INPUT: ${error.message}');
  } on FormatException catch (error) {
    failures.add('$path QUALITY_WORKFLOW_INPUT: ${error.message}');
  }
  return failures;
}

bool _hardFailure(Object? value) => value == null || value == false;

bool _allBranchPushes(Object? events) {
  if (events is! Map || !events.containsKey('push')) return false;
  final push = events['push'];
  if (push == null) return true;
  if (push is! Map ||
      ['branches-ignore', 'paths', 'paths-ignore'].any(push.containsKey)) {
    return false;
  }
  final branches = push['branches'];
  if (branches == null) {
    return !push.containsKey('tags') && !push.containsKey('tags-ignore');
  }
  return branches is List && branches.length == 1 && branches.single == '**';
}

/// These existing Gradle commands populate the pinned Kotlin compiler cache.
/// This checks placement, not build success: absent tooling fails the native CLI.
bool _nativeToolingReady(Map step) =>
    _hardFailure(step['continue-on-error']) &&
    _mandatory(step['if']) &&
    step['run'] is String &&
    const {
      './android/gradlew -p android :app:testDebugUnitTest --no-daemon',
      '(cd android && ./gradlew :app:testDebugUnitTest --no-daemon) '
          '2>&1 | tee native_test_output.txt\nexit \${PIPESTATUS[0]}',
    }.contains((step['run'] as String).trim());

bool _mandatoryJob(Object? condition, String job) {
  if (_mandatory(condition)) return true;
  // The release workflow intentionally accepts pushes and manual releases from
  // main only. Quality checks still have to run on every accepted release.
  return job == 'build' &&
      condition is String &&
      condition.replaceAll(RegExp(r'\s+'), '') ==
          "github.event_name=='push'||github.ref=='refs/heads/main'";
}

bool _mandatory(Object? condition) {
  if (condition == null || condition == true) return true;
  if (condition is! String) return false;
  final normalized = condition.replaceAll(RegExp(r'\s+'), '');
  return const {
    'success()',
    'always()',
    r'${{success()}}',
    r'${{always()}}',
    r'${{true}}',
  }.contains(normalized);
}

bool _runsFinalCommand(Object? run, String required) {
  if (run is! String) return false;
  final lines = run
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .toList();
  if (lines.length != 1) return false;
  final command = lines.single;
  return command == required;
}

void main(List<String> arguments) {
  final failures = checkRequiredQualityGates(
    Directory(arguments.isEmpty ? '.' : arguments.single),
  );
  for (final failure in failures) {
    stderr.writeln(failure);
  }
  exitCode = failures.isEmpty ? 0 : 1;
}
