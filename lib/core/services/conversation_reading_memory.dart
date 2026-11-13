import '../models/profile_session_key.dart';
import '../models/transcript_position.dart';

/// App-lifetime reading memory. The shared application preferences object is
/// used only as a lifetime token: no marker is read from or written to disk.
final class ConversationReadingRegistry {
  ConversationReadingRegistry._();
  static final _registries = Expando<ConversationReadingRegistry>();
  factory ConversationReadingRegistry(Object appLifetime) =>
      _registries[appLifetime] ??= ConversationReadingRegistry._();
  final _entries = <Object, ConversationReadingMemory>{};
  ConversationReadingMemory chat(ProfileSessionKey key) =>
      _entries.putIfAbsent(key, ConversationReadingMemory.new);
  ConversationReadingMemory group(String key) =>
      _entries.putIfAbsent(('group', key), ConversationReadingMemory.new);
}

/// Resume can move backwards without making previously viewed messages unread.
final class ConversationReadingMemory {
  TranscriptPosition _position = const TranscriptPosition();
  TranscriptPosition get position => _position;

  void record(TranscriptBookmark? resume, {int? readThrough}) {
    final previous = _position;
    final read =
        readThrough == null ||
            previous.readThrough != null && readThrough < previous.readThrough!
        ? previous.readThrough
        : readThrough;
    if (previous.resume?.messageId == resume?.messageId &&
        previous.resume?.fraction == resume?.fraction &&
        previous.resume?.alignment == resume?.alignment &&
        previous.readThrough == read) {
      return;
    }
    _position = TranscriptPosition(resume: resume, readThrough: read);
  }
}
