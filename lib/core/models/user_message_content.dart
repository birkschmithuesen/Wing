import 'answer_versions.dart';

/// An attachment in a sent user message. Paths always belong to the server.
class UserMessageAttachment {
  final String name;
  final String target;
  final bool isImage;

  const UserMessageAttachment({
    required this.name,
    required this.target,
    required this.isImage,
  });

  /// Passive metadata for the reading cache, without bytes or upload authority.
  bool get canCacheReadingMetadata =>
      name.isNotEmpty &&
      name.length <= 1024 &&
      target.isNotEmpty &&
      target.length <= 8192 &&
      Uri.tryParse(target.trimLeft())?.scheme.toLowerCase() != 'data';

  Map<String, dynamic> toReadingJson() => {
    'name': name,
    'target': target,
    'is_image': isImage,
  };

  static UserMessageAttachment? fromReadingJson(Object? value) {
    if (value is! Map ||
        value['name'] is! String ||
        value['target'] is! String ||
        value['is_image'] is! bool) {
      return null;
    }
    final attachment = UserMessageAttachment(
      name: value['name'] as String,
      target: value['target'] as String,
      isImage: value['is_image'] as bool,
    );
    return attachment.canCacheReadingMetadata ? attachment : null;
  }

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot > 0 && dot < name.length - 1
        ? name.substring(dot + 1).toUpperCase()
        : 'FILE';
  }
}

/// Keeps attachment bytes and server references out of the visible prose.
/// Copy/edit/replay continue to use the original message projection.
class UserMessageContent {
  final String text;
  final List<UserMessageAttachment> attachments;

  const UserMessageContent(this.text, this.attachments);

  factory UserMessageContent.fromMessage(Map<String, dynamic> message) {
    final attachments = <UserMessageAttachment>[];
    final seen = <String>{};
    void add(String target, bool isImage, [String? name]) {
      if (target.isEmpty || !seen.add(target)) return;
      final uri = target.startsWith('data:') ? null : Uri.tryParse(target);
      final leaf = target.startsWith('data:')
          ? ''
          : (uri?.pathSegments.lastOrNull ??
                target.split(RegExp(r'[/\\]')).last);
      attachments.add(
        UserMessageAttachment(
          name: name?.trim().isNotEmpty == true
              ? name!
              : leaf.isNotEmpty
              ? leaf
              : isImage
              ? 'Image'
              : 'File',
          target: target,
          isImage: isImage,
        ),
      );
    }

    final submitted = message['submitted_attachments'];
    if (submitted is List<UserMessageAttachment>) {
      for (final attachment in submitted) {
        add(attachment.target, attachment.isImage, attachment.name);
      }
    }

    final imageParts = <({String target, String? name})>[];
    Object? withoutImages(Object? value) {
      if (value is List) return value.map(withoutImages).toList();
      if (value is! Map) return value;
      if (!{'image_url', 'input_image', 'image'}.contains(value['type'])) {
        return value;
      }
      final image = value['image_url'];
      final target = image is Map ? image['url'] : image ?? value['url'];
      imageParts.add((
        target: target is String ? target : '',
        name: value['name'] is String ? value['name'] as String : null,
      ));
      return '';
    }

    // Read saved image parts even when the gateway supplies a separate caption.
    final content = withoutImages(message['content'] ?? message['text']);
    final display = withoutImages(message['display_content']);
    var text = answerMessageDisplayText({
      ...message,
      'content': content,
      'display_content': display,
    });
    // Native vision replaces refs with tool-readable path hints. Flattened
    // history retains these hints, matching screenshot stand-ins and sometimes
    // a final model-only memory block. Require the complete producer suffix
    // and image evidence so literal examples remain authored text.
    final native = _nativeImageContent(text, imageParts.length);
    if (native != null) {
      text = native.text;
      for (final target in native.targets) {
        add(target, true);
      }
    } else {
      for (final image in imageParts) {
        add(image.target, true, image.name);
      }
    }
    // Gateway file uploads prepend one reference per line. Only those complete
    // lines become cards; references quoted or discussed in prose stay intact.
    var imageReferences = 0;
    text = text.replaceAllMapped(_referenceLine, (match) {
      var target = match.group(2)!;
      if (target.startsWith('"') ||
          target.startsWith("'") ||
          target.startsWith('`')) {
        target = target.substring(1, target.length - 1);
      }
      add(target, match.group(1) == 'image');
      if (match.group(1) == 'image') imageReferences++;
      return '';
    }).trim();
    // The stock store appends one stand-in per image when flattening a row.
    // Only remove a complete matching suffix backed by explicit image refs.
    final lines = text.split('\n');
    var placeholders = 0;
    while (lines.isNotEmpty && lines.last == '[screenshot]') {
      lines.removeLast();
      placeholders++;
    }
    if (imageReferences > 0 && placeholders == imageReferences) {
      text = lines.join('\n').trimRight();
    }
    return UserMessageContent(text, List.unmodifiable(attachments));
  }
}

final _referenceLine = RegExp(
  r'''^[ \t]*@(file|image):("[^"\n]+"|'[^'\n]+'|`[^`\n]+`|\S+)[ \t]*\r?$''',
  multiLine: true,
);

({String text, List<String> targets})? _nativeImageContent(
  String text,
  int imagePartCount,
) {
  final match = _nativeImageSuffix.firstMatch(text);
  if (match == null) return null;
  final targets = match.group(1)!.split(RegExp(r'\r?\n')).map((line) {
    return line.substring('[Image attached at: '.length, line.length - 1);
  }).toList();
  if (targets.any((target) => target.trim().isEmpty)) return null;
  final placeholders = '\n[screenshot]'
      .allMatches(match.group(2)!.replaceAll('\r\n', '\n'))
      .length;
  if (placeholders != 0 && placeholders != targets.length) return null;
  if (imagePartCount != 0 && imagePartCount != targets.length) return null;
  if (placeholders == 0 && imagePartCount == 0) return null;
  return (text: text.substring(0, match.start).trimRight(), targets: targets);
}

final _nativeImageSuffix = RegExp(
  r'(?:^|\r?\n\r?\n)'
  r'(\[Image attached at: [^\r\n\]]+\](?:\r?\n\[Image attached at: [^\r\n\]]+\])*)'
  r'((?:\r?\n\[screenshot\])*)'
  r'(?:\r?\n<memory-context>[\s\S]*?</memory-context>)?$',
);
