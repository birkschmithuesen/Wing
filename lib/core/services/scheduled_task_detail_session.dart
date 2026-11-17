import '../models/profile_session_key.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/scheduled_task.dart';
import 'scheduled_tasks_controller.dart';
import 'profile_workspace_controller.dart';
import 'wing_bg_watch.dart';

typedef TaskPollTimer = Timer Function(Duration, void Function(Timer));

/// Destination-owned preparation and retry; the workspace owns durable delivery.
class ScheduledTaskInvestigationSession {
  ScheduledTaskInvestigationSession(this.request, this._workspace) {
    final owner = request.owner;
    if (request.task.profileName != owner.profileName ||
        owner.connectionId != _workspace.connection.id ||
        owner.connectionIdentity != _workspace.connectionIdentity) {
      throw ArgumentError('Task investigation belongs to another workspace');
    }
  }
  final ScheduledTaskInvestigationRequest request;
  final ProfileWorkspaceController _workspace;
  ProfileChat? _prepared;
  bool _submitted = false;

  Future<ProfileSessionKey> open({required bool Function() canUse}) async {
    if (!canUse()) throw StateError('Chat opening was cancelled.');
    if (_prepared == null) {
      _prepared = await _workspace.createBrowserChat(
        profileName: request.owner.profileName,
        initialDraft: request.task.failureInvestigationPrompt,
        canDispatch: canUse,
      );
    } else if (_prepared!.reading.historyError != null) {
      await _workspace.refreshHistory(_prepared!);
    }
    if (!canUse()) throw StateError('Chat opening was cancelled.');
    if (_prepared!.reading.historyError case final error?) {
      throw StateError(error);
    }
    void requireSelection() {
      if (_workspace.switching ||
          _workspace.current?.scope != request.owner ||
          _workspace.current?.chat?.key != _prepared!.key) {
        throw StateError(
          'Chat saved in ${request.owner.profileName}. Open it from Chats.',
        );
      }
    }

    requireSelection();
    if (!_submitted) {
      // Delivery uncertainty belongs to the durable queue, never a second send.
      _submitted = true;
      await _workspace.send(_prepared!);
    }
    if (!canUse()) throw StateError('Chat opening was cancelled.');
    requireSelection();
    return _prepared!.key;
  }
}

/// Owns refresh eligibility; the view supplies only visibility/lifecycle facts.
/// It reads the retained controller's cache and never creates another cache.
class ScheduledTasksObservation {
  ScheduledTasksObservation(
    this.controller, {
    required this.isVisible,
    TaskPollTimer? timer,
  }) : _scheduleTimer = timer ?? Timer.periodic {
    _reschedule();
  }
  final ScheduledTasksController controller;
  final bool Function() isVisible;
  final TaskPollTimer _scheduleTimer;
  Timer? _timer;
  bool _resumed = true, _disposed = false;

  // Pausing must stop the timer itself, not only the work inside its
  // callback: an always-ticking Timer.periodic keeps waking the main
  // isolate even while every check inside the callback is false.
  void _reschedule() {
    _timer?.cancel();
    _timer = _disposed || !_resumed
        ? null
        : _scheduleTimer(const Duration(seconds: 30), (_) {
            WingBgWatch.instance.recordWakeup('ScheduledTasksObservation');
            if (!_disposed &&
                isVisible() &&
                !controller.loading &&
                controller.error == null) {
              unawaited(controller.refresh());
            }
          });
  }

  void resumed(bool value) {
    if (_disposed || _resumed == value) return;
    _resumed = value;
    _reschedule();
    if (value && isVisible() && !controller.loading) {
      unawaited(controller.refresh());
    }
  }

  void start() {
    if (!_disposed && !controller.loading) unawaited(controller.refresh());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

class ScheduledTaskDetailState {
  const ScheduledTaskDetailState({
    required this.task,
    required this.missing,
    required this.history,
    required this.loading,
    required this.opening,
    required this.error,
    required this.canShowMore,
    required this.atLimit,
  });
  final ScheduledTask task;
  final bool missing, loading, opening, canShowMore, atLimit;
  final List<TaskRun>? history;
  final String? error;
}

/// Route-local bounded history observation; actions/cache/journal stay with the
/// retained controller. Captured task/profile identities survive list refreshes.
class ScheduledTaskDetailSession extends ChangeNotifier {
  ScheduledTaskDetailSession(
    this.controller,
    this.initial, {
    required this.isVisible,
    required this.onOpenSession,
    TaskPollTimer? timer,
  }) : _scheduleTimer = timer ?? Timer.periodic {
    if (initial.profileName != controller.repository.profile.name) {
      throw ArgumentError('Task detail belongs to another profile');
    }
    controller.addListener(_emit);
    _reschedule();
  }
  final ScheduledTasksController controller;
  final ScheduledTask initial;
  final bool Function() isVisible;
  final Future<void> Function(ProfileSessionKey) onOpenSession;
  final TaskPollTimer _scheduleTimer;
  Timer? _timer;
  List<TaskRun>? _runs;
  String? _error;
  bool _disposed = false, _resumed = true, _loading = false, _opening = false;
  int _limit = 20, _generation = 0;
  ScheduledTaskDetailState get state => ScheduledTaskDetailState(
    task: controller.task(initial.id) ?? initial,
    missing: controller.tasks != null && controller.task(initial.id) == null,
    history: _runs,
    loading: _loading,
    opening: _opening,
    error: _error,
    canShowMore: _runs != null && _runs!.length >= _limit && _limit < 100,
    atLimit: _limit == 100 && _runs?.length == 100,
  );
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  // Pausing must stop the timer itself, not only the work inside its
  // callback: an always-ticking Timer.periodic keeps waking the main
  // isolate even while every check inside the callback is false.
  void _reschedule() {
    _timer?.cancel();
    _timer = _disposed || !_resumed
        ? null
        : _scheduleTimer(const Duration(seconds: 8), (_) {
            WingBgWatch.instance.recordWakeup('ScheduledTaskDetailSession');
            if (!_disposed &&
                isVisible() &&
                !_loading &&
                _error == null &&
                controller.error == null) {
              unawaited(refresh());
            }
          });
  }

  void resumed(bool value) {
    if (_disposed || _resumed == value) return;
    _resumed = value;
    _reschedule();
    if (value && isVisible()) unawaited(refresh());
  }

  Future<void> showMore() async {
    if (_disposed || _loading || !state.canShowMore) return;
    _limit = 100;
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _emit();
    await controller.refresh();
    if (_disposed || generation != _generation) return;
    try {
      final result = await controller.repository.runs(
        initial.id,
        limit: _limit,
      );
      if (_disposed || generation != _generation) return;
      _runs = List.unmodifiable(result);
    } catch (error) {
      if (!_disposed && generation == _generation) _error = taskFailure(error);
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _emit();
      }
    }
  }

  Future<void> open(TaskRun run) async {
    if (_disposed ||
        _opening ||
        !run.isConversation ||
        _runs?.any((row) => row.id == run.id && row.isConversation) != true) {
      return;
    }
    _opening = true;
    _emit();
    try {
      await onOpenSession(
        ProfileSessionKey(controller.repository.profile.scope, run.id),
      );
    } catch (error) {
      if (!_disposed) _error = taskFailure(error);
    } finally {
      if (!_disposed) {
        _opening = false;
        _emit();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
    controller.removeListener(_emit);
    super.dispose();
  }
}
