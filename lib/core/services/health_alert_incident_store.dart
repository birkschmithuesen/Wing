import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import '../models/health_alert.dart';

/// Device-owned unresolved incidents, isolated by exact connection identity.
/// Writes survive route/session disposal and serialize across replacement owners.
class HealthAlertIncidentStore {
  HealthAlertIncidentStore(this.preferences);
  final SharedPreferences preferences;
  final _writes = <String, Future<void>>{};
  String _key(String connection) =>
      'wing-health-alert-incidents:${Uri.encodeComponent(connection)}';

  List<HealthAlert> read(String connection) {
    final raw = preferences.getString(_key(connection));
    if (raw == null) return const [];
    final alerts = (jsonDecode(raw) as List)
        .map((value) => _decode(value as Map))
        .toList();
    if (alerts.any((alert) => alert.connectionIdentity != connection)) {
      throw const FormatException('Incident connection does not match');
    }
    return alerts;
  }

  Future<void> write(String connection, List<HealthAlert> alerts) {
    // Capture before queuing, so later evaluator changes cannot alter this write.
    final raw = jsonEncode(alerts.map(_encode).toList());
    final previous = _writes[connection] ?? Future<void>.value();
    final write = previous.then((_) async {
      if (!await preferences.setString(_key(connection), raw)) {
        throw StateError('Health alert incidents were not saved');
      }
    });
    // A failed write must not poison subsequent recovery or acknowledgement.
    _writes[connection] = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  Map<String, Object?> _encode(HealthAlert alert) => {
    'id': alert.id,
    'connectionIdentity': alert.connectionIdentity,
    'connectionLabel': alert.connectionLabel,
    'scope': alert.scope.name,
    'title': alert.title,
    'detail': alert.detail,
    'severity': alert.severity.name,
    'observedAt': alert.observedAt.toUtc().toIso8601String(),
    'occurrence': alert.occurrence,
    'destination': alert.destination,
    'connectorNames': alert.connectorNames,
    'profileName': alert.profileName,
    'trigger': alert.trigger == null
        ? null
        : {
            'usedPercent': alert.trigger!.usedPercent,
            'warningAbovePercent': alert.trigger!.warningAbovePercent,
            'alertMinutes': alert.trigger!.alertMinutes,
            'criticalPressure': alert.trigger!.criticalPressure,
          },
    'acknowledged': alert.acknowledged,
    'snoozedUntil': alert.snoozedUntil?.toUtc().toIso8601String(),
  };

  HealthAlert _decode(Map value) {
    final trigger = value['trigger'] as Map?;
    return HealthAlert(
      id: value['id'] as String,
      connectionIdentity: value['connectionIdentity'] as String,
      connectionLabel: value['connectionLabel'] as String,
      scope: HealthAlertScope.values.byName(value['scope'] as String),
      title: value['title'] as String,
      detail: value['detail'] as String,
      severity: HealthAlertSeverity.values.byName(value['severity'] as String),
      observedAt: DateTime.parse(value['observedAt'] as String),
      occurrence: value['occurrence'] as int,
      destination: value['destination'] as String?,
      connectorNames: List.unmodifiable(
        List<String>.from(value['connectorNames'] as List),
      ),
      profileName: value['profileName'] as String?,
      trigger: trigger == null
          ? null
          : HealthAlertTrigger(
              usedPercent: (trigger['usedPercent'] as num?)?.toDouble(),
              warningAbovePercent: (trigger['warningAbovePercent'] as num)
                  .toDouble(),
              alertMinutes: trigger['alertMinutes'] as int,
              criticalPressure: trigger['criticalPressure'] as bool,
            ),
      acknowledged: value['acknowledged'] as bool,
      snoozedUntil: value['snoozedUntil'] == null
          ? null
          : DateTime.parse(value['snoozedUntil'] as String),
      lastKnown: true,
    );
  }
}
