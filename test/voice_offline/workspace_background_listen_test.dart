import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';

import '../support/headphone_route_fixture.dart';
import '../support/voice_workspace_fixture.dart';

/// Card t_482d3051: Wing's native memory grew to 1.1 GB and CPU spun on the
/// raster and WingVad/DartWorker threads while paused with conversation mode
/// on. Root cause: an open barge-in listen round (TurnListener) restarted
/// itself on silence forever, never re-checking app focus once opened -
/// going `inactive` without a held background voice service (no car mode,
/// no held notification) left it running, cycling native VAD/AudioRecord
/// sessions indefinitely. These tests pin the fix: the loop closes instead.
void main() {
  late VoiceWorkspaceHarness h;
  setUp(() async {
    h = VoiceWorkspaceHarness();
    await h.setUp();
  });
  tearDown(() => h.tearDown());

  testWidgets(
    'going inactive without a held background service closes an open '
    'listen round instead of leaving it cycling',
    (tester) async {
      // The native background voice hold never succeeds: no car mode, no
      // granted foreground-service hold - the field incident's plausible
      // unsupervised case.
      h.background.grant = false;
      h.route.route = HeadphoneRouteFixture.headphones;
      await h.controller.preferences.setString(
        VoiceOfflinePrefs.bargeInPlaybackKey,
        'on',
      );
      h.device.playbackDelay = Completer<void>();
      await h.vadConversationTurn(tester);
      await h.completeReply(tester, 'Long reply read aloud.');
      expect(find.text('Listening'), findsOneWidget);
      final startsBefore = h.vadStarts();
      // `inactive` alone (not paused/hidden/detached) does not run the
      // screen's own cancel-on-pause path, so only the listener's own focus
      // check can end this round.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await h.settle(tester);
      // Two probability windows are nowhere near a pause/maxDuration
      // decision: the old code would keep listening for one. Losing focus
      // must close the round on the very next device event instead of
      // waiting for silence to decide something.
      await h.windows(tester, 0.3, 2);
      expect(find.text('Listening'), findsNothing);
      expect(
        h.vadStarts(),
        startsBefore,
        reason: 'the round closed, it did not restart',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await h.settle(tester);
    },
  );
}
