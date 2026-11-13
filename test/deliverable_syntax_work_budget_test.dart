import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:wing/core/models/deliverable_reference.dart';
import 'package:wing/core/models/media_reference.dart';

// Observe the real production syntax's underlying regex, rather than counting
// tryMatch calls: a cheap rejection can keep the call while avoiding the regex.
// This test-only spy avoids adding instrumentation to the production matcher.
// ignore: deprecated_implement
class _RegexProbe implements RegExp {
  _RegexProbe(this.delegate);
  final RegExp delegate;
  var prefixCalls = 0;

  @override
  Match? matchAsPrefix(String input, [int start = 0]) {
    prefixCalls++;
    return delegate.matchAsPrefix(input, start);
  }

  @override
  RegExpMatch? firstMatch(String input) => delegate.firstMatch(input);
  @override
  Iterable<RegExpMatch> allMatches(String input, [int start = 0]) =>
      delegate.allMatches(input, start);
  @override
  bool hasMatch(String input) => delegate.hasMatch(input);
  @override
  String? stringMatch(String input) => delegate.stringMatch(input);
  @override
  String get pattern => delegate.pattern;
  @override
  bool get isCaseSensitive => delegate.isCaseSensitive;
  @override
  bool get isMultiLine => delegate.isMultiLine;
  @override
  bool get isUnicode => delegate.isUnicode;
  @override
  bool get isDotAll => delegate.isDotAll;
}

class _ObservedMedia extends MediaReferenceSyntax {
  late final probe = _RegexProbe(super.pattern);
  @override
  RegExp get pattern => probe;
}

class _ObservedHtml extends HtmlFilePathSyntax {
  late final probe = _RegexProbe(super.pattern);
  @override
  RegExp get pattern => probe;
}

class _ObservedCode extends LiteralCodeSyntax {
  late final probe = _RegexProbe(super.pattern);
  @override
  RegExp get pattern => probe;
}

// Preserve the original unguarded matcher as the differential oracle, while
// retaining the production conversion grammar and onMatch behavior.
class _UnguardedMedia extends md.InlineSyntax {
  _UnguardedMedia() : super(mediaReferencePattern, caseSensitive: false);
  final syntax = MediaReferenceSyntax();
  @override
  bool onMatch(md.InlineParser parser, Match match) =>
      syntax.onMatch(parser, match);
}

class _UnguardedHtml extends md.InlineSyntax {
  _UnguardedHtml()
    : super(HtmlFilePathSyntax().pattern.pattern, caseSensitive: false);
  final syntax = HtmlFilePathSyntax();
  @override
  bool onMatch(md.InlineParser parser, Match match) =>
      syntax.onMatch(parser, match);
}

md.Document _document(md.InlineSyntax media, md.InlineSyntax html) =>
    md.Document(
      inlineSyntaxes: [
        media,
        DeliverableLinkSyntax(),
        LiteralCodeSyntax(),
        html,
      ],
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );

Object _ast(md.Node node) {
  if (node is md.Text) return ['text', node.text];
  final element = node as md.Element;
  return [
    element.tag,
    element.attributes,
    element.generatedId,
    element.footnoteLabel,
    element.children?.map(_ast).toList(),
  ];
}

