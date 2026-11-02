import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_diagnostics_controller.dart';
import 'administration_health.dart';
import 'administration_overview.dart';
import 'administration_repository.dart';
import 'health_snapshot.dart';
import 'profile_gateway.dart';
import 'scheduled_tasks_controller.dart';
import 'server_connection_status.dart';

/// Connection-owned health work outlives routes. Disk snapshots also retain
/// completed observations across launches, with a separate clock per profile.
class AdministrationHealthSession extends ChangeNotifier {
  AdministrationHealthSession(
    this.server,
    this.preferences, {
    ServerConnectionStatus? connectionStatus,
    DateTime Function()? now,
    this.ownsServer = false,
  }) : _now = now ?? DateTime.now,
       health = AdministrationHealth(
         server,
         connectionStatus: connectionStatus,
         now: now,
       ) {
    final saved = preferences.getString(_key);
    if (saved != null) {
      try {
        final value = jsonDecode(saved) as Map;
        health.restore(value['health'] as Map);
        _savedProfiles.addAll(
          Map<String, dynamic>.from(value['profiles'] as Map),
        );
      } on Object {
        // A damaged local snapshot is not evidence of a completed check.
        _savedProfiles.clear();
      }
    }
    health.addListener(_changed);
    server.connectorInventory.addListener(_connectorsChanged);
  }

  final AdministrationRepository server;
  final SharedPreferences preferences;
  final AdministrationHealth health;
  final bool ownsServer;
  final DateTime Function() _now;
  final _overviews = <String, AdministrationOverview>{};
  Map<String, AdministrationOverview> get overviews =>
      Map.unmodifiable(_overviews);
  final _tasks = <String, ScheduledTasksController>{};
  final _taskListeners = <String, VoidCallback>{};
  final _checks = <String, ProfileDiagnosticsController>{};
  final _refreshedAt = <String, DateTime>{};
  final _refreshes = <String, Future<void>>{};
  final _savedProfiles = <String, dynamic>{};
  bool _disposed = false;
  Future<void> _saveQueue = Future.value();
  String? _persistenceError;
  String? get persistenceError => _persistenceError;

  String get _key =>
      'health-results:v2:${server.profile('default').scope.storageNamespace}';
  Future<void> get saved => _saveQueue;
  bool checking(String? name) => _refreshes.containsKey(name);
  DateTime? checkedAt(String? name) => _refreshedAt[name];

  void _requireConnection(ProfileGateway gateway) {
    if (gateway.scope.connectionId != server.connectionId ||
        gateway.scope.connectionIdentity != server.connectionIdentity) {
      throw ArgumentError('Health belongs to another connection');
    }
  }

  ProfileDiagnosticsController checksFor(ProfileGateway gateway) {
    _requireConnection(gateway);
    final name = gateway.scope.profileName;
    final checks = _checks.putIfAbsent(name, () {
      final checks = ProfileDiagnosticsController(gateway: gateway);
      final snapshot = _savedProfiles[name];
      if (snapshot != null && snapshot['checks'] != null) {
        try {
          checks.restore(snapshot['checks'] as Map);
        } on Object {
          _refreshedAt.remove(name);
        }
      }
      checks.addListener(() {
        health.updateProfileChecks(checks.healthObservation);
      });
      return checks;
    });
    checks.updateGateway(gateway);
    return checks;
  }

  void select(ProfileGateway? gateway) {
    if (_disposed) return;
    if (gateway == null) {
      health.selectProfile(null);
      return;
    }
    _requireConnection(gateway);
    final name = gateway.scope.profileName;
    final overview = _overviewFor(name);
    final checks = checksFor(gateway);
    checks.updateModel(overview.observations['model']?.data);
    // Attach independently of full-check expiry. The task list may already
    // hold a newer result, which must win before publishing restored findings.
    final tasks = _tasksFor(overview.profile);
    if (tasks.tasks != null) health.updateTasks(tasks);
    health.selectProfile(overview);
    health.updateProfileChecks(checks.healthObservation);
    if (healthSnapshotExpired(_refreshedAt[name], _now()) ||
        checks.healthObservation.finding == null) {
      unawaited(refresh(gateway));
    }
  }

  AdministrationOverview _overviewFor(String name) =>
      _overviews.putIfAbsent(name, () {
        final overview = AdministrationOverview(server.profile(name));
        final snapshot = _savedProfiles[name];
        if (snapshot != null) {
          try {
            overview.restoreHealth(snapshot['overview'] as Map);
            final at = healthSnapshotTime(snapshot['refreshedAt']);
            if (at != null) _refreshedAt[name] = at;
          } on Object {
            _savedProfiles.remove(name);
          }
        }
        overview.addListener(() {
          _checks[name]?.updateModel(overview.observations['model']?.data);
          _changed();
        });
        return overview;
      });

