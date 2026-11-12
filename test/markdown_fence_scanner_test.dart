import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:wing/core/services/markdown_segments.dart';

Object _value(MarkdownSegment segment) => switch (segment) {
  MarkdownProseSegment() => ['prose', segment.source],
  MarkdownFenceSegment() => [
    'fence',
    segment.code,
    segment.language,
    segment.closed,
  ],
};

void main() {
  // These readable expectations were verified against all four pre-existing
  // every-prefix digests before conversion; they retain the same grammar oracle.
  final fixtures =
      jsonDecode(
            File(
              'test/fixtures/markdown_fence_prefixes.json',
            ).readAsStringSync(),
          )
          as List;
  const grammarFamilies = {
    'language and surrounding prose',
    'indented tilde fence and CRLF',
    'shorter nested fence',
    'inline and deeply indented delimiters with unfinished fence',
  };
  final names = fixtures.map((fixture) => fixture['name']).toSet();
  if (fixtures.length != grammarFamilies.length ||
      !names.containsAll(grammarFamilies)) {
    throw const FormatException(
      'Prefix fixture must include every grammar family',
    );
  }
  for (final fixture in fixtures.cast<Map<String, dynamic>>()) {
    final source = fixture['source'] as String;
    final prefixes = fixture['prefixes'] as Map<String, dynamic>;
    test(
      '${fixture['name']}: every streaming prefix retains exact segments',
      () {
        for (var end = 0; end <= source.length; end++) {
          final prefix = source.substring(0, end);
          expect(prefixes, contains(prefix), reason: 'Missing prefix oracle');
          expect(
            splitMarkdownSegments(prefix).map(_value).toList(),
            prefixes[prefix],
            reason:
                'Source: ${jsonEncode(source)}; prefix: ${jsonEncode(prefix)}',
          );
        }
      },
    );
  }

  for (final entry in <String, (String, List<Object>)>{
    'inline delimiter': (
      'inline ``` stays prose',
      [
        ['prose', 'inline ``` stays prose'],
      ],
    ),
    'unfinished fence': (
      '~~~sh\necho hello',
      [
        ['fence', 'echo hello', 'sh', false],
      ],
    ),
  }.entries) {
    test('preserves exact ${entry.key} segments', () {
      expect(splitMarkdownSegments(entry.value.$1).map(_value), entry.value.$2);
    });
  }

  test(
    'copied preparation keeps metadata without sharing mutable AST nodes',
    () {
      final text = md.Text('original');
      final element = md.Element('p', [text])
        ..attributes['id'] = 'anchor'
        ..generatedId = 'generated'
        ..footnoteLabel = 'note';
      const fence = MarkdownFenceSegment(
        code: 'value\n',
        language: 'dart',
        closed: true,
      );
      final copied = copyMarkdownSegments([
        MarkdownProseSegment(source: 'original', nodes: [element]),
        fence,
      ]);
      final copiedElement =
          (copied.first as MarkdownProseSegment).nodes.single as md.Element;
      expect(copiedElement.attributes, {'id': 'anchor'});
      expect(copiedElement.generatedId, 'generated');
      expect(copiedElement.footnoteLabel, 'note');
      expect(copiedElement, isNot(same(element)));
      expect(copiedElement.children!.single, isNot(same(text)));
      expect(copied.last, same(fence));
      copiedElement.attributes.clear();
      copiedElement.children!.clear();
      expect(element.attributes, {'id': 'anchor'});
      expect(element.textContent, 'original');
    },
  );
}
