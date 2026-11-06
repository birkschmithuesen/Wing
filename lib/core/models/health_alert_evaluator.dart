import 'health_alert.dart';
import 'host_thresholds.dart';
import 'profile_connectors.dart';

/// Stateful hysteresis over independent fresh samples. No I/O, timers or UI.
/// Gaps over three times the applicable duration break progress. Collection
/// pauses retain progress; unknown readings retain incidents but reset progress.
class HealthAlertEvaluator {
  HealthAlertEvaluator({
    required this.connectionIdentity,
    required this.connectionLabel,
  });
  final String connectionIdentity, connectionLabel;
  final _alerts = <String, HealthAlert>{};
  final _periods = <String, _Period>{};
  int _occurrence = 0;
  List<HealthAlert> get alerts => List.unmodifiable(_alerts.values);

  /// Restart from retained incidents, never from stale hysteresis progress.
  void restore(List<HealthAlert> incidents) {
    for (final alert in incidents) {
      _alerts[alert.id] = alert.copyWith(lastKnown: true);
      if (alert.occurrence > _occurrence) _occurrence = alert.occurrence;
    }
  }

  void resetPeriods() => _periods.clear();
  void pause() {
    for (final entry in _alerts.entries.toList()) {
      _alerts[entry.key] = entry.value.copyWith(lastKnown: true);
    }
  }

  void clear() {
    _alerts.clear();
    resetPeriods();
  }

  void remove(String key) {
    _alerts.remove(key);
    _periods.remove(key);
  }

  String hostKey(HostMetric metric) =>
      '$connectionIdentity:host:${metric.name}';

  void applyHostRule(HostMetric metric, HealthAlertRule rule) {
    final key = hostKey(metric);
    final alert = _alerts[key];
    if (!rule.enabled && !rule.nativeCriticalEnabled ||
        alert != null &&
            (alert.severity == HealthAlertSeverity.critical
                ? !rule.nativeCriticalEnabled
                : !rule.enabled)) {
      remove(key);
    }
  }

  void restartHostWarning(HostMetric metric) {
    final key = hostKey(metric);
    _periods.remove(key);
    if (_alerts[key]?.severity == HealthAlertSeverity.warning) {
      _alerts.remove(key);
    }
  }

