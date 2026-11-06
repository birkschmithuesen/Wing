import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wing/core/models/context_occupancy.dart';
import 'package:wing/core/widgets/context_ring.dart';
import 'package:wing/core/theme/wing_theme.dart';

const _capture = bool.fromEnvironment('CONTEXT_RING_REVIEW');
const _frame = ValueKey('context-review-frame');

final _sample = {
  'context_used': 132762,
  'context_max': 272000,
  'config_context_length': 272000,
  'context_percent': 49,
  'context_estimated': true,
  'categories': [
    {'id': 'system_prompt', 'label': 'System prompt', 'tokens': 6634},
    {'id': 'tool_definitions', 'label': 'Tool definitions', 'tokens': 10718},
    {'id': 'rules', 'label': 'Rules', 'tokens': 1400},
    {
      'id': 'subagent_definitions',
      'label': 'Subagent definitions',
      'tokens': 1166,
    },
    {'id': 'memory', 'label': 'Memory', 'tokens': 995},
    {'id': 'conversation', 'label': 'Conversation', 'tokens': 111849},
  ],
};

Future<void> _captureFrame(WidgetTester tester, String name) async {
  if (!_capture) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  final paints = find.byKey(const ValueKey('context-ring-paint'));
  final rings = [
    for (var i = 0; i < paints.evaluate().length; i++)
      {
        'label':
            (tester.widget<CustomPaint>(paints.at(i)).painter!
                    as ContextRingPainter)
                .label,
        'x': tester.getRect(paints.at(i)).left * 3,
        'y': tester.getRect(paints.at(i)).top * 3,
        'size': tester.getRect(paints.at(i)).width * 3,
      },
  ];
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/context-ring-review')
        ..createSync(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      await File(
        '${directory.path}/$name.json',
      ).writeAsString(jsonEncode(rings));
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(File(entry.value).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });
  testWidgets('context details can be reached and opened with a keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
        home: const Scaffold(body: Center(child: ContextRing(occupancy: null))),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('context-ring-details')),
    );
    expect(button.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('context-usage-popover')), findsOneWidget);
  });

  test('parses and clamps server occupancy', () {
    final value = ContextOccupancy.fromJson({
      'context_used': 1200,
      'context_max': 1000,
      'context_percent': 125.5,
      'context_estimated': true,
    });
    expect(value, isNotNull);
    expect(value!.used, 1200);
    expect(value.max, 1000);
    expect(value.percent, 100);
    expect(value.estimated, isTrue);
  });

  test('returns unknown for missing, zero, or nonfinite server values', () {
    expect(ContextOccupancy.fromJson(null), isNull);
    expect(
      ContextOccupancy.fromJson({
        'context_used': 1,
        'context_max': 0,
        'context_percent': 1,
      }),
      isNull,
    );
    expect(
      ContextOccupancy.fromJson({
        'context_used': 1,
        'context_max': 10,
        'context_percent': double.nan,
      }),
      isNull,
    );
  });

  testWidgets('unknown context is static, accessible and never reports zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: ContextRing())),
      ),
    );
    expect(find.byType(StudioLoading), findsNothing);
    expect(find.bySemanticsLabel('Context usage unknown'), findsOneWidget);
    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('context-ring-paint')),
    );
    expect((paint.painter! as ContextRingPainter).progress, isNull);
    await tester.tap(find.byKey(const ValueKey('context-ring-details')));
    await tester.pumpAndSettle();
    expect(find.text('Context usage unknown'), findsOneWidget);
    expect(find.textContaining('0 percent'), findsNothing);
  });

  testWidgets('tap reveals exact server usage and its estimate qualifier', (
    tester,
  ) async {
    final occupancy = ContextOccupancy(
      used: 800,
      max: 1000,
      percent: 80,
      estimated: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: ContextRing(occupancy: occupancy)),
        ),
      ),
    );
    expect(
      find.bySemanticsLabel(
        'Approximately 800 of 1000 tokens, 80 percent used',
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('context-ring-paint'))),
      const Size.square(32),
    );
    await tester.tap(find.byKey(const ValueKey('context-ring-details')));
    await tester.pumpAndSettle();
    expect(find.text('800 / 1,000'), findsOneWidget);
    expect(find.text('~80% full'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byKey(const ValueKey('context-ring-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('context-usage-popover')), findsNothing);
  });

  testWidgets(
    'context popover stays anchored without dismissing the keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(412, 823);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.reset);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(focusNode: focus),
                  Row(
                    children: [
                      const SizedBox(width: 60),
                      ContextRing(
                        occupancy: ContextOccupancy(
                          used: 94090,
                          max: 272000,
                          percent: 35,
                          estimated: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.byKey(const ValueKey('context-ring-details')));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('context-usage-popover'));
      final ring = tester.getRect(
        find.byKey(const ValueKey('context-ring-paint')),
      );
      final bounds = tester.getRect(card);
      expect(bounds.left, closeTo(ring.left, .1));
      expect(bounds.bottom, closeTo(ring.top - 8, .1));
      expect(bounds.width, lessThanOrEqualTo(320));
      expect(bounds.height, lessThan(200));
      expect(find.byType(AlertDialog), findsNothing);
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.text('94,090 / 272,000'));
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      expect(focus.hasFocus, isTrue);
      await tester.tapAt(
        tester.getTopLeft(find.byType(TextField)) + const Offset(8, 8),
      );
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'occupancy keeps the existing warning thresholds in both themes',
    (tester) async {
      for (final brightness in Brightness.values) {
        final tokens = WingTokens.forBrightness(brightness);
        for (final percent in [0.0, 64.9, 65.0, 84.9, 85.0, 100.0]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              home: Scaffold(
                body: Center(
                  child: ContextRing(
                    occupancy: ContextOccupancy(
                      used: percent.round(),
                      max: 100,
                      percent: percent,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final painter =
              tester
                      .widget<CustomPaint>(
                        find.byKey(const ValueKey('context-ring-paint')),
                      )
                      .painter!
                  as ContextRingPainter;
          expect(painter.progress, percent / 100);
          expect(
            painter.color,
            percent >= 85
                ? tokens.danger
                : percent >= 65
                ? tokens.warning
                : tokens.accent,
          );
        }
      }
    },
  );
  test(
    'category observations are copied and do not replace measured occupancy',
    () {
      final payload = <String, dynamic>{
        ..._sample,
        'categories': [
          for (final category in _sample['categories'] as List)
            Map<String, dynamic>.from(category as Map),
        ],
        'context_used': 150000,
        'context_percent': 55,
      };
      final value = ContextOccupancy.fromJson(payload)!;
      (payload['categories'] as List).add({
        'id': 'mcp',
        'label': 'MCP',
        'tokens': 800,
      });
      expect(value.used, 150000);
      expect(value.percent, 55);
      expect(value.categories, hasLength(6));
      expect(() => value.categories.clear(), throwsUnsupportedError);
      expect(value.withoutCategories().categories, isEmpty);
      expect(value.withoutCategories().used, 150000);
    },
  );

  test(
    'invalid categories are ignored; a zero conversation is a measurement',
    () {
      final value = ContextOccupancy.fromJson({
        ..._sample,
        'categories': [
          {'id': 'conversation', 'label': 'Conversation', 'tokens': 0},
          {'id': 'skills', 'label': 'Skills', 'tokens': -1},
          {'id': 'rules', 'label': 'Rules', 'tokens': double.infinity},
          {'id': '', 'label': 'Unknown', 'tokens': 12},
          {'id': 'mcp', 'tokens': 12},
        ],
      })!;
      expect(value.categories.single.id, 'conversation');
      expect(value.categories.single.tokens, 0);
    },
  );

  testWidgets(
    'keyboard Escape closes details and refresh remains an owner command',
    (tester) async {
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: Scaffold(
            body: Center(child: ContextRing(onRefresh: () => refreshes++)),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('context-usage-popover')), findsNothing);
    },
  );

  testWidgets('unavailable composition can be retried without a fake zero', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: ContextRing(
              error: 'Couldn’t load the context breakdown.',
              onRefresh: () => retries++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('context-ring-details')));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t load the context breakdown.'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry context breakdown'));
    expect(retries, 2); // Open and explicit Retry each forward the intent.
    expect(find.textContaining('0%'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('compact composition in ${brightness.name} at $scale text', (
        tester,
      ) async {
        final size = Size(scale == 1 ? 393 : 320, 844);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          RepaintBoundary(
            key: _frame,
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
                appBar: AppBar(title: const Text('Compare Perth car rental')),
                body: Column(
                  children: [
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'You can drive more than 500 km in total—that’s allowed. The restriction is on where you take the car, not the kilometres accumulated on the odometer.',
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: WingTokens.forBrightness(brightness).raised,
                          borderRadius: WingRadius.card,
                          border: Border.all(
                            color: WingTokens.forBrightness(brightness).border,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('Message Hermes'),
                            ),
                            Row(
                              children: [
                                const IconButton(
                                  onPressed: null,
                                  icon: Icon(Icons.add),
                                ),
                                ContextRing(
                                  occupancy: ContextOccupancy.fromJson(_sample),
                                  compressions: 2,
                                ),
                                const Expanded(
                                  child: Text(
                                    'GPT-6.1 Sol',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                                const IconButton(
                                  onPressed: null,
                                  icon: Icon(Icons.arrow_upward),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('context-ring-details')));
        await tester.pumpAndSettle();
        final panel = tester.getRect(
          find.byKey(const ValueKey('context-usage-popover')),
        );
        expect(panel.left, greaterThanOrEqualTo(16));
        expect(panel.right, lessThanOrEqualTo(size.width - 16));
        expect(panel.top, greaterThanOrEqualTo(16));
        expect(find.text('132,762 / 272,000 (pinned)'), findsOneWidget);
        expect(find.text('~49% full'), findsOneWidget);
        expect(find.text('~111,849'), findsOneWidget);
        expect(
          find.textContaining('2 compressions', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('Conversation'), findsOneWidget);
        final bar = find.byKey(const ValueKey('context-composition-bar'));
        expect(tester.getSize(bar).height, 6);
        expect(tester.getSize(bar).width, greaterThan(200));
        final segments = find.descendant(
          of: bar,
          matching: find.byType(ColoredBox),
        );
        expect(segments, findsNWidgets(6));
        for (var i = 0; i < 6; i++) {
          expect(tester.getSize(segments.at(i)).height, 6);
          expect(tester.getSize(segments.at(i)).width, greaterThan(0));
        }
        expect(tester.takeException(), isNull);
        // The test runner's Ahem glyphs wrap differently from Roboto. Density
        // is checked against the loaded production font during render review.
        if (_capture && scale == 1) expect(panel.height, lessThan(330));
        await _captureFrame(tester, '${brightness.name}-$scale-panel');
        await tester.tap(find.byTooltip('Close context window'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('context-usage-popover')),
          findsNothing,
        );
      });

      testWidgets(
        'percentage lengths share a centered gauge in ${brightness.name} at $scale text',
        (tester) async {
          tester.view.physicalSize = const Size(393, 520);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            RepaintBoundary(
              key: _frame,
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
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final percent in [null, 0, 9, 49, 92, 100])
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 120,
                                child: Text(
                                  percent == null ? 'Unknown' : '$percent%',
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ),
                              ContextRing(
                                occupancy: percent == null
                                    ? null
                                    : ContextOccupancy(
                                        used: percent,
                                        max: 100,
                                        percent: percent.toDouble(),
                                      ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final gauges = find.byKey(const ValueKey('context-ring-paint'));
          expect(gauges, findsNWidgets(6));
          for (var i = 0; i < 6; i++) {
            final gauge = gauges.at(i);
            final button = find.ancestor(
              of: gauge,
              matching: find.byType(IconButton),
            );
            expect(tester.getRect(gauge).center, tester.getRect(button).center);
            expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          }
          await _captureFrame(tester, '${brightness.name}-$scale-rings');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
