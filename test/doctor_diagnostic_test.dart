import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/doctor_diagnostic.dart';
import 'package:wing/core/models/administration_operation.dart';

void main() {
  final divider = '─' * 60;
  test('Doctor findings are a completed diagnostic outcome, not a failure', () {
    final findings = [
      '=== doctor started 2026-10-07 08:28:00 ===',
      divider,
      'Found 1 issue(s) to address:',
      '1. state.db is large — enable sessions.auto_prune in config.yaml',
    ];
    for (final (name, running, code, lines, expected) in [
      ('doctor', false, 1, findings, AdministrationOperationOutcome.findings),
      (
        'doctor',
        false,
        0,
        [divider, 'All checks passed! 🎉'],
        AdministrationOperationOutcome.completed,
      ),
      ('doctor', true, null, findings, AdministrationOperationOutcome.running),
      ('doctor', false, null, findings, AdministrationOperationOutcome.unknown),
      (
        'doctor',
        false,
        1,
        ['Doctor could not finish'],
        AdministrationOperationOutcome.failed,
      ),
      (
        'doctor',
        false,
        1,
        [divider, 'Found 2 issue(s) to address:', '1. Truncated'],
        AdministrationOperationOutcome.failed,
      ),
      (
        'doctor',
        false,
        1,
        [divider, 'All checks passed! 🎉'],
        AdministrationOperationOutcome.failed,
      ),
      ('doctor', false, 2, findings, AdministrationOperationOutcome.failed),
      ('install', false, 1, findings, AdministrationOperationOutcome.failed),
      (
        'doctor',
        false,
        1,
        [
          ...findings,
          '=== doctor started 2026-10-07 08:29:00 ===',
          'Doctor could not finish',
        ],
        AdministrationOperationOutcome.failed,
      ),
    ]) {
      final observation = AdminDiagnosticObservation(
        AdministrationAction(name, 7),
        {'running': running, 'exit_code': code, 'lines': lines},
        DateTime.utc(2026, 10, 7),
      );
      expect(
        observation.classification,
        expected,
        reason: '$name running=$running exit=$code lines=$lines',
      );
      expect(
        observation.failed,
        expected == AdministrationOperationOutcome.failed,
      );
      if (expected == AdministrationOperationOutcome.findings) {
        expect(observation.outcome, 'Review Doctor findings');
        expect(observation.summaryLabel, '1 issue found');
      }
    }
  });
  test('turns colored findings into titles and supporting details', () {
    final report = DoctorDiagnostic.fromLines([
      '  ✓ Profiles checked',
      '\x1b[33m$divider\x1b[0m',
      '\x1b[33m\x1b[1m  Found 3 issue(s) to address:\x1b[0m',
      '',
      '  1. state.db is large — enable sessions.auto_prune in config.yaml',
      '  2. Browser tools (agent-browser) has 2 npm vulnerabilities',
      '  3. web workspace has 6 npm vulnerabilities',
      '',
      "  Tip: run 'hermes doctor --fix' to auto-fix what's possible.",
    ])!;
    expect(report.title, '3 issues found');
    expect(report.findings.map((f) => f.title), [
      'state.db is large',
      'Browser tools (agent-browser)',
      'web workspace',
    ]);
    expect(report.findings.map((f) => f.detail), [
      'enable sessions.auto_prune in config.yaml',
      '2 npm vulnerabilities',
      '6 npm vulnerabilities',
    ]);
  });
  test('keeps arbitrary findings and multiline details intact', () {
    final report = DoctorDiagnostic.fromLines([
      divider,
      'Found 1 issue(s) to address:',
      '1. Something needs attention',
      '  More information from the server.',
    ])!;
    expect(report.title, '1 issue found');
    expect(
      report.findings.single.title,
      'Something needs attention More information from the server.',
    );
    expect(report.findings.single.detail, isNull);
  });
  test('uses only the latest report from an appended action log', () {
    final report = DoctorDiagnostic.fromLines([
      divider,
      'Found 3 issue(s) to address:',
      '=== doctor started 2026-09-18 01:15:00 ===',
      divider,
      '  All checks passed! 🎉',
    ])!;
    expect(report.title, 'No issues found');
    expect(report.hasIssues, isFalse);
  });
  test('does not turn missing or incomplete findings into a diagnosis', () {
    for (final lines in [
      <String>[],
      ['  ✓ Profiles checked'],
      [divider, ''],
      [divider, 'All checks passed!', '=== doctor started today ===', 'Error'],
      ['┌${'─' * 60}┐', 'Doctor', '└${'─' * 60}┘'],
      [divider, 'Found 2 issue(s) to address:', '1. Only one item received'],
      [divider, 'Found 1 issue(s) to address:', '2. First item missing'],
      [divider, 'Found 0 issue(s) to address:'],
      [divider, 'Unrecognized report'],
    ]) {
      expect(DoctorDiagnostic.fromLines(lines), isNull);
    }
  });
}
