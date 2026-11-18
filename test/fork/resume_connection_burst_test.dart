import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import '../profile_connection_identity_test.dart' show identityTestConnection;
import '../profile_workspace_controller_test.dart' show Host;

void main() {
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = Host()
      ..running = false
      ..profiles = ['a', 'b', 'c', 'd', 'e'];
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'resume-burst',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    // Load every profile (the chat overview's filter chips touch each one),
    // same as the retained-profile fan-out behind t_a8358240's socket burst.
    for (final name in host.profiles) {
      await controller.openSession(
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: controller.connection.id,
            connectionIdentity: controller.connectionIdentity,
            profileName: name,
          ),
          'same',
        ),
      );
    }
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'resumeConnection batches per-profile reconnects instead of opening every '
    'profile socket at once',
    () async {
      // Every profile's socket is still open and reporting live right after
      // setUp's openSession calls; resumeConnection's liveAvailable fast path
      // (a cheap session.active_list probe, see _resumeResource) correctly
      // skips a full reconnect for those. The reported burst only happens
      // once sockets actually go stale (background/foreground, network
      // blip), so simulate that here the same way the gateway itself would
      // report it losing its connection.
      for (final name in host.profiles) {
        host.gateways[name]!.onConnectionChanged!(false);
      }
      host.connectCalls = 0;
      host.connectDelay = Completer<void>();
      final resumed = controller.resumeConnection(networkChanged: true);
      await pumpEventQueue();
      expect(
        host.connectCalls,
        lessThan(host.profiles.length),
        reason:
            'A foreground/network-restore resume must not open a gateway '
            'socket for every served profile at once (reported server-side '
            'as a stalled event loop, t_a8358240).',
      );
      final firstBatch = host.connectCalls;
      expect(firstBatch, greaterThan(0));
      host.connectDelay!.complete();
      await resumed;
      expect(
        host.connectCalls,
        host.profiles.length,
        reason: 'Batching must still resume every profile, just not at once.',
      );
    },
  );
}
