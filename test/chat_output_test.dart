import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_output.dart';

void main() {
  test('API request suffix in inline code is not a generated file', () {
    final outputs = extractChatOutputs([
      {
        'role': 'assistant',
        'content':
            'Request ending in:\n\n'
            '`/hermes-button-actions/contents/README.md`',
      },
    ]);
    expect(outputs, isEmpty);
  });

  test('code examples are excluded while explicit deliveries remain', () {
    const target = '/hermes-button-actions/contents/README.md';
    for (final source in [
      '`$target`',
      '`` $target ``',
      '```text\n$target\n```',
      '    $target',
      '`[Read]($target)`',
    ]) {
      expect(
        extractChatOutputs([
          {'role': 'assistant', 'content': source},
        ]),
        isEmpty,
        reason: source,
      );
    }
    for (final source in [
      '[Read]($target)',
      '[Read][file]\n\n[file]: $target',
      'MEDIA:$target',
      '`MEDIA:$target`',
      'MEDIA:`$target`',
    ]) {
      expect(
        extractChatOutputs([
          {'role': 'assistant', 'content': source},
        ]).map((output) => output.path),
        [target],
        reason: source,
      );
    }
  });

  test('document links resolve relative paths and keep decoded anchors', () {
    const document = '/srv/reports/pilot/report.md';
    final cases = {
      'details.md#the-six-health-checks': '/srv/reports/pilot/details.md',
      '../evidence/data.csv': '/srv/reports/evidence/data.csv',
      './chart.png': '/srv/reports/pilot/chart.png',
      '/srv/other.md#part': '/srv/other.md',
      'file:///srv/other.md#part': '/srv/other.md',
      'my%20report%23final%25.md#part':
          '/srv/reports/pilot/my report#final%.md',
      '#the-six-health-checks': document,
    };
    for (final entry in cases.entries) {
      expect(resolveDocumentFileLink(entry.key, document)?.path, entry.value);
    }
    expect(
      resolveDocumentFileLink('details.md#six%20checks', document)?.fragment,
      'six checks',
    );
    expect(
      resolveDocumentFileLink('#part', '/srv/a%23b.md')?.path,
      '/srv/a%23b.md',
    );
    expect(
      resolveDocumentFileLink(
        r'..\details.md#part',
        r'C:\reports\pilot\report.md',
      )?.path,
      r'C:\reports\details.md',
    );
    expect(
      resolveDocumentFileLink('https://example.com/a.md#part', document),
      isNull,
    );
    expect(resolveDocumentFileLink('javascript:alert(1)', document), isNull);
  });

  test('classifies only explicit remote file link targets', () {
    for (final target in [
      'report.pdf',
      'config.yaml',
      './lib/main.dart',
      './build/report.pdf',
      '../exports/report.pdf',
      '/srv/output/report.pdf',
      r'C:\exports\report.pdf',
      r'\\server\share\report.pdf',
      'file:///srv/output/report.pdf',
      '/srv/output/Makefile',
    ]) {
      final output = explicitRemoteFileOutput(target);
      expect(output?.kind, ChatOutputKind.file, reason: target);
      expect(output?.path, isNotEmpty, reason: target);
    }

    for (final target in [
      'https://example.test/report.pdf',
      'javascript:report.pdf',
      'intent://open/report.pdf',
      'content://files/report.pdf',
      '//example.test/report.pdf',
      'notes-without-an-extension',
    ]) {
      expect(explicitRemoteFileOutput(target), isNull, reason: target);
    }
  });

  test('decodes explicit Markdown paths without URI suffixes', () {
    final spaced = explicitRemoteFileOutput('./my%20report.pdf#page=2');
    expect(spaced?.path, './my report.pdf');
    expect(spaced?.label, 'my report.pdf');
    final escaped = explicitRemoteFileOutput(
      './report%23final%25.pdf?download=1',
    );
    expect(escaped?.path, './report#final%.pdf');
    expect(escaped?.label, 'report#final%.pdf');
    final encodedPercent = explicitRemoteFileOutput('./literal%2520name.txt');
    expect(encodedPercent?.path, './literal%20name.txt');
    expect(encodedPercent?.label, 'literal%20name.txt');
    final malformed = explicitRemoteFileOutput('./literal%2name.txt');
    expect(malformed?.path, './literal%2name.txt');
    expect(malformed?.label, 'literal%2name.txt');
    expect(
      explicitRemoteFileOutput(r'C:\exports\my%20report.dart#line=2')?.path,
      r'C:\exports\my report.dart',
    );
    expect(
      explicitRemoteFileOutput(
        r'\\server\share\report%23final.pdf?download=1',
      )?.path,
      r'\\server\share\report#final.pdf',
    );
  });

  test('extracts and deduplicates assistant-delivered outputs', () {
    final outputs = extractChatOutputs([
      {
        'role': 'assistant',
        'content': '''
Finished. MEDIA: "/srv/output/final report.pdf"
![chart](https://cdn.example.test/chart.png)
[source](https://example.test/results)
Also saved /srv/output/data.csv and /srv/output/data.csv.
''',
      },
    ]);

    expect(outputs.map((output) => output.target), [
      '/srv/output/final report.pdf',
      'https://cdn.example.test/chart.png',
      'https://example.test/results',
      '/srv/output/data.csv',
    ]);
    expect(outputs.map((output) => output.kind), [
      ChatOutputKind.file,
      ChatOutputKind.image,
      ChatOutputKind.link,
      ChatOutputKind.file,
    ]);
    expect(outputs.map((output) => output.label), [
      'final report.pdf',
      'chart.png',
      'results',
      'data.csv',
    ]);
    expect(outputs.first.path, '/srv/output/final report.pdf');
    expect(outputs[1].url, 'https://cdn.example.test/chart.png');
  });

  test('uses explicit producer fields and ignores passive tool paths', () {
    final outputs = extractChatOutputs([
      {
        'role': 'tool',
        'tool_name': 'web_search',
        'content': jsonEncode({
          'cache_path': '/srv/cache/passive.json',
          'source_url': 'https://example.test/passive',
        }),
      },
      {
        'role': 'tool',
        'tool_name': 'document_export',
        'content': jsonEncode({
          'output_path': '/srv/output/report.pdf',
          'cache_path': '/srv/cache/internal.json',
        }),
      },
      {
        'role': 'tool',
        'tool_name': 'write_file',
        'content': jsonEncode({
          'files_modified': ['/srv/output/notes.md'],
        }),
      },
    ]);

    expect(outputs.map((output) => output.target), [
      '/srv/output/report.pdf',
      '/srv/output/notes.md',
    ]);
  });

  test('extracts structured and wrapped browser screenshots', () {
    final outputs = extractChatOutputs([
      {
        'role': 'tool',
        'tool_name': 'browser_vision',
        'content': {
          '_multimodal': true,
          'meta': {'screenshot_path': '/srv/output/native.png'},
        },
      },
      {
        'role': 'tool',
        'tool_name': 'browser_vision',
        'content':
            'Image attached. Screenshot path: /srv/output/page capture.png',
      },
      {
        'role': 'tool',
        'tool_name': 'image_generate',
        'content': '''<untrusted_tool_result source="image_generate">
External data follows.

{"generated_image":"/srv/output/generated.webp"}
</untrusted_tool_result>''',
      },
    ]);

    expect(outputs.map((output) => output.target), [
      '/srv/output/native.png',
      '/srv/output/page capture.png',
      '/srv/output/generated.webp',
    ]);
    expect(
      outputs.every((output) => output.kind == ChatOutputKind.image),
      isTrue,
    );
  });

  test('accepts productive document formats from explicit delivery forms', () {
    final outputs = extractChatOutputs([
      {
        'role': 'assistant',
        'content': '''
MEDIA: report.docx
[Workbook](results.xlsx)
Mentioning draft.pptx in prose does not make it an output.
Saved /srv/output/slides.pptx.
''',
      },
      {
        'role': 'tool',
        'tool_name': 'document_export',
        'content': jsonEncode({'output_file': 'handout.pdf'}),
      },
    ]);

    expect(outputs.map((output) => output.target), [
      'report.docx',
      'results.xlsx',
      '/srv/output/slides.pptx',
      'handout.pdf',
    ]);
    expect(
      outputs.every((output) => output.kind == ChatOutputKind.file),
      isTrue,
    );
  });

  test('normalizes file URIs and gives embedded images a short label', () {
    final outputs = extractChatOutputs([
      {
        'role': 'assistant',
        'content': '''
MEDIA: file:///srv/output/report.pdf
MEDIA: file:///C:/Temp/workbook.xlsx
MEDIA: file://server/share/slides.pptx
![inline](data:image/png;base64,AAAA)
''',
      },
    ]);

    expect(outputs.map((output) => output.path), [
      '/srv/output/report.pdf',
      'C:/Temp/workbook.xlsx',
      '//server/share/slides.pptx',
      null,
    ]);
    expect(outputs.last.label, 'Embedded image');
  });
}
