import 'dart:convert';
import 'dart:io';

import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/transcript_position.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/transcript_presentation.dart';
import 'package:wing/core/models/transcript_reader.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/services/chat_runtime.dart' as execution;

class _Reading implements TranscriptReader {
  @override
  Iterable<PositionedHermesQuestion> get requestActivities => const [];
  @override
  List<Map<String, dynamic>> messages = [];
  @override
  String? historySessionId;
  @override
  int? nextHistoryOffset;
  @override
  bool historyLoading = true;
  @override
  bool historyAvailable = false;
  @override
  bool historyPaging = false;
  @override
  String? historyError;
  @override
  bool historyUnavailable = false;
  @override
  TranscriptPosition readingPosition = const TranscriptPosition();
  @override
  String streaming = '';
  @override
  Object messagePresentationId(Map<String, dynamic> row) => row['id']!;
  @override
  void recordReading(TranscriptBookmark? resume, {int? readThrough}) =>
      readingPosition = TranscriptPosition(
        resume: resume,
        readThrough: readThrough,
      );

  TranscriptPresentation capture() => TranscriptPresentation.capture(
    identity: 'conversation',
    reader: this,
    timeline: TranscriptTimeline.project(
      messages,
      presentationId: messagePresentationId,
    ),
    needsInput: false,
    turnAdmissionBlocked: false,
  );
}

void main() {
  final reasoningFixture =
      jsonDecode(
            File(
              'test/fixtures/stock_reasoning_history.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final sample in reasoningFixture['cases'] as List) {
    final fields = Map<String, dynamic>.from(sample['row'] as Map);
    final expected = sample['expected'] as String;
    test('stock reasoning authority: ${sample['name']}', () {
      final row = <String, dynamic>{
        'id': 1,
        'role': 'assistant',
        'content': '',
        ...fields,
      };
      final original = jsonEncode(row);
      final timeline = TranscriptTimeline.project([
        row,
      ], presentationId: (row) => row['id']!);
      final entry = timeline.entries.single;
      expect(entry.reasoning, expected);
      expect(entry.hasReasoning, expected.trim().isNotEmpty);
      expect(timeline.sections.isEmpty, expected.trim().isEmpty);
      expect(jsonEncode(row), original);
    });

    test(
      'stock reasoning receipt shares display authority: ${sample['name']}',
      () {
        final runtime = execution.ChatRuntime(runtimeId: 'authority');
        runtime.beginTurn(submitting: false);
        if (expected.isNotEmpty) {
          runtime.observeReasoning('reasoning.delta', {'text': expected});
        }
        runtime.observeTool('tool.start', {
          'tool_id': 'owned',
          'name': 'read_file',
        });
        final row = <String, dynamic>{
          'id': 1,
          'role': 'assistant',
          'content': '',
          ...fields,
          'tool_calls': [
            {'id': 'owned'},
          ],
        };
        ChatTranscriptProjection project(Map<String, dynamic> saved) =>
            ChatTranscriptProjection(
              savedRows: [saved],
              streamingMessage: null,
              runtime: runtime.observation,
              presentationId: (row) => row['id']!,
              liveAnswering: true,
            );
        final matched = project(row);
        expect(matched.timeline.sections, isEmpty);
        expect(
          matched.activity.whereType<ChatReasoningEntry>().map(
            (entry) => entry.text,
          ),
          expected.isEmpty ? isEmpty : [expected],
        );
        // Identical visible text cannot identify a receipt from another call.
        final unrelated = {
          ...row,
          'tool_calls': [
            {'id': 'another-call'},
          ],
        };
        expect(project(unrelated).rows.single, same(unrelated));
      },
    );
  }

  test(
    'display authority is invariant under every raw reasoning representation',
    () {
      final rawRepresentations = <Map<String, dynamic>>[
        {'_gateway_reasoning': 'Different local text'},
        {'reasoning': 'Different replay text'},
        {'reasoning_content': 'Different provider text'},
        {
          'reasoning_details': [
            {'type': 'reasoning.text', 'text': 'Different detail'},
          ],
        },
        {
          'codex_reasoning_items': [
            {
              'type': 'reasoning',
              'summary': [
                {'type': 'summary_text', 'text': 'Different summary'},
              ],
            },
          ],
        },
      ];
      for (final display in ['Display text', '', ' \n ', '日本語 🪽']) {
        for (final fields in rawRepresentations) {
          final entry = TranscriptTimeline.project([
            {
              'id': 1,
              'role': 'assistant',
              'content': '',
              ...fields,
              'display_reasoning': display,
            },
          ], presentationId: (row) => row['id']!).entries.single;
          expect(entry.reasoning, display);
          expect(entry.hasReasoning, display.trim().isNotEmpty);
        }
      }
    },
  );

  test(
    'a retained frame cannot observe a later loading or history mutation',
    () {
      final reader = _Reading();
      final opening = reader.capture();
      expect(opening.blocksReading, isTrue);
      reader
        ..messages = [
          {'id': 1, 'role': 'assistant', 'content': 'Saved answer'},
        ]
        ..historySessionId = 'saved'
        ..historyAvailable = true
        ..historyLoading = false;
      final ready = reader.capture();
      expect(opening.isEmpty, isTrue);
      expect(opening.history.available, isFalse);
      expect(opening.segment, isNull);
      expect(opening.blocksReading, isTrue);
      expect(ready.isEmpty, isFalse);
      expect(ready.blocksReading, isFalse);
      reader
        ..historyLoading = true
        ..historyError = 'Refresh failed'
        ..nextHistoryOffset = 20;
      final refresh = reader.capture();
      expect(ready.history.loading, isFalse);
      expect(ready.history.error, isNull);
      expect(ready.history.hasOlder, isFalse);
      expect(refresh.blocksReading, isFalse);
      expect(refresh.history.hasOlder, isTrue);
      expect(refresh.timeline.entries.single.message.text, 'Saved answer');
    },
  );

  test('reading position writes stay with the captured conversation', () {
    final first = _Reading()
      ..recordReading(const TranscriptBookmark(messageId: 80));
    final second = _Reading()
      ..recordReading(const TranscriptBookmark(messageId: 20));
    final captured = first.capture();
    captured.recordReading(const TranscriptBookmark(messageId: 120));
    expect(first.readingPosition.resume?.messageId, 120);
    expect(second.readingPosition.resume?.messageId, 20);
    expect(captured.readingPosition.resume?.messageId, 80);
    expect(first.capture().readingPosition.resume?.messageId, 120);
  });
}
