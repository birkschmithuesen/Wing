import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import '../profile_connection_identity_test.dart' show identityTestConnection;
import '../support/profile_browser_fixture.dart';

// t_0f45a26f: a device measurement (card t_9fa64f90) showed `resumed` ->
// `visible_chat_resumed` taking 7-10s in a single retained chat. Root cause:
// `gateway.resume()` (profile_gateway.dart, `session.resume`) shipped the
// whole display transcript over the socket (no `omit_messages`), and
// `_resumeRetainedChat` (profile_workspace_controller.dart) then awaited the
// REST transcript page - including any inlined image data URIs - before
// logging the step, so both scaled with this chat's saved content instead of
// staying flat.
//
// This fixture models a ~0.5 MB/s link: every `session.resume` and
// `sessions/<id>/messages` response is delayed by its own encoded byte size
// divided by that rate, exactly like a slow connection actually would.
const _linkBytesPerSecond = 500 * 1024;

Duration _transferTime(Object payload) {
  final bytes = utf8.encode(jsonEncode(payload)).length;
  final micros = bytes / _linkBytesPerSecond * Duration.microsecondsPerSecond;
  return Duration(microseconds: micros.round());
}

const _messageCount = 5000;
final _imageRowIds = {
  for (var i = _messageCount - 7; i <= _messageCount; i++) i,
};
// ~100 KB of inlined image data per row - the shape `inline_images` (default
// true) produces for a stored attachment, per Hermes
// `tui_gateway/contracts/sessions.py` `SessionResumeParams`.
final _bigImage = 'data:image/png;base64,${'A' * 100000}';

class _ThrottledHistoryFixture extends ProfileBrowserFixture {
  // Flipped to true only once the reconnect under test starts, so the
  // initial `openSession` in setUp never pays for the big transcript.
  bool big = false;

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) {
    if (!big) return [{'id': 1, 'role': 'assistant', 'content': 'hello'}];
    return [
      for (var i = 1; i <= _messageCount; i++)
        {
          'id': i,
          'role': i.isEven ? 'assistant' : 'user',
          'content': _imageRowIds.contains(i) ? _bigImage : 'message $i',
        },
    ];
  }

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: base.connect,
      get: (path, query) async {
        final result = await base.read(path, query);
        final delay = _transferTime(result);
        if (path.endsWith('/messages') && delay > Duration.zero) {
          await Future<void>.delayed(delay);
        }
        return result;
      },
      rpc: (method, params) async {
        var result = await base.call(method, params);
        if (method == 'session.resume') {
          // Hermes ships the full display transcript unless the caller
          // opts into tip-only resume (`SessionResumeParams.omit_messages`,
          // default false) - Wing's `refreshHistory` already re-fetches the
          // transcript over REST, so a reverted fix here would resend it.
          if (params['omit_messages'] != true) {
            result = {
              ...result,
              'messages': historyRows(
                scope.profileName,
                params['session_id'] as String,
              ),
            };
          }
          final delay = _transferTime(result);
          if (delay > Duration.zero) await Future<void>.delayed(delay);
        }
        return result;
      },
    );
  }
}

void main() {
  late _ThrottledHistoryFixture fixture;
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
    fixture = _ThrottledHistoryFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'resume-bandwidth',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
    debugPrint = previousPrint;
  });

  test(
    'visible chat resume stays flat on a throttled link, independent of a '
    '${_messageCount}-message transcript with embedded images in its most '
    'recent page (t_0f45a26f)',
    () async {
      final scope = controller.current!.scope;
      await controller.openSession(ProfileSessionKey(scope, 'visible'));
      expect(controller.current!.selectedSession, 'visible');
      final chat = controller.current!.chat!;

      fixture.big = true;
      final recovering = controller.reconnect(scope);
      // Nothing on the way to `visible_chat_resumed` depends on the
      // throttled transcript/image transfer below - pumping the event queue
      // (no real `Timer` fires) is enough to reach it.
      await pumpEventQueue();

      expect(
        events()
            .where((e) => e['event'] == 'workspace.recovery_step')
            .map((e) => e['step']),
        contains('visible_chat_resumed'),
        reason:
            'The visible chat must be live well under the 2s target on a '
            '0.5 MB/s link, independent of this chat\'s saved transcript '
            'length or its embedded image bytes.',
      );
      expect(
        chat.runtime.blocksTurnAdmission,
        isFalse,
        reason:
            'The visible chat must admit turns immediately, not after its '
            'transcript/image page finishes transferring.',
      );

      // Let the deferred transcript/image transfer actually finish so the
      // reconnect settles cleanly and no timer leaks into the next test.
      await recovering;
      expect(chat.reading.messages, isNotEmpty);
    },
  );
}
