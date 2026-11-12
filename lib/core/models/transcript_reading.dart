import 'user_message_content.dart';

/// A passive reading payload. It contains no runtime or execution authority.
/// External inputs are copied and frozen before passive restore admission.
final class TranscriptReadingSnapshot {
  TranscriptReadingSnapshot({
    required Iterable<Map<String, dynamic>> messages,
    required this.historySessionId,
  }) : messages = List.unmodifiable(messages.map(_freezeMessage));

  final List<Map<String, dynamic>> messages;
  final String? historySessionId;
}

Map<String, dynamic> _freezeMessage(Map<String, dynamic> row) =>
    Map.unmodifiable({
      for (final entry in row.entries) entry.key: _freezeValue(entry.value),
    });

Object? _freezeValue(Object? value) {
  if (value is Map) {
    return Map<Object?, Object?>.unmodifiable({
      for (final entry in value.entries) entry.key: _freezeValue(entry.value),
    });
  }
  if (value is List<UserMessageAttachment>) {
    return List<UserMessageAttachment>.unmodifiable([
      for (final attachment in value)
        UserMessageAttachment(
          name: attachment.name,
          target: attachment.target,
          isImage: attachment.isImage,
        ),
    ]);
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freezeValue));
  if (value is UserMessageAttachment) {
    return UserMessageAttachment(
      name: value.name,
      target: value.target,
      isImage: value.isImage,
    );
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  throw const FormatException('Unsupported transcript value.');
}
