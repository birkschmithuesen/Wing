import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import 'media_reference.dart';

enum ChatOutputKind { image, file, link }

class ChatOutput {
  final ChatOutputKind kind;
  final String? path;
  final String? url;
  final String label;
  final String? fragment;

  const ChatOutput({
    required this.kind,
    required this.path,
    required this.url,
    required this.label,
    this.fragment,
  });

  String get target => path ?? url!;
}

/// Returns a file output for an explicit Markdown target that Hermes can read.
/// Web URLs and other URI schemes are left to their dedicated handlers.
ChatOutput? explicitRemoteFileOutput(String target) {
  final normalized = _normalizeExplicitMarkdownTarget(target);
  if (normalized == null) return null;
  if (_isUrl(normalized) ||
      _hasUnsupportedScheme(normalized) ||
      !_looksLikeExplicitFileTarget(normalized)) {
    return null;
  }
  return ChatOutput(
    kind: _imageExtension.hasMatch(normalized)
        ? ChatOutputKind.image
        : ChatOutputKind.file,
    path: normalized,
    url: null,
    label: _decodedPathLabel(normalized),
    fragment: target.contains('#')
        ? _decodeExplicitPath(target.substring(target.indexOf('#') + 1))
        : null,
  );
}

/// Links in a document are relative to that document, not the chat's cwd.
ChatOutput? resolveDocumentFileLink(String target, String documentPath) {
  final output = explicitRemoteFileOutput(
    target.startsWith('#')
        ? Uri(pathSegments: documentPath.split('/')).toString() + target
        : target,
  );
  if (output == null) return null;
  var path = output.path!;
  if (!RegExp(r'^(?:/|~[\\/]|[A-Za-z]:[\\/]|\\\\)').hasMatch(path)) {
    final windows = RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\)').hasMatch(documentPath);
    path = Uri.decodeComponent(
      Uri(
            pathSegments:
                (windows ? documentPath.replaceAll('\\', '/') : documentPath)
                    .split('/'),
          )
          .resolveUri(
            Uri(
              pathSegments: (windows ? path.replaceAll('\\', '/') : path).split(
                '/',
              ),
            ),
          )
          .path,
    );
    if (windows) path = path.replaceAll('/', '\\');
  }
  return ChatOutput(
    kind: output.kind,
    path: path,
    url: null,
    label: output.label,
    fragment: output.fragment,
  );
}

String _decodedPathLabel(String path) =>
    path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).lastOrNull ??
    path;

/// MEDIA carries a literal server filename; percent signs, query characters
/// and Windows separators are not URL syntax (except in an explicit file URI).
ChatOutput? mediaRemoteFileOutput(String target) {
  final path = _normalizeTarget(target);
  if (_isUrl(path) ||
      _hasUnsupportedScheme(path) ||
      !_looksLikeExplicitFileTarget(path)) {
    return null;
  }
  return ChatOutput(
    kind: _imageExtension.hasMatch(path)
        ? ChatOutputKind.image
        : ChatOutputKind.file,
    path: path,
    url: null,
    label: _decodedPathLabel(path),
  );
}

String? _normalizeExplicitMarkdownTarget(String target) {
  final value = target.trim();
  if (value.toLowerCase().startsWith('file:')) {
    return _normalizeTarget(value);
  }
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) || value.startsWith(r'\\')) {
    return _decodeExplicitPath(_withoutUriSuffix(value));
  }
  final uri = Uri.tryParse(value);
  if (uri == null) return _decodeExplicitPath(_withoutUriSuffix(value));
  if (uri.hasScheme || uri.host.isNotEmpty) return null;
  return _decodeExplicitPath(_withoutUriSuffix(value));
}

String _withoutUriSuffix(String value) {
  final query = value.indexOf('?');
  final fragment = value.indexOf('#');
  final end = [
    if (query >= 0) query,
    if (fragment >= 0) fragment,
  ].fold(value.length, (current, index) => index < current ? index : current);
  return value.substring(0, end);
}

String _decodeExplicitPath(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return value;
  }
}

bool _looksLikeExplicitFileTarget(String value) {
  if (_isFilePath(value)) return true;
  final leaf = value.split(RegExp(r'[\\/]')).last;
  return leaf.isNotEmpty &&
      leaf != '.' &&
      leaf != '..' &&
      leaf.contains('.') &&
      !leaf.startsWith('#');
}