  void _connectorsChanged() {
    if (_disposed) return;
    // Unopened profiles still have saved probe failures. Restore their existing
    // observation owner to reconcile/persist membership, without selecting the
    // profile or starting diagnostics. Otherwise a second restart resurrects it.
    for (final name in server.connectorInventory.observations.keys) {
      if (_savedProfiles.containsKey(name)) _overviewFor(name);
    }
    _changed();
  }

  ScheduledTasksController _tasksFor(ProfileAdministration profile) =>
      _tasks.putIfAbsent(profile.name, () {
        final source = ScheduledTasksController.acquire(profile, preferences);
        void listener() {
          if (!_disposed) health.updateTasks(source);
        }

        _taskListeners[profile.name] = listener;
        source.addListener(listener);
        return source;
      });

  /// Recheck a retained task issue without selecting its profile or launching
  /// provider, connector or server diagnostics. Borrow the list's shared owner.
  Future<void> refreshScheduledTasks(String profileName) {
    if (_disposed) return Future.value();
    final source = _tasksFor(server.profile(profileName));
    if (source.tasks != null) health.updateTasks(source);
    return source.loading ? Future.value() : source.refresh();
  }

  Future<void> refresh(ProfileGateway gateway) {
    if (_disposed) return Future.value();
    _requireConnection(gateway);
    final name = gateway.scope.profileName;
    final overview = _overviews[name];
    if (overview == null) return Future.value();
    if (_refreshes[name] case final pending?) return pending;
    final checks = checksFor(gateway);
    final tasks = _tasksFor(overview.profile);
    // Schedule after registering the future so synchronous notifications cannot
    // expose an enabled refresh button while this work is already underway.
    final refresh =
        Future<void>.microtask(() async {
          await Future.wait([
            () async {
              await overview.refresh(keys: {'model'});
              if (!_disposed) await checks.check();
            }(),
            overview.refresh(keys: {'access', 'tools'}),
            overview.refresh(keys: {'connectors'}, testConnectors: true),
            tasks.refresh(),
            health.refreshReadiness(profile: overview.profile),
          ]);
          if (!_disposed) {
            _refreshedAt[name] = _now();
          }
        }).whenComplete(() {
          _refreshes.remove(name);
          _changed();
        });
    _refreshes[name] = refresh;
    _changed();
    return refresh;
  }

  /// The editor and its follow-up reads keep the admitted profile, even if the
  /// visible selection changes. An invalidated older pass must settle before
  /// starting observations of the configuration left by the editor.
  Future<void> reviewAccess(
    ProfileGateway gateway,
    Future<void> Function(ProfileAdministration profile) openEditor,
  ) async {
    if (_disposed) return;
    _requireConnection(gateway);
    final name = gateway.scope.profileName;
    final checks = checksFor(gateway);
    await openEditor(server.profile(name));
    if (_disposed) return;
    checks.invalidate();
    final pending = _refreshes[name];
    if (pending != null) await pending;
    if (_disposed) return;
    // The older pass may have still been reading its model when invalidated.
    // Clear any observation it started later before the fresh captured pass.
    checks.invalidate();
    await refresh(gateway);
  }

  void _changed() {
    if (_disposed) return;
    _persist();
    notifyListeners();
  }

  void _persist() {
    final profiles = Map<String, dynamic>.of(_savedProfiles);
    for (final entry in _overviews.entries) {
      profiles[entry.key] = {
        'overview': entry.value.healthSnapshot(),
        'checks':
            _checks[entry.key]?.snapshot() ??
            _savedProfiles[entry.key]?['checks'],
        'refreshedAt': _refreshedAt[entry.key]?.toUtc().toIso8601String(),
      };
    }
    final encoded = jsonEncode({
      'health': health.snapshot(),
      'profiles': profiles,
    });
    _saveQueue = _saveQueue
        .then((_) async {
          if (!await preferences.setString(_key, encoded)) {
            throw StateError('Health snapshot was not saved');
          }
          _persistenceError = null;
        })
        .catchError((Object _) {
          _persistenceError = 'Could not save Health results on this device.';
          if (!_disposed) notifyListeners();
        });
  }

  @override
  void dispose() {
    _persist();
    _disposed = true;
    server.connectorInventory.removeListener(_connectorsChanged);
    health.dispose();
    for (final overview in _overviews.values) {
      overview.dispose();
    }
    for (final checks in _checks.values) {
      checks.dispose();
    }
    for (final entry in _tasks.entries) {
      entry.value.removeListener(_taskListeners[entry.key]!);
      entry.value.release();
    }
    if (ownsServer) server.close();
    super.dispose();
  }
}
