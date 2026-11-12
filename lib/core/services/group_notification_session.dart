import 'bots_preferences.dart';
import '../models/hermes_question.dart';
import '../models/notification_input.dart';
import '../models/notification_focus.dart';
import '../models/chat_notification_content.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/group_notification.dart';
import '../models/hermes_profile.dart';
import 'bot_group_read_state.dart';
import 'bots_repository.dart';
import 'group_observations.dart';
import '../models/bots.dart';

typedef GroupNotificationRead =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

final class _WatchedGroup {
  _WatchedGroup(this.title, this.cursor);
  String title;
  int cursor;
  int sending = 0;
  final awaiting = <String>{};
  final discarding = <String>{};
  bool working = false, blocked = false, uncertain = false, pending = false;
  List<BotGroupAction> approvals = const [];
  int revision = 0;
  String? submitting;
  final accepted = <String, String>{};
  final errors = <String, String>{};
  bool get active =>
      working ||
      sending > 0 ||
      pending ||
      awaiting.isNotEmpty ||
      approvals.isNotEmpty;
}

/// Owns room work, replay cursors and delivery ordering for one connection.
/// Private bot runtime states never establish shared discussion completion.
class GroupNotificationSession extends ChangeNotifier {
  GroupNotificationSession({
    required this.scope,
    required this.instance,
    required this.preferences,
    required this.read,
    required this.observations,
    required this.publish,
    required this.publishInputs,
    required this.command,
    required this.clearRead,
    this.pollInterval = const Duration(seconds: 5),
  }) {
    final saved = preferences.getString(_storageKey);
    if (saved != null) {
      try {
        final values = jsonDecode(saved) as Map<String, dynamic>;
        for (final entry in values.entries) {
          if (entry.value is int && entry.value >= 0) {
            _cursors[entry.key] = entry.value as int;
          }
        }
      } catch (_) {
        /* Unusable local cursors establish a fresh baseline. */
      }
    }
    final pending = preferences.getString(_pendingStorageKey);
    if (pending != null) {
      final values = _map(jsonDecode(pending));
      for (final entry in values.entries) {
        final value = _map(entry.value);
        final title = value['title'], events = value['events'];
        if (entry.key.isEmpty ||
            title is! String ||
            events is! List ||
            events.any((event) => event is! String || event.isEmpty)) {
          throw const FormatException('Invalid pending group send');
        }
        _groups[entry.key] = _WatchedGroup(title, _cursors[entry.key] ?? -1)
          ..awaiting.addAll(events.cast<String>())
          ..uncertain = true;
      }
    }
  }
  final WorkspaceScope scope;
  final String instance;
  final SharedPreferences preferences;
  final GroupNotificationRead read, command;
  final GroupObservations observations;
  final Future<void> Function(GroupAnswerNotification) publish;
  final Future<void> Function(GroupInputNotification) publishInputs;
  final Future<void> Function(GroupNotificationTarget, int) clearRead;
  final Duration pollInterval;
  final _groups = <String, _WatchedGroup>{};
  final _cursors = <String, int>{};
  String get _storageKey =>
      'group_notification_sequences/${scope.connectionIdentity}';
  String get _pendingStorageKey =>
      'group_notification_pending_sends/${scope.connectionIdentity}';
  Future<void> _writes = Future.value();
  bool _closed = false, _activated = false, _foreground = true, _again = false;
  Future<void>? _refreshing;
  Timer? _timer;

  bool get hasActiveGroups => _groups.values.any((group) => group.active);
  Iterable<({String roomId, String title, String state})>
  get monitoringGroups sync* {
    for (final entry in _groups.entries) {
      final group = entry.value;
      if (group.active) {
        yield (
          roomId: entry.key,
          title: group.title,
          state: group.uncertain
              ? 'reconnecting'
              : group.blocked
              ? 'needs input'
              : 'working',
        );
      }
    }
  }

  void _changed() {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;
    if (_activated && (_foreground || hasActiveGroups)) {
      _timer = Timer(pollInterval, () => unawaited(refresh()));
    }
    notifyListeners();
  }

  void setForeground(bool value) {
    if (_closed || _foreground == value) return;
    _foreground = value;
    _changed();
    if (value && _activated) unawaited(refresh());
  }

  Future<void> activate() {
    _activated = true;
    return refresh();
  }

