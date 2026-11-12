import 'hermes_profile.dart';

enum AdministrationHealthStatus { healthy, warning, failure, unknown }

class AdministrationHealthFinding {
  const AdministrationHealthFinding({
    required this.title,
    required this.detail,
    required this.status,
    this.destination,
    this.checkedAt,
    this.readFailed = false,
  });
  final String title, detail;
  final AdministrationHealthStatus status;
  final String? destination;
  final DateTime? checkedAt;
  final bool readFailed;
}

/// An explicit access check remains attached to its captured workspace.
class AdministrationProfileHealthObservation {
  const AdministrationProfileHealthObservation(this.scope, this.finding);
  final WorkspaceScope scope;
  final AdministrationHealthFinding? finding;
}
