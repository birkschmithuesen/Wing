import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Camera launches once for the chat that opened the sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final fixture = ProfileActionsFixture();
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'camera-action',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    final started = Completer<ProfileSessionKey>();
    final release = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
          onCapturePhoto: (target) async {
            started.complete(target);
            await release.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Attach file'));
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);

    await tester.tap(find.text('Camera'));
    await tester.pump();
    final captured = await started.future;
    expect(captured.toJson(), chat.key.toJson());
    final attachButton = find.ancestor(
      of: find.byTooltip('Attach file'),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(attachButton).onPressed, isNull);

    release.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(attachButton).onPressed, isNotNull);
  });
}
