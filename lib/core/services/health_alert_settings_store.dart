import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/health_alert.dart';

/// Device policy only; never writes Hermes profile configuration.
class HealthAlertSettingsStore {
  HealthAlertSettingsStore(this.preferences);
  final SharedPreferences preferences;
  static const key = 'wing-health-alert-settings';
  bool _needsMigration = false;
  bool get needsMigration => _needsMigration;
  HealthAlertSettings read() {
    _needsMigration = false;
    final value = preferences.getString(key);
    if (value == null) return HealthAlertSettings();
    final data = jsonDecode(value) as Map;
    final rules = data['rules'];
    // Approved one-time conversion of the previously shared duration. The
    // owner persists this new format through its normal ordered write path.
    final sharedDuration =
        rules is Map &&
        hostAlertMetrics.every((metric) {
          final rule = rules[metric.name];
          return rule is Map &&
              rule['minutes'] is int &&
              !rule.containsKey('alertMinutes') &&
              !rule.containsKey('clearMinutes');
        });
    final decoded = HealthAlertSettings.decode(
      sharedDuration
          ? {
              ...data,
              'rules': {
                for (final metric in hostAlertMetrics)
                  metric.name:
                      Map<String, dynamic>.from(rules[metric.name] as Map)
                        ..remove('minutes')
                        ..['alertMinutes'] = rules[metric.name]['minutes']
                        ..['clearMinutes'] = rules[metric.name]['minutes'],
              },
            }
          : data,
    );
    _needsMigration = sharedDuration;
    return decoded;
  }

  Future<void> write(HealthAlertSettings settings) async {
    if (!await preferences.setString(key, jsonEncode(settings.encode()))) {
      throw StateError('Health alert settings were not saved');
    }
  }
}
