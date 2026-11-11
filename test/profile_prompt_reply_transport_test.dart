import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_workspace_controller_test.dart' show Host;

void main() {
  for (final kind in [
    'single',
    'batch',
    'sudo',
    'secret',
    'vault.unlock_prompt',
    'vault.save_login',
    'vault.code',
    'approval',
  ]) {
    test(
      '$kind reply passes strict validation over the real gateway socket',
      () async {
        final isSecure = !{'single', 'batch', 'approval'}.contains(kind);
        final inputValue = kind == 'vault.save_login'
            ? jsonEncode({
                'identifier': 'fixture@example.test',
                'password': 'dummy-fixture-value',
              })
            : kind == 'vault.code'
            ? '123 456-78'
            : 'dummy-fixture-value';
        final replyValue = kind == 'vault.code' ? '12345678' : inputValue;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final connected = Completer<WebSocket>();
        final advertised = Completer<void>();
        final replies = <Map<String, dynamic>>[];
        final secretReply = Completer<void>();
        final subscription = server.listen((request) async {
          if (!WebSocketTransformer.isUpgradeRequest(request)) {
            request.response.write(
              'window.__HERMES_SESSION_TOKEN__="fixture-token";',
            );
            await request.response.close();
            return;
          }
          final socket = await WebSocketTransformer.upgrade(request);
          connected.complete(socket);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'gateway.ready',
                'payload': {'session_authority': true},
              },
            }),
          );
          socket.listen((raw) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            final method = frame['method'];
            if (method == null) {
              replies.add(frame);
              secretReply.complete();
              return;
            }
            final params = frame['params'] as Map;
            if (method == 'client.capabilities') {
              expect(params, {'server_requests': true});
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': frame['id'],
                  'result': {'canonical_clarify_batch': true},
                }),
              );
              advertised.complete();
              return;
            }
            if (method == 'session.list') {
              expect(params, {'profile': 'a', 'limit': 1});
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': frame['id'],
                  'result': {'sessions': []},
                }),
              );
              return;
            }
            replies.add(frame);
            if (isSecure && method == 'request.answer') {
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': frame['id'],
                  'result': {'status': 'expired'},
                }),
              );
              secretReply.complete();
              return;
            }
            // Upstream contracts/prompt_voice.py: neither reply is session-scoped.
            final allowed = method == 'clarify.lock'
                ? {'request_id', 'question_id', 'answer', 'profile'}
                : {'id', 'result', 'profile'};
            final unknown = params.keys.where((key) => !allowed.contains(key));
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                if (unknown.isNotEmpty)
                  'error': {
                    'code': 4000,
                    'message':
                        'invalid params: ${unknown.first}: Extra inputs are not permitted',
                  }
                else
                  'result': {
                    'status': 'ok',
                    if (method == 'clarify.lock') 'remaining': [],
                  },
              }),
            );
          });
        });
        addTearDown(() async {
          await subscription.cancel();
          await server.close(force: true);
        });
        SharedPreferences.setMockInitialValues({});
        final host = Host();
        final delivered = Completer<void>();
        final secondApprovalDelivered = Completer<void>();
        final connection = SavedConnection(
          id: 'reply-transport',
          label: 'Fixture',
          host: '127.0.0.1',
          port: server.port,
          dashboardPortOverride: server.port,
          apiKey: '',
        );
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: connection,
            dashboardOAuth: null,
          ),
          connectionIdentity: 'reply-transport',
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: (WorkspaceScope scope) {
            final base = host.gateway(scope);
            final wire = ProfileGateway.forConnection(
              ConnectionAccess(connection: connection, dashboardOAuth: null),
              scope,
            );
            final gateway = ProfileGateway(
              scope: scope,
              discover: base.discover,
              get: base.read,
              connect: wire.connect,
              close: wire.close,
              serverResponse: wire.respondToRequest,
              rpc: (method, params) =>
                  {'clarify.lock', 'request.answer'}.contains(method)
                  ? wire.call(method, params)
                  : base.call(method, params),
            );
            wire.onEvent = (event) {
              gateway.onEvent?.call(event);
              if (event.data['request_id'] == 'queue-second' &&
                  !secondApprovalDelivered.isCompleted) {
                secondApprovalDelivered.complete();
              }
              if (!delivered.isCompleted) delivered.complete();
            };
            return gateway;
          },
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        final chat = await controller.createChat(canDispatch: () => true);
        final socket = await connected.future;
        await advertised.future.timeout(const Duration(seconds: 2));
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'srq-fixture',
            'method': kind == 'approval'
                ? 'approval'
                : isSecure
                ? kind
                : 'clarify',
            'params': {
              'session_id': chat.runtime.runtimeId,
              if (kind == 'approval') ...{
                'request_id': 'queue-fixture',
                'command': 'echo fixture',
                'choices': ['once', 'deny'],
              },
              if (kind == 'batch')
                'questions': [
                  {
                    'qid': 'q0',
                    'question': 'Which room?',
                    'choices': ['Bedroom'],
                  },
                ]
              else if (kind == 'single')
                'question': 'Which room?'
              else
                'env_var': 'FIXTURE_TOKEN',
            },
          }),
        );
        if (kind == 'approval') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 'srq-second',
              'method': 'approval',
              'params': {
                'session_id': chat.runtime.runtimeId,
                'request_id': 'queue-second',
                'command': 'echo second',
                'choices': ['once', 'deny'],
              },
            }),
          );
          await secondApprovalDelivered.future.timeout(
            const Duration(seconds: 2),
          );
        }
        await delivered.future.timeout(const Duration(seconds: 2));
        if (kind == 'approval') {
          expect(chat.runtime.approval?.requestId, 'queue-fixture');
          await controller.approve(
            chat,
            'once',
            requestId: chat.runtime.approval!.requestId,
          );
          expect(chat.runtime.approval?.requestId, 'queue-second');
          expect(
            (chat.runtime.approvalPosition, chat.runtime.approvalTotal),
            (2, 2),
          );
          await controller.approve(chat, 'deny', requestId: 'queue-second');
          expect(chat.runtime.approval, isNull);
        } else if (isSecure) {
          final answering = controller.respondSensitivePrompt(
            chat,
            inputValue,
            expectedRequest: chat.runtime.secureInput!,
          );
          await secretReply.future.timeout(const Duration(seconds: 2));
          expect(replies.single, {
            'jsonrpc': '2.0',
            'id': 'srq-fixture',
            'result': {'value': replyValue},
          });
          expect(chat.runtime.secureInput, isNotNull);
          expect(chat.runtime.secureResponding, isTrue);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'request.cancel',
                'sid': chat.runtime.runtimeId,
                'payload': {
                  'id': 'srq-fixture',
                  'method': 'secret',
                  'reason': 'resolved',
                },
              },
            }),
          );
          await answering;
          expect(chat.runtime.secureInput, isNull);
        } else {
          await controller.clarify(
            chat,
            'Bedroom',
            expectedRequest: chat.runtime.questions,
          );
          expect(chat.runtime.questions, isNull);
        }
        expect(replies, hasLength(kind == 'approval' ? 2 : 1));
        if (kind == 'approval') {
          expect(replies.last['params'], {
            'profile': 'a',
            'id': 'srq-second',
            'result': {'choice': 'deny'},
          });
        }
        if (isSecure) return;
        expect(
          replies.first['method'],
          kind == 'batch' ? 'clarify.lock' : 'request.answer',
        );
        expect(replies.first['params'], {
          'profile': 'a',
          if (kind == 'batch') ...{
            'request_id': 'srq-fixture',
            'question_id': 'q0',
            'answer': 'Bedroom',
          } else ...{
            'id': 'srq-fixture',
            'result': kind == 'approval'
                ? {'choice': 'once'}
                : isSecure
                ? {'value': replyValue}
                : {'answer': 'Bedroom'},
          },
        });
      },
    );
  }
}
