import 'package:characters/characters.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

typedef SourceToken = ({String text, String? scope});

/// Immutable, isolate-safe input. No UI styles or backend bags cross this seam.
final class SourceHighlightRequest {
  const SourceHighlightRequest(this.text, this.language, this.numberedLines);
  final String text;
  final String? language;
  final bool numberedLines;
}

final _highlight = Highlight()..registerLanguages(builtinAllLanguages);

/// Admit identified source; viewport rendering bounds UI work independently
/// of document length. Unlabelled prose never guesses a grammar.
bool sourceHighlightEligible(SourceHighlightRequest request) =>
    request.text.isNotEmpty &&
    (request.language != null || request.numberedLines);

/// Worker preparation also indexes scopes, so scrolling never scans the tokens.
SourceDocument prepareSourceDocument(SourceHighlightRequest request) =>
    SourceDocument(request.text, highlightSource(request));

final _linePrefix = RegExp(r'^\d+\|');

/// Tokenize a complete source snapshot, retaining multiline grammar context.
/// Unknown/unlabelled text has no guessed grammar. The renderer lays out only
/// viewport ranges; the complete document retains multiline grammar context.
List<SourceToken> highlightSource(SourceHighlightRequest request) {
  final literal = <SourceToken>[(text: request.text, scope: null)];
  // Stock /api/fs/read-text calls shell source "shell". The library's
  // "shell" grammar instead expects console prompts, so adapt that wire value.
  final suppliedLanguage = request.language?.trim().toLowerCase();
  final language = suppliedLanguage == 'shell' ? 'bash' : suppliedLanguage;
  if (!sourceHighlightEligible(request)) return literal;
  final lines = request.text.split('\n');
  final prefixes = <String>[];
  final undecorated = <String>[];
  if (request.numberedLines) {
    for (final line in lines) {
      final prefix = _linePrefix.firstMatch(line)?.group(0) ?? '';
      prefixes.add(prefix);
      undecorated.add(line.substring(prefix.length));
    }
  }
  final source = request.numberedLines ? undecorated.join('\n') : request.text;
  var tokens = <SourceToken>[(text: source, scope: null)];
  if (source.isNotEmpty &&
      language != null &&
      _highlight.getLanguage(language) != null) {
    final renderer = _SourceTokenRenderer();
    _highlight.highlight(code: source, language: language).render(renderer);
    // Grammar bugs must never alter selectable source bytes.
    if (renderer.tokens.map((token) => token.text).join() == source) {
      tokens = renderer.tokens;
    }
  }
  if (!request.numberedLines) return tokens;

  // Insert the original receipt decoration after parsing, so `12|` cannot
  // confuse Python indentation, Bash strings, or a multiline source grammar.
  final result = <SourceToken>[];
  var line = 0;
  void prefix() {
    if (prefixes[line].isNotEmpty) {
      result.add((text: prefixes[line], scope: 'wing-line-number'));
    }
  }

  prefix();
  for (final token in tokens) {
    final parts = token.text.split('\n');
    for (var i = 0; i < parts.length; ++i) {
      if (i > 0) {
        result.add((text: '\n', scope: token.scope));
        ++line;
        prefix();
      }
      if (parts[i].isNotEmpty) {
        result.add((text: parts[i], scope: token.scope));
      }
    }
  }
  return result;
}

final class _SourceTokenRenderer implements HighlightRenderer {
  final _tokens = <SourceToken>[];
  final _scopes = <String?>[];
  final _text = StringBuffer();
  String? _scope;

  List<SourceToken> get tokens {
    _flush();
    return _tokens;
  }

  void _flush() {
    if (_text.isEmpty) return;
    _tokens.add((text: _text.toString(), scope: _scope));
    _text.clear();
  }

  @override
  void openNode(DataNode node) =>
      _scopes.add(node.scope ?? (_scopes.isEmpty ? null : _scopes.last));

  @override
  void closeNode(DataNode node) => _scopes.removeLast();

  @override
  void addText(String text) {
    if (text.isNotEmpty) {
      final scope = _scopes.isEmpty ? null : _scopes.last;
      if (_text.isNotEmpty && scope != _scope) _flush();
      _scope = scope;
      _text.write(text);
    }
  }
}

/// Exact source offsets survive display segmentation, scrolling and selection.
typedef SourceDisplayLine = ({int start, int end});

final class SourceDocument {
  SourceDocument(this.text, List<SourceToken> sourceTokens)
    : tokens = List.unmodifiable(sourceTokens) {
    final tokenOffsets = <int>[];
    final sourceLines = <int>[];
    var offset = 0;
    for (final token in tokens) {
      tokenOffsets.add(offset);
      offset += token.text.length;
    }
    assert(offset == text.length);
    sourceLines.add(0);
    for (
      var at = text.indexOf('\n');
      at >= 0;
      at = text.indexOf('\n', at + 1)
    ) {
      sourceLines.add(at + 1);
    }
    tokenStarts = List.unmodifiable(tokenOffsets);
    lineStarts = List.unmodifiable(sourceLines);
  }

  factory SourceDocument.literal(String text) =>
      SourceDocument(text, [(text: text, scope: null)]);

  final String text;
  final List<SourceToken> tokens;
  late final List<int> tokenStarts;
  late final List<int> lineStarts;

  /// Wrapped long lines become viewport-sized segments, without inserting bytes
  /// in the source. Grapheme clusters stay together at display boundaries.
  List<SourceDisplayLine> displayLines({int? segmentLength}) {
    assert(segmentLength == null || segmentLength > 1);
    final result = <SourceDisplayLine>[];
    for (var i = 0; i < lineStarts.length; ++i) {
      var start = lineStarts[i];
      final end = i + 1 == lineStarts.length
          ? text.length
          : lineStarts[i + 1] - 1;
      while (segmentLength != null && end - start > segmentLength) {
        var next = start + segmentLength;
        final range = CharacterRange.at(text, next);
        next = range.stringBeforeLength;
        if (next == start) next = text.length - range.stringAfterLength;
        next = next.clamp(start + 1, end);
        result.add((start: start, end: next));
        start = next;
      }
      result.add((start: start, end: end));
    }
    return result;
  }

  /// Binary lookup plus just the intersecting runs, regardless of file length.
  List<SourceToken> rangeTokens(int start, int end) {
    if (start == end) return const [];
    var low = 0;
    var high = tokenStarts.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (tokenStarts[mid] <= start) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final result = <SourceToken>[];
    for (var i = low - 1; i < tokens.length && tokenStarts[i] < end; ++i) {
      final token = tokens[i];
      final from = start > tokenStarts[i] ? start - tokenStarts[i] : 0;
      final to = end < tokenStarts[i] + token.text.length
          ? end - tokenStarts[i]
          : token.text.length;
      result.add((text: token.text.substring(from, to), scope: token.scope));
    }
    return result;
  }
}
