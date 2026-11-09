import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/deliverable_reference.dart';
import 'package:wing/core/services/markdown_inline_parser.dart';
import 'package:wing/core/services/performance_instrumentation.dart';
import 'package:markdown/markdown.dart' as md;

List<Object> _ast(List<md.Node> nodes) => nodes.map(_nodeValue).toList();

Object _nodeValue(md.Node node) {
  if (node is md.Text) return ['text', node.text];
  final element = node as md.Element;
  return [
    element.tag,
    Map<String, String>.of(element.attributes),
    element.generatedId,
    element.footnoteLabel,
    element.children == null ? null : _ast(element.children!),
  ];
}

List<md.Node> _stock(
  String source, {
  bool deliverables = true,
  bool guardCode = true,
}) => md.Document(
  inlineSyntaxes: deliverables
      ? [
          MediaReferenceSyntax(),
          DeliverableLinkSyntax(),
          LiteralCodeSyntax(guard: guardCode),
          HtmlFilePathSyntax(),
        ]
      : null,
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
).parse(source);

void _mutate(List<md.Node> nodes) {
  for (final node in nodes) {
    if (node is! md.Element) continue;
    node.attributes.clear();
    node.attributes['changed'] = 'renderer mutation';
    node.generatedId = 'changed';
    node.footnoteLabel = 'changed';
    final children = node.children;
    if (children != null) {
      _mutate(children);
      children.clear();
    }
  }
}

