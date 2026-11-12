import 'package:flutter/foundation.dart';

/// One issued search result. Selection accepts the issued instance, not its ID.
@immutable
final class ChatReadingMatch {
  const ChatReadingMatch({
    required this.text,
    required this.role,
    required this.canSelect,
  });

  final String text;
  final String role;
  final bool canSelect;
}

@immutable
final class ChatReadingObservation {
  ChatReadingObservation({
    required Iterable<ChatReadingMatch> matches,
    required this.query,
    required this.hasLoadedMessages,
    required this.loading,
    required this.hasMore,
    required this.error,
    required this.retired,
  }) : matches = List.unmodifiable(matches);

  final List<ChatReadingMatch> matches;
  final String query;
  final bool hasLoadedMessages;
  final bool loading;
  final bool hasMore;
  final String? error;
  final bool retired;
}

/// Passive focus facts for the existing transcript viewport.
@immutable
final class ChatReadingFocus {
  const ChatReadingFocus({required this.offset, required this.rowId});
  final int offset;
  final int rowId;
}