final _media = RegExp(mediaReferencePattern, caseSensitive: false);
final _url = RegExp(r'''https?://[^\s<>"')]+''');
final _unixPath = RegExp(
  r'''(^|[\s("'`])((?:/|~[\\/]|\.\.?[\\/]|\\\\)[^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)''',
  caseSensitive: false,
  multiLine: true,
);
final _windowsPath = RegExp(
  r'''(^|[\s("'`])([A-Za-z]:[\\/][^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)''',
  caseSensitive: false,
  multiLine: true,
);
final _imageExtension = RegExp(
  r'\.(?:png|jpe?g|gif|webp|svg|bmp)(?:\?.*)?$',
  caseSensitive: false,
);
final _fileExtension = RegExp(
  r'\.(?:png|jpe?g|gif|webp|svg|bmp|pdf|txt|json|md|markdown|csv|docx?|xlsx?|pptx?|odt|ods|odp|rtf|epub|html?|zip|7z|rar|tar|gz|tgz|bz2|xz|avi|flac|m4a|mkv|mp3|ogg|opus|wav|webm|mp4|mov)(?:\?.*)?$',
  caseSensitive: false,
);
final _producerTool = RegExp(
  r'(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)',
  caseSensitive: false,
);
final _strongToolKey = RegExp(
  r'^(?:artifact_(?:file|image|path|url)|files?_(?:created|modified|written)|generated_(?:file|image|path|url)|media_tag|output_(?:file|path|url)|result_(?:file|path|url)|saved_to|screenshot_path)$',
  caseSensitive: false,
);
final _producerToolKey = RegExp(
  r'^(?:artifact(?:s|_(?:file|image|path|url))?|attachment(?:s|_(?:file|image|path|url))?|download(?:s|_(?:file|path|url))?|(?:audio|image|video)(?:_(?:file|path|url))?|file_path|local_path|media(?:_(?:file|path|url))?|path)$',
  caseSensitive: false,
);

typedef _AddOutput = void Function(String candidate, {bool explicit});

/// Extracts output references from one chat's raw, server-owned history.
List<ChatOutput> extractChatOutputs(Iterable<Map<String, dynamic>> history) {
  final found = <String, ChatOutput>{};

  void add(String candidate, {bool explicit = false}) {
    final target = _normalizeTarget(candidate);
    final file =
        _isFilePath(target) ||
        explicit && !_isUrl(target) && _fileExtension.hasMatch(target);
    if (!_looksLikeOutput(target, explicit: explicit) ||
        found.containsKey(target)) {
      return;
    }
    found[target] = ChatOutput(
      kind:
          _imageExtension.hasMatch(target) ||
              target.toLowerCase().startsWith('data:image/')
          ? ChatOutputKind.image
          : file
          ? ChatOutputKind.file
          : ChatOutputKind.link,
      path: file ? target : null,
      url: file ? null : target,
      label: _label(target),
    );
  }

  for (final message in history) {
    final role = message['role']?.toString();
    final text = _messageText(message);
    if (role == 'assistant') {
      _collectText(text, add);
    } else if (role == 'tool') {
      _collectTool(message, text, add);
    }
  }
  return found.values.toList();
}

void _collectText(String text, _AddOutput add) {
  for (final match in _media.allMatches(text)) {
    add(mediaReferenceTarget(match.group(1) ?? ''), explicit: true);
  }
  // Code can describe API routes, commands or examples. Only explicit MEDIA
  // above is delivery intent inside code; never scan code as implicit files.
  final prose = StringBuffer();
  void visit(md.Node node) {
    if (node is md.Text) {
      prose.writeln(node.text);
      return;
    }
    if (node is! md.Element || node.tag == 'code' || node.tag == 'pre') return;
    final target = switch (node.tag) {
      'a' => node.attributes['href'],
      'img' => node.attributes['src'],
      _ => null,
    };
    if (target != null) add(target, explicit: true);
    for (final child in node.children ?? const <md.Node>[]) {
      visit(child);
    }
  }

  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  for (final node in document.parse(text)) {
    visit(node);
  }
  text = prose.toString();
  for (final match in _url.allMatches(text)) {
    add(match.group(0) ?? '');
  }
  for (final match in _unixPath.allMatches(text)) {
    add(match.group(2) ?? '');
  }
  for (final match in _windowsPath.allMatches(text)) {
    add(match.group(2) ?? '');
  }
}

