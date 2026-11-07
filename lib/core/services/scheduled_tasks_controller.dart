import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/scheduled_task.dart';
import '../models/scheduled_task_edit.dart';
import 'administration_repository.dart';
import 'connection_manager.dart';
import 'scheduled_tasks_repository.dart';

String taskFailure(Object error) => switch (error) {
  CronHttpException e => e.description,
  AdministrationFailure e => e.message,
  FormatException _ =>
    'The server returned incomplete task information. Refresh to try again.',
  _ => 'Could not reach the server. Check your connection and refresh.',
};

/// An action belongs to a captured profile, not the route that initiated it.
/// Registry leases keep in-flight actions alive across navigation. Only IDs,
/// operation names and review dispositions are journaled, never instructions.
class ScheduledTasksController extends ChangeNotifier {
  ScheduledTasksController(this.repository, SharedPreferences preferences)
    : _preferences = preferences {
    final saved = preferences.getString(_journalKey);
    if (saved != null) {
      try {
        final value = jsonDecode(saved) as Map;
        for (final entry in value.entries) {
          _uncertain[entry.key as String] =
              _immutableJournalValue(entry.value as Map)
                  as Map<String, dynamic>;
        }
      } on Object {
        _notice =
            'A previous task request could not be recovered. Review tasks before making another request.';
        _uncertain['__create__'] = const {'action': 'create'};
      }
    }
    final savedStops = preferences.getString(_stopJournalKey);
    if (savedStops != null) {
      try {
        final value = jsonDecode(savedStops) as Map;
        for (final entry in value.entries) {
          _stops[entry.key as String] =
              _immutableJournalValue(entry.value as Map)
                  as Map<String, dynamic>;
        }
      } on Object {
        _stopRecoveryFailed = true;
      }
    }
  }
  static final _registry = <String, ScheduledTasksController>{};

  /// A child route acquires the same captured profile without knowing how its
  /// preferences or shared owner registry are assembled.
  ScheduledTasksController acquireLease() {
    if (_disposed) throw StateError('Scheduled task owner is disposed.');
    return acquire(repository.profile, _preferences);
  }

  static ScheduledTasksController acquire(
    ProfileAdministration profile,
    SharedPreferences preferences,
  ) {
    final key = profile.scope.storageNamespace;
    final controller = _registry.putIfAbsent(key, () {
      profile.server.retain();
      return ScheduledTasksController(
        ScheduledTasksRepository(profile),
        preferences,
      ).._managed = true;
    });
    controller._leases++;
    return controller;
  }

  final ScheduledTasksRepository repository;
  final SharedPreferences _preferences;
  int _leases = 0;
  bool _managed = false, _disposed = false;
  int _generation = 0;
  List<ScheduledTask>? _tasks;
  DateTime? _checkedAt;
  String? _error, _notice;
  bool _loading = false;
  final _busy = <String>{};
  final _uncertain = <String, Map<String, dynamic>>{};
  final _stopping = <String>{};
  final _stops = <String, Map<String, dynamic>>{};
  bool _stopRecoveryFailed = false;

  /// Passive snapshots never expose a second writer to cache or journal state.
  /// Busy and journal snapshots remain stable when an admitted command settles.
  List<ScheduledTask>? get tasks => _tasks;
  DateTime? get checkedAt => _checkedAt;
  String? get error => _error;
  String? get notice => _notice;
  bool get loading => _loading;
  Set<String> get busy => Set.unmodifiable({..._busy, ..._stopping});
  bool updating(String id) => _busy.contains(id);
  bool stopping(String id) => _stopping.contains(id);
  Set<String> get stoppingTaskIds => Set.unmodifiable(_stopping);
  Set<String> get stopReviewTaskIds => Set.unmodifiable(
    _stops.entries
        .where(
          (entry) =>
              entry.value['requires_review'] == true && !stopping(entry.key),
        )
        .map((entry) => entry.key),
  );
  bool get hasUnconfirmedActions =>
      _uncertain.isNotEmpty ||
      _stopRecoveryFailed ||
      _stops.values.any((record) => record['requires_review'] == true);
  Map<String, Map<String, dynamic>> get uncertain =>
      Map.unmodifiable(_uncertain);

