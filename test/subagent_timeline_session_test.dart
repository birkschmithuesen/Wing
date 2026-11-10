import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_insight.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/operational_error.dart';
import 'package:wing/core/models/profile_supervision.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/subagent_timeline_session.dart';

void main() {
  final scope = WorkspaceScope(
    connectionId: 'host',
    connectionIdentity: 'server',
    profileName: 'atlas',
  );
  late SubagentTimelineSession session;
  late List<(String, Map<String, dynamic>)> calls;
  late List<OperationalErrorObservation> observations;
  late List<Map<String, dynamic>> events, rows;
  late List<int> offsets;
  late String epoch, mountedId, storedId;
  late bool current, failRead, failHistory, truncated;
  late int replyTurn, replySegment, replyOffset;
  Future<void>? held;
  Map<String, dynamic> event(String type, Map<String, dynamic> payload) {
    final stamped = Map<String, dynamic>.of(payload);
    if (type == 'message.start') {
      replyTurn++;
      replySegment = 0;
      replyOffset = 0;
      stamped['turn_id'] = 'child-turn-$replyTurn';
    } else if (type == 'message.delta' || type == 'message.interim') {
      stamped.addAll({
        'turn_id': 'child-turn-$replyTurn',
        'segment': replySegment,
        'offset': replyOffset,
      });
      if (type == 'message.interim') {
        replySegment++;
        replyOffset = 0;
      } else if (payload['text'] case final String text) {
        replyOffset += text.length;
      }
    }
    return {
      'session_id': 'child-session',
      'seq': events.length + 1,
      'type': type,
      'payload': stamped,
    };
  }

  setUp(() {
    calls = [];
    observations = [];
    events = [];
    rows = [];
    offsets = [];
    epoch = 'epoch-1';
    mountedId = 'child-session';
    storedId = 'child-session';
    current = true;
    failRead = false;
    failHistory = false;
    truncated = false;
    replyTurn = 0;
    replySegment = 0;
    replyOffset = 0;
    held = null;
    session = SubagentTimelineSession(
      scope: scope,
      onOperationalError: observations.add,
      sessionId: 'child-session',
      isCurrent: () => current,
      read: (method, params) async {
        calls.add((method, Map.of(params)));
        if (held != null) await held;
        if (failRead) throw StateError('offline');
        if (method == 'session.resume') {
          return {
            'session_id': mountedId,
            'stored_session_id': storedId,
            'replay_epoch': epoch,
            'last_sequence': events.length,
            'running': true,
          };
        }
        expect(method, 'session.events.since');
        expect(params.containsKey('last_seen'), isFalse);
        final missing = truncated || params['replay_epoch'] != epoch;
        return {
          'replay_epoch': epoch,
          'latest_seq': events.length,
          'truncated': missing,
          'snapshot_required': missing,
          'events': missing ? [] : List.of(events),
        };
      },
      history: (id, offset) async {
        offsets.add(offset);
        if (failHistory) throw StateError('Not persisted yet');
        if (held != null) await held;
        return ProfileHistoryPage(
          id,
          List.of(rows),
          offset,
          20,
          isComplete: true,
        );
      },
    );
  });
  tearDown(() => session.dispose());

  test('live replay cannot clear a failed saved-history read', () async {
    await session.refresh();
    failHistory = true;
    observations.clear();
    await session.refresh();
    final issue = observations.where((item) => item.error != null).single;
    expect(issue.operation, 'subagent-history:atlas:child-session');
    observations.clear();
    session.setActive(true);
    await Future<void>.delayed(Duration.zero);
    session.setActive(false);
    expect(
      observations.single.operation,
      'subagent-timeline:atlas:child-session',
    );
    expect(observations.single.error, isNull);

    failHistory = false;
    observations.clear();
    await session.refresh();
    expect(
      observations
          .singleWhere((item) => item.operation == issue.operation)
          .error,
      isNull,
    );
  });

  test(
    'completed tasks retire through child completion and later turns',
    () async {
      void emit(String type, Map<String, dynamic> payload) =>
          events.add(event(type, payload));
      final done = {
        'revision': 1,
        'todos': [
          {'id': 'task', 'content': 'Inspect child', 'status': 'completed'},
        ],
      };
      emit('message.start', {});
      emit('todo.updated', done);
      await session.refresh();
      expect(session.todos.single.content, 'Inspect child');
      emit('message.complete', {'text': 'Finished'});
      failHistory = true;
      await session.refresh();
      expect(session.todos, isEmpty);
      emit('message.start', {});
      emit('todo.updated', done);
      await session.refresh();
      expect(session.todos, isEmpty);
    },
  );

  test(
    'child identity survives events, snapshots and detached observations',
    () {
      final child = GatewaySubagentActivity.fromGatewayEvent('subagent.start', {
        'subagent_id': 'child',
        'child_session_id': 'child-session',
        'goal': 'Inspect',
      })!;
      final snapshot = GatewaySubagentActivity.fromSnapshot({
        'subagent_id': 'child',
        'status': 'running',
        'tool_count': 3,
      })!;
      expect(
        copySupervisedSubagent(
          child.merge(snapshot, snapshot: true),
        ).childSessionId,
        'child-session',
      );
    },
  );

  test(
    'mounts the exact canonical child and retains saved tool inputs and results',
    () async {
      rows.addAll([
        {
          'id': 1,
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-1',
              'function': {
                'name': 'terminal',
                'arguments': '{"command":"pytest"}',
              },
            },
          ],
        },
        {
          'id': 2,
          'role': 'tool',
          'tool_call_id': 'call-1',
          'content': '17 passed',
        },
      ]);
      await session.refresh();
      expect(calls.first.$1, 'session.resume');
      expect(calls.first.$2, {
        'session_id': 'child-session',
        'display_projection': true,
      });
      expect(session.messages.first['tool_calls'], [
        {
          'id': 'call-1',
          'function': {'name': 'terminal', 'arguments': '{"command":"pytest"}'},
        },
      ]);
      expect(session.messages.last['tool_call_id'], 'call-1');
      expect(session.messages.last['content'], '17 passed');
      expect(session.historyAvailable, isTrue);
      expect(session.runtime.executionActive, isTrue);
      expect(offsets, [0]);
    },
  );

  test(
    'replay keeps reasoning, previews and reply without invented timing',
    () async {
      events.add(event('message.start', {}));
      events.add(
        event('reasoning.delta', {'text': 'Checking the predecessor'}),
      );
      events.add(
        event('tool.start', {
          'name': 'terminal',
          'tool_id': 'submirror:child:1',
          'args': {},
          'preview': 'pytest -q',
        }),
      );
      events.add(event('message.delta', {'text': 'Found the missing row.'}));
      await session.refresh();
      final tool = session.runtime.toolActivities.single;
      expect(tool.context, 'pytest -q');
      expect(tool.arguments, isNull);
      expect(tool.result, isNull);
      expect(tool.startedAt, isNull);
      expect(tool.durationSeconds, isNull);
      expect(session.streaming, 'Found the missing row.');
      final count = session.runtime.activityEntries.length;
      await session.refresh();
      expect(session.streaming, 'Found the missing row.');
      expect(session.runtime.activityEntries, hasLength(count));
      expect(session.state.subagents, isEmpty);
    },
  );

  test('completion replaces mirror with saved history', () async {
    events.add(event('message.start', {}));
    events.add(event('message.delta', {'text': 'Working'}));
    await session.refresh();
    rows.add({'id': 10, 'role': 'assistant', 'content': 'Verified the fix.'});
    events.add(event('message.complete', {'text': 'Verified the fix.'}));
    await session.refresh();
    expect(session.runtime.executionActive, isFalse);
    expect(session.streaming, isEmpty);
    expect(session.messages.single['content'], 'Verified the fix.');
  });

  test(
    'completion retains received reply while persistence catches up',
    () async {
      events.add(event('message.start', {}));
      events.add(event('message.complete', {'text': 'New final answer'}));
      await session.refresh();
      expect(session.streaming, 'New final answer');
      expect(session.liveAnswering, isTrue);
      expect(session.runtime.executionActive, isFalse);
      rows.add({'id': 5, 'role': 'assistant', 'content': 'New final answer'});
      await session.refresh();
      expect(session.streaming, isEmpty);
      expect(session.messages.single['content'], 'New final answer');
      expect(session.liveAnswering, isFalse);
    },
  );

  test('saved history remains readable when live mount fails', () async {
    rows.add({'id': 1, 'role': 'assistant', 'content': 'Saved only'});
    failRead = true;
    await session.refresh();
    expect(session.messages.single['content'], 'Saved only');
    expect(session.liveError, isNotNull);
    failRead = false;
    await session.refresh();
    expect(session.liveError, isNull);
  });

  test('failed refresh retains content and retry clears the error', () async {
    rows.add({'id': 1, 'role': 'assistant', 'content': 'Saved evidence'});
    await session.refresh();
    failRead = true;
    await session.refresh();
    expect(session.messages.single['content'], 'Saved evidence');
    expect(session.liveError, contains('Retry'));
    expect(session.historyLoading, isFalse);
    failRead = false;
    await session.refresh();
    expect(session.liveError, isNull);
  });

  test('held read publishes loading and coalesces explicit refresh', () async {
    final gate = Completer<void>();
    held = gate.future;
    final first = session.refresh();
    final second = session.refresh();
    expect(session.historyLoading, isTrue);
    expect(calls, hasLength(1));
    gate.complete();
    await Future.wait([first, second]);
    expect(calls.where((call) => call.$1 == 'session.resume'), hasLength(1));
    expect(session.historyLoading, isFalse);
  });

  test('retired visit does not publish or issue dependent reads', () async {
    final gate = Completer<void>();
    held = gate.future;
    final pending = session.refresh();
    current = false;
    gate.complete();
    await pending;
    expect(session.historyAvailable, isFalse);
    expect(calls, hasLength(1));
    expect(offsets, isEmpty);
  });

  test('dispose during held mount suppresses late publication', () async {
    final gate = Completer<void>();
    held = gate.future;
    final pending = session.refresh();
    session.dispose();
    gate.complete();
    await pending;
    expect(calls, hasLength(1));
    expect(offsets, isEmpty);
  });

  test('epoch replacement replays from zero without duplicated text', () async {
    events.add(event('message.start', {}));
    events.add(event('message.delta', {'text': 'First epoch'}));
    await session.refresh();
    epoch = 'epoch-2';
    events.clear();
    events.add(event('message.start', {}));
    events.add(event('message.delta', {'text': 'Second epoch'}));
    await session.refresh();
    expect(session.streaming, 'Second epoch');
    expect(calls.last.$2['last_sequence'], 0);
    expect(calls.last.$2['replay_epoch'], 'epoch-2');
    expect(calls.where((call) => call.$1 == 'session.resume'), hasLength(2));
    expect(
      session.qualification,
      contains('Earlier live activity is unavailable'),
    );
  });

  test('watch identity mismatch cannot supply another child replay', () async {
    storedId = 'different-child';
    rows.add({'id': 1, 'role': 'assistant', 'content': 'Exact saved child'});
    await session.refresh();
    expect(session.liveError, isNotNull);
    expect(session.messages.single['content'], 'Exact saved child');
    expect(calls.map((call) => call.$1), ['session.resume']);
  });

  test(
    'a different canonical mount cannot replace the selected child',
    () async {
      mountedId = storedId = 'different-child';
      await session.refresh();
      expect(session.liveError, isNotNull);
      expect(calls.map((call) => call.$1), ['session.resume']);
    },
  );

  test('replay rejects a foreign child before applying any event', () async {
    events.add(event('message.start', {}));
    events.add({
      ...event('message.delta', {'text': 'Foreign'}),
      'session_id': 'different-child',
    });
    await session.refresh();
    expect(session.liveError, isNotNull);
    expect(session.streaming, isEmpty);
  });
  test(
    'live replay remains readable before saved history is available',
    () async {
      failHistory = true;
      events.add(event('message.start', {}));
      events.add(event('message.delta', {'text': 'Live child reply'}));
      await session.refresh();
      expect(session.streaming, 'Live child reply');
      expect(session.historyError, isNotNull);
      expect(session.liveError, isNull);
    },
  );

  test('truncated replay explicitly qualifies earlier live activity', () async {
    truncated = true;
    await session.refresh();
    expect(
      session.qualification,
      contains('Earlier live activity is unavailable'),
    );
  });

  test('a truncated replay resumes after the snapshot watermark', () async {
    events.add(event('message.start', {}));
    events.add(event('message.delta', {'text': 'Missing from the ring'}));
    truncated = true;
    rows.add({
      'id': 1,
      'role': 'assistant',
      'content': 'Saved recovery evidence',
    });
    await session.refresh();
    expect(session.streaming, isEmpty);
    expect(session.messages.single['content'], 'Saved recovery evidence');
    expect(session.qualification, isNotNull);
    truncated = false;
    events.add(event('message.start', {}));
    events.add(event('message.delta', {'text': 'Newly received answer'}));
    await session.refresh();
    expect(calls.last.$2['last_sequence'], 2);
    expect(session.streaming, 'Newly received answer');
  });

  test(
    'paging retains order and a complete prefix across latest refresh',
    () async {
      session.dispose();
      final reads = <int>[];
      session = SubagentTimelineSession(
        scope: scope,
        sessionId: 'child-session',
        isCurrent: () => true,
        read: (method, params) async => method == 'session.resume'
            ? {
                'session_id': 'child-session',
                'stored_session_id': 'child-session',
                'replay_epoch': 'epoch',
                'last_sequence': 0,
                'running': false,
              }
            : {
                'replay_epoch': 'epoch',
                'events': <Map<String, dynamic>>[],
                'latest_seq': 0,
                'truncated': false,
                'snapshot_required': false,
              },
        history: (id, offset) async {
          reads.add(offset);
          return ProfileHistoryPage(
            id,
            [
              for (
                var n = offset == 0 ? 21 : 1;
                n <= (offset == 0 ? 40 : 20);
                n++
              )
                {'id': n, 'role': 'assistant', 'content': 'Message $n'},
            ],
            offset,
            20,
            isComplete: offset != 0,
          );
        },
      );
      await session.refresh();
      expect(session.nextHistoryOffset, 20);
      await session.loadOlder();
      expect(session.messages, hasLength(40));
      expect(session.messages.first['id'], 1);
      expect(session.messages.last['id'], 40);
      expect(session.nextHistoryOffset, isNull);
      await session.refresh();
      expect(session.messages, hasLength(40));
      expect(session.nextHistoryOffset, isNull);
      expect(reads, [0, 20, 0]);
    },
  );
}