void _collectTool(Map<String, dynamic> message, String text, _AddOutput add) {
  final name =
      (message['tool_name'] ?? message['name'])
          ?.toString()
          .trim()
          .toLowerCase() ??
      '';
  final producer =
      _producerTool.hasMatch(name) || name.startsWith('bfl_flux3_');
  if (producer) {
    for (final match in _media.allMatches(text)) {
      add(mediaReferenceTarget(match.group(1) ?? ''), explicit: true);
    }
  }
  if (name == 'browser_vision') {
    final screenshot = RegExp(
      r'Screenshot path:\s*([^\r\n<>]+)',
      caseSensitive: false,
    );
    for (final match in screenshot.allMatches(text)) {
      add(match.group(1) ?? '', explicit: true);
    }
  }

  final payloads = <Object?>[];
  for (final candidate in [text, _untrustedPayload(text)]) {
    if (candidate == null || candidate.trim().isEmpty) continue;
    try {
      payloads.add(jsonDecode(candidate));
    } on FormatException {
      // Tool prose is common and is not a structured output contract.
    }
  }
  final content = message['content'];
  if (content is Map && content['_multimodal'] == true) {
    payloads.add(content['meta']);
  } else if (content is! String) {
    payloads.add(content);
  }
  for (final payload in payloads) {
    _visitPayload(payload, '', producer, add);
  }
}

void _visitPayload(
  Object? value,
  String keyPath,
  bool producer,
  _AddOutput add,
) {
  if (value is String) {
    final allowed = keyPath
        .split('.')
        .where((part) => part.isNotEmpty && int.tryParse(part) == null)
        .any(
          (part) =>
              _strongToolKey.hasMatch(part) ||
              producer && _producerToolKey.hasMatch(part),
        );
    if (!allowed) return;
    for (final match in _media.allMatches(value)) {
      add(mediaReferenceTarget(match.group(1) ?? ''), explicit: true);
    }
    add(value, explicit: true);
  } else if (value is List) {
    for (var i = 0; i < value.length; i++) {
      _visitPayload(value[i], '$keyPath.$i', producer, add);
    }
  } else if (value is Map) {
    for (final entry in value.entries) {
      _visitPayload(
        entry.value,
        keyPath.isEmpty ? '${entry.key}' : '$keyPath.${entry.key}',
        producer,
        add,
      );
    }
  }
}

String _messageText(Map<String, dynamic> message) {
  for (final key in const ['content', 'text', 'context']) {
    final value = message[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return '';
}

String? _untrustedPayload(String text) {
  final trimmed = text.trim();
  final open = RegExp(
    r'^<untrusted_tool_result\b[^>]*>\s*',
  ).firstMatch(trimmed);
  if (open == null) return null;
  final end = trimmed.lastIndexOf('</untrusted_tool_result>');
  if (end <= open.end) return null;
  final wrapped = trimmed.substring(open.end, end).trim();
  final payload = wrapped.indexOf(RegExp(r'\r?\n\r?\n'));
  return (payload < 0 ? wrapped : wrapped.substring(payload).trim());
}

String _normalizeTarget(String value) {
  final normalized = value.trim().replaceFirst(RegExp(r'[),.;]+$'), '');
  if (!normalized.toLowerCase().startsWith('file:')) return normalized;
  final uri = Uri.tryParse(normalized);
  if (uri == null || uri.scheme.toLowerCase() != 'file') return normalized;
  var path = uri.path;
  try {
    path = Uri.decodeComponent(path);
  } on ArgumentError {
    // Keep the gateway path literal when its percent encoding is malformed.
  }
  if (uri.host.isNotEmpty) path = '//${uri.host}$path';
  if (RegExp(r'^/[A-Za-z]:/').hasMatch(path)) path = path.substring(1);
  return path;
}

bool _isFilePath(String value) => RegExp(
  r'^(?:file:|/|[~.][\\/]|\.\.[\\/]|[a-z]:[\\/]|\\\\)',
  caseSensitive: false,
).hasMatch(value);

bool _isUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

bool _hasUnsupportedScheme(String value) {
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return false;
  return RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(value);
}

bool _looksLikeOutput(String value, {required bool explicit}) =>
    _isUrl(value) ||
    value.startsWith('data:image/') ||
    (_isFilePath(value) || explicit) && _fileExtension.hasMatch(value);

String _label(String target) {
  if (target.startsWith('data:image/')) return 'Embedded image';
  var value = target;
  final uri = Uri.tryParse(target);
  if (uri != null && uri.hasScheme && uri.pathSegments.isNotEmpty) {
    value = uri.pathSegments.last;
  } else {
    value =
        target
            .split(RegExp(r'[\\/]'))
            .where((part) => part.isNotEmpty)
            .lastOrNull ??
        target;
  }
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return value;
  }
}
