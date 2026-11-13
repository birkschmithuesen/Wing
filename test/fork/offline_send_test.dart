import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/fork/transient_send.dart';

import '../profile_workspace_controller_test.dart' show Host;

void main() {
  late Host host;
  late ProfileWorkspaceController controller;
  late SharedPreferences preferences;
  late AppPreferences appPreferences;
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
    // Upstream marks HTTP access only on dashboard reads, which this fixture skips.
    controller.connectionStatus.accessAvailable();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'a message queued during a real network outage shows offline at once and sends exactly once on reconnect',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Queue me please');
      // The gateway would throw if a drain were attempted right now; the
      // queue must not even try while the device has no network.
      host.promptSubmitFails = true;

      controller.networkUnavailable();

      // No backoff wait: the device's own network loss is authoritative,
      // unlike the reconnect attempt's own up-to-31s retry budget.
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.disconnected,
      );

      await controller.queuePrompt(chat, chat.composer.observation.text);

      expect(chat.composer.observation.queue.map((p) => p.text), ['Queue me please']);
      expect(chat.composer.observation.paused, isFalse);
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);

      host.promptSubmitFails = false;
      // This chat never had a turn submitted, so the resumed session reports
      // idle, not running (unlike the sent-prompt scenarios other tests here
      // exercise with the fixture's default `running: true`).
      host.running = false;
      // Mirrors ProfileWorkspaceRegistry.recoverConnections(), which always
      // marks the network restored before asking a controller to reconnect.
      // The registry's recoverConnections() restores every connection owner
      // (the connection-wide 'default' gateway included), not only the chat's.
      await controller.resumeConnection(networkChanged: true);

      expect(chat.composer.observation.queue, isEmpty);
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), hasLength(1));
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.connected,
      );
    },
  );

  test(
    'a flaky send right after reconnect resolves on the next reconnect instead of sticking forever',
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

  test(
    'a replay that Hermes already finished (terminal receipt) leaves the chat idle and drains follow-ups',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'first');
      controller.networkUnavailable();
      await controller.queuePrompt(chat, chat.composer.observation.text);
      await controller.updateDraft(chat, 'second');
      await controller.queuePrompt(chat, chat.composer.observation.text);

      host.running = false;
      // The admission is recorded, but the acknowledgement is lost.
      host.promptSubmitFails = true;
      controller.networkRestored();
      await controller.reconnect(chat.key.workspace);
      expect(chat.composer.observation.paused, isTrue);
      expect(chat.composer.observation.queue.first.submissionUncertain, isTrue);

      // Hermes finished the turn while the phone was offline.
      host.promptSubmitFails = false;
      for (final row in host.canonicalAdmissions.values) {
        row['status'] = 'terminal';
      }
      await controller.reconnect(chat.key.workspace);

      expect(chat.composer.observation.paused, isFalse);
      expect(
        host.calls.where((c) => c.$2 == 'prompt.submit').map((c) => c.$3['text']),
        ['first', 'first', 'second'],
        reason: 'the replay is not a new turn; the follow-up drains at once',
      );
    },
  );

  test('a re-marked chat is resumed again; a released hold stops gating', () {
    final chat = Object();
    TransientSend.mark(chat);
    expect(TransientSend.take(chat), isTrue);
    expect(TransientSend.take(chat), isFalse);
    // Failed resume path re-marks, so the next reconnect retries.
    TransientSend.mark(chat);
    expect(TransientSend.take(chat), isTrue);

    TransientSend.hold(chat);
    expect(TransientSend.holding(chat), isTrue);
    TransientSend.release(chat);
    expect(TransientSend.holding(chat), isFalse);
  });
}
