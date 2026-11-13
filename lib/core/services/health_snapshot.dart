import '../models/health_finding.dart';

DateTime? healthSnapshotTime(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

bool healthSnapshotExpired(DateTime? at, DateTime now) =>
    at == null ||
    now.isBefore(at) ||
    now.difference(at) >= const Duration(hours: 24);

Map<String, dynamic> healthFindingSnapshot(AdministrationHealthFinding value) =>
    {
      'title': value.title,
      'detail': value.detail,
      'status': value.status.name,
      'destination': value.destination,
      'checkedAt': value.checkedAt?.toUtc().toIso8601String(),
    };

AdministrationHealthFinding? restoreHealthFinding(Object? data) {
  if (data == null) return null;
  final value = data as Map;
  return AdministrationHealthFinding(
    title: value['title'] as String,
    detail: value['detail'] as String,
    status: AdministrationHealthStatus.values.byName(value['status'] as String),
    destination: value['destination'] as String?,
    checkedAt: healthSnapshotTime(value['checkedAt']),
  );
}
