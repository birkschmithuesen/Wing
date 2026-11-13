import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'support/profile_browser_fixture.dart';

class _UnreadFixture extends ProfileBrowserFixture {
  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    for (var i = 0; i < 51; i++)
      {
        'id': 'chat-$i',
        'title': '$profile chat $i',
        'profile': profile,
        'last_active': now - i * 60,
        'unread': i == 50,
      },
  ];
}

void main() {
  testWidgets(
    'unread filter finds older matches across profiles and intersects search',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = _UnreadFixture();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Test',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'settings',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-filter-status')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-menu-unread')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close filters'));
      await tester.pumpAndSettle();
      expect(find.text('personal chat 50'), findsOneWidget);
      expect(find.text('work chat 50'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-personal-chat-0')), findsNothing);
      await tester.enterText(find.byType(TextField), 'personal');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('personal chat 50'), findsOneWidget);
      expect(find.text('work chat 50'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