  String get _journalKey =>
      'scheduled-task-actions:${repository.profile.scope.storageNamespace}';
  String get _stopJournalKey => '$_journalKey:stops';
  bool _stopUncertain(String id) =>
      _stopRecoveryFailed || _stops[id]?['requires_review'] == true;
  bool blocked(String id) =>
      _busy.contains(id) ||
      _uncertain.containsKey(id) ||
      stopping(id) ||
      _stopUncertain(id);
  String? get savedUnregisteredId =>
      _uncertain['__create__']?['job_id'] as String?;
  ScheduledTask? task(String id) =>
      _tasks?.where((t) => t.id == id).firstOrNull;
  List<TaskActionChoice> actions(ScheduledTask task) {
    final owned =
        task.profileName == repository.profile.name &&
        (_tasks == null || this.task(task.id) != null);
    final enabled = !blocked(task.id) && owned;
    final live = this.task(task.id)?.liveExecution;
    final canCancel =
        owned &&
        live?.live == true &&
        live!.id == task.liveExecution?.id &&
        !stopping(task.id) &&
        !_stopUncertain(task.id) &&
        _stops[task.id]?['execution_id'] != live.id &&
        ((!_busy.contains(task.id) && !_uncertain.containsKey(task.id)) ||
            _uncertain[task.id]?['action'] == 'trigger');
    return List.unmodifiable([
      TaskActionChoice(TaskAction.edit, 'Edit task', enabled),
      if (task.canStop || stopping(task.id))
        TaskActionChoice(TaskAction.cancel, 'Stop run', canCancel),
      if (task.canPause)
        TaskActionChoice(TaskAction.pause, 'Pause schedule', enabled),
      if (task.canResume)
        TaskActionChoice(TaskAction.resume, 'Resume schedule', enabled),
      TaskActionChoice(
        TaskAction.trigger,
        task.enabled ? 'Run now' : 'Resume and run',
        enabled && task.canRun,
        confirmation: task.enabled
            ? null
            : TaskConfirmation(
                'Resume and run?',
                'This runs ${task.title} now and resumes its schedule on the server.',
                'Resume and run',
              ),
      ),
      TaskActionChoice(
        TaskAction.remove,
        'Delete task',
        enabled,
        confirmation: TaskConfirmation(
          'Delete ${task.title}?',
          'Remove this schedule from ${repository.profile.label}. Hermes also cancels its running work.',
          'Delete task',
        ),
      ),
    ]);
  }

  TaskActionChoice? actionChoice(ScheduledTask task, TaskAction action) =>
      actions(task).where((choice) => choice.kind == action).firstOrNull;
  TaskActionChoice? toggleChoice(ScheduledTask task) => actions(task)
      .where(
        (choice) =>
            choice.kind == TaskAction.resume || choice.kind == TaskAction.pause,
      )
      .firstOrNull;
  String? pendingNotice(String id) {
    if (_stopUncertain(id) && !stopping(id)) {
      return 'Stop is not confirmed. Review the task and recent runs before requesting it again.';
    }
    if (!_uncertain.containsKey(id) || _busy.contains(id)) return null;
    return _uncertain[id]?['action'] == 'registration'
        ? 'Your task was saved, but scheduler registration failed. Review the saved task before creating another.'
        : 'A previous request has an unknown outcome. Review the tasks and recent runs before making another request.';
  }

  Future<TaskConfirmation?> reviewPrompt(String id) async {
    await refresh();
    if (pendingNotice(id) == null) return null;
    return const TaskConfirmation(
      'Have you reviewed the result?',
      'The previous request may have reached Hermes. Allowing another request can create duplicate work. This only clears the pending notice; it does not repeat the request.',
      'I have reviewed it',
    );
  }

  Future<void> perform(ScheduledTask task, TaskAction action) async {
    if (actionChoice(task, action)?.enabled != true) return;
    if (action == TaskAction.remove) {
      await delete(task);
    } else if (action == TaskAction.cancel) {
      await _stop(task);
    } else if (action != TaskAction.edit) {
      await act(task, action.name);
    }
  }

