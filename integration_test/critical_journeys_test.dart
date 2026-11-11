import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/profile_queued_messages.dart';

import '../test/profile_workspace_controller_test.dart' show Host;
import 'connection_journey_native_test.dart' as connection;
import 'connection_persistence_native_test.dart' as persistence;

/// Automated Android journeys use controlled gateway/probe responses and
/// production controls. Persistence cases use actual Android storage.
/// Owner recreation below establishes durable restoration, not OS process death.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  connection.main();
  persistence.main();

  testWidgets('uncertain Send survives owner recreation beside a newer draft', (
    tester,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final originalKeys = preferences.getKeys();
    final identity = 'journey-${DateTime.now().microsecondsSinceEpoch}';
    final host = Host()
      ..running = false
      ..promptSubmitFails = true;
    final controllers = <ProfileWorkspaceController>[];
    final owners = <AppPreferences>[];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final controller in controllers) {
        controller.dispose();
      }
      for (final owner in owners) {
        owner.dispose();
      }
      for (final key in preferences.getKeys().difference(originalKeys)) {
        await preferences.remove(key);
      }
    });
    Future<ProfileWorkspaceController> create() async {
      final owner = AppPreferences(preferences);
      owners.add(owner);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: identity,
            label: 'Isolated journey',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: identity,
        preferences: preferences,
        appPreferences: owner,
        gatewayFactory: host.gateway,
      );
      controllers.add(controller);
      await controller.initialize();
      expect(controller.error, isNull);
      return controller;
    }

    Future<void> show(ProfileWorkspaceController controller) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> until(
      bool Function() condition,
      String reason, {
      Map<String, Object?> Function()? failureDetails,
    }) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final satisfied = condition();
      expect(
        satisfied,
        isTrue,
        reason: !satisfied && failureDetails != null
            ? '$reason\n${failureDetails()}'
            : reason,
      );
      expect(tester.takeException(), isNull);
    }

    final controller = await create();
    final key = ProfileSessionKey(controller.current!.scope, 'same');
    final chat = (await controller.openSession(key))!;
    await show(controller);
    final editor = find.byKey(const Key('profile-message-composer'));
    Finder queued(String text) => find.descendant(
      of: find.byType(ProfileQueuedMessages),
      matching: find.textContaining(text),
    );
    await tester.enterText(editor, 'Do not send this twice');
    await tester.pump();
    await tester.tap(find.byType(ComposerActionButton));
    await until(
      () =>
          chat.composer.observation.paused &&
          !chat.composer.observation.saving &&
          !chat.composer.observation.draining &&
          chat.composer.observation.queue.any(
            (item) => item.submissionUncertain,
          ),
      'A lost acknowledgement must retain the outgoing message for review',
    );
    expect(queued('Do not send this twice').hitTestable(), findsOneWidget);
    expect(find.text('Paused · 1 to review'), findsOneWidget);
    // The server accepted this input before the fixture lost its ACK. Capture
    // that authority before destroying the phone owner, not after recovery.
    expect(host.canonicalAdmissions, hasLength(1));
    final accepted = Map<String, dynamic>.from(
      host.canonicalAdmissions.values.single,
    );
    final originalPayload = Map<String, dynamic>.from(
      host.calls.firstWhere((call) => call.$2 == 'prompt.submit').$3,
    );
    expect(accepted['input_id'], originalPayload['submission_id']);
    expect(originalPayload['submission_id'], isA<String>());
    expect(originalPayload['submission_id'], isNotEmpty);
    expect(accepted['status'], 'started');
    expect(originalPayload['text'], 'Do not send this twice');
    await tester.enterText(editor, 'My newer draft');
    await tester.pump();
    // Wait on durable storage rather than a fixed debounce duration.
    final store = ComposerDraftStore(preferences, connectionIdentity: identity);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((await store.read(profileName: 'a', sessionId: 'same'))?.text !=
            'My newer draft' &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final persisted = (await store.read(profileName: 'a', sessionId: 'same'))!;
    expect(persisted.text, 'My newer draft');
    expect(persisted.queuedPrompts, hasLength(1));
    final outgoing = persisted.queuedPrompts.single;
    expect(outgoing.submissionUncertain, isTrue);
    expect(outgoing.submissionId, originalPayload['submission_id']);
    expect(outgoing.submissionPayload, isNotNull);
    // Profile scoping belongs to the gateway; the journal retains the exact
    // submission body before that transport envelope is added.
    expect({...outgoing.submissionPayload!, 'profile': 'a'}, originalPayload);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    controllers.remove(controller);
    owners.removeLast().dispose();
    await preferences.reload();
    host.promptSubmitFails = false;
    final restored = await create();
    final restoredChat = (await restored.openSession(key))!;
    Map<String, Object?> surface(Finder finder) {
      final elements = finder.evaluate().toList();
      return {
        'mounted': elements.length,
        'hitTestable': finder.hitTestable().evaluate().length,
        'layout': elements.map((element) {
          final render = element.findRenderObject();
          if (render is! RenderBox || !render.attached || !render.hasSize) {
            return {'ready': false};
          }
          return {
            'origin': render.localToGlobal(Offset.zero).toString(),
            'size': render.size.toString(),
          };
        }).toList(),
      };
    }

    Map<String, Object?> restorationDetails() {
      final current = restored.current?.chat;
      final work = current?.composer.observation;
      return {
        'selectedOriginalChat': identical(current, restoredChat),
        'selectedKey': current?.key.toString(),
        'notificationKey': restored.notificationChat?.key.toString(),
        'execution': current?.runtime.execution.name,
        'opening': current?.runtime.opening,
        'offline': current?.runtime.offline,
        'openingError': current?.runtime.openingError,
        'historyLoading': current?.reading.historyLoading,
        'historyError': current?.reading.historyError,
        'controllerError': restored.error,
        'draft': work?.displayedText,
        'paused': work?.paused,
        'saving': work?.saving,
        'draining': work?.draining,
        'queue': work?.queue
            .map(
              (item) => {
                'text': item.text,
                'uncertain': item.submissionUncertain,
              },
            )
            .toList(),
        'editor': surface(editor),
        'queuedPreview': surface(queued('Do not send this twice')),
        'pausedLabel': surface(find.text('Paused · 1 to review')),
        'browserRow': surface(find.text('a chat')),
        'physicalSize': tester.view.physicalSize.toString(),
        'pixelRatio': tester.view.devicePixelRatio,
        'keyboardBottom': tester.view.viewInsets.bottom,
        'rpcMethods': host.calls
            .map((call) => '${call.$1}:${call.$2}')
            .toList(),
      };
    }

    await show(restored);
    await until(
      () =>
          editor.hitTestable().evaluate().isNotEmpty &&
          restoredChat.composer.observation.displayedText == 'My newer draft' &&
          restoredChat.composer.observation.queue.isEmpty &&
          !restoredChat.composer.observation.saving &&
          !restoredChat.composer.observation.draining,
      'Receipt recovery must retire the uncertain copy and preserve the newer draft',
      failureDetails: restorationDetails,
    );
    expect(tester.widget<TextField>(editor).controller!.text, 'My newer draft');
    expect(queued('Do not send this twice'), findsNothing);
    expect(find.text('Paused · 1 to review'), findsNothing);
    // Accepted, already-started work belongs to Hermes. Keeping a paused local
    // copy here would falsely offer a second submission after successful recovery.
    final cleanupDeadline = DateTime.now().add(const Duration(seconds: 10));
    var recovered = await store.read(profileName: 'a', sessionId: 'same');
    while ((recovered == null || recovered.queuedPrompts.isNotEmpty) &&
        DateTime.now().isBefore(cleanupDeadline)) {
      await tester.pump(const Duration(milliseconds: 50));
      recovered = await store.read(profileName: 'a', sessionId: 'same');
    }
    expect(recovered, isNotNull);
    expect(recovered!.text, 'My newer draft');
    expect(recovered.queuedPrompts, isEmpty);
    expect(recovered.submissionUncertain, isFalse);
    final submissions = host.calls
        .where((call) => call.$2 == 'prompt.submit')
        .toList();
    expect(submissions.length, greaterThanOrEqualTo(2));
    expect(submissions.map((call) => call.$3), everyElement(originalPayload));
    expect(host.canonicalAdmissions, hasLength(1));
    expect(host.canonicalAdmissions.values.single, accepted);
    expect(host.canonicalPayloads.values.single, originalPayload);

    // Reopening through the browser preserves the newer draft without reviving
    // a local copy of the remotely accepted input.
    final browserRow = find.byKey(const ValueKey('chat-a-same'));
    await tester.binding.handlePopRoute();
    await until(
      () => browserRow.hitTestable().evaluate().isNotEmpty,
      'Return to Chats',
    );
    await tester.tap(browserRow);
    // The field can enter the tree before the bounded composer finishes laying
    // out. Wait for the preserved work's actual surface, not just field creation.
    await until(
      () =>
          editor.hitTestable().evaluate().isNotEmpty &&
          restoredChat.composer.observation.displayedText == 'My newer draft' &&
          restoredChat.composer.observation.queue.isEmpty,
      'Reopening must preserve the draft without reviving accepted outgoing work',
      failureDetails: restorationDetails,
    );
    expect(tester.widget<TextField>(editor).controller!.text, 'My newer draft');
    expect(queued('Do not send this twice'), findsNothing);
    expect(find.text('Paused · 1 to review'), findsNothing);
    expect(
      host.calls
          .where((call) => call.$2 == 'prompt.submit')
          .map((call) => call.$3),
      everyElement(originalPayload),
    );
    expect(host.canonicalAdmissions, hasLength(1));
    expect(host.canonicalAdmissions.values.single, accepted);
  });
}
