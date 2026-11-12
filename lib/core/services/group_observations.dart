import 'package:flutter/foundation.dart';
import '../models/bots.dart';
import '../models/hermes_profile.dart';

/// Latest validated message facts; coverage is independent of delivery/replay
/// cursors and never acknowledges what a human has read.
@immutable
final class GroupMessageObservation {
  const GroupMessageObservation({
    required this.room,
    required this.message,
    required this.answer,
    required this.messageThrough,
    required this.answerThrough,
    required this.latestSequence,
    required this.gatewayId,
    required this.epoch,
  });
  final BotGroup room;
  final BotGroupEvent? message, answer;
  final int? messageThrough, answerThrough;
  final int latestSequence, epoch;
  final String gatewayId;
  int? get coverage => messageThrough == null || answerThrough == null
      ? null
      : messageThrough! < answerThrough!
      ? messageThrough
      : answerThrough;
  BotGroup project(BotGroup decorated) => decorated.withMessageObservation(
    BotGroup(
      scope: room.scope,
      instance: room.instance,
      id: room.id,
      name: room.name,
      members: room.members,
      observationComplete: (coverage ?? -1) >= latestSequence,
      latestSequence: latestSequence,
      messageCoverageSequence: coverage,
      preview: message?.text ?? '',
      lastMessageAt: message?.timestamp,
      lastMessageSequence: message?.sequence ?? 0,
      lastAnswerSequence: answer?.sequence ?? 0,
    ),
  );
}

BotGroup _identity(BotGroup room) => BotGroup(
  scope: room.scope,
  instance: room.instance,
  id: room.id,
  name: room.name,
  members: room.members,
  observationComplete: false,
);

BotGroupEvent? _newest(BotGroupEvent? before, BotGroupEvent? found) =>
    found != null && (before == null || found.sequence > before.sequence)
    ? found
    : before;
int? _furthest(int? before, int? next) => before == null
    ? next
    : next == null || before >= next
    ? before
    : next;

/// Accumulates only two messages across one caller-owned read pass. Publication
/// waits for that pass to settle, so partial pages cannot start a competing read.
final class GroupObservationRead {
  GroupObservationRead._(this._owner, this.room, this._token)
    : _value = _owner.forRoom(room.id);
  final GroupObservations _owner;
  final Object _token;
  final BotGroup room;
  GroupMessageObservation? _value;
  bool _hasPage = false;
  int? _start, _end;
  void add(BotGroupPage page, {required int since}) {
    if (since < 0 || page.cursor < since) {
      throw ArgumentError('Invalid group coverage');
    }
    if (_start != null && (since > _end! || page.cursor < _start!)) {
      throw ArgumentError('Disconnected group observation pages');
    }
    _start = _start == null || since < _start! ? since : _start;
    _end = _end == null || page.cursor > _end! ? page.cursor : _end;
    final old = _value;
    BotGroupEvent? message, answer;
    for (final event in page.events) {
      if (!event.isMessage) continue;
      message = event;
      if (event.kind == 'message.member' && event.text.trim().isNotEmpty) {
        answer = event;
      }
    }
    int? advance(int? before, BotGroupEvent? found) =>
        _start == 0 ||
            found != null &&
                found.sequence > _start! &&
                found.sequence <= _end! ||
            before != null && _start! <= before
        ? _furthest(before, _end)
        : before;
    _value = GroupMessageObservation(
      room: _identity(room),
      message: _newest(old?.message, message),
      answer: _newest(old?.answer, answer),
      messageThrough: advance(
        old?.messageThrough,
        _newest(old?.message, message),
      ),
      answerThrough: advance(old?.answerThrough, _newest(old?.answer, answer)),
      latestSequence: _furthest(old?.latestSequence, page.latestSequence)!,
      gatewayId: page.gatewayId,
      epoch: page.epoch,
    );
    _hasPage = true;
  }

  void publish() {
    if (_hasPage) _owner._admit(_value!, _token);
    _hasPage = false;
  }
}

/// Connection-retained canonical message facts. Bots borrows decorated immutable
/// projections; the notification journal owns only delivery/recovery progress.
/// Retains at most the latest message and answer per known room, never log pages.
final class GroupObservations extends ChangeNotifier {
  GroupObservations(this.scope);
  final WorkspaceScope scope;
  final _rooms = <String, GroupMessageObservation>{};
  final _tokens = <String, Object>{};
  bool _closed = false;
  Iterable<GroupMessageObservation> get values =>
      List.unmodifiable(_rooms.values);
  GroupMessageObservation? forRoom(String id) => _rooms[id];

  GroupObservationRead beginRead(BotGroup room) {
    if (room.scope != scope) {
      throw ArgumentError('Wrong group observation owner');
    }
    return GroupObservationRead._(
      this,
      room,
      _tokens.putIfAbsent(room.id, Object.new),
    );
  }

  void discover(BotGroup room, int latestSequence) {
    if (_closed) return;
    if (room.scope != scope) {
      throw ArgumentError('Wrong group observation owner');
    }
    if (_rooms.containsKey(room.id)) return;
    _tokens.putIfAbsent(room.id, Object.new);
    _rooms[room.id] = GroupMessageObservation(
      room: _identity(room),
      message: null,
      answer: null,
      messageThrough: null,
      answerThrough: null,
      latestSequence: latestSequence,
      gatewayId: '',
      epoch: 0,
    );
    notifyListeners();
  }

  void record(BotGroup room, BotGroupPage page, {required int since}) =>
      beginRead(room)
        ..add(page, since: since)
        ..publish();

  void _admit(GroupMessageObservation next, Object token) {
    if (_closed || !identical(_tokens[next.room.id], token)) return;
    final old = _rooms[next.room.id];
    final newest = old != null && old.latestSequence > next.latestSequence
        ? old
        : next;
    final merged = GroupMessageObservation(
      room: newest.room,
      message: _newest(old?.message, next.message),
      answer: _newest(old?.answer, next.answer),
      messageThrough: _furthest(old?.messageThrough, next.messageThrough),
      answerThrough: _furthest(old?.answerThrough, next.answerThrough),
      latestSequence: newest.latestSequence,
      gatewayId: newest.gatewayId,
      epoch: newest.epoch,
    );
    bool sameMembers(BotGroup a, BotGroup b) => listEquals(
      [
        for (final member in a.members)
          (member.id, member.profile, member.handle, member.name),
      ],
      [
        for (final member in b.members)
          (member.id, member.profile, member.handle, member.name),
      ],
    );
    if (old != null &&
        identical(old.message, merged.message) &&
        identical(old.answer, merged.answer) &&
        old.messageThrough == merged.messageThrough &&
        old.answerThrough == merged.answerThrough &&
        old.latestSequence == merged.latestSequence &&
        old.gatewayId == merged.gatewayId &&
        old.epoch == merged.epoch &&
        old.room.name == merged.room.name &&
        sameMembers(old.room, merged.room)) {
      return;
    }
    _rooms[next.room.id] = merged;
    notifyListeners();
  }

  /// Only a confirmed catalog/disband may retire canonical room membership.
  void retainRooms(Set<String> ids) {
    if (_closed) return;
    final before = _rooms.length;
    _rooms.removeWhere((id, _) => !ids.contains(id));
    _tokens.removeWhere((id, _) => !ids.contains(id));
    if (_rooms.length != before) notifyListeners();
  }

  void forget(String id) {
    if (_closed) return;
    _tokens.remove(id);
    if (_rooms.remove(id) != null) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _rooms.clear();
    _tokens.clear();
    super.dispose();
  }
}
