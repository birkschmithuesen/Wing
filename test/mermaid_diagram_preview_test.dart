import 'package:wing/core/models/transcript_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/widgets/web_output_preview.dart';
import 'package:wing/core/widgets/markdown_code_block.dart';
import 'package:wing/core/widgets/source_code_block.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'helpers/pump_markdown_widget.dart';

void main() {
  test('only complete non-streaming Mermaid blocks offer rendering', () {
    const source = '```mermaid\ngraph TD\nA --> B\n```';
    final complete =
        splitMarkdownCodeBlocks(source).single as MarkdownCodeBlock;
    expect(complete.previewEnabled, isTrue);
    expect(complete.code, 'graph TD\nA --> B\n');
    expect(
      (splitMarkdownCodeBlocks(source, streaming: true).single
              as MarkdownCodeBlock)
          .previewEnabled,
      isFalse,
    );
    expect(
      (splitMarkdownCodeBlocks('```mermaid\ngraph TD').single
              as MarkdownCodeBlock)
          .previewEnabled,
      isFalse,
    );
  });

  testWidgets('oversized diagrams keep source and copy without a native view', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownCodeBlock(
            language: 'mermaid',
            code: 'A' * (WebOutputPreview.maxMermaidSourceLength + 1),
          ),
        ),
      ),
    );
    expect(find.byTooltip('Open diagram'), findsNothing);
    expect(find.byTooltip('Copy code'), findsOneWidget);
    expect(find.byType(AndroidView), findsNothing);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'diagram opens on tap and returns to chat at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final nativeCalls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          (call) async {
            nativeCalls.add(call);
            if (call.method == 'create') return 1;
            if (call.method == 'resize') {
              final args = call.arguments as Map;
              return {'width': args['width'], 'height': args['height']};
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          );
        });
        const source = 'graph TD\nA[Plan] --> B[Deliver]\n';
        await tester.pumpMarkdownWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProfileMessage(
                  message: TranscriptMessage.fromRow({
                    'role': 'assistant',
                    'content': 'A plan\n```mermaid\n$source```',
                  }),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(nativeCalls, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Open diagram'));
        await tester.pumpAndSettle();
        final create = nativeCalls.singleWhere(
          (call) => call.method == 'create',
        );
        final args = create.arguments as Map;
        expect(args['viewType'], WebOutputPreview.viewType);
        expect(
          const StandardMessageCodec().decodeMessage(
            ByteData.sublistView(args['params'] as Uint8List),
          ),
          {
            'source': source,
            'dark': true,
            'format': 'mermaid',
            'palette': {
              'canvas': Theme.of(
                tester.element(find.byType(AndroidView)),
              ).colorScheme.surface.toARGB32(),
              'panel': Theme.of(
                tester.element(find.byType(AndroidView)),
              ).canvasColor.toARGB32(),
              'text': Theme.of(
                tester.element(find.byType(AndroidView)),
              ).colorScheme.onSurface.toARGB32(),
              'muted': Theme.of(
                tester.element(find.byType(AndroidView)),
              ).colorScheme.onSurfaceVariant.toARGB32(),
              'border': Theme.of(
                tester.element(find.byType(AndroidView)),
              ).colorScheme.outlineVariant.toARGB32(),
              'error': Theme.of(
                tester.element(find.byType(AndroidView)),
              ).colorScheme.error.toARGB32(),
              'error-surface': const Color(0xFF352422).toARGB32(),
              'accent': Theme.of(
                tester.element(find.byType(AndroidView)),
              ).colorScheme.primary.toARGB32(),
            },
          },
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Show source'));
        await tester.pumpAndSettle();
        expect(find.byType(AndroidView), findsNothing);
        expect(find.byTooltip('Copy code'), findsOneWidget);
        expect(find.byTooltip('Open diagram'), findsNothing);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('A plan'), findsOneWidget);
        expect(find.byTooltip('Open diagram'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('complete SVG fences open the shared viewer with exact source', (
    tester,
  ) async {
    final nativeCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        nativeCalls.add(call);
        if (call.method == 'create') return 1;
        if (call.method == 'resize') {
          final args = call.arguments as Map;
          return {'width': args['width'], 'height': args['height']};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    const source = '<svg><text>Exact</text></svg>\n';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownCodeBlock(language: 'svg', code: source),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Open SVG'));
    await tester.pumpAndSettle();

    final create = nativeCalls.singleWhere((call) => call.method == 'create');
    final args = create.arguments as Map;
    expect(args['viewType'], WebOutputPreview.viewType);
    expect(
      const StandardMessageCodec().decodeMessage(
        ByteData.sublistView(args['params'] as Uint8List),
      ),
      {
        'source': source,
        'dark': false,
        'format': 'svg',
        'palette': {
          'canvas': Theme.of(
            tester.element(find.byType(AndroidView)),
          ).colorScheme.surface.toARGB32(),
          'panel': Theme.of(
            tester.element(find.byType(AndroidView)),
          ).canvasColor.toARGB32(),
          'text': Theme.of(
            tester.element(find.byType(AndroidView)),
          ).colorScheme.onSurface.toARGB32(),
          'muted': Theme.of(
            tester.element(find.byType(AndroidView)),
          ).colorScheme.onSurfaceVariant.toARGB32(),
          'border': Theme.of(
            tester.element(find.byType(AndroidView)),
          ).colorScheme.outlineVariant.toARGB32(),
          'error': Theme.of(
            tester.element(find.byType(AndroidView)),
          ).colorScheme.error.toARGB32(),
          'error-surface': const Color(0xFFFFF1EF).toARGB32(),
          'accent': Theme.of(
            tester.element(find.byType(AndroidView)),
          ).colorScheme.primary.toARGB32(),
        },
      },
    );
    await tester.tap(find.byTooltip('Show source'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SourceCodeBlock>(find.byType(SourceCodeBlock)).code,
      source,
    );
    expect(find.byTooltip('Show SVG'), findsOneWidget);
  });

  testWidgets(
    'streaming incomplete and oversized SVG fences stay source-only',
    (tester) async {
      final streaming =
          splitMarkdownCodeBlocks('```svg\n<svg>', streaming: true).single
              as MarkdownCodeBlock;
      final incomplete =
          splitMarkdownCodeBlocks('```svg\n<svg>').single as MarkdownCodeBlock;
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              streaming,
              MarkdownCodeBlock(
                language: 'svg',
                code: 'x' * (WebOutputPreview.maxSvgSourceLength + 1),
              ),
            ],
          ),
        ),
      );

      expect(streaming.previewEnabled, isFalse);
      expect(incomplete.previewEnabled, isFalse);
      expect(find.byTooltip('Open SVG'), findsNothing);
      expect(find.byTooltip('Copy code'), findsNWidgets(2));
    },
  );
}
