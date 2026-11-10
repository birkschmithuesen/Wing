import 'answer_versions.dart';
import 'user_message_delivery.dart';

/// Hermes Desktop's display kinds describe timeline events, not human prompts.
/// Keep this projection separate from the stored history and its row IDs.
String? transcriptNoticeKind(Map<String, dynamic> message) {
  final kind = message['display_kind'];
  return kind is String && _noticeKinds.contains(kind)
      ? kind
      : transcriptUserDelivery(message)?.kind;
}

UserMessageDelivery? transcriptUserDelivery(Map<String, dynamic> message) =>
    answerMessageDisplayRole(message) == 'user' &&
        !_noticeKinds.contains(message['display_kind'])
    ? userMessageDelivery(answerMessageDisplayText(message))
    : null;

const _noticeKinds = {
  'async_delegation_complete',
  'process_complete',
  'model_switch',
  'auto_continue',
  'personality_switch',
};

String? transcriptNoticeText(Map<String, dynamic> message) {
  switch (transcriptNoticeKind(message)) {
    case 'model_switch':
      return 'Model changed';
    case 'auto_continue':
      return 'Resumed interrupted turn';
    case 'personality_switch':
      return 'Personality changed';
    case 'async_delegation_complete':
      final metadata = answerMessageDisplayMetadata(message);
      final display = metadata['display_text'];
      if (display is String && display.trim().isNotEmpty) return display.trim();
      final count = metadata['task_count'];
      return count is num &&
              count.isFinite &&
              count > 0 &&
              count == count.round()
          ? '${count.toInt()} background agent${count == 1 ? '' : 's'} finished'
          : 'Background agent work finished';
    case 'process_complete':
      final process = processCompletionDelivery(answerMessageText(message));
      if (process?.botDelivery == true) return process!.headline;
      final display = answerMessageDisplayMetadata(message)['display_text'];
      return display is String && display.trim().isNotEmpty
          ? display.trim()
          : 'Background process finished';
    default:
      return transcriptUserDelivery(message)?.headline;
  }
}

/// Desktop exposes result bodies on demand, never the model-facing preamble,
/// task goals, or full-transcript footer. Malformed envelopes fail closed.
String? transcriptNoticeResult(Map<String, dynamic> message) {
  final delivery = transcriptUserDelivery(message);
  if (delivery != null) return delivery.detail.isEmpty ? null : delivery.detail;
  if (transcriptNoticeKind(message) == 'process_complete') {
    final result = processCompletionDelivery(
      answerMessageText(message),
    )?.detail;
    return result == null || result.isEmpty ? null : result;
  }
  if (transcriptNoticeKind(message) != 'async_delegation_complete') return null;
  final raw = answerMessageText(message);
  final text =
      (raw.isNotEmpty
              ? raw
              : answerMessageText({
                  'content': message['display_content'] ?? message['text'],
                }))
          .trimLeft();
  var bodies = [text];
  if (text.startsWith('[ASYNC DELEGATION')) {
    if (text.startsWith('[ASYNC DELEGATION BATCH COMPLETE')) {
      bodies = text.split(_taskBoundary).skip(1).toList();
    } else {
      final result = _resultBoundary.firstMatch(text);
      bodies = result == null ? [] : [text.substring(result.end)];
    }
  }
  final result = bodies
      .map((body) {
        final output = body.startsWith('Cron job ')
            ? _jobOutputBoundary.firstMatch(body)
            : null;
        return (output == null ? body : body.substring(output.end))
            .replaceFirst(_transcriptFooter, '')
            .trim();
      })
      .where((body) => body.isNotEmpty)
      .join('\n\n');
  return result.isEmpty ? null : result;
}

final _taskBoundary = RegExp(
  r'^--- [✓✗⚠] TASK \d+/\d+(?:: [\s\S]*?)? {2}\(status=[^\n]*\) ---\r?\n',
  multiLine: true,
);
final _resultBoundary = RegExp(
  r'^--- (?:RESULT|ERROR) ---\r?\n',
  multiLine: true,
);
final _jobOutputBoundary = RegExp(r'^--- JOB OUTPUT ---\r?\n', multiLine: true);
final _transcriptFooter = RegExp(
  r'\r?\nFull live transcript \(complete tool/assistant trace\): [^\n]*\n*$',
);