  void host({
    required HostMetric metric,
    required HealthAlertRule rule,
    required DateTime now,
    DateTime? sampledAt,
    double? value,
    bool critical = false,
    bool pressureKnown = true,
  }) {
    final key = hostKey(metric);
    applyHostRule(metric, rule);
    if (!rule.enabled && !rule.nativeCriticalEnabled) {
      return;
    }
    if (sampledAt == null || value == null && !critical) {
      unknown(key);
      return;
    }
    final existing = _alerts[key];
    final trigger = HealthAlertTrigger(
      usedPercent: value,
      warningAbovePercent: rule.warnAbove,
      alertMinutes: rule.alertMinutes,
      criticalPressure: critical && rule.nativeCriticalEnabled,
    );
    final label = switch (metric) {
      HostMetric.memoryUsedPercent => 'Memory usage',
      HostMetric.diskUsedPercent => 'Disk usage',
      _ => 'CPU usage',
    };
    final detail =
        '${value == null ? 'Usage percentage unavailable' : '${value.toStringAsFixed(0)}% used'} · warning above ${rule.warnAbove}%'
        '\n${switch (metric) {
          HostMetric.memoryUsedPercent => 'Memory pressure can interrupt Hermes processes or cause an out-of-memory failure.',
          HostMetric.diskUsedPercent => 'Low free space can prevent Hermes from saving chats or writing files.',
          _ => 'Sustained CPU usage may slow replies and tools.',
        }}';
    if (critical && rule.nativeCriticalEnabled) {
      _periods.remove(key);
      _put(
        key,
        label == 'Memory usage'
            ? 'Critical memory pressure'
            : 'Critical disk pressure',
        detail,
        HealthAlertScope.host,
        HealthAlertSeverity.critical,
        sampledAt,
        trigger: trigger,
      );
      return;
    }
    if (!rule.enabled && existing == null) return;
    if (value == null) return;
    final clearing =
        existing != null &&
        value < rule.clearBelow &&
        (existing.severity != HealthAlertSeverity.critical || pressureKnown);
    final raising = rule.enabled && existing == null && value > rule.warnAbove;
    if (!clearing && !raising) {
      _periods.remove(key);
    } else {
      final old = _periods[key];
      final duration = Duration(
        minutes: clearing ? rule.clearMinutes : rule.alertMinutes,
      );
      if (old == null ||
          old.clearing != clearing ||
          sampledAt.isBefore(old.last) ||
          sampledAt.difference(old.last) > duration * 3) {
        _periods[key] = _Period(sampledAt, sampledAt, clearing);
      } else {
        old.last = sampledAt;
        if (sampledAt.difference(old.start) >= duration) {
          if (clearing) {
            remove(key);
            return;
          }
          _put(
            key,
            'High ${label.toLowerCase()}',
            detail,
            HealthAlertScope.host,
            HealthAlertSeverity.warning,
            sampledAt,
            trigger: trigger,
          );
          _periods.remove(key);
        }
      }
    }
    if (_alerts[key] case final alert?) {
      _alerts[key] = HealthAlert(
        id: key,
        connectionIdentity: connectionIdentity,
        connectionLabel: connectionLabel,
        scope: alert.scope,
        title: alert.title,
        detail: detail,
        severity: alert.severity,
        observedAt: sampledAt,
        occurrence: alert.occurrence,
        destination: alert.destination,
        trigger: alert.trigger,
        acknowledged: alert.acknowledged,
        snoozedUntil: alert.snoozedUntil,
        lastKnown:
            alert.severity == HealthAlertSeverity.critical && !pressureKnown,
      );
    }
  }

  void finding({
    required String key,
    required String title,
    required String detail,
    required HealthAlertScope scope,
    required DateTime? at,
    required bool? failed,
    required String? destination,
    List<String> connectorNames = const [],
    HealthAlertSeverity severity = HealthAlertSeverity.warning,
    String? profileName,
    ConnectorInventoryObservation? connectorInventory,
  }) {
    final remaining = connectorInventory?.remainingFailures(connectorNames, at);
    if (destination == 'MCP connectors' && remaining != null) {
      if (remaining.isEmpty) {
        remove(key);
        return;
      }
      connectorNames = remaining;
    }
    if (failed == null || at == null) {
      unknown(key);
      return;
    }
    if (!failed) {
      remove(key);
      return;
    }
    _put(
      key,
      title,
      detail,
      scope,
      severity,
      at,
      profileName: profileName,
      destination: destination,
      connectorNames: connectorNames,
    );
  }

  /// Retire absent failure sources even when their profile is not selected or
  /// its last probe is stale. Membership never proves a surviving probe passed.
  void reconcileConnectors(String profile, ConnectorInventoryObservation data) {
    for (final alert in alerts) {
      if (alert.profileName != profile ||
          alert.destination != 'MCP connectors') {
        continue;
      }
      final remaining = data.remainingFailures(
        alert.connectorNames,
        alert.observedAt,
      );
      if (remaining == null) continue;
      if (remaining.isEmpty) {
        remove(alert.id);
      } else if (remaining.length != alert.connectorNames.length) {
        _alerts[alert.id] = alert.copyWith(
          connectorNames: remaining,
          lastKnown: true,
        );
      }
    }
  }

  /// Runtime-only recovery can retire runtime incidents, never failed probes.
  /// Missing/configured/connecting rows leave prior failures unconfirmed.
  void connectorRuntime(
    String profile,
    ConnectorRuntimeObservation? runtime,
    ConnectorInventoryObservation? inventory,
  ) {
    final key = '$connectionIdentity:profile:$profile:Connector runtime';
    if (runtime == null || inventory == null) {
      unknown(key);
      return;
    }
    final previous = _alerts[key];
    if (previous != null && runtime.receivedAt.isBefore(previous.observedAt)) {
      return;
    }
    final issues = runtime.issuesFor(inventory.connectors.values);
    final remaining = <String>{
      if (previous != null)
        for (final name in previous.connectorNames)
          if (inventory.enabled[name] == true &&
              runtime.forConnector(inventory.connectors[name])?.recovered !=
                  true)
            name,
      ...issues.keys,
    };
    if (remaining.isEmpty) {
      remove(key);
    } else if (issues.isEmpty) {
      if (previous != null) {
        _alerts[key] = previous.copyWith(
          connectorNames: remaining.toList(),
          lastKnown: true,
        );
      }
    } else {
      _put(
        key,
        'Connector runtime',
        '${ConnectorRuntimeObservation.describeIssues(issues.values)}${remaining.length > issues.length ? ' · Earlier failures still unconfirmed' : ''}',
        HealthAlertScope.profile,
        HealthAlertSeverity.warning,
        runtime.receivedAt,
        profileName: profile,
        destination: 'MCP connectors',
        connectorNames: remaining.toList(),
      );
    }
  }

  void unknown(String key) {
    _periods.remove(key);
    if (_alerts[key] case final alert?) {
      _alerts[key] = alert.copyWith(lastKnown: true);
    }
  }

  void _put(
    String key,
    String title,
    String detail,
    HealthAlertScope scope,
    HealthAlertSeverity severity,
    DateTime at, {
    String? profileName,
    HealthAlertTrigger? trigger,
    String? destination,
    List<String> connectorNames = const [],
  }) {
    final old = _alerts[key];
    final escalated = old == null || severity.index > old.severity.index;
    _alerts[key] = HealthAlert(
      id: key,
      connectionIdentity: connectionIdentity,
      connectionLabel: connectionLabel,
      scope: scope,
      title: title,
      detail: detail,
      severity: severity,
      observedAt: at,
      profileName: profileName,
      destination: destination,
      connectorNames: List.unmodifiable(connectorNames),
      trigger: escalated ? trigger : old.trigger,
      occurrence: escalated ? ++_occurrence : old.occurrence,
      acknowledged: !escalated && old.acknowledged,
      snoozedUntil: escalated ? null : old.snoozedUntil,
    );
  }

  void acknowledge(String id, int occurrence) {
    if (_alerts[id] case final alert? when alert.occurrence == occurrence) {
      _alerts[id] = alert.copyWith(acknowledged: true);
    }
  }

  void snooze(String id, int occurrence, DateTime until) {
    if (_alerts[id] case final alert? when alert.occurrence == occurrence) {
      _alerts[id] = alert.copyWith(snoozedUntil: until);
    }
  }
}

class _Period {
  _Period(this.start, this.last, this.clearing);
  final DateTime start;
  DateTime last;
  final bool clearing;
}
