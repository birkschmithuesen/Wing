import '../test/support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:flutter/widgets.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wing/main.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

/// No model call. Build this target, install with adb install -r to preserve the
/// emulator's notification grant, and launch it. Supply HERMES_TEST_SESSION for
/// an owned android-qa-a chat. Tap the QA notification when posted.
/// This exercises the production native notification sink and navigation handler.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const port = int.fromEnvironment('HERMES_TEST_PORT');
  const session = String.fromEnvironment('HERMES_TEST_SESSION');
  testWidgets(
    'native notification returns B to the original A session',
    (tester) async {
      expect(port, greaterThan(0));
      expect(
        session,
        isNotEmpty,
        reason: 'Select an owned QA session explicitly',
      );
      final preferences = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(preferences);
      final connection = SavedConnection(
        id: 'prestige-notification-qa',
        label: 'Prestige notification QA',
        host: '127.0.0.1',
        port: port,
        dashboardPortOverride: port,
        apiKey: '',
      );
      await manager.importConnections(
        [connection],
        replaceExisting: false,
        canCommit: () => true,
      );
      await preferences.setString('last_connection_id', connection.id);
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      expect(
        (await appPreferences
                .admitProfileSelection(
                  await ProfileConnectionIdentity().resolve(connection),
                  'android-qa-a',
                )
                .settled)
            .confirmed,
        isTrue,
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        WingApp(connManager: manager, appPreferences: appPreferences),
      );
      Future<void> until(bool Function() condition, {int seconds = 30}) async {
        final deadline = DateTime.now().add(Duration(seconds: seconds));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(condition(), isTrue);
      }

      await until(
        () => find.byType(ProfileWorkspaceScreen).evaluate().isNotEmpty,
      );
      final controller = tester
          .widget<ProfileWorkspaceScreen>(find.byType(ProfileWorkspaceScreen))
          .controller;
      await until(() => controller.current != null || controller.error != null);
      expect(controller.error, isNull);
      final resource = controller.current!;
      expect(
        resource.sessions.where((row) => row['id'] == session),
        hasLength(1),
        reason: 'The selected owned session must exist in android-qa-a',
      );
      final key = ProfileSessionKey(resource.scope, session);
      await controller.openSession(key);
      final chat = controller.current!.chat!;
      emitChatEvent(controller, chat, 'session.title', {
        'session_id': chat.key.sessionId,
        'title': 'Notification QA: tap to reopen profile A',
      });
      expect(await controller.switchProfile('android-qa-b'), isTrue);
      await tester.pumpAndSettle();
      await controller.onAttention!(
        ProfileNotification(
          key: chat.key,
          title: chat.title,
          connectionLabel: controller.connection.label,
          content: ChatNotificationContent.reply(
            'Notification previews are working.',
          ),
        ),
      );
      debugPrint(
        '[notification-qa] Posted QA notification while profile B is visible. Tap it now.',
      );
      await until(
        () =>
            controller.current?.scope.profileName == 'android-qa-a' &&
            controller.current?.chat?.key == key,
        seconds: 120,
      );
      await tester.pumpAndSettle();
      expect(controller.current!.chat!.key, key);
      expect(
        find.text('Notification QA: tap to reopen profile A'),
        findsWidgets,
      );
      debugPrint(
        '[notification-qa] PASS: native tap reopened the original profile A session.',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
