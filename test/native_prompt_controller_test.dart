import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;
import 'support/canonical_gateway_fixture.dart';

class _NativeHost extends Host {
  final responses = <Map<String, dynamic>>[];
  Completer<void>? answerGate;
  String answerStatus = 'resolved';

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: () async {
        gateways[scope.profileName] = gateway;
        await base.connect();
      },
      close: base.close,
      get: base.read,
      rpc: (method, params) async {
        if (method != 'clarify.respond') return base.call(method, params);
        expect(params.keys.toSet(), {
          'session_id',
          'profile',
          'execution_generation',
          'prompt_id',
          'answer',
        });
        expect(params['execution_generation'], isA<int>());
        responses.add(Map.of(params));
        await answerGate?.future;
        return {'status': answerStatus, 'prompt_id': params['prompt_id']};
      },
    );
    return gateway;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences preferences;
  late ProfileChat chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = await SharedPreferences.getInstance();
    preferences = AppPreferences(storage);
    host = _NativeHost();
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'canonical-native-prompts',
      preferences: storage,
      appPreferences: preferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
  });
  tearDown(() {
    controller.dispose();
    preferences.dispose();
  });

  void prompt(String kind, String id, {int generation = 0}) => host.event(
    'a',
    '$kind.request',
    {
      'kind': kind,
      'prompt_id': id,
      'execution_generation': generation,
      if (kind == 'approval') ...{
        'command': 'echo reviewed',
        'description': 'Review this command',
      },
      if (kind == 'clarify') 'question': 'Which result?',
      'choices': kind == 'approval' ? ['once', 'deny'] : ['Summary', 'Details'],
    },
  );

  void generation(int value) {
    controller.current!.gateway.canonical.snapshot({
      ...canonicalSnapshotFields,
      'session_id': chat.runtime.runtimeId,
      'stored_session_id': chat.key.sessionId,
      'execution_generation': value,
    });
  }

  test('native approval sends exact prompt identity and generation', () async {
    prompt('approval', 'approve-1');
    expect(chat.runtime.approval!.nativeGeneration, 0);
    await controller.approve(chat, 'once', requestId: 'approve-1');
    expect(host.calls.lastWhere((call) => call.$2 == 'approval.respond').$3, {
      'profile': 'a',
      'session_id': chat.runtime.runtimeId,
      'prompt_id': 'approve-1',
      'execution_generation': 0,
      'choice': 'once',
    });
    expect(chat.runtime.approval, isNull);
  });

  test('an old generation cannot approve a newer turn', () async {
    prompt('approval', 'approve-1');
    generation(1);
    await expectLater(
      controller.approve(chat, 'once', requestId: 'approve-1'),
      throwsStateError,
    );
    expect(host.calls.where((call) => call.$2 == 'approval.respond'), isEmpty);
  });

  test(
    'native clarification uses its owner while a newer draft survives',
    () async {
      prompt('clarify', 'clarify-1');
      await controller.updateDraft(chat, 'Summary');
      host.answerGate = Completer<void>();
      final answering = controller.answerWithComposer(chat);
      await Future<void>.delayed(Duration.zero);
      expect(host.responses.single['answer'], 'Summary');
      expect(host.responses.single['prompt_id'], 'clarify-1');
      await controller.updateDraft(chat, 'A newer independent draft');
      host.answerGate!.complete();
      await answering;
      expect(chat.runtime.pendingQuestion, isNull);
      expect(chat.composer.observation.text, 'A newer independent draft');
    },
  );

  test(
    'settlement before the native answer ACK does not strand the old draft',
    () async {
      prompt('clarify', 'clarify-1');
      await controller.updateDraft(chat, 'Summary');
      host.answerGate = Completer<void>();
      final answering = controller.answerWithComposer(chat);
      await Future<void>.delayed(Duration.zero);
      host.event('a', 'clarify.settled', {
        'prompt_id': 'clarify-1',
        'execution_generation': 0,
      });
      host.answerGate!.complete();
      await answering;
      expect(chat.composer.observation.text, isEmpty);
      expect(chat.runtime.pendingQuestion, isNull);
    },
  );

  test(
    'already-resolved native clarification keeps the unsent composer text',
    () async {
      prompt('clarify', 'clarify-1');
      await controller.updateDraft(chat, 'My intended answer');
      host.answerStatus = 'already_resolved';
      await controller.answerWithComposer(chat);
      expect(chat.runtime.pendingQuestion, isNull);
      expect(chat.composer.observation.text, 'My intended answer');
    },
  );

  test(
    'native settlement cannot close a newer generation with the same ID',
    () async {
      prompt('clarify', 'reused');
      generation(1);
      prompt('clarify', 'reused', generation: 1);
      host.event('a', 'clarify.settled', {
        'prompt_id': 'reused',
        'execution_generation': 0,
      });
      expect(chat.runtime.questions!.nativeGeneration, 1);
      expect(chat.runtime.pendingQuestion!.requestId, 'reused');
    },
  );

  test(
    'JSON-RPC server approvals keep their separate response contract',
    () async {
      host.event('a', 'approval', {
        'request_id': 'queue-entry',
        'server_request_id': 'rpc-request',
        'command': 'echo reviewed',
        'choices': ['once', 'deny'],
      });
      await controller.approve(chat, 'once', requestId: 'queue-entry');
      expect(
        host.calls.where((call) => call.$2 == 'approval.respond'),
        isEmpty,
      );
      expect(host.calls.lastWhere((call) => call.$2 == 'request.answer').$3, {
        'profile': 'a',
        'id': 'rpc-request',
        'result': {'choice': 'once'},
      });
    },
  );
}
