import 'skill_invocation.dart';
import 'user_message_delivery.dart';
import 'composer_reference.dart';

/// Reading identity only. Hermes stores automated notes as user input; their
/// notification kind presents them as incoming assistant content in Wing.
/// Replay, ordering and saved-message actions must use the authoritative row.
String? answerMessageDisplayRole(Map<String, dynamic> message) =>
    message['role'] == 'user' &&
        message['display_kind'] == 'internal_notification'
    ? 'assistant'
    : message['role']?.toString();

/// Text projection for gateway display messages and stored multimodal content.
String answerMessageText(Map<String, dynamic> message) {
  final value = message['content'] ?? message['text'];
  return _answerText(value);
}

/// The gateway's delivery envelope is model context, not user-facing prose.
/// Persisted user rows are classified by Hermes's display kind. The envelope
/// parser only extracts content from an already classified steering message.
String? steeringMessageText(Map<String, dynamic> message) {
  if (message['role'] == 'system') {
    final text = answerMessageText(message);
    return text.startsWith('steer:') ? text.substring(6).trim() : null;
  }
  if (message['role'] != 'user' || message['display_kind'] != 'steer') {
    return null;
  }
  final projected = message['display_content'];
  if (projected != null) return _answerText(projected).trim();
  final raw = answerMessageText(message).trim();
  final match = _steeringEnvelope.firstMatch(raw);
  if (match != null) return match.group(1)!.trim();
  return raw;
}

/// Read the stock display metadata at its wire boundary. Malformed or unknown
/// values carry no display authority; content is never inspected to infer them.
Map answerMessageDisplayMetadata(Map<String, dynamic> message) {
  final metadata = message['display_metadata'];
  return metadata is Map ? metadata : const {};
}

final _steeringEnvelope = RegExp(
  r'^\[OUT-OF-BAND USER MESSAGE(?: — [^\]\r\n]*)?\]\r?\n([\s\S]*?)\r?\n\[/OUT-OF-BAND USER MESSAGE\]$',
);

/// Desktop-compatible text for displaying or replaying a saved user prompt.
///
/// Hermes persists expanded `@` context in `content`. Desktop removes the
/// producer-owned suffix while hydrating user messages, then regenerates from
/// that hydrated text. Assistant content must stay byte-for-byte visible.
String answerMessageDisplayText(Map<String, dynamic> message) {
  if (answerMessageDisplayRole(message) != 'user') {
    return answerMessageText(message);
  }
  final steering = steeringMessageText(message);
  if (steering != null) {
    return PreparedComposerMessage.parse(steering)?.displayMessage ?? steering;
  }
  final value =
      message['display_content'] ?? message['content'] ?? message['text'];
  final rawText = _answerText(value, displayImages: true);
  final text =
      PreparedComposerMessage.parse(rawText)?.displayMessage ?? rawText;
  final invocation = skillInvocationText(text);
  if (invocation != null) return invocation;
  final marker = RegExp(
    r'(?:^|\n)--- Attached Context ---\s*\n',
  ).firstMatch(text);
  if (marker == null) return _withoutContextWarnings(text);

  final visible = _withoutContextWarnings(text.substring(0, marker.start));
  final attached = text.substring(marker.end);
  final refs = <String>{
    for (final match in _contextReferencePattern.allMatches(attached))
      match.group(0)!,
  };
  final missing = refs.where((ref) => !visible.contains(ref)).join('\n');
  return [missing, visible].where((part) => part.isNotEmpty).join('\n\n');
}

final _contextWarningsPattern = RegExp(
  r'(?:^|\n)--- Context Warnings ---[\s\S]*$',
);
final _contextReferencePattern = RegExp(
  r'''@(file|folder|url|image|tool|terminal):(?:"[^"\n]+"|'[^'\n]+'|`[^`\n]+`|\S+)''',
);

String _withoutContextWarnings(String text) =>
    text.replaceFirst(_contextWarningsPattern, '').trim();

String _answerText(Object? value, {bool displayImages = false}) {
  if (value is List) {
    return value.map((part) {
      if (part is String) return part;
      if (part is! Map) return '';
      if (part['text'] is String) return part['text'] as String;
      if (part['type'] == null) return '';
      final text = _structuredText(part, displayImages: displayImages);
      return {'text', 'input_text', 'output_text'}.contains(part['type'])
          ? text
          : '\n$text';
    }).join();
  }
  return value is Map
      ? _structuredText(value, displayImages: displayImages)
      : value?.toString() ?? '';
}

