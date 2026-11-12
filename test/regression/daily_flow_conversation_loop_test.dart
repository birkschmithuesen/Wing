import 'dart:async';
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

  group('R1 conversation loop', () {
    testWidgets('R1: conversation mode sends a dictation that ended on its own', (
      tester,
    ) async {
      await h.conversationMode(true);
      await h.show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await h.sayFinal(tester, 'How is the weather');
      expect(h.prompts(), 1);
      expect(
        h.fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
        'How is the weather',
      );
      expect(h.controller.current!.chat!.composer.observation.text, isEmpty);
      h.gatewayEvent('message.complete', {'text': 'Done.'});
      await h.settle(tester);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    });

    testWidgets('R1: conversation reopens the microphone after the reply was spoken', (
      tester,
    ) async {
      await h.conversationMode(true);
      h.device.playbackDelay = Completer<void>();
      await h.show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await h.sayFinal(tester, 'Question one');
      expect(h.starts(), 1);
      h.gatewayEvent('message.complete', {'text': 'Answer one.'});
      await tester.pump();
      await tester.pump();
      expect(h.device.spoken, 'Answer one.');
      // Still speaking: the microphone stays closed until playback ended.
      expect(h.starts(), 1);
      h.device.playbackDelay!.complete();
      h.device.playbackDelay = null;
      await h.settle(tester);
      expect(h.starts(), 2);
      expect(find.textContaining('Recording ·'), findsOneWidget);
      // Second round trip continues the loop.
      await h.sayFinal(tester, 'Question two');
      expect(h.prompts(), 2);
      await h.completeReply(tester, 'Answer two.');
      expect(h.starts(), 3);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    });

    testWidgets('R1: vad conversation sends after the pause', (tester) async {
      await h.listenTurn(false);
      await h.vadRoute();
      await h.conversationMode(true);
      await h.show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      expect(h.vadStarts(), 1);
      await h.windows(tester, 0.9, 30);
      await h.windows(tester, 0.1, 60);
      expect(h.device.finishes.single.reason.name, 'pause');
      expect(h.prompts(), 1);
      expect(
        h.fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
        'Hello from the phone',
      );
      h.gatewayEvent('message.complete', {'text': 'Done.'});
      await h.settle(tester);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    });
  });
}
