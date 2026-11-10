import 'support/composer_fixture.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_process.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/operational_error.dart';
import 'package:wing/core/models/session_control.dart';
import 'package:wing/core/models/side_question_delivery.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_supervision_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

Map<String, dynamic> _process(String id, String status) => {
  'session_id': id,
  'command': 'python worker.py',
  'status': status,
  'output_tail': 'latest output',
  if (status == 'exited') 'exit_code': 0,
};

Map<String, dynamic> _controlResponse(String revision) => {
  'control': {
    'goal': null,
    'loop': null,
    'heartbeat': null,
    'revision': revision,
    'updated_at': 1,
  },
  'dispatch': {
    'type': 'exec',
    'output': null,
    'notice': null,
    'message': null,
    'display': null,
  },
};

class _BackgroundHost extends Host {
  Map<String, dynamic> listResponse = {'processes': <Object>[]};
  Map<String, dynamic> killResponse = {
    'status': 'killed',
    'session_id': 'bg-1',
  };
  Completer<Map<String, dynamic>>? pendingList;
  Completer<Map<String, dynamic>>? pendingKill;
  bool listFails = false;
  int controlRevision = 0;
  Object? sideTasks = const {'retention': 'live_session', 'tasks': <Object>[]};
  bool includeSideTasks = true;

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
      rpc: (method, params) async {
        if (method == 'process.list') {
          calls.add((scope.profileName, method, params));
          final pending = pendingList;
          if (pending != null) return pending.future;
          if (listFails) throw TimeoutException('list acknowledgement lost');
          return listResponse;
        }
        if (method == 'process.kill') {
          calls.add((scope.profileName, method, params));
          final pending = pendingKill;
          return pending?.future ?? killResponse;
        }
        if (method == 'session.control') {
          calls.add((scope.profileName, method, params));
          return _controlResponse('control-${++controlRevision}');
        }
        final result = await base.call(method, params);
        if (method == 'session.resume') {
          return {...result, if (includeSideTasks) 'side_tasks': sideTasks};
        }
        return result;
      },
    );
    return gateway;
  }
}

