import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_workspace_controller_test.dart' show Host;

Map<String, dynamic> approval(String id, {String? serverId}) => {
  'request_id': id,
  'server_request_id': ?serverId,
  'command': 'echo $id',
  'choices': ['once', 'deny'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late List<ProfileNotification> alerts;
  late List<ProfileInputNotification> inputSnapshots;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = Host();
    alerts = [];
    inputSnapshots = [];
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      connectionIdentity: 'host',
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Home',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      onAttention: (notification) async => alerts.add(notification),
      onNotificationInputs: (snapshot) async => inputSnapshots.add(snapshot),
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'unconfirmed feedback stays with its request when the FIFO advances',
    () async {
      host.pendingApprovals = [approval('one'), approval('two')];
      host.event('a', 'approval', approval('one'));
      host.event('a', 'approval', approval('two'));
      host.approvalFails = true;
      await expectLater(
        controller.approve(chat, 'once', requestId: 'one'),
        throwsA(isA<TimeoutException>()),
      );
      host.event('a', 'approval', approval('one'));
      await Future<void>.delayed(Duration.zero);
      expect(inputSnapshots.last.inputs.first.error, contains('not confirmed'));
      host.pendingApprovals = [approval('two')];
      host.notificationActiveSessions = [
        {'id': chat.runtime.runtimeId, 'session_key': chat.key.sessionId},
      ];
      host.notificationReplay = {'open_requests': [], 'latest_seq': 1};
      // A lost reply retires canonical authority until a fresh resume arrives.
      expect(inputSnapshots.last.inputs, hasLength(2));
      await controller.reconnect(chat.key.workspace);
      await controller.reconcileNotificationRequests({chat.key});
      await Future<void>.delayed(Duration.zero);
      expect(inputSnapshots.last.inputs, hasLength(1));
      expect(inputSnapshots.last.inputs.single.focus.id, 'two');
      expect(inputSnapshots.last.inputs.single.error, isNull);
      expect(
        host.calls.where((call) => call.$2 == 'approval.respond'),
        hasLength(1),
      );
      expect(
        host.calls.where((call) => call.$2 == 'session.resume'),
        isNotEmpty,
      );
    },
  );

  test('expired request.answer is not successful approval', () async {
    host.event('a', 'approval', approval('one', serverId: 'srq-one'));
    host.clarifyResult = {'status': 'expired'};
    await expectLater(
      controller.approve(chat, 'once', requestId: 'one'),
      throwsStateError,
    );
    expect(chat.runtime.approval?.requestId, 'one');
    expect(chat.runtime.decisionError, contains('not confirmed'));
  });

  test(
    'duplicate live delivery updates metadata without re-alerting or reordering',
    () {
      host.event('a', 'approval', approval('one', serverId: 'srq-one'));
      host.event('a', 'approval', approval('two', serverId: 'srq-two'));
      host.event('a', 'approval', approval('one', serverId: 'srq-replay'));
      expect(chat.runtime.approvals, hasLength(2));
      expect(chat.runtime.approval?.serverRequestId, 'srq-replay');
      expect(
        (chat.runtime.approvalPosition, chat.runtime.approvalTotal),
        (1, 2),
      );
      expect(alerts, hasLength(2));
    },
  );

  test(
    'approval arriving during a response survives and keeps input status',
    () async {
      host.event('a', 'approval', approval('one'));
      host.approvalDelay = Completer<void>();
      final response = controller.approve(
        chat,
        'once',
        requestId: chat.runtime.approval!.requestId,
      );
      host.event('a', 'approval', approval('two'));
      await expectLater(
        controller.approve(
          chat,
          'once',
          requestId: chat.runtime.approval!.requestId,
        ),
        throwsStateError,
      );
      host.approvalDelay!.complete();
      await response;
      expect(chat.runtime.approval?.requestId, 'two');
      expect(
        (chat.runtime.approvalPosition, chat.runtime.approvalTotal),
        (2, 2),
      );
      expect(chat.runtime.needsInput, isTrue);
      expect(chat.runtime.approvalResponding, isFalse);
    },
  );

  test('cancellation removes only its matching server request', () {
    host.event('a', 'approval', approval('one', serverId: 'srq-one'));
    host.event('a', 'approval', approval('two', serverId: 'srq-two'));
    host.event('a', 'request.cancel', {
      'id': 'unrelated',
      'method': 'approval',
    });
    expect(chat.runtime.approvals, hasLength(2));
    host.event('a', 'request.cancel', {'id': 'srq-one', 'method': 'approval'});
    expect(chat.runtime.approval?.requestId, 'two');
    expect(chat.runtime.needsInput, isTrue);
    host.event('a', 'request.cancel', {
      'id': 'srq-two',
      'method': 'approval',
      'reason': 'timeout',
    });
    expect(chat.runtime.approval, isNull);
    expect(chat.runtime.execution, ChatExecution.idle);
    expect(
      chat.reading.questionHistory!.question('approval/two')!.status,
      HermesQuestionStatus.expired,
    );
    expect(chat.runtime.error, isNull);
  });

  test(
    'resume restores every pending approval and preserves live reply ownership',
    () async {
      host.pendingApprovals = [approval('one'), approval('two')];
      host.approvalOpenRequests = [
        {
          'method': 'approval',
          'id': 'srq-one',
          'params': {...approval('one'), 'session_id': chat.runtime.runtimeId},
        },
      ];
      await controller.openSession(chat.key);
      await Future<void>.delayed(Duration.zero);
      expect(chat.runtime.approvals, hasLength(2));
      expect(chat.runtime.approval?.serverRequestId, 'srq-one');
      expect(chat.runtime.approvalTotal, 2);
      expect(alerts, isEmpty);
      // The next authoritative read must not clobber the live request metadata.
      await controller.openSession(chat.key);
      await Future<void>.delayed(Duration.zero);
      expect(chat.runtime.approval?.serverRequestId, 'srq-one');
      expect(alerts, isEmpty);
    },
  );

  test(
    'response reads pending queue to recover an approval whose delivery was missed',
    () async {
      host.pendingApprovals = [approval('one'), approval('two')];
      host.event('a', 'approval', approval('one'));
      await controller.approve(
        chat,
        'once',
        requestId: chat.runtime.approval!.requestId,
      );
      expect(chat.runtime.approval?.requestId, 'two');
      expect(chat.runtime.needsInput, isTrue);
      await controller.approve(
        chat,
        'deny',
        requestId: chat.runtime.approval!.requestId,
      );
      expect(chat.runtime.approval, isNull);
      expect(chat.runtime.execution, ChatExecution.idle);
    },
  );

  test('stale pending read cannot erase a newer live approval', () async {
    host.pendingApprovals = [];
    host.pendingApprovalDelay = Completer<void>();
    host.event('a', 'approval', approval('one'));
    final response = controller.approve(
      chat,
      'once',
      requestId: chat.runtime.approval!.requestId,
    );
    await Future<void>.delayed(Duration.zero);
    host.pendingApprovals = [approval('two')];
    host.event('a', 'approval', approval('two'));
    host.pendingApprovalDelay!.complete();
    await response;
    expect(chat.runtime.approval?.requestId, 'two');
    expect(chat.runtime.needsInput, isTrue);
  });

  test('a failed response retains the whole queue for retry', () async {
    host.event('a', 'approval', approval('one'));
    host.event('a', 'approval', approval('two'));
    host.approvalFails = true;
    await expectLater(
      controller.approve(
        chat,
        'once',
        requestId: chat.runtime.approval!.requestId,
      ),
      throwsException,
    );
    expect(chat.runtime.approvals.map((r) => r.requestId), ['one', 'two']);
    expect(chat.runtime.approvalResponding, isFalse);
  });

  test('a stale button cannot approve the next command', () async {
    host.event('a', 'approval', approval('one', serverId: 'srq-one'));
    host.event('a', 'approval', approval('two'));
    host.event('a', 'request.cancel', {'id': 'srq-one', 'method': 'approval'});
    await expectLater(
      controller.approve(chat, 'once', requestId: 'one'),
      throwsStateError,
    );
    expect(chat.runtime.approval?.requestId, 'two');
    expect(host.calls.where((c) => c.$2 == 'approval.respond'), isEmpty);
  });

  test('a newer turn result cannot erase unresolved approvals', () async {
    host.event('a', 'approval', approval('one'));
    host.event('a', 'approval', approval('two'));
    host.event('a', 'message.complete', {'text': 'Done'});
    await Future<void>.delayed(Duration.zero);
    expect(chat.runtime.approvals, hasLength(2));
    expect(chat.runtime.approvalTotal, 2);
  });
  test(
    'completed approval attention and resolution preserve terminal execution',
    () async {
      host.event('a', 'message.start');
      host.event('a', 'message.complete', {'text': 'Finished'});
      expect(chat.runtime.execution, ChatExecution.completed);
      final source = approval('completed-request');
      final choices = <String>['once', 'deny'];
      source['choices'] = choices;
      host.event('a', 'approval', source);
      final retained = chat.runtime.approval!;
      source['command'] = 'Caller rewrite';
      choices.clear();
      expect(retained.request.command, 'echo completed-request');
      expect(retained.request.choices.map((choice) => choice.wireValue), [
        'once',
        'deny',
      ]);
      expect(() => retained.request.choices.clear(), throwsUnsupportedError);
      expect(chat.listObservation.needsInput, isTrue);
      expect(chat.runtime.execution, ChatExecution.completed);
      await controller.approve(chat, 'once', requestId: retained.requestId);
      expect(chat.runtime.approval, isNull);
      expect(chat.runtime.execution, ChatExecution.completed);
      expect(chat.runtime.blocksTurnAdmission, isFalse);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test(
    'already resolved closes the prompt without claiming this decision',
    () async {
      host.event('a', 'approval', approval('one'));
      host.approvalAlreadyResolved = true;
      await controller.approve(chat, 'once', requestId: 'one');
      expect(chat.runtime.approval, isNull);
      expect(chat.runtime.decisionError, isNull);
      expect(
        chat.reading.questionHistory!.question('native/0/approval/one')!.status,
        HermesQuestionStatus.closed,
      );
    },
  );

  test(
    'reconciliation clears a desktop decision with a corroborated runtime',
    () async {
      host.pendingApprovals = [approval('one')];
      host.event('a', 'approval', approval('one'));
      await Future<void>.delayed(Duration.zero);
      host.pendingApprovals = [];
      host.notificationActiveSessions = [
        {
          'id': chat.runtime.runtimeId,
          'session_key': chat.key.sessionId,
          'status': 'working',
          'profile': 'a',
        },
      ];
      host.notificationReplay = {
        'open_requests': [],
        'events': [],
        'latest_seq': 1,
      };
      await controller.reconcileNotificationRequests({chat.key});
      expect(chat.runtime.approval, isNull);
    },
  );

  test(
    'unknown runtime emptiness cannot clear an outstanding request',
    () async {
      host.event('a', 'approval', approval('one'));
      host.notificationActiveSessions = [];
      host.notificationReplay = {'open_requests': []};
      host.calls.clear();
      await controller.reconcileNotificationRequests({chat.key});
      expect(chat.runtime.approval?.requestId, 'one');
      expect(
        host.calls.where((call) => call.$2 == 'session.events.since'),
        isEmpty,
      );
    },
  );
}
