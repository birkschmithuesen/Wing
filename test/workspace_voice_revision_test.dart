import 'package:wing/core/services/bots_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';
import 'support/voice_fixture.dart';

void main() {
  testWidgets('a recording cannot replace a newer draft edited away and back', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    final fixture = ProfileActionsFixture();
    final device = VoiceDeviceFixture();
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'voice-revision',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    addTearDown(controller.dispose);
    addTearDown(appPreferences.dispose);
    addTearDown(device.stream.close);
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    await controller.updateDraft(chat, 'Alpha');
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
          voiceDevice: device,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(device.recording, isNotNull);
    final composer = find.byKey(const Key('profile-message-composer'));
    // Recording disables keyboard editing. Other admitted application commands
    // can still change the draft; their revisions must invalidate this capture.
    await controller.updateDraft(chat, 'Other');
    await tester.pump();
    expect(chat.composer.observation.text, 'Other');
    await controller.updateDraft(chat, 'Alpha');
    await tester.pump();
    device.stream.add({
      'id': device.recording,
      'text': 'spoken',
      'final': true,
    });
    await tester.pump();
    expect(chat.composer.observation.text, 'Alpha');
    expect(tester.widget<TextField>(composer).controller!.text, 'Alpha');
    expect(
      find.text('The draft changed while recording. Please dictate again.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
