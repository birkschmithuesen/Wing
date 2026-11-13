import 'package:markdown/markdown.dart' as md;

import 'chat_output.dart';
import 'media_reference.dart';

const deliverableElementTag = 'wing-deliverable';

md.Element _fileElement(ChatOutput output) =>
    md.Element.empty(deliverableElementTag)
      ..attributes['path'] = output.path!
      ..attributes['name'] = output.label
      ..attributes['fragment'] = output.fragment ?? ''
      ..attributes['kind'] = output.kind.name;

/// Uses the Markdown parser for links, so labels, escaped destinations,
/// reference links, and surrounding prose keep normal Markdown semantics.
class DeliverableLinkSyntax extends md.LinkSyntax {
  @override
  md.Node createNode(
    String destination,
    String? title, {
    required List<md.Node> Function() getChildren,
  }) {
    final output = explicitRemoteFileOutput(destination);
    if (output == null) {
      return super.createNode(destination, title, getChildren: getChildren);
    }
    getChildren();
    return _fileElement(output);
  }
}

/// Literal code is never evidence of a file: API paths have the same shape.
/// Keep the cheap matching guard while leaving content to Markdown CodeSyntax.
class LiteralCodeSyntax extends md.CodeSyntax {
  LiteralCodeSyntax({this.guard = true});

  // QA compares this fast rejection with the unchanged matcher explicitly.
  final bool guard;

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final position = parser.pos;
    if (guard && position >= 0 && position <= parser.source.length) {
      if (position == parser.source.length ||
          parser.source.codeUnitAt(position) != 0x60) {
        return false;
      }
    }
    // CodeSyntax owns delimiter-run handling and uses parser.pos, including
    // when a caller supplies startMatchPos. Preserve that behavior exactly.
    return super.tryMatch(parser, startMatchPos);
  }
}

/// HTML reports are often returned as plain paths rather than Markdown links.
/// Require a path prefix and token boundaries so URLs and filename mentions
/// keep their Markdown meaning. Code spans and fences own their own contents.
class HtmlFilePathSyntax extends md.InlineSyntax {
  HtmlFilePathSyntax()
    : super(
        r'''(?<![^\s("'*])(?:/|~[\\/]|\.\.?[\\/]|[A-Za-z]:[\\/]|\\\\)'''
        r'''[^\s<>"'`*|]*\.html?(?=$|[\s<>"'`*,;:)\]}]|[.!?](?=\s|$))''',
        caseSensitive: false,
      );

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    final source = parser.source;
    if (start < 0 || start > source.length) {
      return super.tryMatch(parser, startMatchPos);
    }
    if (start == source.length) return false;
    final first = source.codeUnitAt(start);
    final drive =
        ((first >= 0x41 && first <= 0x5a) ||
            (first >= 0x61 && first <= 0x7a)) &&
        start + 1 < source.length &&
        source.codeUnitAt(start + 1) == 0x3a;
    // Only /, ~, ., \\ or a drive letter followed by : can start this grammar.
    if (first != 0x2f &&
        first != 0x7e &&
        first != 0x2e &&
        first != 0x5c &&
        !drive) {
      return false;
    }
    return super.tryMatch(parser, startMatchPos);
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final output = mediaRemoteFileOutput(match[0]!);
    parser.addNode(output == null ? md.Text(match[0]!) : _fileElement(output));
    return true;
  }
}

class MediaReferenceSyntax extends md.InlineSyntax {
  MediaReferenceSyntax() : super(mediaReferencePattern, caseSensitive: false);

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    final source = parser.source;
    if (start < 0 || start > source.length) {
      return super.tryMatch(parser, startMatchPos);
    }
    if (start == source.length) return false;
    final first = source.codeUnitAt(start);
    // MEDIA is case insensitive and may have one opening quote/backtick.
    if (first != 0x4d &&
        first != 0x6d &&
        first != 0x22 &&
        first != 0x27 &&
        first != 0x60) {
      return false;
    }
    return super.tryMatch(parser, startMatchPos);
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final target = mediaReferenceTarget(match.group(1)!);
    final output = mediaRemoteFileOutput(target);
    if (output == null) {
      parser.addNode(md.Text(match.group(0)!));
      return true;
    }
    parser.addNode(_fileElement(output));
    return true;
  }
}
