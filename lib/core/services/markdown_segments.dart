import 'package:markdown/markdown.dart' as md;

import 'markdown_inline_parser.dart';

/// Data prepared off the UI isolate. No segment contains a Flutter widget.
sealed class MarkdownSegment {
  const MarkdownSegment();
}

final class MarkdownProseSegment extends MarkdownSegment {
  const MarkdownProseSegment({required this.source, this.nodes = const []});

  final String source;

  /// Unparsed scans leave this empty. Worker results contain resolved nodes.
  /// Renderers may mutate those nodes, so mounted owners must copy a handoff.
  final List<md.Node> nodes;
}

final class MarkdownFenceSegment extends MarkdownSegment {
  const MarkdownFenceSegment({
    required this.code,
    this.language,
    required this.closed,
  });

  final String code;
  final String? language;
  final bool closed;
}

/// Preserves Wing's existing fence grammar, including unfinished fences.
/// Preview eligibility is derived by the UI from [MarkdownFenceSegment.closed]
/// and the current streaming state, rather than belonging to preparation.
List<MarkdownSegment> splitMarkdownSegments(String content) {
  final result = <MarkdownSegment>[];
  final opening = RegExp(
    r'^ {0,3}(`{3,}|~{3,})([^\r\n]*)\r?$',
    multiLine: true,
  );
  var cursor = 0;
  while (cursor < content.length) {
    final match = opening.firstMatch(content.substring(cursor));
    if (match == null) break;
    final start = cursor + match.start;
    final fence = match.group(1)!;
    final info = match.group(2)!.trim();
    final bodyStart = cursor + match.end;
    final closing = RegExp(
      '^ {0,3}${RegExp.escape(fence[0])}{${fence.length},}[ \\t]*\\r?\$',
      multiLine: true,
    ).firstMatch(content.substring(bodyStart));
    final bodyEnd = closing == null
        ? content.length
        : bodyStart + closing.start;
    final codeStart = bodyStart < content.length && content[bodyStart] == '\n'
        ? bodyStart + 1
        : bodyStart;
    if (start > cursor) {
      result.add(
        MarkdownProseSegment(source: content.substring(cursor, start)),
      );
    }
    result.add(
      MarkdownFenceSegment(
        code: content.substring(codeStart, bodyEnd),
        language: info.isEmpty ? null : info.split(RegExp(r'\s+')).first,
        closed: closing != null,
      ),
    );
    cursor = closing == null ? content.length : bodyStart + closing.end;
  }
  if (cursor < content.length) {
    result.add(MarkdownProseSegment(source: content.substring(cursor)));
  }
  return result;
}

/// ASTs cannot be shared between mounted renderers: Markdown builders mutate
/// element children and attributes. Fence fields contain immutable values.
List<MarkdownSegment> copyMarkdownSegments(List<MarkdownSegment> segments) => [
  for (final segment in segments)
    switch (segment) {
      MarkdownProseSegment() => MarkdownProseSegment(
        source: segment.source,
        nodes: copyMarkdownNodes(segment.nodes),
      ),
      MarkdownFenceSegment() => segment,
    },
];
