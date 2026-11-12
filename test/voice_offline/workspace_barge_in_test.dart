import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/barge_in_policy.dart';
import 'package:wing/voice_offline/headphone_route.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import '../support/headphone_route_fixture.dart';
import '../support/voice_workspace_fixture.dart';

void main() {
  late VoiceWorkspaceHarness h;
  setUp(() async {
    h = VoiceWorkspaceHarness();
    await h.setUp();
  });
  tearDown(() => h.tearDown());

  Future<void> bargeInPlayback(bool on) => h.controller.preferences.setString(
    VoiceOfflinePrefs.bargeInPlaybackKey,
    on ? 'on' : 'off',
  );
  int playbackStops() => h.device.calls.where((c) => c == 'stopPlayback').length;

  /// A conversation turn whose reply is being read aloud (playback held).
  Future<void> readingAloud(WidgetTester tester, OutputRoute output) async {
    h.route.route = output;
    await bargeInPlayback(true);
    h.device.playbackDelay = Completer<void>();
    await h.vadConversationTurn(tester);
    await h.completeReply(tester, 'Lange Antwort.');
    expect(h.device.spoken, 'Lange Antwort.');
  }

  Future<void> finishReading(WidgetTester tester) async {
    h.device.playbackDelay!.complete();
    h.device.playbackDelay = null;
    await h.settle(tester);
  }

  testWidgets('with headphones, speaking during read-aloud stops it and sends', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.headphones);
    expect(find.text('Listening'), findsOneWidget);
    final stopsBefore = playbackStops();
    h.device.vadTranscript = 'Testsatz zwei, stopp';
    await h.windows(tester, 0.95, 40);
    expect(playbackStops(), greaterThan(stopsBefore));
    await finishReading(tester);
    await h.windows(tester, 0.1, 60);
    expect(h.prompts(), 2);
    expect(
      h.fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      startsWith('Testsatz zwei, stopp'),
    );
    await tester.tap(find.text('Stop listening'));
    await h.settle(tester);
  });

  testWidgets('with headphones, a cough during read-aloud changes nothing', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.headphones);
    final stopsBefore = playbackStops();
    await h.windows(tester, 0.8, 14);
    await h.windows(tester, 0.1, 60);
    expect(playbackStops(), stopsBefore);
    expect(h.prompts(), 1);
    await finishReading(tester);
    // Read-aloud ended normally: the open round now listens for the next prompt.
    expect(find.text('Listening'), findsOneWidget);
    await tester.tap(find.text('Stop listening'));
    await h.settle(tester);
  });

  testWidgets(
    'with headphones, Birk\'s on-device cough run (p=0.5, 18 windows) '
    'changes nothing',
    (tester) async {
      // Anlass: Birk measured wouldTrigger=1 at p>=0.5 over run50=18 on a
      // probe profile build. The actual gate only counts a window at
      // p >= bargeGateThreshold (0.7), so p=0.5 never advances the run.
      await readingAloud(tester, HeadphoneRouteFixture.headphones);
      final stopsBefore = playbackStops();
      await h.windows(tester, 0.5, 18);
      await h.windows(tester, 0.1, 60);
      expect(playbackStops(), stopsBefore);
      expect(h.prompts(), 1);
      await finishReading(tester);
      expect(find.text('Listening'), findsOneWidget);
      await tester.tap(find.text('Stop listening'));
      await h.settle(tester);
    },
  );

  testWidgets(
    'with Bluetooth headphones, speaking during read-aloud stops it and sends',
    (tester) async {
      await readingAloud(tester, HeadphoneRouteFixture.bluetoothHeadphones);
      expect(find.text('Listening'), findsOneWidget);
      final stopsBefore = playbackStops();
      h.device.vadTranscript = 'Testsatz zwei, stopp';
      await h.windows(tester, 0.95, 40);
      expect(playbackStops(), greaterThan(stopsBefore));
      await finishReading(tester);
      await h.windows(tester, 0.1, 60);
      expect(h.prompts(), 2);
      await tester.tap(find.text('Stop listening'));
      await h.settle(tester);
    },
  );

  testWidgets(
    'with a non-headphone Bluetooth device, speaking during read-aloud does '
    'not stop it',
    (tester) async {
      await readingAloud(tester, HeadphoneRouteFixture.bluetoothOther);
      expect(find.text('Listening'), findsNothing);
      final stopsBefore = playbackStops();
      await h.windows(tester, 0.95, 40);
      await h.windows(tester, 0.1, 60);
      expect(playbackStops(), stopsBefore);
      expect(h.prompts(), 1);
      await finishReading(tester);
      expect(find.textContaining('Recording ·'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets('over the speaker, speaking during read-aloud does not stop it', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.speaker);
    expect(find.text('Listening'), findsNothing);
    final starts = h.vadStarts();
    final stopsBefore = playbackStops();
    await h.windows(tester, 0.95, 40);
    await h.windows(tester, 0.1, 60);
    expect(playbackStops(), stopsBefore);
    expect(h.vadStarts(), starts);
    expect(h.prompts(), 1);
    await finishReading(tester);
    expect(find.textContaining('Recording ·'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('unplugging headphones during read-aloud closes the round', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.headphones);
    expect(find.text('Listening'), findsOneWidget);
    h.route.change(HeadphoneRouteFixture.speaker);
    await h.settle(tester);
    expect(find.text('Listening'), findsNothing);
    final stopsBefore = playbackStops();
    await h.windows(tester, 0.95, 40);
    expect(playbackStops(), stopsBefore);
    await finishReading(tester);
    expect(find.textContaining('Recording ·'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
  });

  testWidgets('plugging headphones in during read-aloud opens the round', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.speaker);
    expect(find.text('Listening'), findsNothing);
    h.route.change(HeadphoneRouteFixture.headphones);
    await h.settle(tester);
    expect(find.text('Listening'), findsOneWidget);
    expect(h.device.vadOptions!.keepPlayback, isTrue);
    await finishReading(tester);
    await tester.tap(find.text('Stop listening'));
    await h.settle(tester);
  });

  testWidgets(
    'a Bluetooth headphone route change during read-aloud opens the round',
    (tester) async {
      await readingAloud(tester, HeadphoneRouteFixture.speaker);
      expect(find.text('Listening'), findsNothing);
      h.route.change(HeadphoneRouteFixture.bluetoothHeadphones);
      await h.settle(tester);
      expect(find.text('Listening'), findsOneWidget);
      expect(h.device.vadOptions!.keepPlayback, isTrue);
      await finishReading(tester);
      await tester.tap(find.text('Stop listening'));
      await h.settle(tester);
    },
  );

  testWidgets(
    'losing the Bluetooth headphone route during read-aloud closes the round',
    (tester) async {
      await readingAloud(tester, HeadphoneRouteFixture.bluetoothHeadphones);
      expect(find.text('Listening'), findsOneWidget);
      h.route.change(HeadphoneRouteFixture.speaker);
      await h.settle(tester);
      expect(find.text('Listening'), findsNothing);
      final stopsBefore = playbackStops();
      await h.windows(tester, 0.95, 40);
      expect(playbackStops(), stopsBefore);
      await finishReading(tester);
      expect(find.textContaining('Recording ·'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets(
    'switching to a non-headphone Bluetooth device during read-aloud does '
    'not open the round',
    (tester) async {
      await readingAloud(tester, HeadphoneRouteFixture.speaker);
      expect(find.text('Listening'), findsNothing);
      h.route.change(HeadphoneRouteFixture.bluetoothOther);
      await h.settle(tester);
      expect(find.text('Listening'), findsNothing);
      await finishReading(tester);
      expect(find.textContaining('Recording ·'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets('the message after a barge-in carries the interrupted-reply hint', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.headphones);
    h.device.vadTranscript = 'Testsatz zwei, stopp';
    await h.windows(tester, 0.95, 40);
    await finishReading(tester);
    await h.windows(tester, 0.1, 60);
    expect(
      h.fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      withInterruptedReplyHint('Testsatz zwei, stopp'),
    );
    await tester.tap(find.text('Stop listening'));
    await h.settle(tester);
  });

}
