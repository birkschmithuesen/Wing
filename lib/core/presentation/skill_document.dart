import '../models/skill_reader.dart';
import 'package:yaml/yaml.dart';
import 'package:markdown/markdown.dart' as md;

/// A received skill document, distinct from an executable or editable skill.
final class SkillDocument {
  SkillDocument._({
    required this.name,
    required this.rawContent,
    required this.formattedContent,
    this.sourcePath,
    required this.description,
    this.category,
    required Iterable<String> tags,
    required Iterable<({String label, String value})> metadata,
  }) : tags = List.unmodifiable(tags),
       metadata = List.unmodifiable(metadata);

  final String name;
  final String rawContent, formattedContent;
  final String? sourcePath;
  final String? description;
  final String? category;
  String get formattedText => _readableText(formattedContent);
  SkillReaderTarget get readerTarget =>
      SkillReaderTarget(name: name, sourcePath: sourcePath);
  final List<String> tags;
  final List<({String label, String value})> metadata;

  factory SkillDocument.fromReceived({
    required String name,
    required String content,
    String? description,
    Iterable<String>? tags,
    Map? metadata,
    String? sourcePath,
    String? category,
  }) {
    Map declaration = const {};
    final documentContent = _withoutPluginEnvelope(name, content);
    final frontMatter = RegExp(
      r'^---\r?\n(.*?)\r?\n---(?:\r?\n|$)',
      dotAll: true,
    ).firstMatch(documentContent);
    if (frontMatter != null) {
      try {
        final parsed = loadYaml(frontMatter.group(1)!);
        if (parsed is Map) declaration = parsed;
      } on YamlException {
        // Exact raw viewing/copying retains malformed declarations.
      }
    }
    final declaredMetadata =
        metadata ??
        (declaration['metadata'] is Map
            ? declaration['metadata'] as Map
            : const {});
    final hermes = declaredMetadata['hermes'] is Map
        ? declaredMetadata['hermes'] as Map
        : const {};
    final hermesTags = _declaredTags(hermes['tags']);
    final declaredTags = hermesTags.isNotEmpty
        ? hermesTags
        : _declaredTags(declaration['tags']);
    return SkillDocument._(
      name: name,
      rawContent: content,
      formattedContent: frontMatter == null
          ? documentContent
          : documentContent.substring(frontMatter.end),
      sourcePath: sourcePath,
      description:
          _nonempty(description) ?? _nonempty(declaration['description']),
      category: category,
      tags: tags ?? declaredTags,
      metadata: [
        for (final key in ['version', 'author'])
          if (declaredMetadata[key] ?? declaration[key] case final value?
              when value is String && value.trim().isNotEmpty || value is num)
            (
              label: '${key[0].toUpperCase()}${key.substring(1)}',
              value: value.toString(),
            ),
      ],
    );
  }
}

/// Stock skill_view prepends this envelope to namespaced plugin instructions.
/// Recognize the producer's structure and namespace; rawContent stays exact.
String _withoutPluginEnvelope(String name, String content) {
  final separator = name.indexOf(':');
  if (separator <= 0) return content;
  final header =
      "[Bundle context: This skill is part of the '${name.substring(0, separator)}' plugin.";
  final envelope = RegExp(
    '^${RegExp.escape(header)}'
    r'(?:\r?\nSibling skills: [^\r\n]+\.\r?\nUse qualified form to invoke siblings \(e\.g\. [^\r\n]+\)\.)?\]\r?\n\r?\n',
  ).firstMatch(content);
  return envelope == null ? content : content.substring(envelope.end);
}

String _readableText(String source) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(source.split('\n'));
  String read(md.Node node) {
    if (node is md.Text) return node.text;
    final element = node as md.Element;
    if (element.tag == 'img') return element.attributes['alt'] ?? '';
    if (element.tag == 'br') return '\n';
    final text = (element.children ?? const <md.Node>[]).map(read).join();
    return switch (element.tag) {
      'li' => '• $text\n',
      'p' ||
      'h1' ||
      'h2' ||
      'h3' ||
      'h4' ||
      'h5' ||
      'h6' ||
      'pre' ||
      'tr' => '$text\n\n',
      'td' || 'th' => '$text\t',
      _ => text,
    };
  }

  return nodes.map(read).join().trim();
}

String? _nonempty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

/// Stock declarations accept lists, comma-separated text and bracketed text.
List<String> _declaredTags(Object? value) {
  if (value is List) {
    return value
        .whereType<String>()
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
  }
  if (value is! String) return const [];
  var text = value.trim();
  if (text.startsWith('[') && text.endsWith(']')) {
    text = text.substring(1, text.length - 1);
  }
  return text
      .split(',')
      .map((tag) => tag.trim().replaceAll(RegExp(r"""^["']+|["']+$"""), ''))
      .where((tag) => tag.isNotEmpty)
      .toList();
}
