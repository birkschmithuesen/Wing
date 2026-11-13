import 'package:wing/core/services/bots_session.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/widgets/profile_message.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_history_fixture.dart';

void main() {
  for (final editingQueue in [false, true]) {
    testWidgets(
      'typing ${editingQueue ? 'a queue edit' : 'a draft'} does not rebuild the unchanged conversation',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final fixture = ProfileHistoryFixture()..messageCount = 20;
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: identityTestConnection(),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'conversation-work-budget',
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: fixture.gateway,
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.openSession(
          ProfileSessionKey(controller.current!.scope, 'chat-0'),
        );
        final chat = controller.current!.chat!;
        if (editingQueue) {
          final prompt = QueuedPromptDraft(text: 'Original queued message');
          await restoreComposerFixture(
            chat: chat,
            preferences: controller.preferences,
            appendQueued: [prompt],
          );
          await controller.beginQueuedPromptEdit(
            chat,
            chat.composer.observation.queue.single.id,
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: ProfileWorkspaceScreen(
              createBotsSession: () => BotsSession((_) async => const []),
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('profile-message-composer'));
        await tester.enterText(field, 'Warm up');
        await tester.pumpAndSettle();
        expect(find.byType(ProfileMessage), findsWidgets);
        var messageBuilds = 0;
        var workspaceUpdates = 0;
        controller.addListener(() => workspaceUpdates++);
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          if (element.widget is ProfileMessage) messageBuilds++;
          previous?.call(element, builtOnce);
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);
        final watch = Stopwatch()..start();
        for (var i = 1; i <= 30; i++) {
          await tester.enterText(field, 'A draft ${'x' * i}');
          await tester.pump(const Duration(milliseconds: 16));
        }
        watch.stop();
        // Work counts are deterministic; host debug timings are diagnostic only.
        debugPrint(
          'Typing 30 edits: $messageBuilds message builds; '
          '${watch.elapsedMilliseconds} ms host debug elapsed',
        );
        expect(chat.composer.observation.displayedText, 'A draft ${'x' * 30}');
        expect(
          workspaceUpdates,
          0,
          reason: 'Keystrokes must not wake workspace/monitoring observers.',
        );
        if (editingQueue) {
          expect(
            chat.composer.observation.queue.single.text,
            'Original queued message',
          );
        } else {
          final savedDraft =
              await ComposerDraftStore(
                controller.preferences,
                connectionIdentity: 'conversation-work-budget',
              ).read(
                profileName: chat.key.workspace.profileName,
                sessionId: chat.key.sessionId,
              );
          expect(savedDraft!.text, chat.composer.observation.text);
        }
        // Programmatic edits still reach the field through the composer listener.
        if (editingQueue) {
          controller.updateQueuedPromptEdit(chat, 'Programmatic edit');
        } else {
          await controller.updateDraft(chat, 'Programmatic edit');
        }
        await tester.pump();
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Programmatic edit',
        );
        expect(
          messageBuilds,
          0,
          reason: 'Typing must not re-render unchanged chat history.',
        );
      },
    );
  }
}
