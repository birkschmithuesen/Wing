import 'dart:convert';
import 'profile_session_key.dart';
import 'bots.dart';
import 'transcript_reading.dart';
import 'transcript_message.dart';
import 'chat_notification_content.dart';

/// Compact display text for the most recent message, including code-only
/// replies. Excerpts preserve the beginning of the message, not its last sentence.
String recentMessageExcerpt(String text) => notificationTextLimit(
  notificationPlainText(
    text
        .replaceAll(RegExp(r'(^|\n)\s*(```|~~~)[^\n]*'), '\n')
        .replaceAll(RegExp(r'^[ \t]+', multiLine: true), ''),
  ),
  240,
);

/// Null means this saved page has no visible conversational message.
String? recentChatMessagePreview(List<Map<String, dynamic>> messages) {
  for (final row in messages.reversed) {
    final message = TranscriptMessage.fromRow(row);
    if (!{
          TranscriptMessageKind.dialogue,
          TranscriptMessageKind.steering,
          TranscriptMessageKind.botMessage,
        }.contains(message.kind) ||
        message.text.trim().isEmpty) {
      continue;
    }
    return recentMessageExcerpt(message.text);
  }
  return null;
}

/// A chat and a hosted room have distinct, authenticated identities.
final class RecentConversationKey {
  const RecentConversationKey.chat(ProfileSessionKey value)
    : chat = value,
      group = null;
  const RecentConversationKey.group(String value) : group = value, chat = null;
  final ProfileSessionKey? chat;
  final String? group;
  @override
  bool operator ==(Object other) =>
      other is RecentConversationKey &&
      chat == other.chat &&
      group == other.group;
  @override
  int get hashCode => Object.hash(chat, group);
}

/// One immutable conversation identity in the canonical Recents order.
final class RecentConversationEntry {
  RecentConversationEntry.chat({
    required ProfileSessionKey key,
    required this.title,
    required this.unread,
  }) : key = RecentConversationKey.chat(key),
       group = null;
  RecentConversationEntry.group(BotGroup value, {required this.unread})
    : key = RecentConversationKey.group(value.key),
      title = value.name,
      group = value;
  final RecentConversationKey key;
  final String title;
  final bool unread;
  final BotGroup? group;
}

/// Immutable passive discussion facts; no room visibility/read authority.
final class GroupConversationPreview {
  GroupConversationPreview({required Iterable<TranscriptMessage> messages})
    : messages = List.unmodifiable(messages);
  final List<TranscriptMessage> messages;
}

/// Every card borrows current identity separately from its saved transcript.
final class RecentConversationAppearance {
  const RecentConversationAppearance({
    this.bot,
    this.pixelRevisionOverride,
    this.group = const BotGroupAppearance.empty(),
  });
  final BotRecord? bot;
  final String? pixelRevisionOverride;
  String get pixelRevision =>
      pixelRevisionOverride ??
      jsonEncode([
        if (bot case final value?) _pixels(value),
        for (final member in group.byHandle.entries)
          [member.key, _pixels(member.value)],
      ]);
  static List<Object?> _pixels(BotRecord bot) => [
    bot.scope.connectionId,
    bot.scope.connectionIdentity,
    bot.scope.profileName,
    bot.title,
    bot.shape,
    bot.color,
    bot.metadata['imageKind'],
  ];
  final BotGroupAppearance group;
  @override
  bool operator ==(Object other) =>
      other is RecentConversationAppearance &&
      bot == other.bot &&
      group == other.group &&
      pixelRevision == other.pixelRevision;
  @override
  int get hashCode => Object.hash(bot, group, pixelRevision);
}

/// A captured catalog, including usable entries after partial failure.
final class RecentConversationCatalog {
  RecentConversationCatalog({
    required Iterable<RecentConversationEntry> entries,
    required this.error,
  }) : entries = List.unmodifiable(entries);
  final List<RecentConversationEntry> entries;
  final String? error;
}

/// Passive saved-history facts, never live execution or selection authority.
final class RecentConversationPreview {
  const RecentConversationPreview({
    required this.entry,
    required this.reading,
    required this.draft,
    required this.scopeLabel,
    this.modelLabel,
    this.group,
  });
  final RecentConversationEntry entry;
  final TranscriptReadingSnapshot reading;
  final String draft, scopeLabel;
  final String? modelLabel;
  final GroupConversationPreview? group;
}

final class RecentConversationCard {
  const RecentConversationCard({
    required this.entry,
    this.preview,
    this.bot,
    this.groupAppearance = const BotGroupAppearance.empty(),
    this.loading = false,
    this.error,
  });
  final RecentConversationEntry entry;
  final RecentConversationPreview? preview;
  final BotRecord? bot;
  final BotGroupAppearance groupAppearance;
  final bool loading;
  final String? error;
}

enum ConversationActivityKind { reply, inputNeeded }

enum ConversationDirection { left, right }

/// A transient projection of a newly admitted notification-journal fact.
/// It has no persistence or notification-delivery authority.
final class ChatNoticeActivity {
  const ChatNoticeActivity({
    required this.key,
    required this.kind,
    required this.identity,
    required this.sequence,
  });
  final RecentConversationKey key;
  final ConversationActivityKind kind;
  final String identity;
  final int sequence;
}

final class ConversationNudge {
  const ConversationNudge({
    required this.key,
    required this.direction,
    required this.kind,
    required this.sequence,
  });
  final RecentConversationKey key;
  final ConversationDirection direction;
  final ConversationActivityKind kind;
  final int sequence;
}

ConversationDirection? recentConversationDirection(
  List<RecentConversationEntry> entries,
  RecentConversationKey current,
  RecentConversationKey target,
) {
  final from = entries.indexWhere((entry) => entry.key == current);
  final to = entries.indexWhere((entry) => entry.key == target);
  if (from < 0 || to < 0 || from == to || entries.length < 2) return null;
  final right = (to - from + entries.length) % entries.length;
  return right <= entries.length - right
      ? ConversationDirection.right
      : ConversationDirection.left;
}
