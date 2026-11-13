import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/barge_in_coordinator.dart';
import 'package:wing/voice_offline/barge_in_policy.dart';
import 'package:wing/voice_offline/headphone_route.dart';
import 'package:wing/voice_offline/turn_listener.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import '../support/headphone_route_fixture.dart';
import '../support/voice_fixture.dart';
import '../support/voice_workspace_fixture.dart';

class _Target implements ListenTarget {
  ListenChatState current = ListenChatState.steerable;
  bool steerAnswer = true;
  ListenChatState? stateAfterSteer;
  final log = <String>[];

  @override
  ListenChatState get state => current;
  @override
  Future<bool> steer(String text) async {
    log.add('steer:$text');
    if (stateAfterSteer != null) current = stateAfterSteer!;
    return steerAnswer;
  }

  @override
  Future<void> queue(String text) async => log.add('queue:$text');
  @override
  Future<void> send(String text) async => log.add('send:$text');
}

const settings = VoiceOfflinePrefs(conversation: true);

void main() {
  group('R8 barge-in hint (workspace)', () {
    late VoiceWorkspaceHarness h;
    // SETUP
    setUp(() async {
      h = VoiceWorkspaceHarness();
      await h.setUp();
    });
    // SETUP
    tearDown(() => h.tearDown());

    Future<void> bargeInPlayback(bool on) => h.controller.preferences.setString(
      VoiceOfflinePrefs.bargeInPlaybackKey,
      on ? 'on' : 'off',
    );

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

    testWidgets('R8: the message after a barge-in carries the interrupted-reply hint', (
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
  });

  group('R8 barge-in hint (policy)', () {
    test('R8: the interrupted-reply hint follows the words after a blank line', () {
      expect(
        withInterruptedReplyHint('Testsatz zwei, stopp '),
        'Testsatz zwei, stopp\n\n'
        '[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen '
        'und nicht zu Ende gehört.]',
      );
    });

    test('R8: the interrupted-reply hint text', () {
      expect(
        withInterruptedReplyHint('Testsatz zwei, stopp '),
        'Testsatz zwei, stopp\n\n[Hinweis von Wing: Die vorige Antwort wurde '
        'beim Vorlesen abgebrochen und nicht zu Ende gehört.]',
      );
    });
  });

  group('R8 barge-in hint (coordinator)', () {
    late VoiceDeviceFixture device;
    late BargeInCoordinator coordinator;
    late _Target target;

    // SETUP
    setUp(() async {
      device = VoiceDeviceFixture();
      coordinator = BargeInCoordinator(TurnListener(device: device));
      target = _Target();
      await coordinator.open('chat-a', target, settings);
    });
    // SETUP
    tearDown(() async {
      coordinator.dispose();
      await device.stream.close();
    });

    Future<void> utter(String text) async {
      device.vadTranscript = text;
      device.emitWindows(List.filled(20, 0.9));
      device.emitWindows(List.filled(60, 0.1));
      await pumpEventQueue();
      await coordinator.settled;
    }

    Future<void> bargeIn(String text) async {
      await coordinator.open(
        'chat-a',
        target,
        settings,
        playback: true,
        onBarge: () async {},
      );
      await utter(text);
    }

    test('R8: words that cut off read-aloud carry the hint when sent or queued', () async {
      target.current = ListenChatState.idle;
      await bargeIn('Testsatz zwei, stopp');
      target.current = ListenChatState.busy;
      await bargeIn('Testsatz drei');
      expect(target.log, [
        'send:${withInterruptedReplyHint('Testsatz zwei, stopp')}',
        'queue:${withInterruptedReplyHint('Testsatz drei')}',
      ]);
    });
  });
}
