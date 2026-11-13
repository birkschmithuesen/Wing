import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/hermes_profile.dart';
import '../models/model_choice.dart';
import '../models/profile_overview_summary.dart';
import '../models/provider_access.dart';
import '../models/settings_edit.dart';
import 'administration_overview.dart';
import 'administration_repository.dart';
import 'scheduled_tasks_controller.dart';

/// Owns one overview route's coordination and projection. The existing owners
/// remain the only observation cache and task action/journal owner respectively.
class ProfileOverviewSession extends ChangeNotifier {
  ProfileOverviewSession(
    ProfileAdministration profile,
    SharedPreferences preferences, {
    required this._refreshWorkspace,
    DateTime Function()? now,
  }) : overviewOwner = AdministrationOverview(profile),
       taskOwner = ScheduledTasksController.acquire(profile, preferences),
       _now = now ?? DateTime.now {
    overviewOwner.addListener(_changed);
    taskOwner.addListener(_changed);
  }

  final AdministrationOverview overviewOwner;
  final ScheduledTasksController taskOwner;
  final DateTime Function() _now;
  final Future<void> Function() _refreshWorkspace;
  WorkspaceScope get scope => overviewOwner.profile.scope;
  String get storageNamespace => overviewOwner.profile.scope.storageNamespace;
  bool _disposed = false;
  int _refreshes = 0;
  String? _refreshError;
  bool get refreshing => !_disposed && _refreshes > 0;
  String? get refreshError => _refreshError;
  final _taskWaiters = <VoidCallback, Completer<void>>{};

  static const _reads = <ProfileOverviewDestination, Set<String>>{
    ProfileOverviewDestination.models: {'model', 'config', 'access'},
    ProfileOverviewDestination.memory: {'config'},
    ProfileOverviewDestination.behavior: {'config'},
    ProfileOverviewDestination.skills: {'skills', 'tools', 'access'},
    ProfileOverviewDestination.skillHub: {'skills'},
    ProfileOverviewDestination.access: {'access', 'connectors'},
    ProfileOverviewDestination.connectors: {'connectors'},
  };

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Entry observes the captured profile without refreshing the workspace.
  Future<void> load() => _refresh(keys: null, refreshWorkspace: false);

  /// Header and pull-to-refresh join the actual reads and workspace refresh.
  /// Targeted owner reads retain independent generations and observations.
  Future<void> refresh({Set<String>? keys}) =>
      _refresh(keys: keys, refreshWorkspace: keys == null);

  Future<void> _refresh({
    required Set<String>? keys,
    required bool refreshWorkspace,
  }) async {
    if (_disposed) return;
    _refreshes++;
    _refreshError = null;
    _changed();
    try {
      if (_disposed) return;
      final workspace = refreshWorkspace ? _refreshWorkspace() : null;
      if (_disposed) {
        if (workspace != null) {
          await workspace;
        }
        return;
      }
      await Future.wait([
        ?workspace,
        overviewOwner.refresh(keys: keys),
        if (keys == null || keys.contains('tasks')) _readTasks(),
      ]);
    } catch (error) {
      if (!_disposed) _refreshError = administrationError(error);
    } finally {
      _refreshes--;
      _changed();
    }
  }

  Future<void> _readTasks() {
    if (_disposed) return Future.value();
    if (!taskOwner.loading) return taskOwner.refresh();
    final completion = Completer<void>();
    late final VoidCallback settled;
    settled = () {
      if (!_disposed && taskOwner.loading) return;
      taskOwner.removeListener(settled);
      _taskWaiters.remove(settled);
      if (!completion.isCompleted) completion.complete();
    };
    _taskWaiters[settled] = completion;
    taskOwner.addListener(settled);
    settled();
    return completion.future;
  }

  /// The owner is captured before navigation. A retired route cannot redirect
  /// the returning editor's observations to a newly selected profile.
  Future<void> review(
    ProfileOverviewDestination destination,
    FutureOr<void> Function() openEditor,
  ) async {
    if (_disposed) return;
    await openEditor();
    if (_disposed) return;
    await returnedFrom(destination);
  }

  Future<void> returnedFrom(ProfileOverviewDestination destination) => _refresh(
    keys: destination == ProfileOverviewDestination.scheduledTasks
        ? const {'tasks'}
        : _reads[destination] ?? const {},
    refreshWorkspace: false,
  );

