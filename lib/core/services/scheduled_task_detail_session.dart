import '../models/profile_session_key.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/scheduled_task.dart';
import 'scheduled_tasks_controller.dart';
import 'profile_workspace_controller.dart';

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
  }) {
    _timer = (timer ?? Timer.periodic)(const Duration(seconds: 30), (_) {
      if (!_disposed &&
          _resumed &&
          isVisible() &&
          !controller.loading &&
          controller.error == null) {
        unawaited(controller.refresh());
      }
    });
  }
  final ScheduledTasksController controller;
  final bool Function() isVisible;
  late final Timer _timer;
  bool _resumed = true, _disposed = false;
  void resumed(bool value) {
    if (_disposed) return;
    _resumed = value;
    if (value && isVisible() && !controller.loading) {
      unawaited(controller.refresh());
    }
  }

  void start() {
    if (!_disposed && !controller.loading) unawaited(controller.refresh());
  }

  void dispose() {
    _disposed = true;
    _timer.cancel();
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
  }) {
    if (initial.profileName != controller.repository.profile.name) {
      throw ArgumentError('Task detail belongs to another profile');
    }
    controller.addListener(_emit);
    _timer = (timer ?? Timer.periodic)(const Duration(seconds: 8), (_) {
      if (!_disposed &&
          _resumed &&
          isVisible() &&
          !_loading &&
          _error == null &&
          controller.error == null) {
        unawaited(refresh());
      }
    });
  }
  final ScheduledTasksController controller;
  final ScheduledTask initial;
  final bool Function() isVisible;
  final Future<void> Function(ProfileSessionKey) onOpenSession;
  late final Timer _timer;
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

  void resumed(bool value) {
    if (_disposed) return;
    _resumed = value;
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
    _timer.cancel();
    controller.removeListener(_emit);
    super.dispose();
  }
}
