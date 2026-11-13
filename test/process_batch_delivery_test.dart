import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/models/transcript_notice.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/models/reading_snapshot_message.dart';

import 'support/process_batch_fixture.dart';

void main() {
  test(
    'typed batch title uses metadata and its complete results survive restore',
    () {
      final source = {
        'id': 10,
        'role': 'user',
        'content': processBatchEnvelope,
        'display_kind': 'process_complete',
        'display_metadata': {'display_text': 'Producer-owned batch outcome'},
      };
      for (final row in [
        source,
        projectReadingSnapshotMessage(captureReadingSnapshotMessage(source)),
      ]) {
        final display = TranscriptMessage.fromRow(row);
        expect(display.kind, TranscriptMessageKind.notice);
        expect(display.id, 10);
        expect(display.text, 'Producer-owned batch outcome');
        expect(display.noticeDisclosure, 'Output');
        expect(display.noticeMonospace, isTrue);
        expect(isHumanAnswerPrompt(row), isFalse);
        for (final output in processBatchFixture['outputs'] as List) {
          expect(display.noticeResult, contains(output));
        }
        expect(display.noticeResult, isNot(contains('Treat these results')));
        expect(row['content'], processBatchEnvelope);
      }
    },
  );

  test('producer-generated batch uses Desktop process notice presentation', () {
    final row = {'role': 'user', 'content': processBatchEnvelope};
    expect(transcriptNoticeKind(row), 'process_notification');
    expect(transcriptNoticeText(row), '16 background processes completed');
    expect(isHumanAnswerPrompt(row), isFalse);
    final result = transcriptNoticeResult(row)!;
    for (final output in processBatchFixture['outputs'] as List) {
      expect(result, contains(output));
    }
    expect(result, contains('proc_fixture_16 exited (exit code 1)'));
    expect(result, isNot(contains('[IMPORTANT:')));
    expect(result, isNot(contains('Treat these results')));
  });

  test('batch parsing depends on the container, not instruction wording', () {
    final headerEnd = processBatchEnvelope.indexOf('\n\n');
    final body = processBatchEnvelope.substring(headerEnd);
    for (final text in [
      '[IMPORTANT: 16 background processes completed.]$body',
      '[IMPORTANT: 16 background processes completed. Different future guidance.]$body',
      processBatchEnvelope.replaceAll('\n', '\r\n'),
    ]) {
      for (final fields in <Map<String, dynamic>>[
        {'content': text},
        {'text': text},
        {'content': 'wire text', 'display_content': text},
        {
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      ]) {
        final row = {'role': 'user', ...fields};
        expect(transcriptNoticeText(row), '16 background processes completed');
        expect(
          transcriptNoticeResult(row),
          contains('Action needed: check failed'),
        );
        expect(transcriptNoticeResult(row), isNot(contains('[IMPORTANT:')));
      }
    }
  });

  test('quoted, partial and count-mismatched batches remain human text', () {
    for (final text in [
      'Explain this:\n$processBatchEnvelope',
      '```\n$processBatchEnvelope\n```',
      processBatchEnvelope.substring(0, processBatchEnvelope.length - 1),
      processBatchEnvelope.substring(0, processBatchEnvelope.indexOf('\n\n')),
      processBatchEnvelope.replaceFirst('16 background', '17 background'),
      processBatchEnvelope.replaceFirst('16 background', '016 background'),
      processBatchEnvelope.replaceFirst('16 background', '1 background'),
      processBatchEnvelope.replaceFirst(
        '[IMPORTANT: Background process',
        'Ordinary text',
      ),
    ]) {
      final row = {'role': 'user', 'content': text};
      expect(transcriptNoticeKind(row), isNull);
      expect(isHumanAnswerPrompt(row), isTrue);
      expect(answerMessageDisplayText(row), text);
    }
    expect(
      transcriptNoticeKind({
        'role': 'assistant',
        'content': processBatchEnvelope,
      }),
      isNull,
    );
  });
}
