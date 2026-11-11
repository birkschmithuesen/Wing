import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/health_alert.dart';
import '../models/health_alert_evaluator.dart';
import '../models/health_finding.dart';
import '../models/host_resources.dart';
import '../models/host_thresholds.dart';
import 'administration_health.dart';
import 'health_alert_settings_session.dart';
import 'health_alert_incident_store.dart';
import 'host_resources_session.dart';
import 'server_connection_status.dart';

enum _AlertChoice { acknowledge, snooze, unacknowledge, unsnooze }

/// Connection-owned evaluator borrowing canonical observations. Owns only its
/// watch demand and incidents; never runs diagnostics. Inventory recovery reads
/// join the same connection owner used by the connector editor and Health.
class HealthAlertsSession extends ChangeNotifier {
  HealthAlertsSession({
    required this.host,
    required this.connectionStatus,
    required this.health,
    required this.settings,
    required this.incidents,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _evaluator = HealthAlertEvaluator(
         connectionIdentity: host.connectionIdentity,
         connectionLabel: host.scopeLabel,
       ) {
    try {
      _evaluator.restore(incidents.read(host.connectionIdentity));
    } catch (_) {
      _error =
          'Saved health alerts could not be read. Acknowledge again to save.';
    }
    _durableState = _incidentState(alerts);
    _watch = host.watch(interval: const Duration(seconds: 15), active: false);
    _lastSettings = settings.settings;
    host.addListener(_changed);
    connectionStatus.addListener(_changed);
    health.addListener(_changed);
    health.server.connectorInventory.addListener(_changed);
    settings.addListener(_settingsChanged);
    _changed();
  }
  final HostResourcesSession host;
  final ServerConnectionStatus connectionStatus;
  final AdministrationHealth health;
  final HealthAlertSettingsSession settings;
  final HealthAlertIncidentStore incidents;
  bool _closed = false, _saving = false;
  String? _error;
  HealthAlert? _pendingChoice;
  bool get saving => _saving;
  String? get error => _error;
  List<Object>? _durableState;
  final DateTime Function() _now;
  final HealthAlertEvaluator _evaluator;
  late final HostResourcesWatch _watch;
  bool _active = false;
  Timer? _connectorRecheck;
  bool _checkingConnectors = false;

  /// Recovery checks read configuration membership only, never connection probes.
  Future<void> refreshConnectorInventories() async {
    if (_closed || !_active || _checkingConnectors) return;
    final profiles = alerts
        .where((alert) => alert.destination == 'MCP connectors')
        .map((alert) => alert.profileName)
        .whereType<String>()
        .toSet();
    if (profiles.isEmpty) return;
    _checkingConnectors = true;
    _connectorRecheck?.cancel();
    _connectorRecheck = null;
    health.server.retain();
    try {
      await Future.wait([
        for (final profile in profiles)
          () async {
            try {
              await health.server.connectorInventory.refresh(profile);
            } catch (_) {
              // An unavailable inventory cannot establish incident recovery.
            }
          }(),
      ]);
    } finally {
      health.server.release();
      _checkingConnectors = false;
      if (!_closed) _publish();
    }
  }

  void _scheduleConnectorRecheck() {
    final needed =
        _active && alerts.any((a) => a.destination == 'MCP connectors');
    if (!needed) {
      _connectorRecheck?.cancel();
      _connectorRecheck = null;
    } else if (!_checkingConnectors && _connectorRecheck == null) {
      _connectorRecheck = Timer(const Duration(seconds: 15), () {
        _connectorRecheck = null;
        unawaited(refreshConnectorInventories());
      });
    }
  }

  HealthAlertSettings? _lastSettings;
  (HostReading<HostSystemStats>, HostReading<HostPressureStatus>)?
  _evaluatedHost;
  (HostReading<HostSystemStats>, HostReading<HostPressureStatus>)?
  _observedHostReads;
  List<HealthAlert> get alerts => _evaluator.alerts;
  List<Object> _published = const [];
  bool get _wantsHost =>
      settings.settings.enabled &&
      settings.settings.rules.values.any(
        (rule) => rule.enabled || rule.nativeCriticalEnabled,
      );
  void setActive(bool value) {
    if (_active == value) return;
    _active = value;
    _watch.setActive(value && _wantsHost);
    if (value) {
      // Another consumer may have kept the shared watch active. Always request
      // a fresh, coalesced read before resuming threshold evaluation.
      if (_wantsHost) unawaited(host.refresh());
      _changed();
    } else {
      _evaluator.pause();
      _publish();
    }
  }

  void _settingsChanged() {
    if (identical(_lastSettings, settings.settings)) return;
    final previous = _lastSettings;
    _lastSettings = settings.settings;
    for (final metric in hostAlertMetrics) {
      final old = previous?.rules[metric];
      final rule = settings.settings.rules[metric]!;
      if (old == null ||
          (
                old.enabled,
                old.warnAbove,
                old.clearBelow,
                old.alertMinutes,
                old.clearMinutes,
              ) !=
              (
                rule.enabled,
                rule.warnAbove,
                rule.clearBelow,
                rule.alertMinutes,
                rule.clearMinutes,
              )) {
        _evaluator.restartHostWarning(metric);
      }
    }
    // A new rule starts a new sustained period under its own limits.
    _evaluatedHost = null;
    _watch.setActive(_active && _wantsHost);
    _changed();
  }

  void _changed() {
    final policy = settings.settings;
    final data = host.state;
    if (_active) _observeConnection();
    _observeHostReads(data);
    // Disabled scopes remove their incidents even while collection is paused.
    for (final alert in alerts) {
      if (alert.scope == HealthAlertScope.profile && !policy.profile) {
        _evaluator.remove(alert.id);
      }
    }
    if (policy.enabled) {
      for (final metric in hostAlertMetrics) {
        _evaluator.applyHostRule(metric, policy.rules[metric]!);
      }
    } else {
      _evaluator.clearHostAlerts();
    }
    if (!_active) {
      _publish();
      return;
    }
    final now = _now();
    final observation = (data.stats, data.pressure);
    if (policy.enabled && !data.refreshing && _evaluatedHost != observation) {
      // Repeated owner notifications are not new host samples. In particular,
      // an aging cached reading must not cancel a retained pending period.
      _evaluatedHost = observation;
      final current = data.stats.isCurrent(now, const Duration(seconds: 30));
      final values = HostThresholdPolicy([
        for (final metric in hostAlertMetrics)
          HostThreshold(metric, policy.rules[metric]!.warnAbove),
      ]).evaluate(data.stats, now: now);
      final pressure = data.pressure.isCurrent(now, const Duration(seconds: 30))
          ? data.pressure.value
          : null;
      for (final result in values) {
        final metric = result.threshold.metric;
        final reported = switch (metric) {
          HostMetric.memoryUsedPercent => pressure?.memoryAt(now),
          HostMetric.diskUsedPercent => pressure?.disk,
          _ => HostPressure.ok,
        };
        _evaluator.host(
          metric: metric,
          rule: policy.rules[metric]!,
          now: now,
          sampledAt: current
              ? data.stats.readAt
              : reported == HostPressure.critical
              ? data.pressure.readAt
              : null,
          value: result.value,
          critical: reported == HostPressure.critical,
          pressureKnown: reported != null && reported != HostPressure.unknown,
        );
      }
    }
    for (final alert in alerts) {
      if (alert.scope == HealthAlertScope.profile &&
          alert.profileName != health.profileName) {
        _evaluator.unknown(alert.id);
      }
    }
    if (policy.profile) {
      final inventories = health.server.connectorInventory.observations;
      final currentInventories = {
        for (final entry in inventories.entries)
          if (!now.isBefore(entry.value.checkedAt) &&
              now.difference(entry.value.checkedAt) < health.maxAge)
            entry.key: entry.value,
      };
      for (final entry in currentInventories.entries) {
        _evaluator.reconcileConnectors(entry.key, entry.value);
      }
      final connectorProfiles = {
        ...currentInventories.keys,
        for (final alert in alerts)
          if (alert.destination == 'MCP connectors') ?alert.profileName,
      };
      for (final profile in connectorProfiles) {
        final runtime =
            health.server.connectorInventory.runtimeObservations[profile];
        final currentRuntime =
            runtime != null &&
            health.server.connectorInventory.runtimeError(profile) == null &&
            !now.isBefore(runtime.receivedAt) &&
            now.difference(runtime.receivedAt) < health.maxAge;
        _evaluator.connectorRuntime(
          profile,
          currentRuntime ? runtime : null,
          currentInventories[profile],
        );
      }
      final findings = [
        for (final entry in health.scheduledTaskFindings.entries)
          (entry.key, entry.value, const <String>[]),
        if (health.profileName case final name?)
          for (final finding in [
            for (final value in health.profileFindings)
              if (value.title != 'Connector settings') value,
            ?health.connectorProbeFinding,
          ])
            if (finding.destination != 'Scheduled tasks')
              (
                name,
                finding,
                finding.destination == 'MCP connectors'
                    ? health.failedConnectorNames
                    : const <String>[],
              ),
      ];
      for (final (name, finding, connectors) in findings) {
        final at = finding.checkedAt;
        final current =
            at != null &&
            !now.isBefore(at) &&
            now.difference(at) < health.maxAge;
        final taskUnknown =
            finding.destination == 'Scheduled tasks' && !current;
        _evaluator.finding(
          key: '${host.connectionIdentity}:profile:$name:${finding.title}',
          title: finding.title,
          detail: finding.detail,
          scope: HealthAlertScope.profile,
          profileName: name,
          destination: finding.destination,
          connectorNames: connectors,
          connectorInventory: currentInventories[name],
          at: at,
          failed:
              taskUnknown ||
                  at == null ||
                  now.isBefore(at) ||
                  finding.status == AdministrationHealthStatus.unknown
              ? null
              : finding.status == AdministrationHealthStatus.failure ||
                    finding.status == AdministrationHealthStatus.warning,
          severity: finding.status == AdministrationHealthStatus.failure
              ? HealthAlertSeverity.critical
              : HealthAlertSeverity.warning,
        );
        if (!current) {
          _evaluator.unknown(
            '${host.connectionIdentity}:profile:$name:${finding.title}',
          );
        }
      }
    }
    _publish();
  }

  void _observeConnection() {
    _evaluator.finding(
      key: '${host.connectionIdentity}:connection',
      title: 'Connection interrupted',
      detail: 'Updates may be delayed. Open connection details to retry.',
      scope: HealthAlertScope.connection,
      destination: 'Connection details',
      at: _now(),
      failed: switch (connectionStatus.transportAvailability) {
        ConnectionAvailability.unavailable => true,
        ConnectionAvailability.available => false,
        ConnectionAvailability.unchecked => null,
      },
    );
  }

  void _observeHostReads(HostResourcesState data) {
    final reads = (data.stats, data.pressure);
    if (data.refreshing ||
        data.attemptedAt == null ||
        _observedHostReads == reads) {
      return;
    }
    _observedHostReads = reads;
    for (final (scope, title, reading) in [
      ('host-stats', 'Host resources could not refresh', data.stats),
      ('host-pressure', 'Host pressure could not refresh', data.pressure),
    ]) {
      final failed = reading.error != null;
      if (!failed && reading.readAt == null) continue;
      _recordOperationalError(
        scope: scope,
        title: title,
        detail: 'Open Hermes health to try again.',
        failed: failed,
        destination: 'Host resources',
      );
    }
  }

  /// Observe settlement from the existing operation owner. A successful
  /// observation clears only its captured scope on this connection.
  void observeOperationalError({
    required String scope,
    required String title,
    required String detail,
    required bool failed,
    String? destination,
    String? profileName,
  }) {
    if (_closed) return;
    _recordOperationalError(
      scope: scope,
      title: title,
      detail: detail,
      failed: failed,
      destination: destination,
      profileName: profileName,
    );
    _publish();
  }

  void _recordOperationalError({
    required String scope,
    required String title,
    required String detail,
    required bool failed,
    String? destination,
    String? profileName,
  }) {
    if (!_active &&
        !failed &&
        connectionStatus.transportAvailability ==
            ConnectionAvailability.available) {
      // A reader can confirm recovery before its workspace starts monitoring.
      _observeConnection();
    }
    if (failed &&
        connectionStatus.access == ConnectionAvailability.unavailable) {
      // The confirmed outage already represents the failed background read.
      // A separate incident is admitted only by a failure outside that outage.
      _observeConnection();
    } else {
      _evaluator.finding(
        key: '${host.connectionIdentity}:operational:$scope',
        title: title,
        detail: detail,
        scope: HealthAlertScope.operational,
        destination: destination,
        profileName: profileName,
        at: _now(),
        failed: failed,
      );
    }
  }

  Future<void> acknowledge(HealthAlert alert) =>
      _saveChoice(alert, _AlertChoice.acknowledge);

  Future<void> snooze(HealthAlert alert) =>
      _saveChoice(alert, _AlertChoice.snooze);

  Future<void> unacknowledge(HealthAlert alert) =>
      _saveChoice(alert, _AlertChoice.unacknowledge);

  Future<void> unsnooze(HealthAlert alert) =>
      _saveChoice(alert, _AlertChoice.unsnooze);

  Future<void> _saveChoice(HealthAlert alert, _AlertChoice choice) async {
    if (_closed || _saving) return;
    final current = alerts.where((a) => a.id == alert.id).firstOrNull;
    if (current == null || current.occurrence != alert.occurrence) return;
    final now = _now();
    final HealthAlertSilencing? silencing = switch (choice) {
      _AlertChoice.acknowledge when !current.acknowledged => (
        acknowledged: true,
        snoozedUntil: null,
      ),
      _AlertChoice.snooze when current.remindsAt(now) => (
        acknowledged: false,
        snoozedUntil: now.add(const Duration(minutes: 30)),
      ),
      _AlertChoice.unacknowledge when current.acknowledged => (
        acknowledged: false,
        snoozedUntil: null,
      ),
      _AlertChoice.unsnooze
          when !current.acknowledged && !current.remindsAt(now) =>
        (acknowledged: false, snoozedUntil: null),
      _ => null,
    };
    if (silencing == null) return;
    final target = current.copyWith(silencing: silencing);
    _saving = true;
    _pendingChoice = target;
    _error = null;
    notifyListeners();
    final snapshot = [for (final a in alerts) a.id == alert.id ? target : a];
    // Submit before yielding so later recovery/escalation writes follow it.
    _durableState = _incidentState(snapshot);
    try {
      await incidents.write(host.connectionIdentity, snapshot);
      if (!_closed) {
        _error = null;
        _evaluator.applySilencing(target);
      }
    } catch (_) {
      if (!_closed) {
        _durableState = null;
        _error = 'Could not save this choice. Please try again.';
      }
    } finally {
      _saving = false;
      _pendingChoice = null;
      if (!_closed) {
        // A recovered/escalated occurrence must win over a held user save.
        _publish();
        notifyListeners();
      }
    }
  }

  List<Object> _incidentState(List<HealthAlert> values) => [
    for (final a in values) ...<Object>[
      (a.id, a.occurrence, a.severity, a.acknowledged, a.snoozedUntil),
      ...a.connectorNames,
    ],
  ];

  void _persistIncidents() {
    // Fresh detail notifications must not queue an unsilenced snapshot behind
    // a pending user choice. A replacement occurrence never inherits that choice.
    final pending = _pendingChoice;
    final snapshot = [
      for (final a in alerts)
        pending != null &&
                a.id == pending.id &&
                a.occurrence == pending.occurrence
            ? a.copyWith(silencing: pending.silencing)
            : a,
    ];
    final state = _incidentState(snapshot);
    if (listEquals(state, _durableState)) return;
    _durableState = state;
    final write = incidents.write(host.connectionIdentity, snapshot);
    unawaited(
      write.catchError((Object _) {
        if (_closed) return;
        if (listEquals(state, _durableState)) _durableState = null;
        _error = 'Could not save health alerts. Please try again.';
        notifyListeners();
      }),
    );
  }

  void _publish() {
    _scheduleConnectorRecheck();
    _persistIncidents();
    final next = alerts
        .expand(
          (a) => <Object>[
            (
              a.id,
              a.title,
              a.detail,
              a.scope,
              a.severity,
              a.observedAt,
              a.occurrence,
              a.profileName,
              a.destination,
              a.connectorNames.length,
              a.trigger,
              a.lastKnown,
              a.acknowledged,
              a.snoozedUntil,
            ),
            ...a.connectorNames,
          ],
        )
        .toList();
    if (listEquals(_published, next)) return;
    _published = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _connectorRecheck?.cancel();
    _watch.close();
    host.removeListener(_changed);
    connectionStatus.removeListener(_changed);
    health.removeListener(_changed);
    health.server.connectorInventory.removeListener(_changed);
    settings.removeListener(_settingsChanged);
    super.dispose();
  }
}