void main() {
  test('cached and fresh parsing keep file-shaped code literal', () {
    final parser = MarkdownInlineParser(deliverables: true);
    for (final path in [
      '/hermes-button-actions/contents/README.md',
      '/api/files/report.md',
      '/srv/report.md',
    ]) {
      final source = '`$path`';
      final expected = md.Document(encodeHtml: false).parse(source);
      expect(_ast(parser.parse(source)), _ast(expected));
      expect(_ast(parser.parse(source)), _ast(expected));
    }
  });

  test('measurement switch leaves output unchanged and gates every metric', () {
    final parser = MarkdownInlineParser(deliverables: false);
    const source =
        'First **paragraph**.\n\nSecond [link](https://example.test).';
    for (var repetition = 0; repetition < 2; repetition++) {
      expect(
        _ast(parser.parse(source)),
        _ast(_stock(source, deliverables: false)),
      );
      expect(
        parser.inlineParses,
        PerformanceInstrumentation.enabled && repetition == 0 ? 2 : 0,
      );
      expect(
        parser.cacheHits,
        PerformanceInstrumentation.enabled && repetition == 1 ? 2 : 0,
      );
      expect(
        parser.lastParseMicros,
        PerformanceInstrumentation.enabled ? greaterThanOrEqualTo(0) : 0,
      );
    }
  });

  test(
    'reference definitions invalidate cached expansions before inline parse',
    () {
      final parser = MarkdownInlineParser(deliverables: true);
      const paragraph = 'Read [forward][ref], [ref] and ![image][ref].';
      for (final definitions in [
        '',
        '[ref]: https://example.com/one "one"',
        '[ref]: https://example.com/two "two"',
        '[ref]: /tmp/final.html "file"',
        '[ref]: /tmp/final.html "new title"',
        '',
      ]) {
        final source = '$paragraph\n\n$definitions';
        expect(_ast(parser.parse(source)), _ast(_stock(source)));
        expect(parser.cacheHits, 0);
        expect(parser.inlineParses, PerformanceInstrumentation.enabled ? 1 : 0);
      }
    },
  );

  test('footnote counts, appearance order and backrefs remain fresh', () {
    final parser = MarkdownInlineParser(deliverables: true);
    const definitions =
        '[^B]: Second note **bold**.\n'
        '[^a]: First note with [site](https://example.com).';
    for (final prose in [
      '[^a] then [^B], [^a].',
      '[^B] then [^a], [^B], [^B].',
      '![^a] [label][^B] ![image][^a] [^B][].',
      '[^a] then [^B], [^a].',
      'Ordinary prose with no note reference.',
    ]) {
      final source = '$prose\n\n$definitions';
      expect(_ast(parser.parse(source)), _ast(_stock(source)));
      expect(_ast(parser.parse(source)), _ast(_stock(source)));
    }
  });

  test('returned AST mutations never enter stored or reused expansions', () {
    const source =
        '# Heading **bold**\n\n'
        'Nested **bold [link](https://example.com "title")** '
        '![image](https://example.com/image.png) [file](/tmp/report.html).\n\n'
        'Footnote [^note].\n\n[^note]: Note **bold**.';
    final parser = MarkdownInlineParser(deliverables: true);
    final expected = _ast(_stock(source));
    final first = parser.parse(source);
    _mutate(first);
    final second = parser.parse(source);
    expect(_ast(second), expected);
    expect(
      parser.cacheHits,
      PerformanceInstrumentation.enabled ? greaterThan(0) : 0,
    );
    _mutate(second);
    final third = parser.parse(source);
    expect(_ast(third), expected);
    expect(identical(second, third), isFalse);
  });

  test('replacement, truncation and clear discard obsolete cached content', () {
    final parser = MarkdownInlineParser(deliverables: false);
    parser.parse('First **paragraph**.\n\nSecond [link](https://example.com).');
    const truncated = 'First **paragraph**.';
    expect(
      _ast(parser.parse(truncated)),
      _ast(_stock(truncated, deliverables: false)),
    );
    expect(parser.cacheHits, PerformanceInstrumentation.enabled ? 1 : 0);
    const removed = 'Second [link](https://example.com).';
    parser.parse(removed);
    expect(parser.cacheHits, 0);
    expect(parser.inlineParses, PerformanceInstrumentation.enabled ? 1 : 0);
    parser.parse(removed);
    expect(parser.cacheHits, PerformanceInstrumentation.enabled ? 1 : 0);
    parser.parse('');
    parser.parse(removed);
    expect(parser.cacheHits, 0);
    parser.clear();
    expect(parser.inlineParses, 0);
    expect(parser.cacheHits, 0);
    expect(parser.lastParseMicros, 0);
    parser.parse(removed);
    expect(parser.cacheHits, 0);
    expect(parser.inlineParses, PerformanceInstrumentation.enabled ? 1 : 0);
  });

  test('unchanged paragraphs with ordinary links avoid inline reparsing', () {
    final paragraphs = List.generate(
      80,
      (index) =>
          'Paragraph $index with **bold** and '
          '[ordinary](https://example.com/$index "title") and ![icon](icon.png).',
    ).join('\n\n');
    final cached = MarkdownInlineParser(deliverables: true);
    final uncached = MarkdownInlineParser(
      deliverables: true,
      cacheEnabled: false,
    );
    cached.parse('$paragraphs\n\nStreaming tail');
    final source = '$paragraphs\n\nStreaming tail grows';
    expect(_ast(cached.parse(source)), _ast(uncached.parse(source)));
    expect(cached.inlineParses, PerformanceInstrumentation.enabled ? 1 : 0);
    expect(cached.cacheHits, PerformanceInstrumentation.enabled ? 80 : 0);
    expect(uncached.inlineParses, PerformanceInstrumentation.enabled ? 81 : 0);
    expect(uncached.cacheHits, 0);
  });

  test('every streaming prefix preserves the complete stock Markdown AST', () {
    const source = '''# Résumé 🦋

Ordinary **bold** and [site](https://example.com "title").

Report [open](/tmp/report.html), `/tmp/chart.png`, MEDIA:/tmp/chart.png.

Read [late][report] and [^first], [^second], [^first].

Heading becomes setext
----------------------

| Label | Result |
| :--- | ---: |
| α | **β** |

- outer [site](https://example.com)
  - nested ~~text~~ and ![image](https://example.com/a.png)

```markdown
[^ignored] /tmp/not-deliverable.html
```

[report]: /tmp/final.html "final report"
[^second]: Footnote **two**.
[^first]: Footnote one with [site](https://example.com).
''';
    for (final (deliverables, guardCode) in [
      (false, true),
      (true, true),
      (true, false),
    ]) {
      for (final cacheEnabled in [false, true]) {
        final parser = MarkdownInlineParser(
          deliverables: deliverables,
          guardCode: guardCode,
          cacheEnabled: cacheEnabled,
        );
        for (var end = 0; end <= source.length; end++) {
          final snapshot = source.substring(0, end);
          expect(
            _ast(parser.parse(snapshot)),
            _ast(
              _stock(
                snapshot,
                deliverables: deliverables,
                guardCode: guardCode,
              ),
            ),
            reason:
                'deliverables=$deliverables, guard=$guardCode, '
                'cache=$cacheEnabled, prefix=$end',
          );
        }
      }
    }
  });
}
