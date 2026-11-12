import 'package:wing/core/services/bots_preferences.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'support/bots_fixture.dart';

void main() {
  late BotsPreferences groupPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    groupPreferences = await BotsPreferences.load();
  });
  test(
    'room freshness ignores work events and reads beyond the tail',
    () async {
      final fixture = BotsFixture();
      for (var seq = 1; seq <= 150; seq++) {
        fixture.events.add({
          'room_id': 'room-1',
          'seq': seq,
          'kind': seq == 1
              ? 'message.member'
              : seq == 2
              ? 'message.user'
              : 'task.completed',
          'created_at': seq <= 2 ? 1000.0 + seq : 999999.0,
          'actor': {'kind': seq == 1 ? 'member' : 'user', 'id': 'atlas'},
          'payload': {'text': 'event $seq'},
        });
      }
      fixture.readHook = (_, method, params) async {
        if (method != 'groups.log') return null;
        final since = params['since_seq'] as int;
        final page = fixture.events
            .where((event) => event['seq'] > since)
            .take(100)
            .toList();
        final cursor = page.last['seq'];
        return {
          'events': page,
          'cursor': cursor,
          'latest_seq': 150,
          'has_more': cursor < 150,
          'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
        };
      };
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      expect(group.lastMessageAt!.millisecondsSinceEpoch, 1002000);
      expect(group.lastMessageSequence, 2);
      expect(group.lastAnswerSequence, 1);
      expect(group.preview, 'event 2');
      final facts = fixture.repository.groupObservations.forRoom(group.id)!;
      expect(facts.coverage, 150);
      expect(facts.project(group).observationComplete, isTrue);
      final pinned = group.withPinned(true);
      expect(pinned.lastMessageAt, group.lastMessageAt);
      expect(pinned.lastAnswerSequence, 1);
      expect(group.withIcon().lastMessageSequence, 2);
    },
  );
  test(
    'read receipts persist, stay monotonic and isolate authenticated rooms',
    () async {
      final fixture = BotsFixture();
      final base = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      final group = BotGroup(
        observationComplete: true,
        scope: base.scope,
        instance: base.instance,
        id: base.id,
        name: base.name,
        members: base.members,
        lastAnswerSequence: 8,
        lastMessageSequence: 9,
      );
      final reads = BotGroupReadState();
      addTearDown(reads.dispose);
      await reads.load();
      expect(reads.unread(group), isTrue);
      await Future.wait([
        reads.acknowledge(group, 9),
        reads.acknowledge(group, 3),
      ]);
      expect(reads.sequence(group), 9);
      expect(reads.unread(group), isFalse);
      final restored = BotGroupReadState();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.sequence(group), 9);
      final other = BotGroup(
        observationComplete: true,
        scope: WorkspaceScope(
          connectionId: 'other',
          connectionIdentity: 'another authenticated server',
          profileName: 'default',
        ),
        instance: 'Other',
        id: group.id,
        name: group.name,
        members: group.members,
        lastAnswerSequence: 8,
      );
      expect(restored.unread(other), isTrue);
    },
  );
  test('only visible delivered messages acknowledge a room answer', () async {
    final fixture = BotsFixture();
    fixture.events.addAll([
      {
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1001.0,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Delivered answer'},
      },
      {
        'room_id': 'room-1',
        'seq': 2,
        'kind': 'task.completed',
        'created_at': 2000.0,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {},
      },
    ]);
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).single;
    final reads = BotGroupReadState();
    addTearDown(reads.dispose);
    await reads.load();
    final session = BotGroupSession(
      fixture.repository,
      group,
      reads: reads,
      preferences: groupPreferences,
      groupMessages: null,
      appearances: FixedGroupAppearances(const []),
    );
    addTearDown(session.dispose);
    await session.refresh();
    await session.acknowledgeVisibleMessages(1);
    expect(reads.unread(group), isTrue);
    session.setVisible(true);
    await session.acknowledgeVisibleMessages(2);
    expect(reads.unread(group), isTrue);
    session.setCapturing(true);
    await session.acknowledgeVisibleMessages(1);
    expect(reads.unread(group), isTrue);
    session.setCapturing(false);
    await session.acknowledgeVisibleMessages(1);
    expect(reads.unread(group), isFalse);
  });
  test(
    'an older preview cannot erase an answer already admitted by its notification',
    () async {
      final fixture = BotsFixture();
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      final notified = BotGroup(
        scope: group.scope,
        instance: group.instance,
        id: group.id,
        name: group.name,
        members: group.members,
        observationComplete: false,
        latestSequence: 8,
        lastAnswerSequence: 8,
      );
      final reads = BotGroupReadState();
      addTearDown(reads.dispose);
      await reads.load();
      await reads.acknowledge(group, 3);
      final merged = notified.withMessageObservation(group);
      expect(merged.lastAnswerSequence, 8);
      expect(reads.unread(merged), isTrue);
      expect(reads.sequence(merged), 3);
    },
  );
  test(
    'retired passive tail stops paging without receipts or commands',
    () async {
      final fixture = BotsFixture();
      final base = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      final group = BotGroup(
        observationComplete: true,
        scope: base.scope,
        instance: base.instance,
        id: base.id,
        name: base.name,
        members: base.members,
        latestSequence: 201,
        lastMessageSequence: 201,
        lastAnswerSequence: 201,
      );
      final reads = BotGroupReadState();
      addTearDown(reads.dispose);
      await reads.load();
      final session = BotGroupSession(
        fixture.repository,
        group,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),
        reads: reads,
        preferences: groupPreferences,
      );
      addTearDown(session.dispose);
      final started = Completer<void>(), released = Completer<void>();
      var allowed = true, pages = 0;
      fixture.readHook = (_, method, _) async {
        if (method != 'groups.log') return null;
        pages++;
        started.complete();
        await released.future;
        return {
          'events': [],
          'cursor': 201,
          'latest_seq': 201,
          'has_more': false,
          'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
        };
      };
      final preview = session.readRecentMessages(
        limit: 6,
        canRead: () => allowed,
      );
      final failure = expectLater(preview, throwsStateError);
      await started.future;
      allowed = false;
      released.complete();
      await failure;
      expect(pages, 1);
      expect(reads.unread(group), isTrue);
      expect(fixture.commands, isEmpty);
      expect(session.events, isEmpty);
    },
  );
}
