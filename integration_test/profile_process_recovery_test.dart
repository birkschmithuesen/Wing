import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wing/main.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';

/// Opt-in, one real prompt per RECOVERY_RUN_ID. Install with adb install -r.
/// After READY_FOR_PROCESS_STOP, force-stop and relaunch the SAME APK. After
/// RESTORED_INPUT, answer PROCESS_RECOVERY_QA through the inline input card.
/// The saved target prevents a restart from ever submitting the prompt again.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
          .shouldPropagateDevicePointerEvents =
      true;
  const port = int.fromEnvironment('HERMES_TEST_PORT');
  const runId = String.fromEnvironment('RECOVERY_RUN_ID');
  const runModel = bool.fromEnvironment('RUN_MODEL');
  const autoAnswer = bool.fromEnvironment('AUTO_ANSWER');
  testWidgets(
    'real input survives Android process death without resubmit',
    (tester) async {
      expect(port, greaterThan(0));
      expect(runId, isNotEmpty);
      final prefs = await SharedPreferences.getInstance();
      final checkpoint = 'profile_recovery_qa_v1_$runId';
      final savedTarget = prefs.getString(checkpoint);
      expect(
        savedTarget,
        isNot('complete'),
        reason: 'This run already completed; no new model call is allowed.',
      );
      final manager = await ConnectionManager.create(prefs);
      final connection = SavedConnection(
        id: 'prestige-recovery-qa',
        label: 'Prestige recovery QA',
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
      await prefs.setString('last_connection_id', connection.id);
      final appPreferences = AppPreferences(prefs);
      addTearDown(appPreferences.dispose);
      if (savedTarget == null) {
        expect(runModel, isTrue, reason: 'Explicit RUN_MODEL=true is required');
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
      }
      final selectedAtStartup = appPreferences
          .profileSelectionFor(
            await ProfileConnectionIdentity().resolve(connection),
          )
          .value
          .selectedName;
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        WingApp(connManager: manager, appPreferences: appPreferences),
      );
      Future<void> until(bool Function() condition, {int seconds = 45}) async {
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
      if (savedTarget == null) {
        final chat = await controller.createChat(canDispatch: () => true);
        // Checkpoint before submitting. A crash at any later point can only
        // resume this owner, never create a second billable turn.
        await prefs.setString(checkpoint, jsonEncode(chat.key.toJson()));
        chat.composer.editText(
          'Android process recovery test. Use only your clarify tool to ask exactly: What is the recovery marker? Wait for my answer, then reply with that answer only. Do not use any other tool, read or change files, browse, delegate, or do other work.',
        );
        await controller.send(chat);
        await until(
          () =>
              chat.runtime.questions != null ||
              !chat.runtime.blocksTurnAdmission,
          seconds: 90,
        );
        expect(chat.runtime.questions, isNotNull, reason: chat.runtime.error);
        await controller.switchProfile('android-qa-b');
        expect(controller.current!.scope.profileName, 'android-qa-b');
        debugPrint(
          '[recovery-qa] READY_FOR_PROCESS_STOP: real clarification pending in A while B is visible.',
        );
        // The external harness terminates this process here, not a widget dispose.
        await until(() => false, seconds: 180);
        return;
      }
      final target = ProfileSessionKey.fromJson(
        jsonDecode(savedTarget) as Map<String, dynamic>,
      );
      await until(
        () => controller.activity.any((c) => c.key == target),
        seconds: 60,
      );
      final restored = controller.activity.singleWhere((c) => c.key == target);
      expect(controller.current!.scope.profileName, selectedAtStartup);
      expect(restored.runtime.needsInput, isTrue);
      expect(restored.runtime.questions, isNotNull);
      await controller.openSession(target);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clarify-other-field')), findsOneWidget);
      expect(find.text('What is the recovery marker?'), findsOneWidget);
      debugPrint(
        '[recovery-qa] RESTORED_INPUT: answer PROCESS_RECOVERY_QA through the inline input card.',
      );
      if (autoAnswer) {
        await tester.enterText(
          find.byKey(const Key('clarify-other-field')),
          'PROCESS_RECOVERY_QA',
        );
        final confirm = find.byTooltip('Confirm answer and continue');
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await until(() => !restored.runtime.blocksTurnAdmission, seconds: 180);
      expect(
        restored.runtime.execution,
        ChatExecution.completed,
        reason: restored.runtime.error,
      );
      await until(
        () => restored.reading.messages.any(
          (m) =>
              m['role'] == 'assistant' &&
              m['content'].toString().trim() == 'PROCESS_RECOVERY_QA',
        ),
      );
      expect(
        restored.reading.messages.where(
          (m) =>
              m['role'] == 'user' &&
              m['content'].toString().contains(
                'Android process recovery test.',
              ),
        ),
        hasLength(1),
      );
      await prefs.setString(checkpoint, 'complete');
      debugPrint(
        '[recovery-qa] PASS: process restarted; original pending input answered; one prompt; exact final result.',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
