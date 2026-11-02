import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/health_alert.dart';
import 'background_monitoring_service.dart';
import 'health_alert_settings_session.dart';
import 'health_alerts_session.dart';
import 'health_alert_incident_store.dart';
import 'profile_workspace_controller.dart';
import 'profile_workspace_registry.dart';

/// Application lifetime and aggregate only. Connection sessions own incidents;
/// the existing monitoring service determines whether background work is alive.
class HealthAlertsCoordinator extends ChangeNotifier {
  HealthAlertsCoordinator({
    required this.registry,
    required this.settings,
    required this.monitoring,
    required this.incidents,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    registry.addListener(_reconcile);
    monitoring.addListener(_reconcile);
    settings.addListener(_reconcile);
    _reconcile();
  }
  final ProfileWorkspaceRegistry registry;
  final HealthAlertSettingsSession settings;
  final HealthAlertIncidentStore incidents;
  final ValueListenable<BackgroundMonitoringState> monitoring;
  final DateTime Function() _now;
  DateTime get now => _now();
  Timer? _reminder;
  final _sessions = <ProfileWorkspaceController, HealthAlertsSession>{};
  final _listeners = <ProfileWorkspaceController, VoidCallback>{};
  final _activeOwners = <ProfileWorkspaceController>{};
  bool _foreground = true, _closed = false;
  List<HealthAlert> get alerts {
    final result = _sessions.values.expand((s) => s.alerts).toList();
    result.sort((a, b) {
      final severity = b.severity.index.compareTo(a.severity.index);
      return severity != 0 ? severity : a.id.compareTo(b.id);
    });
    return List.unmodifiable(result);
  }

  /// Unresolved occurrences that currently need the user's attention, in the
  /// same severity order as [alerts]. Silenced issues remain available to review.
  List<HealthAlert> get attentionAlerts {
    final time = now;
    return List.unmodifiable(alerts.where((alert) => alert.remindsAt(time)));
  }

  void setForeground(bool value) {
    if (value && !_foreground) _activeOwners.clear();
    _foreground = value;
    _reconcile();
  }

  void _reconcile() {
    if (_closed) return;
    final owners = registry.controllers.toSet();
    for (final owner in _sessions.keys.toList()) {
      if (owners.contains(owner)) continue;
      owner.removeListener(_listeners.remove(owner)!);
      final session = _sessions.remove(owner)!;
      _activeOwners.remove(owner);
      session.removeListener(_changed);
      session.dispose();
    }
    for (final owner in owners) {
      if (!owner.initialized && !_sessions.containsKey(owner)) continue;
      _sessions.putIfAbsent(owner, () {
        final session = HealthAlertsSession(
          host: owner.hostResources(),
          health: owner.healthSession().health,
          settings: settings,
          incidents: incidents,
          now: _now,
        );
        void changed() => _ownerChanged(owner);
        _listeners[owner] = changed;
        owner.addListener(changed);
        session.addListener(_changed);
        return session;
      });
      _ownerChanged(owner);
    }
    _changed();
  }

  void _ownerChanged(ProfileWorkspaceController owner) {
    final background =
        monitoring.value == BackgroundMonitoringState.active ||
        monitoring.value == BackgroundMonitoringState.batteryRestricted;
    final active =
        _foreground && owner.hasMountedRoutes ||
        background && owner.hasActiveChats;
    _sessions[owner]?.setActive(active);
    final resumed = active ? _activeOwners.add(owner) : false;
    if (!active) _activeOwners.remove(owner);
    if (resumed && settings.settings.enabled && settings.settings.profile) {
      unawaited(_sessions[owner]!.refreshConnectorInventories());
      // Acknowledged incidents still need recovery checks. Use their captured
      // profiles, including those that are not selected in the workspace.
      final profiles = _sessions[owner]!.alerts
          .where((alert) => alert.destination == 'Scheduled tasks')
          .map((alert) => alert.profileName)
          .whereType<String>()
          .toSet();
      for (final name in profiles) {
        unawaited(owner.healthSession().refreshScheduledTasks(name));
      }
    }
    // Borrow existing profile observations. Selection may perform its existing
    // initial/expired access checks; never start server doctor/audit in a watcher.
    if (active &&
        owner.current != null &&
        settings.settings.profile &&
        settings.settings.enabled &&
        owner.healthSession().health.profileName !=
            owner.current!.scope.profileName) {
      owner.healthSession().select(owner.current!.gateway);
    }
  }

  void _changed() {
    if (_closed) return;
    _reminder?.cancel();
    _reminder = null;
    if (_foreground ||
        monitoring.value == BackgroundMonitoringState.active ||
        monitoring.value == BackgroundMonitoringState.batteryRestricted) {
      final time = now;
      final deadlines =
          alerts
              .where(
                (a) =>
                    !a.acknowledged &&
                    a.snoozedUntil != null &&
                    a.snoozedUntil!.isAfter(time),
              )
              .map((a) => a.snoozedUntil!)
              .toList()
            ..sort();
      if (deadlines.isNotEmpty) {
        _reminder = Timer(deadlines.first.difference(time), _changed);
      }
    }
    notifyListeners();
  }

  ProfileWorkspaceController? ownerFor(HealthAlert alert) => _sessions.keys
      .where((owner) => owner.connectionIdentity == alert.connectionIdentity)
      .firstOrNull;
  bool get saving => _sessions.values.any((session) => session.saving);
  String? error(HealthAlert alert) => _sessions[ownerFor(alert)]?.error;
  Future<void> acknowledge(HealthAlert alert) async =>
      _sessions[ownerFor(alert)]?.acknowledge(alert);
  Future<void> snooze(HealthAlert alert) async =>
      _sessions[ownerFor(alert)]?.snooze(alert);
  @override
  void dispose() {
    _closed = true;
    _reminder?.cancel();
    registry.removeListener(_reconcile);
    monitoring.removeListener(_reconcile);
    settings.removeListener(_reconcile);
    for (final e in _sessions.entries) {
      e.key.removeListener(_listeners[e.key]!);
      e.value.removeListener(_changed);
      e.value.dispose();
    }
    _sessions.clear();
    _activeOwners.clear();
    super.dispose();
  }
}
