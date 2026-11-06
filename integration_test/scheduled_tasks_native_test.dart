import 'package:wing/core/services/scheduled_tasks_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/administration/admin_scheduled_tasks_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import '../test/support/scheduled_tasks_fixture.dart';

/// Disposable emulator only. Uses production screens with in-memory transport;
/// no real profile/model or messaging destination is contacted.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android task creation, keyboard, anchored menu and back navigation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = ScheduledTasksFixture();
      addTearDown(fixture.admin.server.close);
      final taskPreferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        MaterialApp(
          theme: profileWorkspaceTheme(
            wingTheme(Brightness.dark),
            accent: WorkspaceAccent.teal,
          ),
          home: AdminScheduledTasksPage(
            profile: fixture.profile,
            acquireController: () => ScheduledTasksController.acquire(
              fixture.profile,
              taskPreferences,
            ),
            onOpenSession: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('New task'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextFormField, 'Name (optional)'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name (optional)'),
        'Android acceptance',
      );
      await tester.pumpAndSettle();
      final nameField = find.widgetWithText(TextFormField, 'Name (optional)');
      final keyboardDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (View.of(tester.element(nameField)).viewInsets.bottom == 0 &&
          DateTime.now().isBefore(keyboardDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        View.of(tester.element(nameField)).viewInsets.bottom,
        greaterThan(0),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(TextFormField, 'Instructions'),
      );
      // Lay out the revealed field before changing focus and scheduling its caret.
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Instructions'),
        'Prepare a daily summary.',
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Create task').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Create task'));
      await tester.pumpAndSettle();
      expect(
        fixture.jobs.values.any((j) => j['name'] == 'Android acceptance'),
        true,
      );
      await tester.ensureVisible(find.text('Android acceptance'));
      await tester.tap(find.byTooltip('Actions for Android acceptance'));
      await tester.pumpAndSettle();
      expect(find.text('Pause schedule'), findsOneWidget);
      await tester.tap(find.text('Pause schedule'));
      await tester.pumpAndSettle();
      expect(
        fixture.jobs.values.firstWhere(
          (j) => j['name'] == 'Android acceptance',
        )['enabled'],
        false,
      );
      await tester.tap(find.text('Android acceptance'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Resume and run').hitTestable(), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Scheduled tasks'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
}