String _structuredText(Map part, {bool displayImages = false}) {
  final kind = part['type'];
  if ({'text', 'input_text', 'output_text'}.contains(kind)) {
    return (part['text'] ?? part['content'] ?? '').toString();
  }
  if ({'image_url', 'input_image', 'image'}.contains(kind)) {
    if (displayImages) return '[image]';
    final image = part['image_url'];
    final url = image is Map ? image['url'] : image;
    return url is String && url.isNotEmpty ? url : '[image]';
  }
  if ({'audio', 'input_audio'}.contains(kind)) return '[audio]';
  if (kind != null && kind != '') return '[$kind]';
  if (part.containsKey('text')) return part['text']?.toString() ?? '';
  return '[structured content]';
}

/// Text for classifying a row without preparing attachment locations or bodies.
String answerMessageInspectionText(Map<String, dynamic> message) =>
    _answerText(message['content'] ?? message['text'], displayImages: true);

bool isBranchMessage(Map<String, dynamic> message) =>
    {'user', 'assistant'}.contains(message['role']) &&
    answerMessageInspectionText(message).trim().isNotEmpty;

bool isHiddenAnswerMessage(Map<String, dynamic> message) {
  if (message['display_kind'] == 'hidden' ||
      answerMessageDisplayMetadata(message)['model_only'] == true) {
    return true;
  }
  // Producer classification wins over recognizers for the remaining untyped
  // stock rows. Authored steering text can itself quote any technical marker.
  if (message['role'] != 'user' || message['display_kind'] != null) {
    return false;
  }
  if (message['_todo_snapshot_synthetic'] == true ||
      answerMessageInspectionText(message).trimLeft().startsWith('[System:')) {
    return true;
  }
  final display = answerMessageDisplayText(message);
  return _isTaskSnapshot(display) || _isContinuationReminder(display);
}

/// A compaction reminder repeats the active request for the agent. Recognize
/// the complete standalone envelope, leaving quoted or partial markers visible.
bool _isContinuationReminder(String text) {
  const header =
      '[STILL IN PROGRESS — this is the active request, restated after the '
      'compaction boundary because it was not finished yet. Continue it; '
      'do not start over.]';
  text = text.trim().replaceAll('\r\n', '\n');
  return text.startsWith('$header\n') &&
      text.substring(header.length + 1).trim().isNotEmpty;
}

/// TodoStore.format_for_injection uses this stable header for standalone
/// post-compression snapshots. Stock persistence omits the synthetic flag. Match
/// only that envelope at the start, never a task list or quoted marker alone.
/// Keep stored rows intact so paging and rewind retain their server ordinals.
bool _isTaskSnapshot(String text) {
  const header =
      '[Your active task list was preserved across context compression]';
  text = text.trim().replaceAll('\r\n', '\n');
  if (!text.startsWith('$header\n')) return false;
  final body = text.substring(header.length + 1);
  // Completed/cancelled parents can be retained above active descendants.
  return const [
    '- [>] ',
    '- [ ] ',
    '- [x] ',
    '- [~] ',
  ].any((marker) => body.startsWith(marker) && body.length > marker.length);
}

bool isAnswerPrompt(Map<String, dynamic> message) =>
    message['role'] == 'user' &&
    message['display_kind'] == null &&
    isBranchMessage(message);

/// Keep durable user ordinals intact, but never edit or replay a delivery.
bool isHumanAnswerPrompt(Map<String, dynamic> message) =>
    isAnswerPrompt(message) &&
    !isHiddenAnswerMessage(message) &&
    userMessageDelivery(answerMessageDisplayText(message)) == null;

int? answerMessageId(Map<String, dynamic> message) {
  final id = message['row_id'] ?? message['id'];
  return id is int ? id : null;
}

List<Map<String, dynamic>> answerHistoryRows(
  List<Map<String, dynamic>> messages,
) => messages
    .map(
      (m) => {
        ...m,
        'id': answerMessageId(m),
        // Keep user content parts intact so forked/rewound history can render
        // its attachments. Text-only consumers use the projections above.
        'content': m['role'] == 'user'
            ? m['content'] ?? m['text']
            : answerMessageText(m),
      },
    )
    .toList();

class AnswerTarget {
  final int userOrdinal;
  final String prompt;
  final int? userRowId;
  const AnswerTarget(this.userOrdinal, this.prompt, {this.userRowId});

  static AnswerTarget? at(List<Map<String, dynamic>> messages, int index) {
    if (index < 0 ||
        index >= messages.length ||
        messages[index]['role'] != 'assistant' ||
        !isBranchMessage(messages[index])) {
      return null;
    }
    var ordinal = -1;
    var prompt = '';
    int? rowId;
    for (final message in messages.take(index + 1)) {
      if (isAnswerPrompt(message)) {
        ordinal++;
        prompt = answerMessageText(message);
        rowId = message['row_id'] is int ? message['row_id'] as int : null;
      }
    }
    return AnswerTarget(ordinal, prompt, userRowId: rowId);
  }
}
