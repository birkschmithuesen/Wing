import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/health_finding.dart';
import '../models/administration_operation.dart';
import 'administration_operation_session.dart';
import '../models/provider_access.dart';
import '../models/profile_connectors.dart';
import 'administration_overview.dart';
import 'administration_repository.dart';
import 'scheduled_tasks_controller.dart';
import 'server_connection_status.dart';
import 'health_snapshot.dart';

/// Connection-owned, bounded observations. Reading this model never performs
/// diagnostics or duplicates the selected profile's overview requests.
class AdministrationHealth extends ChangeNotifier {
  AdministrationHealth(
    this.server, {
    this.maxAge = const Duration(minutes: 5),
    this.connectionStatus,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    connectionStatus?.addListener(_changed);
  }

  final AdministrationRepository server;
  final Duration maxAge;
  final ServerConnectionStatus? connectionStatus;
  final DateTime Function() _now;
  AdministrationOverview? _overview;
  final _profiles = <String, _ProfileHealthState>{};
  _ProfileHealthState get _profileState =>
      _profiles.putIfAbsent(profileName!, _ProfileHealthState.new);
  AdministrationHealthFinding? get _profileChecks => _profileState.checks;
  Timer? _expiry;
  bool _disposed = false;
  int _notificationDepth = 0;
  AdministrationObservation get _readiness => _profileState.readiness;
  final _diagnosticGenerations = <String, int>{};
  final _operations = <String, AdministrationOperationSession>{};
  final _operationListeners = <String, VoidCallback>{};
  final _diagnosticScopes = <String, String>{};
  final _diagnosticAttempts = <String, DateTime>{};
  final _attemptedGenerations = <String, int>{};
  final _starting = <String>{};
  final _startErrors = <String, String>{};
  String? diagnosticStartError(String path) => _startErrors[path];
  DateTime? _serverCheckedAt;
  DateTime? _serverRefreshStartedAt;
  final _serverRefreshGenerations = <String, int>{};
  final _observedGenerations = <String, int>{};
  static const diagnosticPaths = ['ops/doctor', 'ops/security-audit'];

  DateTime? get serverCheckedAt => _serverCheckedAt;
  DateTime? get serverAttemptedAt {
    final times = _diagnosticAttempts.values.toList()..sort();
    return times.lastOrNull;
  }

  bool get serverChecking =>
      _starting.isNotEmpty ||
      diagnostics.values.any(
        (value) => value.running == true && !value.resultUnavailable,
      );

  bool get serverCheckIncomplete =>
      diagnosticPaths.any((path) {
        final value = diagnostics[path];
        final attempted = _diagnosticAttempts[path];
        return value == null ||
            value.readError != null ||
            value.running != false ||
            value.exitCode == null ||
            value.checkedAt == null ||
            (_attemptedGenerations[path] != null &&
                _observedGenerations[path] != _attemptedGenerations[path]) ||
            (attempted != null && value.checkedAt!.isBefore(attempted));
      }) ||
      _serverRefreshStartedAt != null;

  /// Only a refresh of both diagnostics advances the shared completion time.
  void _beginServerRefresh() {
    _serverRefreshStartedAt = _now();
    _serverRefreshGenerations
      ..clear()
      ..addEntries(
        diagnosticPaths.map(
          (path) => MapEntry(path, (_diagnosticGenerations[path] ?? 0) + 1),
        ),
      );
    _changed();
  }

  bool get profileCheckIncomplete {
    if (profileName == null) return true;
    final findings = profileFindings;
    final tools = _overview?.observations['tools']?.data?['data'];
    return [
          'Model selection',
          'Provider credential check',
          'Tool setup',
          'Connector settings',
          'Scheduled tasks',
        ].any((title) {
          final finding = findings.where((f) => f.title == title).firstOrNull;
          return finding == null ||
              finding.status == AdministrationHealthStatus.unknown;
        }) ||
        _overview?.observations['model']?.error != null ||
        _overview?.observations['tools']?.error != null ||
        _overview?.observations['connectors']?.error != null ||
        _profileState.taskError != null ||
        (tools is List &&
            tools.any(
              (row) =>
                  row is! Map ||
                  row['enabled'] is! bool ||
                  row['enabled'] == true && row['configured'] is! bool,
            )) ||
        _overview!.connectorChecks.values.any((value) => value == null);
  }

  ModelAccessObservation get modelAccess =>
      _overview?.modelAccess ?? const ModelAccessObservation();
  String? get profileName => _overview?.profile.name;
  List<String> get failedConnectorNames {
    final rows = _overview?.observations['connectors']?.data?['servers'];
    if (rows is! List) return const [];
    return List.unmodifiable([
      for (final row in rows)
        if (row is Map &&
            row['enabled'] == true &&
            row['name'] is String &&
            _overview?.connectorChecks[row['name']] == false)
          row['name'] as String,
    ]);
  }

  Map<String, AdminDiagnosticObservation> get diagnostics => Map.unmodifiable({
    for (final entry in _operations.entries)
      entry.key: entry.value.state.observation,
  });
  AdministrationOperationSession? diagnosticOperation(String path) =>
      _operations[path];
  Set<String> get starting => Set.unmodifiable(_starting);
  String? diagnosticScope(String path) => _diagnosticScopes[path];
  bool hasAttemptedDiagnostic(String path) =>
      _diagnosticAttempts.containsKey(path);
  void _recordDiagnosticAttempt(String path) {
    if (_disposed || !_starting.contains(path)) return;
    _diagnosticAttempts[path] = _now();
    _attemptedGenerations[path] = _diagnosticGenerations[path]!;
    _changed();
  }

  bool diagnosticNeedsRefresh(String path) {
    final observation = diagnostics[path];
    return canStartDiagnostic(path) &&
        (observation == null
            ? !hasAttemptedDiagnostic(path)
            : observation.terminal &&
                  healthSnapshotExpired(observation.checkedAt, _now()));
  }

  Map<String, dynamic> snapshot() => {
    'serverCheck': {
      'checkedAt': _serverCheckedAt?.toUtc().toIso8601String(),
      'startedAt': _serverRefreshStartedAt?.toUtc().toIso8601String(),
      'generations': Map.of(_serverRefreshGenerations),
    },
    'generations': Map.of(_diagnosticGenerations),
    'attempted': {
      for (final entry in _diagnosticAttempts.entries)
        entry.key: {
          'at': entry.value.toUtc().toIso8601String(),
          'generation': _attemptedGenerations[entry.key],
        },
    },
    'profiles': {
      for (final entry in _profiles.entries)
        entry.key: {
          'readiness': entry.value.readiness.healthSnapshot(),
          'tasks': entry.value.tasks == null
              ? null
              : healthFindingSnapshot(entry.value.tasks!),
          'taskError': entry.value.taskError,
          'checks': entry.value.checks == null
              ? null
              : healthFindingSnapshot(entry.value.checks!),
        },
    },
    'diagnostics': {
      for (final entry in diagnostics.entries)
        entry.key: {
          'name': entry.value.action.name,
          'pid': entry.value.action.pid,
          'status': diagnosticStatusSnapshot(entry.value),
          'checkedAt': entry.value.checkedAt?.toUtc().toIso8601String(),
          'readError': entry.value.readError,
          'scope': _diagnosticScopes[entry.key],
          'generation': _observedGenerations[entry.key],
        },
    },
  };

  void restore(Map value) {
    final serverCheck = value['serverCheck'] as Map;
    _serverCheckedAt = healthSnapshotTime(serverCheck['checkedAt']);
    _serverRefreshStartedAt = healthSnapshotTime(serverCheck['startedAt']);
    _serverRefreshGenerations.addAll(
      Map<String, int>.from(serverCheck['generations'] as Map),
    );
    _diagnosticGenerations.addAll(
      Map<String, int>.from(value['generations'] as Map),
    );
    for (final entry in (value['attempted'] as Map).entries) {
      final at = healthSnapshotTime(entry.value['at']);
      if (at != null) _diagnosticAttempts[entry.key as String] = at;
      _attemptedGenerations[entry.key as String] =
          entry.value['generation'] as int;
    }
    for (final entry in (value['profiles'] as Map).entries) {
      final state = _ProfileHealthState();
      state.readiness = AdministrationObservation.fromHealth(
        entry.value['readiness'] as Map,
      );
      state.tasks = restoreHealthFinding(entry.value['tasks']);
      state.taskError = entry.value['taskError'] as String?;
      state.checks = restoreHealthFinding(entry.value['checks']);
      _profiles[entry.key as String] = state;
    }
    for (final entry in (value['diagnostics'] as Map).entries) {
      final path = entry.key as String;
      if (!{'ops/doctor', 'ops/security-audit'}.contains(path)) continue;
      final saved = entry.value as Map;
      final action = AdministrationAction.fromJson(
        Map<String, dynamic>.from(saved),
      );
      if (path != 'ops/${action.name}') continue;
      final observation = AdminDiagnosticObservation(
        action,
        Map<String, dynamic>.from(saved['status'] as Map),
        healthSnapshotTime(saved['checkedAt']),
        readError: saved['readError'] as String?,
      );
      _diagnosticScopes[path] =
          saved['scope'] as String? ?? server.connectionLabel;
      _observedGenerations[path] = saved['generation'] as int;
      _installOperation(
        path,
        AdministrationOperationSession(
          server,
          action,
          initial: observation,
          now: _now,
        ),
        _diagnosticGenerations[path]!,
      );
    }
    _changed();
  }

  bool isStale(DateTime? at) =>
      at == null || _now().isBefore(at) || !_now().isBefore(at.add(maxAge));

  /// Detach immediately during a profile switch. Old overview completions can
  /// no longer notify this controller or recolor the new profile's entry.
  void selectProfile(AdministrationOverview? overview) {
    if (_disposed || identical(overview, _overview)) return;
    if (overview != null &&
        (overview.profile.server.connectionId != server.connectionId ||
            overview.profile.server.connectionIdentity !=
                server.connectionIdentity)) {
      throw ArgumentError('Health observations belong to another connection');
    }
    _overview?.removeListener(_changed);
    _overview = overview;
    overview?.addListener(_changed);
    _changed();
  }

  void updateProfileChecks(AdministrationProfileHealthObservation observation) {
    if (_disposed ||
        observation.scope.connectionId != server.connectionId ||
        observation.scope.connectionIdentity != server.connectionIdentity) {
      return;
    }
    _profiles
            .putIfAbsent(observation.scope.profileName, _ProfileHealthState.new)
            .checks =
        observation.finding;
    _changed();
  }

  /// Stock setup.status only observes configuration in the canonical profile's
  /// secret scope. It neither probes a model nor creates provider credentials.
  /// Inspected upstream 98f758ae7e8db83c2bb9214c3b35adf41df15f03:
  /// tui_gateway/methods_config.py:268; hermes_cli/main.py:1009.
  Future<void> refreshReadiness({ProfileAdministration? profile}) async {
    profile ??= _overview?.profile;
    if (_disposed || profile == null) return;
    final state = _profiles.putIfAbsent(profile.name, _ProfileHealthState.new);
    final readiness = state.readiness;
    final generation = ++state.generation;
    state.readiness = readiness.copyWith(loading: true, error: null);
    _changed();
    try {
      final data = await profile.rpc('setup.status');
      if (data['profile'] != profile.name ||
          data['provider_configured'] is! bool) {
        throw const FormatException('Incomplete profile readiness');
      }
      if (_disposed || generation != state.generation) return;
      state.readiness = AdministrationObservation(
        data: {'provider_configured': data['provider_configured']},
        checkedAt: _now(),
        loading: true,
      );
    } on Object catch (error) {
      if (_disposed || generation != state.generation) return;
      state.readiness = state.readiness.copyWith(
        error: administrationError(error),
      );
    } finally {
      if (!_disposed && generation == state.generation) {
        state.readiness = state.readiness.copyWith(loading: false);
        _changed();
      }
    }
  }

  void updateTasks(ScheduledTasksController source) {
    if (_disposed ||
        source.repository.profile.server.connectionIdentity !=
            server.connectionIdentity) {
      return;
    }
    final state = _profiles.putIfAbsent(
      source.repository.profile.name,
      _ProfileHealthState.new,
    );
    final count = source.tasks?.where((task) => task.needsAttention).length;
    state.taskLoading = source.loading;
    state.taskError = source.error;
    if (count == null && state.tasks?.checkedAt != null) {
      _changed();
      return;
    }
    state.tasks = _finding(
      'Scheduled tasks',
      count == null
          ? AdministrationHealthStatus.unknown
          : count > 0 || source.hasUnconfirmedActions
          ? AdministrationHealthStatus.warning
          : AdministrationHealthStatus.healthy,
      count == null
          ? 'Couldn’t check scheduled tasks'
          : [
              if (source.tasks!.isEmpty)
                'No scheduled tasks'
              else
                '${source.tasks!.length} ${source.tasks!.length == 1 ? 'task' : 'tasks'} · '
                    '${count == 0 ? 'No reported errors' : '$count ${count == 1 ? 'has a reported error' : 'have reported errors'}'}',
              if (source.hasUnconfirmedActions) 'A task action needs review',
            ].join(' · '),
      at: source.checkedAt,
      destination: 'Scheduled tasks',
    );
    _changed();
  }

  /// Captured task observations remain available independently of selection so
  /// recovery can retire an issue belonging to another profile.
  Map<String, AdministrationHealthFinding> get scheduledTaskFindings =>
      Map.unmodifiable({
        for (final entry in _profiles.entries)
          entry.key: ?_taskFinding(entry.value),
      });

  AdministrationHealthFinding? _taskFinding(_ProfileHealthState state) {
    final task = state.tasks;
    return task == null
        ? null
        : _finding(
            task.title,
            state.taskLoading || state.taskError != null
                ? AdministrationHealthStatus.unknown
                : task.status,
            task.detail,
            at: task.checkedAt,
            loading: state.taskLoading,
            error: state.taskError,
            destination: task.destination,
          );
  }

  AdministrationHealthFinding _finding(
    String title,
    AdministrationHealthStatus status,
    String detail, {
    DateTime? at,
    bool loading = false,
    String? error,
    String? destination,
  }) {
    final unknown = at == null || error != null;
    return AdministrationHealthFinding(
      title: title,
      detail: at == null && loading
          ? 'Checking…'
          : at == null && error != null
          ? 'Couldn’t check ${title.toLowerCase()}'
          : '$detail${loading
                ? ' · Refreshing'
                : error != null
                ? ' · Refresh unavailable'
                : ''}',
      status: unknown && status == AdministrationHealthStatus.healthy
          ? AdministrationHealthStatus.unknown
          : status,
      checkedAt: at,
      destination: destination,
    );
  }

