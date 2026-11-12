import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_browser_fixture.dart';

class _LeaseFixture extends ProfileBrowserFixture {
  int _nextChat = 0;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      rpc: (method, params) async {
        final result = await base.call(method, params);
        if (method != 'session.create') return result;
        final id = 'lease-chat-${_nextChat++}';
        return {...result, 'session_id': id, 'stored_session_id': id};
      },
    );
  }
}

void main() {
  testWidgets(
    'covered workspace retains its captured idle chat until route disposal',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = _LeaseFixture();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'route-lease',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final original = await controller.createChat(canDispatch: () => true);
      // Make the protected chat unambiguously oldest, even on a fast fixture.
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProfileWorkspaceScreen(
                      createBotsSession: () =>
                          BotsSession((_) async => const []),
                      controller: controller,
                    ),
                  ),
                ),
                child: const Text('Open workspace'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open workspace'));
      await tester.pumpAndSettle();
      expect(controller.hasRetentionObligations, isTrue);
      expect(controller.visible, isTrue);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covered workspace')),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.visible, isFalse);
      for (
        var i = 0;
        i < ProfileWorkspaceController.settledChatLimit + 2;
        i++
      ) {
        await controller.createChat(canDispatch: () => true);
      }
      await tester.pumpAndSettle();
      controller.pruneSettledState();
      expect(controller.current!.chats[original.key.sessionId], same(original));
      expect(controller.hasRetentionObligations, isTrue);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      controller.pruneSettledState();
      expect(find.text('Open workspace'), findsOneWidget);
      expect(
        controller.current!.chats.containsKey(original.key.sessionId),
        isFalse,
      );
      expect(controller.hasRetentionObligations, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