  void release() {
    _leases--;
    _collect();
  }

  void _collect() {
    if (_managed && _leases == 0 && _busy.isEmpty && _stopping.isEmpty) {
      _registry.remove(repository.profile.scope.storageNamespace);
      repository.profile.server.release();
      dispose();
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _persist() async {
    if (!await _preferences.setString(_journalKey, jsonEncode(_uncertain))) {
      throw const AdministrationFailure(
        'Could not save task request state on your phone.',
      );
    }
  }

  Future<void> _persistStops() async {
    // An unreadable record remains durable until the user reviews it.
    if (_stopRecoveryFailed) return;
    if (!await _preferences.setString(_stopJournalKey, jsonEncode(_stops))) {
      throw const AdministrationFailure(
        'Could not save task request state on your phone.',
      );
    }
  }

  // Run now waits for the whole execution in stock Hermes. Stop has its own
  // journal and lifetime: neither completion may release the other's guard.
  Future<void> _stop(ScheduledTask task) async {
    if (actionChoice(task, TaskAction.cancel)?.enabled != true) return;
    final id = task.id, execution = task.liveExecution!.id;
    _stopping.add(id);
    _stops[id] = Map.unmodifiable({
      'execution_id': execution,
      'requires_review': true,
    });
    _error = null;
    _notice = null;
    _emit();
    var sent = false;
    try {
      await _persistStops();
      sent = true;
      final result = await repository.cancel(id);
      if (result.requested && result.executionId != execution) {
        throw const TaskMutationUncertain();
      }
      if (result.requested) {
        _stops[id] = Map.unmodifiable({
          'execution_id': execution,
          'requires_review': false,
        });
      } else {
        _stops.remove(id);
      }
      try {
        await _persistStops();
      } catch (_) {
        _notice =
            'Stop was confirmed. Its local request record could not be cleared.';
      }
      await refresh();
      _notice = _error == null
          ? result.notice
          : 'Stop was confirmed. Refresh to reload the task.';
    } catch (e) {
      final notSent = !sent || e is TaskPreflightFailure;
      final definite =
          notSent ||
          e is AdministrationFailure ||
          (e is CronHttpException && !e.uncertain);
      if (definite) _stops.remove(id);
      try {
        await _persistStops();
      } catch (_) {
        // Retain the in-memory guard when persistence is unavailable.
      }
      _error = definite
          ? '${taskFailure(e)}${notSent ? ' Nothing was sent.' : ''}'
          : null; // The durable Stop review notice owns uncertain outcomes.
      rethrow;
    } finally {
      _stopping.remove(id);
      _emit();
      _collect();
    }
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _emit();
    try {
      final result = await repository.list();
      if (_disposed || generation != _generation) return;
      _tasks = List.unmodifiable(result);
      _checkedAt = DateTime.now();
      _stops.removeWhere(
        (id, record) =>
            record['requires_review'] == false &&
            !stopping(id) &&
            task(id)?.liveExecution?.id != record['execution_id'],
      );
      // A later list cannot establish which store an unconfirmed request
      // mutated. Only its authoritative acknowledgement or explicit review
      // releases the guard, including after recovery of its saved record.
      await _persist();
      await _persistStops();
    } catch (e) {
      if (!_disposed && generation == _generation) _error = taskFailure(e);
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _emit();
      }
    }
  }

  Future<T?> _mutate<T>(
    String id,
    String action,
    Future<T> Function() request,
  ) async {
    if (blocked(id)) return null;
    _busy.add(id);
    _error = null;
    _notice = null;
    _uncertain[id] = Map.unmodifiable({
      'action': action,
      'requires_review': true,
    });
    _emit();
    bool sent = false;
    try {
      await _persist();
      sent = true;
      final value = await request();
      _uncertain.remove(id);
      if (savedUnregisteredId == id) _uncertain.remove('__create__');
      if (value is ScheduledTask && action != 'trigger') {
        _tasks = List.unmodifiable([
          ...?_tasks?.where((t) => t.id != value.id),
          value,
        ]);
      } else if (action == 'delete') {
        _tasks = _tasks == null
            ? null
            : List.unmodifiable(_tasks!.where((t) => t.id != id));
      }
      try {
        await _persist();
      } catch (_) {
        _notice =
            'The server confirmed the change. Its local request record could not be cleared.';
      }
      await refresh();
      if (_error != null) {
        _notice = 'The change was confirmed. The list could not be refreshed.';
      }
      return value;
    } catch (e) {
      final notSent = !sent || e is TaskPreflightFailure;
      final definite =
          notSent ||
          e is AdministrationFailure ||
          (e is CronHttpException && !e.uncertain);
      final partial = e is CronHttpException && e.statusCode == 424;
      if (definite && !partial) _uncertain.remove(id);
      if (partial && e.detail is Map) {
        final detail = e.detail as Map;
        _uncertain[id] =
            _immutableJournalValue({
                  'action': 'registration',
                  'job_id': detail['job_id'],
                })
                as Map<String, dynamic>;
        final jobId = detail['job_id'];
        if (jobId is String) {
          try {
            final saved = await repository.get(jobId);
            _tasks = List.unmodifiable([
              ...?_tasks?.where((t) => t.id != jobId),
              saved,
            ]);
          } catch (_) {
            /* Keep the saved identity even if readback is offline. */
          }
        }
      }
      try {
        await _persist();
      } catch (_) {
        /* Keep the in-memory guard. */
      }
      if (e is CronHttpException && e.statusCode == 424) {
        await refresh();
        _notice =
            '${e.description}${savedUnregisteredId == null ? '' : ' Saved task: $savedUnregisteredId.'}';
      }
      _error = definite
          ? '${taskFailure(e)}${notSent ? ' Nothing was sent.' : ''}'
          : 'Result not confirmed. The server may have received this request. Refresh and review before sending it again.';
      rethrow;
    } finally {
      _busy.remove(id);
      _emit();
      _collect();
    }
  }

  /// Called only after an explicit user review. This never repeats the request.
  Future<void> acknowledgeUncertainty(String id) async {
    if (stopping(id) || _busy.contains(id) && !_stopUncertain(id)) return;
    if (!_busy.contains(id)) _uncertain.remove(id);
    if (_stopUncertain(id)) _stops.remove(id);
    _stopRecoveryFailed = false;
    await _persist();
    await _persistStops();
    _emit();
  }

  void _requireOwner(ScheduledTask task) {
    if (task.profileName != repository.profile.name) {
      throw const TaskPreflightFailure('The task belongs to another profile.');
    }
  }

  Future<ScheduledTask?> act(ScheduledTask task, String action) async {
    _requireOwner(task);
    return _mutate(task.id, action, () => repository.action(task.id, action));
  }

  Future<bool?> delete(ScheduledTask task) async {
    _requireOwner(task);
    return _mutate(task.id, 'delete', () async {
      await repository.delete(task.id);
      return true;
    });
  }

  Future<ScheduledTask?> save(
    Map<String, dynamic> values, {
    ScheduledTask? original,
  }) {
    if (original != null) _requireOwner(original);
    final intent = original == null
        ? null
        : TaskEditIntent(baseline: original, values: values);
    final captured = Map<String, dynamic>.unmodifiable(values);
    return _mutate(
      original?.id ?? '__create__',
      original == null ? 'create' : 'edit',
      () => intent == null
          ? repository.create(captured)
          : repository.update(intent),
    );
  }

  Future<ScheduledTask?> instantiate(
    TaskTemplate template,
    Map<String, String> values,
  ) => _mutate(
    '__create__',
    'create',
    () => repository.instantiate(template, values),
  );

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

/// Journal JSON can retain child maps/lists after recovery. Freeze each record
/// once at admission so an observation cannot mutate any retained descendant.
Object? _immutableJournalValue(Object? value) => switch (value) {
  Map value => Map<String, dynamic>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _immutableJournalValue(entry.value),
  }),
  List value => List<Object?>.unmodifiable(value.map(_immutableJournalValue)),
  _ => value,
};
