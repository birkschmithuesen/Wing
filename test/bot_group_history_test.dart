import 'package:wing/core/models/transcript_position.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/group_observations.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/services/bot_group_history_session.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'support/administration_fixture.dart';
import 'support/bots_fixture.dart';

Map<String, dynamic> _worker(String id) => {
  'id': '$id-root',
  'resolved_id': '$id-tip',
  'title': 'Group: room-1',
  'source': 'bot_room',
};

Map<String, dynamic> _message(int id, String text) => {
  'id': id,
  'role': 'assistant',
  'content': text,
  'timestamp': 1791756000.0,
};

class _WorkerReplay {
  _WorkerReplay(BotsFixture fixture) {
    fixture.readHook = (_, method, params) async => switch (method) {
      'session.active_list' => {
        'sessions': [
          if (present)
            {
              'id': 'atlas-live',
              'session_key': 'atlas-tip',
              'title': 'Group: room-1',
              'status': status,
            },
        ],
      },
      'session.resume' => BotsFixture.passiveSnapshot(
        params,
        epoch: epoch,
        sequence: events.length,
      ),
      'session.events.since' => {
        'events': (truncated ? <Map<String, dynamic>>[] : events)
            .where((e) => (e['seq'] as int) > (params['last_sequence'] as int))
            .toList(),
        'latest_seq': events.length,
        'truncated': truncated,
        'snapshot_required': truncated,
        'replay_epoch': epoch,
        'open_requests': openRequests,
      },
      _ => null,
    };
  }
  bool present = true, truncated = false;
  String epoch = 'recovery-test';
  String status = 'working';
  final events = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> openRequests = [];
  void add(String type, [Map<String, dynamic> payload = const {}]) =>
      events.add({
        'seq': events.length + 1,
        'session_id': 'atlas-live',
        'type': type,
        'payload': stockWorkerReply(events, type, payload),
      });
}