  List<AdministrationHealthFinding> get profileFindings {
    if (_overview == null) {
      return const [
        AdministrationHealthFinding(
          title: 'Selected profile',
          detail: 'Select an available profile',
          status: AdministrationHealthStatus.unknown,
        ),
      ];
    }
    final findings = <AdministrationHealthFinding>[];
    final connection = connectionStatus;
    if (connection != null &&
        (connection.chatEndpointUnsupported ||
            connection.phase == ServerConnectionPhase.unchecked ||
            connection.phase == ServerConnectionPhase.reconnecting ||
            connection.access == ConnectionAvailability.unavailable ||
            connection.live == ConnectionAvailability.unavailable)) {
      findings.add(
        AdministrationHealthFinding(
          title: 'Connection',
          detail: connection.chatEndpointUnsupported
              ? connection.problem!
              : connection.description,
          status: connection.chatEndpointUnsupported
              ? AdministrationHealthStatus.failure
              : AdministrationHealthStatus.unknown,
        ),
      );
    }
    final configured = _readiness.data?['provider_configured'];
    findings.add(
      _finding(
        'Provider configuration',
        configured == true
            ? AdministrationHealthStatus.healthy
            : configured == false
            ? AdministrationHealthStatus.warning
            : AdministrationHealthStatus.unknown,
        configured == true
            ? 'Provider configuration detected'
            : configured == false
            ? 'No provider configuration detected'
            : 'Provider configuration has not been established',
        at: _readiness.checkedAt,
        loading: _readiness.loading,
        error: _readiness.error,
        destination: 'Access and connectors',
      ),
    );
    for (final key in ['model', 'access', 'tools', 'connectors']) {
      final observation = _overview!.observations[key];
      final data = observation?.data;
      final title = switch (key) {
        'model' => 'Model selection',
        'access' => 'Provider access',
        'tools' => 'Tool setup',
        _ => 'Connector settings',
      };
      final destination = switch (key) {
        'model' => 'Models and reasoning',
        'tools' => 'Skills and tools',
        'connectors' => 'MCP connectors',
        _ => 'Access and connectors',
      };
      var status = AdministrationHealthStatus.unknown;
      var detail = 'Information unavailable';
      if (data != null) {
        try {
          (status, detail) = switch (key) {
            'model' => _model(data),
            'access' => _access(data),
            'tools' => _tools(data),
            _ => _connectors(data),
          };
        } on Object {
          detail = 'Incomplete observation; refresh to check again';
        }
      }
      findings.add(
        _finding(
          title,
          status,
          detail,
          at:
              key == 'connectors' &&
                  _overview!.connectorRuntimeIssues.isNotEmpty
              ? _overview!.connectorRuntime?.receivedAt
              : observation?.checkedAt,
          loading: observation?.loading == true,
          error: observation?.error,
          destination: destination,
        ),
      );
    }
    if (_taskFinding(_profileState) case final task?) findings.add(task);
    if (_profileChecks case final checks?) {
      findings.add(
        _finding(
          checks.title,
          checks.status,
          checks.detail,
          at: checks.checkedAt,
          destination: checks.destination,
        ),
      );
    }
    return findings;
  }

