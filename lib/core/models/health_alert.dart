import 'host_thresholds.dart';

enum HealthAlertSeverity { warning, critical }

enum HealthAlertScope { host, profile, connection }

/// The host reading and policy that admitted an occurrence, retained as later
/// readings update its detail or qualify it as last known.
class HealthAlertTrigger {
  const HealthAlertTrigger({
    required this.usedPercent,
    required this.warningAbovePercent,
    required this.alertMinutes,
    required this.criticalPressure,
  });
  final double? usedPercent;
  final double warningAbovePercent;
  final int alertMinutes;
  final bool criticalPressure;
}

class HealthAlert {
  const HealthAlert({
    required this.id,
    required this.connectionIdentity,
    required this.connectionLabel,
    required this.scope,
    required this.title,
    required this.detail,
    required this.severity,
    required this.observedAt,
    required this.occurrence,
    required this.destination,
    this.connectorNames = const [],
    this.profileName,
    this.trigger,
    this.lastKnown = false,
    this.acknowledged = false,
    this.snoozedUntil,
  });
  final String id, connectionIdentity, connectionLabel, title, detail;
  final String? profileName;

  /// Captured recovery route and failed connector identities, never parsed from
  /// the display title or looked up in a later profile's observations.
  final String? destination;
  final List<String> connectorNames;
  final HealthAlertTrigger? trigger;
  final HealthAlertScope scope;
  final HealthAlertSeverity severity;
  final DateTime observedAt;
  final int occurrence;
  final bool lastKnown;
  final bool acknowledged;
  final DateTime? snoozedUntil;
  bool remindsAt(DateTime now) =>
      !acknowledged && (snoozedUntil == null || !now.isBefore(snoozedUntil!));
  HealthAlert copyWith({
    List<String>? connectorNames,
    bool? lastKnown,
    bool? acknowledged,
    DateTime? snoozedUntil,
  }) => HealthAlert(
    id: id,
    connectionIdentity: connectionIdentity,
    connectionLabel: connectionLabel,
    scope: scope,
    title: title,
    detail: detail,
    severity: severity,
    observedAt: observedAt,
    occurrence: occurrence,
    destination: destination,
    connectorNames: connectorNames ?? this.connectorNames,
    profileName: profileName,
    trigger: trigger,
    lastKnown: lastKnown ?? this.lastKnown,
    acknowledged: acknowledged ?? this.acknowledged,
    snoozedUntil: snoozedUntil ?? this.snoozedUntil,
  );
}

class HealthAlertRule {
  HealthAlertRule({
    required this.enabled,
    this.nativeCriticalEnabled = false,
    required this.warnAbove,
    required this.clearBelow,
    required this.alertMinutes,
    required this.clearMinutes,
  }) {
    if (!warnAbove.isFinite ||
        !clearBelow.isFinite ||
        warnAbove > 100 ||
        warnAbove <= 0 ||
        clearBelow < 0 ||
        clearBelow > 100 ||
        alertMinutes < 1 ||
        alertMinutes > 30 ||
        clearMinutes < 1 ||
        clearMinutes > 30) {
      throw ArgumentError(
        'Use 0–100%, a recovery limit below the warning, and 1–30 minutes.',
      );
    }
    if (clearBelow >= warnAbove) {
      throw ArgumentError.value(
        clearBelow,
        'clearBelow',
        'The clear percentage must be lower than the alert percentage.',
      );
    }
  }
  final bool enabled, nativeCriticalEnabled;
  final double warnAbove, clearBelow;
  final int alertMinutes, clearMinutes;
  HealthAlertRule copyWith({
    bool? enabled,
    bool? nativeCriticalEnabled,
    double? warnAbove,
    double? clearBelow,
    int? alertMinutes,
    int? clearMinutes,
  }) => HealthAlertRule(
    enabled: enabled ?? this.enabled,
    nativeCriticalEnabled: nativeCriticalEnabled ?? this.nativeCriticalEnabled,
    warnAbove: warnAbove ?? this.warnAbove,
    clearBelow: clearBelow ?? this.clearBelow,
    alertMinutes: alertMinutes ?? this.alertMinutes,
    clearMinutes: clearMinutes ?? this.clearMinutes,
  );
  Map<String, Object> encode() => {
    'enabled': enabled,
    'nativeCriticalEnabled': nativeCriticalEnabled,
    'warnAbove': warnAbove,
    'clearBelow': clearBelow,
    'alertMinutes': alertMinutes,
    'clearMinutes': clearMinutes,
  };
  factory HealthAlertRule.decode(Map value) => HealthAlertRule(
    enabled: value['enabled'] as bool,
    nativeCriticalEnabled: value['nativeCriticalEnabled'] as bool,
    warnAbove: (value['warnAbove'] as num).toDouble(),
    clearBelow: (value['clearBelow'] as num).toDouble(),
    alertMinutes: value['alertMinutes'] as int,
    clearMinutes: value['clearMinutes'] as int,
  );
}

class HealthAlertSettings {
  HealthAlertSettings({
    this.enabled = true,
    this.profile = true,
    this.animateBell = true,
    this.showNotice = true,
    Map<HostMetric, HealthAlertRule>? rules,
  }) : rules = Map.unmodifiable(
         rules ??
             {
               HostMetric.memoryUsedPercent: HealthAlertRule(
                 enabled: true,
                 nativeCriticalEnabled: true,
                 warnAbove: 90,
                 clearBelow: 85,
                 alertMinutes: 2,
                 clearMinutes: 2,
               ),
               HostMetric.diskUsedPercent: HealthAlertRule(
                 enabled: true,
                 nativeCriticalEnabled: true,
                 warnAbove: 90,
                 clearBelow: 85,
                 alertMinutes: 2,
                 clearMinutes: 2,
               ),
               HostMetric.cpuPercent: HealthAlertRule(
                 enabled: false,
                 warnAbove: 95,
                 clearBelow: 80,
                 alertMinutes: 3,
                 clearMinutes: 3,
               ),
             },
       ) {
    if (this.rules.length != 3 ||
        !hostAlertMetrics.every(this.rules.containsKey)) {
      throw ArgumentError('RAM, disk and CPU rules are required.');
    }
  }
  final bool enabled, profile, animateBell, showNotice;
  final Map<HostMetric, HealthAlertRule> rules;
  HealthAlertSettings copyWith({
    bool? enabled,
    bool? profile,
    bool? animateBell,
    bool? showNotice,
    Map<HostMetric, HealthAlertRule>? rules,
  }) => HealthAlertSettings(
    enabled: enabled ?? this.enabled,
    profile: profile ?? this.profile,
    animateBell: animateBell ?? this.animateBell,
    showNotice: showNotice ?? this.showNotice,
    rules: rules ?? this.rules,
  );
  Map<String, Object> encode() => {
    'enabled': enabled,
    'profile': profile,
    'animateBell': animateBell,
    'showNotice': showNotice,
    'rules': {for (final e in rules.entries) e.key.name: e.value.encode()},
  };
  factory HealthAlertSettings.decode(Map value) => HealthAlertSettings(
    enabled: value['enabled'] as bool,
    profile: value['profile'] as bool,
    animateBell: value['animateBell'] as bool,
    showNotice: value['showNotice'] as bool,
    rules: {
      for (final metric in hostAlertMetrics)
        metric: HealthAlertRule.decode(
          (value['rules'] as Map)[metric.name] as Map,
        ),
    },
  );
}

const hostAlertMetrics = [
  HostMetric.memoryUsedPercent,
  HostMetric.diskUsedPercent,
  HostMetric.cpuPercent,
];
