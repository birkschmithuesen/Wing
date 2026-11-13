import 'package:wing/core/widgets/activity/activity_detail_actions.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:wing/core/widgets/source_code_text.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';
import 'package:wing/core/presentation/tool_call_presentation.dart';
import 'package:wing/core/services/owned_remote_files.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';
import 'package:wing/core/widgets/resource_filename.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';

import 'helpers/pump_markdown_widget.dart';

ToolCallPresentation call(String name, Map args, Map result) =>
    ToolCallPresentation.live(
      GatewayToolActivity.fromGatewayEvent('tool.complete', {
        'tool_id': 'call',
        'name': name,
        'args': args,
        'result': result,
      })!,
    );
Future<void> pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(390, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.settleMarkdown();
  await tester.pumpAndSettle();
}

void main() {
  const capture = bool.fromEnvironment('CAPTURE_ACTIVITY_ACTIONS');
  setUpAll(() async {
    if (!capture) return;
    const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$fonts/${font.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  Future<void> capturePending(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('activity-capture')),
    );
    await tester.runAsync(() async {
      final bitmap = await boundary.toImage();
      try {
        final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/design-previews/activity-pending/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        bitmap.dispose();
      }
    });
  }

  for (final brightness in Brightness.values) {
    for (final enlarged in [false, true]) {
      for (final outcome in ['success', 'failure', 'departure']) {
        final name =
            '${brightness.name}-${enlarged ? 'large-reduced' : 'normal'}-$outcome';
        testWidgets('activity sharing retains visible feedback through $name', (
          tester,
        ) async {
          tester.view.physicalSize = Size(enlarged ? 320 : 390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final pending = Completer<void>();
          addTearDown(() {
            if (!pending.isCompleted) pending.complete();
          });
          final shared = <String>[];
          const raw =
              '# Review output\n\nRead the actual error before changing code.\n';
          const channel = MethodChannel('dev.fluttercommunity.plus/share');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async {
              if (call.method != 'share') {
                throw StateError('Unexpected ${call.method}');
              }
              shared.add((call.arguments as Map)['text'] as String);
              await pending.future;
              if (outcome == 'failure' && shared.length == 1) {
                throw PlatformException(code: 'unavailable');
              }
              return 'dev.fluttercommunity.plus/share/success';
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => RepaintBoundary(
                key: const Key('activity-capture'),
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(enlarged ? 2 : 1),
                    disableAnimations: enlarged,
                  ),
                  child: child!,
                ),
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: ToolActivityDetailsView(
                    call: call(
                      'skill_view',
                      {'name': 'review-output'},
                      {
                        'success': true,
                        'name': 'review-output',
                        '_source_path':
                            '/workspace/skills/review-output/SKILL.md',
                        'content': raw,
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Open skill instructions'));
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          await tester.tap(find.byTooltip('Show raw content'));
          await tester.pumpAndSettle();
          final share = find.byTooltip('Share content');
          final before = tester.getRect(share);
          await tester.tap(share);
          await tester.pump();
          final progress = find.descendant(
            of: share,
            matching: find.byType(CircularProgressIndicator),
          );
          expect(progress, findsOneWidget);
          expect(tester.getRect(share), before);
          expect(
            tester.widget<CircularProgressIndicator>(progress).value,
            enlarged ? isNotNull : isNull,
          );
          expect(
            tester.widget<CircularProgressIndicator>(progress).backgroundColor,
            isNotNull,
            reason:
                'The first frame must paint a visible track before indeterminate motion advances.',
          );
          expect(find.text(raw), findsOneWidget);
          await capturePending(tester, name);
          await tester.tap(share);
          await tester.pump(const Duration(seconds: 2));
          expect(shared, [raw]);
          expect(progress, findsOneWidget);
          if (outcome == 'departure') {
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(find.byTooltip('Share content'), findsNothing);
            pending.complete();
            await tester.pumpAndSettle();
            expect(find.byTooltip('Open skill instructions'), findsOneWidget);
            expect(find.byType(CircularProgressIndicator), findsNothing);
          } else {
            pending.complete();
            await tester.pumpAndSettle();
            expect(progress, findsNothing);
            expect(share.hitTestable(), findsOneWidget);
            if (outcome == 'failure') {
              expect(
                find.text('Could not share this text. Try again.'),
                findsOneWidget,
              );
              await tester.tap(share);
              await tester.pumpAndSettle();
              expect(shared, [raw, raw]);
              expect(progress, findsNothing);
            }
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets(
    'short code can toggle wrapping while prose and empty code cannot',
    (tester) async {
      for (final block in [
        const ToolDetailBlock(
          label: 'Code',
          text: 'print("Wing")',
          format: ToolDetailFormat.source,
          language: 'python',
        ),
        const ToolDetailBlock(label: 'Prose', text: 'A short explanation.'),
        const ToolDetailBlock(
          label: 'Empty code',
          text: '',
          format: ToolDetailFormat.source,
        ),
      ]) {
        await pump(tester, ActivityDetailSection(block: block));
        final horizontal = find.byWidgetPredicate(
          (widget) => widget is SourceCodeText && !widget.wrap,
        );
        if (block.label == 'Code') {
          await tester.tap(find.byTooltip('Scroll Code horizontally'));
          await tester.pumpAndSettle();
          expect(horizontal, findsOneWidget);
          expect(find.byTooltip('Wrap Code'), findsOneWidget);
          await tester.tap(find.byTooltip('Wrap Code'));
          await tester.pumpAndSettle();
        } else {
          expect(find.byIcon(Icons.wrap_text), findsNothing);
          expect(find.byIcon(Icons.swap_horiz), findsNothing);
        }
        expect(horizontal, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('Markdown viewer exposes wrap only while showing raw content', (
    tester,
  ) async {
    await pump(
      tester,
      ActivityDetailSection(
        block: ToolDetailBlock(
          label: 'Document',
          text: '# Heading\n\n${'A long **paragraph**.\n\n' * 30}',
          markdown: true,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Open Document'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Scroll Document horizontally'), findsNothing);
    await tester.tap(find.byTooltip('Show raw content'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Scroll Document horizontally'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Wrap Document'), findsOneWidget);
    await tester.tap(find.byTooltip('Show formatted content'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Wrap Document'), findsNothing);
    await tester.tap(find.byTooltip('Show raw content'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Wrap Document'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'skill identity, purpose and exact viewer ${brightness.name} $scale',
        (tester) async {
          const source = '/workspace/skills/inspect-build/SKILL.md';
          const raw =
              '---\nname: inspect-build\nversion: 1.0\nauthor: Example\nlicense: MIT\n---\n# Inspect build\n\nRead the actual **error** before changing code.\n';
          String? copied;
          final shared = <String?>[];
          final sharing = Completer<void>();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            shareChannel,
            (call) async {
              if (call.method == 'share') {
                shared.add((call.arguments as Map)['text'] as String);
                await sharing.future;
                return 'dev.fluttercommunity.plus/share/success';
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(shareChannel, null),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: ToolActivityDetailsView(
                    call: call(
                      'skill_view',
                      {'name': 'inspect-build'},
                      {
                        'success': true,
                        'name': 'inspect-build',
                        'description': 'Inspect build output.',
                        'tags': ['build', 'review'],
                        '_source_path': source,
                        'content': raw,
                      },
                    ),
                    onShareResource: (output) {
                      shared.add(output.target);
                      return sharing.future;
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('inspect-build'), findsOneWidget);
          expect(find.text('Inspect build output.'), findsOneWidget);
          expect(find.text('Inspect build'), findsNothing);
          expect(find.text('Result'), findsNothing);
          expect(find.byTooltip('Copy skill instructions'), findsOneWidget);
          await tester.tap(find.byTooltip('Copy skill instructions'));
          await tester.pump();
          expect(copied, raw);
          await tester.tap(find.byTooltip('Open skill instructions'));
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(find.text('Inspect build'), findsOneWidget);
          expect(find.text('Version'), findsOneWidget);
          expect(find.text('1.0'), findsOneWidget);
          expect(find.text('Author'), findsOneWidget);
          expect(find.text('Example'), findsOneWidget);
          expect(find.text('License'), findsNothing);
          expect(find.text('MIT'), findsNothing);
          expect(find.text('build'), findsOneWidget);
          expect(find.text('review'), findsOneWidget);
          expect(find.byTooltip('Copy content'), findsOneWidget);
          await tester.tap(find.text('inspect-build'));
          await tester.pumpAndSettle();
          expect(find.text(source), findsOneWidget);
          await tester.tapAt(const Offset(5, 400));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byTooltip('Show raw content'));
          await tester.tap(find.byTooltip('Show raw content'));
          await tester.pumpAndSettle();
          expect(find.text(raw), findsOneWidget);
          expect(find.text('Version'), findsOneWidget);
          await tester.tap(find.byTooltip('Copy content'));
          await tester.pump();
          expect(copied, raw);
          await tester.tap(find.byTooltip('Share content'));
          await tester.pump();
          expect(shared, [raw]);
          expect(
            tester
                .widget<ActivityDetailAction>(
                  find.ancestor(
                    of: find.byTooltip('Share content'),
                    matching: find.byType(ActivityDetailAction),
                  ),
                )
                .busy,
            isTrue,
          );
          sharing.complete();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('all file headers keep one-line names and exact resource targets', (
    tester,
  ) async {
    const target =
        '/workspace/sources/research/a-very-long-file-name-that-must-stay-on-one-line.md';
    final opened = <String?>[];
    await pump(
      tester,
      ProfileToolCall(
        initiallyExpanded: true,
        call: call('read_file', {'path': target}, {'content': '1|# Report'}),
        onOpenResource: (output) async => opened.add(output.path),
        onShareResource: (_) async {},
      ),
    );
    final names = tester.widgetList<ResourceFilename>(
      find.byType(ResourceFilename),
    );
    expect(names, hasLength(2));
    for (final name in names) {
      final text = tester.widget<Text>(
        find.descendant(of: find.byWidget(name), matching: find.byType(Text)),
      );
      expect(text.data, 'a-very-long-file-name-that-must-stay-on-one-line.md');
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.softWrap, isFalse);
      expect(name.target, target);
    }
    await tester.tap(find.byType(ResourceFilename).last);
    await tester.pumpAndSettle();
    expect(find.text(target), findsOneWidget);
    await tester.tapAt(const Offset(385, 1050));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Preview file'));
    await tester.pumpAndSettle();
    expect(opened, [target]);
  });

  testWidgets('passive short acknowledgement earns no controls', (
    tester,
  ) async {
    await pump(
      tester,
      const ActivityDetailsCard(
        children: [
          ActivityDetailSection(
            block: ToolDetailBlock(label: 'Result', text: 'Patch applied'),
          ),
        ],
      ),
    );
    expect(find.byType(IconButton), findsNothing);
    expect(find.text('Patch applied'), findsOneWidget);
  });
  testWidgets('resource header retains wrap before eye share and exact copy', (
    tester,
  ) async {
    final receipt = '1|${'code ' * 100}';
    await pump(
      tester,
      ToolActivityDetailsView(
        call: call('read_file', {'path': 'report.py'}, {'content': receipt}),
        onOpenResource: (_) async {},
        onShareResource: (_) async {},
      ),
    );
    final buttons = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .map((b) => b.tooltip)
        .toList();
    expect(buttons, [
      'Scroll Result horizontally',
      'Preview file',
      'Share file',
      'Copy content',
    ]);
    expect(find.byTooltip('Open Result'), findsNothing);
    expect(find.byTooltip('Copy Result'), findsNothing);
    await tester.tap(find.byTooltip('Scroll Result horizontally'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Wrap Result'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('overflowing web excerpt has one source eye and one copy', (
    tester,
  ) async {
    await pump(
      tester,
      ToolActivityDetailsView(
        call: call(
          'web_extract',
          {
            'urls': ['https://example.org/report'],
          },
          {
            'results': [
              {
                'url': 'https://example.org/report',
                'title': 'Report',
                'content': 'Paragraph.\n\n' * 40,
              },
            ],
          },
        ),
      ),
    );
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    expect(find.byTooltip('Open source'), findsOneWidget);
    expect(find.byTooltip('Open Report'), findsNothing);
    expect(find.byTooltip('Copy Report'), findsOneWidget);
  });
  testWidgets(
    'identity-only search rows omit empty bodies and repeated paths',
    (tester) async {
      await pump(
        tester,
        ToolActivityDetailsView(
          call: call(
            'search_files',
            {'pattern': 'name', 'output_mode': 'count'},
            {
              'total_count': 5,
              'counts': {'a.py': 2, 'b.py': 3},
            },
          ),
          onOpenResource: (_) async {},
        ),
      );
      expect(find.text('Empty text'), findsNothing);
      expect(find.text('a.py'), findsOneWidget);
      expect(find.text('b.py'), findsOneWidget);
      expect(
        find.byIcon(Icons.copy_outlined),
        findsOneWidget,
      ); // reusable pattern only
      expect(find.byTooltip('Copy Counts'), findsNothing);
    },
  );
  test(
    'unknown native MCP result preserves received text without field promotion',
    () {
      final projected = ToolActivityDetails.project(
        name: 'mcp__tracker__lookup',
        input: {},
        output: {
          'result': 'Two matching notes are available.',
          'structuredContent': {'internal': true},
        },
      );
      expect(
        projected.response.single.copyText,
        'Two matching notes are available.',
      );
      expect(projected.response.single.copyable, isTrue);
    },
  );
  test(
    'embedded tool pixels use received bytes without a remote-file read',
    () async {
      var reads = 0;
      final image = await acquireToolReceiptImage(
        'data:image/png;base64,AQID',
        (_) async {
          reads++;
          return Uint8List(0);
        },
      );
      expect(image.bytes, [1, 2, 3]);
      expect(reads, 0);
    },
  );
  test(
    'tool image admission keeps unsupported and credential URLs closed',
    () async {
      for (final target in [
        'data:text/plain;base64,AQID',
        'javascript:alert(1)',
        'https://user:secret@example.org/image.png',
      ]) {
        await expectLater(
          acquireToolReceiptImage(target, (_) async => Uint8List(0)),
          throwsFormatException,
        );
      }
    },
  );
}
