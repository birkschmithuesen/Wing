// Compile and run this probe in product mode, deliberately requesting metrics.
// It exercises the actual parser and worker, including an alternate QA renderer.
import 'dart:io';

import 'package:wing/core/services/completion_diagnostics.dart';
import 'package:wing/core/services/markdown_inline_parser.dart';
import 'package:wing/core/services/markdown_parse_worker.dart';
import 'package:wing/core/services/markdown_qa_variant.dart';
import 'package:wing/core/services/markdown_segments.dart';
import 'package:wing/core/services/performance_instrumentation.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  require(
    const bool.fromEnvironment('dart.vm.product'),
    'Compile this probe with dart compile exe.',
  );
  require(!PerformanceInstrumentation.enabled, 'Release enabled measurements.');
  require(
    !CompletionDiagnostics.enabled,
    'Release enabled completion tracing.',
  );
  require(
    markdownQaVariant == MarkdownQaVariant.background,
    'Release selected an alternate QA renderer.',
  );
  require(CompletionDiagnostics.start() == 0, 'Release read the trace clock.');
  CompletionDiagnostics.event('release.probe');
  CompletionDiagnostics.finish('release.probe', 0);
  require(
    CompletionDiagnostics.snapshot().length == 1 &&
        CompletionDiagnostics.snapshot()['enabled'] == false,
    'Release recorded diagnostic events.',
  );

  final parser = MarkdownInlineParser(deliverables: false);
  const prose = '**first**\n\nsecond\n';
  require(parser.parse(prose).isNotEmpty, 'Release parser lost content.');
  parser.parse('$prose\nthird\n');
  require(
    parser.inlineParses == 0 &&
        parser.cacheHits == 0 &&
        parser.lastParseMicros == 0,
    'Release parser performed measurements.',
  );

  final worker = MarkdownParseWorker();
  try {
    final result = await worker.parse(
      owner: 1,
      source: '$prose\n```dart\nfinal value = 1;\n```\n',
      deliverables: false,
    );
    final fences = result.segments.whereType<MarkdownFenceSegment>().toList();
    require(
      result.segments.first is MarkdownProseSegment &&
          (result.segments.first as MarkdownProseSegment).source.contains(
            '**first**',
          ) &&
          fences.length == 1 &&
          fences.single.language == 'dart' &&
          fences.single.closed &&
          fences.single.code.contains('final value = 1;'),
      'Release worker lost formatted content.',
    );
    require(
      result.parseMicros == 0 &&
          result.fenceMicros == 0 &&
          result.cacheHits == 0 &&
          result.inlineParses == 0,
      'Release worker performed measurements.',
    );
  } finally {
    worker.dispose();
  }
  stdout.writeln('Product-mode instrumentation checks passed.');
}
