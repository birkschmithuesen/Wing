import 'dart:convert';
import 'package:wing/core/models/app_preferences.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/live_voice_session.dart';
import 'package:wing/core/models/transcript_timeline.dart';

import 'support/live_voice_fixture.dart';

void main() {
  late VoiceChatFixture chat;
  late VoiceTransportFixture transport;
  late VoiceBackgroundFixture background;
  late LiveVoiceSession voice;
  setUp(() {
    chat = VoiceChatFixture();
    transport = VoiceTransportFixture();
    background = VoiceBackgroundFixture();
    voice = LiveVoiceSession(
      createTransport: () => transport,
      background: background,
    );
  });
  tearDown(() async {
    await voice.end();
    voice.dispose();
    chat.dispose();
  });

  test('speech is retained once, scoped and never submitted as work', () async {
    await voice.start(chat);
    final key = chat.key;
    void speech(String type, String id, String text) => transport.event({
      'type': type,
      'item': {'id': id, 'text': text},
    });
    void done(String id, String role, String text) => transport.event({
      'type': 'turn.done',
      'turn': {'id': id, 'role': role, 'transcript': text},
    });
    speech('input_transcript.added', 'u1', 'What is my full name?');
    speech('input_transcript.added', 'u1', 'What is my full name?');
    final originalId = voice.transcript(key).single.id;
    done('user1', 'user', 'My name?');
    done('user1', 'user', 'My name?');
    speech('output_transcript.added', 'a1', 'Your name is Robert.');
    done('answer1', 'assistant', 'Robert.');
    done('answer1', 'assistant', 'Robert.');
    done('user2', 'user', 'My name?');
    expect(voice.transcript(key).map((t) => t.text), [
      'What is my full name?',
      'Your name is Robert.',
      'My name?',
    ]);
    expect(voice.transcript(key).first.id, originalId);
    expect(voice.transcript(key).map((t) => t.id).toSet(), hasLength(3));
    expect(chat.calls, isEmpty);
    final oldEvent = transport.event;
    await voice.end();
    oldEvent({
      'type': 'turn.done',
      'turn': {'id': 'late', 'role': 'assistant', 'transcript': 'Late'},
    });
    expect(voice.transcript(key), hasLength(3));
    final other = VoiceChatFixture(profile: 'other');
    await voice.start(other);
    expect(voice.transcript(other.key), isEmpty);
    expect(voice.transcript(key), hasLength(3));
    await voice.end();
    other.dispose();
    final again = VoiceChatFixture();
    await voice.start(again);
    done('user1', 'user', 'Another call');
    expect(voice.transcript(key).map((t) => t.text), [
      'What is my full name?',
      'Your name is Robert.',
      'My name?',
      'Another call',
    ]);
    await voice.end();
    again.dispose();
  });

  test('API speaker boundaries and disconnect retain both sides', () async {
    chat.dispose();
    chat = VoiceChatFixture(mode: LiveVoiceMode.api);
    await voice.start(chat);
    void delta(bool user, String text) => transport.event({
      'type': 'session.${user ? 'input' : 'output'}_transcript.delta',
      'delta': text,
    });
    delta(true, 'Hello');
    delta(true, ' there');
    delta(false, 'Hi');
    delta(true, 'Again');
    expect(voice.transcript(chat.key).map((t) => t.text), [
      'Hello there',
      'Hi',
      'Again',
    ]);
    expect(voice.transcript(chat.key).last.complete, isFalse);
    transport.disconnected();
    await settleVoice();
    expect(voice.transcript(chat.key).every((t) => t.complete), isTrue);
    expect(chat.calls, isEmpty);
  });

  test(
    'local speech projection preserves saved rows and command authority',
    () async {
      await voice.start(chat);
      transport.event({
        'type': 'turn.done',
        'turn': {'id': 'u', 'role': 'user', 'transcript': 'Read this'},
      });
      final before = DateTime.now().subtract(const Duration(days: 1));
      final after = DateTime.now().add(const Duration(days: 1));
      final rows = [
        {
          'id': 1,
          'role': 'user',
          'content': 'Earlier',
          'timestamp': before.millisecondsSinceEpoch / 1000,
        },
        {
          'id': 2,
          'role': 'assistant',
          'content': 'Hermes result',
          'timestamp': after.millisecondsSinceEpoch / 1000,
        },
      ];
      final native = TranscriptTimeline.project(
        rows,
        presentationId: (row) => row['id']!,
      );
      final merged = native.withVoiceTurns(voice.transcript(chat.key));
      expect(merged.entries.map((e) => e.message.text), [
        'Earlier',
        'Read this',
        'Hermes result',
      ]);
      expect(rows, hasLength(2));
      expect(merged.entries.first, same(native.entries.first));
      expect(merged.entries.last, same(native.entries.last));
      final speech = merged.entries[1];
      expect(speech.sourceIndex, -1);
      expect(speech.savedMessageId, isNull);
      expect(speech.editablePrompt, isFalse);
      expect(speech.branchAnswer, isFalse);
      expect(speech.message.copyText, 'Read this');
    },
  );

  test('startup context cannot delegate work before new user speech', () async {
    await voice.start(chat);
    transport.event({
      'type': 'delegation.created',
      'item': {
        'id': 'historical-work',
        'type': 'delegation',
        'target': 'client',
        'content': [
          {'type': 'input_text', 'text': 'Repeat the old tool call'},
        ],
      },
    });
    await settleVoice();
    expect(chat.calls, isEmpty);
    expect(jsonEncode(transport.sent), contains('Wait for the user to speak'));
    transport.delegate('new-request', 'Now calculate it');
    await settleVoice();
    expect(chat.calls, ['request:Now calculate it']);
  });

  test(
    'failed result delivery is visible and leaves Hermes work alone',
    () async {
      await voice.start(chat);
      await settleVoice();
      transport.failSend = true;
      chat.completeReply('new', 'Completed task');
      await settleVoice();
      expect(voice.active, isFalse);
      expect(voice.error, contains('could not send'));
      expect(chat.calls, isEmpty);
    },
  );

  test('ordinary provider closure does not claim an account limit', () async {
    await voice.start(chat);
    transport.event({'type': 'session.closed', 'reason': 'connection_lost'});
    await settleVoice();
    expect(voice.active, isFalse);
    expect(voice.error, contains('connection'));
    expect(voice.error, isNot(contains('limits')));
  });

  test('rejected provider command does not terminate a healthy call', () async {
    await voice.start(chat);
    transport.event({
      'type': 'error',
      'error': {
        'type': 'invalid_request_error',
        'code': 'invalid_value',
        'message': 'private provider content',
      },
    });
    await settleVoice();
    expect(voice.phase, LiveVoicePhase.listening);
    expect(voice.active, isTrue);
    expect(transport.closed, isFalse);
    expect(voice.error, isNot(contains('private')));
    expect(voice.error, contains('rejected'));
  });

  test(
    'API session uses API events without subscription event fallback',
    () async {
      chat.dispose();
      chat = VoiceChatFixture(mode: LiveVoiceMode.api);
      await voice.start(chat);
      expect(voice.phase, LiveVoicePhase.listening);
      transport.event({
        'type': 'session.input_transcript.delta',
        'delta': 'Do the task',
      });
      transport.event({
        'type': 'session.delegation.created',
        'delegation': {'id': 'api1', 'type': 'delegation', 'target': 'client'},
      });
      await settleVoice();
      expect(chat.calls, ['request:Do the task']);
      expect(
        transport.sent.any((e) => e['type'] == 'session.commentary.append'),
        isTrue,
      );
      expect(
        transport.sent.any((e) => e['type'] == 'delegation.context.append'),
        isFalse,
      );
      await voice.toggleMute();
      expect(transport.sent.last['type'], 'session.input_audio.mute');
    },
  );

  test(
    'connecting is visible before audio preparation and End fences it',
    () async {
      final preparation = Completer<void>();
      final start = voice.start(chat, prepare: () => preparation.future);
      expect(voice.phase, LiveVoicePhase.connecting);
      final end = voice.end();
      preparation.complete();
      await Future.wait([start, end]);
      expect(voice.active, isFalse);
      expect(transport.answers, 0);
      expect(background.running, isFalse);
    },
  );

  test(
    'End releases audio and revokes chat before delayed negotiation returns',
    () async {
      chat.negotiation = Completer();
      final start = voice.start(chat);
      await settleVoice();
      final end = voice.end();
      await settleVoice();
      expect(transport.closed, isTrue);
      expect(chat.released, isTrue);
      expect(voice.phase, LiveVoicePhase.ending);
      chat.negotiation!.complete({
        'mode': 'subscription',
        'protocol': 'codex-live-v3',
        'contractVersion': 2,
        'handoff': 'client',
        'answer': 'late',
      });
      await Future.wait([start, end]);
      expect(transport.answers, 0);
      expect(background.running, isFalse);
      expect(voice.active, isFalse);
      expect(chat.calls, isEmpty);
    },
  );
  test(
    'late microphone acquisition cannot start background or negotiate',
    () async {
      transport.opening = Completer();
      final start = voice.start(chat);
      await settleVoice();
      final end = voice.end();
      transport.opening!.complete('late offer');
      await Future.wait([start, end]);
      expect(transport.closed, isTrue);
      expect(background.running, isFalse);
      expect(transport.answers, 0);
    },
  );
  test(
    'delegates native text once, rejects empty requests, and ignores stale events',
    () async {
      await voice.start(chat);
      transport.delegate('one', 'Build it');
      transport.delegate('one', 'Build it');
      transport.delegate('bad', '');
      await settleVoice();
      expect(chat.calls, ['request:Build it']);
      await voice.end();
      transport.delegate('late', 'Stop');
      await settleVoice();
      expect(chat.calls, ['request:Build it']);
    },
  );
  test(
    'barge-in and End leave accepted work alive; explicit stop is separate',
    () async {
      await voice.start(chat);
      transport.delegate('one', 'Long task');
      transport.event({
        'type': 'input_transcript.added',
        'item': {'text': 'How is it going?'},
      });
      await settleVoice();
      expect(chat.calls, ['request:Long task']);
      transport.delegate('two', 'Stop the task');
      await settleVoice();
      expect(chat.calls, ['request:Long task', 'stop:Stop the task']);
      await voice.end();
      expect(chat.calls.length, 2);
    },
  );
  test(
    'late task result after End cannot speak into a subsequent call',
    () async {
      chat.delegation = Completer();
      await voice.start(chat);
      transport.delegate('one', 'Work');
      await settleVoice();
      await voice.end();
      final second = VoiceChatFixture();
      await voice.start(second);
      chat.delegation!.complete('Old result');
      await settleVoice();
      expect(
        transport.sent.where((e) => e['type'] == 'delegation.context.append'),
        isEmpty,
      );
      await voice.end();
      second.dispose();
    },
  );
  test(
    'initial history is context; new completed reply is delivered once',
    () async {
      chat.replies['old'] = 'Past result';
      await voice.start(chat);
      chat.completeReply('new', 'Task finished');
      chat.completeReply('new', 'Task finished');
      await settleVoice();
      final spoken = transport.sent
          .where((e) => e['channel'] == 'speakable')
          .toList();
      expect(spoken.length, 1);
      expect(jsonEncode(spoken.single), contains('Task finished'));
      expect(jsonEncode(spoken.single), isNot(contains('Past result')));
    },
  );
  test(
    'short final transcript does not truncate speech and notification can mute/end',
    () async {
      await voice.start(chat);
      transport.event({
        'type': 'output_transcript.added',
        'item': {'text': 'The complete spoken result'},
      });
      transport.event({
        'type': 'turn.done',
        'turn': {'role': 'assistant', 'transcript': 'result'},
      });
      expect(
        voice.transcript(chat.key).single.text,
        'The complete spoken result',
      );
      expect(voice.caption, 'The complete spoken result');
      expect(voice.connectedAt, isNotNull);
      background.action('mute');
      await settleVoice();
      expect(transport.isMuted, isTrue);
      background.action('end');
      await settleVoice();
      expect(voice.active, isFalse);
    },
  );
  test(
    'failed negotiation settles as visible failure with resources released',
    () async {
      chat.negotiation = Completer();
      final start = voice.start(chat);
      await settleVoice();
      chat.negotiation!.completeError(StateError('private token detail'));
      await start;
      await settleVoice();
      expect(voice.phase, LiveVoicePhase.failed);
      expect(voice.error, isNot(contains('private token')));
      expect(transport.closed, isTrue);
      expect(background.running, isFalse);
      expect(chat.released, isTrue);
    },
  );
}
