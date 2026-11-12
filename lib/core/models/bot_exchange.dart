import 'tool_payload.dart';
import 'user_message_delivery.dart';

/// A handoff and later immutable observations, joined only by stock identities.
/// Neither a runner exit nor a queue acknowledgment is a delivery receipt.
final class BotExchangeQueue {
  const BotExchangeQueue(this.processId, this.deliveryId);
  final String processId;
  final String? deliveryId;

  static BotExchangeQueue? fromResult(String raw) {
    final value = decodeToolPayload(raw);
    if (value is! Map || value['status'] != 'queued') return null;
    final id = value['process_id'];
    if (id is! String || id.isEmpty) return null;
    return BotExchangeQueue(
      id,
      value['delivery_id'] is String ? value['delivery_id'] as String : null,
    );
  }

  BotExchangeReceipt? receive(ProcessCompletion process, DateTime? timestamp) {
    if (process.id != processId || !process.botDelivery) return null;
    final data = decodeToolPayload(process.output);
    if (data is Map &&
        data['delivery_id'] != null &&
        data['delivery_id'] != deliveryId) {
      return null;
    }
    final status = data is Map ? data['status'] : null;
    final pending = status == 'queued' || status == 'claimed';
    final unknown =
        status == 'ambiguous' ||
        process.exitCode == null ||
        (data is Map &&
            status != null &&
            !const {
              'settled',
              'failed',
              'cancelled',
              'queued',
              'claimed',
            }.contains(status));
    final error = data is Map ? data['error'] : null;
    final failed =
        !unknown &&
        !pending &&
        (process.exitCode != 0 ||
            error != null ||
            status == 'failed' ||
            status == 'cancelled');
    final label = pending
        ? 'Exchange pending'
        : unknown
        ? 'Exchange outcome unknown'
        : failed
        ? 'Exchange failed'
        : 'Exchange complete';
    final String text;
    if (data is Map &&
        (status != null || data.containsKey('delivery_id') || error != null)) {
      text = [
        if (data['reply'] is String) data['reply'] as String,
        if (error is String) error,
        if (data['detail'] is String) data['detail'] as String,
      ].where((s) => s.trim().isNotEmpty).join('\n\n');
    } else {
      // The relay runner supplies a producer heading, rather than authored
      // answer text. Keep its exact evidence in Raw and copy only the reply.
      text = process.command.contains('bot_mode_dm.py --wait-reply ')
          ? process.output.replaceFirst(
              RegExp(r'^Reply from [^\r\n]+:\r?\n'),
              '',
            )
          : process.output;
    }
    return BotExchangeReceipt(
      label: label,
      text: text.trim().isNotEmpty
          ? text
          : pending
          ? 'Delivery remains pending. Do not resend.'
          : unknown
          ? 'The delivery outcome is unknown. Do not resend.'
          : failed
          ? 'The delivery process failed.'
          : 'The exchange completed without a reply.',
      timestamp: timestamp,
      raw: process.raw,
      failed: failed,
      uncertain: pending || unknown,
    );
  }
}

final class BotExchangeReceipt {
  const BotExchangeReceipt({
    required this.label,
    required this.text,
    required this.timestamp,
    required this.raw,
    required this.failed,
    required this.uncertain,
  });
  final String label, text, raw;
  final DateTime? timestamp;
  final bool failed, uncertain;
}
