import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/gateway_sensitive_prompt_panel.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;
import 'support/loopback_http_fixtures.dart';

void main() {
  useRealHttpClientsForLoopbackFixtures();
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_VAULT')) return;
    for (final font in {
      'Roboto': 'build/studio-roboto.ttf',
      'Ahem': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(
            font.key,
          )..addFont(File(font.value).readAsBytes().then(ByteData.sublistView)))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final action in ['save', 'cancel', 'timeout', 'failure']) {
        testWidgets(
          'vault save-login masked form: $action ${brightness.name} ${scale}x',
          (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            SharedPreferences.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final appPreferences = AppPreferences(preferences);
            addTearDown(appPreferences.dispose);
            final host = Host();
            final controller = ProfileWorkspaceController(
              access: ConnectionAccess(
                connection: identityTestConnection(),
                dashboardOAuth: null,
              ),
              connectionIdentity: 'vault-wire-test',
              preferences: preferences,
              appPreferences: appPreferences,
              gatewayFactory: host.gateway,
            );
            addTearDown(controller.dispose);
            await controller.initialize();
            final chat = await controller.createChat(canDispatch: () => true);
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: RepaintBoundary(
                  key: const Key('vault-frame'),
                  child: ProfileWorkspaceScreen(
                    controller: controller,
                    createBotsSession: () => BotsSession((_) async => const []),
                  ),
                ),
              ),
            );

            Future<void> deliver(Map<String, dynamic> frame) async {
              await tester.runAsync(() async {
                final server = await HttpServer.bind(
                  InternetAddress.loopbackIPv4,
                  0,
                );
                final connected = Completer<WebSocket>();
                final subscription = server
                    .transform(WebSocketTransformer())
                    .listen(connected.complete);
                final delivered = Completer<void>();
                final client = WsClient('http://127.0.0.1:${server.port}')
                  ..onStreamEvent = (event) {
                    host.gateways['a']!.onEvent!(event);
                    delivered.complete();
                  };
                try {
                  await client.connect();
                  final socket = await connected.future;
                  socket.add(jsonEncode(frame));
                  await delivered.future.timeout(const Duration(seconds: 2));
                } finally {
                  client.close();
                  await subscription.cancel();
                  await server.close(force: true);
                }
              });
              await tester.pump();
              await tester.pump();
            }

            await deliver({
              'jsonrpc': '2.0',
              'id': 'srq-vault-test',
              'method': 'vault.save_login',
              'params': {
                'session_id': chat.runtime.runtimeId,
                'origin': 'https://example.test',
                'site': 'Example',
              },
            });
            expect(find.text('Save login for Example'), findsOneWidget);
            final pending = chat.reading.questionHistory!.questions.single;
            expect(pending.requestId, 'srq-vault-test');
            expect(pending.kind, HermesQuestionKind.secureInput);
            expect(pending.status, HermesQuestionStatus.pending);
            final password = find.byKey(const Key('sensitive-prompt-password'));
            expect(tester.widget<TextField>(password).obscureText, isTrue);
            expect(
              tester.widget<TextField>(password).enableSuggestions,
              isFalse,
            );
            expect(
              host.calls.where((call) => call.$2 == 'server.response'),
              isEmpty,
            );
            await tester.enterText(
              find.byKey(const Key('sensitive-prompt-field')),
              'fixture@example.test',
            );
            await tester.enterText(password, 'dummy-vault-password');
            await tester.pump();
            tester.view.viewInsets = const FakeViewPadding(bottom: 260);
            addTearDown(tester.view.resetViewInsets);
            await tester.pump();
            if (action == 'timeout') {
              await deliver({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': 'request.cancel',
                  'sid': chat.runtime.runtimeId,
                  'payload': {
                    'id': 'srq-vault-test',
                    'method': 'vault.save_login',
                    'reason': 'timeout',
                  },
                },
              });
              expect(
                host.calls.where((call) => call.$2 == 'server.response'),
                isEmpty,
              );
              final expired = chat.reading.questionHistory!.questions.single;
              expect(expired.id, pending.id);
              expect(expired.timestamp, pending.timestamp);
              expect(expired.description, pending.description);
              expect(expired.status, HermesQuestionStatus.expired);
              expect(find.text('Asked a question'), findsNothing);
              await tester.tap(find.text('Activity'));
              await tester.pumpAndSettle();
              expect(
                find.descendant(
                  of: find.byType(ProfileActivityTimeline),
                  matching: find.byType(ProfileToolCall),
                ),
                findsOneWidget,
              );
              expect(find.text('Asked a question'), findsOneWidget);
              expect(find.textContaining('Expired'), findsOneWidget);
              expect(chat.runtime.error, isNull);
            } else {
              final button = find.byKey(
                Key(
                  (action == 'save' || action == 'failure')
                      ? 'sensitive-prompt-submit'
                      : 'sensitive-prompt-cancel',
                ),
              );
              await tester.ensureVisible(button);
              await tester.pump();
              final held = Completer<void>();
              host.onClarifyResponse = () async {
                await held.future;
                if (action == 'failure') {
                  throw StateError('synthetic response failure');
                }
              };
              await tester.tap(button);
              await tester.pump();
              expect(
                find.descendant(
                  of: find.byType(GatewaySensitivePromptPanel),
                  matching: find.byType(CircularProgressIndicator),
                ),
                findsOneWidget,
              );
              await captureVault(
                tester,
                '${brightness.name}-$scale-$action-pending',
              );
              held.complete();
              await tester.pump();
              await tester.pump();
              final replies = host.calls.where(
                (call) => call.$2 == 'server.response',
              );
              expect(replies, hasLength(1));
              expect(replies.single.$3['id'], 'srq-vault-test');
              final value = (replies.single.$3['result'] as Map)['value'];
              if (action == 'save' || action == 'failure') {
                expect(jsonDecode(value as String), {
                  'identifier': 'fixture@example.test',
                  'password': 'dummy-vault-password',
                });
              } else {
                expect(value, '');
              }
            }
            if (action == 'failure') {
              expect(chat.runtime.secureInput, isNotNull);
              expect(
                find.text(
                  'Hermes could not accept the response. Please try again.',
                ),
                findsOneWidget,
              );
              expect(
                tester.widget<TextField>(password).controller!.text,
                isEmpty,
              );
              await tester.ensureVisible(
                find.byKey(const Key('sensitive-prompt-error')),
              );
              await tester.pump();
              await captureVault(tester, '${brightness.name}-$scale-failure');
            } else {
              expect(chat.runtime.secureInput, isNull);
              expect(password, findsNothing);
            }
            expect(
              chat.composer.observation.text,
              isNot(contains('dummy-vault-password')),
            );
            expect(
              chat.reading.messages.toString(),
              isNot(contains('dummy-vault-password')),
            );
            expect(
              jsonEncode([
                for (final question in chat.reading.questionHistory!.questions)
                  question.toJson(),
              ]),
              isNot(contains('dummy-vault-password')),
            );
            expect(
              [
                for (final key in preferences.getKeys()) preferences.get(key),
              ].toString(),
              isNot(contains('dummy-vault-password')),
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }
}

Future<void> captureVault(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_VAULT')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('vault-frame')),
  );
  await tester.runAsync(() async {
    final bitmap = await boundary.toImage();
    try {
      final data = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/bitwarden-unlock-investigation/frames')
        ..createSync(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      bitmap.dispose();
    }
  });
}
