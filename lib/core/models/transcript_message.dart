import 'dart:convert';
import 'bot_exchange.dart';
import 'bots.dart';

import 'answer_versions.dart';
import 'gateway_activity.dart';
import 'review_notice.dart';
import 'transcript_notice.dart';
import 'user_message_content.dart';

enum TranscriptMessageKind {
  hidden,
  notice,
  review,
  steering,
  system,
  tool,
  dialogue,
  voice,
  botMessage,
  discussion,
  discussionPass,
}

/// Passive reading facts. This projection cannot hydrate or execute a runtime,
/// acknowledge delivery, or change the authoritative history row.
final class TranscriptMessage {
  TranscriptMessage._({
    required this.kind,
    required this.role,
    required this.id,
    required this.streaming,
    this.text = '',
    this.copyText = '',
    this.noticeResult,
    this.noticeDisclosure = 'View result',
    this.noticePlainText = false,
    this.noticeMonospace = false,
    this.systemMultiline = false,
    this.timestamp,
    this.sender,
    this.senderHandle,
    this.tool,
    Iterable<UserMessageAttachment> attachments = const [],
  }) : attachments = List.unmodifiable([
         for (final attachment in attachments)
           UserMessageAttachment(
             name: attachment.name,
             target: attachment.target,
             isImage: attachment.isImage,
           ),
       ]);

  final TranscriptMessageKind kind;

  /// Presentation role, not authority to replay or modify the saved row.
  final String role;
  final bool streaming;
  final Object? id;
  final String text;
  final String copyText;
  final String? noticeResult;
  final String noticeDisclosure;
  final bool noticePlainText;
  final bool noticeMonospace;
  final bool systemMultiline;
  final DateTime? timestamp;
  final String? sender;
  final String? senderHandle;
  final TranscriptToolResult? tool;
  final List<UserMessageAttachment> attachments;

  /// Hosted discussion events already carry validated sender/time facts.
  /// They are reading content, without private bot-runtime authority.
  factory TranscriptMessage.discussion({
    required BotGroup group,
    required BotGroupEvent event,
  }) {
    if (!event.isTranscriptEntry) {
      throw ArgumentError('The group event has no transcript entry');
    }
    final user = event.kind == 'message.user';
    final member = group.members
        .where((member) => member.id == event.memberId)
        .firstOrNull;
    return TranscriptMessage._(
      streaming: false,
      kind: event.isPass
          ? TranscriptMessageKind.discussionPass
          : TranscriptMessageKind.discussion,
      role: user ? 'user' : 'assistant',
      id: '${group.id}:${event.sequence}',
      text: event.isPass ? 'Passed' : event.text,
      copyText: event.isPass ? '' : event.text,
      timestamp: event.timestamp,
      sender: user
          ? null
          : member?.name ??
                (event.isPass
                    ? event.memberId
                    : event.actorName.isNotEmpty
                    ? event.actorName
                    : event.actor),
      senderHandle: user ? null : member?.handle,
      attachments: event.attachments.map(
        (attachment) => UserMessageAttachment(
          name: attachment.name,
          target: attachment.target(event.eventId),
          isImage: attachment.isImage,
        ),
      ),
    );
  }

  /// Local speech has no saved-history identity or revision authority.
  factory TranscriptMessage.voice({
    required String id,
    required bool user,
    required String text,
    required DateTime timestamp,
    required bool complete,
  }) => TranscriptMessage._(
    kind: TranscriptMessageKind.voice,
    role: user ? 'user' : 'assistant',
    id: id,
    text: text,
    copyText: text,
    timestamp: timestamp,
    streaming: !complete,
  );

