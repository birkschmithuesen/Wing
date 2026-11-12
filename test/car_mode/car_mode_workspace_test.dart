import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/car_mode/car_mode_screen.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import '../support/voice_workspace_fixture.dart';

void main() {
  late VoiceWorkspaceHarness h;
  setUp(() async {
    h = VoiceWorkspaceHarness();
    await h.setUp();
  });
  tearDown(() => h.tearDown());

  testWidgets('car mode case 2: three rounds by tap only, read aloud, then idle with the mic closed', (
    tester,
  ) async {
    await h.vadRoute();
    await h.conversationMode(false);
    await h.show(tester);
    await h.openCarMode(tester);
    expect(find.byType(CarModeScreen), findsOneWidget);
    expect(find.text('Tap to talk'), findsOneWidget);
    expect(h.device.keepScreenOnCalls, [true]);
    for (var round = 1; round <= 3; round++) {
      await h.tapCar(tester); // tap = start recording
      expect(h.vadStarts(), round);
      expect(find.text('Listening'), findsOneWidget);
      await h.windows(tester, 0.9, 30);
      await h.windows(tester, 0.1, 200); // 6.4 s of silence: no automatic end in case 2
      expect(h.device.finishes, hasLength(round - 1));
      expect(h.prompts(), round - 1);
      await h.tapCar(tester); // tap = stop and send
      expect(h.device.finishes.last.reason.name, 'mediaKey');
      expect(h.prompts(), round);
      await h.completeReply(tester, 'Answer $round.');
      expect(h.device.spoken, 'Answer $round.'); // read aloud although Spoken replies is off
      expect(h.vadStarts(), round); // the microphone stays closed
      expect(find.text('Tap to talk'), findsOneWidget);
    }
    expect(h.controller.preferences.getString(VoiceOfflinePrefs.conversationKey), 'off');
    expect(h.controller.preferences.getString(VoiceOfflinePrefs.autoSpeakKey), isNot('on'));
    await h.swipeOut(tester);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(h.device.keepScreenOnCalls.last, isFalse);
  });

  testWidgets('car mode: the loop switch, once turned on, reopens the microphone after the answer', (tester) async {
    await h.conversationMode(true); // saved preference; car mode ignores it and starts with the loop off (t_ce610125)
    await h.show(tester);
    await h.openCarMode(tester);
    await h.tapCar(tester);
    expect(h.starts(), 1);
    final id = h.device.recording;
    await h.tapCar(tester); // end of speech not detected: the tap sends now
    h.device.stream.add({'id': id, 'text': 'Question', 'final': true});
    await h.settle(tester);
    expect(h.prompts(), 1);
    await h.completeReply(tester, 'Answer.');
    expect(h.device.spoken, 'Answer.');
    expect(h.starts(), 1, reason: 'the loop switch starts off; the saved preference is ignored');
    expect(find.text('Tap to talk'), findsOneWidget);

    await h.toggleCarLoop(tester); // flips the session-local switch on
    await h.tapCar(tester);
    expect(h.starts(), 2);
    final id2 = h.device.recording;
    await h.tapCar(tester); // end of speech not detected: the tap sends now
    h.device.stream.add({'id': id2, 'text': 'Question two', 'final': true});
    await h.settle(tester);
    expect(h.prompts(), 2);
    await h.completeReply(tester, 'Answer two.');
    expect(h.device.spoken, 'Answer two.');
    expect(h.starts(), 3, reason: 'the loop switch, once on, reopened the microphone');
    expect(find.text('Listening'), findsOneWidget);

    await h.swipeOut(tester);
    expect(h.device.recording, isNull);
  });

  testWidgets('car mode: a tap during read-aloud stops it, then opens the microphone', (tester) async {
    h.device.playbackDelay = Completer<void>();
    await h.show(tester);
    await h.openCarMode(tester);
    await h.tapCar(tester);
    final id = h.device.recording;
    await h.tapCar(tester);
    h.device.stream.add({'id': id, 'text': 'Question', 'final': true});
    await h.settle(tester);
    h.gatewayEvent('message.complete', {'text': 'A long answer.'});
    await tester.pump();
    await tester.pump();
    expect(find.text('Reading aloud'), findsOneWidget);
    h.device.calls.clear();
    await h.tapCar(tester);
    expect(h.device.calls, contains('stopPlayback'));
    expect(h.device.calls.indexOf('stopPlayback'), lessThan(h.device.calls.indexOf('start')));
    expect(find.text('Listening'), findsOneWidget);
    h.device.playbackDelay!.complete();
    h.device.playbackDelay = null;
    await h.swipeOut(tester);
  });

  testWidgets('car mode: focus stays under the car route (media keys on)', (tester) async {
    await h.vadRoute();
    await h.show(tester);
    await h.openCarMode(tester);
    // The "Chat actions" menu itself briefly covers the workspace before car
    // mode is entered; only the settled state (media keys on) matters here.
    expect(h.device.mediaKeysCalls.last, isTrue);
    await h.tapCar(tester);
    await h.windows(tester, 0.9, 30);
    await h.tapCar(tester);
    expect(h.prompts(), 1);
    expect(h.device.mediaKeysCalls.last, isTrue);
    h.gatewayEvent('message.complete', {'text': 'Done.'});
    await h.settle(tester);
    await h.swipeOut(tester);
  });

  testWidgets('car mode: a swipe exit cancels the recording and keeps the draft', (tester) async {
    final chat = h.controller.current!.chat!;
    await h.controller.updateDraft(chat, 'Typed before');
    await h.show(tester);
    await h.openCarMode(tester);
    await h.tapCar(tester);
    final id = h.device.recording;
    await h.swipeOut(tester);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(h.device.cancelled, contains(id));
    expect(chat.composer.observation.text, 'Typed before');
    expect(h.prompts(), 0);
  });

  testWidgets('car mode: the status line shows the running tool by name only', (tester) async {
    await h.show(tester);
    await h.openCarMode(tester);
    h.gatewayEvent('message.start');
    h.gatewayEvent('tool.start', {'name': 'terminal', 'tool_id': 't1', 'context': 'rm -rf /tmp/secret'});
    await h.settle(tester);
    expect(find.text('Hermes is working'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    h.gatewayEvent('message.complete', {'text': 'Done.'});
    await h.settle(tester);
    await h.swipeOut(tester);
  });

  testWidgets('car mode: a recording finished offline waits and is sent once after reconnect', (
    tester,
  ) async {
    await h.vadRoute();
    await h.show(tester);
    await h.openCarMode(tester);
    await h.tapCar(tester);
    h.controller.connectionStatus.failRecovery('car-test', 'Offline');
    await h.settle(tester);
    expect(find.text('Offline'), findsOneWidget);
    await h.windows(tester, 0.9, 30); // recording goes on offline
    await h.tapCar(tester);
    expect(h.prompts(), 0);
    expect(find.text('Waiting for connection'), findsOneWidget);
    expect(h.controller.current!.chat!.draft, 'Hello from the phone'); // kept on the device
    h.controller.connectionStatus.endRecovery('car-test');
    await h.settle(tester);
    expect(h.prompts(), 1);
    expect(
      h.fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'Hello from the phone',
    );
    h.controller.connectionStatus.liveChanged('car-test', true); // more notifications
    await h.settle(tester);
    expect(h.prompts(), 1);
    await h.completeReply(tester, 'Got it.');
    expect(h.device.spoken, 'Got it.');
    await h.swipeOut(tester);
  });

  testWidgets(
    'car mode: a real network outage shows offline at once; the recording waits and sends once after reconnect',
    (tester) async {
      await h.vadRoute();
      await h.show(tester);
      await h.openCarMode(tester);
      await h.tapCar(tester);
      h.controller.networkUnavailable();
      await h.settle(tester);
      // Authoritative at once: not masked by the reconnect attempt's own
      // backoff (which this harness never even lets run, by design).
      expect(
        h.controller.connectionStatus.phase,
        ServerConnectionPhase.disconnected,
      );
      expect(find.text('Offline'), findsOneWidget);
      await h.windows(tester, 0.9, 30); // recording goes on offline
      await h.tapCar(tester);
      expect(h.prompts(), 0);
      expect(find.text('Waiting for connection'), findsOneWidget);
      expect(h.controller.current!.chat!.draft, 'Hello from the phone'); // kept on the device
      h.controller.networkRestored();
      await tester.runAsync(
        () => h.controller.resumeConnection(networkChanged: true),
      );
      await h.settle(tester);
      expect(h.prompts(), 1);
      expect(
        h.fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
        'Hello from the phone',
      );
      await h.completeReply(tester, 'Got it.');
      expect(h.device.spoken, 'Got it.');
      await h.swipeOut(tester);
    },
  );

  testWidgets('car mode: a pending approval shows on screen and the tap does nothing', (tester) async {
    await h.show(tester);
    await h.openCarMode(tester);
    h.gatewayEvent('approval', {'request_id': 'approve-1', 'command': 'rm -rf build'});
    await h.settle(tester);
    expect(find.text('Needs you on screen'), findsOneWidget);
    // Session setup and the approval event itself already talk to
    // 'approval.pending'; only the tap's own effect matters here.
    final approvalCallsBeforeTap = h.fixture.calls
        .where((c) => c.$2.contains('approval'))
        .length;
    await h.tapCar(tester);
    expect(h.starts(), 0);
    expect(
      h.fixture.calls.where((c) => c.$2.contains('approval')).length,
      approvalCallsBeforeTap,
    );
    await h.swipeOut(tester);
  });

  testWidgets('car mode: speech during a running turn is steered into it', (tester) async {
    await h.show(tester);
    await h.openCarMode(tester);
    await h.tapCar(tester);
    var id = h.device.recording;
    await h.tapCar(tester);
    h.device.stream.add({'id': id, 'text': 'Plan the trip', 'final': true});
    await h.settle(tester);
    expect(h.prompts(), 1);
    h.gatewayEvent('message.start');
    await h.tapCar(tester); // thinking → microphone (tap while working, option A)
    id = h.device.recording;
    expect(id, isNotNull);
    await h.tapCar(tester);
    h.device.stream.add({'id': id, 'text': 'Also the weather', 'final': true});
    await h.settle(tester);
    expect(h.prompts(), 1);
    expect(
      h.fixture.calls.where((c) => c.$2 == 'session.steer').single.$3['text'],
      'Also the weather',
    );
    await h.swipeOut(tester);
  });

}
