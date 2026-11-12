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

  group('R2 unsolicited reply', () {
    testWidgets(
      'R2: an unsolicited reply while recording queues instead of cutting the '
      'recording off or ending the loop',
      (tester) async {
        await h.conversationMode(true);
        await h.show(tester);
        await tester.tap(find.byTooltip('Dictate message'));
        await tester.pump();
        await h.sayFinal(tester, 'Question one');
        await h.completeReply(tester, 'Answer one.');
        expect(h.device.spoken, 'Answer one.');
        expect(h.starts(), 2, reason: 'the mic reopened for the next round');
        expect(find.textContaining('Recording ·'), findsOneWidget);
        // A background job's own turn completes for this chat while the user
        // is recording their next utterance; it is unsolicited (the
        // conversation's own awaiting-reply flag was already consumed by the
        // first reply) and must not cut the recording off or break the loop.
        h.gatewayEvent('message.start');
        await h.completeReply(tester, 'Unsolicited answer.');
        expect(
          h.device.spoken,
          'Answer one.',
          reason: 'the unsolicited reply never speaks over the open mic',
        );
        expect(
          find.textContaining('Recording ·'),
          findsOneWidget,
          reason: 'the recording was not cut off',
        );
        // The user finishes their own turn; its reply speaks first, then the
        // queued unsolicited one, and the loop stays on afterwards.
        await h.sayFinal(tester, 'Question two');
        await h.completeReply(tester, 'Answer two.');
        expect(
          h.device.spoken,
          'Unsolicited answer.',
          reason: 'the queued reply speaks after the regular one, in order',
        );
        expect(
          h.starts(),
          3,
          reason: 'the loop stays on after the queued reply speaks',
        );
        await tester.tap(find.text('Cancel recording'));
        await h.settle(tester);
      },
    );

    testWidgets(
      'R2: an unsolicited reply while idle is spoken and the loop stays on',
      (tester) async {
        await h.conversationMode(true);
        h.device.playbackDelay = Completer<void>();
        await h.show(tester);
        await tester.tap(find.byTooltip('Dictate message'));
        await tester.pump();
        await h.sayFinal(tester, 'Question');
        await h.completeReply(tester, 'Answer.');
        expect(h.device.spoken, 'Answer.');
        // The regular reply is still playing: the mic has not reopened yet,
        // so it is genuinely idle from the mic's point of view. A background
        // job's own turn now completes for the same chat; it is unsolicited
        // (the conversation's own awaiting-reply flag was already consumed by
        // the first reply).
        h.gatewayEvent('message.start');
        h.gatewayEvent('message.complete', {'text': 'Unsolicited answer.'});
        await tester.pump();
        await tester.pump();
        expect(
          h.starts(),
          1,
          reason:
              'the microphone has not reopened yet: both replies queue '
              'behind playback',
        );
        // The regular reply finishes; the unsolicited one plays next instead
        // of being dropped or ending the loop.
        h.device.playbackDelay!.complete();
        h.device.playbackDelay = Completer<void>();
        await tester.pump();
        await tester.pump();
        expect(h.device.spoken, 'Unsolicited answer.');
        h.device.playbackDelay!.complete();
        h.device.playbackDelay = null;
        await h.settle(tester);
        expect(
          h.starts(),
          2,
          reason: 'the loop stays on: the mic reopens like after a normal reply',
        );
        await tester.tap(find.text('Cancel recording'));
        await h.settle(tester);
      },
    );

    testWidgets(
      'R2: a reply that arrives while one plays queues instead of cutting it off',
      (tester) async {
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
        expect(h.device.calls.where((c) => c == 'speak').length, 1);
        // A follow-up reply for this chat arrives while the first is still
        // playing (e.g. the gateway ran a steer as a follow-up turn).
        h.gatewayEvent('message.start');
        h.gatewayEvent('message.complete', {'text': 'Answer two.'});
        await tester.pump();
        await tester.pump();
        expect(
          h.device.calls.where((c) => c == 'speak').length,
          1,
          reason: 'the second reply waits; the first is not cut off',
        );
        expect(h.device.spoken, 'Answer one.');
        expect(
          h.starts(),
          1,
          reason: 'the microphone stays closed while the queue is not empty',
        );
        // The first reply ends on its own; the queued second one starts.
        h.device.playbackDelay!.complete();
        h.device.playbackDelay = Completer<void>();
        await tester.pump();
        await tester.pump();
        expect(h.device.spoken, 'Answer two.');
        expect(h.device.calls.where((c) => c == 'speak').length, 2);
        expect(
          h.starts(),
          1,
          reason: 'still queued work: the microphone has not reopened yet',
        );
        h.device.playbackDelay!.complete();
        h.device.playbackDelay = null;
        await h.settle(tester);
        // Both replies played in full, in arrival order, and neither was cut
        // off. The second reply is unsolicited (the conversation's own
        // awaiting-reply flag was already consumed by the first); per
        // t_0179b15f that no longer ends the loop, so the mic reopens once
        // both have been spoken - exercised directly by the dedicated
        // unsolicited-reply tests below.
        expect(h.device.spoken, 'Answer two.');
        await tester.tap(find.text('Cancel recording'));
        await h.settle(tester);
      },
    );
  });
}