  factory TranscriptMessage.fromRow(
    Map<String, dynamic> row, {
    bool streaming = false,
  }) {
    final role = answerMessageDisplayRole(row) ?? '';
    final rawId = row['id'];
    final id = rawId is int || rawId is String ? rawId : null;
    if (isHiddenAnswerMessage(row)) {
      return TranscriptMessage._(
        streaming: streaming,
        kind: TranscriptMessageKind.hidden,
        role: role,
        id: id,
      );
    }
    final delivery = transcriptUserDelivery(row);
    if (delivery?.kind == 'agent_message') {
      return TranscriptMessage._(
        streaming: streaming,
        kind: TranscriptMessageKind.botMessage,
        role: role,
        id: id,
        text: delivery!.detail,
        copyText: delivery.detail,
        sender: delivery.sender,
        senderHandle: delivery.senderHandle,
        timestamp: _timestamp(row['timestamp']),
      );
    }
    final notice = transcriptNoticeText(row);
    if (notice != null) {
      return TranscriptMessage._(
        streaming: streaming,
        kind: TranscriptMessageKind.notice,
        role: role,
        id: id,
        text: notice,
        noticeResult: transcriptNoticeResult(row),
        noticeDisclosure:
            row['display_kind'] == 'process_complete' ||
                delivery?.kind == 'process_notification'
            ? 'Output'
            : 'View result',
        noticePlainText:
            delivery != null || row['display_kind'] == 'process_complete',
        noticeMonospace:
            delivery?.kind == 'process_notification' ||
            row['display_kind'] == 'process_complete',
      );
    }
    final review = reviewMessageText(row);
    if (review != null) {
      return TranscriptMessage._(
        streaming: streaming,
        kind: TranscriptMessageKind.review,
        role: role,
        id: id,
        text: review,
      );
    }
    final steering = steeringMessageText(row);
    // Acceptance is local feedback until Hermes incorporates this user message
    // into saved history. Keep its raw kind for replay, but render the saved row
    // through the ordinary user bubble and clean-text Copy projection below.
    if (steering != null && (role != 'user' || answerMessageId(row) == null)) {
      return TranscriptMessage._(
        streaming: streaming,
        kind: TranscriptMessageKind.steering,
        role: role,
        id: id,
        text: steering,
      );
    }
    final user = role == 'user' ? UserMessageContent.fromMessage(row) : null;
    final content =
        user?.text ??
        (row['display_content'] ?? row['content'] ?? '').toString();
    if (content.isEmpty && (user?.attachments.isEmpty ?? true)) {
      return TranscriptMessage._(
        streaming: streaming,
        kind: TranscriptMessageKind.hidden,
        role: role,
        id: id,
      );
    }
    if (role == 'system') {
      final slash = _slashOutput.firstMatch(content);
      final command = row['_command'] as String? ?? slash?.group(1)?.trim();
      final output = slash == null ? content : slash.group(2)!.trim();
      final multiline = output.contains('\n');
      return TranscriptMessage._(
        streaming: streaming,
        kind: TranscriptMessageKind.system,
        role: role,
        id: id,
        text: command == null
            ? output
            : '$command${multiline ? '\n' : ' · '}$output',
        systemMultiline: multiline,
      );
    }
    if (role == 'tool') {
      return TranscriptMessage._(
        streaming: streaming,
        kind: TranscriptMessageKind.tool,
        role: role,
        id: id,
        tool: TranscriptToolResult.fromRow(row),
      );
    }
    return TranscriptMessage._(
      streaming: streaming,
      kind: TranscriptMessageKind.dialogue,
      role: role,
      id: id,
      text: content,
      copyText: role == 'user' ? answerMessageDisplayText(row) : content,
      attachments: user?.attachments ?? const [],
      timestamp: _timestamp(row['timestamp']),
    );
  }
}

final _slashOutput = RegExp(r'^slash:(/[^\n]+)\n([\s\S]*)$');

DateTime? _timestamp(Object? seconds) {
  // The existing transcript contract uses Unix seconds; unknown stays absent.
  if (seconds is! num || !seconds.isFinite || seconds.abs() > 8640000000000) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
}

/// Saved tool output copied independently of its mutable gateway/history row.
final class TranscriptToolResult {
  const TranscriptToolResult._({
    required this.id,
    required this.name,
    required this.text,
    required this.rawResult,
    this.callId,
    this.arguments,
    this.context,
    this.summary,
    this.durationSeconds,
    this.labels = const [],
    this.exchangeReceipts = const [],
  });

  final Object? id;
  final String name;
  final String text;
  final String rawResult;
  final String? callId;
  final String? arguments;
  final String? context;
  final String? summary;
  final double? durationSeconds;
  final List<ToolCallLabel> labels;
  final List<BotExchangeReceipt> exchangeReceipts;

  factory TranscriptToolResult.fromRow(
    Map<String, dynamic> row, {
    List<BotExchangeReceipt> exchangeReceipts = const [],
  }) {
    final id = row['id'];
    return TranscriptToolResult._(
      id: id is int || id is String ? id : null,
      name: row['tool_name']?.toString() ?? 'Tool result',
      text: (row['display_content'] ?? row['content'] ?? '').toString(),
      rawResult: (row['content'] ?? '').toString(),
      callId: row['tool_call_id'] as String?,
      context: row['context'] as String?,
      summary: row['summary'] as String?,
      arguments: row['args'] == null
          ? null
          : row['args'] is String
          ? row['args'] as String
          : jsonEncode(row['args']),
      durationSeconds:
          row['duration_s'] is num &&
              (row['duration_s'] as num).isFinite &&
              (row['duration_s'] as num) >= 0
          ? (row['duration_s'] as num).toDouble()
          : null,
      labels: ToolCallLabel.parse(row['labels']),
      exchangeReceipts: List.unmodifiable(exchangeReceipts),
    );
  }
}
