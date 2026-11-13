import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_insight.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_supervision_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

class _SubagentHost extends Host {
  Map<String, dynamic> listResponse = {'subagents': <Map<String, dynamic>>[]};
  Map<String, dynamic> tailResponse = {
    'subagent_id': 'child',
    'available': true,
    'text': 'tail',
    'truncated': false,
  };
  Map<String, dynamic> steerResponse = {
    'status': 'queued',
    'subagent_id': 'child',
  };
  Map<String, dynamic> interruptResponse = {
    'found': true,
    'subagent_id': 'child',
  };
  Completer<Map<String, dynamic>>? pendingList;
  Completer<Map<String, dynamic>>? pendingTail;
  Completer<Map<String, dynamic>>? pendingControl;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: () async {
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
        await base.connect();
      },
      close: base.close,
      get: base.read,
      rpc: (method, params) {
        if (method.startsWith('subagent.')) {
          calls.add((scope.profileName, method, params));
          return switch (method) {
            'subagent.list' =>
              pendingList?.future ?? Future.value(listResponse),
            'subagent.tail' =>
              pendingTail?.future ?? Future.value(tailResponse),
            'subagent.steer' || 'subagent.interrupt' =>
              pendingControl?.future ??
                  Future.value(
                    method == 'subagent.steer'
                        ? steerResponse
                        : interruptResponse,
                  ),
            _ => Future.value(<String, dynamic>{}),
          };
        }
        return base.call(method, params);
      },
    );
    return gateway;
  }
}