  Future<void> beginSend(String roomId, String title, String eventId) async {
    if (_closed) return;
    _activated = true;
    final group = _groups.putIfAbsent(
      roomId,
      () => _WatchedGroup(title, _cursors[roomId] ?? -1),
    );
    group.sending++;
    final wireId = BotsRepository.groupUserEventId(eventId);
    final remember = group.cursor < 0 && group.awaiting.add(wireId);
    _changed();
    if (remember) {
      try {
        await _savePending();
      } catch (_) {
        group.awaiting.remove(wireId);
        group.sending--;
        _changed();
        rethrow;
      }
    }
  }

  Future<void> endSend(
    String roomId,
    String eventId, {
    required bool dispatched,
    int? sequence,
  }) async {
    if (_closed) return;
    final group = _groups[roomId];
    if (group == null) return;
    if (sequence != null && (!dispatched || sequence < 1)) {
      throw const FormatException('Invalid accepted group send sequence');
    }
    try {
      if (sequence != null && group.cursor < 0) {
        final saved = await _saveCursor(roomId, sequence);
        if (saved > group.cursor) group.cursor = saved;
      }
      if (!dispatched || sequence != null) {
        final wireId = BotsRepository.groupUserEventId(eventId);
        if (!dispatched) group.discarding.add(wireId);
        await _removePending(roomId, {wireId});
        group.discarding.remove(wireId);
      }
      // A lost acknowledgement keeps the exact durable send identity until its
      // accepted stock event is found, including after an engine restart.
      await refresh();
    } catch (_) {
      // Notification persistence failure cannot revoke a confirmed chat send.
      // Its durable identity and active lease retain replay/cleanup for retry.
      group.uncertain = true;
      group.pending = true;
    } finally {
      if (group.sending > 0) group.sending--;
      if (dispatched && group.uncertain) group.pending = true;
      _changed();
    }
  }

  Future<void> acknowledge(String roomId, int sequence) =>
      clearRead(GroupNotificationTarget(scope, roomId), sequence);

