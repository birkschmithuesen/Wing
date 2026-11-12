// Host parser diagnostic, independent of Flutter and phone frame measurements.
// dart run -DWING_PERF_INSTRUMENTATION=true tools/performance/markdown_parse_benchmark.dart [report.json]
import 'dart:convert';
import 'dart:io';

import 'package:markdown/markdown.dart' as md;
import 'package:wing/core/services/markdown_inline_parser.dart';
import 'package:wing/core/services/performance_instrumentation.dart';

import 'streaming_replay_fixture.dart';

const _warmups = 2;
const _repeats = 7;
const _variants = [
  (name: 'baseline', guard: false, cache: false),
  (name: 'guard', guard: true, cache: false),
  (name: 'cache', guard: true, cache: true),
];

String _ast(List<md.Node> nodes) => jsonEncode(nodes.map(_nodeValue).toList());

Object _nodeValue(md.Node node) {
  if (node is md.Text) return ['text', node.text];
  final element = node as md.Element;
  final attributes = element.attributes.keys.toList()..sort();
  return [
    element.tag,
    {for (final key in attributes) key: element.attributes[key]},
    element.generatedId,
    element.footnoteLabel,
    element.children?.map(_nodeValue).toList(),
  ];
}

({int parseUs, int cacheHits, int inlineParses}) _replay(
  List<String> snapshots,
  List<String> expected, {
  required bool guard,
  required bool cache,
}) {
  final parser = MarkdownInlineParser(
    deliverables: true,
    guardCode: guard,
    cacheEnabled: cache,
  );
  if (_ast(parser.parse(snapshots.first)) != expected.first) {
    throw StateError('Initial AST differs: guard=$guard cache=$cache.');
  }
  final watch = Stopwatch();
  var cacheHits = 0;
  var inlineParses = 0;
  for (var publication = 1; publication < snapshots.length; publication++) {
    watch.start();
    final nodes = parser.parse(snapshots[publication]);
    watch.stop();
    cacheHits += parser.cacheHits;
    inlineParses += parser.inlineParses;
    // Serialization and comparison are deliberately outside the timed interval.
    if (_ast(nodes) != expected[publication]) {
      throw StateError(
        'AST differs at publication $publication: guard=$guard cache=$cache.',
      );
    }
  }
  return (
    parseUs: watch.elapsedMicroseconds,
    cacheHits: cacheHits,
    inlineParses: inlineParses,
  );
}

void main(List<String> arguments) {
  if (!PerformanceInstrumentation.enabled) {
    throw StateError('Run with -DWING_PERF_INSTRUMENTATION=true.');
  }
  if (arguments.length > 1) {
    throw ArgumentError('Usage: markdown_parse_benchmark.dart [report.json]');
  }
  final fixtures = <Map<String, Object>>[];
  for (final fences in [false, true]) {
    final initial = streamingReplayInitial(fences: fences);
    final growth = streamingReplayGrowth(fences: fences);
    final snapshots = [
      initial,
      for (
        var publication = 0;
        publication < streamingReplayPresentations;
        publication++
      )
        initial +
            growth.substring(
              0,
              streamingReplayGrowthEnd(publication, growth.length),
            ),
    ];
    final oracle = MarkdownInlineParser(
      deliverables: true,
      guardCode: false,
      cacheEnabled: false,
    );
    final expected = snapshots
        .map((source) => _ast(oracle.parse(source)))
        .toList();
    final results = {
      for (final variant in _variants)
        variant.name: <({int parseUs, int cacheHits, int inlineParses})>[],
    };
    for (var round = 0; round < _warmups + _repeats; round++) {
      // Rotate execution order to distribute host load and JIT effects.
      for (var offset = 0; offset < _variants.length; offset++) {
        final variant = _variants[(round + offset) % _variants.length];
        final result = _replay(
          snapshots,
          expected,
          guard: variant.guard,
          cache: variant.cache,
        );
        if (round >= _warmups) results[variant.name]!.add(result);
      }
    }
    fixtures.add({
      'fences': fences ? 1 : 0,
      'initialCodeUnits': initial.length,
      'finalCodeUnits': snapshots.last.length,
      'publications': streamingReplayPresentations,
      'verifiedSnapshotsPerReplay': snapshots.length,
      'variants': {
        for (final variant in _variants)
          variant.name: _metrics(results[variant.name]!),
      },
    });
  }
  final report = {
    'kind': 'host-pure-dart-parser-diagnostic',
    'dartVersion': Platform.version,
    'operatingSystem': Platform.operatingSystem,
    'warmupsPerVariantAndFixture': _warmups,
    'measuredRepeatsPerVariantAndFixture': _repeats,
    'deliverables': 1,
    'limitations': [
      'Whole Markdown documents are parsed; app code-fence splitting is excluded.',
      'Initial seed parsing and AST verification are outside measured intervals.',
      'Host JIT timings include parsing, cache lookup and defensive AST copying.',
      'Verification between parses can affect allocation and garbage collection.',
      'No widget building, isolate transport, frame, typing or phone latency is measured.',
    ],
    'fixtures': fixtures,
  };
  final file = File(
    arguments.isEmpty
        ? 'build/background-markdown/markdown-parse-benchmark.json'
        : arguments.single,
  );
  file.parent.createSync(recursive: true);
  final json = '${const JsonEncoder.withIndent('  ').convert(report)}\n';
  file.writeAsStringSync(json);
  stdout.write(json);
}

Map<String, Object> _metrics(
  List<({int parseUs, int cacheHits, int inlineParses})> results,
) {
  final times = results.map((result) => result.parseUs).toList();
  final sorted = [...times]..sort();
  final counts = results.first;
  if (results.any(
    (result) =>
        result.cacheHits != counts.cacheHits ||
        result.inlineParses != counts.inlineParses,
  )) {
    throw StateError('Work counts changed across identical replays.');
  }
  return {
    'medianTotalParseUs': sorted[sorted.length ~/ 2],
    'minTotalParseUs': sorted.first,
    'maxTotalParseUs': sorted.last,
    'totalParseUsPerRepeat': times,
    'cacheHitsPerReplay': counts.cacheHits,
    'inlineParsesPerReplay': counts.inlineParses,
    'allSnapshotsEquivalent': 1,
  };
}
