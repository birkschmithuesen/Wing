import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_workspace_controller_test.dart' show Host;

class SensitivePromptHost extends Host {
  Completer<void>? responseDelay;
  Object? responseError;
  String? resumedRuntime;
  Object? openRequests = const [];
  bool includeOpenRequests = true;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway wrapped;
    wrapped = ProfileGateway(
      scope: scope,
      discover: discover,
      connect: () async {
        if (wrapped.onEvent != null) gateways[scope.profileName] = wrapped;
        await base.connect();
      },
      close: base.close,
      get: base.read,
      serverResponse: (id, result) async {
        final response = base.respondToRequest(id, result);
        await responseDelay?.future;
        final error = responseError;
        if (error != null) throw error;
        await response;
      },
      rpc: (method, params) async {
        final response = base.call(method, params);
        final result = await response;
        if (method == 'session.resume' && resumedRuntime != null) {
          return {
            ...result,
            'session_id': resumedRuntime,
            if (includeOpenRequests) 'open_requests': openRequests,
          };
        }
        if (method == 'session.resume') {
          return {
            ...result,
            if (includeOpenRequests) 'open_requests': openRequests,
          };
        }
        return result;
      },
    );
    return wrapped;
  }
}

void main() {
  late SensitivePromptHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late SharedPreferences preferences;
  late ProfileChat chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    host = SensitivePromptHost();
    controller = ProfileWorkspaceController(
      connectionIdentity: 'sensitive-prompt-test',
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
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'routes sudo and secret responses through their exact profile owner',
    () async {
      chat.composer.editText('composer marker');
      const cases = [
        (
          event: 'sudo',
          id: 'sudo-1',
          method: 'server.response',
          field: 'password',
        ),
        (
          event: 'secret',
          id: 'secret-1',
          method: 'server.response',
          field: 'value',
        ),
      ];

      for (final value in cases) {
        host.event('a', value.event, {
          'request_id': value.id,
          'env_var': 'FIXTURE_TOKEN',
          'prompt': 'Enter the fixture token',
        });
        final request = chat.runtime.secureInput!;

        await controller.respondSensitivePrompt(
          chat,
          'synthetic-secret',
          expectedRequest: request,
        );

        expect(host.calls.last.$2, value.method);
        expect(host.calls.last.$3, {
          'id': value.id,
          'result': {'value': 'synthetic-secret'},
        });
        expect(chat.runtime.secureInput, isNull);
      }

      expect(chat.composer.observation.text, 'composer marker');
      expect(
        chat.reading.messages.toString(),
        isNot(contains('synthetic-secret')),
      );
      expect(chat.runtime.error, isNull);
      expect(
        [
          for (final key in preferences.getKeys()) preferences.get(key),
        ].toString(),
        isNot(contains('synthetic-secret')),
      );
    },
  );

  test('cancel sends the official empty value', () async {
    host.event('a', 'secret', {
      'request_id': 'secret-cancel',
      'env_var': 'FIXTURE_TOKEN',
    });
    final request = chat.runtime.secureInput!;

    await controller.respondSensitivePrompt(chat, '', expectedRequest: request);

    expect(host.calls.last.$3, {
      'id': 'secret-cancel',
      'result': {'value': ''},
    });
  });

  test(
    'routes the three vault response contracts and normalizes codes',
    () async {
      final login = jsonEncode({
        'identifier': 'person@example.test',
        'password': 'synthetic-password',
      });
      final cases = [
        (
          event: 'vault.unlock_prompt',
          data: <String, dynamic>{
            'request_id': 'unlock-1',
            'backend': 'onepassword',
            'display_name': '1Password',
          },
          method: 'server.response',
          field: 'password',
          input: 'synthetic-password',
          output: 'synthetic-password',
        ),
        (
          event: 'vault.code',
          data: <String, dynamic>{
            'request_id': 'code-1',
            'site': 'Example',
            'hint': 'Authenticator code',
          },
          method: 'server.response',
          field: 'code',
          input: '123 456-78',
          output: '12345678',
        ),
        (
          event: 'vault.save_login',
          data: <String, dynamic>{
            'request_id': 'save-1',
            'origin': 'https://example.test',
            'site': 'Example',
          },
          method: 'server.response',
          field: 'login',
          input: login,
          output: login,
        ),
      ];

      for (final value in cases) {
        host.event('a', value.event, value.data);
        final request = chat.runtime.secureInput!;

        await controller.respondSensitivePrompt(
          chat,
          value.input,
          expectedRequest: request,
        );

        expect(host.calls.last.$2, value.method);
        expect(host.calls.last.$3, {
          'id': value.data['request_id'],
          'result': {'value': value.output},
        });
      }

      expect(
        chat.reading.messages.toString(),
        isNot(contains('synthetic-password')),
      );
      expect(
        [
          for (final key in preferences.getKeys()) preferences.get(key),
        ].toString(),
        isNot(contains('synthetic-password')),
      );
    },
  );

  test('vault cancel values are explicit empty strings', () async {
    const cases = [
      (
        event: 'vault.unlock_prompt',
        method: 'server.response',
        field: 'password',
      ),
      (event: 'vault.code', method: 'server.response', field: 'code'),
      (event: 'vault.save_login', method: 'server.response', field: 'login'),
    ];

    for (final value in cases) {
      host.event('a', value.event, {'request_id': value.event});
      final request = chat.runtime.secureInput!;
      await controller.respondSensitivePrompt(
        chat,
        '',
        expectedRequest: request,
      );

      expect(host.calls.last.$2, value.method);
      expect(host.calls.last.$3['result'], {'value': ''});
    }
  });

  test('vault expiry clears only its matching request ID and kind', () {
    host.event('a', 'vault.code', {
      'request_id': 'current-code',
      'site': 'Example',
    });

    host.event('a', 'request.cancel', {
      'id': 'older-code',
      'method': 'vault.code',
      'reason': 'timeout',
    });
    expect(chat.runtime.secureInput?.requestId, 'current-code');

    host.event('a', 'request.cancel', {
      'id': 'current-code',
      'method': 'vault.unlock_prompt',
      'reason': 'timeout',
    });
    expect(chat.runtime.secureInput?.requestId, 'current-code');

    host.event('a', 'request.cancel', {
      'id': 'current-code',
      'method': 'vault.code',
      'reason': 'timeout',
    });
    expect(chat.runtime.secureInput, isNull);
    expect(chat.runtime.secureResponding, isFalse);
  });

  test('an older response cannot clear a newer pending request', () async {
    host.responseDelay = Completer<void>();
    host.event('a', 'sudo', {'request_id': 'old'});
    final old = chat.runtime.secureInput!;
    final response = controller.respondSensitivePrompt(
      chat,
      'synthetic-password',
      expectedRequest: old,
    );
    await Future<void>.delayed(Duration.zero);

    host.event('a', 'secret', {'request_id': 'new', 'env_var': 'NEW_TOKEN'});
    host.responseDelay!.complete();
    await response;

    expect(chat.runtime.secureInput?.requestId, 'new');
    expect(chat.runtime.secureResponding, isFalse);
  });

  test('disconnect retains metadata but disables response state', () {
    host.event('a', 'sudo', {'request_id': 'waiting'});

    host.gateways['a']!.onConnectionChanged!(false);

    expect(chat.runtime.secureInput?.requestId, 'waiting');
    expect(chat.runtime.secureResponding, isFalse);
    expect(chat.runtime.reconnecting, isTrue);
  });

  test(
    'resume restores a secure form from open_requests for its runtime',
    () async {
      host.openRequests = [
        {
          'id': 'foreign',
          'method': 'secret',
          'params': {'session_id': 'other-runtime', 'env_var': 'WRONG_TOKEN'},
        },
        {
          'id': 'recovered-secret',
          'method': 'secret',
          'params': {
            'session_id': chat.runtime.runtimeId,
            'env_var': 'FIXTURE_TOKEN',
            'prompt': 'Enter the fixture token',
          },
        },
      ];
      await controller.reconnect(chat.key.workspace);
      expect(chat.runtime.secureInput?.requestId, 'recovered-secret');
      expect(chat.runtime.secureInput?.title, 'FIXTURE_TOKEN');
      expect(chat.runtime.needsInput, isTrue);
      host.openRequests = [];
      await controller.reconnect(chat.key.workspace);
      expect(chat.runtime.secureInput, isNull);
    },
  );

  test(
    'a changed runtime cannot restore another runtime secure request',
    () async {
      host.event('a', 'sudo', {'request_id': 'old'});
      host.openRequests = [
        {
          'id': 'old',
          'method': 'sudo',
          'params': {'session_id': chat.runtime.runtimeId},
        },
      ];
      host.resumedRuntime = 'new-runtime';
      await controller.reconnect(chat.key.workspace);
      expect(chat.runtime.secureInput, isNull);
    },
  );

  test('partial session info retains a live secure request', () {
    host.event('a', 'secret', {'request_id': 'live'});
    host.event('a', 'session.info', {'model': 'fixture-model'});
    expect(chat.runtime.secureInput?.requestId, 'live');
  });

  test('a snapshot during secure submission cannot strand the form', () async {
    host.event('a', 'secret', {'request_id': 'answering'});
    host.responseDelay = Completer<void>();
    final response = controller.respondSensitivePrompt(
      chat,
      'synthetic-secret',
      expectedRequest: chat.runtime.secureInput!,
    );
    host.event('a', 'session.info', {
      'open_requests': [
        {
          'id': 'answering',
          'method': 'secret',
          'params': {'session_id': chat.runtime.runtimeId},
        },
      ],
    });
    host.responseDelay!.complete();
    await response;
    expect(chat.runtime.secureInput, isNull);
    expect(chat.runtime.secureResponding, isFalse);
  });

  test(
    'session info updates open requests without resetting an in-flight answer',
    () async {
      Map<String, dynamic> snapshot(String site) => {
        'open_requests': [
          {
            'id': 'code',
            'method': 'vault.code',
            'params': {'session_id': chat.runtime.runtimeId, 'site': site},
          },
        ],
      };
      host.event('a', 'session.info', snapshot('Example'));
      expect(chat.runtime.secureInput?.requestId, 'code');
      host.responseDelay = Completer<void>();
      final answering = controller.respondSensitivePrompt(
        chat,
        'synthetic-code',
        expectedRequest: chat.runtime.secureInput!,
      );
      expect(chat.runtime.secureResponding, isTrue);
      host.event('a', 'session.info', snapshot('Updated Example'));
      expect(chat.runtime.secureResponding, isTrue);
      host.event('a', 'session.info', {'open_requests': [], 'running': false});
      expect(chat.runtime.secureInput, isNull);
      expect(chat.runtime.secureResponding, isFalse);
      expect(chat.runtime.executionActive, isFalse);
      host.responseDelay!.complete();
      await answering;
      expect(chat.runtime.secureResponding, isFalse);
      expect(
        chat.reading.questionHistory!.questions.last.status.name,
        'answered',
      );
    },
  );

  test('completed secure attention and reply keep the terminal turn', () async {
    host.event('a', 'message.start');
    host.event('a', 'message.complete', {'text': 'Finished'});
    expect(chat.runtime.execution, ChatExecution.completed);
    host.event('a', 'secret', {'request_id': 'completed-secret'});
    expect(chat.listObservation.needsInput, isTrue);
    expect(chat.runtime.execution, ChatExecution.completed);
    await controller.respondSensitivePrompt(
      chat,
      'synthetic-secret',
      expectedRequest: chat.runtime.secureInput!,
    );
    expect(chat.runtime.secureInput, isNull);
    expect(chat.runtime.execution, ChatExecution.completed);
    expect(chat.runtime.blocksTurnAdmission, isFalse);
    expect(
      host.calls.where((call) => call.$2 == 'server.response'),
      hasLength(1),
    );
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
  });

  test(
    'secure response data in snapshots is rejected without persisting it',
    () async {
      host.openRequests = [
        {
          'id': 'bad',
          'method': 'secret',
          'params': {
            'session_id': chat.runtime.runtimeId,
            'value': 'synthetic-secret-must-not-persist',
          },
        },
      ];
      await controller.reconnect(chat.key.workspace);
      expect(chat.runtime.secureInput, isNull);
      expect(
        [
          for (final key in preferences.getKeys()) preferences.get(key),
        ].toString(),
        isNot(contains('synthetic-secret-must-not-persist')),
      );
    },
  );

  test(
    'a timeout during submission expires without claiming acceptance',
    () async {
      host.responseDelay = Completer<void>();
      host.event('a', 'secret', {
        'request_id': 'expired',
        'env_var': 'FIXTURE_TOKEN',
      });
      final answering = controller.respondSensitivePrompt(
        chat,
        'synthetic-secret',
        expectedRequest: chat.runtime.secureInput!,
      );
      host.event('a', 'request.cancel', {
        'id': 'expired',
        'method': 'secret',
        'reason': 'timeout',
      });
      expect(chat.runtime.secureInput, isNull);
      expect(chat.runtime.secureResponding, isFalse);
      host.responseError = StateError('request expired');
      host.responseDelay!.complete();
      await expectLater(answering, throwsStateError);
      expect(
        chat.reading.questionHistory!.questions.last.status.name,
        'expired',
      );
    },
  );

  test(
    'a transport failure retains metadata without storing its error',
    () async {
      host.responseError = StateError('server echoed synthetic-secret');
      host.event('a', 'secret', {
        'request_id': 'retry',
        'env_var': 'FIXTURE_TOKEN',
      });
      final request = chat.runtime.secureInput!;

      await expectLater(
        controller.respondSensitivePrompt(
          chat,
          'synthetic-secret',
          expectedRequest: request,
        ),
        throwsStateError,
      );

      expect(chat.runtime.secureInput, same(request));
      expect(chat.runtime.secureResponding, isFalse);
      expect(chat.runtime.error, isNull);
      expect(
        chat.reading.messages.toString(),
        isNot(contains('synthetic-secret')),
      );
    },
  );
}
