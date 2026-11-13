import 'package:wing/core/services/bots_session.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

void main() {
  testWidgets('batch question accepts a free-text answer inline', (
    tester,
  ) async {
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
    emitChatEvent(controller, chat, 'message.start');
    emitChatEvent(controller, chat, 'clarify', {
      'request_id': 'recovered-request',
      'questions': [
        {'qid': 'q0', 'question': 'What is the recovery marker?'},
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    expect(find.text('What is the recovery marker?'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('clarify-other-field')),
      'PROCESS_RECOVERY_QA',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('clarify-continue')));
    await tester.tap(find.byKey(const Key('clarify-continue')));
    // Reply resumes work; let the dialog finish closing without waiting for
    // the ongoing runtime indicator to stop animating.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.text('Reply to Hermes'), findsNothing);
    expect(host.calls.last.$3['question_id'], 'q0');
    expect(host.calls.last.$3['answer'], 'PROCESS_RECOVERY_QA');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
