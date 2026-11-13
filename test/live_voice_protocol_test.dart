import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/live_voice_protocol.dart';

void main() {
  test(
    'subscription retains native transcript IDs and ignores replayed fragments',
    () {
      final protocol = LiveVoiceProtocol(LiveVoiceMode.subscription);
      final delta = {
        'type': 'output_transcript.added',
        'item': {'id': 'fragment', 'text': 'Hello'},
      };
      expect((protocol.accept(delta) as VoiceTranscript).id, 'fragment');
      expect(protocol.accept(delta), isNull);
      final done = {
        'type': 'turn.done',
        'turn': {'id': 'turn', 'role': 'assistant', 'transcript': 'Hello'},
      };
      final transcript = protocol.accept(done) as VoiceTranscript;
      expect(
        (transcript.id, transcript.complete, transcript.text),
        ('turn', true, 'Hello'),
      );
      expect(protocol.accept(done), isNull);
    },
  );

  test('subscription accepts the live provider plain-text delegation', () {
    final protocol = LiveVoiceProtocol(LiveVoiceMode.subscription);
    // Captured from the published plugin's live spoken calculation test.
    final request =
        protocol.accept({
              'type': 'delegation.created',
              'item': {
                'id': 'captured-delegation',
                'type': 'delegation',
                'content': [
                  {
                    'type': 'input_text',
                    'text':
                        'Ask Hermes to use its terminal tool to calculate one hundred and thirty-seven times twenty-nine and read me the result',
                  },
                ],
                'handoff_id': 'handoff_1',
                'target': 'client',
                'user_bidi_turn_id': 'captured-user-turn',
              },
              'offset_ms': 9600,
            })
            as VoiceDelegation;
    expect(request.action, 'request');
    expect(request.text, contains('terminal tool'));
  });
  Map<String, dynamic> apiDelegation(String id) => {
    'type': 'session.delegation.created',
    'delegation': {'id': id, 'type': 'delegation', 'target': 'client'},
  };
  test(
    'API delegation captures input once and duplicate IDs do not consume next request',
    () {
      final protocol = LiveVoiceProtocol(LiveVoiceMode.api);
      protocol.accept({
        'type': 'session.input_transcript.delta',
        'delta': 'Build the app',
      });
      final first = protocol.accept(apiDelegation('1')) as VoiceDelegation;
      expect((first.action, first.text), ('request', 'Build the app'));
      protocol.accept({
        'type': 'session.input_transcript.delta',
        'delta': 'Also run tests',
      });
      expect(protocol.accept(apiDelegation('1')), isNull);
      final second = protocol.accept(apiDelegation('2')) as VoiceDelegation;
      expect(second.text, 'Also run tests');
    },
  );
  test('API work commands use the current spoken turn after conversation', () {
    for (final (speech, action) in [
      ('Stop the task.', 'stop'),
      ('Task status', 'status'),
    ]) {
      final protocol = LiveVoiceProtocol(LiveVoiceMode.api);
      protocol.accept({
        'type': 'session.input_transcript.delta',
        'delta': 'What is my name?',
      });
      protocol.accept({
        'type': 'session.output_transcript.delta',
        'delta': 'Your name is Robert.',
      });
      protocol.accept({
        'type': 'session.input_transcript.delta',
        'delta': speech,
      });
      // A spoken acknowledgement can precede the delegation itself.
      protocol.accept({
        'type': 'session.output_transcript.delta',
        'delta': 'I will ask Hermes.',
      });
      final request =
          protocol.accept(apiDelegation('current')) as VoiceDelegation;
      expect((request.action, request.text), (action, speech));
    }
  });

  test('only a whole explicit cancellation command stops work in API mode', () {
    for (final (text, expected) in [
      ('Stop the task.', 'stop'),
      ('Cancel the task!', 'stop'),
      ('Explain what "stop the task" means', 'request'),
      ('Do not stop working', 'request'),
    ]) {
      final protocol = LiveVoiceProtocol(LiveVoiceMode.api);
      protocol.accept({
        'type': 'session.input_transcript.delta',
        'delta': text,
      });
      expect(
        (protocol.accept(apiDelegation('1')) as VoiceDelegation).action,
        expected,
      );
    }
  });
  test('provider protocols never mix append or mute event families', () {
    final api = LiveVoiceProtocol(LiveVoiceMode.api),
        subscription = LiveVoiceProtocol(LiveVoiceMode.subscription);
    expect(api.result('d', 'Done').single['type'], 'session.commentary.append');
    expect(api.context('Working').single['type'], 'session.thinking.append');
    expect(api.mute(true)?['type'], 'session.input_audio.mute');
    expect(
      subscription.result('d', 'Done').single['type'],
      'delegation.context.append',
    );
    expect(
      subscription.context('Working').single['type'],
      'session.context.append',
    );
    expect(subscription.mute(true), isNull);
    expect(subscription.accept(apiDelegation('d')), isNull);
  });
  test('subscription only treats whole explicit commands as work controls', () {
    for (final (text, action) in [
      ('Stop the task.', 'stop'),
      ('How is the task going?', 'status'),
      ('Explain what "stop the task" means', 'request'),
      ('Do not stop working', 'request'),
      ('{"action":"stop","text":"example"}', 'request'),
      ('', 'invalid'),
      ('x' * 32001, 'invalid'),
    ]) {
      final protocol = LiveVoiceProtocol(LiveVoiceMode.subscription);
      final request =
          protocol.accept({
                'type': 'delegation.created',
                'item': {
                  'id': 'item',
                  'type': 'delegation',
                  'target': 'client',
                  'content': [
                    {'type': 'input_text', 'text': text},
                  ],
                },
              })
              as VoiceDelegation;
      expect(request.action, action);
    }
  });
  test(
    'both modes split every append below 500 tokens without losing text',
    () {
      final text = '語🙂 context with Hermes results. ' * 1000;
      for (final mode in LiveVoiceMode.values) {
        final protocol = LiveVoiceProtocol(mode);
        for (final events in [
          protocol.result('d', text),
          protocol.context(text),
          protocol.begin(text),
        ]) {
          final contents = events
              .map(
                (event) => mode == LiveVoiceMode.api
                    ? event['content'] as String
                    : (event['content'] as List).single['text'] as String,
              )
              .toList();
          for (final content in contents) {
            expect(utf8.encode(content).length, lessThanOrEqualTo(480));
            expect(content, isNot(contains('\uFFFD')));
          }
          // begin(API) supplies only its fixed short instructions.
          if (events.first['type'] != 'session.instructions.append') {
            expect(contents.join(), text);
          }
        }
      }
    },
  );
  test('subscription uses item identity and deduplicates native requests', () {
    final protocol = LiveVoiceProtocol(LiveVoiceMode.subscription);
    final event = {
      'type': 'delegation.created',
      'item': {
        'id': 'item',
        'handoff_id': 'other',
        'type': 'delegation',
        'target': 'client',
        'content': [
          {'type': 'input_text', 'text': 'stop'},
        ],
      },
    };
    final request = protocol.accept(event) as VoiceDelegation;
    expect(request.id, 'item');
    expect(request.action, 'request');
    expect(protocol.accept(event), isNull);
  });
}
