import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import '../profile_workspace_controller_test.dart' show Host;
import '../support/voice_workspace_fixture.dart';

void main() {
  group('R5 queue resume (controller)', () {
    late Host host;
    late ProfileWorkspaceController controller;
    late SharedPreferences preferences;
    late AppPreferences appPreferences;
    // SETUP
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      preferences = await SharedPreferences.getInstance();
      appPreferences = AppPreferences(preferences);
      host = Host();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Host',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (notification) async {},
      );
      await controller.initialize();
    });
    // SETUP
    tearDown(() {
      controller.dispose();
      appPreferences.dispose();
    });

    test(
      'R5: a flaky send right after reconnect resolves on the next reconnect instead of sticking forever',
      () async {
        final chat = await controller.createChat(canDispatch: () => true);
        await controller.updateDraft(chat, 'first');
        controller.networkUnavailable();
        await controller.queuePrompt(chat, chat.composer.observation.text);
        await controller.updateDraft(chat, 'second');
        await controller.queuePrompt(chat, chat.composer.observation.text);
        expect(chat.composer.observation.queue.map((p) => p.text), ['first', 'second']);

        host.running = false;
        // Card t_8c76c35a observation 2026-10-19: dozens of ws reconnects each
        // 1005 right after the phone regains signal. The first drain attempt
        // after reconnect still hits that flaky window.
        host.promptSubmitFailures = 1;
        controller.networkRestored();
        await controller.reconnect(chat.key.workspace);

        // The flaky send leaves an uncertain ack, same as before: it pauses
        // the queue rather than guessing whether the server already has it.
        expect(chat.composer.observation.paused, isTrue);
        // probe moved: upstream API rename e8a4089c
        expect(chat.composer.observation.queue.first.submissionUncertain, isTrue);
        expect(chat.composer.observation.queue.map((p) => p.text), ['first', 'second']);
        expect(host.calls.where((c) => c.$2 == 'prompt.submit'), hasLength(1));

        // Old (buggy) behavior: nothing short of a manual resume ever drains
        // this again. The next reconnect must resolve it by itself instead.
        await controller.reconnect(chat.key.workspace);

        // "first" was never actually delivered, so it's resent; "second"
        // waits its turn until that resend's own turn finishes.
        expect(chat.composer.observation.paused, isFalse);
        expect(chat.composer.observation.queue.map((p) => p.text), ['second']);
        expect(
          host.calls.where((c) => c.$2 == 'prompt.submit').map((c) => c.$3['text']),
          ['first', 'first'],
        );

        final drained = Completer<void>();
        void observeDrain() {
          if (chat.composer.observation.queue.isEmpty && !drained.isCompleted) {
            drained.complete();
          }
        }

        controller.addListener(observeDrain);
        host.event('a', 'message.complete');
        await drained.future;
        controller.removeListener(observeDrain);

        expect(chat.composer.observation.paused, isFalse);
        expect(
          host.calls.where((c) => c.$2 == 'prompt.submit').map((c) => c.$3['text']),
          ['first', 'first', 'second'],
        );
      },
    );
  });

  group('R5 queue resume (conversation)', () {
    late VoiceWorkspaceHarness h;
    // SETUP
    setUp(() async {
      h = VoiceWorkspaceHarness();
      await h.setUp();
    });
    // SETUP
    tearDown(() => h.tearDown());

    testWidgets(
      'R5: a flaky send right after reconnect does not end the conversation; the mic reopens once it drains',
      (tester) async {
        await h.conversationMode(true);
        await h.show(tester);
        final chat = h.controller.current!.chat!;
        h.controller.networkUnavailable();
        await tester.tap(find.byTooltip('Dictate message'));
        await tester.pump();
        await h.sayFinal(tester, 'Queue me please');
        expect(h.prompts(), 0);
        expect(chat.composer.observation.queue.map((p) => p.text), ['Queue me please']);
        h.controller.networkRestored();
        // Card t_8c76c35a observation 2026-10-19: the connection is still
        // flaky right after reconnect; the first drain attempt hits that.
        h.fixture.promptSubmitFailures = 1;
        await tester.runAsync(() => h.controller.reconnect(chat.key.workspace));
        await h.settle(tester);
        // The flaky send leaves an uncertain ack, same as the non-conversation
        // case: it pauses rather than guessing. Crucially chat.status stays
        // "reconnecting", not "failed" - the conversation keeps running.
        expect(chat.composer.observation.paused, isTrue);
        expect(chat.composer.observation.queue, isNotEmpty);
        expect(h.prompts(), 1);
        // Old (buggy) behavior: nothing short of a manual resume (not
        // available in conversation mode) ever drains this again, and the
        // conversation already ended when chat.status flipped to failed.
        await tester.runAsync(() => h.controller.reconnect(chat.key.workspace));
        await h.settle(tester);
        expect(chat.composer.observation.queue, isEmpty);
        expect(h.prompts(), 2);
        await h.completeReply(tester, 'Queued answer.');
        expect(h.device.spoken, 'Queued answer.');
        expect(h.starts(), 2, reason: 'the mic reopened after the queued reply');
        await tester.tap(find.byTooltip('Cancel recording'));
        await h.settle(tester);
      },
    );
  });
}