void main() {
  test(
    'inline code avoids regex probes where a backtick cannot start code',
    () {
      final code = _ObservedCode();
      final source = 'ordinary words field_id_1 and value_2 ' * 100;
      final actual = md.Document(
        inlineSyntaxes: [code],
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      ).parse(source).map(_ast).toList();
      final reference = md.Document(
        inlineSyntaxes: [md.CodeSyntax()],
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      ).parse(source).map(_ast).toList();
      expect(actual, reference);
      expect(code.probe.prefixCalls, 0);
    },
  );

  for (final fixture in {
    'ordinary words': 'Ordinary prose flows through words and sentences ',
    'technical identifiers': 'value_1 = field_id_2 + other_value_3; ',
  }.entries) {
    test('${fixture.key} avoid impossible deliverable regex probes', () {
      final media = _ObservedMedia();
      final html = _ObservedHtml();
      final source = fixture.value * 100;
      final actual = _document(media, html).parse(source).map(_ast).toList();
      final reference = _document(
        _UnguardedMedia(),
        _UnguardedHtml(),
      ).parse(source).map(_ast).toList();
      expect(actual, reference);
      debugPrint(
        '${fixture.key}: ${media.probe.prefixCalls} MEDIA regex probes, '
        '${html.probe.prefixCalls} HTML-path regex probes',
      );
      // The fixtures contain none of either syntax's possible start characters.
      // Current production reaches its regex at every parser candidate instead.
      expect(
        media.probe.prefixCalls,
        0,
        reason:
            'MEDIA regex must not scan words/identifiers that cannot start MEDIA markup.',
      );
      expect(
        html.probe.prefixCalls,
        0,
        reason:
            'HTML-path regex must not scan words/identifiers without a path prefix.',
      );
    });
  }

  test(
    'complete MEDIA and HTML paths produce exact deliverable attributes',
    () {
      for (final fixture in {
        'MEDIA:/srv/report.md': '/srv/report.md',
        '"media:/srv/report.md"': '/srv/report.md',
        '/srv/report.html': '/srv/report.html',
        './report.htm': './report.htm',
      }.entries) {
        final paragraph =
            _document(
                  MediaReferenceSyntax(),
                  HtmlFilePathSyntax(),
                ).parse(fixture.key).single
                as md.Element;
        final file = paragraph.children!.single as md.Element;
        expect(file.tag, deliverableElementTag);
        expect(file.attributes, {
          'path': fixture.value,
          'name': fixture.value.split('/').last,
          'fragment': '',
          'kind': 'file',
        });
        expect(file.children, isNull);
      }
    },
  );

  const positives = [
    'MEDIA:/srv/report.md',
    'media:/srv/report.md',
    'MeDiA:/srv/report.md',
    '"MEDIA:/srv/report.md"',
    "'MEDIA:/srv/report.md'",
    '`MEDIA:/srv/report.md`',
    'MEDIA:"/srv/a report.html"',
    'MEDIA:`/srv/a report.md`',
    'MEDIA:/srv/a report.md',
    '/srv/report.html',
    '~/report.htm',
    './report.html',
    '../report.html',
    r'.\report.htm',
    r'..\report.html',
    r'C:\reports\report.html',
    'c:/reports/report.htm',
    r'\\server\report.html',
  ];
  const boundaries = [
    '',
    'ordinary words ',
    'value_id_1 ',
    '(',
    '*',
    '"',
    "'",
    '\n',
    'x',
    '_',
    '`',
    'é',
    '漢',
    '“',
    '😀',
    '\u212A',
    '\u017F',
  ];
  test(
    'guarded syntax matches unguarded AST at all positive boundaries and prefixes',
    () {
      for (final positive in positives) {
        for (final boundary in boundaries) {
          // Include every unfinished streamed prefix, not only complete markup.
          for (var length = 0; length <= positive.length; length++) {
            final source = '$boundary${positive.substring(0, length)}';
            expect(
              _document(
                MediaReferenceSyntax(),
                HtmlFilePathSyntax(),
              ).parse(source).map(_ast).toList(),
              _document(
                _UnguardedMedia(),
                _UnguardedHtml(),
              ).parse(source).map(_ast).toList(),
              reason: 'Boundary=$boundary, positive=$positive, length=$length',
            );
          }
        }
      }
    },
  );

  test(
    'reference links, footnotes and mixed blocks keep the full resolved AST',
    () {
      for (final source in [
        'Read [report][r].\n\n[r]: /srv/report.html',
        'Text[^note] and MEDIA:/srv/report.md\n\n[^note]: Refer to /srv/report.html',
        '| File | State |\n| --- | --- |\n| /srv/report.html | **ready** |',
        '> "MEDIA:/srv/report.md"\n\n- ./report.htm\n- `literal_value_1`',
        '\u212A:/report.html \u017F:/report.html \u0131:/report.html',
        '“MEDIA:/srv/report.md” 😀MEDIA:/srv/report.md',
        '😀/srv/report.html 😀C:/report.html\n\n漢./report.htm',
        '\uD800MEDIA:/srv/report.md \uDC00/srv/report.html',
      ]) {
        expect(
          _document(
            MediaReferenceSyntax(),
            HtmlFilePathSyntax(),
          ).parse(source).map(_ast).toList(),
          _document(
            _UnguardedMedia(),
            _UnguardedHtml(),
          ).parse(source).map(_ast).toList(),
        );
      }
    },
  );

  for (final syntax in [MediaReferenceSyntax(), HtmlFilePathSyntax()]) {
    test(
      '${syntax.runtimeType} honors explicit match positions and empty input',
      () {
        final source = syntax is MediaReferenceSyntax
            ? 'x MEDIA:/srv/report.md'
            : 'x /srv/report.html';
        final parser = md.InlineParser(source, md.Document());
        expect(syntax.tryMatch(parser, 2), isTrue);
        expect(syntax.tryMatch(md.InlineParser('', md.Document())), isFalse);
        expect(
          syntax.tryMatch(md.InlineParser('x', md.Document()), 1),
          isFalse,
        );
      },
    );
  }
}