void main() {
  late _SubagentHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = _SubagentHost();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'subagent-test',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'message.start');
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test('completed agent leaves the drawer when its parent turn ends', () async {
    final session = ProfileSupervisionSession(
      controller: controller,
      chat: chat,
    );
    addTearDown(session.dispose);
    host.event('a', 'message.start');
    host.event('a', 'subagent.complete', {
      'subagent_id': 'previous-child',
      'goal': 'Find massage venues',
      'status': 'completed',
    });
    expect(session.state.subagents.single.id, 'previous-child');
    host.event('a', 'message.complete', {'text': 'Previous answer'});
    expect(chat.subagents.single.id, 'previous-child');
    expect(chat.runtime.executionActive, isFalse);
    expect(session.state.subagents, isEmpty);

    host.event('a', 'message.start');
    host.event('a', 'message.delta', {'text': 'Current answer is streaming'});
    expect(chat.runtime.executionActive, isTrue);
    expect(session.state.subagents, isEmpty);
  });

  for (final (event, status) in [
    ('message.complete', 'completed'),
    ('turn.end', 'completed'),
    ('message.complete', 'interrupted'),
    ('turn.error', 'error'),
  ]) {
    test(
      'parent $event $status retires terminal agents before history loads',
      () async {
        final session = ProfileSupervisionSession(
          controller: controller,
          chat: chat,
        );
        addTearDown(session.dispose);
        for (final terminal in ['completed', 'failed', 'interrupted']) {
          host.event('a', 'subagent.complete', {
            'subagent_id': terminal,
            'status': terminal,
          });
        }
        host.event('a', 'subagent.start', {
          'subagent_id': 'background',
          'goal': 'Still working',
        });
        expect(session.state.subagents, hasLength(4));
        final history = Completer<void>();
        host.heldHistoryDelay = history;
        addTearDown(() {
          if (!history.isCompleted) history.complete();
        });
        final before = chat.workRevision;
        var notifications = 0;
        session.addListener(() => notifications++);
        host.event('a', event, {'text': 'Parent settled', 'status': status});
        expect(chat.runtime.executionActive, isFalse);
        expect(history.isCompleted, isFalse);
        expect(chat.workRevision, isNot(same(before)));
        expect(notifications, greaterThan(0));
        expect(session.state.subagents.map((agent) => agent.id), [
          'background',
        ]);
        // A background child finishing after its parent also retires immediately.
        host.event('a', 'subagent.complete', {
          'subagent_id': 'background',
          'status': 'completed',
        });
        expect(session.state.subagents, isEmpty);
        host.event('a', 'message.start');
        expect(session.state.subagents, isEmpty);
      },
    );
  }

  test(
    'round scope survives stale roster reads and repeated completions',
    () async {
      final session = ProfileSupervisionSession(
        controller: controller,
        chat: chat,
      );
      addTearDown(session.dispose);
      host.event('a', 'message.start');
      for (final status in ['completed', 'failed', 'interrupted']) {
        host.event('a', 'subagent.complete', {
          'subagent_id': status,
          'goal': 'Previous $status task',
          'status': status,
        });
      }
      host.event('a', 'subagent.start', {
        'subagent_id': 'background',
        'goal': 'Still working',
      });
      host.event('a', 'subagent.spawn_requested', {
        'subagent_id': 'queued',
        'goal': 'Still queued',
      });
      host.event('a', 'message.complete', {'text': 'Previous answer'});
      host.pendingList = Completer<Map<String, dynamic>>();
      final read = controller.refreshSubagents(chat);
      final before = chat.workRevision;
      var notifications = 0;
      session.addListener(() => notifications++);
      host.event('a', 'message.start');
      expect(chat.workRevision, isNot(same(before)));
      expect(notifications, greaterThan(0));
      expect(session.state.subagents.map((agent) => agent.id), [
        'background',
        'queued',
      ]);
      host.pendingList!.complete({
        'subagents': [
          {'subagent_id': 'completed', 'status': 'completed'},
          {'subagent_id': 'late-completion', 'status': 'completed'},
          {'subagent_id': 'background', 'status': 'running'},
          {'subagent_id': 'queued', 'status': 'queued'},
        ],
      });
      await read;
      expect(
        chat.subagents.any((agent) => agent.id == 'late-completion'),
        isTrue,
      );
      host.event('a', 'subagent.complete', {
        'subagent_id': 'completed',
        'status': 'completed',
      });
      expect(session.state.subagents.map((agent) => agent.id), [
        'background',
        'queued',
      ]);
      // A genuinely new child still retains its completion during this answer,
      // including when message.start repeats within the same running round.
      host.event('a', 'subagent.complete', {
        'subagent_id': 'current',
        'status': 'completed',
      });
      host.event('a', 'message.start');
      expect(session.state.subagents.map((agent) => agent.id), [
        'background',
        'queued',
        'current',
      ]);
      expect(
        session.state.subagentSummary,
        '1 of 3 completed · 1 running · 1 queued',
      );
    },
  );

  test(
    'sending the next prompt retires completed agents before stream start',
    () async {
      final session = ProfileSupervisionSession(
        controller: controller,
        chat: chat,
      );
      addTearDown(session.dispose);
      host.event('a', 'subagent.start', {
        'subagent_id': 'child',
        'goal': 'Previous task',
      });
      final detail = session.openSubagent('child');
      addTearDown(detail.dispose);
      host.event('a', 'subagent.complete', {
        'subagent_id': 'child',
        'status': 'completed',
      });
      host.event('a', 'message.complete', {'text': 'Previous answer'});
      await controller.updateDraft(chat, 'Next question');
      await controller.send(chat);
      expect(chat.runtime.executionActive, isTrue);
      expect(session.state.subagents, isEmpty);
      expect(detail.state.activity.status, GatewaySubagentStatus.completed);
      expect(detail.state.canControl, isFalse);
    },
  );

  test(
    'subagent header separates outcomes, queue and unconfirmed work',
    () async {
      final session = ProfileSupervisionSession(
        controller: controller,
        chat: chat,
      );
      addTearDown(session.dispose);
      final rows = [
        for (final (id, status) in [
          ('done-1', 'completed'),
          ('done-2', 'completed'),
          ('done-3', 'completed'),
          ('running-1', 'running'),
          ('running-2', 'running'),
          ('queued', 'queued'),
          ('failed', 'failed'),
          ('interrupted', 'interrupted'),
        ])
          {'subagent_id': id, 'goal': 'Review $id', 'status': status},
      ];
      host.listResponse = {'subagents': rows};
      await controller.refreshSubagents(chat);
      expect(
        session.state.subagentSummary,
        '3 of 8 completed · 2 running · 1 queued · 1 failed · 1 interrupted',
      );
      rows[3]['status'] = 'completed';
      host.listResponse = {
        'subagents': rows
            .where(
              (row) =>
                  row['subagent_id'] != 'running-2' &&
                  row['subagent_id'] != 'queued',
            )
            .toList(),
      };
      await controller.refreshSubagents(chat);
      expect(
        session.state.subagentSummary,
        '4 of 8 completed · 1 failed · 1 interrupted · 2 unconfirmed',
      );
    },
  );

  test(
    'subagent header handles empty and entirely completed rosters',
    () async {
      final session = ProfileSupervisionSession(
        controller: controller,
        chat: chat,
      );
      addTearDown(session.dispose);
      expect(session.state.subagentSummary, 'No subagents');
      host.listResponse = {
        'subagents': [
          {
            'subagent_id': 'done',
            'goal': 'Review source',
            'status': 'completed',
          },
        ],
      };
      await controller.refreshSubagents(chat);
      expect(session.state.subagentSummary, '1 of 1 completed');
    },
  );

  test('opening a saved chat discovers its active agent roster', () async {
    host.listResponse = {
      'subagents': [
        {
          'subagent_id': 'existing-child',
          'goal': 'Already working',
          'status': 'running',
          'started_at': 123.0,
        },
      ],
    };
    await controller.openSession(chat.key);
    await Future<void>.delayed(Duration.zero);
    expect(chat.subagents.single.id, 'existing-child');
    expect(
      host.calls.where((call) => call.$2 == 'subagent.list'),
      hasLength(1),
    );
  });

  for (final olderFails in [false, true]) {
    test(
      'newer roster wins after an older ${olderFails ? 'error' : 'running snapshot'} settles first',
      () async {
        final older = Completer<Map<String, dynamic>>();
        final newer = Completer<Map<String, dynamic>>();
        host.pendingList = older;
        final first = controller.refreshSubagents(chat);
        host.pendingList = newer;
        final second = controller.refreshSubagents(chat);
        if (olderFails) {
          older.completeError(StateError('Old request failed'));
        } else {
          older.complete({
            'subagents': [
              {'subagent_id': 'child', 'status': 'running'},
            ],
          });
        }
        await first;
        expect(chat.subagents, isEmpty);
        expect(chat.subagentsError, isNull);
        expect(chat.subagentsLoading, isTrue);
        newer.complete({
          'subagents': [
            {'subagent_id': 'child', 'status': 'completed'},
          ],
        });
        await second;
        expect(chat.subagents.single.status, GatewaySubagentStatus.completed);
        expect(chat.subagentsError, isNull);
        expect(chat.subagentsLoading, isFalse);
      },
    );
  }

  test('an older roster cannot replace a newer completed snapshot', () async {
    final older = Completer<Map<String, dynamic>>();
    final newer = Completer<Map<String, dynamic>>();
    host.pendingList = older;
    final first = controller.refreshSubagents(chat);
    host.pendingList = newer;
    final second = controller.refreshSubagents(chat);
    newer.complete({
      'subagents': [
        {'subagent_id': 'child', 'status': 'completed'},
      ],
    });
    await second;
    older.complete({
      'subagents': [
        {'subagent_id': 'child', 'status': 'running'},
      ],
    });
    await first;
    expect(chat.subagents.single.status, GatewaySubagentStatus.completed);
    expect(chat.subagentsLoading, isFalse);
    expect(chat.subagentsError, isNull);
  });

  test('events merge sparse updates and normalize terminal status', () {
    host.event('a', 'subagent.start', {
      'subagent_id': 'child',
      'goal': 'Inspect transport',
      'accepting_steer': true,
    });
    host.event('a', 'subagent.tool', {
      'subagent_id': 'child',
      'tool_name': 'read_file',
    });

    expect(chat.subagents.single.goal, 'Inspect transport');
    expect(chat.subagents.single.lastTool, 'read_file');
    expect(chat.subagents.single.acceptingSteer, isTrue);

    host.event('a', 'subagent.complete', {
      'subagent_id': 'child',
      'status': 'timeout',
      'summary': 'Timed out',
    });
    expect(chat.subagents.single.status, GatewaySubagentStatus.failed);
    expect(chat.subagents.single.isTerminal, isTrue);

    host.event('a', 'subagent.progress', {'text': 'missing owner'});
    expect(chat.subagents, hasLength(1));
  });

  test(
    'partial snapshot keeps known children and uses the parent runtime',
    () async {
      host.event('a', 'subagent.complete', {
        'subagent_id': 'done',
        'goal': 'Finished task',
        'status': 'completed',
      });
      host.event('a', 'subagent.start', {
        'subagent_id': 'stale',
        'goal': 'No longer active',
      });
      host.listResponse = {
        'subagents': [
          {
            'subagent_id': 'active',
            'parent_id': 'root',
            'depth': 1,
            'goal': 'Current task',
            'delegation_id': 'batch',
            'model': 'model-a',
            'status': 'running',
            'started_at': 12.5,
            'tool_count': 3,
            'last_tool': 'search',
            'accepting_steer': true,
          },
        ],
        'delegations': <Object>[],
      };

      await controller.refreshSubagents(chat);

      expect(chat.subagents.map((item) => item.id), [
        'done',
        'stale',
        'active',
      ]);
      final active = chat.subagents.last;
      expect(chat.unconfirmedSubagentIds, {'stale'});
      expect(active.parentId, 'root');
      expect(active.delegationId, 'batch');
      expect(active.acceptingSteer, isTrue);
      expect(host.calls.last.$2, 'subagent.list');
      expect(host.calls.last.$3, {'session_id': 'a-runtime', 'profile': 'a'});
    },
  );

  test(
    'malformed snapshot preserves confirmed active rows and reports an error',
    () async {
      host.listResponse = {
        'subagents': [
          {'subagent_id': 'child'},
        ],
      };
      await controller.refreshSubagents(chat);

      expect(chat.subagents.single.id, 'child');
      expect(chat.subagents.single.status, GatewaySubagentStatus.running);
      expect(chat.subagentsError, isNull);

      host.listResponse = {
        'subagents': [
          {'goal': 'Malformed row without a subagent identity'},
        ],
      };
      await controller.refreshSubagents(chat);

      expect(chat.subagents.single.id, 'child');
      expect(chat.subagents.single.status, GatewaySubagentStatus.running);
      expect(chat.subagentsError, contains('could not be refreshed'));

      host.listResponse = {
        'subagents': [
          {'subagent_id': 'new-child'},
          'not a subagent row',
        ],
      };
      await controller.refreshSubagents(chat);

      expect(chat.subagents.single.id, 'child');
      expect(chat.subagentsError, contains('could not be refreshed'));
    },
  );

  test('late roster cannot replace newer events', () async {
    host.pendingList = Completer<Map<String, dynamic>>();
    final list = controller.refreshSubagents(chat);
    host.event('a', 'subagent.start', {
      'subagent_id': 'child',
      'goal': 'Live child',
    });
    host.pendingList!.complete({
      'subagents': [
        {'subagent_id': 'old', 'goal': 'Old child', 'status': 'running'},
      ],
    });
    await list;
    expect(chat.subagents.map((item) => item.id), ['child']);
  });

  test('tail ignores unrelated subagent progress', () async {
    host.event('a', 'subagent.start', {'subagent_id': 'child'});
    host.pendingTail = Completer<Map<String, dynamic>>();
    final tail = controller.loadSubagentTail(chat, 'child');
    host.event('a', 'subagent.progress', {
      'subagent_id': 'other',
      'text': 'Unrelated progress',
    });
    host.pendingTail!.complete({
      'subagent_id': 'child',
      'available': true,
      'text': 'older tail',
      'truncated': false,
    });
    expect((await tail)?.text, 'older tail');
  });

  test('completion invalidates a pending tail for that subagent', () async {
    host.event('a', 'subagent.start', {'subagent_id': 'child'});
    host.pendingTail = Completer<Map<String, dynamic>>();
    final staleTail = controller.loadSubagentTail(chat, 'child');
    host.event('a', 'subagent.complete', {
      'subagent_id': 'child',
      'status': 'completed',
    });
    host.pendingTail!.complete({
      'subagent_id': 'child',
      'available': true,
      'text': 'pre-completion tail',
      'truncated': false,
    });
    expect(await staleTail, isNull);
  });

  test(
    'completion before interrupt acknowledgement preserves acceptance',
    () async {
      host.event('a', 'subagent.start', {'subagent_id': 'child'});
      host.pendingControl = Completer<Map<String, dynamic>>();
      final interrupt = controller.interruptSubagent(
        chat,
        'child',
        canDispatch: () => true,
      );
      host.event('a', 'subagent.complete', {
        'subagent_id': 'child',
        'status': 'interrupted',
      });
      host.pendingControl!.complete({'found': true, 'subagent_id': 'child'});
      expect(await interrupt, isTrue);
      expect(chat.subagents.single.status, GatewaySubagentStatus.interrupted);
    },
  );

  test(
    'missing children recover on fresh events and settle only on completion',
    () async {
      host.event('a', 'subagent.start', {
        'subagent_id': 'child',
        'goal': 'Research',
      });
      await controller.refreshSubagents(chat);
      expect(chat.subagents.single.isTerminal, isFalse);
      expect(chat.unconfirmedSubagentIds, {'child'});
      host.event('a', 'subagent.tool', {
        'subagent_id': 'child',
        'tool_name': 'browser_snapshot',
      });
      expect(chat.unconfirmedSubagentIds, isEmpty);
      expect(chat.subagents.single.lastTool, 'browser_snapshot');
      await controller.refreshSubagents(chat);
      expect(chat.unconfirmedSubagentIds, {'child'});
      host.event('a', 'subagent.complete', {
        'subagent_id': 'child',
        'status': 'completed',
        'summary': 'Research saved',
      });
      expect(chat.unconfirmedSubagentIds, isEmpty);
      expect(chat.subagents.single.isTerminal, isTrue);
      expect(chat.subagents.single.recentActivity.last, 'Research saved');
    },
  );

  test(
    'recent activity keeps bounded tool previews and server output tails',
    () async {
      for (var index = 0; index < 45; index++) {
        host.event('a', 'subagent.progress', {
          'subagent_id': 'child',
          'text': 'Progress $index',
        });
      }
      host.event('a', 'subagent.tool', {
        'subagent_id': 'child',
        'tool_name': 'read_file',
        'tool_preview': 'Checking build.gradle',
        'output_tail': [
          {'tool': 'browser_snapshot', 'preview': 'Found the booking page'},
        ],
      });
      expect(
        chat.subagents.single.recentActivity,
        hasLength(GatewaySubagentActivity.maxRecentActivity),
      );
      expect(
        chat.subagents.single.recentActivity,
        contains('Tool: browser_snapshot · Found the booking page'),
      );
      expect(
        chat.subagents.single.recentActivity.last,
        'Tool: read_file · Checking build.gradle',
      );
      final before = chat.subagents.single.recentActivity;
      host.listResponse = {
        'subagents': [
          {
            'subagent_id': 'child',
            'last_tool': 'read_file',
            'status': 'running',
          },
        ],
      };
      await controller.refreshSubagents(chat);
      expect(chat.subagents.single.recentActivity, before);
    },
  );

  test('tail read enforces the text resource budget', () async {
    host.event('a', 'subagent.start', {
      'subagent_id': 'child',
      'goal': 'Owned child',
    });
    host.tailResponse = {
      'subagent_id': 'child',
      'available': true,
      'text': List.filled(GatewaySubagentTail.maxTextLength + 8, 'x').join(),
      'truncated': false,
    };
    final clipped = await controller.loadSubagentTail(chat, 'child');
    expect(clipped!.text, hasLength(GatewaySubagentTail.maxTextLength));
    expect(clipped.truncated, isTrue);
  });

  test('steer trims the instruction and sends exact scoped identity', () async {
    host.event('a', 'subagent.start', {'subagent_id': 'child'});
    expect(
      await controller.steerSubagent(
        chat,
        'child',
        ' redirect ',
        canDispatch: () => true,
      ),
      isTrue,
    );
    expect(host.calls.last.$3, {
      'session_id': 'a-runtime',
      'subagent_id': 'child',
      'text': 'redirect',
      'profile': 'a',
    });
  });

  test('rejected steer is not accepted', () async {
    host.event('a', 'subagent.start', {'subagent_id': 'child'});
    host.steerResponse = {'status': 'rejected'};
    expect(
      await controller.steerSubagent(
        chat,
        'child',
        'again',
        canDispatch: () => true,
      ),
      isFalse,
    );
  });

  test('interrupt rejects acknowledgement for another child', () async {
    host.event('a', 'subagent.start', {'subagent_id': 'child'});
    host.interruptResponse = {'found': true, 'subagent_id': 'other'};
    expect(
      await controller.interruptSubagent(
        chat,
        'child',
        canDispatch: () => true,
      ),
      isFalse,
    );
  });

  test('accepted steer retains originating profile after navigation', () async {
    host.event('a', 'subagent.start', {'subagent_id': 'child'});
    host.pendingControl = Completer<Map<String, dynamic>>();
    final scoped = controller.steerSubagent(
      chat,
      'child',
      'scoped',
      canDispatch: () => true,
    );
    await controller.switchProfile('b');
    host.pendingControl!.complete({'status': 'queued', 'subagent_id': 'child'});
    expect(await scoped, isTrue);
    expect(host.calls.lastWhere((call) => call.$2 == 'subagent.steer').$1, 'a');
  });

  test(
    'late steer acknowledgement cannot affect replacement runtime',
    () async {
      host.event('a', 'subagent.start', {'subagent_id': 'child'});
      host.pendingControl = Completer<Map<String, dynamic>>();
      final late = controller.steerSubagent(
        chat,
        'child',
        'late',
        canDispatch: () => true,
      );
      host.runtimeForResume['a'] = 'replacement-runtime';
      await controller.openSession(chat.key);
      host.pendingControl!.complete({
        'status': 'queued',
        'subagent_id': 'child',
      });
      expect(await late, isFalse);
      expect(host.calls.last.$1, 'a');
    },
  );
}