  (AdministrationHealthStatus, String) _model(Map<String, dynamic> data) {
    final model = data['model'], provider = data['provider'];
    if (model is! String || provider is! String) {
      return (
        AdministrationHealthStatus.unknown,
        'Model selection unavailable',
      );
    }
    if (model.trim().isEmpty || provider.trim().isEmpty) {
      return (
        AdministrationHealthStatus.warning,
        'Choose a model and provider',
      );
    }
    return (AdministrationHealthStatus.healthy, '$model · $provider');
  }

  (AdministrationHealthStatus, String) _access(Map<String, dynamic> data) {
    final providers = administrationRows(
      data['providers'],
    ).map((row) => ProviderAccess(row, now: _now())).toList();
    final expired = providers
        .where((p) => p.state == ProviderAccessState.expired)
        .toList();
    if (expired.isNotEmpty) {
      final name = expired.length == 1
          ? _observedName(expired.single.row, const ['name', 'id'])
          : null;
      return (
        AdministrationHealthStatus.failure,
        expired.length == 1
            ? '${name ?? '1 provider'} sign-in expired'
            : '${expired.length} provider sign-ins expired',
      );
    }
    if (providers.any(
      (p) =>
          p.state == ProviderAccessState.unknown ||
          p.state == ProviderAccessState.external ||
          p.status['expires_at'] != null && p.expiresAt == null,
    )) {
      return (
        AdministrationHealthStatus.unknown,
        'Provider readiness is not fully observed',
      );
    }
    return (AdministrationHealthStatus.healthy, 'No expired sign-ins reported');
  }

