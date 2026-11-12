import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/administration_operation.dart';
import 'package:wing/core/services/administration_health.dart';
import 'package:wing/core/services/administration_operation_session.dart';
import 'package:wing/core/services/administration_repository.dart';

AdministrationOperationSession fixtureOperation(
  AdministrationRepository server,
  AdministrationAction action,
) {
  final operation = AdministrationOperationSession(server, action);
  addTearDown(operation.dispose);
  return operation;
}

/// Seed the real retained-observation codec, rather than test-only mutators.
void restoreDiagnostic(
  AdministrationHealth health,
  String path,
  AdminDiagnosticObservation observation,
) {
  final saved = health.snapshot();
  final generations = saved['generations'] as Map;
  final generation = (generations[path] as int? ?? 0) + 1;
  generations[path] = generation;
  (saved['diagnostics'] as Map)[path] = {
    'name': observation.action.name,
    'pid': observation.action.pid,
    'status': diagnosticStatusSnapshot(observation),
    'checkedAt': observation.checkedAt?.toUtc().toIso8601String(),
    'readError': observation.readError,
    'scope': health.server.connectionLabel,
    'generation': generation,
  };
  health.restore(saved);
}