  Future<void> refresh() {
    if (_closed) return Future.value();
    if (_refreshing != null) {
      _again = true;
      return _refreshing!;
    }
    _refreshing =
        (() async {
          do {
            _again = false;
            await _refresh();
          } while (_again && !_closed);
        })().whenComplete(() {
          _refreshing = null;
        });
    return _refreshing!;
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map) throw const FormatException('Missing group observation');
    return Map<String, dynamic>.from(value);
  }

  Future<T> _write<T>(Future<T> Function() run) {
    final result = _writes.then((_) => run());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<int> _saveCursor(String roomId, int sequence) => _write(() async {
    final saved = _cursors[roomId] ?? -1;
    if (sequence <= saved) return saved;
    final next = {..._cursors, roomId: sequence};
    if (!await preferences.setString(_storageKey, jsonEncode(next))) {
      throw StateError('Group notification cursor could not be saved');
    }
    _cursors.addAll(next);
    return sequence;
  });

  Future<void> _savePending() => _write(() async {
    final next = {
      for (final entry in _groups.entries)
        if (entry.value.awaiting.isNotEmpty)
          entry.key: {
            'title': entry.value.title,
            'events': entry.value.awaiting.toList()..sort(),
          },
    };
    if (!await preferences.setString(_pendingStorageKey, jsonEncode(next))) {
      throw StateError('Pending group sends could not be saved');
    }
  });

  Future<void> _removePending(String id, Set<String> events) async {
    final group = _groups[id]!;
    final removed = group.awaiting.intersection(events);
    if (removed.isEmpty) return;
    group.awaiting.removeAll(removed);
    try {
      await _savePending();
    } catch (_) {
      group.awaiting.addAll(removed);
      rethrow;
    }
  }

  Future<void> _refresh() async {
    try {
      final rooms = <String, String>{};
      var offset = 0;
      while (!_closed) {
        final result = await read('groups.list', {
          'limit': 100,
          'offset': offset,
        });
        if (_closed) return;
        final rows = result['rooms'];
        if (rows is! List) throw const FormatException('Missing group list');
        for (final raw in rows) {
          final row = _map(raw);
          final id = row['room_id'], name = row['name'];
          if (id is! String ||
              id.isEmpty ||
              name is! String ||
              name.trim().isEmpty ||
              rooms.containsKey(id)) {
            throw const FormatException('Invalid group identity');
          }
          rooms[id] = name;
        }
        final next = result['next_offset'];
        if (next == null) break;
        if (next is! int || next <= offset || rows.isEmpty) {
          throw const FormatException('Invalid group list cursor');
        }
        offset = next;
      }
      // Missing rooms are uncertain; they cannot release previously seen work.
      for (final entry in _groups.entries) {
        if (!rooms.containsKey(entry.key) && entry.value.active) {
          try {
            await _refreshRoom(entry.key, entry.value);
          } catch (_) {
            entry.value.uncertain = true;
          }
        }
      }
      for (final entry in rooms.entries) {
        if (_closed) return;
        final group = _groups.putIfAbsent(
          entry.key,
          () => _WatchedGroup(entry.value, _cursors[entry.key] ?? -1),
        );
        group.title = entry.value;
        try {
          await _refreshRoom(entry.key, group);
        } catch (_) {
          group.uncertain = true;
        }
      }
    } catch (_) {
      for (final group in _groups.values) {
        group.uncertain = true;
      }
    } finally {
      _changed();
    }
  }

  Future<void> _publishInputs(String id, _WatchedGroup group) async {
    await publishInputs(
      GroupInputNotification(
        target: GroupNotificationTarget(scope, id),
        title: group.title,
        instance: instance,
        inputs: [
          for (final action in group.approvals)
            if (!group.accepted.containsKey(groupApprovalFocusId(action)))
              NotificationInput(
                focus: NotificationFocus(
                  'approval',
                  groupApprovalFocusId(action),
                ),
                content: ChatNotificationContent.approval(
                  action.command,
                  action.description,
                ),
                choices: action.choices,
                submitting: group.submitting == groupApprovalFocusId(action),
                error: group.errors[groupApprovalFocusId(action)],
              ),
        ],
      ),
    );
    final history = BotsPreferences(
      preferences,
    ).questions(scope.connectionIdentity, id);
    for (final action in group.approvals) {
      final decision = group.accepted[groupApprovalFocusId(action)];
      if (decision != null) {
        history.settle(action.key, HermesQuestionStatus.decision(decision));
      }
    }
    await history.flush();
  }

  /// Re-read the exact stock runtime before a native decision. A notification
  /// snapshot can identify a request, but cannot grant permission by itself.
  Future<bool> resolveApproval(
    String roomId,
    String focus,
    String choice,
    String? previewCommand,
  ) async {
    if (_closed || !{'once', 'deny'}.contains(choice)) return false;
    final group = _groups.putIfAbsent(roomId, () => _WatchedGroup('Group', -1));
    if (group.submitting != null) return false;
    group.revision++;
    group.submitting = focus;
    group.errors.remove(focus);
    var observed = false;
    try {
      if (group.approvals.isNotEmpty) await _publishInputs(roomId, group);
      final state = await read('groups.state', {'room_id': roomId});
      if (_closed) return false;
      final decoded = BotsRepository.decodeGroupState(
        scope,
        instance,
        roomId,
        state,
      );
      if (decoded.room == null) {
        observed = true;
        group.approvals = const [];
        return false;
      }
      final runtime = decoded.runtime;
      if (runtime == null) {
        throw StateError('Group approval could not be checked');
      }
      observed = true;
      BotsPreferences(
        preferences,
      ).observeQuestions(decoded.room!, runtime, decoded.latestSequence);
      group.title = decoded.room!.name;
      group.approvals = BotsPreferences(
        preferences,
      ).pendingApprovals(decoded.room!, runtime);
      final action = group.approvals
          .where((a) => groupApprovalFocusId(a) == focus)
          .firstOrNull;
      if (action == null || group.accepted.containsKey(focus)) return false;
      if (!action.choices.contains(choice) ||
          (choice != 'deny' && action.command.trim() != previewCommand)) {
        throw StateError('Review the current approval in the group');
      }
      final result = await command('groups.approve', {
        'room_id': roomId,
        'task_id': action.task,
        'member_id': action.member,
        'request_id': action.request,
        'execution_generation': action.generation,
        'choice': choice,
      });
      if (result['approved'] != true) {
        throw StateError('Decision not confirmed');
      }
      group.accepted[focus] = choice;
      return true;
    } catch (_) {
      group.errors[focus] = 'Decision not confirmed. Open the group to review.';
      rethrow;
    } finally {
      group.revision++;
      group.submitting = null;
      if (!_closed) {
        if (observed || group.approvals.isNotEmpty) {
          await _publishInputs(roomId, group);
        }
        _changed();
        unawaited(refresh());
      }
    }
  }

  Future<void> _refreshRoom(String id, _WatchedGroup group) async {
    if (group.submitting != null) return;
    final revision = group.revision;
    if (group.discarding.isNotEmpty) {
      await _removePending(id, Set.of(group.discarding));
      group.discarding.clear();
    }
    final state = await read('groups.state', {
      'room_id': id,
      'include_disbanded': true,
    });
    if (_closed) return;
    if (revision != group.revision) return;
    final decoded = BotsRepository.decodeGroupState(scope, instance, id, state);
    final room = decoded.room;
    if (room == null) {
      observations.forget(id);
      group.approvals = const [];
      await _publishInputs(id, group);
      group.working = false;
      group.pending = false;
      await _removePending(id, Set.of(group.awaiting));
      group.uncertain = false;
      return;
    }
    final runtime = decoded.runtime;
    if (runtime == null) {
      throw const FormatException('Invalid shared group state');
    }
    BotsPreferences(
      preferences,
    ).observeQuestions(room, runtime, decoded.latestSequence);
    group.approvals = BotsPreferences(
      preferences,
    ).pendingApprovals(room, runtime);
    final identities = group.approvals.map(groupApprovalFocusId).toSet();
    group.accepted.removeWhere((key, _) => !identities.contains(key));
    group.errors.removeWhere((key, _) => !identities.contains(key));
    if (runtime.working || runtime.blocked) {
      group.working = true;
      group.blocked = runtime.blocked;
      _changed();
    }
    await _publishInputs(id, group);
    if (_closed || revision != group.revision) return;
    final latest = decoded.latestSequence;
    if (latest < group.cursor) {
      throw const FormatException('Group sequence moved backwards');
    }
    final working = runtime.working || runtime.blocked;
    if (working) {
      group.working = true;
      group.uncertain = false;
      _changed();
    }
    if (group.cursor < 0 && group.awaiting.isEmpty) {
      // First discovery is a quiet history baseline, including an active room.
      final saved = await _saveCursor(id, latest);
      if (_closed) return;
      if (saved > group.cursor) group.cursor = saved;
      observations.discover(room, latest);
    } else if (latest > group.cursor || group.awaiting.isNotEmpty) {
      group.pending = true;
      _changed();
      final awaiting = Set.of(group.awaiting);
      final accepted = <String, int>{};
      var cursor = awaiting.isNotEmpty || group.cursor < 0 ? 0 : group.cursor;
      BotGroupEvent? answer;
      final observation = observations.beginRead(room);
      try {
        do {
          final page = await read('groups.log', {
            'room_id': id,
            'since_seq': cursor,
            'limit': 100,
          });
          if (_closed) return;
          final decoded = BotsRepository.decodeGroupLog(
            id,
            page,
            since: cursor,
          );
          if (decoded.latestSequence < latest) {
            throw const FormatException('Invalid group log cursor');
          }
          // Canonical message facts precede notification eligibility and delivery.
          // Even an already-read answer or failed post remains an observed message.
          observation.add(decoded, since: cursor);
          for (final event in decoded.events) {
            if (awaiting.contains(event.eventId)) {
              if (event.kind != 'message.user') {
                throw const FormatException(
                  'Invalid accepted group send event',
                );
              }
              accepted[event.eventId] = event.sequence;
            }
            if (event.kind == 'message.member' &&
                event.text.trim().isNotEmpty) {
              answer = event;
            }
          }
          cursor = decoded.cursor;
          if (!decoded.hasMore) break;
        } while (!_closed);
      } finally {
        if (!_closed) observation.publish();
      }
      if (_closed) return;
      if (group.awaiting.any((event) => !accepted.containsKey(event))) {
        throw StateError('Group send acceptance is still uncertain');
      }
      if (cursor < group.cursor) {
        throw const FormatException('Group log does not cover accepted send');
      }
      final baseline = group.cursor >= 0
          ? group.cursor
          : accepted.isEmpty
          ? cursor
          : accepted.values.reduce((a, b) => a < b ? a : b);
      if (answer != null) {
        final sequence = answer.sequence;
        // Actual viewport receipts, not opening a route, suppress read replies.
        final target = GroupNotificationTarget(scope, id);
        final readSequence = BotGroupReadState.savedSequence(
          preferences,
          target.key,
        );
        if (sequence > baseline && sequence > readSequence) {
          await publish(
            GroupAnswerNotification(
              target: target,
              title: group.title,
              instance: instance,
              sequence: sequence,
              text: answer.text,
            ),
          );
        }
        final reached = BotGroupReadState.savedSequence(
          preferences,
          target.key,
        );
        if (sequence <= reached) await clearRead(target, reached);
      }
      if (_closed) return;
      final saved = await _saveCursor(id, cursor);
      if (_closed) return;
      if (saved > group.cursor) group.cursor = saved;
      await _removePending(id, accepted.keys.toSet());
      group.pending = false;
    }
    group.working = working;
    group.blocked = runtime.blocked;
    group.pending = false;
    group.uncertain = false;
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    super.dispose();
  }
}
