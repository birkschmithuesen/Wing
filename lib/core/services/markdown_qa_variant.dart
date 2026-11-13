import 'performance_instrumentation.dart';

/// Background parsing is the production default. Explicit benchmark variants
/// allow matched performance comparisons against individual optimizations.
enum MarkdownQaVariant { baseline, guard, cache, background }

MarkdownQaVariant get markdownQaVariant {
  if (!PerformanceInstrumentation.enabled) return MarkdownQaVariant.background;
  return switch (const String.fromEnvironment(
    'WING_QA_MARKDOWN_VARIANT',
    defaultValue: 'background',
  )) {
    'baseline' => MarkdownQaVariant.baseline,
    'guard' => MarkdownQaVariant.guard,
    'cache' => MarkdownQaVariant.cache,
    'background' => MarkdownQaVariant.background,
    _ => throw StateError('Unknown QA Markdown variant.'),
  };
}