  (AdministrationHealthStatus, String) _tools(Map<String, dynamic> data) {
    final rows = administrationRows(data['data']);
    final enabled = rows.where((r) => r['enabled'] == true).length;
    final setup = rows
        .where((r) => r['enabled'] == true && r['configured'] == false)
        .toList();
    if (setup.isNotEmpty) {
      return (
        AdministrationHealthStatus.warning,
        '$enabled enabled · ${setup.length} ${setup.length == 1 ? 'needs' : 'need'} setup',
      );
    }
    if (rows.any(
      (r) =>
          r['enabled'] is! bool ||
          r['enabled'] == true && r['configured'] is! bool,
    )) {
      return (
        AdministrationHealthStatus.unknown,
        'Tool setup is not fully observed',
      );
    }
    return (
      AdministrationHealthStatus.healthy,
      enabled == 0 ? 'No tools enabled' : '$enabled enabled · All set up',
    );
  }

  String? _observedName(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final value = row[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  /// Explicit probe findings keep their own identity in Health alerts. The
  /// displayed row also includes independently observed cached runtime issues.
  AdministrationHealthFinding? get connectorProbeFinding {
    final observation = _overview?.observations['connectors'];
    final data = observation?.data;
    if (data == null) return null;
    final (status, detail) = _connectorProbes(data);
    return _finding(
      'Connector settings',
      status,
      detail,
      at: observation?.checkedAt,
      loading: observation?.loading == true,
      error: observation?.error,
      destination: 'MCP connectors',
    );
  }

  (AdministrationHealthStatus, String) _connectors(Map<String, dynamic> data) {
    final probes = _connectorProbes(data);
    final issues = _overview!.connectorRuntimeIssues;
    return issues.isEmpty
        ? probes
        : (
            AdministrationHealthStatus.warning,
            '${ConnectorRuntimeObservation.describeIssues(issues.values)} · ${probes.$2}',
          );
  }

  (AdministrationHealthStatus, String) _connectorProbes(
    Map<String, dynamic> data,
  ) {
    final rows = administrationRows(data['servers']);
    if (rows.any((r) => r['name'] is! String || r['enabled'] is! bool)) {
      return (
        AdministrationHealthStatus.unknown,
        'Connector settings are incomplete',
      );
    }
    if (rows.isEmpty) {
      return (AdministrationHealthStatus.healthy, 'No connectors configured');
    }
    final enabled = rows.where((r) => r['enabled'] == true).toList();
    if (enabled.isEmpty) {
      return (AdministrationHealthStatus.healthy, 'No connectors enabled');
    }
    final checks = _overview!.connectorChecks;
    final failed = enabled.where((r) => checks[r['name']] == false).length;
    final unknown = enabled.where((r) => checks[r['name']] == null).length;
    final passed = enabled.length - failed - unknown;
    if (failed > 0 || unknown > 0) {
      return (
        failed > 0
            ? AdministrationHealthStatus.warning
            : AdministrationHealthStatus.unknown,
        [
          '$passed passed',
          if (failed > 0) '$failed failed',
          if (unknown > 0) '$unknown couldn’t be checked',
        ].join(' · '),
      );
    }
    return (
      AdministrationHealthStatus.healthy,
      '$passed of ${enabled.length} connection ${enabled.length == 1 ? 'check' : 'checks'} passed',
    );
  }

  bool canStartDiagnostic(String path) {
    if (_disposed || _starting.contains(path)) return false;
    final previous = _operations[path];
    return previous == null || previous.state.canRunAgain;
  }

  Future<bool> startDiagnostic(AdministrationDiagnostic kind) async {
    final path = kind.path;
    if (!canStartDiagnostic(path)) return false;
    _starting.add(path);
    _startErrors.remove(path);
    final generation = _diagnosticGenerations.update(
      path,
      (n) => n + 1,
      ifAbsent: () => 1,
    );
    _recordDiagnosticAttempt(path);
    _changed();
    try {
      final action = await server.startDiagnostic(
        path,
        isActive: () =>
            !_disposed && _diagnosticGenerations[path] == generation,
      );
      if (_disposed || _diagnosticGenerations[path] != generation) return false;
      if (action.name != kind.actionName) {
        throw const AdministrationFailure(
          'Operation started, but tracking is unavailable. Refresh its result.',
        );
      }
      _diagnosticScopes[path] = server.connectionLabel;
      _installOperation(
        path,
        AdministrationOperationSession(server, action, now: _now),
        generation,
      );
      return true;
    } catch (error) {
      if (!_disposed && _diagnosticGenerations[path] == generation) {
        _startErrors[path] = error is AdministrationFailure
            ? error.message
            : 'Could not confirm the diagnostic started. Check the connection.';
      }
      return false;
    } finally {
      if (!_disposed && _diagnosticGenerations[path] == generation) {
        _starting.remove(path);
        _changed();
      }
    }
  }

  bool get canRunAllDiagnostics => diagnosticPaths.every(canStartDiagnostic);

  Future<List<String>> runAllDiagnostics() async {
    if (!canRunAllDiagnostics) return const [];
    _beginServerRefresh();
    await Future.wait([
      for (final kind in AdministrationDiagnostic.values) startDiagnostic(kind),
    ]);
    if (_disposed) return const [];
    return List.unmodifiable([
      for (final kind in AdministrationDiagnostic.values)
        if (_startErrors[kind.path] case final error?) '${kind.title}: $error',
    ]);
  }

  Future<void> refreshDiagnostics() async {
    if (_disposed) return;
    if (diagnosticPaths.every(diagnosticNeedsRefresh)) {
      await runAllDiagnostics();
    } else {
      await Future.wait([
        for (final kind in AdministrationDiagnostic.values)
          if (diagnosticNeedsRefresh(kind.path)) startDiagnostic(kind),
      ]);
    }
  }

  void _installOperation(
    String path,
    AdministrationOperationSession operation,
    int generation,
  ) {
    final previous = _operations.remove(path);
    final listener = _operationListeners.remove(path);
    if (listener != null) previous?.removeListener(listener);
    previous?.dispose();
    _operations[path] = operation;
    void changed() {
      if (_disposed ||
          _diagnosticGenerations[path] != generation ||
          !identical(_operations[path], operation)) {
        return;
      }
      _observedGenerations[path] = generation;
      _changed();
    }

    _operationListeners[path] = changed;
    operation.addListener(changed);
  }

  void _changed() {
    if (_disposed) return;
    final completed = diagnosticPaths.map((path) => diagnostics[path]).toList();
    if (completed.every(
      (value) =>
          value != null &&
          value.readError == null &&
          value.running == false &&
          value.exitCode != null &&
          value.checkedAt != null,
    )) {
      final times = completed.map((value) => value!.checkedAt!).toList()
        ..sort();
      if (_serverRefreshStartedAt case final start?) {
        if (!times.first.isBefore(start) &&
            diagnosticPaths.every(
              (path) =>
                  (_observedGenerations[path] ?? -1) >=
                  _serverRefreshGenerations[path]!,
            )) {
          _serverCheckedAt = times.last;
          _serverRefreshStartedAt = null;
          _serverRefreshGenerations.clear();
        }
      } else {
        // Individually run diagnostics establish conservative initial coverage.
        // Later individual reruns must not make the other result look fresh.
        _serverCheckedAt ??= times.first;
      }
    }
    _expiry?.cancel();
    final futureExpiries = [
      ..._providerExpiries(),
    ].where((time) => time.isAfter(_now())).toList()..sort();
    if (futureExpiries.isNotEmpty) {
      _expiry = Timer(futureExpiries.first.difference(_now()), _changed);
    }
    ++_notificationDepth;
    try {
      notifyListeners();
    } finally {
      --_notificationDepth;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  Iterable<DateTime> _providerExpiries() sync* {
    final rows = _overview?.observations['access']?.data?['providers'];
    if (rows is! List) return;
    for (final row in rows) {
      if (row is! Map || row['status'] is! Map) continue;
      final expiry = providerStatusDate(row['status']['expires_at']);
      if (expiry != null) yield expiry;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _expiry?.cancel();
    for (final entry in _operations.entries) {
      entry.value.removeListener(_operationListeners[entry.key]!);
      entry.value.dispose();
    }
    _operations.clear();
    _operationListeners.clear();
    _overview?.removeListener(_changed);
    connectionStatus?.removeListener(_changed);
    if (_notificationDepth == 0) super.dispose();
  }
}

class _ProfileHealthState {
  AdministrationObservation readiness = AdministrationObservation();
  AdministrationHealthFinding? tasks;
  bool taskLoading = false;
  String? taskError;
  AdministrationHealthFinding? checks;
  int generation = 0;
}
