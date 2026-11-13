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

  group('R9 cancel keeps conversation', () {
    testWidgets(
      'R9: Cancel discards only the current recording; the loop reopens the '
      'microphone and keeps sending',
      (tester) async {
        await h.conversationMode(true);
        await h.show(tester);
        await tester.tap(find.byTooltip('Dictate message'));
        await tester.pump();
        expect(h.starts(), 1);
        expect(find.textContaining('Recording ·'), findsOneWidget);

        await tester.tap(find.byTooltip('Cancel recording'));
        await h.settle(tester);
        expect(h.prompts(), 0, reason: 'a cancelled recording is never sent');
        expect(h.starts(), 2, reason: 'the next listen round started');
        expect(find.textContaining('Recording ·'), findsOneWidget);

        // Cancelling again is one fresh round per tap, never a retry loop.
        await tester.tap(find.byTooltip('Cancel recording'));
        await h.settle(tester);
        expect(h.prompts(), 0);
        expect(h.starts(), 3);

        // The loop is still active: the next dictation is sent on its own.
        await h.sayFinal(tester, 'Still talking');
        expect(h.prompts(), 1);
        expect(
          h.fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
          'Still talking',
        );
        await h.completeReply(tester, 'Done.');
        expect(h.starts(), 4, reason: 'the loop continued after the reply');

        // End the loop cleanly: with the mode off, Cancel does not reopen.
        await h.conversationMode(false);
        await tester.tap(find.byTooltip('Cancel recording'));
        await h.settle(tester);
        expect(h.starts(), 4);
        expect(find.textContaining('Recording ·'), findsNothing);
      },
    );

    testWidgets('R9: Cancel outside conversation mode only discards', (
      tester,
    ) async {
      await h.show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      expect(h.starts(), 1);
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
      expect(h.prompts(), 0);
      expect(h.starts(), 1, reason: 'no loop, so the microphone stays closed');
      expect(find.textContaining('Recording ·'), findsNothing);
    });
  });
}