  ProfileOverviewSummary get summary {
    final modelObservation = overviewOwner.observations['model'];
    final modelData = modelObservation?.data;
    final model = modelData == null
        ? null
        : ConfiguredModel.fromInfo(modelData);
    final title = model?.hasModel == true
        ? model!.model
        : modelObservation?.loading == true
        ? 'Loading…'
        : 'Model unavailable';
    final metadata = _describe('model', (_) {
      final provider = model!.provider.isEmpty
          ? 'Automatic provider'
          : model.provider;
      return OverviewText('$provider · ').followedBy(
        _describe('config', (config) {
          final effort = setting(config, 'agent.reasoning_effort');
          return OverviewText(
            effort is String && effort.isNotEmpty
                ? 'Reasoning $effort'
                : 'Reasoning not specified',
          );
        }),
      );
    });
    final rows = <ProfileOverviewDestination, ProfileOverviewRow>{};
    void row(
      ProfileOverviewDestination destination,
      OverviewText text, {
      String? detail,
    }) {
      rows[destination] = ProfileOverviewRow(
        destination: destination,
        summary: text,
        detail: detail,
        attention: _attention(destination),
      );
    }

    row(
      ProfileOverviewDestination.identity,
      OverviewText('Description and agent instructions'),
    );
    row(
      ProfileOverviewDestination.memory,
      _describe('config', (config) {
        final retained = setting(config, 'memory.memory_enabled');
        final budget = setting(config, 'memory.memory_char_limit');
        final budgetText = budget is num && budget.isFinite
            ? OverviewText.parts([
                if (budget == budget.roundToDouble())
                  OverviewInteger(budget.toInt())
                else
                  OverviewLiteral('$budget'),
                const OverviewLiteral('-character budget'),
              ])
            : OverviewText('Memory budget unavailable');
        return budgetText.followedBy(
          OverviewText(
            ' · ${retained is bool ? (retained ? 'Retention on' : 'Retention off') : 'Retention unavailable'}',
          ),
        );
      }),
    );
    row(
      ProfileOverviewDestination.behavior,
      _describe('config', (config) {
        final approval = setting(config, 'approvals.mode');
        final compression = setting(config, 'compression.enabled');
        return OverviewText(
          '${approval is String ? 'Approvals $approval' : 'Approval mode unavailable'} · ${compression is bool ? (compression ? 'Compression on' : 'Compression off') : 'Setting unavailable'}',
        );
      }),
    );
    row(
      ProfileOverviewDestination.skills,
      _describe('skills', (data) {
        final rows = administrationRows(data['data']);
        final enabled = rows.where((row) => row['enabled'] == true).length;
        final unknown = rows.any((row) => row['enabled'] is! bool);
        return OverviewText(
          '$enabled ${enabled == 1 ? 'skill' : 'skills'} enabled${unknown ? ' · Some states unavailable' : ''} · ',
        ).followedBy(
          _describe('tools', (tools) {
            final rows = administrationRows(tools['data']);
            final enabled = rows.where((row) => row['enabled'] == true).length;
            return OverviewText(
              '$enabled ${enabled == 1 ? 'toolset' : 'toolsets'} enabled${rows.any((row) => row['enabled'] is! bool || row['configured'] is! bool) ? ' · Some tool states unavailable' : ''}',
            );
          }),
        );
      }),
    );
    row(
      ProfileOverviewDestination.access,
      _describe('access', (data) {
        final providers = _providers(data);
        final stored = providers.where((row) => row.hasCredential).length;
        final access = providers
            .where((row) => row.id == model?.provider)
            .firstOrNull;
        final source = access?.status['source_label'];
        return OverviewText(
          '$stored ${stored == 1 ? 'sign-in' : 'sign-ins'} reported · ${source is String && source.isNotEmpty ? source : 'Access source unavailable'} · ',
        ).followedBy(
          _describe('connectors', (data) {
            final count = administrationRows(data['servers']).length;
            return OverviewText(
              '$count ${count == 1 ? 'connector' : 'connectors'}',
            );
          }),
        );
      }),
    );
    final tasks = taskOwner.tasks;
    final upcoming =
        tasks
            ?.where(
              (task) =>
                  task.enabled &&
                  {'scheduled', 'enabled'}.contains(task.state) &&
                  task.nextRun != null,
            )
            .toList()
          ?..sort((a, b) => a.nextRun!.compareTo(b.nextRun!));
    final latest = tasks?.where((task) => task.lastRun != null).toList()
      ?..sort((a, b) => b.lastRun!.compareTo(a.lastRun!));
    final running = tasks?.where((task) => task.running).length ?? 0;
    var activity = tasks == null
        ? OverviewText(
            taskOwner.loading ? 'Loading schedules…' : 'Schedules unavailable',
          )
        : upcoming!.isNotEmpty
        ? OverviewText.parts([
            const OverviewLiteral('Next '),
            OverviewTaskTime(upcoming.first.nextRun!),
            OverviewLiteral(running > 0 ? ' · $running running' : ''),
          ])
        : OverviewText(
            tasks.isEmpty ? 'No scheduled tasks' : 'No confirmed upcoming run',
          );
    if (tasks != null && latest!.isNotEmpty) {
      activity = activity.followedBy(
        OverviewText(
          '\nLast listed run · ${latest.first.error.isNotEmpty ? 'Error reported' : 'Outcome unavailable'}',
        ),
      );
    }
    if (tasks != null && taskOwner.error != null) {
      activity = _stale(activity, taskOwner.checkedAt);
    }
    row(
      ProfileOverviewDestination.scheduledTasks,
      activity,
      detail: upcoming?.firstOrNull?.title,
    );
    return ProfileOverviewSummary(
      modelTitle: title,
      modelMetadata: metadata,
      modelAttention: _attention(ProfileOverviewDestination.models),
      rows: rows,
    );
  }

