import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';

import '../profile_workspace_controller_test.dart' show Host;

void main() {
  group('R6 offline indicator', () {
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
      controller.connectionStatus.accessAvailable();
    });
    // SETUP
    tearDown(() {
      controller.dispose();
      appPreferences.dispose();
    });

    test(
      'R6: a lost device network reports offline at once, even mid-recovery, until restored',
      () {
        final status = ServerConnectionStatus('Claw');
        addTearDown(status.dispose);
        status.accessAvailable();
        status.liveChanged('work', true);
        expect(status.phase, ServerConnectionPhase.connected);
        // An unrelated, in-flight server-side recovery would normally keep the
        // phase at "reconnecting" (see the independent-observations test
        // above); the device's own network loss must override that display.
        status.beginRecovery('work');
        expect(status.phase, ServerConnectionPhase.reconnecting);
        status.networkLost();
        expect(status.phase, ServerConnectionPhase.disconnected);
        // The in-flight recovery can finish while the radio is still down; the
        // network signal, not the recovery outcome, must stay authoritative.
        status.endRecovery('work');
        expect(status.phase, ServerConnectionPhase.disconnected);
        status.networkRestored();
        expect(status.phase, ServerConnectionPhase.connected);
      },
    );

    test(
      'R6: a message queued during a real network outage shows offline at once and sends exactly once on reconnect',
      () async {
        final chat = await controller.createChat(canDispatch: () => true);
        await controller.updateDraft(chat, 'Queue me please');
        // The gateway would throw if a drain were attempted right now; the
        // queue must not even try while the device has no network.
        host.promptSubmitFails = true;

        controller.networkUnavailable();
        expect(controller.connectionStatus.description, 'Disconnected');

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
        controller.networkRestored();
        await controller.reconnect(chat.key.workspace);

        expect(chat.composer.observation.queue, isEmpty);
        expect(host.calls.where((c) => c.$2 == 'prompt.submit'), hasLength(1));
        expect(
          controller.connectionStatus.phase,
          ServerConnectionPhase.connected,
        );
      },
    );
  });
}