void main() {
  late _BackgroundHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late List<OperationalErrorObservation> operationalErrors;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = _BackgroundHost();
    operationalErrors = [];
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'background-work-test',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      onOperationalError: operationalErrors.add,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  int reads() => host.calls.where((call) => call.$2 == 'process.list').length;

  test(
    'idle process registry stays out of the live dock across later turns',
    () async {
      final session = ProfileSupervisionSession(
        controller: controller,
        chat: chat,
      );
      addTearDown(session.dispose);
      host.listResponse = {
        'processes': [for (var i = 0; i < 7; i++) _process('old-$i', 'exited')],
      };
      await controller.refreshProcesses(chat);
      expect(chat.runtime.executionActive, isFalse);
      expect(chat.processes, hasLength(7));
      expect(session.state.processes, isEmpty);
      host.event('a', 'message.start');
      await controller.refreshProcesses(chat);
      expect(session.state.processes, isEmpty);
    },
  );

  for (final event in ['message.complete', 'turn.end', 'turn.error']) {
    test(
      'parent $event retires exited processes while running work survives',
      () async {
        final session = ProfileSupervisionSession(
          controller: controller,
          chat: chat,
        );
        addTearDown(session.dispose);
        host.event('a', 'message.start');
        host.listResponse = {
          'processes': [
            _process('finished', 'exited'),
            _process('working', 'running'),
          ],
        };
        await controller.refreshProcesses(chat);
        expect(session.state.processes, hasLength(2));
        host.event('a', event, {
          'text': 'Done',
          'status': event == 'turn.error' ? 'error' : 'completed',
        });
        expect(chat.runtime.executionActive, isFalse);
        expect(session.state.processes.map((p) => p.id), ['working']);
        await controller.refreshProcesses(chat);
        expect(session.state.processes.map((p) => p.id), ['working']);
        host.event('a', 'message.start');
        await controller.refreshProcesses(chat);
        expect(session.state.processes.map((p) => p.id), ['working']);
      },
    );
  }

  for (final nextTurn in [false, true]) {
    test(
      'process exit read after response, next turn $nextTurn, stays retired',
      () async {
        final session = ProfileSupervisionSession(
          controller: controller,
          chat: chat,
        );
        addTearDown(session.dispose);
        host.event('a', 'message.start');
        host.listResponse = {
          'processes': [_process('working', 'running')],
        };
        await controller.refreshProcesses(chat);
        final pending = host.pendingList = Completer<Map<String, dynamic>>();
        final refresh = controller.refreshProcesses(chat);
        host.event('a', 'message.complete', {'text': 'Done'});
        expect(session.state.processes.single.isRunning, isTrue);
        if (nextTurn) host.event('a', 'message.start');
        pending.complete({
          'processes': [_process('working', 'exited')],
        });
        await refresh;
        expect(session.state.processes, isEmpty);
      },
    );
  }

  testWidgets(
    'visible chat discovers and follows processes without idle polling',
    (tester) async {
      final route = Object();
      host.listResponse = {
        'processes': [_process('bg-1', 'running')],
      };
      controller.setRouteVisibility(route, true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(chat.processes.single.id, 'bg-1');
      expect(reads(), 1);
      final revision = chat.workRevision;
      await tester.pump(const Duration(seconds: 5));
      expect(reads(), 2);
      expect(
        chat.workRevision,
        same(revision),
        reason: 'Quiet unchanged polls do not invalidate the dock',
      );
      host.listResponse = {
        'processes': [
          {..._process('bg-1', 'running'), 'output_tail': 'new output'},
        ],
      };
      await tester.pump(const Duration(seconds: 5));
      expect(chat.processes.single.outputTail, 'new output');
      controller.setRouteVisibility(route, false);
      final hiddenReads = reads();
      await tester.pump(const Duration(seconds: 30));
      expect(reads(), hiddenReads);
      host.listResponse = {
        'processes': [_process('bg-1', 'exited')],
      };
      controller.setRouteVisibility(route, true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(chat.processes.single.isRunning, isFalse);
      final settledReads = reads();
      await tester.pump(const Duration(seconds: 30));
      expect(reads(), settledReads);
      controller.setRouteVisibility(route, false);
    },
  );

  testWidgets(
    'terminal receipts discover from empty and coalesce in-flight changes',
    (tester) async {
      final route = Object();
      controller.setRouteVisibility(route, true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(chat.processes, isEmpty);
      final emptyReads = reads();
      await tester.pump(const Duration(seconds: 30));
      expect(reads(), emptyReads);
      void receipt(String name) => host.event('a', 'tool.complete', {
        'name': name,
        'tool_call_id': name,
      });
      receipt('web_search');
      await tester.pump(const Duration(milliseconds: 250));
      expect(reads(), emptyReads);
      final pending = host.pendingList = Completer<Map<String, dynamic>>();
      for (var i = 0; i < 10; i++) {
        receipt('terminal');
      }
      await tester.pump(const Duration(milliseconds: 250));
      expect(reads(), emptyReads + 1);
      final selectionRead = controller.refreshProcesses(chat);
      receipt('process_manage');
      await tester.pump(const Duration(seconds: 20));
      expect(
        reads(),
        emptyReads + 1,
        reason: 'Slow reads never overlap polls or event refreshes',
      );
      host.pendingList = null;
      host.listResponse = {
        'processes': [_process('bg-1', 'exited')],
      };
      pending.complete({
        'processes': [_process('bg-1', 'running')],
      });
      await selectionRead;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(reads(), emptyReads + 2);
      expect(chat.processes.single.isRunning, isFalse);
      controller.setRouteVisibility(route, false);
    },
  );

  testWidgets(
    'failed automatic read retains rows and stops until explicit recovery',
    (tester) async {
      final route = Object();
      host.listResponse = {
        'processes': [_process('bg-1', 'running')],
      };
      controller.setRouteVisibility(route, true);
      await tester.pump(const Duration(milliseconds: 1));
      host.listFails = true;
      await tester.pump(const Duration(seconds: 5));
      expect(chat.processes.single.id, 'bg-1');
      expect(chat.processesError, isNotNull);
      expect(chat.inlineProcessesError, isNull);
      final issue = operationalErrors
          .where((item) => item.error != null)
          .single;
      expect(
        issue.operation,
        'processes:${chat.key.workspace.profileName}:${chat.key.sessionId}',
      );
      final failedReads = reads();
      await tester.pump(const Duration(seconds: 30));
      expect(reads(), failedReads);
      host.listFails = false;
      await controller.refreshProcesses(chat);
      expect(chat.processesError, isNull);
      expect(operationalErrors.last.operation, issue.operation);
      expect(operationalErrors.last.error, isNull);
      await tester.pump(const Duration(seconds: 5));
      expect(reads(), failedReads + 2);
      controller.setRouteMounted(route, false);
      final retiredReads = reads();
      await tester.pump(const Duration(seconds: 30));
      expect(reads(), retiredReads);
    },
  );

  testWidgets('replaced runtime ignores a held automatic snapshot', (
    tester,
  ) async {
    final route = Object();
    final pending = host.pendingList = Completer<Map<String, dynamic>>();
    controller.setRouteVisibility(route, true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(reads(), 1);
    host.pendingList = null;
    host.listResponse = {
      'processes': [_process('replacement', 'running')],
    };
    host.runtimeForResume['a'] = 'replacement-runtime';
    await controller.openSession(chat.key);
    await tester.pump(const Duration(milliseconds: 1));
    expect(chat.runtime.runtimeId, 'replacement-runtime');
    expect(chat.processes.single.id, 'replacement');
    pending.complete({
      'processes': [_process('stale', 'running')],
    });
    await tester.pump();
    expect(chat.processes.single.id, 'replacement');
    controller.setRouteVisibility(route, false);
  });

  test(
    'refresh is scoped and a stale read cannot replace a newer list',
    () async {
      final pending = host.pendingList = Completer<Map<String, dynamic>>();
      final stale = controller.refreshProcesses(chat);

      host.pendingList = null;
      host.listResponse = {
        'processes': [_process('new', 'running')],
      };
      await controller.refreshProcesses(chat);
      pending.complete({
        'processes': [_process('old', 'running')],
      });
      await stale;
      expect(chat.processes.single.id, 'new');
      expect(host.calls.where((call) => call.$2 == 'process.list').last.$3, {
        'session_id': 'a-runtime',
        'profile': 'a',
      });
    },
  );

  test(
    'malformed snapshot preserves confirmed processes and reports an error',
    () async {
      host.listResponse = {
        'processes': [
          {'session_id': 'live', 'status': 'running'},
        ],
      };
      await controller.refreshProcesses(chat);

      expect(chat.processes.single.id, 'live');
      expect(chat.processes.single.command, 'Background process');
      expect(chat.processesError, isNull);

      host.listResponse = {
        'processes': [
          {'status': 'running'},
        ],
      };
      await controller.refreshProcesses(chat);

      expect(chat.processes.single.id, 'live');
      expect(chat.processes.single.isRunning, isTrue);
      expect(chat.processesError, contains('could not be refreshed'));

      host.listResponse = {
        'processes': [
          {'session_id': 'new-live', 'status': 'running'},
          'not a process row',
        ],
      };
      await controller.refreshProcesses(chat);

      expect(chat.processes.single.id, 'live');
      expect(chat.processesError, contains('could not be refreshed'));
    },
  );

  test('session info authoritatively hydrates side-task history', () {
    emitChatEvent(controller, chat, 'session.info', {
      'open_requests': [],
      'running': false,
    });
    host.event('a', 'session.info', {
      'side_tasks': {
        'retention': 'live_session',
        'tasks': [
          {
            'task_id': 'running',
            'kind': 'background',
            'prompt': 'Check deployment',
            'prompt_truncated': false,
            'status': 'running',
            'result': null,
            'result_truncated': false,
          },
          {
            'task_id': 'answered',
            'kind': 'btw',
            'prompt': 'What changed?',
            'prompt_truncated': true,
            'status': 'completed',
            'result': 'The server changed.',
            'result_truncated': false,
          },
          {
            'task_id': 'failed',
            'kind': 'background',
            'prompt': 'Deploy',
            'prompt_truncated': false,
            'status': 'error',
            'result': 'Deployment failed.',
            'result_truncated': true,
          },
        ],
      },
    });

    expect(chat.sideQuestionDeliveries, hasLength(3));
    expect(
      chat.sideQuestionDeliveries[0].state,
      SideQuestionDeliveryState.pending,
    );
    expect(chat.sideQuestionDeliveries[1].questionTruncated, isTrue);
    expect(
      chat.sideQuestionDeliveries[2].state,
      SideQuestionDeliveryState.failed,
    );
    expect(chat.sideQuestionDeliveries[2].resultTruncated, isTrue);
    expect(chat.runtime.execution, ChatExecution.idle);

    host.event('a', 'session.info', {'model': 'fixture-model'});
    expect(chat.sideQuestionDeliveries, hasLength(3));
  });

  for (final clearKind in ['empty resume', 'malformed event']) {
    test('resumed tasks are cleared by $clearKind', () async {
      host.sideTasks = {
        'retention': 'live_session',
        'tasks': [
          {
            'task_id': 'recovered',
            'kind': 'btw',
            'prompt': 'Recovered question',
            'prompt_truncated': false,
            'status': 'running',
            'result': null,
            'result_truncated': false,
          },
        ],
      };
      await controller.reconnect(chat.key.workspace);
      expect(chat.sideQuestionDeliveries.single.taskId, 'recovered');
      expect(chat.runtime.blocksTurnAdmission, isTrue);
      expect(chat.runtime.execution, ChatExecution.running);

      if (clearKind == 'empty resume') {
        host.sideTasks = const {
          'retention': 'live_session',
          'tasks': <Object>[],
        };
        await controller.reconnect(chat.key.workspace);
      } else {
        host.event('a', 'session.info', {
          'side_tasks': {'retention': 'wrong', 'tasks': <Object>[]},
        });
      }
      expect(chat.sideQuestionDeliveries, isEmpty);
    });
  }

  test(
    'same-runtime resume preserves side-task cards when the field is absent',
    () async {
      host.event('a', 'background.complete', {
        'task_id': 'live-task',
        'question': 'Check deployment',
        'text': 'Deployment complete.',
      });
      host.includeSideTasks = false;

      await controller.reconnect(chat.key.workspace);

      expect(chat.sideQuestionDeliveries.single.taskId, 'live-task');
      expect(
        chat.sideQuestionDeliveries.single.state,
        SideQuestionDeliveryState.completed,
      );
    },
  );

  test(
    'changed-runtime resume clears side-task cards when the field is absent',
    () async {
      host.event('a', 'background.complete', {
        'task_id': 'old-task',
        'question': 'Check deployment',
        'text': 'Deployment complete.',
      });
      host.includeSideTasks = false;
      host.running = false;
      host.runtimeForResume['a'] = 'a-new-runtime';

      await controller.reconnect(chat.key.workspace);

      expect(chat.runtime.runtimeId, 'a-new-runtime');
      expect(chat.sideQuestionDeliveries, isEmpty);
    },
  );

  for (final (name, response, accepted) in [
    (
      'confirmed stop',
      <String, dynamic>{'status': 'killed', 'session_id': 'bg-1'},
      true,
    ),
    (
      'server rejection',
      <String, dynamic>{'status': 'error', 'session_id': 'bg-1'},
      false,
    ),
    (
      'already exited',
      <String, dynamic>{'status': 'already_exited', 'exit_code': 0},
      true,
    ),
    (
      'different process acknowledgement',
      <String, dynamic>{
        'status': 'already_exited',
        'session_id': 'another-process',
      },
      false,
    ),
  ]) {
    test('stop handles $name without inventing completion', () async {
      host.listResponse = {
        'processes': [_process('bg-1', 'running')],
      };
      await controller.refreshProcesses(chat);
      host.killResponse = response;
      host.listResponse = {
        'processes': [_process('bg-1', 'exited')],
      };
      expect(
        await controller.stopProcess(chat, 'bg-1', canDispatch: () => true),
        accepted,
      );
      expect(
        chat.processes.single.status,
        accepted ? GatewayProcessStatus.exited : GatewayProcessStatus.running,
      );
      expect(host.calls.where((call) => call.$2 == 'process.kill').single.$3, {
        'session_id': 'a-runtime',
        'process_id': 'bg-1',
        'profile': 'a',
      });
      if (!accepted) expect(chat.processesError, isNotNull);
    });
  }

  test('stop remains single-flight across a list refresh', () async {
    host.listResponse = {
      'processes': [_process('bg-1', 'running')],
    };
    await controller.refreshProcesses(chat);
    final pending = host.pendingKill = Completer<Map<String, dynamic>>();
    final first = controller.stopProcess(chat, 'bg-1', canDispatch: () => true);
    expect(
      await controller.stopProcess(chat, 'bg-1', canDispatch: () => true),
      isFalse,
    );

    await controller.refreshProcesses(chat);
    host.listResponse = {
      'processes': [_process('bg-1', 'exited')],
    };
    pending.complete({'status': 'killed', 'session_id': 'bg-1'});
    expect(await first, isTrue);
  });

  test('late stop acknowledgement cannot affect replacement runtime', () async {
    host.listResponse = {
      'processes': [_process('bg-1', 'running')],
    };
    await controller.refreshProcesses(chat);
    final scopedPending = host.pendingKill = Completer<Map<String, dynamic>>();
    final scoped = controller.stopProcess(
      chat,
      'bg-1',
      canDispatch: () => true,
    );

    host.runtimeForResume['a'] = 'replacement-runtime';
    await controller.openSession(chat.key);
    scopedPending.complete({'status': 'killed', 'session_id': 'bg-1'});
    expect(await scoped, isFalse);
  });

  test(
    'dismissed exited rows stay hidden only while the server reports them',
    () async {
      host.listResponse = {
        'processes': [_process('done', 'exited'), _process('live', 'running')],
      };
      await controller.refreshProcesses(chat);
      controller.dismissProcess(chat, 'live');
      expect(chat.processes.map((item) => item.id), contains('live'));

      controller.dismissProcess(chat, 'done');
      expect(chat.processes.map((item) => item.id), isNot(contains('done')));
      await controller.refreshProcesses(chat);
      expect(chat.processes.map((item) => item.id), isNot(contains('done')));

      host.listResponse = {'processes': <Object>[]};
      await controller.refreshProcesses(chat);
      host.listResponse = {
        'processes': [_process('done', 'exited')],
      };
      await controller.refreshProcesses(chat);
      expect(chat.processes.single.id, 'done');
    },
  );

  test('acknowledged stop reports a failed authoritative refresh', () async {
    host.listResponse = {
      'processes': [_process('bg-1', 'running')],
    };
    await controller.refreshProcesses(chat);
    host.listFails = true;

    expect(
      await controller.stopProcess(chat, 'bg-1', canDispatch: () => true),
      isTrue,
    );
    expect(chat.processes.single.isRunning, isTrue);
    expect(chat.processesError, contains('acknowledged'));
  });

  test(
    'loop and heartbeat actions use the shared scoped control RPC',
    () async {
      expect(
        await controller.controlSession(
          chat,
          SessionControlAction.loopPause,
          canDispatch: () => true,
        ),
        isTrue,
      );
      expect(
        await controller.controlSession(
          chat,
          SessionControlAction.heartbeatClear,
          canDispatch: () => true,
        ),
        isTrue,
      );
      final actions = host.calls
          .where((call) => call.$2 == 'session.control')
          .map((call) => call.$3['action']);
      expect(actions, ['loop.pause', 'heartbeat.clear']);
      expect(chat.sessionControlNotice, 'Session controls updated.');
    },
  );
}
