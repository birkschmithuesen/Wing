import 'package:wing/core/models/transcript_message.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/theme/wing_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/widgets/profile_message.dart';

const wrappedSteer =
    '[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]\nKeep searching\n[/OUT-OF-BAND USER MESSAGE]';

void main() {
  test('typed steering retains authored marker-shaped content from REST and WS', () {
    for (final text in [
      '[System: please explain this marker]',
      '[Your active task list was preserved across context compression]\n- [ ] Explain this list',
      '[STILL IN PROGRESS — this is the active request, restated after the compaction boundary because it was not finished yet. Continue it; do not start over.]\nExplain this instruction',
    ]) {
      for (final payload in [
        {'text': text},
        {
          'content':
              '[OUT-OF-BAND USER MESSAGE]\n$text\n[/OUT-OF-BAND USER MESSAGE]',
          'display_content': text,
        },
      ]) {
        final row = {
          'id': 7,
          'role': 'user',
          'display_kind': 'steer',
          ...payload,
        };
        expect(isHiddenAnswerMessage(row), isFalse);
        final display = TranscriptMessage.fromRow(row);
        expect(display.kind, TranscriptMessageKind.dialogue);
        expect(display.text, text);
        expect(display.copyText, text);
        expect(display.id, 7);
        expect(row, {
          'id': 7,
          'role': 'user',
          'display_kind': 'steer',
          ...payload,
        });
      }
    }
  });

  test('only typed steering extracts a complete producer envelope', () {
    expect(
      steeringMessageText({
        'role': 'user',
        'content': wrappedSteer,
        'display_kind': 'steer',
      }),
      'Keep searching',
    );
    expect(
      steeringMessageText({
        'role': 'user',
        'content': 'Please explain:\n$wrappedSteer',
      }),
      isNull,
    );
    expect(
      steeringMessageText({
        'role': 'user',
        'content': '[OUT-OF-BAND USER MESSAGE]\nunfinished',
      }),
      isNull,
    );
    expect(
      steeringMessageText({'role': 'assistant', 'content': wrappedSteer}),
      isNull,
    );
    expect(
      answerMessageDisplayText({'role': 'assistant', 'content': wrappedSteer}),
      wrappedSteer,
    );
    expect(
      answerMessageText({'role': 'user', 'content': wrappedSteer}),
      wrappedSteer,
    );
    expect(
      answerMessageDisplayText({
        'role': 'user',
        'content': wrappedSteer,
        'display_kind': 'steer',
      }),
      'Keep searching',
    );
    final untyped = {'role': 'user', 'content': wrappedSteer};
    expect(steeringMessageText(untyped), isNull);
    expect(answerMessageDisplayText(untyped), wrappedSteer);
    expect(
      TranscriptMessage.fromRow(untyped).kind,
      TranscriptMessageKind.dialogue,
    );
    expect(
      steeringMessageText({
        ...untyped,
        'display_kind': 'steer',
        'display_content': 'Server-selected text',
      }),
      'Server-selected text',
    );
  });

  test(
    'typed clean steering and Desktop system notes share their display text',
    () {
      expect(
        steeringMessageText({
          'role': 'user',
          'content': 'Keep searching',
          'display_kind': 'steer',
        }),
        'Keep searching',
      );
      expect(
        steeringMessageText({
          'role': 'system',
          'content': 'steer:Keep searching',
        }),
        'Keep searching',
      );
      expect(
        steeringMessageText({
          'role': 'user',
          'content': 'steer:Keep searching',
        }),
        isNull,
      );
    },
  );
  testWidgets(
    'accepted unsaved steering renders a compact note without the delivery wrapper',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileMessage(
              message: TranscriptMessage.fromRow({
                'role': 'user',
                'content': wrappedSteer,
                'display_kind': 'steer',
              }),
            ),
          ),
        ),
      );
      expect(find.text('steered'), findsOneWidget);
      expect(find.text('Keep searching'), findsOneWidget);
      expect(find.textContaining('OUT-OF-BAND'), findsNothing);
      expect(find.byIcon(WingIcons.steer), findsOneWidget);
      expect(find.byTooltip('Copy message'), findsNothing);
    },
  );

  test('only a durable user row promotes steering to dialogue', () {
    for (final identity in <Map<String, dynamic>>[
      {},
      {'id': 'local-steer'},
      {'timestamp': 1793495836.9},
      {'id': 7},
      {'row_id': 7},
    ]) {
      final row = {
        'role': 'user',
        'content': wrappedSteer,
        'display_kind': 'steer',
        ...identity,
      };
      final saved = identity['id'] == 7 || identity['row_id'] == 7;
      final message = TranscriptMessage.fromRow(row);
      expect(
        message.kind,
        saved ? TranscriptMessageKind.dialogue : TranscriptMessageKind.steering,
      );
      expect(message.text, 'Keep searching');
      expect(message.copyText, saved ? 'Keep searching' : '');
      expect(row['content'], wrappedSteer);
      expect(row['display_kind'], 'steer');
    }
    expect(
      TranscriptMessage.fromRow({
        'id': 7,
        'role': 'system',
        'content': 'steer:Keep searching',
      }).kind,
      TranscriptMessageKind.steering,
    );
  });
}
