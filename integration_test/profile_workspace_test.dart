import 'package:wing/core/models/chat_runtime.dart';
import 'package:flutter/widgets.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/main.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';

/// Opt-in emulator test against unmodified Hermes Desktop. With RUN_MODEL=true
/// this submits exactly one bounded prompt in the disposable android-qa-a profile.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const port = int.fromEnvironment('HERMES_TEST_PORT');
  const runModel = bool.fromEnvironment('RUN_MODEL');
  const projectPath = String.fromEnvironment('HERMES_TEST_PROJECT');
  testWidgets(
    'emulator profiles, project, attachment, background completion',
    (tester) async {
      expect(port, greaterThan(0), reason: 'Supply the local gateway port');
      final preferences = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(preferences);
      final connection = SavedConnection(
        id: 'prestige-local-qa',
        label: 'Prestige local',
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
      final screen = tester.widget<ProfileWorkspaceScreen>(
        find.byType(ProfileWorkspaceScreen),
      );
      final controller = screen.controller;
      await until(() => controller.current != null || controller.error != null);
      expect(controller.error, isNull);
      expect(controller.current!.scope.profileName, 'android-qa-a');
      expect(controller.discovery!.named('android-qa-b'), isNotNull);
      if (projectPath.isNotEmpty) {
        String normalize(String path) =>
            path.replaceAll('\\', '/').toLowerCase();
        bool matches(Map<String, dynamic> project) =>
            normalize(project['primary_path']?.toString() ?? '') ==
            normalize(projectPath);
        if (!controller.current!.projects.any(matches)) {
          await controller.createProject(
            'Android QA ${DateTime.now().millisecondsSinceEpoch}',
            projectPath,
            color: '',
            icon: 'folder-library',
            canDispatch: () => true,
          );
        }
        await controller.selectProject(
          controller.current!.projects.singleWhere(matches),
        );
        expect(controller.current!.projectSessionsError, isNull);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('New chat'));
      await until(() => controller.current!.chat != null);
      final a = controller.current!.chat!;
      String? profileAtCompletion;
      void observeCompletion() {
        if (a.runtime.execution == ChatExecution.completed) {
          profileAtCompletion ??= controller.current?.scope.profileName;
        }
      }

      controller.addListener(observeCompletion);
      addTearDown(() => controller.removeListener(observeCompletion));
      final directory = await getTemporaryDirectory();
      final attachment = File('${directory.path}/android-qa.txt');
      await attachment.writeAsString('ANDROID_PROFILE_QA');
      addTearDown(() async {
        if (await attachment.exists()) await attachment.delete();
      });
      await controller.addAttachments(a, [
        (path: attachment.path, name: 'android-qa.txt'),
      ]);
      await tester.pump();
      expect(find.text('android-qa.txt'), findsOneWidget);
      if (runModel) {
        a.composer.editText(
          'This is one bounded Android integration test. Read the attached text file and reply with its exact contents only. Do not edit files, browse, delegate, or perform any other task.',
        );
        await controller.send(a);
        expect(a.runtime.blocksTurnAdmission, isTrue, reason: a.runtime.error);
      }
      await tester.tap(find.byTooltip('Switch profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('android-qa-b').last);
      await until(
        () => controller.current?.scope.profileName == 'android-qa-b',
      );
      expect(controller.current!.chat, isNull);
      expect(find.text('android-qa.txt'), findsNothing);
      if (runModel) {
        await until(() => !a.runtime.blocksTurnAdmission, seconds: 120);
        expect(
          a.runtime.execution,
          ChatExecution.completed,
          reason: a.runtime.error,
        );
        expect(profileAtCompletion, 'android-qa-b');
        expect(
          a.reading.messages.any(
            (m) =>
                m['role'] == 'assistant' &&
                m['content'].toString().contains('ANDROID_PROFILE_QA'),
          ),
          isTrue,
        );
      }
      await controller.openSession(a.key);
      await tester.pumpAndSettle();
      expect(controller.current!.scope.profileName, 'android-qa-a');
      expect(controller.current!.chat, same(a));
      await controller.reconnect(a.key.workspace);
      expect(controller.error, isNull);
      final app = tester.state<WingAppState>(find.byType(WingApp));
      // Exercise the real Android secure store and application registry. Do not
      // connect to the replacement: an old target must fail before any I/O.
      final replacementConnection = connection.copyWith(
        dashboardPortOverride: 1,
      );
      try {
        await manager.importConnections(
          [replacementConnection],
          replaceExisting: false,
          canCommit: () => true,
        );
        final savedReplacement = (await manager.loadConnectionsWithSecrets())
            .singleWhere((c) => c.id == connection.id);
        final replacement = await app.profileController(savedReplacement);
        expect(replacement, isNot(same(controller)));
        expect(replacement.discovery, isNull);
        expect(replacement.activity, isEmpty);
        expect(replacement.owns(a.key), isFalse);
        await expectLater(replacement.openSession(a.key), throwsArgumentError);
        expect(replacement.discovery, isNull);
        expect(controller.connection.dashboardPort, port);
        expect(
          await ProfileConnectionIdentity().resolve(connection),
          controller.connectionIdentity,
          reason: 'A fresh resolver must read the same Android secure key',
        );
      } finally {
        await manager.importConnections(
          [connection],
          replaceExisting: false,
          canCommit: () => true,
        );
      }
      expect(await app.profileController(connection), same(controller));
      debugPrint(
        '[connection-qa] PASS: edited endpoint isolated; old session rejected; original owner preserved.',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
