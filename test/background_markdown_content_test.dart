import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:wing/core/services/markdown_parse_worker.dart';
import 'package:wing/core/services/markdown_segments.dart';
import 'package:wing/core/services/performance_instrumentation.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:wing/core/utils/expansion_scroll_controller.dart';
import 'package:wing/core/widgets/studio_error.dart';

MarkdownParseResult _prose(String source) => MarkdownParseResult(
  [
    MarkdownProseSegment(source: source, nodes: [md.Text(source)]),
  ],
  1,
  0,
  1,
);

void main() {
  for (final outcome in ['completed', 'failed', 'disposed']) {
    testWidgets('bounded pending transcript geometry releases when $outcome', (
      tester,
    ) async {
      final job = Completer<MarkdownParseResult>();
      final row = GlobalKey();
      Widget host({bool showMessage = true}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: TranscriptScrollAnchor(
            key: row,
            initialHeight: 240,
            child: SizedBox(
              width: 200,
              height: 96,
              child: LayoutBuilder(
                builder: (_, _) => showMessage
                    ? BackgroundMarkdownContent(
                        data: 'A saved answer',
                        deliverables: false,
                        parse: (_) => job.future,
                        builder: (_, _) => const SizedBox(height: 32),
                      )
                    : const SizedBox(height: 32),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(host());
      expect(tester.getSize(find.byKey(row)).height, 240);
      if (outcome == 'disposed') {
        await tester.pumpWidget(host(showMessage: false));
        job.complete(_prose('A saved answer'));
      } else if (outcome == 'failed') {
        job.completeError(StateError('Injected parse failure'));
      } else {
        job.complete(_prose('A saved answer'));
      }
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(row)).height, 96);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pending transcript geometry releases when $outcome', (
      tester,
    ) async {
      final job = Completer<MarkdownParseResult>();
      final row = GlobalKey();
      Widget host({bool showMessage = true}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: TranscriptScrollAnchor(
            key: row,
            initialHeight: 240,
            child: showMessage
                ? BackgroundMarkdownContent(
                    data: 'A saved answer',
                    deliverables: false,
                    parse: (_) => job.future,
                    builder: (_, _) => const SizedBox(height: 32),
                  )
                : const SizedBox(height: 32),
          ),
        ),
      );
      await tester.pumpWidget(host());
      expect(tester.getSize(find.byKey(row)).height, 240);
      if (outcome == 'disposed') {
        await tester.pumpWidget(host(showMessage: false));
        job.complete(_prose('A saved answer'));
      } else if (outcome == 'failed') {
        job.completeError(StateError('Injected parse failure'));
      } else {
        job.complete(_prose('A saved answer'));
      }
      await tester.pump();
      await tester.pump();
      expect(tester.getSize(find.byKey(row)).height, lessThan(240));
      if (outcome != 'failed') {
        expect(tester.getSize(find.byKey(row)).height, 32);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('grammar changes reparse identical source before rendering', (
    tester,
  ) async {
    final jobs = <Completer<MarkdownParseResult>>[];
    Future<MarkdownParseResult> parse(String source) {
      final result = Completer<MarkdownParseResult>();
      jobs.add(result);
      return result.future;
    }

    Widget host(bool deliverables) => Directionality(
      textDirection: TextDirection.ltr,
      child: BackgroundMarkdownContent(
        data: 'Same source',
        deliverables: deliverables,
        parse: parse,
        builder: (text, _) => Text(text),
      ),
    );
    await tester.pumpWidget(host(true));
    jobs.first.complete(const MarkdownParseResult([], 1, 0, 1));
    await tester.pump();
    await tester.pump();
    expect(find.text('Same source'), findsOneWidget);
    await tester.pumpWidget(host(false));
    expect(jobs, hasLength(2));
    expect(find.text('Same source'), findsNothing);
    jobs.last.complete(const MarkdownParseResult([], 1, 0, 1));
    await tester.pump();
    await tester.pump();
    expect(find.text('Same source'), findsOneWidget);
  });

  testWidgets('failed parse retries on new data and clears the error', (
    tester,
  ) async {
    final jobs = <Completer<MarkdownParseResult>>[];
    Future<MarkdownParseResult> parse(String source) {
      final result = Completer<MarkdownParseResult>();
      jobs.add(result);
      return result.future;
    }

    Widget host(String data) => Directionality(
      textDirection: TextDirection.ltr,
      child: BackgroundMarkdownContent(
        data: data,
        deliverables: false,
        parse: parse,
        builder: (text, _) => Text(text),
      ),
    );
    await tester.pumpWidget(host('A'));
    final state = tester.state<BackgroundMarkdownContentState>(
      find.byType(BackgroundMarkdownContent),
    );
    expect(state.pending, isTrue);
    jobs.first.completeError(StateError('Injected failure'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudioError), findsOneWidget);
    // A terminal failure must not keep restoration or test waiters pending.
    expect(state.pending, isFalse);
    await tester.pumpWidget(host('AB'));
    expect(state.pending, isTrue);
    jobs.last.complete(const MarkdownParseResult([], 1, 0, 1));
    await tester.pump();
    await tester.pump();
    expect(find.text('AB'), findsOneWidget);
    expect(find.byType(StudioError), findsNothing);
    expect(state.pending, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'latest update waits behind one parse while completed progress stays visible',
    (tester) async {
      final jobs = <(String, Completer<MarkdownParseResult>)>[];
      Future<MarkdownParseResult> parse(String source) {
        final result = Completer<MarkdownParseResult>();
        jobs.add((source, result));
        return result.future;
      }

      Widget host(String source) => Directionality(
        textDirection: TextDirection.ltr,
        child: BackgroundMarkdownContent(
          data: source,
          deliverables: false,
          parse: parse,
          builder: (text, _) => Text(text),
        ),
      );
      await tester.pumpWidget(host('A'));
      await tester.pumpWidget(host('AB'));
      await tester.pumpWidget(host('ABC'));
      expect(jobs.map((job) => job.$1), ['A']);
      jobs.first.$2.complete(_prose('A'));
      await tester.pump();
      await tester.pump();
      expect(find.text('A'), findsOneWidget);
      expect(jobs.map((job) => job.$1), ['A', 'ABC']);
      jobs.last.$2.complete(_prose('ABC'));
      await tester.pump();
      await tester.pump();
      expect(find.text('ABC'), findsOneWidget);
      expect(
        tester
            .state<BackgroundMarkdownContentState>(
              find.byType(BackgroundMarkdownContent),
            )
            .pending,
        isFalse,
      );
    },
  );

  testWidgets(
    'mixed snapshots publish prose and fences atomically while coalescing',
    (tester) async {
      const initial = 'First\n\n```dart\nold();';
      const middle = '$initial\nnew();';
      const latest = '$middle\n```\n\nLast';
      final jobs = <(String, Completer<MarkdownParseResult>)>[];
      final published = <String, List<MarkdownSegment>>{};
      var changes = 0;
      Future<MarkdownParseResult> parse(String source) {
        final result = Completer<MarkdownParseResult>();
        jobs.add((source, result));
        return result.future;
      }

      Widget host(String source) => Directionality(
        textDirection: TextDirection.ltr,
        child: NotificationListener<MarkdownContentWillChange>(
          onNotification: (_) {
            changes++;
            return false;
          },
          child: BackgroundMarkdownContent(
            data: source,
            deliverables: false,
            streaming: true,
            parse: parse,
            builder: (text, segments) {
              published[text] = segments;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final segment in segments)
                    Text(switch (segment) {
                      MarkdownProseSegment() => 'prose: ${segment.source}',
                      MarkdownFenceSegment() => 'code: ${segment.code}',
                    }),
                ],
              );
            },
          ),
        ),
      );

      await tester.pumpWidget(host(initial));
      final state = tester.state<BackgroundMarkdownContentState>(
        find.byType(BackgroundMarkdownContent),
      );
      await tester.pumpWidget(host(middle));
      await tester.pumpWidget(host(latest));
      expect(jobs.map((job) => job.$1), [initial]);
      expect(
        state.updatesCoalesced,
        PerformanceInstrumentation.enabled ? 2 : 0,
      );
      expect(published, isEmpty);
      jobs.first.$2.complete(
        MarkdownParseResult(
          [
            MarkdownProseSegment(source: 'First', nodes: [md.Text('First')]),
            const MarkdownFenceSegment(
              code: 'old();',
              language: 'dart',
              closed: false,
            ),
          ],
          11,
          1,
          1,
          fenceMicros: 3,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(jobs.map((job) => job.$1), [initial, latest]);
      expect(state.renderedSource, initial);
      expect(state.pending, isTrue);
      expect(find.text('code: old();'), findsOneWidget);
      expect(find.text('prose: Last'), findsNothing);
      expect(published.keys, [initial]);
      expect(
        (published[initial]!.last as MarkdownFenceSegment).closed,
        isFalse,
      );

      jobs.last.$2.complete(
        MarkdownParseResult(
          [
            MarkdownProseSegment(source: 'First', nodes: [md.Text('First')]),
            const MarkdownFenceSegment(
              code: 'old();\nnew();',
              language: 'dart',
              closed: true,
            ),
            MarkdownProseSegment(source: 'Last', nodes: [md.Text('Last')]),
          ],
          13,
          2,
          2,
          fenceMicros: 5,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(state.renderedSource, latest);
      expect(state.pending, isFalse);
      expect(find.text('code: old();'), findsNothing);
      expect(find.text('code: old();\nnew();'), findsOneWidget);
      expect(find.text('prose: Last'), findsOneWidget);
      expect(published.keys, [initial, latest]);
      expect((published[latest]![1] as MarkdownFenceSegment).closed, isTrue);
      expect(changes, 2);
      expect(state.parsesCompleted, PerformanceInstrumentation.enabled ? 2 : 0);
      expect(
        state.totalParserMicros,
        PerformanceInstrumentation.enabled ? 24 : 0,
      );
      expect(
        state.totalFenceMicros,
        PerformanceInstrumentation.enabled ? 8 : 0,
      );
      expect(state.totalCacheHits, PerformanceInstrumentation.enabled ? 3 : 0);
      expect(
        state.totalRequestMicros,
        PerformanceInstrumentation.enabled ? greaterThan(0) : 0,
      );
      expect(
        state.maxRequestMicros,
        PerformanceInstrumentation.enabled ? greaterThan(0) : 0,
      );
      expect(
        state.maxRequestMicros,
        lessThanOrEqualTo(state.totalRequestMicros),
      );
      expect(
        state.maxPendingCharacters,
        PerformanceInstrumentation.enabled
            ? greaterThanOrEqualTo(latest.length - initial.length)
            : 0,
      );
    },
  );

  testWidgets('replacement rejects a late result from a different snapshot', (
    tester,
  ) async {
    final jobs = <Completer<MarkdownParseResult>>[];
    Future<MarkdownParseResult> parse(String source) {
      final result = Completer<MarkdownParseResult>();
      jobs.add(result);
      return result.future;
    }

    Widget host(String source) => Directionality(
      textDirection: TextDirection.ltr,
      child: BackgroundMarkdownContent(
        data: source,
        deliverables: false,
        parse: parse,
        builder: (text, _) => Text(text),
      ),
    );
    await tester.pumpWidget(host('Old message'));
    await tester.pumpWidget(host('Replacement'));
    jobs.last.complete(_prose('Replacement'));
    await tester.pump();
    await tester.pump();
    jobs.first.complete(_prose('Old message'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Replacement'), findsOneWidget);
    expect(find.text('Old message'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'backgrounding cancels display publication and resumes latest source',
    (tester) async {
      final jobs = <(String, Completer<MarkdownParseResult>)>[];
      Future<MarkdownParseResult> parse(String source) {
        final result = Completer<MarkdownParseResult>();
        jobs.add((source, result));
        return result.future;
      }

      Widget host(String source) => Directionality(
        textDirection: TextDirection.ltr,
        child: BackgroundMarkdownContent(
          data: source,
          deliverables: false,
          parse: parse,
          builder: (text, _) => Text(text),
        ),
      );
      await tester.pumpWidget(host('A'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpWidget(host('ABC'));
      jobs.first.$2.complete(_prose('A'));
      await tester.pump();
      await tester.pump();
      expect(find.text('A'), findsNothing);
      expect(jobs, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(jobs.last.$1, 'ABC');
      jobs.last.$2.complete(_prose('ABC'));
      await tester.pump();
      await tester.pump();
      expect(find.text('ABC'), findsOneWidget);
    },
  );
}
