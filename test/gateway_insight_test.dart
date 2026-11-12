import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_insight.dart';

void main() {
  group('GatewayReasoningUpdate', () {
    for (final entry in <String, String>{
      'reasoning.delta': 'Check the ',
      'reasoning.available': 'Verified the complete gateway contract.',
    }.entries) {
      test('retains exact ${entry.key} payload', () {
        final value = GatewayReasoningUpdate.fromGatewayEvent(entry.key, {
          'text': entry.value,
          'verbose': true,
        });
        expect(value!.text, entry.value);
      });
    }
    for (final entry in <String, (String, String)>{
      'unrelated': ('thinking.delta', 'not reasoning'),
      'empty': ('reasoning.delta', ''),
      'NUL-only': ('reasoning.delta', '\u0000'),
    }.entries) {
      test('ignores ${entry.key} reasoning event', () {
        expect(
          GatewayReasoningUpdate.fromGatewayEvent(entry.value.$1, {
            'text': entry.value.$2,
          }),
          isNull,
        );
      });
    }
  });

  group('GatewayNotice', () {
    test('parses background completion', () {
      final notice = GatewayNotice.fromGatewayEvent('background.complete', {
        'task_id': 'bg-7',
        'text': 'Indexed the selected files.',
      })!;
      expect(notice.kind, GatewayNoticeKind.background);
      expect(notice.taskId, 'bg-7');
      expect(notice.text, 'Indexed the selected files.');
    });
    test('parses review summary', () {
      final notice = GatewayNotice.fromGatewayEvent('review.summary', {
        'text': 'Two changes require review.',
      })!;
      expect(notice.kind, GatewayNoticeKind.review);
      expect(notice.text, 'Two changes require review.');
    });
  });

  group('Gateway Desktop activity events', () {
    test('agent timing uses stock snapshot start and completion duration', () {
      final started = GatewaySubagentActivity.fromSnapshot({
        'subagent_id': 'timed',
        'goal': 'Inspect transport',
        'status': 'running',
        'started_at': 1000.25,
      })!;
      final complete = GatewaySubagentActivity.fromGatewayEvent(
        'subagent.complete',
        {
          'subagent_id': 'timed',
          'status': 'completed',
          'duration_seconds': 2.75,
        },
      )!;
      final finalState = started.merge(complete);
      expect(finalState.startedAt, 1000.25);
      expect(finalState.durationSeconds, 2.75);
      expect(finalState.merge(started).isTerminal, isTrue);
      expect(finalState.merge(started).durationSeconds, 2.75);
    });
    for (final entry in <String, Object>{
      'negative': -1,
      'NaN': double.nan,
      'infinity': double.infinity,
      'text': '3',
    }.entries) {
      test('ignores ${entry.key} completion duration', () {
        expect(
          GatewaySubagentActivity.fromGatewayEvent('subagent.complete', {
            'subagent_id': 'invalid',
            'duration_seconds': entry.value,
          })!.durationSeconds,
          isNull,
        );
      });
      test('ignores ${entry.key} snapshot start', () {
        expect(
          GatewaySubagentActivity.fromSnapshot({
            'subagent_id': 'invalid',
            'started_at': entry.value,
          })!.startedAt,
          isNull,
        );
      });
    }
    test('merges subagent progress into its stable activity', () {
      final started =
          GatewaySubagentActivity.fromGatewayEvent('subagent.start', {
            'subagent_id': 'child-1',
            'goal': 'Inspect Android transport',
            'task_index': 1,
            'task_count': 2,
          })!;
      final completed =
          GatewaySubagentActivity.fromGatewayEvent('subagent.complete', {
            'subagent_id': 'child-1',
            'goal': 'Inspect Android transport',
            'summary': 'Transport inspected.',
          })!;

      final merged = started.merge(completed);
      expect(merged.id, 'child-1');
      expect(merged.isTerminal, isTrue);
      expect(merged.detail, 'Transport inspected.');
      expect(merged.taskIndex, 1);
    });
  });
}
