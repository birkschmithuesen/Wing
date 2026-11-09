import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import '../models/deliverable_reference.dart';
import 'performance_instrumentation.dart';

/// Reuses unchanged inline expansions while parsing every snapshot's blocks.
///
/// The parser owns only the known Wing grammar. Construct a new instance when
/// its configuration changes; arbitrary caller-provided syntaxes and resolvers
/// are not part of this cache's contract.
class MarkdownInlineParser {
  MarkdownInlineParser({
    required this.deliverables,
    this.cacheEnabled = true,
    this.guardCode = true,
  });

  final bool deliverables;
  final bool cacheEnabled;
  final bool guardCode;

  Map<(String, String), List<md.Node>> _cache = {};
  int _inlineParses = 0;
  int _cacheHits = 0;
  int _lastParseMicros = 0;

  /// Inline expansions performed during the most recent [parse].
  int get inlineParses => _inlineParses;

  /// Inline expansions reused during the most recent [parse].
  int get cacheHits => _cacheHits;

  /// Total block parsing, inline expansion and copying time for the last parse.
  int get lastParseMicros => _lastParseMicros;

  List<md.Node> parse(String source) {
    if (PerformanceInstrumentation.enabled) {
      _inlineParses = 0;
      _cacheHits = 0;
    }
    final clock = PerformanceInstrumentation.enabled
        ? (Stopwatch()..start())
        : null;
    final document = _CachingDocument(this);
    try {
      final nodes = document.parse(source);
      // Retain only expansions used by this snapshot, including on truncation,
      // replacement, or reference-context changes.
      _cache = document.used;
      return nodes;
    } finally {
      if (PerformanceInstrumentation.enabled) {
        clock!.stop();
        _lastParseMicros = clock.elapsedMicroseconds;
      }
    }
  }

  void clear() {
    _cache.clear();
    if (PerformanceInstrumentation.enabled) {
      _inlineParses = 0;
      _cacheHits = 0;
      _lastParseMicros = 0;
    }
  }
}

class _CachingDocument extends md.Document {
  _CachingDocument(this.owner)
    : super(
        inlineSyntaxes: owner.deliverables
            ? [
                MediaReferenceSyntax(),
                DeliverableLinkSyntax(),
                LiteralCodeSyntax(guard: owner.guardCode),
                HtmlFilePathSyntax(),
              ]
            : null,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      );

  final MarkdownInlineParser owner;
  final Map<(String, String), List<md.Node>> used = {};
  String? _references;

  @override
  List<md.Node> parseInline(String text) {
    // Footnote links mutate per-document counts and appearance order. Stock
    // markdown's four footnote reference forms all contain this opening token.
    // Even unresolved or escaped candidates are deliberately parsed afresh.
    if (!owner.cacheEnabled || text.contains('[^')) {
      if (PerformanceInstrumentation.enabled) owner._inlineParses++;
      return super.parseInline(text);
    }
    // Document calls parseInline only after the complete block pass, when all
    // reference definitions (including forward definitions) have resolved.
    final key = (text, _references ??= _referenceContext());
    final cached = used[key] ?? owner._cache[key];
    if (cached != null) {
      if (PerformanceInstrumentation.enabled) owner._cacheHits++;
      used[key] = cached;
      return copyMarkdownNodes(cached);
    }
    if (PerformanceInstrumentation.enabled) owner._inlineParses++;
    final nodes = super.parseInline(text);
    // Renderers mutate attributes and children, so neither side of the cache
    // boundary may share mutable nodes with a returned document.
    used[key] = copyMarkdownNodes(nodes);
    return nodes;
  }

  String _referenceContext() {
    final labels = linkReferences.keys.toList()..sort();
    return jsonEncode([
      for (final label in labels)
        [
          label,
          linkReferences[label]!.label,
          linkReferences[label]!.destination,
          linkReferences[label]!.title,
        ],
    ]);
  }
}

/// Resolved snapshots may be handed to another mounted renderer. Markdown
/// builders can mutate nodes, so a handoff must not share their mutable AST.
List<md.Node> copyMarkdownNodes(List<md.Node> nodes) =>
    nodes.map(_copyNode).toList();

md.Node _copyNode(md.Node node) {
  if (node is md.Text) return md.Text(node.text);
  final element = node as md.Element;
  return md.Element(
      element.tag,
      element.children == null ? null : copyMarkdownNodes(element.children!),
    )
    ..attributes.addAll(element.attributes)
    ..generatedId = element.generatedId
    ..footnoteLabel = element.footnoteLabel;
}