void main() {
  late BotsFixture fixture;
  late BotGroup group;
  late BotGroupHistorySession session;
  setUp(() async {
    fixture = BotsFixture();
    group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).single;
    session = BotGroupHistorySession(fixture.repository, group);
    fixture.workerRows['atlas'] = [_worker('atlas')];
    fixture.workerRows['mira'] = [_worker('mira')];
  });
  tearDown(() => session.dispose());

  test('group worker uses shared clarification retirement on replay', () async {
    final replay = _WorkerReplay(fixture);
    replay.add('message.start');
    final question = {
      'id': 'worker-question',
      'method': 'clarify',
      'params': {'session_id': 'atlas-live', 'question': 'Continue?'},
    };
    replay.openRequests = [question];
    await session.select(group.members.first);
    await session.refreshLive(discover: true);
    expect(session.runtime.pendingQuestion?.requestId, 'worker-question');
    replay.openRequests = [];
    await session.refreshLive(discover: true);
    expect(session.runtime.pendingQuestion, isNull);
    replay.openRequests = [question];
    await session.refreshLive(discover: true);
    expect(session.runtime.pendingQuestion, isNull);
    expect(fixture.commands, isEmpty);
  });

  test(
    'quiet history refresh bridges a new tool tail to retained messages',
    () async {
      fixture.workerMessages['atlas'] = [
        for (var id = 1; id <= 20; id++) _message(id, 'Retained $id'),
      ];
      await session.select(group.members.first);
      fixture.workerMessages['atlas']!.addAll([
        for (var id = 21; id <= 60; id++)
          {'id': id, 'role': 'tool', 'content': 'New receipt $id'},
      ]);
      await session.refreshLive(discover: true);
      expect(
        session.reader.messages.where((row) => row['role'] == 'assistant'),
        hasLength(20),
      );
      expect(session.reader.messages.last['id'], 60);
      expect(session.reader.nextHistoryOffset, 60);
    },
  );

  test(
    'quiet overlap retains older prefix and advances its paging cursor',
    () async {
      fixture.workerMessages['atlas'] = [
        for (var id = 1; id <= 60; id++) _message(id, 'Answer $id'),
      ];
      await session.select(group.members.first);
      await session.loadOlder();
      expect(session.reader.messages.first['id'], 21);
      fixture.workerMessages['atlas']!.addAll([
        for (var id = 61; id <= 65; id++) _message(id, 'New answer $id'),
      ]);
      await session.refreshLive(discover: true);
      expect(session.reader.messages.first['id'], 21);
      expect(session.reader.nextHistoryOffset, 45);
      await session.loadOlder();
      expect(fixture.historyReads.last.$3, 45);
      expect(session.reader.messages.first['id'], 1);
      expect(session.reader.messages.last['id'], 65);
    },
  );

  test(
    'disappeared worker keeps partial answer until saved recovery succeeds',
    () async {
      final replay = _WorkerReplay(fixture)
        ..add('message.start')
        ..add('message.delta', {'text': 'Visible partial answer'});
      await session.select(group.members.first);
      await session.refreshLive();
      replay.present = false;
      fixture.historyHook = (_, _, _) async =>
          throw StateError('Offline history');
      await session.refreshLive();
      expect(session.reader.streaming, 'Visible partial answer');
      expect(session.reader.historyError, isNotNull);
      expect(session.runtime.executionActive, isFalse);
      expect(session.liveAnswering, isTrue);
      fixture.historyHook = null;
      fixture.workerMessages['atlas'] = [_message(1, 'Saved completed answer')];
      await session.refreshLive();
      expect(session.reader.streaming, isEmpty);
      expect(
        session.reader.messages.single['content'],
        'Saved completed answer',
      );
      expect(session.reader.historyError, isNull);
      expect(session.liveAnswering, isFalse);
    },
  );

  test(
    'idle worker retries a failed terminal history reconciliation',
    () async {
      final replay = _WorkerReplay(fixture)
        ..add('message.start')
        ..add('message.delta', {'text': 'Completed answer'});
      await session.select(group.members.first);
      await session.refreshLive();
      replay
        ..status = 'idle'
        ..add('message.complete', {'text': 'Completed answer'});
      fixture.historyHook = (_, _, _) async =>
          throw StateError('Offline history');
      await session.refreshLive();
      expect(session.reader.historyError, isNotNull);
      final failedReads = fixture.historyReads.length;
      fixture.historyHook = null;
      fixture.workerMessages['atlas'] = [_message(1, 'Completed answer')];
      await session.refreshLive();
      expect(fixture.historyReads.length, greaterThan(failedReads));
      expect(session.reader.historyError, isNull);
      expect(session.reader.messages.single['id'], 1);
    },
  );

  test(
    'terminal reconciliation waits for initial progressive backfill',
    () async {
      final older = Completer<ProfileHistoryPage>();
      addTearDown(() {
        if (!older.isCompleted) older.completeError(StateError('Retired'));
      });
      var newestReads = 0;
      fixture.historyHook = (_, id, offset) async {
        if (offset > 0) return older.future;
        newestReads++;
        return ProfileHistoryPage(
          id,
          [
            _message(101, 'Existing latest answer'),
            for (var id = 102; id <= 120; id++)
              {'id': id, 'role': 'tool', 'content': 'Receipt'},
          ],
          0,
          20,
        );
      };
      final replay = _WorkerReplay(fixture)
        ..add('message.start')
        ..add('message.delta', {'text': 'New live answer'});
      final selecting = session.select(group.members.first);
      await Future<void>.delayed(Duration.zero);
      await session.refreshLive();
      replay
        ..status = 'idle'
        ..add('message.complete', {'text': 'New live answer'});
      final reconciling = session.refreshLive();
      await Future<void>.delayed(Duration.zero);
      expect(
        newestReads,
        1,
        reason: 'Do not cancel or overtake held initial backfill',
      );
      older.complete(
        ProfileHistoryPage(
          'atlas-tip',
          [for (var id = 1; id <= 19; id++) _message(id, 'Older answer')],
          20,
          20,
        ),
      );
      await selecting;
      await reconciling;
      expect(session.reader.messages.any((row) => row['id'] == 1), isTrue);
      expect(session.reader.historyLoading, isFalse);
      expect(newestReads, 2);
    },
  );

  test(
    'saved selection does not await or start initial live hydration',
    () async {
      var activeReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'session.active_list') activeReads++;
        return null;
      };
      fixture.workerMessages['atlas'] = [_message(1, 'Saved message first')];
      await session.select(group.members.first);
      expect(session.reader.messages.single['content'], 'Saved message first');
      expect(session.reader.historyLoading, isFalse);
      expect(activeReads, 0);
      await session.refreshLive();
      expect(activeReads, 1);
    },
  );

  test(
    'first history page is readable while older message backfill is held',
    () async {
      final older = Completer<ProfileHistoryPage>();
      addTearDown(() {
        if (!older.isCompleted) older.completeError(StateError('Retired read'));
      });
      fixture.historyHook = (_, id, offset) async {
        if (offset > 0) return older.future;
        return ProfileHistoryPage(
          id,
          [
            _message(101, 'Read this saved answer immediately'),
            for (var id = 102; id <= 120; id++)
              {'id': id, 'role': 'tool', 'content': 'Saved tool receipt'},
          ],
          0,
          20,
        );
      };
      final selected = session.select(group.members.first);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.historyReads.map((r) => r.$3), [0, 20]);
      expect(session.historyAvailable, isTrue);
      expect(
        session.reader.messages.first['content'],
        'Read this saved answer immediately',
      );
      expect(session.reader.historyLoading, isTrue);
      older.complete(
        ProfileHistoryPage(
          'atlas-tip',
          [for (var id = 1; id <= 19; id++) _message(id, 'Earlier answer')],
          20,
          20,
        ),
      );
      await selected;
      expect(session.reader.messages, hasLength(39));
      expect(session.reader.historyLoading, isFalse);
    },
  );

  test(
    'live tasks outrank older saved receipts arriving during backfill',
    () async {
      final older = Completer<ProfileHistoryPage>();
      addTearDown(() {
        if (!older.isCompleted) older.completeError(StateError('Retired read'));
      });
      fixture.historyHook = (_, id, offset) async => offset == 0
          ? ProfileHistoryPage(
              id,
              [
                _message(101, 'Readable conversation'),
                for (var id = 102; id <= 120; id++)
                  {'id': id, 'role': 'tool', 'content': 'Tool receipt'},
              ],
              0,
              20,
            )
          : older.future;
      fixture.readHook = (_, method, params) async => switch (method) {
        'session.active_list' => {
          'sessions': [
            {
              'id': 'atlas-live',
              'session_key': 'atlas-tip',
              'title': 'Group: room-1',
              'status': 'working',
            },
          ],
        },
        'session.resume' => BotsFixture.passiveSnapshot(
          params,
          epoch: 'concurrent-read',
          sequence: 2,
        ),
        'session.events.since' => {
          'replay_epoch': 'concurrent-read',
          'latest_seq': 2,
          'truncated': false,
          'snapshot_required': false,
          'open_requests': [],
          'events': [
            {'seq': 1, 'session_id': 'atlas-live', 'type': 'message.start'},
            {
              'seq': 2,
              'session_id': 'atlas-live',
              'type': 'todo.updated',
              'payload': {
                'revision': 5,
                'todos': [
                  {
                    'id': 'new',
                    'content': 'Current live task',
                    'status': 'in_progress',
                  },
                ],
              },
            },
          ],
        },
        _ => null,
      };
      final selecting = session.select(group.members.first);
      await Future<void>.delayed(Duration.zero);
      expect(session.historyAvailable, isTrue);
      await session.refreshLive();
      expect(session.todos.single.content, 'Current live task');
      older.complete(
        ProfileHistoryPage(
          'atlas-tip',
          [
            {
              'id': 1,
              'role': 'tool',
              'tool_name': 'todo_list',
              'content': {
                'todos': [
                  {
                    'id': 'old',
                    'content': 'Old saved task',
                    'status': 'pending',
                  },
                ],
              },
            },
          ],
          20,
          20,
        ),
      );
      await selecting;
      expect(session.todos.single.content, 'Current live task');
    },
  );

  test('fresh working history includes the latest 20 conversation messages '
      'behind a tool-only tail', () async {
    fixture.workerMessages['atlas'] = [
      for (var id = 1; id <= 25; id++) _message(id, 'Saved answer $id'),
      for (var id = 26; id <= 65; id++)
        id.isEven
            ? {'id': id, 'role': 'assistant', 'content': ''}
            : {
                'id': id,
                'role': 'tool',
                'content': 'Tool output $id',
                'tool_name': 'terminal',
              },
    ];
    await session.select(group.members.first);
    await session.refreshLive();
    final answers = session.reader.messages.where(
      (row) => row['role'] == 'assistant' && row['content'] != '',
    );
    expect(answers, hasLength(20));
    expect(answers.first['content'], 'Saved answer 6');
    expect(answers.last['content'], 'Saved answer 25');
    expect(session.reader.messages.last['id'], 65);
    expect(fixture.historyReads.map((read) => read.$3), [0, 20, 40]);
    expect(session.reader.nextHistoryOffset, 60);
    expect(fixture.commands, isEmpty);
  });

  test(
    'short history exhausts tool and hidden pages to find its messages',
    () async {
      fixture.workerMessages['atlas'] = [
        _message(1, 'Only saved answer'),
        for (var id = 2; id <= 42; id++)
          {..._message(id, 'Hidden carrier'), 'display_kind': 'hidden'},
      ];
      await session.select(group.members.first);
      await session.refreshLive();
      expect(session.reader.historyError, isNull);
      expect(session.reader.messages.first['content'], 'Only saved answer');
      expect(session.reader.nextHistoryOffset, isNull);
      expect(fixture.historyReads.map((read) => read.$3), [0, 20, 40]);
    },
  );

  test(
    'refresh retains its snapshot and loading until message backfill settles',
    () async {
      fixture.workerMessages['atlas'] = [_message(1, 'Retained answer')];
      await session.select(group.members.first);
      await session.refreshLive();
      final held = Completer<ProfileHistoryPage>();
      addTearDown(() {
        if (!held.isCompleted) held.completeError(StateError('Retired read'));
      });
      fixture.historyHook = (_, id, offset) async {
        if (offset == 20) return held.future;
        return ProfileHistoryPage(
          id,
          [
            for (var id = 101; id <= 120; id++)
              {'id': id, 'role': 'tool', 'content': 'New tool output'},
          ],
          offset,
          20,
        );
      };
      final refresh = session.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(session.reader.historyLoading, isTrue);
      expect(session.reader.messages.single['content'], 'Retained answer');
      await session.refresh();
      expect(fixture.historyReads.map((read) => read.$3), [0, 0, 20]);
      held.completeError(StateError('Offline backfill'));
      await refresh;
      expect(session.reader.historyLoading, isFalse);
      expect(session.reader.historyError, isNotNull);
      expect(session.reader.messages.single['content'], 'Retained answer');
      fixture.historyHook = null;
      fixture.workerMessages['atlas'] = [_message(2, 'Recovered answer')];
      await session.refresh();
      expect(session.reader.historyError, isNull);
      expect(session.reader.messages.single['content'], 'Recovered answer');
    },
  );

  test('member switch retires a held continuation page', () async {
    final held = Completer<ProfileHistoryPage>();
    final entered = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.completeError(StateError('Retired'));
    });
    fixture.historyHook = (profile, id, offset) async {
      if (profile == 'mira') {
        return ProfileHistoryPage(id, [_message(1, 'Mira only')], offset, 20);
      }
      if (offset == 20) {
        entered.complete();
        return held.future;
      }
      return ProfileHistoryPage(
        id,
        [
          for (var id = 21; id <= 40; id++)
            {'id': id, 'role': 'tool', 'content': 'Atlas tool output'},
        ],
        offset,
        20,
      );
    };
    final atlas = session.select(group.members.first);
    await entered.future;
    expect(fixture.historyReads.last.$3, 20);
    await session.select(group.members.last);
    await session.refreshLive();
    held.complete(
      ProfileHistoryPage(
        'atlas-tip',
        [for (var id = 1; id <= 20; id++) _message(id, 'Retired Atlas answer')],
        20,
        20,
      ),
    );
    await atlas;
    expect(session.reader.historyLoading, isFalse);
    expect(session.reader.messages.single['content'], 'Mira only');
    expect(session.member?.profile, 'mira');
  });

  test(
    'opening a long worker history reads only a small newest page',
    () async {
      final server = AdministrationFixture();
      server.rpcOverride = (method, params) async => {
        'sessions': [_worker('atlas')],
      };
      int? requestedLimit;
      server.override = (method, path, query, body) async {
        if (path == 'profiles') return {'profiles': fixture.profiles};
        if (path == 'profiles/active') {
          return {'current': 'atlas', 'active': 'atlas'};
        }
        expect(path, 'sessions/atlas-tip/messages');
        requestedLimit = int.parse(query['limit']!);
        return {
          'session_id': 'atlas-tip',
          'messages': [
            for (var id = 1001 - requestedLimit!; id <= 1000; id++)
              _message(id, 'Saved tool result $id ${'output ' * 1000}'),
          ],
          'pagination': {
            'limit': requestedLimit,
            'offset': 0,
            'order': 'latest',
            'returned': requestedLimit,
          },
        };
      };
      final repository = BotsRepository.forServer(
        server.server,
        groupObservations: GroupObservations(
          WorkspaceScope(
            connectionId: server.server.connectionId,
            connectionIdentity: server.server.connectionIdentity,
            profileName: 'default',
          ),
        ),
      );
      final ownedGroup = BotGroup(
        observationComplete: true,
        scope: repository.scope,
        instance: repository.instance,
        id: group.id,
        name: group.name,
        members: group.members,
      );
      final viewer = BotGroupHistorySession(repository, ownedGroup);
      addTearDown(viewer.dispose);
      await viewer.select(ownedGroup.members.first);
      await viewer.refreshLive();
      expect(viewer.reader.historyError, isNull);
      expect(
        requestedLimit,
        20,
        reason: 'Opening should not transfer 100 potentially large tool rows',
      );
      expect(viewer.reader.messages, hasLength(20));
      expect(viewer.reader.messages.last['id'], 1000);
      expect(viewer.reader.nextHistoryOffset, 20);
    },
  );

  test(
    'cold worker replay keeps text before a restamped same-turn start',
    () async {
      final replay = _WorkerReplay(fixture);
      replay.add('message.start', {'turn_id': 'same-turn'});
      replay.add('message.delta', {
        'turn_id': 'same-turn',
        'segment': 0,
        'offset': 0,
        'text': 'Before ',
      });
      replay.add('message.start', {'turn_id': 'same-turn'});
      replay.add('message.delta', {
        'turn_id': 'same-turn',
        'segment': 0,
        'offset': 7,
        'text': 'after',
      });
      await session.select(group.members.first);
      await session.refreshLive();
      expect(session.reader.streaming, 'Before after');
    },
  );

  test(
    'worker replay splits reasoning, tracks work and deduplicates deltas',
    () async {
      var working = true;
      var epoch = 'first';
      final events = <Map<String, dynamic>>[];
      void event(String type, Map<String, dynamic> payload) => events.add({
        'type': type,
        'payload': stockWorkerReply(events, type, payload),
        'session_id': 'atlas-live',
        'seq': events.length + 1,
      });
      event('message.start', {});
      event('reasoning.delta', {'text': 'First reasoning'});
      event('tool.start', {
        'tool_id': 'read-1',
        'name': 'read_file',
        'args': {'path': 'README.md'},
      });
      event('todo.updated', {
        'revision': 1,
        'todos': [
          {'id': '1', 'content': 'Inspect transcript', 'status': 'in_progress'},
        ],
      });
      event('subagent.start', {
        'subagent_id': 'child-1',
        'goal': 'Check events',
        'status': 'running',
      });
      event('reasoning.delta', {'text': 'Second reasoning'});
      fixture.readHook = (profile, method, params) async => switch (method) {
        'session.active_list' => {
          'sessions': [
            {
              'id': 'atlas-live',
              'session_key': 'atlas-tip',
              'title': 'Group: room-1',
              'status': working ? 'working' : 'idle',
            },
          ],
        },
        'session.resume' => BotsFixture.passiveSnapshot(
          params,
          epoch: epoch,
          sequence: events.length,
        ),
        'session.events.since' => {
          'events': events
              .where(
                (e) => (e['seq'] as int) > (params['last_sequence'] as int),
              )
              .toList(),
          'latest_seq': events.length,
          'truncated': false,
          'snapshot_required': false,
          'replay_epoch': epoch,
          'open_requests': [],
        },
        _ => null,
      };
      await session.select(group.members.first);
      await session.refreshLive();
      final reasoning = session.runtime.activityEntries
          .whereType<ChatReasoningEntry>()
          .toList();
      expect(reasoning.map((e) => e.text), [
        'First reasoning',
        'Second reasoning',
      ]);
      expect(reasoning.map((e) => e.running), [false, true]);
      expect(session.todos.single.content, 'Inspect transcript');
      expect(session.subagents.single.goal, 'Check events');
      event('message.delta', {'text': 'Live answer'});
      await session.refreshLive();
      await session.refreshLive();
      expect(session.reader.streaming, 'Live answer');
      expect(
        session.runtime.activityEntries.whereType<ChatReasoningEntry>().every(
          (e) => !e.running,
        ),
        isTrue,
      );
      final detail = session.openSubagent('child-1');
      expect(detail.state.canControl, isFalse);
      expect(detail.supportsTail, isFalse);
      detail.dispose();
      final done = {
        'revision': 2,
        'todos': [
          {'id': '1', 'content': 'Inspect transcript', 'status': 'completed'},
        ],
      };
      event('todo.updated', done);
      await session.refreshLive();
      expect(session.todos.single.content, 'Inspect transcript');
      fixture.workerMessages['atlas'] = [_message(1, 'Live answer')];
      event('message.complete', {'text': 'Live answer'});
      working = false;
      await session.refreshLive();
      expect(session.reader.streaming, isEmpty);
      expect(session.reader.messages.single['content'], 'Live answer');
      expect(session.liveAnswering, isFalse);
      expect(session.todos, isEmpty);
      // Restarted replay sequences must not strand an old watermark.
      events.clear();
      epoch = 'second';
      working = true;
      event('message.start', {});
      event('todo.updated', done);
      event('message.delta', {'text': 'After restart'});
      await session.refreshLive();
      expect(session.reader.streaming, 'After restart');
      expect(session.todos, isEmpty);
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'worker replay retains the next turn after a batched completion',
    () async {
      final events = <Map<String, dynamic>>[];
      void event(String type, Map<String, dynamic> payload) => events.add({
        'type': type,
        'payload': stockWorkerReply(events, type, payload),
        'session_id': 'atlas-live',
        'seq': events.length + 1,
      });
      event('message.start', {});
      event('message.delta', {'text': 'First answer'});
      fixture.readHook = (profile, method, params) async => switch (method) {
        'session.active_list' => {
          'sessions': [
            {
              'id': 'atlas-live',
              'session_key': 'atlas-tip',
              'title': 'Group: room-1',
              'status': 'working',
            },
          ],
        },
        'session.events.since' => {
          'events': events
              .where(
                (e) => (e['seq'] as int) > (params['last_sequence'] as int),
              )
              .toList(),
          'latest_seq': events.length,
          'truncated': false,
          'snapshot_required': false,
          'replay_epoch': 'test',
        },
        _ => null,
      };
      await session.select(group.members.first);
      await session.refreshLive();
      event('message.complete', {'text': 'First answer'});
      event('message.start', {});
      event('message.delta', {'text': 'Second answer'});
      await session.refreshLive();
      expect(session.reader.streaming, 'Second answer');
      expect(session.liveAnswering, isTrue);
    },
  );

  test(
    'manual refresh stays pending through replay and reports read failure',
    () async {
      final held = Completer<Map<String, dynamic>>();
      var hold = false;
      fixture.readHook = (profile, method, params) async => switch (method) {
        'session.active_list' => {
          'sessions': [
            {
              'id': 'atlas-live',
              'session_key': 'atlas-tip',
              'title': 'Group: room-1',
              'status': 'working',
            },
          ],
        },
        'session.events.since' when hold => held.future,
        'session.events.since' => {
          'events': [],
          'latest_seq': 0,
          'truncated': false,
          'snapshot_required': false,
          'replay_epoch': 'test',
        },
        _ => null,
      };
      await session.select(group.members.first);
      await session.refreshLive();
      hold = true;
      final refreshing = session.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(session.reader.historyLoading, isTrue);
      held.completeError(StateError('Offline replay'));
      await refreshing;
      expect(session.reader.historyLoading, isFalse);
      expect(session.liveError, isNotNull);
      expect(session.liveAnswering, isTrue);
      expect(fixture.commands, isEmpty);
    },
  );

  for (final retire in ['member switch', 'disposal']) {
    test('late worker replay cannot publish after $retire', () async {
      final held = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      fixture.readHook = (profile, method, params) async {
        if (method == 'session.active_list') {
          return {
            'sessions': [
              if (profile == 'atlas')
                {
                  'id': 'atlas-live',
                  'session_key': 'atlas-tip',
                  'title': 'Group: room-1',
                  'status': 'working',
                },
            ],
          };
        }
        if (method == 'session.events.since') {
          started.complete();
          return held.future;
        }
        return null;
      };
      addTearDown(() {
        if (!held.isCompleted) held.complete({'events': []});
      });
      await session.select(group.members.first);
      final retired = session;
      final replay = retired.refreshLive();
      await started.future;
      if (retire == 'member switch') {
        await session.select(group.members.last);
      } else {
        session.dispose();
        session = BotGroupHistorySession(fixture.repository, group);
      }
      final before = retired.reader.streaming;
      var latePublications = 0;
      if (retire == 'member switch') {
        retired.addListener(() => latePublications++);
      }
      held.complete({
        'events': [
          {
            'type': 'message.delta',
            'payload': {'text': 'Wrong bot'},
            'session_id': 'atlas-live',
            'seq': 1,
          },
        ],
        'latest_seq': 1,
        'truncated': false,
        'snapshot_required': false,
        'replay_epoch': 'first',
      });
      await replay;
      expect(retired.reader.streaming, before);
      expect(session.reader.streaming, isEmpty);
      if (retire == 'member switch') expect(session.member!.profile, 'mira');
      expect(latePublications, 0);
      expect(fixture.commands, isEmpty);
    });
  }

  test(
    'worker truncation refreshes saved evidence and continues after its watermark',
    () async {
      final replay = _WorkerReplay(fixture);
      replay.add('message.start');
      replay.add('message.delta', {'text': 'Lost live range'});
      replay.truncated = true;
      await session.select(group.members.first);
      await session.refreshLive();
      expect(session.reader.streaming, isEmpty);
      expect(
        session.liveError,
        contains('Earlier live activity is unavailable'),
      );
      replay.truncated = false;
      replay.add('message.start');
      replay.add('message.delta', {'text': 'New work after the gap'});
      await session.refreshLive();
      expect(session.reader.streaming, 'New work after the gap');
      expect(fixture.commands, isEmpty);
    },
  );

  test('working history receives the active worker answer', () async {
    fixture.readHook = (profile, method, params) async => switch (method) {
      'session.active_list' => {
        'sessions': [
          {
            'id': 'atlas-live',
            'session_key': 'atlas-tip',
            'status': 'working',
            'title': 'Group: room-1',
          },
        ],
      },
      'session.resume' => BotsFixture.passiveSnapshot(
        params,
        epoch: 'worker-test',
        sequence: 2,
      ),
      'session.events.since' => {
        'events': [
          {
            'type': 'message.start',
            'session_id': 'atlas-live',
            'seq': 1,
            'payload': {'turn_id': 'active-worker-turn'},
          },
          {
            'type': 'message.delta',
            'session_id': 'atlas-live',
            'payload': {
              'text': 'Live answer',
              'turn_id': 'active-worker-turn',
              'segment': 0,
              'offset': 0,
            },
            'seq': 2,
          },
        ],
        'latest_seq': 2,
        'truncated': false,
        'snapshot_required': false,
        'replay_epoch': 'worker-test',
      },
      _ => null,
    };
    await session.select(group.members.first);
    await session.refreshLive();
    expect(session.reader.streaming, 'Live answer');
    expect(fixture.commands, isEmpty);
  });

  test(
    'production viewer reads member history and passive live observations',
    () async {
      final server = AdministrationFixture();
      var offline = false;
      server.rpcOverride = (method, params) async {
        expect(params['profile'], 'atlas');
        if (method == 'session.active_list') {
          return {'sessions': <Map<String, dynamic>>[]};
        }
        expect(method, 'session.list');
        expect(params['title'], 'Group: room-1');
        expect(params['include_hidden'], isTrue);
        return {
          'sessions': [_worker('atlas')],
        };
      };
      server.override = (method, path, query, body) async {
        expect(method, 'GET');
        if (path == 'profiles') return {'profiles': fixture.profiles};
        if (path == 'profiles/active') {
          return {'current': 'atlas', 'active': 'atlas'};
        }
        expect(path, 'sessions/atlas-tip/messages');
        expect(query, {
          'profile': 'atlas',
          'limit': '20',
          'offset': '0',
          'order': 'latest',
          'include_compacted': 'true',
          'inline_images': 'false',
        });
        if (offline) throw DashboardSessionNotFound(path);
        return {
          'session_id': 'atlas-tip',
          'messages': [_message(1, 'Production snapshot')],
          'pagination': {
            'limit': 20,
            'offset': 0,
            'order': 'latest',
            'returned': 1,
          },
        };
      };
      final repository = BotsRepository.forServer(
        server.server,
        groupObservations: GroupObservations(
          WorkspaceScope(
            connectionId: (server.server).connectionId,
            connectionIdentity: (server.server).connectionIdentity,
            profileName: 'default',
          ),
        ),
      );
      final ownedGroup = BotGroup(
        observationComplete: true,
        scope: repository.scope,
        instance: repository.instance,
        id: group.id,
        name: group.name,
        members: group.members,
      );
      final reader = BotGroupHistorySession(repository, ownedGroup);
      addTearDown(reader.dispose);
      await reader.select(ownedGroup.members.first);
      await reader.refreshLive();
      expect(reader.reader.historyError, isNull);
      expect(reader.reader.messages.single['content'], 'Production snapshot');
      offline = true;
      await reader.refresh();
      expect(reader.reader.historyError, isNotNull);
      expect(reader.reader.messages.single['content'], 'Production snapshot');
      offline = false;
      await reader.refresh();
      expect(reader.reader.historyError, isNull);
      expect(
        server.rpcRequests.every(
          (read) =>
              read.$1 == 'atlas' &&
              const {'session.list', 'session.active_list'}.contains(read.$2),
        ),
        isTrue,
      );
      expect(server.rpcRequests, contains(('atlas', 'session.active_list')));
      expect(reader.liveError, isNull);
      expect(server.requests, isNotEmpty);
      expect(server.requests.every((read) => read.$1 == 'GET'), isTrue);
    },
  );

  test(
    'exact hidden worker tip, paged history and refresh issue no commands',
    () async {
      final registry = <(String, Map<String, dynamic>)>[];
      fixture.readHook = (profile, method, params) async {
        if (method == 'session.list') registry.add((profile, params));
        return null;
      };
      fixture.workerMessages['atlas'] = [
        for (var id = 1; id <= 102; id++) _message(id, 'Saved $id'),
      ];
      await session.select(group.members.first);
      await session.refreshLive();
      expect(registry.single.$1, 'atlas');
      expect(registry.single.$2, {
        'title': 'Group: room-1',
        'include_hidden': true,
      });
      expect(fixture.historyReads.single, ('atlas', 'atlas-tip', 0));
      expect(session.reader.messages.length, 20);
      for (
        var page = 0;
        page < 6 && session.reader.nextHistoryOffset != null;
        page++
      ) {
        await session.loadOlder();
      }
      expect(session.reader.nextHistoryOffset, isNull);
      expect(session.reader.messages.length, 102);
      expect(fixture.historyReads.map((read) => read.$3), [
        0,
        20,
        40,
        60,
        80,
        100,
      ]);
      expect(session.reader.messages.first['content'], 'Saved 1');
      expect((session.reader.nextHistoryOffset != null), isFalse);
      fixture.workerRows['atlas'] = [_worker('atlas-new')];
      await session.refresh();
      expect(fixture.historyReads.last, ('atlas', 'atlas-new-tip', 0));
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'switching back reuses the member page and its reading position',
    () async {
      fixture.workerMessages['atlas'] = [_message(1, 'Atlas saved')];
      fixture.workerMessages['mira'] = [_message(2, 'Mira saved')];
      await session.select(group.members.first);
      await session.refreshLive();
      final atlasReader = session.reader;
      atlasReader.recordReading(const TranscriptBookmark(messageId: 240));
      await session.select(group.members.last);
      await session.refreshLive();
      final reads = fixture.historyReads.length;
      await session.select(group.members.first);
      await session.refreshLive();
      expect(fixture.historyReads.length, reads);
      expect(session.reader, same(atlasReader));
      expect(session.reader.readingPosition.resume?.messageId, 240);
      fixture.workerMessages['atlas'] = [_message(3, 'Atlas refreshed')];
      await session.refresh();
      expect(session.reader.messages.single['content'], 'Atlas refreshed');
      expect(fixture.historyReads.length, reads + 1);
    },
  );

  test('a warm member retires another member’s held read', () async {
    fixture.workerMessages['atlas'] = [_message(1, 'Atlas saved')];
    await session.select(group.members.first);
    await session.refreshLive();
    final atlasReader = session.reader;
    final held = Completer<ProfileHistoryPage>();
    fixture.historyHook = (_, _, _) => held.future;
    final mira = session.select(group.members.last);
    await Future<void>.delayed(Duration.zero);
    expect(session.reader.historyLoading, isTrue);
    await session.select(group.members.first);
    await session.refreshLive();
    expect(session.reader, same(atlasReader));
    expect(session.reader.historyLoading, isFalse);
    held.complete(
      ProfileHistoryPage('mira-tip', [_message(2, 'Late Mira')], 0, 20),
    );
    await mira;
    expect(session.reader, same(atlasReader));
    expect(session.reader.messages.single['content'], 'Atlas saved');
    fixture.historyHook = null;
    fixture.workerMessages['mira'] = [_message(3, 'Fresh Mira')];
    await session.select(group.members.last);
    await session.refreshLive();
    expect(session.reader.messages.single['content'], 'Fresh Mira');
  });

  test(
    'confirmed empty history is reused while failed selection retries',
    () async {
      fixture.workerRows['atlas'] = [];
      await session.select(group.members.first);
      await session.refreshLive();
      expect(session.historyAvailable, isTrue);
      final empty = session.reader;
      fixture.historyHook = (_, _, _) async => throw StateError('Offline');
      await session.select(group.members.last);
      await session.refreshLive();
      expect(session.reader.historyError, isNotNull);
      await session.select(group.members.first);
      await session.refreshLive();
      expect(session.reader, same(empty));
      expect(session.reader.historyError, isNull);
      fixture.historyHook = null;
      fixture.workerMessages['mira'] = [_message(1, 'Recovered Mira')];
      await session.select(group.members.last);
      await session.refreshLive();
      expect(session.reader.messages.single['content'], 'Recovered Mira');
      expect(fixture.historyReads, hasLength(2));
    },
  );

  test(
    'absent, wrong-source and contradictory history stay distinct',
    () async {
      expect(session.historyAvailable, isFalse);
      fixture.workerRows['atlas'] = [];
      await session.select(group.members.first);
      await session.refreshLive();
      expect(session.historyAvailable, isTrue);
      expect(session.reader.historyError, isNull);
      expect(fixture.historyReads, isEmpty);
      fixture.workerRows['atlas'] = [
        {..._worker('atlas'), 'source': 'cli'},
      ];
      await session.refresh();
      expect(session.reader.historyError, isNotNull);
      expect(session.historyAvailable, isTrue);
      expect(fixture.historyReads, isEmpty);
      fixture.workerRows['atlas'] = [_worker('atlas')];
      fixture.historyHook = (_, _, _) async => ProfileHistoryPage(
        'another-session',
        [_message(1, 'Private')],
        0,
        100,
      );
      await session.refresh();
      expect(session.reader.historyError, isNotNull);
      expect(session.reader.messages, isEmpty);
      fixture.historyHook = null;
      fixture.workerMessages['atlas'] = [_message(1, 'Recovered')];
      await session.refresh();
      expect(session.reader.historyError, isNull);
      expect(session.reader.messages.single['content'], 'Recovered');
      fixture.historyHook = (_, _, _) async => throw StateError('Offline');
      await session.refresh();
      expect(session.reader.historyError, isNotNull);
      expect(session.reader.messages.single['content'], 'Recovered');
    },
  );

  test(
    'late pages cannot cross bot selection or resurrect a disposed route',
    () async {
      final held = Completer<ProfileHistoryPage>();
      fixture.historyHook = (profile, id, offset) async => profile == 'atlas'
          ? held.future
          : ProfileHistoryPage(id, [_message(2, 'Mira only')], offset, 100);
      final first = session.select(group.members.first);
      await Future<void>.delayed(Duration.zero);
      expect(session.historyAvailable, isFalse);
      final retiredReader = session.reader;
      retiredReader.recordReading(const TranscriptBookmark(messageId: 180));
      await session.select(group.members.last);
      await session.refreshLive();
      expect(session.historyAvailable, isTrue);
      retiredReader.recordReading(const TranscriptBookmark(messageId: 420));
      expect(session.reader.readingPosition.resume, isNull);
      expect(session.reader, isNot(same(retiredReader)));
      held.complete(
        ProfileHistoryPage('atlas-tip', [_message(1, 'Late Atlas')], 0, 100),
      );
      await first;
      expect(session.member?.profile, 'mira');
      expect(session.reader.messages.single['content'], 'Mira only');
      final disposing = Completer<ProfileHistoryPage>();
      fixture.historyHook = (_, _, _) => disposing.future;
      final pending = session.refresh();
      await Future<void>.delayed(Duration.zero);
      session.dispose();
      // Replace the teardown owner; the retired owner must never emit again.
      session = BotGroupHistorySession(fixture.repository, group);
      disposing.complete(
        ProfileHistoryPage('mira-tip', [_message(3, 'Late')], 0, 100),
      );
      await pending;
      expect(fixture.commands, isEmpty);
    },
  );

  test('a non-member cannot discover or read a group worker', () async {
    const member = BotGroupMember(
      id: 'foreign',
      profile: 'forge',
      handle: 'bot_forge',
      name: 'Forge',
    );
    await expectLater(
      fixture.repository.groupMemberSession(group, member),
      throwsStateError,
    );
    await expectLater(
      fixture.repository.groupMemberHistory(group, member, 'forge-tip', 0),
      throwsArgumentError,
    );
    expect(fixture.historyReads, isEmpty);
  });
}
