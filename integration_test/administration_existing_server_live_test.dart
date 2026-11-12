import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/models/backend_update.dart';

import '../test/support/existing_backend_login.dart';

/// Read-only shell/navigation acceptance against the owner's running server.
/// Supply WING_HERMES_URL and WING_HERMES_LOGIN_FILE as Dart defines. The latter
/// is a private file inside the disposable emulator's app cache; credentials
/// themselves are never compiled into the test. Only browse administration;
/// never open a chat, resume a session, run health actions or submit changes.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets(
    'existing Hermes server exposes Administration through the app drawer',
    (tester) async {
      const url = String.fromEnvironment('WING_HERMES_URL');
      const loginFile = String.fromEnvironment('WING_HERMES_LOGIN_FILE');
      expect(url.isNotEmpty && loginFile.isNotEmpty, isTrue);
      final connection = await readExistingBackendConnection(
        url: url,
        loginFile: loginFile,
        id: 'existing-admin-readonly',
      );
      final repository = ProfilesRepository.forConnection(
        ConnectionAccess(connection: connection, dashboardOAuth: null),
      );
      addTearDown(repository.close);
      final discovery = await repository.discover();
      expect(discovery.named('default') != null, isTrue);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      expect(
        (await appPreferences
                .admitProfileSelection('existing-admin-readonly', 'default')
                .settled)
            .confirmed,
        isTrue,
      );
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        appPreferences: appPreferences,
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        connectionIdentity: 'existing-admin-readonly',
        preferences: preferences,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.initialized, isTrue);
      expect(controller.current?.scope.profileName == 'default', isTrue);
      expect(controller.current?.chat == null, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: ProfileWorkspaceScreen(
            controller: controller,
            onConnections: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hermes administration'));
      await tester.pumpAndSettle();
      expect(find.text('Models and reasoning'), findsOneWidget);
      expect(find.text('Identity'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Server'), findsNothing);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('menu-server-version')),
      );
      await tester.tap(find.byKey(const ValueKey('menu-server-version')));
      await tester.pumpAndSettle();
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (find.text('Current version unavailable').evaluate().isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final version = BackendUpdateCheck.fromJson(
        await controller.current!.gateway.read('hermes/update/check'),
      );
      expect(version.currentVersion, isNotNull);
      expect(find.text(version.currentVersion!), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      // Versions keeps its originating drawer underneath the pushed route;
      // Back restores that already-open menu and its previous scroll position.
      expect(find.byType(Drawer), findsOneWidget);
      await tester.ensureVisible(find.text('Hermes health'));
      await tester.pumpAndSettle();
      expect(find.text('Hermes health').hitTestable(), findsOneWidget);
      // Entering Health automatically starts missing or expired server
      // diagnostics and profile checks. Verify its real navigation entry here;
      // those actions are exercised by the isolated native fixture instead.
      // A drawer closes through the route's local history, without a visible
      // BackButton. Exercise the platform Back dispatch for this transition.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(controller.current?.scope.profileName, 'default');
      expect(controller.current?.chat, isNull);
      expect(find.text('Models and reasoning'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
