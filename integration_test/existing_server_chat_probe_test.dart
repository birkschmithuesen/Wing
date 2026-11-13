import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';

import '../test/support/existing_backend_login.dart';

/// Mutating opt-in: an operator must supply an owned disposable QA profile and
/// authorize one real provider turn. The outer runner owns profile cleanup.
/// Credentials are read from a private app-cache file, never compiler defines.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets(
    'real provider answer and unsent draft survive reopening the chat',
    (tester) async {
      expect(
        const bool.fromEnvironment('RUN_MODEL'),
        isTrue,
        reason: 'This opt-in needs authorization for a real provider turn.',
      );
      const url = String.fromEnvironment('WING_HERMES_URL');
      const loginFile = String.fromEnvironment('WING_HERMES_LOGIN_FILE');
      const profile = String.fromEnvironment('WING_QA_PROFILE');
      expect(url.isNotEmpty && loginFile.isNotEmpty, isTrue);
      expect(
        profile.startsWith('wing-qa-'),
        isTrue,
        reason: 'Supply an operator-owned disposable QA profile.',
      );
      final connection = await readExistingBackendConnection(
        url: url,
        loginFile: loginFile,
        id: 'provider-native-qa',
      );
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      expect(
        (await appPreferences
                .admitProfileSelection('provider-native-qa', profile)
                .settled)
            .confirmed,
        isTrue,
      );

      Future<void> until(bool Function() ready, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 120));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
        }
        expect(ready(), isTrue, reason: reason);
      }

      final owners = <ProfileWorkspaceController>[];
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final owner in owners.reversed) {
          final chat = owner.current?.chat;
          try {
            if (chat != null && chat.runtime.executionActive) {
              await owner.stop(chat);
            }
          } finally {
            owner.dispose();
          }
        }
      });

      Future<ProfileWorkspaceController> launch() async {
        final controller = ProfileWorkspaceController(
          appPreferences: appPreferences,
          access: ConnectionAccess(
            connection: connection,
            dashboardOAuth: null,
          ),
          connectionIdentity: 'provider-native-qa',
          preferences: preferences,
        );
        owners.add(controller);
        await controller.initialize();
        expect(controller.error, isNull);
        expect(controller.current!.scope.profileName, profile);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            home: ProfileWorkspaceScreen(controller: controller),
          ),
        );
        await until(
          () => find.byTooltip('New chat').hitTestable().evaluate().isNotEmpty,
          'The real QA browser must admit a new chat.',
        );
        return controller;
      }

      final first = await launch();
      final profileFilter = find.byKey(const ValueKey('chat-filter-profile'));
      await tester.ensureVisible(profileFilter);
      await tester.tap(profileFilter);
      final search = find.byKey(const ValueKey('chat-menu-search'));
      await until(
        () => search.evaluate().isNotEmpty,
        'The profile filter must open its search control.',
      );
      await tester.enterText(search, profile);
      final qaChoice = find.byKey(ValueKey('chat-menu-$profile'));
      await until(
        () => qaChoice.hitTestable().evaluate().isNotEmpty,
        'Searching must expose the owned QA profile.',
      );
      await tester.tap(qaChoice);
      tester.binding.focusManager.primaryFocus?.unfocus();
      await tester.pump();
      await tester.tap(find.byTooltip('Close Profile'));
      await until(
        () => find.byTooltip('New chat').hitTestable().evaluate().isNotEmpty,
        'The QA-filtered browser must admit a new chat.',
      );
      await tester.tap(find.byTooltip('New chat'));
      final composer = find.byKey(const Key('profile-message-composer'));
      await until(
        () => composer.evaluate().isNotEmpty,
        'New chat must open its real composer.',
      );
      final chat = first.current!.chat!;
      debugPrint('PROVIDER_NATIVE_QA_RUNTIME ${chat.runtime.runtimeId}');
      final marker = 'WING_NATIVE_${DateTime.now().microsecondsSinceEpoch}';
      await tester.enterText(
        composer,
        'Reply exactly $marker. Do not call tools.',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await until(
        () =>
            !chat.runtime.executionActive &&
            chat.reading.messages.any(
              (row) =>
                  row['role'] == 'assistant' &&
                  row['content'].toString().trim() == marker,
            ),
        'The real provider must save the exact requested answer.',
      );
      expect(find.text(marker, findRichText: true), findsOneWidget);
      const draft = 'Keep this unsent native draft';
      await tester.enterText(composer, draft);
      await until(
        () => chat.composer.observation.text == draft,
        'The unsent draft must reach its owner.',
      );
      final key = chat.key;
      await tester.pumpWidget(const SizedBox.shrink());
      first.dispose();
      owners.remove(first);

      final reopened = await launch();
      final row = find.byKey(ValueKey('chat-$profile-${key.sessionId}'));
      await until(
        () => row.hitTestable().evaluate().isNotEmpty,
        'The saved chat must appear in its real QA browser.',
      );
      await tester.tap(row);
      await until(
        () =>
            reopened.current?.chat?.runtime.opening == false &&
            composer.evaluate().isNotEmpty,
        'The saved chat must reopen through the browser.',
      );
      expect(reopened.current!.chat!.key, key);
      await until(
        () => find.text(marker, findRichText: true).evaluate().isNotEmpty,
        'The saved provider answer must render after owner recreation.',
      );
      expect(tester.widget<TextField>(composer).controller!.text, draft);
      expect(
        reopened.current!.chat!.reading.messages.where(
          (row) =>
              row['role'] == 'assistant' &&
              row['content'].toString().trim() == marker,
        ),
        hasLength(1),
      );
      debugPrint('PROVIDER_NATIVE_REOPEN_VERIFIED');
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
