import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';

import '../profile_connection_identity_test.dart' show identityTestConnection;
import '../profile_workspace_controller_test.dart' show Host;

// t_edbdd961: a device measurement showed `app.lifecycle resumed` ->
// `workspace.recovered profile=birk` taking 57.9 s. Root cause (file:line on
// the pre-fix tree): `_performReconnect` in
// `lib/core/services/profile_workspace_controller.dart` resumed every
// eligible retained chat of the selected profile SERIALLY in one `for` loop
// (around line 10735), and only called `connectionStatus.endRecovery` -
// which is what flips `ServerConnectionStatus.phase` out of `reconnecting`
// (server_connection_status.dart:119) - after that entire loop plus
// `_restorePendingForResource`, `_journal` and `_refreshSessions` finished
// (around line 10827). A profile with several retained chats still busy
// from before backgrounding (agent runs, approvals) therefore kept the
// selected profile's own connection indicator on "Reconnecting" for as long
// as the slowest of those background chats took, even though the visible
// chat's own socket (`ws.gateway_ready`, mirrored here by
// `ProfileGateway._liveChanged(true)` firing right after `gateway.connect()`
// resolves) was already healthy.
void main() {
  late Host host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late DebugPrintCallback previousPrint;
  late List<String> lines;
  List<Map<String, dynamic>> events() => lines
      .where((line) => line.startsWith('[WingConnection] '))
      .map(
        (line) =>
            jsonDecode(line.substring('[WingConnection] '.length))
                as Map<String, dynamic>,
      )
      .toList();

  setUp(() async {
    previousPrint = debugPrint;
    lines = [];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    SharedPreferences.setMockInitialValues({});
    host = Host()
      ..running = false
      ..profiles = ['a'];
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'visible-first',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
    debugPrint = previousPrint;
  });

  Future<void> openAndStick(String sessionId) async {
    final chat = (await controller.openSession(
      ProfileSessionKey(
        WorkspaceScope(
          connectionId: controller.connection.id,
          connectionIdentity: controller.connectionIdentity,
          profileName: 'a',
        ),
        sessionId,
      ),
    ))!;
    chat.composer.editText('still working on $sessionId');
    host.promptSubmitStarted = Completer<void>();
    host.promptSubmitDelay = Completer<void>();
    unawaited(controller.send(chat));
    await host.promptSubmitStarted!.future;
    expect(chat.runtime.blocksTurnAdmission, isTrue);
  }

  test(
    "the selected profile's visible chat resumes, and its connection "
    'indicator goes green, even while several other retained chats of the '
    'same profile are stuck resuming (does not scale with retained chat '
    'count, t_edbdd961)',
    () async {
      // Four background chats are busy (mid-turn) when the app backgrounds -
      // the realistic shape of the device repro, not an idle retained chat
      // (an idle, non-busy, non-visible chat is already skipped by the
      // eligibility filter and never contends for a socket round trip).
      for (final id in ['bg1', 'bg2', 'bg3', 'bg4']) {
        await openAndStick(id);
      }
      // Opened last, so it is also last in the resource's chat map
      // iteration order - the exact arrangement the old serial loop handled
      // worst: the visible chat sat behind every stuck background chat.
      await controller.openSession(
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: controller.connection.id,
            connectionIdentity: controller.connectionIdentity,
            profileName: 'a',
          ),
          'visible',
        ),
      );
      expect(controller.current!.selectedSession, 'visible');

      host.gateways['a']!.onConnectionChanged!(false);
      // Background chats' `session.resume` never returns - representative
      // of "slow", not just "eventually succeeds"; the selected profile
      // must not depend on them completing at all.
      host.resumeHold = (profile, sessionId) async {
        if (sessionId == 'visible') return;
        await Completer<void>().future;
      };

      unawaited(controller.resumeConnection());
      await pumpEventQueue();

      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.connected,
        reason:
            'The visible chat and the socket are both healthy; the '
            "indicator must not stay \"Reconnecting\" behind four stuck "
            'background chats.',
      );
      expect(
        events()
            .where((e) => e['event'] == 'workspace.recovery_step')
            .map((e) => e['step']),
        contains('visible_chat_resumed'),
      );
      expect(
        events().any((e) => e['event'] == 'workspace.recovered'),
        isFalse,
        reason:
            'The background chats are still stuck; the full pipeline '
            '(including the bounded-concurrency background sweep) has not '
            'finished, and must not need to for the indicator to go green.',
      );
    },
  );
}
