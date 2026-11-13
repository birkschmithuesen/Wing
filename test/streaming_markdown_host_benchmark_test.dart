// Host diagnostic only: these debug timings do not measure phone frame latency.
// flutter test --no-pub --reporter expanded \
//   --dart-define=WING_STREAMING_BENCHMARK=true \
//   --dart-define=WING_STREAMING_REPORT=build/streaming-performance/report.json \
//   test/streaming_markdown_host_benchmark_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:wing/core/widgets/block_reusing_markdown_body.dart';
import 'package:wing/core/widgets/markdown_code_block.dart';
import 'package:wing/core/widgets/source_code_block.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';

import '../tools/performance/streaming_replay_fixture.dart';

const _enabled = bool.fromEnvironment('WING_STREAMING_BENCHMARK');
const _report = String.fromEnvironment('WING_STREAMING_REPORT');
const _fences = bool.fromEnvironment(
  'WING_STREAMING_FENCES',
  defaultValue: true,
);

Object _astValue(md.Node node) {
  if (node is md.Text) return ['text', node.text];
  final element = node as md.Element;
  final keys = element.attributes.keys.toList()..sort();
  return [
    element.tag,
    {for (final key in keys) key: element.attributes[key]},
    element.children?.map(_astValue).toList(),
  ];
}

Map<String, int> _distribution(List<int> values) {
  final sorted = [...values]..sort();
  int percentile(double fraction) =>
      sorted[((sorted.length - 1) * fraction).ceil()];
  return {
    'total': values.fold(0, (sum, value) => sum + value),
    'p50': percentile(.50),
    'p95': percentile(.95),
    'max': sorted.last,
  };
}

void main() {
  testWidgets(
    'mixed growing Markdown with simultaneous typing: host diagnostic',
    (tester) async {
      final source = ValueNotifier(streamingReplayInitial(fences: _fences));
      final draft = TextEditingController();
      addTearDown(source.dispose);
      addTearDown(draft.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: SizedBox(
                      width: 390,
                      child: ValueListenableBuilder<String>(
                        valueListenable: source,
                        builder: (_, text, _) =>
                            MarkdownMessageContent(data: text, streaming: true),
                      ),
                    ),
                  ),
                ),
                TextField(
                  key: const Key('synthetic-composer'),
                  controller: draft,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final buildUs = <int>[];
      final layoutUs = <int>[];
      final paintUs = <int>[];
      final splitUs = <int>[];
      final parseUs = <int>[];
      final signatureUs = <int>[];
      var bodyBuilds = 0;
      var codeBuilds = 0;
      var unchangedCodeBuilds = 0;
      final initialCode = {
        for (var section = 0; section < 6; section++)
          'final synthetic$section = $section;\n',
      };
      var retained = 0;
      var created = 0;
      var typingBodyBuilds = 0;
      final original = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget is BlockReusingMarkdownBody) bodyBuilds++;
        if (element.widget case SourceCodeBlock(code: final code)) {
          codeBuilds++;
          if (initialCode.contains(code)) unchangedCodeBuilds++;
        }
        original?.call(element, builtOnce);
      };
      addTearDown(() => debugOnRebuildDirtyWidget = original);
      final growing = streamingReplayGrowth(fences: _fences);
      // Ten synthetic deltas per presentation, at the controller's 100ms cadence.
      // Two composer edits per presentation exercise overlapping dirty work.
      const updates = streamingReplayPresentations;
      var consumed = 0;
      for (var update = 0; update < updates; update++) {
        final before = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .toSet();
        for (
          var delta = 0;
          delta < streamingReplayDeltasPerPresentation;
          delta++
        ) {
          if (delta == 3 || delta == 8) {
            final beforeTyping = bodyBuilds;
            await tester.enterText(
              find.byKey(const Key('synthetic-composer')),
              streamingReplayDraft(update, delta),
            );
            await tester.pump(const Duration(milliseconds: 10));
            typingBodyBuilds += bodyBuilds - beforeTyping;
          } else {
            await tester.pump(const Duration(milliseconds: 10));
          }
        }
        final nextConsumed = streamingReplayGrowthEnd(update, growing.length);
        source.value += growing.substring(consumed, nextConsumed);
        consumed = nextConsumed;

        final watch = Stopwatch()..start();
        await tester.pump(Duration.zero, EnginePhase.build);
        buildUs.add(watch.elapsedMicroseconds);
        watch.reset();
        tester.binding.rootPipelineOwner.flushLayout();
        layoutUs.add(watch.elapsedMicroseconds);
        watch.reset();
        tester.binding.rootPipelineOwner.flushCompositingBits();
        tester.binding.rootPipelineOwner.flushPaint();
        paintUs.add(watch.elapsedMicroseconds);
        watch.stop();
        // Complete the frame before the next input operation. The staged timings
        // above isolate host build, layout and paint flushes, not raster/present.
        await tester.pump();
        for (final text in tester.widgetList<SelectableText>(
          find.byType(SelectableText),
        )) {
          if (before.contains(text)) {
            retained++;
          } else {
            created++;
          }
        }

        // Equivalent stock full-document parsing and AST-signature work are
        // measured separately. They are explanatory probes, not a subtraction
        // from the actual widget's build time (JIT/cache effects differ).
        watch.start();
        watch.reset();
        final segments = splitMarkdownCodeBlocks(source.value, streaming: true);
        splitUs.add(watch.elapsedMicroseconds);
        watch.reset();
        final nodes = [
          for (final segment in segments.whereType<String>())
            ...md.Document(
              extensionSet: md.ExtensionSet.gitHubFlavored,
              encodeHtml: false,
            ).parseLines(const LineSplitter().convert(segment)),
        ];
        parseUs.add(watch.elapsedMicroseconds);
        watch.reset();
        for (final node in nodes) {
          jsonEncode(_astValue(node));
        }
        signatureUs.add(watch.elapsedMicroseconds);
        watch.stop();
        expect(tester.takeException(), isNull);
      }

      expect(source.value, streamingReplayInitial(fences: _fences) + growing);
      expect(draft.text, 'Synthetic draft 59/8');
      expect(
        typingBodyBuilds,
        0,
        reason:
            'Composer input must leave the unchanged live renderer unbuilt.',
      );
      final result = {
        'kind': 'host-debug-diagnostic-not-device-latency',
        'fixture':
            '12 mixed sections, 60 presentation updates, 120 draft edits',
        'fences': _fences,
        'finalCodeUnits': source.value.length,
        'buildUs': _distribution(buildUs),
        'layoutUs': _distribution(layoutUs),
        'paintFlushUs': _distribution(paintUs),
        'equivalentSplitUs': _distribution(splitUs),
        'equivalentFullParseUs': _distribution(parseUs),
        'equivalentAstSignatureUs': _distribution(signatureUs),
        'bodyBuilds': bodyBuilds,
        'codeBuilds': codeBuilds,
        'unchangedInitialCodeBuilds': unchangedCodeBuilds,
        'typingBodyBuilds': typingBodyBuilds,
        'retainedSelectableWidgets': retained,
        'createdSelectableWidgets': created,
        'samples': {
          'buildUs': buildUs,
          'layoutUs': layoutUs,
          'paintFlushUs': paintUs,
          'equivalentFullParseUs': parseUs,
        },
      };
      if (_report.isNotEmpty) {
        final file = File(_report);
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(result)}\n',
        );
      }
      debugPrint('[WingStreamingHost] ${jsonEncode(result)}');
    },
    skip: !_enabled,
  );
}
