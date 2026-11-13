import 'package:wing/core/models/transcript_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/widgets/profile_message.dart';

const snapshotHeader =
    '[Your active task list was preserved across context compression]';
const snapshot =
    '$snapshotHeader\n'
    '- [>] backup. Quiesce processing, back up production, and rehearse '
    'database migration (in_progress)\n'
    '- [ ] publish. Publish verified commits (pending)';

void main() {
  test('snapshot projection covers history encodings and typed provenance', () {
    for (final fields in <Map<String, dynamic>>[
      {'content': snapshot},
      {'text': snapshot},
      {'content': snapshot.replaceAll('\n', '\r\n')},
      {'content': 'wire payload', 'display_content': snapshot},
      {
        'content': [
          {'type': 'text', 'text': snapshot},
        ],
      },
      {'content': 'future task snapshot', '_todo_snapshot_synthetic': true},
      {'content': 'future task snapshot', 'display_kind': 'hidden'},
      {'content': snapshot.replaceFirst('- [>]', '- [x]')},
      {'content': snapshot.replaceFirst('- [>]', '- [~]')},
      {'content': '$snapshot\n\n[Runtime note: reload pruned skills]'},
    ]) {
      final row = {'role': 'user', ...fields};
      expect(isHiddenAnswerMessage(row), isTrue, reason: '$fields');
      expect(isHumanAnswerPrompt(row), isFalse, reason: '$fields');
      final projected = answerHistoryRows([row]).single;
      expect(isHiddenAnswerMessage(projected), isTrue);
    }
    expect(
      isHiddenAnswerMessage({
        'role': 'user',
        'content': snapshot,
        'display_content': 'Server-projected user text',
      }),
      isFalse,
    );
  });

  testWidgets('compression task snapshot never appears as a human bubble', (
    tester,
  ) async {
    final row = {'id': 3, 'role': 'user', 'content': snapshot};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(message: TranscriptMessage.fromRow(row)),
        ),
      ),
    );
    expect(find.textContaining(snapshotHeader), findsNothing);
    expect(find.byTooltip('Copy message'), findsNothing);
    expect(isHiddenAnswerMessage(row), isTrue);
    expect(isHumanAnswerPrompt(row), isFalse);
    expect(answerMessageText(row), snapshot);
    // View filtering must not alter durable history ordinals used by rewind.
    expect(isAnswerPrompt(row), isTrue);
  });

  test(
    'ordinary lists, quoted reminders and assistant text remain visible',
    () {
      for (final text in [
        '- [ ] publish. Publish verified commits (pending)',
        'Explain this:\n$snapshot',
        '```\n$snapshot\n```',
        '> $snapshot',
        snapshotHeader,
        '$snapshotHeader\nWhat does this mean?',
      ]) {
        final row = {'role': 'user', 'content': text};
        expect(isHiddenAnswerMessage(row), isFalse, reason: text);
        expect(isHumanAnswerPrompt(row), isTrue, reason: text);
        expect(answerMessageDisplayText(row), text);
      }
      expect(
        isHiddenAnswerMessage({'role': 'assistant', 'content': snapshot}),
        isFalse,
      );
    },
  );
}
