import '../services/doctor_diagnostic.dart';
import '../services/security_audit_report.dart';

/// Captured stock action identity; a same-name replacement is a different run.
class AdministrationAction {
  const AdministrationAction(this.name, this.pid);
  final String name;
  final int pid;
  factory AdministrationAction.fromJson(Map<String, dynamic> result) {
    final name = result['name'];
    final pid = result['pid'];
    if (name is! String || name.isEmpty || pid is! int) {
      throw const FormatException('Invalid operation receipt');
    }
    return AdministrationAction(name, pid);
  }
}

enum AdministrationDiagnostic {
  doctor('ops/doctor', 'doctor', 'Doctor'),
  securityAudit('ops/security-audit', 'security-audit', 'Security audit');

  const AdministrationDiagnostic(this.path, this.actionName, this.title);
  final String path, actionName, title;
}

enum AdministrationOperationOutcome {
  unknown,
  running,
  completed,
  findings,
  failed,
}

/// Immutable facts from one captured run. The raw map stays inside its codec.
class AdminDiagnosticObservation {
  AdminDiagnosticObservation(
    this.action,
    Map<String, dynamic> status,
    this.checkedAt, {
    this.readError,
    this.resultUnavailable = false,
  }) : _status = _immutable(status) as Map<String, dynamic> {
    final output = _status['lines'];
    if (output != null &&
        (output is! List || output.any((line) => line is! String))) {
      throw const FormatException('Invalid operation output');
    }
  }
  final AdministrationAction action;
  final Map<String, dynamic> _status;
  final DateTime? checkedAt;
  final String? readError;

  /// A valid stock response no longer identifies this captured run.
  /// Last confirmed output and completion facts remain available for review.
  final bool resultUnavailable;
  bool get diagnostic => {'doctor', 'security-audit'}.contains(action.name);
  bool get securityAudit => action.name == 'security-audit';
  bool get auditSummaryUnavailable =>
      securityAudit && running == false && audit == null;
  bool? get running =>
      _status['running'] is bool ? _status['running'] as bool : null;
  int? get exitCode =>
      _status['exit_code'] is int ? _status['exit_code'] as int : null;
  List<String> get lines => List<String>.unmodifiable(
    (_status['lines'] as List? ?? const []).cast<String>(),
  );
  bool get terminal => running == false && exitCode != null;
  bool get failed => classification == AdministrationOperationOutcome.failed;
  DoctorDiagnostic? get diagnosis {
    final parsed = action.name == 'doctor' && running == false
        ? DoctorDiagnostic.fromLines(lines)
        : null;
    return parsed == null
        ? null
        : DoctorDiagnostic(List.unmodifiable(parsed.findings));
  }

  SecurityAuditReport? get audit {
    final parsed = action.name == 'security-audit'
        ? SecurityAuditReport.fromStatus(_status)
        : null;
    return parsed == null
        ? null
        : SecurityAuditReport(
            componentCount: parsed.componentCount,
            findings: List.unmodifiable(parsed.findings),
            notices: parsed.notices,
          );
  }

  AdministrationOperationOutcome get classification =>
      resultUnavailable && !terminal
      ? AdministrationOperationOutcome.unknown
      : running == true
      ? AdministrationOperationOutcome.running
      : !terminal
      ? AdministrationOperationOutcome.unknown
      : exitCode == 0
      ? AdministrationOperationOutcome.completed
      : securityAudit && exitCode == 1
      ? audit == null
            ? AdministrationOperationOutcome.unknown
            : AdministrationOperationOutcome.findings
      : action.name == 'doctor' && exitCode == 1 && diagnosis?.hasIssues == true
      ? AdministrationOperationOutcome.findings
      : AdministrationOperationOutcome.failed;
  String get outcome => switch (classification) {
    AdministrationOperationOutcome.running => 'Running',
    AdministrationOperationOutcome.completed => 'Completed',
    AdministrationOperationOutcome.findings =>
      securityAudit ? 'Review audit findings' : 'Review Doctor findings',
    AdministrationOperationOutcome.failed => 'Failed',
    AdministrationOperationOutcome.unknown => 'Outcome unavailable',
  };
  String get summaryLabel =>
      audit?.title ??
      diagnosis?.title ??
      (classification == AdministrationOperationOutcome.completed
          ? 'Completed · Review results'
          : outcome);

  AdminDiagnosticObservation withReadError(
    String? error, {
    bool? resultUnavailable,
  }) => AdminDiagnosticObservation(
    action,
    _status,
    checkedAt,
    readError: error,
    resultUnavailable: resultUnavailable ?? this.resultUnavailable,
  );
}

/// Existing Health persistence shape. It is not an alternate wire protocol.
Map<String, dynamic> diagnosticStatusSnapshot(
  AdminDiagnosticObservation value,
) => value._status;

Object? _immutable(Object? value) => switch (value) {
  Map value => Map<String, dynamic>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _immutable(entry.value),
  }),
  List value => List<dynamic>.unmodifiable(value.map(_immutable)),
  null || String() || bool() || num() => value,
  _ => throw const FormatException('Invalid operation value'),
};
