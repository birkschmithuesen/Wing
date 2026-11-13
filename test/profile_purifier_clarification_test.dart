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

// Reported tool arguments. The gateway, rather than the tool caller, supplies
// the JSON-RPC request ID and qid. This fixture tests that client boundary;
// it does not establish that a live gateway emitted the event.
const questions = <Map<String, dynamic>>[
  {
    'question': 'Which space should the first purifier protect during haze?',
    'choices': [
      'One closed bedroom',
      'Living room or study',
      'One large open-plan zone',
      'Several separate rooms',
    ],
  },
  {
    'question':
        'Who will use the protected space? Select every applicable category.',
    'choices': [
      'Healthy adult(s) only',
      'Allergies or sensitivity',
      'Asthma or chronic heart/lung condition',
      'Child, older adult, or pregnancy',
    ],
    'multi_select': true,
  },
  {
    'question':
        'What is the comfortable upfront appliance budget for the first protected zone? Replacement filters will be assessed separately.',
    'choices': [r'S$250–500', r'Under S$250', r'S$500–800', r'Over S$800'],
  },
  {
    'question': 'When must the purifier be operating?',
    'choices': [
      'Within 24–48 hours',
      'Today if possible',
      'Within one week',
      'No hard deadline',
    ],
  },
  {
    'question': 'How important is removing the smoky odour?',
    'choices': [
      'PM2.5 first; odour secondary',
      'PM2.5 and odour both matter',
      'Odour control is essential',
      'Not sure yet',
    ],
  },
];

void main() {
  useRealHttpClientsForLoopbackFixtures();

  for (final count in [1, 5]) {
    testWidgets('submits the reported $count-question purifier form', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final host = Host();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'test-identity',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      final batch = [
        for (var i = 0; i < count; i++) {...questions[i], 'qid': 'q$i'},
      ];
      await tester.runAsync(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
          socket.listen((raw) {
            final capability = jsonDecode(raw as String) as Map;
            expect(capability['method'], 'client.capabilities');
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': capability['id'],
                'result': {'canonical_clarify_batch': true},
              }),
            );
          });
          await client.capabilitiesReady;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 'purifier-request',
              'method': 'clarify',
              'params': {
                'session_id': chat.runtime.runtimeId,
                'questions': batch,
              },
            }),
          );
          await delivered.future.timeout(const Duration(seconds: 2));
        } finally {
          client.close();
          await subscription.cancel();
          await server.close(force: true);
        }
      });
      await tester.pump();
      await tester.pump();

      for (var i = 0; i < count; i++) {
        expect(find.text(questions[i]['question'] as String), findsOneWidget);
        final selected = i == 1 ? [1, 3] : [0];
        for (final choice in selected) {
          final option = find.byKey(
            Key(
              count == 1
                  ? 'clarify-choice-$choice'
                  : 'clarify-q$i-choice-$choice',
            ),
          );
          await tester.ensureVisible(option);
          await tester.pump();
          expect(option.hitTestable(), findsOneWidget);
          await tester.tap(option);
          await tester.pump();
        }
        expect(host.calls.where((call) => call.$2 == 'clarify.lock'), isEmpty);
      }
      host.onClarifyResponse = () async {
        final qid = host.calls.last.$3['question_id'] as String;
        final index = int.parse(qid.substring(1));
        host.clarifyResult = {
          'status': 'ok',
          'remaining': [for (var j = index + 1; j < count; j++) 'q$j'],
        };
      };
      final submit = find.byKey(const Key('clarify-continue'));
      await tester.ensureVisible(submit);
      await tester.pump();
      expect(submit.hitTestable(), findsOneWidget);
      await tester.tap(submit);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('clarify-error')), findsNothing);
      final replies = host.calls
          .where((call) => call.$2 == 'clarify.lock')
          .toList();
      expect(replies, hasLength(count));
      for (var i = 0; i < count; i++) {
        final choices = questions[i]['choices'] as List<String>;
        final selected = i == 1 ? [1, 3] : [0];
        expect(replies[i].$3, {
          'profile': 'a',
          'request_id': 'purifier-request',
          'question_id': 'q$i',
          'answer': selected.map((index) => choices[index]).join(', '),
        });
      }
      expect(tester.takeException(), isNull);
      expect(chat.runtime.questions, isNull);
      expect(find.byKey(const Key('clarify-continue')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