  List<ProviderAccess> _providers(Map<String, dynamic> data) {
    final now = _now();
    return [
      for (final row in administrationRows(data['providers']))
        ProviderAccess(row, now: now),
    ];
  }

  OverviewText _describe(
    String key,
    OverviewText Function(Map<String, dynamic>) describe,
  ) {
    final observation = overviewOwner.observations[key];
    final data = observation?.data;
    if (data == null) {
      return OverviewText(
        observation?.loading == true ? 'Loading…' : 'Information unavailable',
      );
    }
    final value = describe(data);
    return observation?.error == null
        ? value
        : _stale(value, observation?.checkedAt);
  }

  OverviewText _stale(OverviewText value, DateTime? checkedAt) =>
      value.followedBy(
        OverviewText.parts([
          OverviewLiteral(
            checkedAt == null ? ' · Last observation' : ' · Last checked ',
          ),
          if (checkedAt != null) OverviewCheckedTime(checkedAt),
          const OverviewLiteral('; refresh unavailable'),
        ]),
      );

  String? _attention(ProfileOverviewDestination destination) {
    if (destination == ProfileOverviewDestination.skills) {
      final data = overviewOwner.observations['tools']?.data;
      if (data != null) {
        final count = administrationRows(
          data['data'],
        ).where((r) => r['enabled'] == true && r['configured'] == false).length;
        if (count > 0) return count == 1 ? 'Setup needed' : '$count need setup';
      }
    }
    if (destination == ProfileOverviewDestination.access) {
      final data = overviewOwner.observations['access']?.data;
      if (data != null) {
        final count = _providers(
          data,
        ).where((row) => row.state == ProviderAccessState.expired).length;
        if (count > 0) {
          return count == 1 ? 'Sign-in expired' : '$count sign-ins expired';
        }
      }
    }
    if (destination == ProfileOverviewDestination.scheduledTasks) {
      final count =
          taskOwner.tasks?.where((task) => task.needsAttention).length ?? 0;
      if (count > 0) {
        return count == 1 ? 'Needs attention' : '$count need attention';
      }
      if (taskOwner.error != null) return 'Refresh unavailable';
    }
    for (final key in _reads[destination] ?? const <String>{}) {
      final observation = overviewOwner.observations[key];
      if (observation?.error != null) {
        return observation?.data == null
            ? 'Information unavailable'
            : 'Refresh unavailable';
      }
    }
    return null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _taskWaiters.entries.toList()) {
      taskOwner.removeListener(entry.key);
      if (!entry.value.isCompleted) entry.value.complete();
    }
    _taskWaiters.clear();
    overviewOwner.removeListener(_changed);
    taskOwner.removeListener(_changed);
    overviewOwner.dispose();
    taskOwner.release();
    super.dispose();
  }
}
