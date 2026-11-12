import 'package:wing/core/widgets/source_code_text.dart';
import 'dart:async';
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'package:wing/core/widgets/profile_activity_tabs.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'chat_inline_image_test.dart' show settleImages;
import 'helpers/pump_markdown_widget.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/presentation/tool_call_presentation.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/chat_inline_image.dart';
import 'package:wing/core/widgets/chat_image_preview.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/widgets/activity_time.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/compact_activity_row.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';

void main() {
  testWidgets('countdown uses readable units for long and short delays', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 10, 28);
    for (final entry in <Duration, String>{
      const Duration(days: 3, hours: 2): '3d 2h',
      const Duration(hours: 4, minutes: 5): '4h 5m',
      const Duration(minutes: 2, seconds: 9): '2m 9s',
      const Duration(milliseconds: 1): '1s',
    }.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActivityTime.countdown(
              due: now.add(entry.key),
              wallClock: () => now,
            ),
          ),
        ),
      );
      expect(find.text('Next in ${entry.value}'), findsOneWidget);
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        contains('Scheduled'),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('countdown stops while hidden and never reports negative time', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 10, 28);
    final due = now.add(const Duration(seconds: 5));
    Widget frame(bool visible) => MaterialApp(
      home: Scaffold(
        body: TickerMode(
          enabled: visible,
          child: ActivityTime.countdown(due: due, wallClock: () => now),
        ),
      ),
    );
    await tester.pumpWidget(frame(true));
    expect(find.textContaining('Next in'), findsOneWidget);
    await tester.pumpWidget(frame(false));
    now = now.add(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Next in'), findsOneWidget);
    await tester.pumpWidget(frame(true));
    expect(find.text('Due now'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('live progress wraps in $brightness at $scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(320, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: ProfileToolCall(
                    call: ToolCallPresentation.live(
                      const GatewayToolActivity(
                        toolId: 'mcp-call',
                        name: 'mcp_search',
                        phase: GatewayToolActivityPhase.running,
                        progress: GatewayToolProgress(
                          value: 4,
                          total: 10,
                          percent: 40,
                          message:
                              'Indexing the project files and shared documents',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.text('40% · Indexing the project files and shared documents'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets('short payload keeps copy without a redundant viewer action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: const Scaffold(
          body: ActivityDetailsCard(
            children: [
              ActivityDetailSection(
                block: ToolDetailBlock(
                  label: 'Result',
                  text: 'Patch applied',
                  copyable: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Patch applied'), findsOneWidget);
    expect(find.byTooltip('Copy Result'), findsOneWidget);
    expect(find.byTooltip('Open Result'), findsNothing);
    expect(find.byIcon(Icons.fullscreen), findsNothing);
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
    expect(find.byTooltip('Wrap Result'), findsNothing);
    expect(find.byTooltip('Scroll Result horizontally'), findsNothing);
  });
  const capture = bool.fromEnvironment('CAPTURE_TOOL_RESULTS');
  setUpAll(() async {
    if (!capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final (family, file) in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
      ('monospace', 'DejaVuSansMono.ttf'),
    ]) {
      await (FontLoader(family)..addFont(
            File(
              '$root/$file',
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final variant in ['receipt', 'long', 'failed', 'unconfirmed']) {
        testWidgets(
          'skill receipt without inputs ${brightness.name} $scale $variant',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 1100);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final path = variant == 'long'
                ? 'references/a-very-long-supporting-file-name-for-analytics-collaboration-and-follow-up-planning.md'
                : 'references/analytics-collaboration.md';
            final raw = jsonEncode({
              if (variant != 'unconfirmed') 'success': variant != 'failed',
              if (variant == 'failed')
                'error': 'Batch aborted; changes rolled back.',
              if (variant == 'receipt' || variant == 'long')
                'operations_applied': 1,
              'results': [
                {
                  'name': 'health-coaching',
                  'action': 'patch',
                  'file_path': path,
                  'success': true,
                },
              ],
            });
            final call = ToolCallPresentation.saved(
              TranscriptToolResult.fromRow({
                'role': 'tool',
                'tool_name': 'skill_manage',
                'content': raw,
              }),
            );
            var resourceActions = 0;
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
                    padding: const EdgeInsets.all(16),
                    child: RepaintBoundary(
                      key: const ValueKey('skill-receipt-capture'),
                      child: ColoredBox(
                        color: wingTheme(brightness).scaffoldBackgroundColor,
                        child: ProfileToolCall(
                          call: call,
                          initiallyExpanded: true,
                          onOpenResource: (_) async => resourceActions++,
                          onShareResource: (_) async => resourceActions++,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.textContaining('health-coaching'), findsWidgets);
            expect(find.text(path.split('/').last), findsOneWidget);
            expect(find.text('No input details supplied'), findsNothing);
            expect(find.byTooltip('Preview file'), findsNothing);
            expect(find.byTooltip('Share file'), findsNothing);
            expect(find.byTooltip('Copy health-coaching'), findsNothing);
            expect(resourceActions, 0);
            final outcome = variant == 'failed'
                ? 'Batch failed'
                : variant == 'unconfirmed'
                ? 'Outcome unconfirmed'
                : 'Patched';
            expect(find.text(outcome), findsOneWidget);
            if (variant == 'failed' || variant == 'unconfirmed') {
              expect(find.text('Patched'), findsNothing);
            }
            expect(tester.takeException(), isNull);
            if (capture) {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('skill-receipt-capture')),
              );
              await tester.runAsync(() async {
                final image = await boundary.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/design-previews/skill-receipts/site/renders/${brightness.name}-$scale-$variant.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            await tester.tap(find.text(path.split('/').last));
            await tester.pumpAndSettle();
            expect(find.text(path), findsOneWidget);
            expect(resourceActions, 0);
            await tester.tapAt(const Offset(5, 5));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
      testWidgets('read receipt is compact and formatted ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source =
            '# Project notes\n\n**Current state:** [Review the evidence](docs/evidence.md). '
            '${List.filled(15, 'Only reported facts appear here.').join(' ')}\n\n'
            '${List.generate(40, (i) => '- Record $i: supplied details').join('\n')}\n\nLast received line';
        final receipt = source
            .split('\n')
            .indexed
            .map((line) => '${line.$1 + 1}|${line.$2}')
            .join('\n');
        final outer = ScrollController();
        addTearDown(outer.dispose);
        var opened = 0;
        String? copied;
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
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final call = ToolCallPresentation.live(
          GatewayToolActivity.fromGatewayEvent('tool.complete', {
            'tool_id': 'read-markdown',
            'name': 'read_file',
            'args': {'path': 'trip/README.md', 'offset': 1, 'limit': 44},
            'result': {
              'content': receipt,
              'total_lines': 80,
              'next_offset': 45,
              'truncated': true,
            },
          })!,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(scale == 1 ? 390 : 320, 1100),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  controller: outer,
                  child: RepaintBoundary(
                    key: const ValueKey('read-receipt-capture'),
                    child: ProfileToolCall(
                      call: call,
                      initiallyExpanded: true,
                      onOpenResource: (_) async {
                        opened++;
                      },
                      onShareResource: (_) async {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.settleMarkdown();
        expect(find.byType(MarkdownMessageContent), findsOneWidget);
        expect(
          tester
              .widget<MarkdownMessageContent>(
                find.byType(MarkdownMessageContent),
              )
              .data,
          source,
        );
        expect(find.text('Read content'), findsNothing);
        expect(find.text('Read options'), findsNothing);
        expect(find.text('Offset: 1 · Limit: 44'), findsOneWidget);
        expect(find.byTooltip('Open Raw content'), findsNothing);
        expect(find.byTooltip('Share file'), findsOneWidget);
        await tester.tap(find.byTooltip('Copy content'));
        await tester.pump();
        expect(copied, receipt);
        await tester.pump(const Duration(seconds: 2));
        Future<void> captureRead(String mode) async {
          if (!capture) return;
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('read-receipt-capture')),
            );
            final rendered = await boundary.toImage(pixelRatio: 2);
            final bytes = await rendered.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/tool-results/read-$mode-${brightness.name}-${scale.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            rendered.dispose();
          });
        }

        await captureRead('formatted');
        expect(find.byTooltip('Show Raw content'), findsNothing);
        expect(find.text('Raw content'), findsNothing);
        final viewport = find
            .byKey(const ValueKey('activity-content-scroll'))
            .first;
        expect(tester.getSize(viewport).height, lessThanOrEqualTo(160));
        final offset = outer.offset;
        await tester.drag(viewport, const Offset(0, -120));
        await tester.pumpAndSettle();
        final receiptScroll = tester
            .widget<SingleChildScrollView>(viewport)
            .controller!;
        expect(receiptScroll.offset, greaterThan(0));
        expect(outer.offset, offset);
        receiptScroll.jumpTo(receiptScroll.position.maxScrollExtent);
        await tester.pump();
        expect(opened, 0);
        await captureRead('scrolled');
        await tester.tap(find.byTooltip('Preview file'));
        await tester.pumpAndSettle();
        expect(opened, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('file and image resource actions retain exact owner targets', (
    tester,
  ) async {
    for (final name in [
      'read_file',
      'patch',
      'vision_analyze',
      'image_generate',
    ]) {
      const path = '/workspace/folder/a #%.png';
      ChatOutput? opened;
      ChatOutput? shared;
      final shareDone = Completer<void>();
      final call = ToolCallPresentation.live(
        GatewayToolActivity.fromGatewayEvent('tool.complete', {
          'tool_id': name,
          'name': name,
          'args': name == 'image_generate'
              ? {'prompt': 'A chart'}
              : name == 'vision_analyze'
              ? {'image_url': path, 'question': 'Review it'}
              : {'path': path},
          'result': switch (name) {
            'image_generate' => {'image': path},
            'vision_analyze' => {'success': true, 'analysis': 'Exact receipt'},
            'patch' => {
              'success': true,
              'diff': '--- a/file\n+++ b/file\n+Exact receipt',
            },
            _ => {'content': '1|Exact receipt'},
          },
        })!,
      );
      final pixels = img.Image(width: 4, height: 4);
      final png = Uint8List.fromList(img.encodePng(pixels));
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfileToolCall(
                call: call,
                initiallyExpanded: true,
                loadImage: (_) async => png,
                onOpenResource: (output) async {
                  opened = output;
                },
                onShareResource: (output) async {
                  shared = output;
                  await shareDone.future;
                },
              ),
            ),
          ),
        ),
      );
      await settleImages(tester);
      final image = name == 'vision_analyze' || name == 'image_generate';
      final previewLabel = image ? 'Preview image' : 'Preview file';
      final shareLabel = image ? 'Share image' : 'Share file';
      expect(find.text(previewLabel), findsNothing);
      expect(find.text(shareLabel), findsNothing);
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      await tester.tap(find.byTooltip(previewLabel));
      await settleImages(tester);
      if (image) {
        expect(opened, isNull);
        final viewer = tester.widget<ChatImagePreview>(
          find.byType(ChatImagePreview),
        );
        expect(viewer.bytes, png);
        expect(viewer.uri, isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      } else {
        expect(opened?.path, path);
        expect(opened?.kind, ChatOutputKind.file);
      }
      await tester.tap(find.byTooltip(shareLabel));
      await tester.pump();
      expect(shared?.path, path);
      expect(
        tester
            .widget<IconButton>(
              find
                  .ancestor(
                    of: find.byTooltip(shareLabel),
                    matching: find.byType(IconButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      shareDone.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('resource failures stay readable and actions can be retried', (
    tester,
  ) async {
    final call = ToolCallPresentation.live(
      GatewayToolActivity.fromGatewayEvent('tool.complete', {
        'tool_id': 'failed-share',
        'name': 'read_file',
        'args': {'path': '/workspace/report.py'},
        'result': {'content': '1|print(1)'},
      })!,
    );
    var attempts = 0;
    var shared = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileToolCall(
            call: call,
            initiallyExpanded: true,
            onShareResource: (_) async {
              if (++attempts == 1) throw StateError('Unavailable');
              shared = true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Share file'));
    await tester.pumpAndSettle();
    expect(find.byType(StudioError), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find
                .ancestor(
                  of: find.byTooltip('Share file'),
                  matching: find.byType(IconButton),
                )
                .first,
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byTooltip('Share file'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(shared, isTrue);
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final name in [
        'execute_code',
        'read_file',
        'patch',
        'vision_analyze',
      ]) {
        testWidgets('rich $name receipt in $brightness at $scale', (
          tester,
        ) async {
          tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final (args, result) = switch (name) {
            'execute_code' => (
              {
                'code':
                    'from pathlib import Path\n\nreport = Path("delivery-test.txt")\nlines = report.read_text().splitlines()\nprint(f"Checked {len(lines)} records")',
              },
              {
                'output': 'Checked 7 records\nDelivery test passed',
                'status': 'success',
              },
            ),
            'read_file' => (
              {'path': '/workspace/report.py', 'offset': 1, 'limit': 5},
              {
                'content':
                    '1|from pathlib import Path\n2|\n3|report = Path("delivery-test.txt")\n4|lines = report.read_text().splitlines()\n5|print(len(lines))',
                'total_lines': 80,
                'file_size': 1941,
                'truncated': true,
                'next_offset': 6,
              },
            ),
            'patch' => (
              {
                'path': '/workspace/report.py',
                'old_string': 'print(len(lines))',
                'new_string': 'print(f"Checked {len(lines)} records")',
              },
              {
                'success': true,
                'diff':
                    '--- a/report.py\n+++ b/report.py\n@@ -5 +5 @@\n-print(len(lines))\n+print(f"Checked {len(lines)} records")',
              },
            ),
            _ => (
              {
                'image_url': '/workspace/dashboard.png',
                'question':
                    'Review the dashboard for legibility and clipped text.',
              },
              {
                'success': true,
                'analysis':
                    '## Legibility\nThe headings are readable.\n\n- **Baseline dates:** clearly labelled.\n- The last record is clipped at the right edge.',
              },
            ),
          };
          final call = ToolCallPresentation.live(
            GatewayToolActivity.fromGatewayEvent('tool.complete', {
              'tool_id': name,
              'name': name,
              'args': args,
              'result': result,
              'duration_s': .14,
            })!,
          );
          final image = img.Image(width: 320, height: 140);
          img.fill(image, color: img.ColorRgb8(232, 244, 241));
          img.fillRect(
            image,
            x1: 16,
            y1: 18,
            x2: 304,
            y2: 42,
            color: img.ColorRgb8(90, 128, 131),
          );
          for (var i = 0; i < 5; i++) {
            img.fillRect(
              image,
              x1: 24 + i * 54,
              y1: 68 - i * 4,
              x2: 55 + i * 54,
              y2: 122,
              color: img.ColorRgb8(34, 137, 126),
            );
          }
          final png = Uint8List.fromList(img.encodePng(image));
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
                  padding: const EdgeInsets.all(16),
                  child: RepaintBoundary(
                    key: const ValueKey('rich-receipt-capture'),
                    child: ColoredBox(
                      color: wingTheme(brightness).scaffoldBackgroundColor,
                      child: ProfileToolCall(
                        call: call,
                        initiallyExpanded: true,
                        loadImage: (_) async => png,
                        onOpenResource: (_) async {},
                        onShareResource: (_) async {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await settleImages(tester);
          await tester.settleMarkdown();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // Review the family against one rendered alignment contract, rather
          // than accepting a different spacing/status convention for each tool.
          final cardLeft = tester
              .getTopLeft(find.byType(ToolActivityDetailsView))
              .dx;
          if (name == 'vision_analyze') {
            expect(
              tester.getTopLeft(find.byType(Image)).dx,
              greaterThanOrEqualTo(cardLeft),
            );
          }
          expect(find.text('Completed'), findsOneWidget);
          expect(find.text('Succeeded'), findsNothing);
          final completed = tester.widget<Text>(find.text('Completed'));
          final muted = WingTokens.of(
            tester.element(find.text('Completed')),
          ).muted;
          expect(completed.style?.color, muted);
          expect(
            tester.widget<Icon>(find.byIcon(Icons.check_circle_outline)).color,
            muted,
          );
          for (final block in [
            ...call.activityDetails.request,
            ...call.activityDetails.response,
          ]) {
            if (block.isReadContent) {
              expect(find.byTooltip('Copy content'), findsOneWidget);
              expect(find.text('Raw content'), findsNothing);
              expect(find.byTooltip('Open Raw content'), findsNothing);
              final viewport = find.byType(SourceCodeText);
              expect(tester.getSize(viewport).height, lessThanOrEqualTo(160));
              continue;
            }
            expect(
              find.byTooltip('Copy ${block.label}'),
              block.copyable ? findsOneWidget : findsNothing,
            );
            if (!block.copyable) continue;
            expect(find.text('Copy ${block.label}'), findsNothing);
            expect(
              tester.getTopLeft(find.text(block.label)).dx,
              greaterThanOrEqualTo(cardLeft),
            );
            final headerRow = find
                .ancestor(
                  of: find.text(block.label),
                  matching: find.byType(Row),
                )
                .first;
            final headerFrame = find
                .ancestor(of: headerRow, matching: find.byType(Container))
                .first;
            final rowRect = tester.getRect(headerRow);
            final frameRect = tester.getRect(headerFrame);
            expect(rowRect.left, greaterThanOrEqualTo(frameRect.left));
            expect(rowRect.top, greaterThanOrEqualTo(frameRect.top));
            expect(rowRect.bottom, lessThanOrEqualTo(frameRect.bottom));
            final copyButton = find
                .ancestor(
                  of: find.byTooltip('Copy ${block.label}'),
                  matching: find.byType(IconButton),
                )
                .first;
            expect(tester.getSize(copyButton).width, greaterThanOrEqualTo(32));
            expect(tester.getSize(copyButton).height, greaterThanOrEqualTo(32));
            expect(
              tester.getRect(copyButton).right,
              lessThanOrEqualTo(frameRect.right),
            );
            final body = block.markdown
                ? find.byWidgetPredicate(
                    (widget) =>
                        widget is MarkdownMessageContent &&
                        widget.data == block.text,
                  )
                : find.byWidgetPredicate(
                    (widget) =>
                        (widget is SourceCodeText &&
                            widget.text == block.text) ||
                        (widget is SelectableText &&
                            widget.textSpan?.toPlainText() == block.text),
                  );
            expect(tester.getTopLeft(body).dx, greaterThanOrEqualTo(cardLeft));
            final contentSurface = find
                .ancestor(of: body, matching: find.byType(ColoredBox))
                .first;
            expect(
              tester.getTopLeft(body).dy,
              greaterThanOrEqualTo(tester.getTopLeft(contentSurface).dy),
            );
            final visibleBody = tester.widget(body) is SourceCodeText
                ? body
                : find
                      .ancestor(
                        of: body,
                        matching: find.byKey(
                          const ValueKey('activity-content-scroll'),
                        ),
                      )
                      .first;
            expect(
              tester.getBottomLeft(visibleBody).dy,
              lessThanOrEqualTo(tester.getBottomLeft(contentSurface).dy),
            );
            expect(
              tester.getTopRight(body).dx,
              lessThanOrEqualTo(tester.getTopRight(contentSurface).dx),
            );
          }
          if (name == 'read_file') {
            expect(find.byTooltip('Copy Read options'), findsNothing);
            expect(find.byTooltip('Open Read options'), findsNothing);
            expect(find.text('Offset: 1 · Limit: 5'), findsOneWidget);
            if (scale == 1 && capture) {
              // Ahem substitutes square glyphs in uncaptured widget tests;
              // the ordinary inline fit is checked with actual Roboto renders.
              expect(find.text('Read options'), findsNothing);
              expect(
                tester.getSize(find.byType(ToolActivityDetailsView)).height,
                lessThan(400),
              );
            }
          }
          if (name == 'execute_code') {
            expect(find.text('Exit 0'), findsNothing);
            final card = find.byType(ToolActivityDetailsView);
            final leading = find.byIcon(Icons.code_rounded).first;
            expect(tester.getTopLeft(card).dx, tester.getTopLeft(leading).dx);
            String? copied;
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
            await tester.tap(find.byTooltip('Copy Code'));
            await tester.pump();
            expect(copied, args['code']);
            expect(find.byTooltip('Copy Code: copied'), findsOneWidget);
            await tester.pump(const Duration(seconds: 2));
          }
          if (capture) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('rich-receipt-capture')),
            );
            await tester.runAsync(() async {
              final rendered = await boundary.toImage();
              final bytes = await rendered.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/tool-results/activity-$name-${brightness.name}-${scale.toInt()}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              rendered.dispose();
            });
          }
        });
      }
    }
  }

  for (final advisory in [false, true]) {
    testWidgets(
      'long prose scrolls as Markdown without a Preview row advisory=$advisory',
      (tester) async {
        final text =
            '# Findings\n\n${List.generate(20, (i) => '- Record $i').join('\n')}';
        final call = ToolCallPresentation.live(
          GatewayToolActivity.fromGatewayEvent('tool.complete', {
            'tool_id': 'long',
            'name': 'skill_view',
            'args': {'name': 'record-review'},
            'result': advisory
                ? '${jsonEncode({'content': text})}\n\n'
                      '[Tool loop warning: idempotent_no_progress_warning; count=2; '
                      'skill_view returned the same result 2 times. Use the result '
                      'already provided or change the query instead of repeating '
                      'it unchanged.]'
                : {'content': text},
          })!,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProfileToolCall(call: call, initiallyExpanded: true),
              ),
            ),
          ),
        );
        await tester.settleMarkdown();
        expect(find.text('Preview'), findsNothing);
        expect(find.text('Full text'), findsNothing);
        expect(find.byTooltip('Expand Result'), findsNothing);
        expect(find.byType(MarkdownMessageContent), findsOneWidget);
        expect(
          tester
              .widget<MarkdownMessageContent>(
                find.byType(MarkdownMessageContent),
              )
              .data,
          text,
        );
        final region = find.descendant(
          of: find
              .ancestor(
                of: find.byType(MarkdownMessageContent),
                matching: find.byType(ActivityDetailSection),
              )
              .first,
          matching: find.byKey(const ValueKey('activity-content-scroll')),
        );
        expect(tester.getSize(region).height, lessThanOrEqualTo(160));
        await tester.drag(region, const Offset(0, -100));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SingleChildScrollView>(region).controller!.offset,
          greaterThan(0),
        );
        String? copied;
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
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.ensureVisible(find.byTooltip('Copy skill instructions'));
        await tester.tap(find.byTooltip('Copy skill instructions'));
        await tester.pump();
        expect(copied, text);
        await tester.pump(const Duration(seconds: 2));
        await tester.ensureVisible(find.byTooltip('Open skill instructions'));
        await tester.tap(find.byTooltip('Open skill instructions'));
        await tester.pumpAndSettle();
        expect(
          find.byType(MarkdownMessageContent).evaluate().length,
          greaterThanOrEqualTo(1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'tool icons describe the activity instead of defaulting to commands',
    (tester) async {
      final expected = <String, IconData>{
        'hindsight_retain': Icons.psychology_outlined,
        'hindsight_recall': Icons.psychology_outlined,
        'hindsight_reflect': Icons.psychology_outlined,
        'memory': Icons.psychology_outlined,
        'execute_code': Icons.code_rounded,
        'terminal': Icons.terminal_rounded,
        'read_file': Icons.description_outlined,
        'write_file': Icons.edit_note_outlined,
        'edit_file': Icons.edit_note_outlined,
        'patch': Icons.difference_outlined,
        'list_files': Icons.folder_open_outlined,
        'search_files': Icons.find_in_page_outlined,
        'web_search': Icons.search,
        'browser_navigate': Icons.language,
        'browser_click': Icons.touch_app_outlined,
        'browser_type': Icons.keyboard_outlined,
        'skill_view': Icons.menu_book_outlined,
        'image_generate': Icons.image_outlined,
        'vision_analyze': Icons.image_search_outlined,
        'todo_list': Icons.playlist_add_check_outlined,
        'delegate_task': Icons.account_tree_outlined,
        'cronjob': Icons.calendar_month_outlined,
        'new_custom_tool': Icons.extension_outlined,
        // A readable label must not disguise the underlying tool's purpose.
        'tool_call': Icons.extension_outlined,
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (final name in expected.keys)
                    ProfileToolCall(
                      key: ValueKey(name),
                      call: ToolCallPresentation.live(
                        GatewayToolActivity.fromGatewayEvent('tool.complete', {
                          'tool_id': name,
                          'name': name,
                          if (name == 'tool_call')
                            'labels': [
                              {'text': 'Read file', 'name': 'connector.read'},
                            ],
                        })!,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      for (final entry in expected.entries) {
        final row = tester.widget<CompactActivityRow>(
          find.descendant(
            of: find.byKey(ValueKey(entry.key)),
            matching: find.byType(CompactActivityRow),
          ),
        );
        expect(
          tester.widget<Icon>(find.byWidget(row.icon)).icon,
          entry.value,
          reason: entry.key,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final saved in [false, true]) {
        testWidgets(
          'code and memory have visible second lines in $brightness at $scale saved=$saved',
          (tester) async {
            tester.view.physicalSize = const Size(360, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final calls = [
              for (final (id, name, args) in [
                (
                  'code',
                  'execute_code',
                  {'code': '# Compare rental prices\nprint(prices)'},
                ),
                (
                  'retain',
                  'hindsight_retain',
                  {
                    'content':
                        'Remember the booking\nand cancellation deadline.',
                  },
                ),
                ('missing-code', 'execute_code', <String, String>{}),
                ('missing-retain', 'hindsight_retain', <String, String>{}),
              ])
                saved
                    ? ToolCallPresentation.saved(
                        TranscriptToolResult.fromRow({
                          'role': 'tool',
                          'tool_call_id': id,
                          'tool_name': name,
                          'args': args,
                          'content': '{"success":true}',
                          'duration_s': 2.1,
                        }),
                      )
                    : ToolCallPresentation.live(
                        GatewayToolActivity.fromGatewayEvent('tool.complete', {
                          'tool_id': id,
                          'name': name,
                          'args': args,
                          'result': {'success': true},
                          'duration_s': 2.1,
                        })!,
                      ),
            ];
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
                    padding: const EdgeInsets.all(16),
                    child: RepaintBoundary(
                      key: const ValueKey('code-memory-capture'),
                      child: ColoredBox(
                        color: wingTheme(brightness).scaffoldBackgroundColor,
                        child: Column(
                          children: [
                            for (final call in calls)
                              ProfileToolCall(call: call),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            expect(
              find.text('# Compare rental prices print(prices)'),
              findsOneWidget,
            );
            expect(
              find.text('Remember the booking and cancellation deadline.'),
              findsOneWidget,
            );
            expect(find.text('No input details supplied'), findsNWidgets(2));
            final rows = tester
                .widgetList<CompactActivityRow>(find.byType(CompactActivityRow))
                .toList();
            expect(rows, hasLength(4));
            final heights = <double>[];
            for (final row in rows) {
              expect(row.lines, hasLength(1));
              final title = find.byWidget(row.title);
              final subtitle = find.byWidget(row.lines.single);
              expect(tester.getSize(subtitle).height, greaterThan(0));
              expect(
                tester.getTopLeft(subtitle).dy,
                greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
              );
              heights.add(tester.getSize(find.byWidget(row)).height);
            }
            expect(
              heights.every((height) => (height - heights.first).abs() < .01),
              isTrue,
            );
            if (capture && saved) {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('code-memory-capture')),
              );
              await tester.runAsync(() async {
                final image = await boundary.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/tool-results/code-memory-${brightness.name}-$scale.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            expect(tester.takeException(), isNull);
          },
        );
        testWidgets(
          'skill batch results in $brightness at $scale saved=$saved',
          (tester) async {
            tester.view.physicalSize = const Size(360, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final raw = jsonEncode({
              'success': true,
              'operations_applied': 4,
              'results': [
                for (final file in [
                  null,
                  'references/accommodation-search-quality.md',
                  'references/flight-search-quality.md',
                  'references/trip-preferences.md',
                ])
                  {
                    'name': 'business-trip-policy-research',
                    'action': 'patch',
                    'file_path': file,
                    'success': true,
                  },
              ],
            });
            final args = {
              'operations': [
                for (final (index, file) in [
                  null,
                  'references/accommodation-search-quality.md',
                  'references/flight-search-quality.md',
                  'references/trip-preferences.md',
                ].indexed)
                  {
                    'name': 'business-trip-policy-research',
                    'action': 'patch',
                    'file_path': ?file,
                    'old_string': 'Previous policy $index',
                    'new_string': 'Updated policy $index',
                  },
              ],
            };
            final call = saved
                ? ToolCallPresentation.saved(
                    TranscriptToolResult.fromRow({
                      'role': 'tool',
                      'tool_name': 'skill_manage',
                      'args': args,
                      'content': raw,
                    }),
                  )
                : ToolCallPresentation.live(
                    GatewayToolActivity.fromGatewayEvent('tool.complete', {
                      'tool_id': 'skill-batch',
                      'name': 'skill_manage',
                      'args': args,
                      'result': raw,
                    })!,
                  );
            String? copied;
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              (method) async {
                if (method.method == 'Clipboard.setData') {
                  copied = (method.arguments as Map)['text'] as String;
                }
                return null;
              },
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(SystemChannels.platform, null),
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
                    padding: const EdgeInsets.all(16),
                    child: RepaintBoundary(
                      key: const ValueKey('skill-results-capture'),
                      child: ColoredBox(
                        color: wingTheme(brightness).scaffoldBackgroundColor,
                        child: ProfileToolCall(call: call),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('Managed skills'));
            await tester.pumpAndSettle();
            expect(find.text('Result'), findsNothing);
            expect(call.activityDetails.response, hasLength(4));
            expect(call.activityDetails.metadata, ['Operations applied: 4']);
            expect(find.text('Operations applied: 4'), findsOneWidget);
            expect(call.activityDetails.request, hasLength(8));
            for (final detail in call.activityDetails.request) {
              expect(detail.copyable, isTrue);
              expect(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is SourceCodeText && widget.text == detail.text,
                ),
                findsOneWidget,
              );
              expect(
                detail.label == 'business-trip-policy-research' ||
                    detail.facts.contains('business-trip-policy-research'),
                isTrue,
              );
              expect(detail.facts, contains('patch'));
              final size = tester.getSize(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is SourceCodeText && widget.text == detail.text,
                ),
              );
              expect(size.width, greaterThan(0));
              expect(size.height, greaterThan(0));
            }
            expect(find.textContaining('Success: true'), findsNothing);
            if (capture && saved) {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('skill-results-capture')),
              );
              await tester.runAsync(() async {
                final image = await boundary.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/tool-results/${brightness.name}-$scale.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            await tester.ensureVisible(find.text('Raw details'));
            await tester.tap(find.text('Raw details'));
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.byTooltip('Copy Output'));
            await tester.tap(find.byTooltip('Copy Output'));
            expect(copied, raw);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'completed tool rows show exceptions only and retain delivered durations',
    (tester) async {
      final calls = [
        ToolCallPresentation.live(
          GatewayToolActivity.fromGatewayEvent('tool.complete', {
            'tool_id': 'skill',
            'name': 'skill_view',
            'result': {'success': true, 'status': 'unchanged'},
          })!,
        ),
        ToolCallPresentation.live(
          GatewayToolActivity.fromGatewayEvent('tool.complete', {
            'tool_id': 'search',
            'name': 'search_files',
            'result': {'matches': 2},
            'duration_s': .7,
          })!,
        ),
        ToolCallPresentation.live(
          GatewayToolActivity.fromGatewayEvent('tool.complete', {
            'tool_id': 'vision',
            'name': 'vision_analyze',
            'result': {'success': true, 'analysis': 'Area confirmed'},
          })!,
        ),
        ToolCallPresentation.live(
          GatewayToolActivity.fromGatewayEvent('tool.complete', {
            'tool_id': 'page',
            'name': 'web_extract',
            'result': {
              'results': [
                {
                  'title': '404 Page Not Found',
                  'content': '404 Page Not Found',
                },
              ],
            },
          })!,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [for (final call in calls) ProfileToolCall(call: call)],
            ),
          ),
        ),
      );
      expect(find.text('Returned a 404 page'), findsOneWidget);
      expect(find.text('Completed'), findsNothing);
      expect(find.text('Succeeded'), findsNothing);
      expect(find.text('Already loaded'), findsNothing);
      expect(find.text('700 ms'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(3));
    },
  );

  testWidgets('unknown tool timing is explicit and never reads a clock', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActivityTime(
            showUnavailable: true,
            clock: () => throw StateError('No backend start'),
            wallClock: () => throw StateError('No backend start'),
          ),
        ),
      ),
    );
    expect(find.text('—'), findsOneWidget);
    expect(
      find.byTooltip('No backend timing available for this call'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('—'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'backend epoch counters tick, clamp clock skew and end on backend duration',
    (tester) async {
      var now = DateTime.fromMillisecondsSinceEpoch(1002000);
      Future<void> show({
        double? start,
        double? duration,
        bool visible = true,
      }) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TickerMode(
              enabled: visible,
              child: ActivityTime(
                subject: 'Agent',
                backendStartedAt: start,
                durationSeconds: duration,
                wallClock: () => now,
              ),
            ),
          ),
        ),
      );
      await show();
      expect(find.byType(Text), findsNothing);
      await show(start: 1000);
      expect(find.text('≈ 2.0 s'), findsOneWidget);
      now = DateTime.fromMillisecondsSinceEpoch(1005000);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('≈ 5.0 s'), findsOneWidget);
      await show(start: 1000, visible: false);
      now = DateTime.fromMillisecondsSinceEpoch(1010000);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('≈ 5.0 s'), findsOneWidget);
      await show(start: 1012);
      expect(find.text('≈ 0 ms'), findsOneWidget);
      await show(start: 1000, duration: 2.75);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('2.8 s'), findsOneWidget);
      await show();
      expect(find.byType(Text), findsNothing);
    },
  );
  testWidgets(
    'an open call stays open when a live completion becomes saved history',
    (tester) async {
      var saved = false;
      var complete = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: SingleChildScrollView(
                  child: ProfileActivitySection(
                    label: 'Activity',
                    initiallyExpanded: true,
                    detailsBuilder: (_) => ProfileActivityTabs(
                      tabs: [
                        ProfileActivityTab(
                          id: 'timeline',
                          label: 'Timeline',
                          child: Column(
                            children: [
                              if (saved)
                                ProfileToolActivity(
                                  results: [
                                    TranscriptToolResult.fromRow({
                                      'id': 17,
                                      'role': 'tool',
                                      'tool_name': 'read_file',
                                      'tool_call_id': 'file-call',
                                      'content': jsonEncode({
                                        'content': 'Readable file content',
                                      }),
                                      'duration_s': .42,
                                    }),
                                  ],
                                )
                              else
                                ProfileLiveToolActivity(
                                  activities: [
                                    GatewayToolActivity(
                                      toolId: 'file-call',
                                      name: 'read_file',
                                      phase: complete
                                          ? GatewayToolActivityPhase.completed
                                          : GatewayToolActivityPhase.running,
                                      result: complete
                                          ? jsonEncode({
                                              'content':
                                                  'Readable file content',
                                            })
                                          : null,
                                      durationSeconds: complete ? .42 : null,
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Reading file'));
      await tester.pumpAndSettle();
      expect(find.text('Raw details'), findsOneWidget);
      update(() => complete = true);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText &&
              widget.text == 'Readable file content',
        ),
        findsOneWidget,
      );
      update(() => saved = true);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText &&
              widget.text == 'Readable file content',
        ),
        findsOneWidget,
      );
      expect(find.text('420 ms'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'counter ticks only for a received start, pauses hidden and final duration wins',
    (tester) async {
      var now = const Duration(seconds: 10);
      Future<void> show({
        Duration? start,
        double? finalTime,
        bool visible = true,
      }) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TickerMode(
              enabled: visible,
              child: ActivityTime(
                startedAt: start,
                durationSeconds: finalTime,
                clock: () => now,
              ),
            ),
          ),
        ),
      );
      await show();
      expect(find.byType(Text), findsNothing);
      await show(start: const Duration(seconds: 10));
      expect(find.text('≈ 0 ms'), findsOneWidget);
      now = const Duration(seconds: 12);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('≈ 2.0 s'), findsOneWidget);
      await show(start: const Duration(seconds: 10), visible: false);
      now = const Duration(seconds: 20);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('≈ 2.0 s'), findsOneWidget);
      await show(start: const Duration(seconds: 10));
      expect(find.text('≈ 10 s'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      now = const Duration(seconds: 30);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('≈ 10 s'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('≈ 20 s'), findsOneWidget);
      await show(start: const Duration(seconds: 10), finalTime: .574);
      now = const Duration(seconds: 100);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('574 ms'), findsOneWidget);
      expect(find.text('≈ 90 s'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'vision details and exact copy are usable in $brightness at scale $scale',
        (tester) async {
          tester.view.physicalSize = const Size(360, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          const args =
              '{"image_url":"/tmp/map.png","question":"Where can I drive?"}';
          const output =
              '{"success":true,"analysis":"Inside the yellow region."}';
          final call = ToolCallPresentation.live(
            GatewayToolActivity.fromGatewayEvent('tool.complete', {
              'tool_id': 'vision',
              'name': 'vision_analyze',
              'args': args,
              'result': output,
              'duration_s': .574,
            })!,
          );
          final images = <String>[];
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (method) async {
              if (method.method == 'Clipboard.setData') {
                copied = (method.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
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
                  padding: const EdgeInsets.all(16),
                  child: ProfileToolCall(
                    call: call,
                    loadImage: (target) async {
                      images.add(target);
                      return img.encodePng(img.Image(width: 12, height: 12));
                    },
                  ),
                ),
              ),
            ),
          );
          expect(images, isEmpty);
          expect(find.text('574 ms'), findsOneWidget);
          await tester.tap(find.text('Analyzed image'));
          await settleImages(tester);
          expect(
            tester.widget<ChatInlineImage>(find.byType(ChatInlineImage)).target,
            '/tmp/map.png',
          );
          expect(images, ['/tmp/map.png']);
          await tester.settleMarkdown();
          for (final text in [
            'Where can I drive?',
            'Inside the yellow region.',
          ]) {
            final body = find.byWidgetPredicate(
              (widget) =>
                  widget is MarkdownMessageContent && widget.data == text,
            );
            expect(body, findsOneWidget);
            expect(tester.getSize(body).height, greaterThan(0));
            expect(
              find.descendant(
                of: body,
                matching: find.text(text, findRichText: true),
              ),
              findsOneWidget,
            );
          }
          await tester.ensureVisible(find.text('Raw details'));
          await tester.tap(find.text('Raw details'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byTooltip('Copy Output'));
          await tester.tap(find.byTooltip('Copy Output'));
          expect(copied, output);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
