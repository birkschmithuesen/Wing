import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/services/recent_conversation_snapshots.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/hermes_profile.dart';

class _Snapshot implements RecentConversationSnapshot {
  _Snapshot(this.byteSize);
  @override
  final int byteSize;
  int disposals = 0;
  @override
  void dispose() => disposals++;
}

void main() {
  const a = RecentConversationKey.group('host/a');
  const b = RecentConversationKey.group('host/b');
  const c = RecentConversationKey.group('host/c');
  const environment = ('dark', 390, 844, 1.0);

  late RecentConversationSnapshots cache;
  var disposed = false;
  setUp(() {
    cache = RecentConversationSnapshots(byteLimit: 300);
    disposed = false;
  });
  tearDown(() {
    if (!disposed) cache.dispose();
  });

  void record(RecentConversationKey key, _Snapshot snapshot) => cache.record(
    key,
    snapshot,
    live: true,
    revision: 1,
    environment: environment,
  );

  test('borrowers reuse a snapshot only in its rendering environment', () {
    final first = _Snapshot(100);
    record(a, first);
    expect(cache.snapshotFor(a, environment: environment), same(first));
    expect(cache.snapshotFor(a, environment: ('light', 390, 844, 1.0)), isNull);
    expect(cache.snapshotFor(a, environment: environment), same(first));
    expect(first.disposals, 0);
  });

  test('replacement releases the old image before notifying borrowers', () {
    final first = _Snapshot(100), replacement = _Snapshot(100);
    record(a, first);
    final observed = <RecentConversationSnapshot?>[];
    cache.addListener(() {
      expect(first.disposals, 1);
      observed.add(cache.snapshotFor(a, environment: environment));
    });
    record(a, replacement);
    expect(observed, [replacement]);
    expect(cache.retainedBytes, 100);
  });

  test(
    'workspace disposal releases retained images and rejects late images',
    () {
      final retained = _Snapshot(100);
      record(a, retained);
      cache.dispose();
      disposed = true;
      expect(retained.disposals, 1);
      expect(cache.retainedBytes, 0);
      final late = _Snapshot(100);
      record(a, late);
      expect(late.disposals, 1);
      expect(cache.snapshotFor(a, environment: environment), isNull);
    },
  );

  test('in-flight readback evicts distant images before visible images', () {
    final visible = _Snapshot(100), distant = _Snapshot(100);
    record(a, visible);
    record(b, distant);
    cache.retain({a});
    cache.reserve(150);
    expect(visible.disposals, 0);
    expect(distant.disposals, 1);
    expect(cache.retainedBytes + cache.reservedBytes, lessThanOrEqualTo(300));
  });

  test('releasing readback reservations makes room for new snapshots', () {
    cache.reserve(250);
    final rejected = _Snapshot(100);
    record(a, rejected);
    expect(rejected.disposals, 1);
    cache.release(250);
    final accepted = _Snapshot(100);
    record(a, accepted);
    expect(cache.reservedBytes, 0);
    expect(cache.snapshotFor(a, environment: environment), same(accepted));
  });

  test('oversize images are rejected without evicting current images', () {
    final visible = _Snapshot(100), oversize = _Snapshot(301);
    record(a, visible);
    record(c, oversize);
    expect(oversize.disposals, 1);
    expect(visible.disposals, 0);
    expect(cache.snapshotFor(a, environment: environment), same(visible));
  });

  test('invalidating a snapshot releases it and informs borrowers once', () {
    final snapshot = _Snapshot(100);
    record(a, snapshot);
    var notifications = 0;
    cache.addListener(() => notifications++);
    cache.invalidate(a);
    cache.invalidate(a);
    expect(snapshot.disposals, 1);
    expect(cache.snapshotFor(a, environment: environment), isNull);
    expect(cache.retainedBytes, 0);
    expect(notifications, 1);
  });

  BotGroup group(String id, {String identity = 'host'}) => BotGroup(
    scope: WorkspaceScope(
      connectionId: 'connection',
      connectionIdentity: identity,
      profileName: 'default',
    ),
    instance: identity,
    id: id,
    name: id,
    members: const [],
    observationComplete: true,
  );
  BotGroupEvent event(int seq, {String text = 'message'}) => BotGroupEvent(
    eventId: 'event-$seq',
    sequence: seq,
    kind: 'message.member',
    actor: 'member',
    actorId: 'pace',
    actorName: 'Pace',
    timestamp: DateTime.utc(2026, 10, 12),
    text: text,
  );

  late RecentGroupMessages messages;
  setUp(() => messages = RecentGroupMessages());
  tearDown(() => messages.dispose());

  test('decoded tails return the requested most recent messages', () {
    final room = group('room');
    messages.record(room, [
      for (var seq = 1; seq <= 12; seq++) event(seq),
    ], complete: true);
    expect(messages.borrow(room, limit: 6)!.map((e) => e.sequence), [
      7,
      8,
      9,
      10,
      11,
      12,
    ]);
  });

  test(
    'truncated decoded tails cannot claim coverage they no longer retain',
    () {
      final room = group('room');
      messages.record(room, [
        for (var seq = 1; seq <= 12; seq++) event(seq),
      ], complete: true);
      expect(messages.borrow(room, limit: 11), isNull);
    },
  );

  for (final identity in ['host', 'other auth']) {
    test('decoded tails reject a different observation for $identity', () {
      final room = group('room');
      messages.record(room, [event(1)], complete: true);
      expect(
        messages.borrow(group('room', identity: identity), limit: 1),
        isNull,
      );
    });
  }

  test('metadata replacement transfers borrowing to the new observation', () {
    final room = group('room');
    messages.record(room, [event(1)], complete: true);
    final decorated = room.withIcon();
    messages.rebind(room, decorated);
    expect(messages.borrow(room, limit: 1), isNull);
    expect(messages.borrow(decorated, limit: 1)!.single.sequence, 1);
  });

  test('disposed message cache rejects late records', () {
    final room = group('room');
    messages.record(room, [event(1)], complete: true);
    messages.dispose();
    messages.record(room, [event(2)], complete: true);
    expect(messages.borrow(room, limit: 1), isNull);
    expect(messages.retainedBytes, 0);
  });

  test('room budget evicts the oldest observation across instances', () {
    final rooms = [
      for (var index = 0; index < 12; index++)
        group('$index', identity: 'host$index'),
    ];
    for (final room in rooms) {
      messages.record(room, [event(1)], complete: true);
    }
    expect(messages.length, RecentGroupMessages.roomLimit);
    expect(messages.borrow(rooms.first, limit: 1), isNull);
    expect(messages.borrow(rooms.last, limit: 1)!.single.sequence, 1);
  });

  test('an oversize decoded tail is not retained', () {
    final room = group('oversize');
    messages.record(room, [
      event(1, text: 'x' * RecentGroupMessages.byteLimit),
    ], complete: true);
    expect(messages.borrow(room, limit: 1), isNull);
    expect(
      messages.retainedBytes,
      lessThanOrEqualTo(RecentGroupMessages.byteLimit),
    );
  });

  test('borrowed message lists cannot mutate the cached tail', () {
    final room = group('room');
    messages.record(room, [event(1)], complete: true);
    expect(
      () => messages.borrow(room, limit: 1)!.clear(),
      throwsUnsupportedError,
    );
    expect(messages.borrow(room, limit: 1)!.single.sequence, 1);
  });
}
