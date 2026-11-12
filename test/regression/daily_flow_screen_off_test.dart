import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/voice_workspace_fixture.dart';

void main() {
  late VoiceWorkspaceHarness h;
  // SETUP
  setUp(() async {
    h = VoiceWorkspaceHarness();
    await h.setUp();
  });
  // SETUP
  tearDown(() => h.tearDown());

  group('R7 screen off', () {
    Future<void> startVadConversation(WidgetTester tester) async {
      // These tests count VAD starts, so listen rounds stay off here; Task 5
      // switches them on explicitly.
      await h.listenTurn(false);
      await h.vadRoute();
      await h.conversationMode(true);
      await h.show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await h.settle(tester);
    }

    Future<void> speakAndSend(WidgetTester tester) async {
      await h.windows(tester, 0.9, 30);
      await h.windows(tester, 0.1, 60);
    }

    void screenOff(WidgetTester tester) => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);

    void screenOn(WidgetTester tester) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    testWidgets('R7: a vad conversation holds while it runs', (tester) async {
      await startVadConversation(tester);
      expect(h.background.holds, [true]);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
      expect(h.background.holds, [true, false]);
    });

    testWidgets('R7: reading continues and the microphone reopens', (
      tester,
    ) async {
      h.device.playbackDelay = Completer<void>();
      await startVadConversation(tester);
      await speakAndSend(tester);
      expect(h.prompts(), 1);
      h.gatewayEvent('message.complete', {'text': 'Answer.'});
      await tester.pump();
      await tester.pump();
      expect(h.device.calls, contains('speak'));
      screenOff(tester);
      await tester.pump();
      expect(h.device.calls, isNot(contains('stopPlayback')));
      h.device.playbackDelay!.complete();
      h.device.playbackDelay = null;
      await h.settle(tester);
      expect(h.vadStarts(), 2);
      await speakAndSend(tester);
      expect(h.prompts(), 2);
      await h.completeReply(tester, 'Answer two.');
      expect(h.vadStarts(), 3);
      screenOn(tester);
      await h.settle(tester);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    });

    testWidgets('R7: a reply that arrives with the screen off is spoken', (
      tester,
    ) async {
      await startVadConversation(tester);
      await speakAndSend(tester);
      screenOff(tester);
      await tester.pump();
      await h.completeReply(tester, 'Pocket answer.');
      expect(h.device.spoken, 'Pocket answer.');
      expect(h.vadStarts(), 2);
      screenOn(tester);
      await h.settle(tester);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    });
  });
}
