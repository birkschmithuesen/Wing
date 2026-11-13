import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_workspace_controller_test.dart' show Host;

class ReopenHost extends Host {
  Map<String, dynamic> pending = {};
  bool loseSubmitAcknowledgement = false;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: base.connect,
      close: base.close,
      get: base.read,
      rpc: (method, params) async {
        final result = await base.call(method, params);
        if (method == 'approval.pending' && pending['prompts'] is List) {
          return {
            'approvals': [
              for (final prompt
                  in (pending['prompts'] as List).whereType<Map>())
                if (prompt['kind'] == 'approval')
                  {...prompt, 'request_id': prompt['prompt_id']}
                    ..remove('prompt_id')
                    ..remove('kind')
                    ..remove('execution_generation'),
            ],
          };
        }
        if (method == 'prompt.submit' && loseSubmitAcknowledgement) {
          throw TimeoutException('Acknowledgement lost');
        }
        return {...result, if (method == 'session.resume') ...pending};
      },
    );
  }
}

void main() {
  late ReopenHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = ReopenHost();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'reopen',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'reopening a cached chat reads current run and pending-input state',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('An unsent follow-up');
      controller.showList();
      host.pending = {
        'prompts': [
          {
            'kind': 'approval',
            'prompt_id': 'reopened-approval',
            'execution_generation': 0,
            'command': 'example',
            'choices': ['once', 'deny'],
          },
        ],
      };
      await controller.openSession(chat.key);
      expect(chat.runtime.needsInput, isTrue);
      expect(chat.runtime.approval?.request.command, 'example');
      expect(chat.composer.observation.text, 'An unsent follow-up');

      controller.showList();
      host.pendingApprovals = [];
      host.pending = {
        'open_requests': [
          {
            'id': 'q',
            'method': 'clarify',
            'params': {
              'session_id': chat.runtime.runtimeId,
              'question': 'Which result?',
            },
          },
        ],
      };
      await controller.openSession(chat.key);
      expect(chat.runtime.approval, isNull);
      expect(chat.runtime.questions?.questions.first.requestId, 'q');
      expect(chat.runtime.needsInput, isTrue);

      controller.showList();
      host.pending = {};
      host.running = false;
      await controller.openSession(chat.key);
      expect(chat.runtime.questions, isNull);
      expect(chat.runtime.blocksTurnAdmission, isFalse);
      final completed = chat.reading.messages
          .where((row) => row['id'] == 1 && row['role'] == 'assistant')
          .single;
      expect(completed['content'], 'a completed');
      final questions = chat.reading.questionHistory!.questions;
      expect(
        questions.map((q) => q.requestId),
        containsAll(['reopened-approval', 'q']),
      );
      expect(
        questions.every((q) => q.status == HermesQuestionStatus.closed),
        isTrue,
      );
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test(
    'a lost submit acknowledgement replays one identity without duplicate admission',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('Send this once');
      host.loseSubmitAcknowledgement = true;
      await controller.send(chat);
      expect(chat.runtime.reconnecting, isTrue);
      host.loseSubmitAcknowledgement = false;
      await controller.reconnect(chat.key.workspace);
      expect(chat.runtime.execution, ChatExecution.running);
      final submissions = host.calls
          .where((c) => c.$2 == 'prompt.submit')
          .toList();
      expect(submissions, hasLength(2));
      expect(submissions.last.$3, submissions.first.$3);
      expect(host.canonicalAdmissions, hasLength(1));
      expect(chat.composer.observation.submissionUncertain, isFalse);
    },
  );

  test(
    'resume restores unanswered batch questions from open_requests',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.pendingApprovals = [];
      host.pending = {
        'open_requests': [
          {
            'id': 'foreign',
            'method': 'clarify',
            'params': {
              'session_id': 'other-runtime',
              'question': 'Wrong owner',
            },
          },
          {
            'id': 'batch-request',
            'method': 'clarify',
            'params': {
              'session_id': chat.runtime.runtimeId,
              'questions': [
                {'qid': 'q0', 'question': 'Which room?'},
                {'qid': 'q1', 'question': 'What budget?'},
              ],
              'answers': {'q0': 'Bedroom'},
            },
          },
        ],
      };
      await controller.reconnect(chat.key.workspace);
      expect(chat.runtime.needsInput, isTrue);
      expect(chat.runtime.pendingQuestion!.question, 'What budget?');
      await controller.clarify(chat, '250');
      final reply = host.calls.last;
      expect(reply.$2, 'clarify.lock');
      expect(reply.$3['request_id'], 'batch-request');
      expect(reply.$3['question_id'], 'q1');
      expect(reply.$3['answer'], '250');
    },
  );

  test(
    'reopening does not replace a submission awaiting acknowledgement',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      await controller.updateDraft(chat, 'Held outgoing prompt');
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      controller.showList();
      await controller.openSession(chat.key);
      expect(controller.current!.chat, same(chat));
      expect(chat.composer.observation.sending, isTrue);
      expect(host.calls.where((c) => c.$2 == 'session.resume'), isEmpty);
      host.promptSubmitDelay!.complete();
      await sending;
    },
  );
}
