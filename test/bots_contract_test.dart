import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/services/group_observations.dart';
import 'package:wing/core/services/bots_preferences.dart';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'dart:async';
import 'package:wing/core/models/composer_reference.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bot_profile_edit_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/recent_conversation_snapshots.dart';
import 'support/bots_fixture.dart';
import 'support/administration_fixture.dart';
import 'package:wing/core/services/bot_avatar_io.dart';
import 'package:wing/core/services/connection_manager.dart';

const _avatarPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=';

class _AvatarPicker extends BotAvatarIo {
  @override
  Future<Uint8List?> pick() async => base64Decode(_avatarPng);
}

class _DraftStorage extends InMemorySharedPreferencesStore {
  _DraftStorage() : super.empty();
  Completer<void>? held;
  bool reject = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.startsWith('flutter.bots_group_message_draft:')) {
      await held?.future;
      if (reject) return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  for (final method in [
    'groups.context',
    'groups.continue',
    'groups.discard',
  ]) {
    test(
      'production group adapter dispatches $method with its captured profile',
      () async {
        final administration = AdministrationFixture();
        final fixture = BotsFixture();
        final writes = <Map<String, dynamic>>[];
        administration.rpcOverride = (incoming, params) async {
          if (incoming != method) {
            return fixture.read(params['profile'] as String, incoming, params);
          }
          writes.add(Map.of(params));
          return switch (method) {
            'groups.context' => {
              'context': const BotGroupContext(
                purpose: 'Plan together',
              ).toJson(),
              'event': {
                'room_id': params['room_id'],
                'event_id': params['event_id'],
                'kind': 'room.context_set',
              },
            },
            'groups.continue' => {
              'continued': true,
              'event': {
                'room_id': params['room_id'],
                'kind': 'room.continued',
                'payload': {
                  'discussion_event_id': params['discussion_event_id'],
                },
              },
            },
            _ => {
              'discarded': true,
              'task': {
                'room_id': params['room_id'],
                'task_id': params['task_id'],
              },
            },
          };
        };
        final observations = GroupObservations(
          WorkspaceScope(
            connectionId: administration.server.connectionId,
            connectionIdentity: administration.server.connectionIdentity,
            profileName: 'default',
          ),
        );
        addTearDown(observations.dispose);
        final repository = BotsRepository.forServer(
          administration.server,
          groupObservations: observations,
        );
        final group = (await repository.groupCatalog()).single;
        final expected = <String, dynamic>{
          'room_id': group.id,
          'profile': 'default',
        };
        switch (method) {
          case 'groups.context':
            const context = BotGroupContext(purpose: 'Plan together');
            expect(
              await repository.saveGroupContext(
                group,
                context,
                'context-1',
                () => true,
              ),
              context,
            );
            expected.addAll({'event_id': 'context-1', ...context.toJson()});
          case 'groups.continue':
            await repository.continueGroup(group, 'discussion-1', () => true);
            expected['discussion_event_id'] = 'discussion-1';
          case 'groups.discard':
            var dispatched = false;
            await repository.resolveGroup(
              group,
              BotGroupAction(
                kind: 'discard',
                task: 'task-1',
                member: 'atlas',
                generation: 7,
              ),
              null,
              () => true,
              () => dispatched = true,
            );
            expect(dispatched, isTrue);
            expected.addAll({
              'task_id': 'task-1',
              'member_id': 'atlas',
              'execution_generation': 7,
            });
        }
        expect(writes, [expected]);
        expect(
          administration.rpcRequests.where((request) => request.$2 == method),
          [('default', method)],
        );
      },
    );
  }

  test(
    'production bot gateway rejects unknown and retired group commands before dispatch',
    () async {
      final administration = AdministrationFixture();
      final gateway = administration.server.gateway('work');
      addTearDown(gateway.close);
      var dispatches = 0;
      await expectLater(
        gateway.botCommand(
          'groups.unrecognized',
          {},
          canDispatch: () => true,
          onDispatched: () => dispatches++,
        ),
        throwsArgumentError,
      );
      for (final method in [
        'groups.context',
        'groups.continue',
        'groups.discard',
      ]) {
        await expectLater(
          gateway.botCommand(
            method,
            {'room_id': 'room-1'},
            canDispatch: () => false,
            onDispatched: () => dispatches++,
          ),
          throwsA(isA<DashboardRequestNotSentException>()),
        );
      }
      expect(dispatches, 0);
      expect(administration.rpcRequests, isEmpty);
    },
  );

  test(
    'stock group passes use payload member identity and reject malformed status',
    () {
      Map<String, dynamic> settled(Object? passed, Object? member) => {
        'room_id': 'room-1',
        'seq': 1,
        'event_id': 'terminal-1',
        'kind': 'turn.settled',
        'actor': {'kind': 'gateway', 'id': 'gateway-1'},
        'created_at': 1700000001,
        'payload': {'passed': passed, 'member_id': member},
      };
      BotGroupEvent decode(Map<String, dynamic> event) =>
          BotsRepository.decodeGroupLog('room-1', {
            'events': [event],
            'cursor': 1,
            'latest_seq': 1,
            'has_more': false,
            'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
          }, since: 0).events.single;
      final pass = decode(settled(true, 'atlas'));
      expect(pass.isPass, isTrue);
      expect(pass.isMessage, isFalse);
      expect(pass.isTranscriptEntry, isTrue);
      expect(pass.actorId, 'gateway-1');
      expect(pass.memberId, 'atlas');
      expect(pass.text, isEmpty);
      expect(decode(settled(false, 'atlas')).isTranscriptEntry, isFalse);
      for (final event in [
        settled('true', 'atlas'),
        settled(null, 'atlas'),
        settled(true, ''),
        settled(true, null),
      ]) {
        expect(() => decode(event), throwsFormatException);
      }
    },
  );

  for (final cached in [false, true]) {
    for (final passOnly in [false, true]) {
      test(
        'group pass tails remain passive cached=$cached passOnly=$passOnly',
        () async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await BotsPreferences.load();
          final fixture = BotsFixture();
          if (!passOnly) {
            fixture.events.add({
              'room_id': 'room-1',
              'seq': 1,
              'kind': 'message.member',
              'created_at': 1700000001,
              'actor': {'kind': 'member', 'id': 'atlas'},
              'payload': {'text': 'A real answer'},
            });
          }
          final passSeq = passOnly ? 1 : 2;
          fixture.events.add({
            'room_id': 'room-1',
            'seq': passSeq,
            'kind': 'turn.settled',
            'created_at': 1700000000 + passSeq,
            'actor': {'kind': 'gateway', 'id': 'gateway-1'},
            'payload': {
              'member_id': 'mira',
              'passed': true,
              'message_event_id': null,
            },
          });
          final cache = cached ? RecentGroupMessages() : null;
          addTearDown(() => cache?.dispose());
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: cache,
          )).single;
          expect(group.latestSequence, passSeq);
          expect(group.lastMessageSequence, passOnly ? 0 : 1);
          expect(group.lastAnswerSequence, passOnly ? 0 : 1);
          expect(group.preview, passOnly ? '' : 'A real answer');
          final reads = BotGroupReadState();
          addTearDown(reads.dispose);
          await reads.load();
          if (!passOnly) await reads.acknowledge(group, 1);
          expect(reads.unread(group), isFalse);
          final session = BotGroupSession(
            fixture.repository,
            group,
            reads: reads,
            preferences: preferences,
            appearances: FixedGroupAppearances(const []),
            groupMessages: cache,
          );
          addTearDown(session.dispose);
          final events = await session.readRecentMessages(
            limit: 10,
            canRead: () => true,
          );
          expect(
            events.map((event) => event.sequence),
            passOnly ? [1] : [1, 2],
          );
          final message = TranscriptMessage.discussion(
            group: group,
            event: events.last,
          );
          expect(message.kind, TranscriptMessageKind.discussionPass);
          expect(message.sender, 'Mira');
          expect(message.senderHandle, 'bot_mira');
          expect(message.text, 'Passed');
          expect(message.copyText, isEmpty);
          expect(message.timestamp, events.last.timestamp);
          expect(fixture.commands, isEmpty);
          expect(reads.unread(group), isFalse);
          session.setVisible(true);
          await session.refresh();
          await session.acknowledgeVisibleMessages(passSeq);
          expect(reads.sequence(group), passOnly ? 0 : 1);
        },
      );
    }
  }

  late BotsPreferences groupPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    groupPreferences = await BotsPreferences.load();
  });

  test(
    'group arrivals overtake held previews without clearing unread or starting duplicate reads',
    () async {
      var now = DateTime(2026, 10, 14);
      final fixture = BotsFixture();
      void event(int sequence, String kind) => fixture.events.add({
        'room_id': 'room-1',
        'seq': sequence,
        'kind': kind,
        'created_at': now.millisecondsSinceEpoch / 1000 + sequence,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Reply $sequence'},
      });
      event(1, 'message.member');
      final bots = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) bots.dispose();
      });
      await bots.refresh();
      final group = bots.observedGroups.single;
      await bots.groupReads.acknowledge(group, 1);
      event(2, 'task.completed');
      final release = Completer<void>(), started = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var logs = 0;
      fixture.readHook = (_, method, params) async {
        if (method != 'groups.log') return null;
        logs++;
        if (logs != 1) return null;
        final captured = List<Map<String, dynamic>>.of(fixture.events);
        started.complete();
        await release.future;
        return {
          'events': captured,
          'cursor': 2,
          'latest_seq': 2,
          'has_more': false,
          'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
        };
      };
      now = now.add(const Duration(seconds: 31));
      final refresh = bots.refresh();
      await started.future;
      for (final sequence in [3, 4]) {
        event(sequence, 'message.member');
        fixture.observeGroupMessages(since: sequence - 1);
      }
      expect(bots.groupReads.unread(bots.observedGroups.single), isTrue);
      expect(
        logs,
        1,
        reason: 'Both arrivals join the already admitted preview',
      );
      release.complete();
      await refresh;
      expect(bots.groupReads.unread(bots.observedGroups.single), isTrue);
      for (
        var i = 0;
        i < 30 && bots.observedGroups.single.lastMessageSequence != 4;
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(bots.observedGroups.single.lastMessageSequence, 4);
      expect(bots.observedGroups.single.lastAnswerSequence, 4);
      expect(bots.groupReads.sequence(group), 1);
      expect(
        logs,
        1,
        reason: 'Complete observations need no redundant preview',
      );
      expect(fixture.commands, isEmpty);
      final readCount = logs;
      final other = BotsFixture();
      other.events.add({...fixture.events.last, 'seq': 5});
      other.observeGroupMessages();
      await Future<void>.delayed(Duration.zero);
      expect(logs, readCount);
      bots.dispose();
      disposed = true;
      event(6, 'message.member');
      fixture.observeGroupMessages();
      await Future<void>.delayed(Duration.zero);
      expect(logs, readCount);
    },
  );

  test(
    'old group arrival admits its real message before follow-up reads',
    () async {
      final now = DateTime(2026, 10, 14);
      final fixture = BotsFixture();
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at':
            now.subtract(const Duration(days: 2)).millisecondsSinceEpoch / 1000,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Old answer'},
      });
      final bots = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(bots.dispose);
      await bots.refresh();
      final room = bots.observedGroups.single;
      await bots.groupReads.acknowledge(room, 1);
      fixture.readHook = (_, method, _) async {
        if (method.startsWith('groups.')) {
          throw StateError('Follow-up unavailable');
        }
        return null;
      };
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 2,
        'kind': 'message.member',
        'created_at': now.millisecondsSinceEpoch / 1000,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Fresh answer'},
      });
      fixture.observeGroupMessages(since: 1);
      expect(bots.observedGroups.single.lastMessageAt, now);
      expect(bots.observedGroups.single.preview, 'Fresh answer');
      expect(bots.groupReads.unread(bots.observedGroups.single), isTrue);
    },
  );

  test(
    'unknown and late-subscribed rooms borrow complete observations without preview I/O',
    () async {
      final fixture = BotsFixture();
      final bots = BotsSession((_) async => [fixture.repository]);
      addTearDown(bots.dispose);
      fixture.readHook = (_, method, _) async => method == 'groups.list'
          ? {'rooms': <Map<String, dynamic>>[], 'next_offset': null}
          : null;
      await bots.refresh();
      expect(bots.observedGroups, isEmpty);
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1791936000.0,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Discovered reply'},
      });
      var reads = 0;
      fixture.readHook = (_, method, _) async {
        if (method.startsWith('groups.')) reads++;
        return null;
      };
      fixture.observeGroupMessages();
      await Future<void>.delayed(Duration.zero);
      expect(bots.observedGroups.single.preview, 'Discovered reply');
      expect(reads, 0);
      final later = BotsSession((_) async => [fixture.repository]);
      addTearDown(later.dispose);
      await later.refresh();
      expect(later.observedGroups.single.preview, 'Discovered reply');
      expect(later.groupReads.unread(later.observedGroups.single), isTrue);
    },
  );

  test(
    'complete arrival during unrelated mutation updates facts with no follow-up read',
    () async {
      final fixture = BotsFixture();
      final bots = BotsSession((_) async => [fixture.repository]);
      addTearDown(bots.dispose);
      await bots.refresh();
      final release = Completer<void>(), started = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      fixture.beforeCommand = () async {
        started.complete();
        await release.future;
      };
      final mutation = bots.setPinned(
        bots.state.bots.first,
        canUse: () => true,
      );
      await started.future;
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1791936000.0,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'During pin save'},
      });
      var logs = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.log') logs++;
        return null;
      };
      fixture.observeGroupMessages();
      expect(bots.observedGroups.single.preview, 'During pin save');
      expect(bots.groupReads.unread(bots.observedGroups.single), isTrue);
      release.complete();
      await mutation;
      await Future<void>.delayed(Duration.zero);
      expect(logs, 0);
    },
  );

  test(
    'incomplete discovery during mutation retains targeted read demand',
    () async {
      final fixture = BotsFixture();
      final bots = BotsSession((_) async => [fixture.repository]);
      addTearDown(bots.dispose);
      await bots.refresh();
      final release = Completer<void>(), started = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      fixture.beforeCommand = () async {
        started.complete();
        await release.future;
      };
      final mutation = bots.setPinned(
        bots.state.bots.first,
        canUse: () => true,
      );
      await started.future;
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1791936000.0,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Read after pin save'},
      });
      fixture.repository.groupObservations.discover(
        bots.observedGroups.single,
        1,
      );
      release.complete();
      await mutation;
      for (
        var i = 0;
        i < 30 && bots.observedGroups.single.lastMessageSequence != 1;
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(bots.observedGroups.single.preview, 'Read after pin save');
    },
  );

  test(
    'live multi-page replay publishes canonical facts without competing preview reads',
    () async {
      final fixture = BotsFixture();
      final bots = BotsSession((_) async => [fixture.repository]);
      addTearDown(bots.dispose);
      await bots.refresh();
      final room = bots.observedGroups.single;
      final discussion = bots.openGroup(room);
      addTearDown(discussion.dispose);
      for (var sequence = 1; sequence <= 101; sequence++) {
        fixture.events.add({
          'room_id': 'room-1',
          'seq': sequence,
          'kind': 'message.member',
          'created_at': 1791936000.0 + sequence,
          'actor': {'kind': 'member', 'id': 'atlas'},
          'payload': {'text': 'Live $sequence'},
        });
      }
      var logs = 0;
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      fixture.readHook = (_, method, params) async {
        if (method != 'groups.log') return null;
        logs++;
        if (params['since_seq'] == 100) {
          started.complete();
          await release.future;
        }
        return null;
      };
      discussion.setVisible(true);
      final reading = discussion.refresh();
      await started.future;
      await Future<void>.delayed(Duration.zero);
      expect(logs, 2);
      release.complete();
      await reading;
      await Future<void>.delayed(Duration.zero);
      expect(bots.observedGroups.single.preview, 'Live 101');
      expect(bots.observedGroups.single.lastAnswerSequence, 101);
      expect(logs, 2);
      expect(bots.groupReads.sequence(room), 0);
    },
  );

  test(
    'observation subscriptions rebind and retire without leaking old owners',
    () async {
      final first = BotsFixture(), replacement = BotsFixture();
      var active = first;
      final bots = BotsSession((_) async => [active.repository]);
      await bots.refresh();
      active = replacement;
      await bots.refresh();
      final next = bots;
      addTearDown(next.dispose);
      first.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1791936000.0,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Retired source'},
      });
      first.observeGroupMessages();
      expect(next.observedGroups.single.preview, isEmpty);
      replacement.events.add({
        ...first.events.single,
        'payload': {'text': 'Current source'},
      });
      replacement.observeGroupMessages();
      expect(next.observedGroups.single.preview, 'Current source');
      replacement.repository.groupObservations.dispose();
      replacement.observeGroupMessages();
      expect(next.observedGroups.single.preview, 'Current source');
    },
  );

  test(
    'newer incomplete observation survives an older targeted read',
    () async {
      final fixture = BotsFixture();
      final bots = BotsSession((_) async => [fixture.repository]);
      addTearDown(bots.dispose);
      await bots.refresh();
      final room = bots.observedGroups.single;
      void event(int sequence, String kind, String text) => fixture.events.add({
        'room_id': 'room-1',
        'seq': sequence,
        'kind': kind,
        'created_at': 1791936000.0 + sequence,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': text},
      });
      event(1, 'message.user', 'First prompt');
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var logs = 0;
      fixture.readHook = (_, method, _) async {
        if (method != 'groups.log') return null;
        logs++;
        if (logs != 1) return null;
        final captured = List<Map<String, dynamic>>.of(fixture.events);
        started.complete();
        await release.future;
        return {
          'events': captured,
          'cursor': 1,
          'latest_seq': 1,
          'has_more': false,
          'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
        };
      };
      fixture.repository.groupObservations.discover(room, 1);
      await started.future;
      event(2, 'task.completed', 'Work');
      event(3, 'message.user', 'Newest prompt');
      fixture.observeGroupMessages(since: 2);
      release.complete();
      for (
        var i = 0;
        i < 60 && bots.observedGroups.single.messageCoverageSequence != 3;
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(bots.observedGroups.single.preview, 'Newest prompt');
      expect(bots.observedGroups.single.messageCoverageSequence, 3);
      expect(bots.observedGroups.single.lastAnswerSequence, 0);
      expect(logs, 2);
    },
  );

  test(
    'held catalog preserves a room discovered after that catalog began',
    () async {
      final fixture = BotsFixture();
      final bots = BotsSession((_) async => [fixture.repository]);
      addTearDown(bots.dispose);
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      fixture.readHook = (_, method, _) async {
        if (method != 'groups.list') return null;
        started.complete();
        await release.future;
        return {'rooms': <Map<String, dynamic>>[], 'next_offset': null};
      };
      final reading = bots.refresh();
      await started.future;
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1791936000.0,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Newly discovered'},
      });
      fixture.observeGroupMessages();
      release.complete();
      await reading;
      expect(bots.observedGroups.single.preview, 'Newly discovered');
      expect(
        fixture.repository.groupObservations.forRoom('room-1')!.message!.text,
        'Newly discovered',
      );
    },
  );

  Future<(BotsFixture, BotGroupSession)> draftGroup() async {
    final fixture = BotsFixture();
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).single;
    final session = BotGroupSession(
      fixture.repository,
      group,
      appearances: FixedGroupAppearances(const []),
      reads: BotGroupReadState(),
      groupMessages: null,
      preferences: groupPreferences,
    );
    return (fixture, session);
  }

  test(
    'group message draft restores selected routing and clears after acceptance',
    () async {
      final (fixture, session) = await draftGroup();
      const text = '  Ask @Atlas for details.\nThen compare.  ';
      final mention = session
          .completeMentions(MentionQuery.at('@atl', 4)!)
          .items
          .single
          .reference;
      await session.editMentions(text, selected: mention);
      final group = session.group;
      session.dispose();
      SharedPreferences.resetStatic();
      final restored = BotGroupSession(
        fixture.repository,
        group,
        appearances: FixedGroupAppearances(const []),
        reads: BotGroupReadState(),
        groupMessages: null,
        preferences: await BotsPreferences.load(),
      );
      addTearDown(restored.dispose);
      expect(restored.draftText, text);
      expect(restored.composerReferences.single.target, 'atlas');
      expect(await restored.send(restored.draftText), true);
      expect(
        fixture.commands.single.$3['payload']['text'],
        'Ask @bot_atlas for details.\nThen compare.',
      );
      expect(restored.draftText, isEmpty);
      SharedPreferences.resetStatic();
      expect(
        (await BotsPreferences.load()).messageDraft('instance-1', group.id),
        isNull,
      );
    },
  );

  test(
    'group message draft writes keep the latest edit available while saving',
    () async {
      final storage = _DraftStorage()..held = Completer<void>();
      SharedPreferencesStorePlatform.instance = storage;
      SharedPreferences.resetStatic();
      final preferences = await SharedPreferences.getInstance();
      final first = BotsPreferences(preferences),
          second = BotsPreferences(preferences);
      final old = first.writeMessageDraft('one', 'room', 'Old draft', const []);
      final newer = second.writeMessageDraft(
        'one',
        'room',
        'Newest draft',
        const [],
      );
      expect(first.messageDraft('one', 'room')!.text, 'Newest draft');
      expect(first.messageDraft('two', 'room'), isNull);
      expect(first.messageDraft('one', 'other'), isNull);
      final clear = first.writeMessageDraft('one', 'room', '', const []);
      expect(second.messageDraft('one', 'room'), isNull);
      storage.held!.complete();
      await Future.wait([old, newer, clear]);
      SharedPreferences.resetStatic();
      expect(
        (await BotsPreferences.load()).messageDraft('one', 'room'),
        isNull,
      );
    },
  );

  test(
    'group message draft save failure keeps text and recovers on editing',
    () async {
      final storage = _DraftStorage()..reject = true;
      SharedPreferencesStorePlatform.instance = storage;
      SharedPreferences.resetStatic();
      groupPreferences = await BotsPreferences.load();
      final (_, session) = await draftGroup();
      addTearDown(session.dispose);
      await session.editMentions('Keep this draft');
      expect(session.draftText, 'Keep this draft');
      expect(session.error, contains('Draft could not be saved'));
      storage.reject = false;
      await session.editMentions('Keep this edited draft');
      expect(session.error, isNull);
      SharedPreferences.resetStatic();
      expect(
        (await BotsPreferences.load())
            .messageDraft('instance-1', 'room-1')!
            .text,
        'Keep this edited draft',
      );
    },
  );

  for (final reopen in [false, true]) {
    test(
      'group message acceptance preserves a newer draft ${reopen ? 'in a new visit' : 'while sending'}',
      () async {
        final (fixture, session) = await draftGroup();
        await session.editMentions('Send this');
        final held = Completer<void>(), started = Completer<void>();
        fixture.commandHook = (_, method, _) async {
          if (method != 'groups.send') return null;
          started.complete();
          await held.future;
          return null;
        };
        final sending = session.send(session.draftText);
        await started.future;
        final current = reopen
            ? BotGroupSession(
                fixture.repository,
                session.group,
                appearances: FixedGroupAppearances(const []),
                reads: BotGroupReadState(),
                groupMessages: null,
                preferences: groupPreferences,
              )
            : session;
        if (reopen) session.dispose();
        addTearDown(current.dispose);
        final mention = current
            .completeMentions(MentionQuery.at('@atl', 4)!)
            .items
            .single
            .reference;
        await current.editMentions('Ask @Atlas next', selected: mention);
        held.complete();
        await sending;
        expect(current.draftText, 'Ask @Atlas next');
        expect(current.composerReferences.single.target, 'atlas');
        SharedPreferences.resetStatic();
        final saved = (await BotsPreferences.load()).messageDraft(
          'instance-1',
          'room-1',
        )!;
        expect(saved.text, 'Ask @Atlas next');
        expect(saved.references.single.target, 'atlas');
      },
    );
  }

  test('group message send failure retains the saved draft', () async {
    final (fixture, session) = await draftGroup();
    addTearDown(session.dispose);
    await session.editMentions('Keep the unsent message');
    fixture.sendLost = true;
    expect(await session.send(session.draftText), false);
    expect(session.draftText, 'Keep the unsent message');
    SharedPreferences.resetStatic();
    expect(
      (await BotsPreferences.load()).messageDraft('instance-1', 'room-1')!.text,
      'Keep the unsent message',
    );
  });

  test(
    'group dictation applies immediately while automatic draft saving is held',
    () async {
      final storage = _DraftStorage();
      SharedPreferencesStorePlatform.instance = storage;
      SharedPreferences.resetStatic();
      groupPreferences = await BotsPreferences.load();
      final (_, session) = await draftGroup();
      addTearDown(session.dispose);
      session.setVisible(true);
      storage.held = Completer<void>();
      addTearDown(() {
        if (!storage.held!.isCompleted) storage.held!.complete();
      });
      var applied = false;
      final applying = session
          .applyVoiceDraft(session.captureVoiceDraft(), 'Dictated text')
          .then((_) => applied = true);
      await Future<void>.delayed(Duration.zero);
      expect(applied, true);
      expect(session.draftText, 'Dictated text');
      storage.held!.complete();
      await applying;
      await session.editMentions('Dictated text with an edit');
    },
  );

  Future<(BotsFixture, BotGroupSession)> pausedGroup({
    bool retireInTest = false,
    Future<void> Function(BotGroup, String)? beforeSend,
    Future<void> Function(BotGroup, BotGroupSendOutcome)? afterSend,
  }) async {
    final fixture = BotsFixture();
    fixture.pending.add({
      'kind': 'retry',
      'task_id': 'paused-task',
      'member_id': 'atlas',
      'execution_generation': 4,
    });
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).first;
    final session = BotGroupSession(
      fixture.repository,
      group,
      reads: BotGroupReadState(),
      preferences: groupPreferences,
      groupMessages: null,
      appearances: FixedGroupAppearances(const []),
      beforeSend: beforeSend,
      afterSend: afterSend,
    );
    if (!retireInTest) addTearDown(session.dispose);
    await session.refresh();
    return (fixture, session);
  }

  test(
    'group approval publishes before held log replay and saved details never grant authority',
    () async {
      final fixture = BotsFixture();
      fixture.pending.add({
        'kind': 'approval',
        'task_id': 'task',
        'member_id': 'atlas',
        'request_id': 'request',
        'execution_generation': 1,
        'approval': {
          'command': 'write AGENTS.md',
          'choices': ['once', 'deny'],
        },
      });
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      final entered = Completer<void>(), held = Completer<void>();
      fixture.readHook = (_, method, params) async {
        if (method == 'groups.log') {
          if (!entered.isCompleted) entered.complete();
          await held.future;
        }
        return null;
      };
      BotGroupSession create() => BotGroupSession(
        fixture.repository,
        group,
        reads: BotGroupReadState(),
        preferences: groupPreferences,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),
      );
      final session = create();
      addTearDown(session.dispose);
      final read = session.refresh();
      await entered.future;
      expect(session.pendingApprovals.single.command, 'write AGENTS.md');
      held.complete();
      await read;
      fixture.pending.clear();
      final restored = create();
      addTearDown(restored.dispose);
      expect(restored.pendingApprovals, isEmpty);
      expect(restored.runtime, isNull);
      expect(
        restored.questionHistory.questions.single.command,
        'write AGENTS.md',
      );
      await restored.refresh();
      expect(restored.pendingApprovals, isEmpty);
      expect(restored.runtime, isNotNull);
    },
  );

  test(
    'group approvals keep first-seen order when runtime member order changes',
    () async {
      final fixture = BotsFixture();
      for (final request in ['first', 'second']) {
        fixture.pending.add({
          'kind': 'approval',
          'task_id': 'task',
          'member_id': 'atlas',
          'request_id': request,
          'execution_generation': 1,
          'approval': {
            'command': request,
            'choices': ['once', 'deny'],
          },
        });
      }
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      final session = BotGroupSession(
        fixture.repository,
        group,
        reads: BotGroupReadState(),
        preferences: groupPreferences,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),
      );
      addTearDown(session.dispose);
      await session.refresh();
      final reversed = fixture.pending.reversed.toList();
      fixture.pending
        ..clear()
        ..addAll(reversed);
      await session.refresh();
      expect(session.pendingApprovals.map((a) => a.request), [
        'first',
        'second',
      ]);
      fixture.pending.removeWhere((a) => a['request_id'] == 'first');
      await session.refresh();
      expect(session.pendingApprovals.single.request, 'second');
      expect(
        session.questionHistory.questions
            .where((q) => q.status == HermesQuestionStatus.closed)
            .single
            .requestId,
        'first',
      );
    },
  );

  test(
    'desktop-cleared group approval cannot regain controls from replay',
    () async {
      final fixture = BotsFixture();
      final pending = {
        'kind': 'approval',
        'task_id': 'task',
        'member_id': 'atlas',
        'request_id': 'request',
        'execution_generation': 1,
        'approval': {
          'command': 'Inspect changes',
          'choices': ['once', 'deny'],
        },
      };
      fixture.pending.add(pending);
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      final session = BotGroupSession(
        fixture.repository,
        group,
        reads: BotGroupReadState(),
        preferences: groupPreferences,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),
      );
      addTearDown(session.dispose);
      await session.refresh();
      final original = session.pendingApprovals.single;
      fixture.pending.clear();
      await session.refresh();
      expect(session.pendingApprovals, isEmpty);
      fixture.pending.add(pending);
      await session.refresh();
      expect(session.pendingApprovals, isEmpty);
      await session.resolve(original, choice: 'once');
      expect(
        fixture.commands.where((call) => call.$2 == 'groups.approve'),
        isEmpty,
      );
      fixture.pending
        ..clear()
        ..add({...pending, 'execution_generation': 2});
      await session.refresh();
      expect(session.pendingApprovals.single.generation, 2);
    },
  );

  test(
    'group retry dispatches exact attempt once without Stop or synthetic input',
    () async {
      final (fixture, session) = await pausedGroup();
      final gate = Completer<void>();
      fixture.beforeCommand = () => gate.future;
      final action = session.runtime!.actions.single;
      final retry = session.resolve(action);
      expect(session.acting, true);
      await session.resolve(action);
      expect(await session.send('Concurrent'), false);
      gate.complete();
      await retry;
      await session.refresh();
      expect(fixture.commands.map((call) => call.$2), ['groups.retry']);
      expect(fixture.commands.single.$3, {
        'room_id': session.group.id,
        'task_id': 'paused-task',
        'member_id': 'atlas',
        'execution_generation': 4,
      });
      expect(fixture.events, isEmpty);
      expect(session.runtime!.actions, isEmpty);
      expect(session.acting, false);
    },
  );

  test(
    'group retry rejects stale generations and preserves its draft',
    () async {
      final (fixture, session) = await pausedGroup();
      final original = session.runtime!.actions.single;
      await session.editMentions('Keep my draft');
      fixture.pending.single['execution_generation'] = 5;
      await session.refresh();
      await session.resolve(original);
      expect(fixture.commands, isEmpty);
      await session.resolve(session.runtime!.actions.single);
      expect(fixture.commands.single.$3['execution_generation'], 5);
      expect(session.draftText, 'Keep my draft');
      expect(fixture.events, isEmpty);
    },
  );

  test(
    'unconfirmed retry shows recovery without guessing a continuation',
    () async {
      final (fixture, session) = await pausedGroup();
      fixture.commandHook = (_, method, _) async => method == 'groups.retry'
          ? {
              'retried': true,
              'task': {'room_id': 'other', 'task_id': 'paused-task'},
            }
          : null;
      await session.resolve(session.runtime!.actions.single);
      expect(session.error, contains('Retry could not be confirmed'));
      expect(fixture.commands.map((call) => call.$2), ['groups.retry']);
      expect(session.acting, false);
      expect(fixture.events, isEmpty);
    },
  );

  test('group retry retires before dispatch when its owner closes', () async {
    final (fixture, session) = await pausedGroup(retireInTest: true);
    final gate = Completer<void>();
    fixture.beforeCommand = () => gate.future;
    final retry = session.resolve(session.runtime!.actions.single);
    session.dispose();
    gate.complete();
    await retry;
    expect(fixture.commands, isEmpty);
  });

  test(
    'presence validation distinguishes successful uncertainty from failed reads',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['canonical_session']['id'] = 'mira-chat';
      final roster = await fixture.repository.bots();
      final validated = await fixture.repository.presence(roster);
      expect(validated.validated, true);
      expect(validated.values[roster.first.id], BotPresence.unknown);
      fixture.readHook = (_, method, _) async {
        if (method == 'session.active_list') throw StateError('Disconnected');
        return null;
      };
      final unavailable = await fixture.repository.presence(roster);
      expect(unavailable.validated, false);
      expect(unavailable.values.values, everyElement(BotPresence.unknown));
    },
  );

  test('group catalog and known-room status never scan messages', () async {
    final fixture = BotsFixture();
    final calls = <String>[];
    fixture.readHook = (_, method, _) async {
      calls.add(method);
      return null;
    };
    final room = (await fixture.repository.groupCatalog()).single;
    expect(calls, ['profiles.list', 'groups.list']);
    expect(room.observationComplete, false);
    calls.clear();
    final state = await fixture.repository.groupState(room);
    expect(calls, ['groups.state']);
    expect(state.roomAvailable, true);
    expect(state.runtimeAvailable, true);
    expect(state.applyTo(room).observationComplete, false);
  });

  test(
    'missing group driver preserves room and independent message coverage',
    () async {
      final fixture = BotsFixture();
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1700000001,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Confirmed answer'},
      });
      final messages = RecentGroupMessages();
      addTearDown(messages.dispose);
      final room = (await fixture.repository.groupCatalog()).single;
      final calls = <String>[];
      fixture.readHook = (_, method, _) async {
        calls.add(method);
        if (method == 'groups.state') {
          return {
            'room': {...fixture.room, 'name': 'Renamed room', 'latest_seq': 1},
          };
        }
        return null;
      };
      final state = await fixture.repository.groupState(room);
      expect(state.roomAvailable, true);
      expect(state.runtimeAvailable, false);
      final preview = await fixture.repository.groupPreview(
        room,
        state: state,
        groupMessages: messages,
        canPublish: () => true,
      );
      expect(calls, ['groups.state', 'groups.log']);
      expect(preview.name, 'Renamed room');
      expect(preview.runtimeAvailable, false);
      expect(preview.working, false);
      expect(preview.activeMemberProfiles, isEmpty);
      expect(preview.observationComplete, true);
      expect(preview.messageCoverageSequence, 1);
      expect(
        messages.borrow(preview, limit: 6)!.single.text,
        'Confirmed answer',
      );
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.state') throw StateError('Disconnected');
        return null;
      };
      final unavailable = (await fixture.repository.groupState(
        preview,
      )).applyTo(preview);
      expect(unavailable.preview, 'Confirmed answer');
      expect(unavailable.messageCoverageSequence, 1);
      expect(unavailable.runtimeAvailable, false);
      expect(unavailable.activeMemberProfiles, isEmpty);
    },
  );

  test(
    'status cursors preserve old coverage and late previews preserve new status',
    () async {
      final fixture = BotsFixture();
      final room = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      final state = BotGroupState(
        room: room,
        roomAvailable: true,
        latestSequence: 20,
        runtimeAvailable: true,
        working: true,
        memberActivity: const [
          BotGroupMemberActivity(memberId: 'atlas', status: 'running'),
          BotGroupMemberActivity(memberId: 'mira', status: 'queued'),
        ],
      );
      final updated = state.applyTo(room);
      expect(updated.latestSequence, 20);
      expect(updated.messageCoverageSequence, 0);
      expect(updated.activeMemberProfiles, {'atlas', 'mira'});
      final merged = updated.withMessageObservation(room);
      expect(merged.latestSequence, 20);
      expect(merged.messageCoverageSequence, 0);
      expect(merged.working, true);
      expect(merged.activeMemberProfiles, {'atlas', 'mira'});
      final unavailable = BotGroupState(
        room: room,
        roomAvailable: false,
      ).applyTo(merged);
      expect(unavailable.working, false);
      expect(unavailable.blocked, false);
      expect(unavailable.activeMemberProfiles, isEmpty);
      expect(unavailable.messageCoverageSequence, 0);
    },
  );

  test(
    'retired group preview cannot replace the accepted message tail',
    () async {
      final fixture = BotsFixture();
      void append(int seq) => fixture.events.add({
        'room_id': 'room-1',
        'seq': seq,
        'kind': 'message.member',
        'created_at': 1700000000 + seq,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Answer $seq'},
      });
      append(1);
      final messages = RecentGroupMessages();
      addTearDown(messages.dispose);
      final accepted = (await readFixtureGroups(
        fixture.repository,
        groupMessages: messages,
      )).single;
      append(2);
      final read = Completer<void>();
      final release = Completer<void>();
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.log') {
          read.complete();
          await release.future;
        }
        return null;
      };
      var current = true;
      final pending = fixture.repository.groupPreview(
        accepted,
        groupMessages: messages,
        canPublish: () => current,
      );
      await read.future;
      current = false;
      release.complete();
      final retired = await pending;
      expect(retired.observationComplete, false);
      expect(messages.borrow(accepted, limit: 6)!.single.sequence, 1);
      expect(messages.borrow(retired, limit: 6), isNull);
    },
  );

  test(
    'byte-shortened group logs retain the latest discovery and passive tail',
    () async {
      final fixture = BotsFixture();
      final text = List.filled(65000, 'x').join();
      for (var seq = 1; seq <= 40; seq++) {
        fixture.events.add({
          'room_id': 'room-1',
          'seq': seq,
          'kind': 'message.member',
          'created_at': 1700000000 + seq,
          'actor': {'kind': 'member', 'id': 'atlas'},
          'payload': {'text': 'Answer $seq ${seq <= 35 ? text : ''}'},
        });
      }
      final reads = <int>[];
      fixture.readHook = (_, method, params) async {
        if (method == 'groups.log') reads.add(params['since_seq'] as int);
        return null;
      };
      final cache = RecentGroupMessages();
      addTearDown(cache.dispose);
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: cache,
      )).single;
      expect(reads.length, greaterThan(1));
      expect(group.observationComplete, true);
      expect(group.lastMessageSequence, 40);
      expect(group.lastAnswerSequence, 40);
      expect(group.preview.startsWith('Answer 40 '), true);
      expect(
        cache.retainedBytes,
        lessThanOrEqualTo(RecentGroupMessages.byteLimit),
      );
      expect(cache.borrow(group, limit: 6)!.map((event) => event.sequence), [
        35,
        36,
        37,
        38,
        39,
        40,
      ]);
      final session = BotGroupSession(
        fixture.repository,
        group,
        appearances: FixedGroupAppearances(const []),
        reads: BotGroupReadState(),
        preferences: groupPreferences,
        groupMessages: null,
      );
      addTearDown(session.dispose);
      expect(
        (await session.readRecentMessages(
          limit: 6,
          canRead: () => true,
        )).map((event) => event.sequence),
        [35, 36, 37, 38, 39, 40],
      );
    },
  );

  test(
    'group windows exclude arrivals beyond their captured end and stop on retirement',
    () async {
      final fixture = BotsFixture();
      for (var seq = 1; seq <= 120; seq++) {
        fixture.events.add({
          'room_id': 'room-1',
          'seq': seq,
          'kind': 'message.member',
          'created_at': 1700000000 + seq,
          'actor': {'kind': 'member', 'id': 'atlas'},
          'payload': {'text': 'Answer $seq'},
        });
      }
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      expect(
        (await fixture.repository.groupLogWindow(
          group,
          start: 0,
          end: 40,
          canRead: () => true,
        )).map((event) => event.sequence),
        List.generate(40, (i) => i + 1),
      );
      var allowed = true, logReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.log') {
          logReads++;
          allowed = false;
        }
        return null;
      };
      await expectLater(
        fixture.repository.groupLogWindow(
          group,
          start: 0,
          end: 40,
          canRead: () => allowed,
        ),
        throwsStateError,
      );
      expect(logReads, 1);
    },
  );

  test(
    'incomplete group windows remain uncertain instead of publishing a partial tail',
    () async {
      final fixture = BotsFixture();
      fixture.events.add({'seq': 1});
      fixture.readHook = (_, method, params) async => method == 'groups.log'
          ? {
              'events': <Map<String, dynamic>>[],
              'cursor': params['since_seq'],
              'latest_seq': 1,
              'has_more': true,
              'authority': {'gateway_id': 'gateway-1', 'epoch': 1},
            }
          : null;
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      expect(group.observationComplete, false);
      expect(group.lastMessageSequence, 0);
    },
  );

  for (final oldReadFinishesFirst in [false, true]) {
    test(
      'confirmed mutation replaces a retired roster read oldFirst=$oldReadFinishesFirst',
      () async {
        var now = DateTime.utc(2026, 10, 13);
        final fixture = BotsFixture();
        final owner = BotsSession(
          (_) async => [fixture.repository],
          now: () => now,
        );
        addTearDown(owner.dispose);
        await owner.refresh();
        final readStarted = Completer<void>(), releaseRead = Completer<void>();
        final commandStarted = Completer<void>(),
            releaseCommand = Completer<void>();
        var held = false;
        fixture.readHook = (_, method, _) async {
          if (method == 'session.active_list' && !held) {
            held = true;
            readStarted.complete();
            await releaseRead.future;
          }
          return null;
        };
        fixture.beforeCommand = () async {
          commandStarted.complete();
          await releaseCommand.future;
        };
        now = now.add(const Duration(seconds: 30));
        final refresh = owner.refresh();
        await readStarted.future;
        final mutation = owner.createBot(
          'instance-1',
          'newbot',
          canUse: () => true,
        );
        await commandStarted.future;
        if (oldReadFinishesFirst) {
          releaseRead.complete();
          await refresh;
          releaseCommand.complete();
          expect(await mutation, true);
        } else {
          releaseCommand.complete();
          expect(await mutation, true);
          releaseRead.complete();
          await refresh;
        }
        for (var i = 0; i < 50 && owner.state.loading; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(owner.state.loading, false);
        expect(
          owner.state.bots.any((bot) => bot.profile.name == 'newbot'),
          true,
        );
      },
    );
  }

  test(
    'group sends publish their exact acknowledged stock sequence and reject a wrong receipt',
    () async {
      final fixture = BotsFixture();
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      expect(
        await fixture.repository.sendGroup(
          group,
          'first-send',
          'Hello',
          () => true,
          () {},
        ),
        1,
      );
      expect(
        await fixture.repository.sendGroup(
          group,
          'first-send',
          'Hello',
          () => true,
          () {},
        ),
        1,
      );
      expect(fixture.events, hasLength(1));
      fixture.commandHook = (_, method, params) async => method == 'groups.send'
          ? {
              'accepted': true,
              'client_event_id': params['event_id'],
              'event': {
                'room_id': 'other-room',
                'kind': 'message.user',
                'seq': 2,
                'event_id': BotsRepository.groupUserEventId(
                  params['event_id'] as String,
                ),
              },
            }
          : null;
      await expectLater(
        fixture.repository.sendGroup(
          group,
          'second-send',
          'Hello',
          () => true,
          () {},
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'profile chat entry resolves the exact profile and creates only if absent',
    () async {
      final fixture = BotsFixture();
      final session = BotsSession((_) async => [fixture.repository]);
      addTearDown(session.dispose);
      final scope = WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: 'instance-1',
        profileName: 'mira',
      );
      final existing = await session.openProfile(scope, canUse: () => true);
      expect(existing, ProfileSessionKey(scope, 'mira-chat'));
      expect(fixture.commands, isEmpty);
      fixture.profiles[1]['canonical_session'] = null;
      session.invalidateAppearances();
      final created = await session.openProfile(scope, canUse: () => true);
      expect(created!.workspace, scope);
      expect(
        fixture.commands.where((command) => command.$2 == 'session.create'),
        hasLength(1),
      );
      expect(fixture.commands.every((command) => command.$1 == 'mira'), isTrue);
    },
  );

  for (final initialCatalog in ['empty', 'previous connection']) {
    test(
      'profile chat entry discovers a source after $initialCatalog catalog',
      () async {
        final fixture = BotsFixture();
        final previousScope = WorkspaceScope(
          connectionId: 'host',
          connectionIdentity: 'previous-identity',
          profileName: 'default',
        );
        var sources = <BotsRepository>[
          if (initialCatalog == 'previous connection')
            BotsRepository(
              scope: previousScope,
              instance: 'Previous connection',
              groupObservations: GroupObservations(previousScope),
              read: fixture.read,
              command: fixture.command,
              ownership: fixture.ownership,
            ),
        ];
        final session = BotsSession((_) async => sources);
        addTearDown(session.dispose);
        await session.refresh();
        sources = [fixture.repository];
        final scope = WorkspaceScope(
          connectionId: 'host',
          connectionIdentity: 'instance-1',
          profileName: 'mira',
        );
        expect(
          await session.openProfile(scope, canUse: () => true),
          ProfileSessionKey(scope, 'mira-chat'),
        );
        expect(fixture.commands, isEmpty);
      },
    );
  }

  for (final failure in ['sources', 'roster']) {
    test(
      'profile chat entry retries failed $failure discovery immediately',
      () async {
        final fixture = BotsFixture();
        var fail = true;
        final session = BotsSession((_) async {
          if (fail && failure == 'sources') throw StateError('Offline');
          return [fixture.repository];
        });
        addTearDown(session.dispose);
        fixture.readHook = (_, method, _) async {
          if (fail && failure == 'roster') throw StateError('Offline');
          return null;
        };
        final scope = WorkspaceScope(
          connectionId: 'host',
          connectionIdentity: 'instance-1',
          profileName: 'mira',
        );
        await expectLater(
          session.openProfile(scope, canUse: () => true),
          throwsStateError,
        );
        fail = false;
        expect(
          await session.openProfile(scope, canUse: () => true),
          ProfileSessionKey(scope, 'mira-chat'),
        );
        expect(fixture.commands, isEmpty);
      },
    );
  }

  test(
    'profile chat entry retired during discovery cannot create a chat',
    () async {
      final fixture = BotsFixture();
      final session = BotsSession((_) async => [fixture.repository]);
      addTearDown(session.dispose);
      final started = Completer<void>();
      final held = Completer<void>();
      var current = true;
      fixture.readHook = (profile, method, params) async {
        if (method == 'profiles.list') {
          if (!started.isCompleted) started.complete();
          await held.future;
        }
        return null;
      };
      final opening = session.openProfile(
        WorkspaceScope(
          connectionId: 'host',
          connectionIdentity: 'instance-1',
          profileName: 'mira',
        ),
        canUse: () => current,
      );
      await started.future;
      current = false;
      held.complete();
      expect(await opening, isNull);
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'live groups borrow the same canonical appearance updates as cards',
    () async {
      final fixture = BotsFixture();
      final bots = BotsSession((_) async => [fixture.repository]);
      addTearDown(bots.dispose);
      await bots.refresh();
      final group = bots.observedGroups.single;
      final visit = bots.openGroup(group);
      addTearDown(visit.dispose);
      var changes = 0;
      visit.addListener(() => changes++);
      expect(visit.appearance('atlas')!.title, 'Atlas');
      final unchanged = bots.appearanceForGroup(group);
      await bots.refresh();
      expect(bots.appearanceForGroup(group), unchanged);
      expect(
        changes,
        0,
        reason: 'An unchanged roster must retain canonical group identity',
      );
      final roster = await fixture.repository.bots();
      fixture.profiles.first['ui_meta']['hermes-bots']['title'] =
          'Resolved Atlas';
      bots.invalidateAppearances();
      await bots.appearancesForProfiles([
        roster.first.scope,
      ], canRead: () => true);
      expect(visit.appearance('atlas')!.title, 'Resolved Atlas');
      expect(
        visit.appearance('atlas'),
        same(bots.appearanceForGroup(group).byHandle['bot_atlas']),
      );
      expect(changes, greaterThan(0));
      final before = changes;
      await bots.appearancesForProfiles([
        roster.last.scope,
      ], canRead: () => true);
      expect(
        changes,
        before,
        reason: 'Unrelated bot metadata must not redraw the group',
      );
      expect(fixture.commands, isEmpty);
    },
  );

  test('passive group preview reuses the discovery message tail', () async {
    final fixture = BotsFixture();
    final groupMessages = RecentGroupMessages();
    addTearDown(groupMessages.dispose);
    for (var seq = 1; seq <= 6; seq++) {
      fixture.events.add({
        'room_id': 'room-1',
        'seq': seq,
        'kind': 'message.member',
        'created_at': 1700000000 + seq,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Saved answer $seq'},
      });
    }
    var logReads = 0;
    fixture.readHook = (_, method, _) async {
      if (method == 'groups.log') logReads++;
      return null;
    };
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: groupMessages,
    )).single;
    final discoveryReads = logReads;
    final preview = BotGroupSession(
      fixture.repository,
      group,
      appearances: FixedGroupAppearances(const []),
      reads: BotGroupReadState(),
      preferences: groupPreferences,
      groupMessages: groupMessages,
    );
    addTearDown(preview.dispose);
    final messages = await preview.readRecentMessages(
      limit: 6,
      canRead: () => true,
    );
    expect(messages.map((event) => event.text), [
      for (var seq = 1; seq <= 6; seq++) 'Saved answer $seq',
    ]);
    expect(
      logReads,
      discoveryReads,
      reason: 'Discovery already fetched this immutable message tail',
    );
    expect(fixture.commands, isEmpty);
  });

  test(
    'group activity reaches only members and preserves individual input priority',
    () async {
      final fixture = BotsFixture();
      fixture.readHook = (_, method, _) async => method == 'groups.state'
          ? {
              'room': {...fixture.room, 'latest_seq': 0},
              'driver_status': {
                'working': true,
                'blocked': false,
                'counts': {'running': 1},
                'member_activity': [
                  {'member_id': 'atlas', 'status': 'running'},
                  {'member_id': 'mira', 'status': 'queued'},
                ],
                'pending_actions': [],
              },
            }
          : null;
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      await owner.refresh();
      expect(owner.state.bots.map((bot) => bot.presence), [
        BotPresence.groupWorking,
        BotPresence.needsInput,
        BotPresence.working,
      ]);
      expect(owner.state.bots.first.chat!.sessionId, 'atlas-chat');
      expect(
        owner.state.bots.first.preview,
        contains('three useful approaches'),
      );
      expect(owner.state.groups.single.activeMemberProfiles, {'atlas', 'mira'});
      expect(
        () => owner.state.groups.single.activeMemberProfiles.add('forge'),
        throwsUnsupportedError,
      );
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'unavailable group reads clear roster activity and recovery restores it',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture();
      var failure = '';
      fixture.readHook = (_, method, _) async {
        if (method == failure) {
          throw StateError('Unavailable');
        }
        if (method == 'session.active_list') return {'sessions': []};
        if (method == 'groups.state') {
          return {
            'room': {...fixture.room, 'latest_seq': 1},
            'driver_status': {
              'working': true,
              'blocked': false,
              'counts': {'running': 1},
              'member_activity': [
                {'member_id': 'atlas', 'status': 'running'},
                {'member_id': 'mira', 'status': 'queued'},
              ],
              'pending_actions': [],
            },
          };
        }
        return null;
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      for (final failed in [
        '',
        'groups.state',
        '',
        'groups.list',
        '',
        'groups.log',
      ]) {
        failure = failed;
        now = now.add(const Duration(minutes: 5));
        await owner.refresh();
        expect(
          owner.state.bots.first.presence,
          failed == 'groups.state'
              ? BotPresence.idle
              : BotPresence.groupWorking,
        );
      }
      expect(fixture.commands, isEmpty);
    },
  );

  test('unavailable source discovery revokes group activity', () async {
    var now = DateTime.utc(2026, 10, 13);
    final fixture = BotsFixture();
    fixture.readHook = (_, method, _) async => switch (method) {
      'session.active_list' => {'sessions': []},
      'groups.state' => {
        'room': {...fixture.room, 'latest_seq': 0},
        'driver_status': {
          'working': true,
          'blocked': false,
          'counts': {'running': 1},
          'member_activity': [
            {'member_id': 'atlas', 'status': 'running'},
            {'member_id': 'mira', 'status': 'queued'},
          ],
          'pending_actions': [],
        },
      },
      _ => null,
    };
    var unavailable = false;
    final owner = BotsSession((_) async {
      if (unavailable) throw StateError('Source unavailable');
      return [fixture.repository];
    }, now: () => now);
    addTearDown(owner.dispose);
    await owner.refresh();
    expect(owner.state.bots.first.presence, BotPresence.groupWorking);
    unavailable = true;
    now = now.add(const Duration(seconds: 30));
    await owner.refresh();
    expect(owner.state.bots.first.presence, BotPresence.idle);
    unavailable = false;
    now = now.add(const Duration(seconds: 30));
    await owner.refresh();
    expect(owner.state.bots.first.presence, BotPresence.groupWorking);
  });

  test(
    'group observations update member rows before a held bot refresh',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture();
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      await owner.refresh();
      final held = Completer<Map<String, dynamic>?>();
      final published = Completer<void>();
      fixture.readHook = (_, method, params) async => switch (method) {
        'profiles.list' when params['include_sessions'] == true => held.future,
        'groups.state' => {
          'room': {...fixture.room, 'latest_seq': 0},
          'driver_status': {
            'working': true,
            'blocked': false,
            'counts': {'running': 1},
            'member_activity': [
              {'member_id': 'atlas', 'status': 'running'},
              {'member_id': 'mira', 'status': 'queued'},
            ],
            'pending_actions': [],
          },
        },
        _ => null,
      };
      owner.addListener(() {
        if (!published.isCompleted &&
            owner.state.groups.single.activeMemberProfiles.isNotEmpty) {
          published.complete();
        }
      });
      now = now.add(const Duration(seconds: 30));
      final refresh = owner.refresh();
      await published.future;
      expect(owner.state.bots.first.presence, BotPresence.groupWorking);
      expect(owner.state.loading, true);
      held.complete(null);
      await refresh;
      expect(owner.state.bots.first.presence, BotPresence.groupWorking);
      expect(owner.state.loading, false);
    },
  );

  test('active group membership never crosses captured instances', () async {
    final active = BotsFixture(), other = BotsFixture();
    active.readHook = (_, method, _) async => switch (method) {
      'session.active_list' => {'sessions': []},
      'groups.state' => {
        'room': {...active.room, 'latest_seq': 0},
        'driver_status': {
          'working': true,
          'blocked': false,
          'counts': {'running': 1},
          'member_activity': [
            {'member_id': 'atlas', 'status': 'running'},
            {'member_id': 'mira', 'status': 'queued'},
          ],
          'pending_actions': [],
        },
      },
      _ => null,
    };
    other.readHook = (_, method, _) async =>
        method == 'session.active_list' ? {'sessions': []} : null;
    final repository = BotsRepository(
      groupObservations: GroupObservations(
        WorkspaceScope(
          connectionId: 'other-host',
          connectionIdentity: 'other-instance',
          profileName: 'default',
        ),
      ),
      scope: WorkspaceScope(
        connectionId: 'other-host',
        connectionIdentity: 'other-instance',
        profileName: 'default',
      ),
      instance: 'Other server',
      read: other.read,
      command: other.command,
      ownership: other.ownership,
    );
    final owner = BotsSession((_) async => [active.repository, repository]);
    addTearDown(owner.dispose);
    await owner.refresh();
    expect(
      owner.state.bots
          .where((bot) => bot.scope.connectionIdentity == 'instance-1')
          .map((bot) => bot.presence),
      [BotPresence.groupWorking, BotPresence.groupWorking, BotPresence.idle],
    );
    expect(
      owner.state.bots
          .where((bot) => bot.scope.connectionIdentity == 'other-instance')
          .map((bot) => bot.presence),
      everyElement(BotPresence.idle),
    );
  });

  test(
    'standalone group previews read stock logs without a shared store',
    () async {
      final fixture = BotsFixture();
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1700000001,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Saved answer'},
      });
      var logReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.log') logReads++;
        return null;
      };
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      final discoveryReads = logReads;
      final preview = BotGroupSession(
        fixture.repository,
        group,
        appearances: FixedGroupAppearances(const []),
        reads: BotGroupReadState(),
        preferences: groupPreferences,
        groupMessages: null,
      );
      addTearDown(preview.dispose);
      expect(
        (await preview.readRecentMessages(
          limit: 6,
          canRead: () => true,
        )).map((event) => event.text),
        ['Saved answer'],
      );
      expect(logReads, discoveryReads + 1);
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'backward discovery keeps the newest shared messages across pages',
    () async {
      final fixture = BotsFixture();
      final groupMessages = RecentGroupMessages();
      addTearDown(groupMessages.dispose);
      for (var seq = 1; seq <= 120; seq++) {
        fixture.events.add({
          'room_id': 'room-1',
          'seq': seq,
          'kind': seq == 1 ? 'message.member' : 'message.user',
          'created_at': 1700000000 + seq,
          'actor': {'kind': seq == 1 ? 'member' : 'user', 'id': 'atlas'},
          'payload': {'text': 'Answer $seq'},
        });
      }
      var logReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.log') logReads++;
        return null;
      };
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: groupMessages,
      )).single;
      expect(logReads, 2);
      final preview = BotGroupSession(
        fixture.repository,
        group,
        appearances: FixedGroupAppearances(const []),
        reads: BotGroupReadState(),
        preferences: groupPreferences,
        groupMessages: groupMessages,
      );
      addTearDown(preview.dispose);
      expect(
        (await preview.readRecentMessages(
          limit: 6,
          canRead: () => true,
        )).map((event) => event.sequence),
        [115, 116, 117, 118, 119, 120],
      );
      expect(
        logReads,
        2,
        reason: 'Older scan pages must not replace the newer tail',
      );
      expect(groupMessages.borrow(group, limit: 11), isNull);
    },
  );

  test(
    'group tail cache fences replacements and incomplete coverage',
    () async {
      final fixture = BotsFixture();
      final groupMessages = RecentGroupMessages();
      addTearDown(groupMessages.dispose);
      void append(int seq) => fixture.events.add({
        'room_id': 'room-1',
        'seq': seq,
        'kind': 'message.member',
        'created_at': 1700000000 + seq,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Answer $seq'},
      });
      for (var seq = 1; seq <= 6; seq++) {
        append(seq);
      }
      final old = (await readFixtureGroups(
        fixture.repository,
        groupMessages: groupMessages,
      )).single;
      expect(groupMessages.borrow(old, limit: 6), hasLength(6));
      for (var seq = 7; seq <= 11; seq++) {
        append(seq);
      }
      final current = (await readFixtureGroups(
        fixture.repository,
        groupMessages: groupMessages,
      )).single;
      expect(groupMessages.borrow(old, limit: 6), isNull);
      groupMessages.rebind(current, old);
      expect(groupMessages.borrow(old, limit: 6), isNull);
      expect(
        groupMessages.borrow(current, limit: 6)!.map((event) => event.sequence),
        [6, 7, 8, 9, 10, 11],
      );
      expect(
        groupMessages.borrow(current, limit: 11),
        isNull,
        reason:
            'A bounded retained tail cannot claim earlier messages are absent',
      );
      final visit = BotGroupSession(
        fixture.repository,
        current,
        groupMessages: groupMessages,
        appearances: FixedGroupAppearances(const []),
        reads: BotGroupReadState(),
        preferences: groupPreferences,
      );
      addTearDown(visit.dispose);
      expect(
        await visit.readRecentMessages(limit: 11, canRead: () => true),
        hasLength(11),
      );
      await expectLater(
        visit.readRecentMessages(limit: 6, canRead: () => false),
        throwsStateError,
      );
    },
  );

  test(
    'group tail cache excludes payloads beyond its retained byte budget',
    () async {
      final fixture = BotsFixture();
      final groupMessages = RecentGroupMessages();
      addTearDown(groupMessages.dispose);
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1700000000,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'x' * (1024 * 1024)},
      });
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: groupMessages,
      )).single;
      expect(groupMessages.borrow(group, limit: 6), isNull);
    },
  );

  test(
    'group dictation requires the captured visit and exact draft revision',
    () async {
      final fixture = BotsFixture();
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      BotGroupSession open() => BotGroupSession(
        fixture.repository,
        group,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),
        reads: BotGroupReadState(),
        preferences: groupPreferences,
      )..setVisible(true);
      final session = open();
      final otherVisit = open();
      addTearDown(session.dispose);
      addTearDown(otherVisit.dispose);
      session.editMentions('Original');
      final captured = session.captureVoiceDraft();
      expect(session.voiceTarget.chat, isNull);
      expect(session.voiceTarget.group, group.key);
      session.editMentions('Edited');
      session.editMentions('Original');
      expect(
        () => session.applyVoiceDraft(captured, 'Late result'),
        throwsStateError,
      );
      final current = session.captureVoiceDraft();
      expect(
        () => otherVisit.applyVoiceDraft(current, 'Wrong visit'),
        throwsStateError,
      );
      await session.applyVoiceDraft(current, 'Original dictated');
      expect(session.captureVoiceDraft().text, 'Original dictated');
      session.setVisible(false);
      expect(() => session.captureVoiceDraft(), throwsStateError);
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'group voice uses its captured instance and stock default-profile audio',
    () async {
      final server = AdministrationFixture();
      final fixture = BotsFixture(server: server.server);
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      server.mutationOverride =
          (method, path, query, body, canDispatch, onDispatched) async {
            expect(canDispatch(), isTrue);
            onDispatched();
            server.requests.add((method, path, query, body));
            return {'ok': true, 'transcript': 'Spoken group draft'};
          };
      final voice = fixture.repository.voiceForGroup(group);
      expect(
        await voice.transcribe(Uint8List.fromList([1, 2, 3])),
        'Spoken group draft',
      );
      final request = server.requests.single;
      expect(request.$1, 'POST');
      expect(request.$2, 'audio/transcribe');
      expect(request.$3, {'profile': 'default'});
      expect(request.$4, {
        'data_url': 'data:audio/mp4;base64,AQID',
        'mime_type': 'audio/mp4',
      });
      voice.close();
      await expectLater(
        voice.transcribe(Uint8List.fromList([1])),
        throwsStateError,
      );
      expect(server.requests, hasLength(1));
      expect(fixture.commands, isEmpty);
    },
  );
  ProfileSessionKey canonical(String name, {String suffix = 'chat'}) =>
      ProfileSessionKey(
        WorkspaceScope(
          connectionId: 'host',
          connectionIdentity: 'instance-1',
          profileName: name,
        ),
        '$name-$suffix',
      );

  test('direct chat retains its settings repository until disposal', () async {
    final fixture = BotsFixture();
    var retained = 0, released = 0;
    final repository = BotsRepository(
      groupObservations: GroupObservations(fixture.repository.scope),
      scope: fixture.repository.scope,
      instance: fixture.repository.instance,
      read: fixture.read,
      command: fixture.command,
      ownership: fixture.ownership,

      retain: () => retained++,
      release: () => released++,
    );
    final owner = BotsSession((_) async => [repository]);
    final key = canonical('atlas');
    expect((await owner.botForConversation(key))!.title, 'Atlas');
    expect(
      owner.repository(key.workspace.connectionIdentity),
      same(repository),
    );
    expect(retained - released, 1);
    owner.invalidateAppearances();
    expect((await owner.botForConversation(key))!.title, 'Atlas');
    expect(retained - released, 1);
    await owner.refresh();
    expect(retained - released, 1);
    owner.dispose();
    expect(released, retained);
  });

  test(
    'profile appearance never borrows a same-named bot from another connection',
    () async {
      final fixture = BotsFixture();
      var reads = 0;
      fixture.readHook = (_, _, _) async {
        reads++;
        return null;
      };
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      final wrongSavedId = WorkspaceScope(
        connectionId: 'another-saved-connection',
        connectionIdentity: 'instance-1',
        profileName: 'atlas',
      );
      final wrongInstance = WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: 'another-instance',
        profileName: 'atlas',
      );
      expect(
        await owner.appearancesForProfiles([
          wrongSavedId,
          wrongInstance,
        ], canRead: () => true),
        isEmpty,
      );
      expect(reads, 0);
      final scope = canonical('atlas').workspace;
      final result = await owner.appearancesForProfiles([
        scope,
        wrongSavedId,
        wrongInstance,
      ], canRead: () => true);
      expect(result.keys, [scope]);
      expect(result[scope]!.title, 'Atlas');
      expect(reads, 1);
    },
  );

  test(
    'metadata remains available beyond the ten image slots without rereading the roster',
    () async {
      final fixture = BotsFixture();
      fixture.profiles
        ..clear()
        ..addAll([
          for (var i = 0; i < 11; i++) BotsFixture.profile('bot$i', 'Bot $i'),
        ]);
      var rosters = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'profiles.list') rosters++;
        return null;
      };
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      for (var i = 0; i < 11; i++) {
        expect(
          (await owner.botForConversation(canonical('bot$i')))!.title,
          'Bot $i',
        );
      }
      expect(owner.cachedAppearance(canonical('bot0'))!.title, 'Bot 0');
      expect(owner.cachedAppearance(canonical('bot10'))!.title, 'Bot 10');
      expect(
        (await owner.botForConversation(canonical('bot0')))!.title,
        'Bot 0',
      );
      expect(rosters, 1);
    },
  );

  test(
    'confirmed owner refresh replaces only changed appearance observations',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture();
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      final key = canonical('atlas');
      final before = await owner.botForConversation(key);
      await owner.refresh();
      expect(owner.cachedAppearance(key), same(before));
      (fixture.profiles.first['ui_meta'] as Map)['hermes-bots']['title'] =
          'Atlas revised';
      fixture.profiles.first['ui_meta_revisions'] = {'hermes-bots': 3};
      now = now.add(const Duration(seconds: 30));
      await owner.refresh();
      expect(owner.cachedAppearance(key)!.title, 'Atlas revised');
      expect(owner.cachedAppearance(key), isNot(same(before)));
    },
  );
  test(
    'group publication crosses instances without waiting for bots',
    () async {
      final first = BotsFixture(), second = BotsFixture();
      second.room['name'] = 'Second team';
      final scope = WorkspaceScope(
        connectionId: 'other-host',
        connectionIdentity: 'instance-2',
        profileName: 'default',
      );
      final other = BotsRepository(
        groupObservations: GroupObservations(scope),
        scope: scope,
        instance: 'Other server',
        read: second.read,
        command: second.command,
        ownership: second.ownership,
      );
      final started = Completer<void>(), release = Completer<void>();
      first.readHook = (_, method, _) async {
        if (method == 'session.active_list') {
          started.complete();
          await release.future;
        }
        return null;
      };
      final owner = BotsSession((_) async => [first.repository, other]);
      addTearDown(owner.dispose);
      final refresh = owner.refresh();
      try {
        await started.future;
        await Future<void>.delayed(Duration.zero);
        expect(owner.observedGroups.map((g) => g.name), [
          'Research team',
          'Second team',
        ]);
        expect(owner.groupForKey(owner.observedGroups.last.key)!.scope, scope);
        expect(owner.state.loading, isTrue);
      } finally {
        release.complete();
        await refresh;
      }
      expect(owner.state.loading, isFalse);
      expect(owner.state.bots, hasLength(6));
      expect(owner.state.errors, isEmpty);
      expect([...first.commands, ...second.commands], isEmpty);
    },
  );

  test('retired group discovery cannot continue or publish', () async {
    final fixture = BotsFixture();
    final started = Completer<void>(), release = Completer<void>();
    var continued = false;
    fixture.readHook = (_, method, _) async {
      if (method == 'groups.list') {
        started.complete();
        await release.future;
      }
      if (method == 'groups.state' || method == 'groups.log') continued = true;
      return null;
    };
    final owner = BotsSession((_) async => [fixture.repository]);
    final refresh = owner.refresh();
    await started.future;
    owner.dispose();
    release.complete();
    await refresh;
    expect(continued, isFalse);
    expect(owner.observedGroups, isEmpty);
    expect(fixture.commands, isEmpty);
  });

  test(
    'delivered sender appearance uses its exact handle and instance',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.add(BotsFixture.profile('default', 'Default'));
      fixture.profiles.first['has_avatar'] = true;
      final methods = <String>[];
      fixture.readHook = (_, method, _) async {
        methods.add(method);
        if (method == 'profiles.get_asset') {
          return {'found': true, 'data': _avatarPng};
        }
        return null;
      };
      final session = BotsSession((_) async => [fixture.repository]);
      addTearDown(session.dispose);
      final scope = WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: 'instance-1',
        profileName: 'mira',
      );
      final atlas = await session.appearanceForSender(scope, 'atlas');
      expect(atlas!.title, 'Atlas');
      expect(methods, ['profiles.list']);
      expect(
        (await session.appearanceForSender(scope, 'hermes'))!.profile.name,
        'default',
      );
      expect(await session.appearanceForSender(scope, 'Atlas'), isNull);
      expect(await session.appearanceForSender(scope, 'default'), isNull);
      methods.clear();
      expect(
        await session.appearanceForSender(
          WorkspaceScope(
            connectionId: 'other',
            connectionIdentity: 'instance-1',
            profileName: 'mira',
          ),
          'atlas',
        ),
        isNull,
      );
      expect(methods, isEmpty);
    },
  );

  test(
    'sender appearance failure and disposal keep delivery readable',
    () async {
      final fixture = BotsFixture();
      final scope = WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: 'instance-1',
        profileName: 'mira',
      );
      final session = BotsSession((_) async => [fixture.repository]);
      fixture.readHook = (_, _, _) async => throw StateError('Offline');
      expect(await session.appearanceForSender(scope, 'atlas'), isNull);
      final held = Completer<Map<String, dynamic>>();
      fixture.readHook = (_, _, _) => held.future;
      final late = session.appearanceForSender(scope, 'atlas');
      await Future<void>.delayed(Duration.zero);
      session.dispose();
      held.complete({'profiles': fixture.profiles, 'bot_mode_protocol': true});
      expect(await late, isNull);
    },
  );
  for (final status in ['working', 'waiting']) {
    test(
      'production presence proves compressed root ownership: $status',
      () async {
        final administration = AdministrationFixture();
        final fixture = BotsFixture();
        for (final row in fixture.profiles) {
          administration.configs[row['name'] as String] = {};
        }
        administration.rpcOverride = (method, params) async {
          if (method == 'session.active_list') {
            return {
              'sessions': [
                {
                  'id': 'runtime',
                  'session_key': 'atlas-chat',
                  'status': status,
                },
              ],
            };
          }
          return fixture.read(params['profile'] as String, method, params);
        };
        administration.override = (method, path, query, body) async {
          if (path == 'profiles') {
            return {'profiles': fixture.profiles};
          }
          if (path == 'profiles/active') {
            return {'current': 'atlas', 'active': 'atlas'};
          }
          if (path == 'sessions/search') {
            return {
              'results': [
                {
                  'id': 'atlas-tip',
                  'session_id': 'atlas-tip',
                  'profile': query['profile'],
                },
              ],
            };
          }
          if (query['profile'] == 'atlas') {
            return {'id': 'atlas-chat', 'profile': 'atlas', 'hidden': true};
          }
          throw DashboardSessionNotFound(path);
        };
        final repository = BotsRepository.forServer(
          administration.server,
          groupObservations: GroupObservations(
            WorkspaceScope(
              connectionId: (administration.server).connectionId,
              connectionIdentity: (administration.server).connectionIdentity,
              profileName: 'default',
            ),
          ),
        );
        final roster = await repository.bots();
        final presence = (await repository.presence(roster)).values;
        expect(
          presence[roster.first.id],
          status == 'waiting' ? BotPresence.needsInput : BotPresence.working,
        );
        expect(presence[roster[1].id], BotPresence.idle);
        expect(presence[roster[2].id], BotPresence.idle);
        expect(
          administration.requests.any((r) => r.$2 == 'sessions/search'),
          false,
        );
      },
    );
  }
  for (final failure in ['transport', 'owner', 'id', 'wrong absence']) {
    test(
      'production presence stays unknown on $failure and recovers',
      () async {
        final administration = AdministrationFixture();
        final fixture = BotsFixture();
        administration.rpcOverride = (method, params) async =>
            method == 'session.active_list'
            ? {
                'sessions': [
                  {
                    'id': 'runtime',
                    'session_key': 'atlas-chat',
                    'status': 'working',
                  },
                ],
              }
            : fixture.read(params['profile'] as String, method, params);
        var broken = true;
        administration.override = (method, path, query, body) async {
          if (path == 'profiles') {
            return {'profiles': fixture.profiles};
          }
          if (path == 'profiles/active') {
            return {'current': 'atlas', 'active': 'atlas'};
          }
          if (path == 'sessions/search') return {'results': []};
          if (query['profile'] != 'atlas') throw DashboardSessionNotFound(path);
          if (broken) {
            switch (failure) {
              case 'transport':
                throw StateError('Offline');
              case 'owner':
                return {'id': 'atlas-chat', 'profile': 'mira'};
              case 'id':
                return {'id': 'atlas-tip', 'profile': 'atlas'};
              case 'wrong absence':
                throw const DashboardSessionNotFound('sessions/another');
            }
          }
          return {'id': 'atlas-chat', 'profile': 'atlas'};
        };
        final repository = BotsRepository.forServer(
          administration.server,
          groupObservations: GroupObservations(
            WorkspaceScope(
              connectionId: (administration.server).connectionId,
              connectionIdentity: (administration.server).connectionIdentity,
              profileName: 'default',
            ),
          ),
        );
        final roster = await repository.bots();
        expect(
          (await repository.presence(roster)).values.values,
          everyElement(BotPresence.unknown),
        );
        broken = false;
        expect(
          (await repository.presence(roster)).values[roster.first.id],
          BotPresence.working,
        );
      },
    );
  }
  test(
    'uploaded avatar handoff preserves saved image and clears it on shape selection',
    () async {
      final fixture = BotsFixture();
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,
        avatarIo: _AvatarPicker(),

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      await edit.pickImage();
      edit.change(title: 'Saved title', color: '#123456');
      expect(await edit.flush(), true);
      final acknowledged = edit.bot;
      final savedImage = edit.savedImage;
      expect(acknowledged.hasAvatar, true);
      expect(edit.savedImage, orderedEquals(base64Decode(_avatarPng)));
      expect(acknowledged.title, 'Saved title');
      expect(acknowledged.color, '#123456');
      expect(acknowledged.chat!.sessionId, 'atlas-chat');
      expect(acknowledged.metadata['unrelated'], {
        'nested': ['kept'],
      });
      edit.dispose();
      final reopened = BotProfileEditSession(
        fixture.repository,
        acknowledged,
        savedImage: savedImage,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      expect(reopened.image, orderedEquals(base64Decode(_avatarPng)));
      reopened.change(shape: 'triangle');
      expect(await reopened.flush(), true);
      expect(reopened.savedImage, isNull);
      expect(reopened.bot.hasAvatar, false);
      expect(fixture.commands.last.$3['clear'], true);
      final afterShape = reopened.bot;
      reopened.dispose();
      final finalEditor = BotProfileEditSession(
        fixture.repository,
        afterShape,
        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      expect(finalEditor.image, isNull);
      expect(finalEditor.shape, 'triangle');
      finalEditor.dispose();
    },
  );
  test(
    'editor shape preview yields to draft and acknowledged photos',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['ui_meta']['hermes-bots']['imageKind'] = 'shape';
      final bot = (await fixture.repository.bots()).first.withAvatarHint(true);
      final edit = BotProfileEditSession(
        fixture.repository,
        bot,
        savedImage: base64Decode(_avatarPng),
        avatarIo: _AvatarPicker(),

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      expect(edit.image, isNull);
      expect(edit.dirty, false);
      edit.change(color: '#123456');
      expect(edit.image, isNull);
      expect(await edit.flush(), true);
      expect(edit.image, isNull);
      expect(edit.savedImage, orderedEquals(base64Decode(_avatarPng)));
      expect(fixture.commands.single.$2, 'profiles.configure');
      await edit.pickImage();
      expect(edit.image, orderedEquals(base64Decode(_avatarPng)));
      expect(await edit.flush(), true);
      expect(edit.bot.metadata['imageKind'], 'photo');
      expect(edit.image, orderedEquals(base64Decode(_avatarPng)));
      final reopened = BotProfileEditSession(
        fixture.repository,
        edit.bot,
        savedImage: edit.savedImage,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      expect(reopened.image, orderedEquals(base64Decode(_avatarPng)));
      reopened.dispose();
    },
  );
  for (final kind in [null, 'photo', 'unexpected']) {
    test('editor retains saved images with image kind $kind', () async {
      final fixture = BotsFixture();
      final meta = fixture.profiles.first['ui_meta']['hermes-bots'];
      if (kind != null) meta['imageKind'] = kind;
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first.withAvatarHint(true),
        savedImage: base64Decode(_avatarPng),

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      edit.change(color: '#123456');
      expect(edit.image, orderedEquals(base64Decode(_avatarPng)));
      expect(await edit.flush(), true);
      expect(edit.image, orderedEquals(base64Decode(_avatarPng)));
    });
  }
  test(
    'avatar acknowledgement preserves edits arriving during an asset write',
    () async {
      final fixture = BotsFixture();
      final started = Completer<void>(), held = Completer<void>();
      final clearing = Completer<void>(), clearHeld = Completer<void>();
      fixture.commandHook = (_, method, _) async {
        if (method == 'profiles.set_asset' && !started.isCompleted) {
          started.complete();
          await held.future;
        } else if (method == 'profiles.set_asset') {
          clearing.complete();
          await clearHeld.future;
        }
        return null;
      };
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,
        avatarIo: _AvatarPicker(),

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      await edit.pickImage();
      final saving = edit.flush();
      await started.future;
      edit.change(title: 'Newer title');
      edit.removeImage();
      held.complete();
      await clearing.future;
      expect(edit.savedImage, orderedEquals(base64Decode(_avatarPng)));
      expect(edit.bot.hasAvatar, true);
      expect(edit.bot.title, 'Newer title');
      expect(edit.bot.revision, 4);
      expect(edit.image, isNull);
      expect(edit.dirty, true);
      clearHeld.complete();
      expect(await saving, true);
      expect(edit.bot.title, 'Newer title');
      expect(edit.savedImage, isNull);
      expect(edit.bot.hasAvatar, false);
      expect(edit.dirty, false);
      expect(
        fixture.commands.where((c) => c.$2 == 'profiles.set_asset').length,
        2,
      );
      final reopened = BotProfileEditSession(
        fixture.repository,
        edit.bot,
        savedImage: edit.savedImage,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      expect(reopened.image, isNull);
      reopened.dispose();
    },
  );
  test(
    'roster ordering uses newest stock activity and preserves it through edits',
    () async {
      final fixture = BotsFixture();
      fixture.profiles[0]['canonical_session'] = <String, dynamic>{
        ...fixture.profiles[0]['canonical_session'],
        'last_active': 1000,
      };
      fixture.profiles[0]['last_session'] = <String, dynamic>{
        ...fixture.profiles[0]['last_session'],
        'last_active': 1500,
      };
      fixture.profiles[0]['worker_session'] = {
        'id': 'atlas-worker',
        'source': 'tool',
        'last_active': 2000,
      };
      fixture.profiles[1]['canonical_session'] = <String, dynamic>{
        ...fixture.profiles[1]['canonical_session'],
        'last_active': 3000,
      };
      fixture.profiles[1]['last_session'] = <String, dynamic>{
        ...fixture.profiles[1]['last_session'],
        'last_active': 2500,
      };
      fixture.profiles[2]['canonical_session'] = <String, dynamic>{
        ...fixture.profiles[2]['canonical_session'],
        'last_active': 'invalid',
      };
      fixture.profiles[2]['last_session'] = <String, dynamic>{
        ...fixture.profiles[2]['last_session'],
        'last_active': -1,
      };
      fixture.profiles[2]['worker_session'] = {
        'id': 'forge-worker',
        'source': 'tool',
        'last_active': 1e30,
      };
      final roster = await fixture.repository.bots();
      expect(
        roster[0].lastActive,
        DateTime.fromMillisecondsSinceEpoch(2000000, isUtc: true),
      );
      expect(
        roster[1].lastActive,
        DateTime.fromMillisecondsSinceEpoch(3000000, isUtc: true),
      );
      expect(roster[2].lastActive, isNull);
      final enriched = roster[0].withPresence(BotPresence.idle);
      for (final copy in [
        enriched,
        enriched.withPresence(BotPresence.working),
        enriched.withAvatarHint(false),
        enriched.withMetadata(
          metadata: enriched.metadata,
          revision: 3,
          title: 'Renamed',
        ),
      ]) {
        expect(copy.lastActive, roster[0].lastActive);
      }
      final ordered = [...roster]..sort(BotRecord.compareForRoster);
      expect(ordered.map((bot) => bot.profile.name), [
        'mira',
        'atlas',
        'forge',
      ]);
      fixture.profiles[0]['last_session'] = <String, dynamic>{
        ...fixture.profiles[0]['last_session'],
        'last_active': 3000,
      };
      fixture.profiles[2]['canonical_session'] = <String, dynamic>{
        ...fixture.profiles[2]['canonical_session'],
        'last_active': 3000,
      };
      final tied = [...await fixture.repository.bots()]
        ..sort(BotRecord.compareForRoster);
      expect(tied.map((bot) => bot.profile.name), ['atlas', 'forge', 'mira']);
      expect(fixture.commands, isEmpty);
    },
  );

  test('roster activity includes stock background worker heartbeats', () async {
    final now = DateTime.utc(2026, 10, 12, 12);
    final fixture = BotsFixture(now: () => now);
    fixture.profiles.first['worker_session'] = {
      'id': 'private-worker',
      'source': 'kanban',
      'title': 'Background work',
      'last_active': now.millisecondsSinceEpoch / 1000,
    };
    fixture.readHook = (_, method, _) async =>
        method == 'session.active_list' ? {'sessions': []} : null;
    final owner = BotsSession((_) async => [fixture.repository]);
    addTearDown(owner.dispose);
    await owner.refresh();
    expect(owner.state.bots.first.presence, BotPresence.working);
    expect(owner.state.bots.skip(1).map((bot) => bot.presence), [
      BotPresence.idle,
      BotPresence.idle,
    ]);
    expect(owner.state.bots.first.chat!.sessionId, 'atlas-chat');
    expect(owner.state.bots.first.preview, contains('three useful approaches'));
    expect(fixture.commands, isEmpty);
  });

  test('worker heartbeat expiry and renewal update the same bot', () async {
    var now = DateTime.utc(2026, 10, 12, 12);
    final fixture = BotsFixture(now: () => now);
    final worker = {
      'id': 'private-worker',
      'source': 'tool',
      'last_active': now.millisecondsSinceEpoch / 1000,
    };
    fixture.profiles.first['worker_session'] = worker;
    fixture.readHook = (_, method, _) async =>
        method == 'session.active_list' ? {'sessions': []} : null;
    final owner = BotsSession(
      (_) async => [fixture.repository],
      now: () => now,
    );
    addTearDown(owner.dispose);
    for (final (elapsed, expected) in [
      (0, BotPresence.working),
      (120000, BotPresence.working),
      (150000, BotPresence.idle),
    ]) {
      now = DateTime.utc(2026, 10, 12, 12).add(Duration(milliseconds: elapsed));
      await owner.refresh();
      expect(owner.state.bots.first.presence, expected);
      expect(
        owner.state.bots.first.workerLastActive,
        DateTime.utc(2026, 10, 12, 12),
      );
    }
    now = now.add(const Duration(seconds: 30));
    worker['last_active'] = now.millisecondsSinceEpoch / 1000;
    await owner.refresh();
    expect(owner.state.bots.first.presence, BotPresence.working);
    now = now.add(const Duration(seconds: 30));
    fixture.profiles.first['worker_session'] = null;
    await owner.refresh();
    expect(owner.state.bots.first.presence, BotPresence.idle);
    expect(fixture.commands, isEmpty);
  });

  test('fresh worker evidence survives unavailable live sessions', () async {
    final now = DateTime.utc(2026, 10, 12, 12);
    final fixture = BotsFixture(now: () => now);
    fixture.profiles.first['worker_session'] = {
      'id': 'private-worker',
      'source': 'kanban',
      'last_active': now.millisecondsSinceEpoch / 1000,
    };
    fixture.readHook = (_, method, _) async {
      if (method == 'session.active_list') throw StateError('Disconnected');
      return null;
    };
    final roster = await fixture.repository.bots();
    final presence = (await fixture.repository.presence(roster)).values;
    expect(presence[roster.first.id], BotPresence.working);
    expect(presence[roster[1].id], BotPresence.unknown);
  });

  test('pending input takes precedence over worker motion', () async {
    final now = DateTime.utc(2026, 10, 12, 12);
    final fixture = BotsFixture(now: () => now);
    fixture.profiles[1]['worker_session'] = {
      'id': 'private-worker',
      'source': 'tool',
      'last_active': now.millisecondsSinceEpoch / 1000,
    };
    final roster = await fixture.repository.bots();
    expect(
      (await fixture.repository.presence(roster)).values[roster[1].id],
      BotPresence.needsInput,
    );
  });

  test('invalid worker observations never animate an idle bot', () async {
    final now = DateTime.utc(2026, 10, 12, 12);
    final fixture = BotsFixture(now: () => now);
    fixture.readHook = (_, method, _) async => switch (method) {
      'session.active_list' => {'sessions': []},
      'profiles.list' => {
        'profiles': fixture.profiles,
        'bot_mode_protocol': true,
        'install_id': 'install-1',
      },
      _ => null,
    };
    for (final value in [
      null,
      'invalid',
      {},
      {
        'id': '',
        'source': 'tool',
        'last_active': now.millisecondsSinceEpoch / 1000,
      },
      for (final timestamp in [
        'invalid',
        0,
        -1,
        double.nan,
        double.infinity,
        1e30,
        now.millisecondsSinceEpoch / 1000 + 1,
      ])
        {'id': 'private-worker', 'source': 'tool', 'last_active': timestamp},
    ]) {
      fixture.profiles.first['worker_session'] = value;
      final roster = await fixture.repository.bots();
      expect(
        (await fixture.repository.presence(roster)).values[roster.first.id],
        BotPresence.idle,
      );
    }
  });
  test(
    'failed asset write leaves metadata acknowledgement and retries only asset',
    () async {
      final fixture = BotsFixture();
      var failAsset = true;
      fixture.commandHook = (_, method, _) async {
        if (method == 'profiles.set_asset' && failAsset) {
          throw StateError('Lost acknowledgement');
        }
        return null;
      };
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,
        avatarIo: _AvatarPicker(),

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      await edit.pickImage();
      edit.change(title: 'Saved metadata');
      expect(await edit.flush(), false);
      expect(edit.bot.title, 'Saved metadata');
      expect(edit.bot.revision, 3);
      expect(edit.bot.hasAvatar, false);
      expect(edit.savedImage, isNull);
      failAsset = false;
      expect(await edit.flush(), true);
      expect(edit.savedImage, orderedEquals(base64Decode(_avatarPng)));
      expect(edit.bot.hasAvatar, true);
      expect(
        fixture.commands.where((c) => c.$2 == 'profiles.configure').length,
        1,
      );
    },
  );
  test(
    'conversation appearance admits exact canonical root and tip only',
    () async {
      final fixture = BotsFixture();
      final methods = <String>[];
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=';
      fixture.profiles.first['has_avatar'] = true;
      fixture.readHook = (_, method, _) async {
        methods.add(method);
        if (method == 'profiles.get_asset') {
          return {'found': true, 'data': png};
        }
        return null;
      };
      final session = BotsSession((_) async => [fixture.repository]);
      addTearDown(session.dispose);
      final scope = WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: 'instance-1',
        profileName: 'atlas',
      );
      for (final id in ['atlas-chat', 'atlas-tip']) {
        methods.clear();
        final bot = await session.botForConversation(
          ProfileSessionKey(scope, id),
        );
        expect(bot!.title, 'Atlas');
        expect(
          bot
              .withMetadata(metadata: bot.metadata, revision: 4)
              .describesConversation(ProfileSessionKey(scope, 'atlas-tip')),
          true,
        );
        expect(methods, id == 'atlas-chat' ? ['profiles.list'] : isEmpty);
      }
      methods.clear();
      final root = ProfileSessionKey(scope, 'atlas-chat');
      final tip = ProfileSessionKey(scope, 'atlas-tip');
      final unrelated = ProfileSessionKey(scope, 'atlas-cron');
      final appearances = await session.appearancesForConversations([
        root,
        tip,
        unrelated,
      ], canRead: () => true);
      expect(appearances.keys, unorderedEquals([root, tip]));
      expect(identical(appearances[root], appearances[tip]), true);
      expect(methods, isEmpty);
      for (final key in [
        ProfileSessionKey(scope, 'atlas-cron'),
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: 'host',
            connectionIdentity: 'instance-1',
            profileName: 'mira',
          ),
          'atlas-chat',
        ),
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: 'other',
            connectionIdentity: 'instance-1',
            profileName: 'atlas',
          ),
          'atlas-chat',
        ),
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: 'host',
            connectionIdentity: 'edited-instance',
            profileName: 'atlas',
          ),
          'atlas-chat',
        ),
      ]) {
        methods.clear();
        expect(await session.botForConversation(key), isNull);
        expect(methods, isNot(contains('profiles.get_asset')));
      }
      expect(fixture.commands, isEmpty);
    },
  );
  test(
    'conversation appearance read failure and disposal stay passive',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture();
      var retains = 0, releases = 0;
      final repository = BotsRepository(
        groupObservations: GroupObservations(fixture.repository.scope),
        scope: fixture.repository.scope,
        instance: fixture.repository.instance,
        read: fixture.read,

        command: fixture.command,
        ownership: fixture.ownership,
        retain: () => retains++,
        release: () => releases++,
      );
      final session = BotsSession((_) async => [repository], now: () => now);
      final key = ProfileSessionKey(
        WorkspaceScope(
          connectionId: 'host',
          connectionIdentity: 'instance-1',
          profileName: 'atlas',
        ),
        'atlas-chat',
      );
      fixture.readHook = (_, method, _) async => throw StateError('Offline');
      expect(await session.botForConversation(key), isNull);
      expect(session.state.errors, isEmpty);
      expect(retains - releases, 1); // The retained catalog owner.
      final held = Completer<Map<String, dynamic>?>();
      final started = Completer<void>();
      fixture.readHook = (_, method, _) async {
        started.complete();
        return held.future;
      };
      now = now.add(const Duration(seconds: 30));
      final reading = session.botForConversation(key);
      await started.future;
      expect(retains - releases, 2); // Catalog plus the in-flight read.
      session.dispose();
      expect(retains - releases, 1); // Only the unfinished read remains.
      held.complete(null);
      expect(await reading, isNull);
      expect(releases, retains);
      expect(fixture.commands, isEmpty);
    },
  );
  test(
    'roster preview and click share the server-owned canonical root, never last_session',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['canonical_session'] = null;
      // Latest-session metadata is irrelevant to the canonical bot roster.
      fixture.profiles[1]['last_session'] = {'id': null};
      final bots = await fixture.repository.bots();
      expect(bots.first.chat, isNull);
      expect(bots.first.preview, isEmpty);
      expect(bots[1].chat!.sessionId, 'mira-chat');
      expect(bots[1].preview, contains('review is ready'));
      expect(
        () => (bots.first.metadata['unrelated'] as Map)['nested'] = [],
        throwsUnsupportedError,
      );
    },
  );
  test(
    'live presence is profile scoped and never inferred from a message preview',
    () async {
      final fixture = BotsFixture();
      final roster = await fixture.repository.bots();
      final presence = (await fixture.repository.presence(roster)).values;
      final bots = roster
          .map((bot) => bot.withPresence(presence[bot.id]!))
          .toList();
      expect(bots.map((bot) => bot.presence), [
        BotPresence.idle,
        BotPresence.needsInput,
        BotPresence.working,
      ]);
      fixture.readHook = (_, method, _) async {
        if (method == 'session.active_list') throw StateError('Disconnected');
        return null;
      };
      expect(
        (await fixture.repository.presence(bots)).values[bots.first.id],
        BotPresence.unknown,
      );
    },
  );

  test(
    'metadata CAS preserves unknown fields and conflicts leave the draft intact',
    () async {
      final fixture = BotsFixture();
      final bot = (await fixture.repository.bots()).first;
      final updated = await fixture.repository.metadata(
        bot,
        {'pinned': false},
        () => true,
        () {},
      );
      expect(updated.revision, 3);
      expect(updated.metadata['unrelated'], bot.metadata['unrelated']);
      final edit = BotProfileEditSession(
        fixture.repository,
        updated,
        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      edit.change(title: 'Atlas revised');
      fixture.conflict = true;
      expect(await edit.flush(), false);
      expect(edit.conflicted, true);
      expect(edit.title, 'Atlas revised');
      fixture.conflict = false;
      await edit.reload();
      expect(edit.title, 'Atlas revised');
      expect(await edit.flush(), true);
      expect(
        fixture.commands.last.$3['ui_meta']['hermes-bots']['unrelated'],
        bot.metadata['unrelated'],
      );
    },
  );
  test('wrong instance cannot dispatch profile or group operations', () async {
    final fixture = BotsFixture();
    final other = BotsRepository(
      groupObservations: GroupObservations(
        WorkspaceScope(
          connectionId: 'other',
          connectionIdentity: 'other',
          profileName: 'default',
        ),
      ),
      scope: WorkspaceScope(
        connectionId: 'other',
        connectionIdentity: 'other',
        profileName: 'default',
      ),
      instance: 'Other',
      read: fixture.read,

      command: fixture.command,
      ownership: fixture.ownership,
    );
    final bot = (await fixture.repository.bots()).first;
    await expectLater(
      other.metadata(bot, {'pinned': false}, () => true, () {}),
      throwsStateError,
    );
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).first;
    await expectLater(
      other.sendGroup(group, 'event', 'hello', () => true, () {}),
      throwsStateError,
    );
    expect(fixture.commands, isEmpty);
  });
  test(
    'canonical creation materializes exact title with hidden and current profile config',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['canonical_session'] = null;
      final bot = (await fixture.repository.bots()).first;
      final key = await fixture.repository.openChat(bot, () => true, () {});
      expect(key.chat!.workspace, bot.scope);
      expect(key.chat!.sessionId, 'new-bot-chat-1');
      expect(fixture.commands.single.$2, 'session.create');
      expect(fixture.commands.single.$3, {
        'title': 'Bot Chat',
        'hidden': true,
        'follow_profile_config': true,
        'source': 'gui',
      });
      await fixture.repository.openChat(bot, () => true, () {});
      expect(fixture.commands, hasLength(1));
    },
  );
  test(
    'a desktop title race adopts the winner without another creation or prompt',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['canonical_session'] = null;
      fixture.commandHook = (_, method, _) async {
        if (method == 'session.create') {
          fixture.profiles.first['canonical_session'] = {
            'id': 'desktop-winner',
            'preview': 'Desktop message',
          };
          return {
            'session_id': 'desktop-winner',
            'stored_session_id': 'desktop-winner',
          };
        }
        return null;
      };
      final key = await fixture.repository.openChat(
        (await fixture.repository.bots()).first,
        () => true,
        () {},
      );
      expect(key.chat!.sessionId, 'desktop-winner');
      expect(fixture.commands.where((c) => c.$2 == 'session.create').length, 1);
      expect(fixture.commands.any((c) => c.$2 == 'prompt.submit'), false);
    },
  );
  test(
    'a lost titled-create acknowledgement recovers without resubmission',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['canonical_session'] = null;
      fixture.commandHook = (_, method, _) async {
        if (method == 'session.create') {
          fixture.profiles.first['canonical_session'] = {
            'id': 'accepted-bot-chat',
            'resolved_id': 'accepted-bot-chat',
            'preview': '',
          };
          throw StateError('Connection closed after creation');
        }
        return null;
      };
      final bot = (await fixture.repository.bots()).first;
      final opened = await fixture.repository.openChat(bot, () => true, () {});
      expect(opened.chat!.sessionId, 'accepted-bot-chat');
      await fixture.repository.openChat(bot, () => true, () {});
      expect(fixture.commands.single.$2, 'session.create');
    },
  );
  test(
    'room references borrow saved avatars without reads or changing frozen addressing',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['has_avatar'] = true;
      final metadata = fixture.profiles.first['ui_meta']['hermes-bots'];
      metadata['title'] = 'Renamed Atlas';
      metadata['shape'] = 'hexagon';
      metadata['color'] = '#8b5cf6';
      var reads = 0;
      fixture.readHook = (profile, method, params) async {
        reads++;
        if (method == 'profiles.get_asset') {
          expect(profile, 'atlas');
          return {'found': true, 'data': 'data:image/png;base64,$_avatarPng'};
        }
        return null;
      };
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      await owner.refresh();
      final session = owner.openGroup(owner.state.groups.single);
      addTearDown(session.dispose);
      final before = reads;
      for (final text in ['@', '@bot_atlas', '@Atlas']) {
        final choice = session
            .completeMentions(MentionQuery.at(text, text.length)!)
            .items
            .first;
        expect(choice.label, 'Atlas');
        expect(choice.reference.token, '@Atlas');
        expect(choice.reference.target, 'atlas');
        expect(choice.appearance!.title, 'Renamed Atlas');
        expect(choice.appearance!.shape, 'hexagon');
        expect(choice.appearance!.color, '#8b5cf6');
        expect(choice.isCollective, isFalse);
      }
      final everyone = session
          .completeMentions(MentionQuery.at('@everyone', 9)!)
          .items
          .single;
      expect(everyone.isCollective, isTrue);
      expect(everyone.appearance, isNull);
      expect(reads, before);
    },
  );
  test(
    'room avatar admission rejects foreign and ambiguous profile observations',
    () async {
      final fixture = BotsFixture();
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      final roster = await fixture.repository.bots();
      final bot = roster.first;
      final foreign = BotRecord(
        scope: WorkspaceScope(
          connectionId: 'other-host',
          connectionIdentity: 'other-instance',
          profileName: bot.profile.name,
        ),
        instance: 'Other server',
        profile: bot.profile,
        title: bot.title,
        shape: bot.shape,
        color: bot.color,
        pinned: bot.pinned,
        hidden: bot.hidden,
        hasAvatar: bot.hasAvatar,
        revision: bot.revision,
        metadata: bot.metadata,
      );
      final session = BotGroupSession(
        fixture.repository,
        group,
        groupMessages: null,
        appearances: FixedGroupAppearances([foreign, roster[1], roster[1]]),

        reads: BotGroupReadState(),
        preferences: groupPreferences,
      );
      addTearDown(session.dispose);
      final choices = session.completeMentions(MentionQuery.at('@', 1)!).items;
      expect(choices.take(2).every((c) => c.appearance == null), isTrue);
      expect(choices.map((c) => c.reference.token), [
        '@Atlas',
        '@Mira',
        '@everyone',
      ]);
      session.editMentions('@everyone', selected: choices.last.reference);
      expect(await session.send('@everyone'), isTrue);
    },
  );
  test(
    'live replay retains a covered tail for a later route without preview reads',
    () async {
      final fixture = BotsFixture();
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': 1700000001,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Read in the live discussion'},
      });
      final bots = BotsSession((_) async => [fixture.repository]);
      addTearDown(bots.dispose);
      await bots.refresh();
      final cache = RecentGroupMessages();
      addTearDown(cache.dispose);
      bots.attachGroupMessages(cache);
      final live = bots.openGroup(bots.observedGroups.single);
      await live.refresh();
      live.dispose();
      var reads = 0;
      fixture.readHook = (_, _, _) async {
        reads++;
        return null;
      };
      final later = bots.openGroup(bots.observedGroups.single);
      addTearDown(later.dispose);
      expect(later.events.single.text, 'Read in the live discussion');
      expect(reads, 0);
      expect(bots.groupReads.unread(bots.observedGroups.single), isTrue);
      final cursors = <int>[];
      fixture.readHook = (_, method, params) async {
        if (method == 'groups.log') cursors.add(params['since_seq'] as int);
        return null;
      };
      await later.refresh();
      expect(cursors, [
        0,
      ], reason: 'Cached messages never advance the live replay cursor');
      final covered = bots.observedGroups.single;
      for (var index = 0; index < RecentGroupMessages.roomLimit; index++) {
        cache.record(
          BotGroup(
            scope: covered.scope,
            instance: covered.instance,
            id: 'other-$index',
            name: 'Other',
            members: const [],
            observationComplete: true,
          ),
          later.events,
          complete: true,
        );
      }
      expect(cache.borrow(covered, limit: 1), isNull);
      await later.editMentions('Keep typing');
      await later.refresh();
      expect(
        cache.borrow(covered, limit: 1),
        isNull,
        reason:
            'Draft/status updates must not rebuild or reinsert unchanged transcript tails',
      );
    },
  );

  for (final complete in [false, true]) {
    test(
      'live group borrows Recents messages before its first runtime read complete=$complete',
      () async {
        final fixture = BotsFixture();
        fixture.events.add({
          'room_id': 'room-1',
          'seq': 1,
          'kind': 'message.member',
          'actor': {'kind': 'member', 'id': 'atlas', 'profile': 'atlas'},
          'created_at': 1791756000.0,
          'payload': {'text': 'Cached latest reply'},
        });
        final cache = RecentGroupMessages();
        addTearDown(cache.dispose);
        final group = (await readFixtureGroups(
          fixture.repository,
          groupMessages: cache,
        )).single;
        final tail = cache.borrow(group, limit: 10)!;
        cache.record(group, tail, complete: complete);
        expect(
          cache.borrow(group, limit: 1)!.single.text,
          'Cached latest reply',
        );
        final session = BotGroupSession(
          fixture.repository,
          group,
          reads: BotGroupReadState(),
          preferences: groupPreferences,
          groupMessages: cache,
          appearances: FixedGroupAppearances(const []),
        );
        addTearDown(session.dispose);
        expect(session.events.single.text, 'Cached latest reply');
        expect(session.runtime, isNull);
        final cursors = <int>[];
        fixture.readHook = (_, method, params) async {
          if (method == 'groups.log') cursors.add(params['since_seq'] as int);
          return null;
        };
        await session.refresh();
        expect(cursors, [0]);
        expect(session.events.single.text, 'Cached latest reply');
      },
    );
  }

  for (final outcome in ['success', 'failure', 'retired']) {
    test(
      'concurrent group refresh awaits the owned read through $outcome',
      () async {
        final fixture = BotsFixture();
        final group = (await readFixtureGroups(
          fixture.repository,
          groupMessages: null,
        )).first;
        final session = BotGroupSession(
          fixture.repository,
          group,
          reads: BotGroupReadState(),
          preferences: groupPreferences,
          groupMessages: null,
          appearances: FixedGroupAppearances(const []),
        );
        if (outcome != 'retired') addTearDown(session.dispose);
        await session.refresh();
        final started = Completer<void>();
        final release = Completer<void>();
        var stateReads = 0;
        fixture.readHook = (_, method, _) async {
          if (method == 'groups.state') {
            stateReads++;
            if (!started.isCompleted) started.complete();
            await release.future;
            if (outcome == 'failure') throw StateError('Offline');
          }
          return null;
        };
        final poll = session.refresh(explicit: false);
        await started.future;
        final manual = session.refresh();
        expect(identical(poll, manual), isTrue);
        var settled = false;
        unawaited(manual.then((_) => settled = true));
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);
        expect(stateReads, 1);
        if (outcome == 'retired') session.dispose();
        release.complete();
        await Future.wait([poll, manual]);
        expect(settled, isTrue);
        expect(stateReads, 1);
        if (outcome == 'failure') {
          expect(session.error, contains('could not refresh'));
          fixture.readHook = null;
          await session.refresh();
          expect(session.error, isNull);
        }
      },
    );
  }

  test(
    'group capture retires held reads and resumes the exact log cursor',
    () async {
      final fixture = BotsFixture();
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      fixture.events.add({
        'room_id': group.id,
        'seq': 1,
        'kind': 'message.member',
        'actor': {
          'kind': 'member',
          'id': 'atlas',
          'profile': 'atlas',
          'display_name': 'Atlas',
        },
        'created_at': 1791756000.5,
        'payload': {'text': '**Evidence**'},
      });
      final session = BotGroupSession(
        fixture.repository,
        group,
        reads: BotGroupReadState(),
        preferences: groupPreferences,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),
      );
      addTearDown(session.dispose);
      final waiting = Completer<void>();
      final started = Completer<void>();
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.log') {
          if (!started.isCompleted) started.complete();
          await waiting.future;
        }
        return null;
      };
      final reading = session.refresh();
      await started.future;
      session.setCapturing(true);
      waiting.complete();
      await reading;
      expect(session.events, isEmpty);
      await session.refresh();
      expect(session.events, isEmpty);
      session.setCapturing(false);
      await session.refresh();
      final event = session.events.single;
      expect(event.actorId, 'atlas');
      expect(event.actorName, 'Atlas');
      expect(event.timestamp.millisecondsSinceEpoch, 1791756000500);
      expect(event.text, '**Evidence**');
    },
  );

  test(
    'lost group-send acknowledgement retries the same frozen id and text exactly once',
    () async {
      final fixture = BotsFixture()..sendLost = true;
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      final session = BotGroupSession(
        fixture.repository,
        group,
        reads: BotGroupReadState(),
        preferences: groupPreferences,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),
      );
      addTearDown(session.dispose);
      expect(await session.send('Hello @bot_atlas'), false);
      expect(await session.send('A different message'), false);
      expect(await session.send('Hello @bot_atlas'), true);
      final sends = fixture.commands
          .where((command) => command.$2 == 'groups.send')
          .toList();
      expect(sends.length, 2);
      expect(sends.first.$3, sends.last.$3);
      expect(sends.first.$3['payload'], {
        'text': 'Hello @bot_atlas',
        'thread_id': sends.first.$3['event_id'],
      });
      expect(fixture.events.length, 1);
    },
  );
  test(
    'readable group names keep canonical routing and frozen retries',
    () async {
      final fixture = BotsFixture()..sendLost = true;
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      final session = BotGroupSession(
        fixture.repository,
        group,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),

        reads: BotGroupReadState(),
        preferences: groupPreferences,
      );
      addTearDown(session.dispose);
      final choice = session
          .completeMentions(MentionQuery.at('@atl', 4)!)
          .items
          .single;
      expect(choice.reference.token, '@Atlas');
      expect(choice.reference.target, 'atlas');
      const authored = 'Please ask (@Atlas), then report.';
      session.editMentions(authored, selected: choice.reference);
      expect(await session.send(authored), isFalse);
      expect(session.pendingText, authored);
      (fixture.room['members'] as List).removeAt(0);
      expect(await session.send(authored), isTrue);
      final sends = fixture.commands
          .where((call) => call.$2 == 'groups.send')
          .toList();
      expect(sends, hasLength(2));
      expect(sends.first.$3, sends.last.$3);
      expect(
        sends.first.$3['payload']['text'],
        'Please ask (@bot_atlas), then report.',
      );
    },
  );

  test(
    'readable multiword and duplicate room names preserve selected identities',
    () async {
      final fixture = BotsFixture();
      final members = fixture.room['members'] as List;
      members[0]['display_name'] = 'Client Work';
      members[1]['display_name'] = 'Client Work';
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      final session = BotGroupSession(
        fixture.repository,
        group,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),

        reads: BotGroupReadState(),
        preferences: groupPreferences,
      );
      addTearDown(session.dispose);
      const typed = '@`Client Wo';
      final choices = session
          .completeMentions(MentionQuery.at(typed, typed.length)!)
          .items;
      expect(choices.map((c) => c.reference.token), [
        '@`Client Work (bot_atlas)`',
        '@`Client Work (bot_mira)`',
      ]);
      final first = choices.first.reference, second = choices.last.reference;
      final text = 'Ask ${first.token}, then ${second.token}.';
      session.editMentions(text, selected: first);
      session.editMentions(text, selected: second);
      expect(await session.send(text), isTrue);
      expect(
        fixture.commands
            .lastWhere((call) => call.$2 == 'groups.send')
            .$3['payload']['text'],
        'Ask @bot_atlas, then @bot_mira .',
      );
    },
  );

  test('qualified display names cannot retarget an existing claim', () async {
    final fixture = BotsFixture();
    final members = fixture.room['members'] as List;
    members[0]['display_name'] = 'Foo';
    members[1]['display_name'] = 'Foo (bot_atlas)';
    members.add({
      'member_id': 'forge',
      'profile': 'forge',
      'handle': 'bot_forge',
      'display_name': 'Foo',
    });
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).first;
    final session = BotGroupSession(
      fixture.repository,
      group,
      groupMessages: null,
      appearances: FixedGroupAppearances(const []),

      reads: BotGroupReadState(),
      preferences: groupPreferences,
    );
    addTearDown(session.dispose);
    final query = MentionQuery.at('@foo', 4)!;
    final old = session
        .completeMentions(query)
        .items
        .singleWhere((candidate) => candidate.reference.target == 'mira')
        .reference;
    session.editMentions('Ask ${old.token}', selected: old);
    final next = session
        .completeMentions(query)
        .items
        .singleWhere((candidate) => candidate.reference.target == 'atlas')
        .reference;
    expect(next.token, isNot(old.token));
    final text = 'Ask ${old.token} then ${next.token}.';
    session.editMentions(text, selected: next);
    expect(await session.send(text), isTrue);
    expect(
      fixture.commands
          .lastWhere((call) => call.$2 == 'groups.send')
          .$3['payload']['text'],
      'Ask @bot_mira then @bot_atlas .',
    );
  });

  test(
    'group picker uses frozen members; removed identity pauses before stock send',
    () async {
      final fixture = BotsFixture();
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      final session = BotGroupSession(
        fixture.repository,
        group,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),

        reads: BotGroupReadState(),
        preferences: groupPreferences,
      );
      addTearDown(session.dispose);
      final choices = session.completeMentions(MentionQuery.at('@', 1)!).items;
      expect(choices.map((c) => c.reference.token), [
        '@Atlas',
        '@Mira',
        '@everyone',
      ]);
      final ref = choices.first.reference;
      session.editMentions('Hello ${ref.token}', selected: ref);
      (fixture.room['members'] as List).removeAt(0);
      expect(await session.send('Hello ${ref.token}'), isFalse);
      expect(session.error, contains('Correct the mention'));
      expect(fixture.commands.where((c) => c.$2 == 'groups.send'), isEmpty);
      final everyone = choices.last.reference;
      session.editMentions('Hello @everyone', selected: everyone);
      expect(await session.send('Hello @everyone'), isTrue);
      expect(
        fixture.commands
            .lastWhere((c) => c.$2 == 'groups.send')
            .$3['payload']['text'],
        'Hello @everyone',
      );
    },
  );
  test('a member id named everyone is still a selected identity', () async {
    final fixture = BotsFixture();
    (fixture.room['members'] as List).first['member_id'] = 'everyone';
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).first;
    final session = BotGroupSession(
      fixture.repository,
      group,
      groupMessages: null,
      appearances: FixedGroupAppearances(const []),

      reads: BotGroupReadState(),
      preferences: groupPreferences,
    );
    addTearDown(session.dispose);
    final ref = session
        .completeMentions(MentionQuery.at('@bot_atlas', 10)!)
        .items
        .single
        .reference;
    session.editMentions('Hello ${ref.token}', selected: ref);
    (fixture.room['members'] as List).removeAt(0);
    expect(await session.send('Hello ${ref.token}'), isFalse);
    expect(fixture.commands.where((c) => c.$2 == 'groups.send'), isEmpty);
  });
  test(
    'route retirement revokes dispatch after asynchronous connection preparation',
    () async {
      final fixture = BotsFixture();
      final gate = Completer<void>();
      fixture.beforeCommand = () => gate.future;
      final session = BotsSession((_) async => [fixture.repository]);
      await session.refresh();
      final pinned = session.setPinned(
        session.state.bots.first,
        canUse: () => true,
      );
      session.dispose();
      gate.complete();
      expect(await pinned, false);
      expect(fixture.commands, isEmpty);
    },
  );
  test(
    'unconfirmed non-idempotent profile creation is never blindly repeated',
    () async {
      final fixture = BotsFixture();
      fixture.commandHook = (_, method, _) async {
        if (method == 'profiles.create') throw StateError('Lost');
        return null;
      };
      final session = BotsSession((_) async => [fixture.repository]);
      addTearDown(session.dispose);
      await session.refresh();
      expect(
        await session.createBot('instance-1', 'new_bot', canUse: () => true),
        false,
      );
      expect(
        await session.createBot('instance-1', 'new_bot', canUse: () => true),
        false,
      );
      expect(
        fixture.commands.where((c) => c.$2 == 'profiles.create').length,
        1,
      );
      expect(session.state.errors.join(), contains('unconfirmed'));
    },
  );
  test(
    'captured group approval sends only the permitted one-time scope',
    () async {
      final fixture = BotsFixture();
      fixture.pending.add({
        'kind': 'approval',
        'task_id': 'task-1',
        'member_id': 'atlas',
        'request_id': 'approval-1',
        'execution_generation': 2,
        'approval': {
          'command': 'git status',
          'description': 'Inspect the project',
          'choices': ['once', 'deny'],
        },
      });
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      final runtime = await fixture.repository.groupRuntime(group);
      final action = runtime.runtime.actions.single;
      await expectLater(
        fixture.repository.resolveGroup(
          group,
          action,
          'always',
          () => true,
          () {},
        ),
        throwsArgumentError,
      );
      await fixture.repository.resolveGroup(
        group,
        action,
        'once',
        () => true,
        () {},
      );
      expect(fixture.commands.single.$3, {
        'room_id': 'room-1',
        'task_id': 'task-1',
        'member_id': 'atlas',
        'request_id': 'approval-1',
        'execution_generation': 2,
        'choice': 'once',
      });
    },
  );
  test('group creation rejects mixed instances before any dispatch', () async {
    final fixture = BotsFixture();
    final other = BotsRepository(
      groupObservations: GroupObservations(
        WorkspaceScope(
          connectionId: 'other',
          connectionIdentity: 'other',
          profileName: 'default',
        ),
      ),
      scope: WorkspaceScope(
        connectionId: 'other',
        connectionIdentity: 'other',
        profileName: 'default',
      ),
      instance: 'Other',
      read: fixture.read,

      command: fixture.command,
      ownership: fixture.ownership,
    );
    final local = (await fixture.repository.bots()).first;
    final remote = (await other.bots()).last;
    await expectLater(
      fixture.repository.createGroup(
        'new-room',
        'Team',
        [local, remote],
        () => true,
        () {},
      ),
      throwsStateError,
    );
    expect(fixture.commands, isEmpty);
  });
  testWidgets(
    'reselecting the displayed shape saves an explicit shared choice',
    (tester) async {
      final fixture = BotsFixture();
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      expect(edit.bot.metadata['imageKind'], isNull);
      edit.change(shape: edit.shape);
      await tester.pump(const Duration(milliseconds: 500));
      expect(edit.bot.metadata['imageKind'], 'shape');
      expect(edit.bot.metadata['shape'], edit.shape);
      expect(edit.dirty, false);
      expect(fixture.commands.single.$2, 'profiles.configure');
    },
  );
  testWidgets('an in-flight save cannot acknowledge a later shape selection', (
    tester,
  ) async {
    final fixture = BotsFixture();
    final gate = Completer<void>();
    fixture.beforeCommand = () => gate.future;
    final edit = BotProfileEditSession(
      fixture.repository,
      (await fixture.repository.bots()).first,

      validateImage: (bot) async =>
          (await fixture.repository.readAvatar(bot)).bytes,
    );
    addTearDown(edit.dispose);
    edit.change(shape: edit.shape);
    final saved = edit.flush();
    await tester.pump();
    edit.change(shape: 'triangle');
    gate.complete();
    await tester.pump();
    expect(await saved, true);
    expect(fixture.commands.length, 2);
    expect(edit.bot.metadata['shape'], 'triangle');
    expect(edit.bot.metadata['imageKind'], 'shape');
    expect(edit.dirty, false);
  });
  testWidgets('selecting a shape clears an asset even when its read failed', (
    tester,
  ) async {
    final fixture = BotsFixture();
    fixture.profiles.first['has_avatar'] = true;
    final bot = (await fixture.repository.bots()).first;
    final edit = BotProfileEditSession(
      fixture.repository,
      bot,
      validateImage: (bot) async =>
          (await fixture.repository.readAvatar(bot)).bytes,
    );
    addTearDown(edit.dispose);
    expect(edit.image, isNull);
    edit.change(shape: edit.shape);
    expect(await edit.flush(), true);
    expect(edit.bot.hasAvatar, false);
    expect(edit.bot.metadata['imageKind'], 'shape');
    expect(fixture.commands.last.$2, 'profiles.set_asset');
    expect(fixture.commands.last.$3['clear'], true);
  });
  testWidgets(
    'reload retains an explicit shape choice across a desktop conflict',
    (tester) async {
      final fixture = BotsFixture()..conflict = true;
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      final chosen = edit.shape;
      edit.change(shape: chosen);
      await tester.pump(const Duration(milliseconds: 500));
      expect(edit.conflicted, true);
      fixture.conflict = false;
      fixture.profiles.first['ui_meta']['hermes-bots']['shape'] = 'triangle';
      fixture.profiles.first['ui_meta']['hermes-bots']['imageKind'] = 'photo';
      fixture.profiles.first['has_avatar'] = true;
      fixture.profiles.first['ui_meta_revisions']['hermes-bots'] = 3;
      fixture.readHook = (_, method, _) async => method == 'profiles.get_asset'
          ? {'found': true, 'data': _avatarPng}
          : null;
      await edit.reload();
      expect(edit.shape, chosen);
      expect(edit.image, isNull);
      expect(edit.needsReview, true);
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.commands.length, 1);
      expect(await edit.flush(), true);
      expect(edit.bot.metadata['shape'], chosen);
      expect(edit.bot.metadata['imageKind'], 'shape');
      expect(edit.bot.hasAvatar, false);
    },
  );
  testWidgets(
    'appearance autosave coalesces typing and drains edits made during a write',
    (tester) async {
      final fixture = BotsFixture();
      final gate = Completer<void>();
      fixture.beforeCommand = () => gate.future;
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      edit.change(title: 'First name');
      await tester.pump(const Duration(milliseconds: 300));
      edit.change(title: 'Second name', color: '#123456');
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.commands, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(edit.saving, true);
      edit.change(title: 'Latest name', color: '#654321');
      expect(edit.title, 'Latest name');
      gate.complete();
      await tester.pump();
      expect(await edit.flush(), true);
      expect(fixture.commands.length, 2);
      expect(
        fixture.commands.first.$3['ui_meta']['hermes-bots']['title'],
        'Second name',
      );
      expect(
        fixture.commands.last.$3['ui_meta']['hermes-bots']['title'],
        'Latest name',
      );
      expect(
        fixture.commands.last.$3['ui_meta']['hermes-bots']['color'],
        '#654321',
      );
      expect(edit.dirty, false);
      expect(edit.error, isNull);
    },
  );
  testWidgets(
    'appearance autosave never writes an empty name or a retired draft',
    (tester) async {
      final fixture = BotsFixture();
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      edit.change(title: '');
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.commands, isEmpty);
      edit.change(title: 'Valid name');
      edit.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.commands, isEmpty);
    },
  );
  testWidgets('a generated avatar stays visible after automatic persistence', (
    tester,
  ) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=';
    final fixture = BotsFixture();
    fixture.commandHook = (_, method, _) async => method == 'image.generate'
        ? {'success': true, 'image_data': png}
        : null;
    final edit = BotProfileEditSession(
      fixture.repository,
      (await fixture.repository.bots()).first,

      validateImage: (bot) async =>
          (await fixture.repository.readAvatar(bot)).bytes,
    );
    addTearDown(edit.dispose);
    await edit.generate('An owl');
    await tester.pump(const Duration(milliseconds: 500));
    expect(edit.dirty, false);
    expect(edit.image, orderedEquals(base64Decode(png)));
    expect(
      fixture.commands.where((c) => c.$2 == 'profiles.set_asset').length,
      1,
    );
  });
  testWidgets(
    'conflicted autosave waits for reload and review before retrying',
    (tester) async {
      final fixture = BotsFixture()..conflict = true;
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      edit.change(title: 'My edit');
      await tester.pump(const Duration(milliseconds: 500));
      expect(edit.conflicted, true);
      fixture.conflict = false;
      fixture.profiles.first['ui_meta']['hermes-bots']['title'] =
          'Desktop edit';
      fixture.profiles.first['ui_meta_revisions']['hermes-bots'] = 3;
      await edit.reload();
      expect(edit.title, 'My edit');
      expect(edit.error, isNull);
      expect(edit.needsReview, true);
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.commands.length, 1);
      expect(await edit.flush(), true);
      expect(fixture.commands.length, 2);
      expect(edit.needsReview, false);
    },
  );
  testWidgets(
    'failed appearance reload keeps the draft without an automatic write',
    (tester) async {
      final fixture = BotsFixture();
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      edit.change(title: 'Unsaved name');
      fixture.readHook = (_, method, _) async {
        if (method == 'profiles.list') throw StateError('Disconnected');
        return null;
      };
      await edit.reload();
      expect(edit.error, 'Saved appearance could not be reloaded.');
      expect(edit.title, 'Unsaved name');
      expect(edit.dirty, true);
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.commands, isEmpty);
    },
  );
  test(
    'successful appearance reload is silent and preserves edited fields',
    () async {
      final fixture = BotsFixture();
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      edit.change(color: '#a58cdf');
      fixture.profiles.first['ui_meta']['hermes-bots']['title'] =
          'Desktop title';
      await edit.reload();
      expect(edit.title, 'Desktop title');
      expect(edit.color, '#a58cdf');
      expect(edit.error, isNull);
      expect(edit.conflicted, false);
      expect(fixture.commands, isEmpty);
    },
  );
  test(
    'color-only edits do not overwrite an untouched title after CAS reload',
    () async {
      final fixture = BotsFixture();
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      edit.change(color: '#a58cdf');
      fixture.profiles.first['ui_meta']['hermes-bots']['title'] =
          'Desktop title';
      fixture.profiles.first['ui_meta_revisions']['hermes-bots'] = 3;
      expect(await edit.flush(), false);
      await edit.reload();
      expect(edit.title, 'Desktop title');
      expect(edit.color, '#a58cdf');
      expect(await edit.flush(), true);
      expect(
        fixture.commands.last.$3['ui_meta']['hermes-bots']['title'],
        'Desktop title',
      );
    },
  );
  test(
    'partial appearance saves do not repeat acknowledged metadata',
    () async {
      final fixture = BotsFixture();
      var first = true;
      fixture.commandHook = (_, method, _) async {
        if (method == 'profiles.set_asset' && first) {
          first = false;
          throw StateError('Lost acknowledgement');
        }
        return null;
      };
      final edit = BotProfileEditSession(
        fixture.repository,
        (await fixture.repository.bots()).first,

        validateImage: (bot) async =>
            (await fixture.repository.readAvatar(bot)).bytes,
      );
      addTearDown(edit.dispose);
      edit.change(title: 'Updated title');
      edit.removeImage();
      expect(await edit.flush(), false);
      expect(edit.dirty, true);
      expect(await edit.flush(), true);
      expect(
        fixture.commands.where((c) => c.$2 == 'profiles.configure').length,
        1,
      );
      expect(
        fixture.commands.where((c) => c.$2 == 'profiles.set_asset').length,
        2,
      );
    },
  );
  test(
    'colliding saved IDs never attribute another profile’s live status',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['canonical_session']['id'] = 'mira-chat';
      final roster = await fixture.repository.bots();
      final presence = (await fixture.repository.presence(roster)).values;
      expect(presence[roster.first.id], BotPresence.unknown);
      expect(presence[roster[1].id], BotPresence.unknown);
      expect(presence[roster.last.id], BotPresence.working);
    },
  );
  test(
    'leaving an input route revokes dispatch even while the roster remains mounted',
    () async {
      final fixture = BotsFixture();
      final gate = Completer<void>();
      fixture.beforeCommand = () => gate.future;
      var active = true;
      final session = BotsSession((_) async => [fixture.repository]);
      addTearDown(session.dispose);
      await session.refresh();
      final operation = session.setPinned(
        session.state.bots.first,
        canUse: () => active,
      );
      active = false;
      gate.complete();
      expect(await operation, false);
      expect(fixture.commands, isEmpty);
    },
  );
}
