import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/presentation/tool_call_presentation.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';

import 'helpers/pump_markdown_widget.dart';
import 'chat_inline_image_test.dart' show settleImages;

void main() {
  const capture = bool.fromEnvironment('CAPTURE_ACTIVITY_CATALOG');
  final fixture =
      jsonDecode(
            File('test/fixtures/stock_activity_shapes.json').readAsStringSync(),
          )
          as Map;
  final cases = (fixture['cases'] as List).cast<Map>();
  final actualNames = cases.map((v) => v['name']).toSet();
  for (final name in ['edit_file', 'list_files', 'tool_get', 'cronjob']) {
    cases.add({
      'id': 'unsupported-$name',
      'name': name,
      'input': null,
      'output': null,
    });
  }
  final png = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 32, height: 24)..clear(img.ColorRgb8(50, 100, 110)),
    ),
  );
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
  test(
    'stock source corpus accounts for supported contracts and dormant captions',
    () {
      expect(
        actualNames,
        containsAll([
          'read_file',
          'write_file',
          'patch',
          'search_files',
          'terminal',
          'execute_code',
          'browser_exec',
          'image_generate',
          'vision_analyze',
          'browser_navigate',
          'browser_snapshot',
          'browser_click',
          'browser_type',
          'web_search',
          'web_extract',
          'desktop_preview',
          'drive_preview',
          'memory',
          'skill_view',
          'skill_manage',
          'todo_list',
          'delegate_task',
          'cronjob_manage',
          'session_search',
          'tool_search',
          'tool_describe',
          'tool_call',
          'clarify',
        ]),
      );
      expect(
        cases.map((c) => c['name']).toSet(),
        containsAll([
          'edit_file',
          'list_files',
          'browser_fill',
          'browser_take_screenshot',
          'tool_get',
          'cronjob',
        ]),
      );
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'all stock receipt shapes remain compact and readable ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          for (final item in cases) {
            final name = item['name'] as String;
            final call = ToolCallPresentation.live(
              GatewayToolActivity.fromGatewayEvent('tool.complete', {
                'tool_id': item['id'],
                'name': name,
                'args': item['input'],
                'result': item['output'],
              })!,
            );
            final key = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: key,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: wingTheme(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(call.title),
                            ToolActivityDetailsView(
                              key: ValueKey(item['id']),
                              call: call,
                              loadImage: (_) => Future.value(png),
                              onOpenResource: (_) async {},
                              onShareResource: (_) async {},
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.settleMarkdown();
            await settleImages(tester);
            expect(
              tester.takeException(),
              isNull,
              reason: '${item['id']} ${brightness.name} $scale',
            );
            expect(find.text('Options'), findsNothing, reason: '${item['id']}');
            expect(find.text('Read options'), findsNothing);
            expect(find.text('Preview'), findsNothing);
            expect(find.byIcon(Icons.fullscreen), findsNothing);
            for (final button in tester.widgetList<IconButton>(
              find.byType(IconButton),
            )) {
              expect(
                button.tooltip,
                isNotEmpty,
                reason: '${item['id']} unnamed action',
              );
              expect(button.icon, isNot(isA<Text>()));
            }
            final content = find.byKey(
              const ValueKey('activity-content-scroll'),
            );
            for (final region in content.evaluate()) {
              final box = region.renderObject! as RenderBox;
              expect(
                box.size.height,
                lessThanOrEqualTo(160),
                reason: '${item['id']} unbounded content',
              );
            }
            if (capture) {
              await tester.runAsync(() async {
                final image =
                    await (key.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/activity-catalog/${brightness.name}-${scale.toInt()}/${item['id']}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(data!.buffer.asUint8List());
                image.dispose();
              });
            }
          }
        },
      );
    }
  }
}
