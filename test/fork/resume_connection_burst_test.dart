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
    'resumeConnection resumes the current profile first and alone, and '
    'leaves idle background profiles disconnected',
    () async {
      // 'c' sits in the middle of host.profiles; setUp's last openSession
      // call made 'e' current. Re-select 'c' so it is the selected profile
      // while staying in the middle of _resources' iteration order - the
      // exact arrangement that could seat it behind other profiles in a
      // batch of 3 under the old list-order-only batching (t_1d748269).
      await controller.openSession(
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: controller.connection.id,
            connectionIdentity: controller.connectionIdentity,
            profileName: 'c',
          ),
          'same',
        ),
      );
      for (final name in host.profiles) {
        host.gateways[name]!.onConnectionChanged!(false);
      }
      host.connectOrder.clear();
      host.connectDelay = Completer<void>();
      final resumed = controller.resumeConnection(networkChanged: true);
      await pumpEventQueue();
      expect(
        host.connectOrder,
        ['c'],
        reason:
            'The selected profile must resume first and alone, before any '
            'background profile is even started, so its own recovery '
            'cannot sit behind unrelated profiles in a batch.',
      );
      host.connectDelay!.complete();
      await resumed;
      // Fork (t_15b221a3): acceptance item 4 of t_a8358240 - none of 'a',
      // 'b', 'd', 'e' has a turn awaiting admission or an unrestored
      // pending input, so a resume must not reconnect them at all. They
      // open their own socket lazily the next time the user actually
      // visits them (switchProfile/openSession already call
      // gateway.connect()).
      expect(host.connectOrder, ['c']);
    },
  );

  test(
    'resumeConnection does not reconnect idle background profiles at all; '
    'at most the selected profile opens a socket (acceptance item 4 of '
    't_a8358240)',
    () async {
      for (final name in host.profiles) {
        host.gateways[name]!.onConnectionChanged!(false);
      }
      host.connectCalls = 0;
      host.connectDelay = Completer<void>();
      final resumed = controller.resumeConnection(networkChanged: true);
      await pumpEventQueue();
      host.connectDelay!.complete();
      await resumed;
      expect(
        host.connectCalls,
        lessThanOrEqualTo(2),
        reason:
            'At most one gateway socket per instance (small bounded pool, '
            '<= 2), opened lazily: an idle resume with no pending turn '
            'anywhere must not reconnect every served profile, even '
            'batched (t_b7f69683 still did, just staggered).',
      );
      expect(
        host.connectCalls,
        1,
        reason:
            "Only the selected profile ('e', the last openSession in "
            'setUp) has any reason to resume eagerly here; the other four '
            'are merely loaded, not pending anything.',
      );
    },
  );

  test(
    'resumeConnection still eagerly resumes a background profile with a '
    'turn still awaiting admission, not just the selected profile',
    () async {
      // Give profile 'b' (not the soon-to-be-selected 'c') a turn still
      // awaiting admission, so it has genuine pending work that a
      // first-real-use-only connect would otherwise strand.
      await controller.openSession(
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: controller.connection.id,
            connectionIdentity: controller.connectionIdentity,
            profileName: 'b',
          ),
          'same',
        ),
      );
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('still sending');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      expect(chat.runtime.blocksTurnAdmission, isTrue);

      await controller.openSession(
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: controller.connection.id,
            connectionIdentity: controller.connectionIdentity,
            profileName: 'c',
          ),
          'same',
        ),
      );
      for (final name in host.profiles) {
        host.gateways[name]!.onConnectionChanged!(false);
      }
      host.connectOrder.clear();
      host.connectDelay = Completer<void>();
      final resumed = controller.resumeConnection(networkChanged: true);
      await pumpEventQueue();
      host.connectDelay!.complete();
      await resumed;
      expect(
        host.connectOrder.toSet(),
        {'c', 'b'},
        reason:
            "'c' is the selected profile and resumes eagerly; 'b' has a "
            'turn still awaiting admission, which is genuine "first real '
            'use", not an idle, merely-visited profile. The other idle '
            "profiles ('a', 'd', 'e') must stay deferred.",
      );
      host.promptSubmitDelay!.complete();
      await sending;
    },
  );
}
