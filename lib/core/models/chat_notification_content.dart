import 'package:flutter/widgets.dart' show StringCharacters;
import 'turn_failure.dart';

enum ChatNotificationCategory { update, inputNeeded, stopped }

/// Event-owned content, captured before history refresh or platform delivery.
/// Only user-facing reply/question/approval text may be used as an excerpt.
class ChatNotificationContent {
  final ChatNotificationCategory category;
  final String status;
  final String preview;
  final bool needsAttention;

  const ChatNotificationContent._(
    this.category,
    this.status,
    this.preview,
    this.needsAttention,
  );

  factory ChatNotificationContent.reply(String text) =>
      ChatNotificationContent._(
        ChatNotificationCategory.update,
        'Reply ready',
        _excerpt(text, 'Open the chat to read the reply.'),
        false,
      );

  factory ChatNotificationContent.input(String text) =>
      ChatNotificationContent._(
        ChatNotificationCategory.inputNeeded,
        'Input needed',
        _excerpt(text, 'Open the chat to continue.'),
        true,
      );

  static const secureInput = ChatNotificationContent._(
    ChatNotificationCategory.inputNeeded,
    'Input needed',
    'Open the chat to provide secure input.',
    true,
  );
  static const failed = ChatNotificationContent._(
    ChatNotificationCategory.stopped,
    'Failed',
    'Open the chat for details.',
    true,
  );
  factory ChatNotificationContent.failure(TurnFailure failure) =>
      ChatNotificationContent._(
        ChatNotificationCategory.stopped,
        failure.title,
        failure.recovery ?? 'Open the chat for details.',
        true,
      );
  static const stopped = ChatNotificationContent._(
    ChatNotificationCategory.stopped,
    'Stopped',
    'The response was interrupted.',
    false,
  );
  static const updated = ChatNotificationContent._(
    ChatNotificationCategory.update,
    'Chat updated',
    'Open the chat to see the outcome.',
    false,
  );

  factory ChatNotificationContent.approval(
    String command,
    String description,
  ) => ChatNotificationContent._(
    ChatNotificationCategory.inputNeeded,
    'Approval needed',
    command.trim().isNotEmpty ? command.trim() : description.trim(),
    true,
  );

  Map<String, dynamic> toJson() => {
    'category': category.name,
    'status': status,
    'preview': preview,
    'attention': needsAttention,
  };
  factory ChatNotificationContent.fromJson(Map<String, dynamic> value) =>
      ChatNotificationContent._(
        ChatNotificationCategory.values.byName(value['category'] as String),
        value['status'] as String,
        value['preview'] as String,
        value['attention'] as bool,
      );

  String body({required bool showPreview, int limit = 180}) =>
      notificationTextLimit(
        !showPreview
            ? status
            : category == ChatNotificationCategory.stopped
            ? '$status · $preview'
            : preview,
        limit,
      );

  static String _excerpt(String text, String empty) {
    final clean = notificationPlainText(text);
    return clean.isEmpty ? empty : notificationTextLimit(clean, 800);
  }
}

/// Conservative display projection; this is not a general secret detector.
String notificationPlainText(String text) {
  return text
      .replaceAll(
        RegExp(
          r'<(think|thinking|reasoning|tool_result|tool_call|agent_message|process_notification)\b[^>]*>[\s\S]*?(</\1>|$)',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(r'(^|\n)\s*(```|~~~)[\s\S]*?(\n\s*\2[^\n]*(\n|$)|$)'),
        ' ',
      )
      .replaceAll(RegExp(r'^(?: {4}|\t)[^\n]*', multiLine: true), ' ')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'(https?://|www\.)\S+', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(
        RegExp(r'\b(sk-[a-zA-Z0-9_-]{12,}|gh[pousr]_[a-zA-Z0-9_]{12,})\b'),
        '[redacted]',
      )
      .replaceAll(
        RegExp(
          r'\b(password|api[_ -]?key|token|secret)\s*[:=]\s*\S+',
          caseSensitive: false,
        ),
        '[redacted]',
      )
      .replaceAll(RegExp(r'(^|\n)\s{0,3}(#{1,6}\s+|>\s*|[-+*]\s+)'), ' ')
      .replaceAll(RegExp(r'[`*_~]'), '')
      .replaceAll(
        RegExp(r'[\x00-\x1f\x7f\u200b\u200e\u200f\u202a-\u202e\u2066-\u2069]'),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String notificationTextLimit(String text, int limit) {
  if (text.characters.length <= limit) return text;
  final prefix = text.characters.take(limit - 1).toString();
  final boundary = prefix.lastIndexOf(' ');
  return '${boundary > prefix.length ~/ 2 ? prefix.substring(0, boundary) : prefix}…';
}
