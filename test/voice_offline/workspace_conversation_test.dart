import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/chat_voice_view.dart';
import '../support/voice_workspace_fixture.dart';

void main() {
  late VoiceWorkspaceHarness h;
  setUp(() async {
    h = VoiceWorkspaceHarness();
    await h.setUp();
  });
  tearDown(() => h.tearDown());

  testWidgets('conversation mode sends a dictation that ended on its own', (
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

  testWidgets(
    'a second dictation while the first turn still runs becomes a steering message',
    (tester) async {
      await h.conversationMode(true);
      await h.show(tester);
      final chat = h.controller.current!.chat!;
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await h.sayFinal(tester, 'How is the weather');
      expect(h.prompts(), 1);
      expect(chat.voiceBusy, isTrue);
      // The reply has not arrived yet; the mic can be tapped again.
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await h.sayFinal(tester, 'Actually, for tomorrow');
      expect(h.prompts(), 1, reason: 'no second turn was started');
      expect(h.fixture.calls.where((c) => c.$2 == 'session.steer').length, 1);
      expect(
        h.fixture.calls.lastWhere((c) => c.$2 == 'session.steer').$3['text'],
        'Actually, for tomorrow',
      );
      expect(chat.composer.observation.text, isEmpty);
      // The conversation stayed alive: the turn's eventual reply still
      // continues the hands-free loop.
      await h.completeReply(tester, 'Tomorrow looks sunny.');
      expect(h.device.spoken, 'Tomorrow looks sunny.');
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets(
    'a dictation while reconnecting is queued and sent once reconnected',
    (tester) async {
      await h.conversationMode(true);
      await h.show(tester);
      final chat = h.controller.current!.chat!;
      h.controller.networkUnavailable();
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await h.sayFinal(tester, 'Queue me please');
      expect(h.prompts(), 0);
      expect(chat.composer.observation.queue.map((p) => p.text), ['Queue me please']);
      expect(chat.composer.observation.text, isEmpty);
      h.controller.networkRestored();
      await tester.runAsync(() => h.controller.reconnect(chat.key.workspace));
      await h.settle(tester);
      expect(h.prompts(), 1);
      expect(chat.composer.observation.queue, isEmpty);
      await h.completeReply(tester, 'Queued answer.');
      expect(h.device.spoken, 'Queued answer.');
      expect(h.starts(), 2, reason: 'the mic reopened after the queued reply');
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets(
    'a flaky send right after reconnect does not end the conversation; the mic reopens once it drains',
    (tester) async {
      await h.conversationMode(true);
      await h.show(tester);
      final chat = h.controller.current!.chat!;
      h.controller.networkUnavailable();
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await h.sayFinal(tester, 'Queue me please');
      expect(h.prompts(), 0);
      expect(chat.composer.observation.queue.map((p) => p.text), ['Queue me please']);
      h.controller.networkRestored();
      // Card t_8c76c35a observation 2026-10-19: the connection is still
      // flaky right after reconnect; the first drain attempt hits that.
      h.fixture.promptSubmitFailures = 1;
      await tester.runAsync(() => h.controller.reconnect(chat.key.workspace));
      await h.settle(tester);
      // The flaky send leaves an uncertain ack, same as the non-conversation
      // case: it pauses rather than guessing. Crucially chat.status stays
      // "reconnecting", not "failed" - the conversation keeps running.
      expect(chat.composer.observation.paused, isTrue);
      expect(chat.composer.observation.queue, isNotEmpty);
      expect(h.prompts(), 1);
      // Old (buggy) behavior: nothing short of a manual resume (not
      // available in conversation mode) ever drains this again, and the
      // conversation already ended when chat.status flipped to failed.
      await tester.runAsync(() => h.controller.reconnect(chat.key.workspace));
      await h.settle(tester);
      expect(chat.composer.observation.queue, isEmpty);
      expect(h.prompts(), 2);
      await h.completeReply(tester, 'Queued answer.');
      expect(
        h.device.spoken,
        'Queued answer.',
        reason:
            'exec=${chat.runtime.execution} err=${chat.runtime.error} blocks=${chat.runtime.blocksTurnAdmission} queue=${chat.composer.observation.queue.length} starts=${h.starts()} prompts=${h.prompts()} calls=${h.fixture.calls.map((c) => c.$2).toList()}',
      );
      expect(h.starts(), 2, reason: 'the mic reopened after the queued reply');
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets('without conversation mode a final dictation is never sent', (
    tester,
  ) async {
    await h.conversationMode(false);
    await h.show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await h.sayFinal(tester, 'Just a draft');
    expect(h.controller.current!.chat!.composer.observation.text, 'Just a draft');
    expect(h.prompts(), 0);
  });

  testWidgets('conversation mode never sends after the user pressed Stop', (
    tester,
  ) async {
    await h.conversationMode(true);
    await h.show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    final id = h.device.recording;
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pump();
    h.device.stream.add({'id': id, 'text': 'Stopped words', 'final': true});
    await h.settle(tester);
    expect(h.controller.current!.chat!.composer.observation.text, 'Stopped words');
    expect(h.prompts(), 0);
  });

  testWidgets('conversation reopens the microphone after the reply was spoken', (
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

  testWidgets(
    'a reply that arrives while one plays queues instead of cutting it off',
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
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets(
    'tapping the microphone while a reply plays clears the queued one',
    (tester) async {
      await h.conversationMode(true);
      h.device.playbackDelay = Completer<void>();
      await h.show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await h.sayFinal(tester, 'Question one');
      h.gatewayEvent('message.complete', {'text': 'Answer one.'});
      await tester.pump();
      await tester.pump();
      expect(h.device.spoken, 'Answer one.');
      h.gatewayEvent('message.start');
      h.gatewayEvent('message.complete', {'text': 'Answer two.'});
      await tester.pump();
      await tester.pump();
      expect(
        h.device.calls.where((c) => c == 'speak').length,
        1,
        reason: 'the second reply is still queued',
      );
      // The user taps the microphone while the first reply is still playing.
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      h.device.playbackDelay!.complete();
      h.device.playbackDelay = null;
      await h.settle(tester);
      // The queued second reply must never speak: the tap cleared it.
      expect(h.device.calls.where((c) => c == 'speak').length, 1);
      expect(h.device.spoken, 'Answer one.');
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets(
    'an unsolicited reply while recording queues instead of cutting the '
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
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets(
    'an unsolicited reply while idle is spoken and the loop stays on',
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
      await tester.tap(find.byTooltip('Cancel recording'));
      await h.settle(tester);
    },
  );

  testWidgets('Cancel ends the conversation and the microphone stays closed', (
    tester,
  ) async {
    await h.conversationMode(true);
    await h.show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await h.sayFinal(tester, 'Question');
    await h.completeReply(tester);
    expect(h.starts(), 2);
    await tester.tap(find.byTooltip('Cancel recording'));
    await h.settle(tester);
    // A later reply in this chat must not reopen the microphone.
    h.gatewayEvent('message.start');
    await h.completeReply(tester, 'Late reply.');
    expect(h.starts(), 2);
    expect(h.device.recording, isNull);
  });

  for (final failure in ['error', 'no speech']) {
    testWidgets('$failure ends the conversation and the microphone stays closed', (
      tester,
    ) async {
      await h.conversationMode(true);
      await h.show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await h.sayFinal(tester, 'Question');
      await h.completeReply(tester);
      expect(h.starts(), 2);
      if (failure == 'error') {
        h.device.stream.add({'id': h.device.recording, 'error': 'Recognizer busy'});
        await h.settle(tester);
      } else {
        await h.sayFinal(tester, '   ');
      }
      expect(find.textContaining('Recording ·'), findsNothing);
      expect(h.prompts(), 1);
      h.gatewayEvent('message.start');
      await h.completeReply(tester, 'Late reply.');
      expect(h.starts(), 2);
    });
  }

  testWidgets('backgrounding during the spoken reply ends the conversation', (
    tester,
  ) async {
    await h.conversationMode(true);
    h.device.playbackDelay = Completer<void>();
    await h.show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await h.sayFinal(tester, 'Question');
    h.gatewayEvent('message.complete', {'text': 'Answer.'});
    await tester.pump();
    await tester.pump();
    expect(h.device.calls, contains('speak'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    h.device.playbackDelay!.complete();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await h.settle(tester);
    expect(h.device.calls, contains('stopPlayback'));
    expect(h.starts(), 1);
    expect(find.textContaining('Recording ·'), findsNothing);
  });

  for (final request in ['approval', 'clarify']) {
    testWidgets('a pending $request keeps the microphone closed', (
      tester,
    ) async {
      await h.conversationMode(true);
      await h.show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await h.sayFinal(tester, 'Clean up the disk');
      expect(h.prompts(), 1);
      h.gatewayEvent(
        request,
        request == 'approval'
            ? {'request_id': 'approve-1', 'command': 'rm -rf build'}
            : {
                'request_id': 'ask-1',
                'questions': [
                  {'qid': 'q0', 'question': 'Which disk?'},
                ],
              },
      );
      await tester.pump();
      await h.completeReply(tester, 'Waiting for you.');
      expect(h.device.spoken, 'Waiting for you.');
      expect(h.starts(), 1);
      expect(find.textContaining('Recording ·'), findsNothing);
    });
  }

}
