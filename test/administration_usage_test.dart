import 'package:wing/core/widgets/studio_error.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/analytics_content.dart';
import 'package:wing/core/services/usage_analytics.dart';
import 'package:wing/core/services/usage_analytics_session.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/screens/administration/usage_charts.dart';
import 'support/administration_fixture.dart';
import 'package:wing/core/models/models_dev_prices.dart';

Map<String, dynamic> _astra() => {
  'model': 'gpt-6-astra',
  'provider': 'openai-codex',
  'input_tokens': 250000,
  'cache_read_tokens': 1000000,
  'output_tokens': 30000,
  'reasoning_tokens': 20000,
  'estimated_cost': 0,
  'sessions': 2,
  'api_calls': 12,
};
Map<String, dynamic> _sol() => {
  'model': 'gpt-5.6-sol',
  'provider': 'openai-codex',
  'input_tokens': 50000,
  'cache_read_tokens': 100000,
  'output_tokens': 10000,
  'estimated_cost': 0,
  'sessions': 1,
  'api_calls': 3,
};
Map<String, dynamic> _paid() => {
  'model': 'Paid API model',
  'provider': 'openai',
  'input_tokens': 100000,
  'output_tokens': 20000,
  'estimated_cost': 3,
  'sessions': 1,
  'api_calls': 4,
};

Map<String, dynamic> dailyData() {
  final today = DateTime.now().toUtc();
  return {
    'daily': [
      for (var i = 0; i < 6; i++)
        {
          'day': today
              .subtract(Duration(days: i))
              .toIso8601String()
              .substring(0, 10),
          'input_tokens': 12000 + i * 1000,
          'cache_read_tokens': 35000 + i * i * 4000,
          'output_tokens': 4000 + i * 2000,
        },
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('CAPTURE_USAGE');
  setUpAll(() async {
    if (!capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$root/${font.value}',
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });

  late AdministrationFixture fixture;
  late List<Map<String, dynamic>> rows;
  bool offline = false;
  setUp(() {
    fixture = AdministrationFixture('Demo server');
    addTearDown(fixture.server.close);
    rows = [_sol(), _astra()];
    offline = false;
    fixture.override = withSubscriptionModelOptions((
      method,
      path,
      query,
      body,
    ) async {
      if (offline) throw StateError('Offline');
      if (path == 'analytics/usage') return dailyData();
      return {'models': rows, 'period_days': int.parse(query['days']!)};
    });
  });

  Future<void> show(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
    double scale = 1,
    bool settle = true,
    bool reducedMotion = false,
  }) async {
    tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reducedMotion,
          ),
          child: RepaintBoundary(
            key: const ValueKey('usage-capture'),
            child: child!,
          ),
        ),
        home: AnalyticsPage(profile: fixture.server.profile('personal')),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('usage-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/usage-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    final scrollable = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
          ),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    if (target.evaluate().isEmpty) {
      position.jumpTo(0);
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      // A drag over a chart can belong to its local scroll frame. Advance the
      // page's own position when locating an off-screen control instead.
      for (
        var attempts = 0;
        target.evaluate().isEmpty && attempts < 80;
        attempts++
      ) {
        position.jumpTo(
          (position.pixels + 180).clamp(0, position.maxScrollExtent),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 250));
      }
      expect(target, findsOneWidget);
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await reveal(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
  }

  Future<Map<String, Rect>> sectionGeometry(
    WidgetTester tester, {
    List<String> extra = const [],
  }) async {
    final outer = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(outer).position;
    position.jumpTo(0);
    await tester.pump();
    final result = <String, Rect>{};
    for (final id in [
      'usage-calendar-slot',
      'usage-breakdown-group',
      'usage-breakdown-slot',
      'usage-trend-group',
      'usage-trend-slot',
      ...extra,
    ]) {
      final target = find.byKey(ValueKey(id));
      for (
        var attempts = 0;
        target.evaluate().isEmpty && attempts < 30;
        attempts++
      ) {
        position.jumpTo(
          (position.pixels + 150).clamp(0, position.maxScrollExtent),
        );
        await tester.pump();
      }
      expect(target, findsOneWidget);
      result[id] = tester.getRect(target).shift(Offset(0, position.pixels));
    }
    position.jumpTo(0);
    await tester.pump();
    return result;
  }

  void expectSameGeometry(
    Map<String, Rect> actual,
    Map<String, Rect> expected,
  ) {
    for (final id in expected.keys) {
      expect(
        actual[id]!.top,
        closeTo(expected[id]!.top, .001),
        reason: '$id top',
      );
      expect(
        actual[id]!.height,
        closeTo(expected[id]!.height, .001),
        reason: '$id height',
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final yearFirst in [false, true]) {
        testWidgets(
          'analytics sections stay in place ${brightness.name} $scale yearFirst=$yearFirst',
          (tester) async {
            final year = Completer<Map<String, dynamic>>();
            final models = Completer<Map<String, dynamic>>();
            final daily = Completer<Map<String, dynamic>>();
            fixture.override = (_, path, query, _) => path == 'analytics/models'
                ? models.future
                : query['days'] == '365'
                ? year.future
                : daily.future;
            await show(
              tester,
              brightness: brightness,
              scale: scale,
              settle: false,
            );
            final original = await sectionGeometry(tester);
            expect(find.text('Tokens'), findsWidgets);
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(find.textContaining('Loading activity year'), findsNothing);
            final header = tester.getRect(
              find.byKey(const ValueKey('studio-loading-slot')),
            );
            await snapshot(tester, 'loading-${brightness.name}-$scale');
            if (yearFirst) {
              year.complete(dailyData());
            } else {
              models.complete({
                'models': [_paid()..['cache_read_tokens'] = 0],
              });
              await tester.pump();
              await tester.pump();
              expect(
                find.descendant(
                  of: find.byKey(const ValueKey('usage-token-total')),
                  matching: find.text('120K'),
                ),
                findsOneWidget,
              );
              expect(find.text('USD 3.00'), findsOneWidget);
              expectSameGeometry(await sectionGeometry(tester), original);
              await snapshot(tester, 'models-first-${brightness.name}-$scale');
              daily.complete(dailyData());
            }
            await tester.pump();
            await tester.pump();
            expectSameGeometry(await sectionGeometry(tester), original);
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(
              tester.getRect(find.byKey(const ValueKey('studio-loading-slot'))),
              header,
            );
            await snapshot(
              tester,
              'partial-${brightness.name}-$scale-yearFirst-$yearFirst',
            );
            if (yearFirst) {
              models.complete({
                'models': [
                  _paid(),
                  for (var i = 0; i < 8; i++) _paid()..['model'] = 'Model $i',
                ],
              });
              daily.complete(dailyData());
            } else {
              year.complete(dailyData());
            }
            await tester.pumpAndSettle();
            expectSameGeometry(await sectionGeometry(tester), original);
            expect(find.byType(StudioLoading), findsNothing);
            expect(
              tester.getRect(find.byKey(const ValueKey('studio-loading-slot'))),
              header,
            );
            await snapshot(
              tester,
              'settled-${brightness.name}-$scale-yearFirst-$yearFirst',
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'analytics Refresh holds stable content through success and failure ${brightness.name} $scale',
        (tester) async {
          await show(tester, brightness: brightness, scale: scale);
          final original = await sectionGeometry(tester);
          final year = Completer<Map<String, dynamic>>();
          final period = Completer<Map<String, dynamic>>();
          fixture.override = (_, path, query, _) =>
              path == 'analytics/usage' && query['days'] == '365'
              ? year.future
              : period.future;
          await reveal(tester, find.byTooltip('Refresh usage'));
          await tester.tap(find.byTooltip('Refresh usage'));
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          expectSameGeometry(await sectionGeometry(tester), original);
          expect(find.text('USD 5.44'), findsOneWidget);
          await snapshot(tester, 'refresh-${brightness.name}-$scale');
          // Only repeated refresh is disabled; chart choices remain operable.
          final outer = find
              .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable),
              )
              .first;
          final position = tester.state<ScrollableState>(outer).position;
          for (
            var attempt = 0;
            find.byTooltip('Refresh usage').evaluate().isEmpty && attempt < 30;
            attempt++
          ) {
            position.jumpTo(
              (position.pixels + 200).clamp(0, position.maxScrollExtent),
            );
            await tester.pump();
          }
          expect(
            tester
                .widget<IconButton>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is IconButton &&
                        widget.tooltip == 'Refresh usage',
                  ),
                )
                .onPressed,
            isNull,
          );
          period.completeError(StateError('Offline'));
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          const modelError = 'usage-retained-models-error';
          final geometry = await sectionGeometry(tester, extra: [modelError]);
          const calendar = 'usage-calendar-slot';
          // Sliver coordinates can rebase when a tall error is inserted offscreen.
          // Compare the retained sections to the calendar's measured anchor.
          void expectRetainedSections(Map<String, Rect> measured) {
            final shift = measured[calendar]!.top - original[calendar]!.top;
            expectSameGeometry(measured, {
              for (final entry in original.entries)
                entry.key: entry.value.translate(
                  0,
                  shift +
                      (entry.key.startsWith('usage-trend-')
                          ? geometry[modelError]!.height
                          : 0),
                ),
            });
          }

          expectRetainedSections(geometry);
          year.complete(dailyData());
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expectRetainedSections(await sectionGeometry(tester));
          expect(find.text('USD 5.44'), findsOneWidget);
          await reveal(
            tester,
            find.widgetWithText(StudioError, 'Could not load model totals.'),
          );
          await snapshot(tester, 'refresh-error-${brightness.name}-$scale');
          fixture.override = (_, path, _, _) async =>
              path == 'analytics/models' ? {'models': []} : {'daily': []};
          await tap(tester, find.byTooltip('Refresh usage'));
          expectSameGeometry(await sectionGeometry(tester), original);
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.textContaining('Could not load'), findsNothing);
          await snapshot(tester, 'empty-${brightness.name}-$scale');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('analytics loading supports reduced motion and retirement', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    fixture.override = (_, _, _, _) => pending.future;
    await show(tester, reducedMotion: true, settle: false);
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    final original = await sectionGeometry(tester);
    await tester.tap(find.text('30D'));
    await tester.pump();
    await tester.pump();
    expectSameGeometry(await sectionGeometry(tester), original);
    expect(find.byType(StudioLoading), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('Retired read'));
    await tester.pumpAndSettle();
    expect(find.byType(StudioLoading), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all model rows remain reachable inside the stable breakdown frame',
    (tester) async {
      rows = [for (var i = 0; i < 12; i++) _sol()..['model'] = 'Model $i'];
      await show(tester);
      await reveal(tester, find.byKey(const ValueKey('usage-breakdown-slot')));
      final frame = tester.getRect(
        find.byKey(const ValueKey('usage-breakdown-slot')),
      );
      final inner = find.descendant(
        of: find.byKey(const ValueKey('usage-breakdown-slot')),
        matching: find.byType(Scrollable),
      );
      expect(inner, findsOneWidget);
      final position = tester.state<ScrollableState>(inner).position;
      expect(position.maxScrollExtent, greaterThan(0));
      final rowNames = [for (var i = 0; i < 12; i++) 'Model $i'];
      final last = rowNames.last;
      for (final name in rowNames) {
        await tester.ensureVisible(find.text(name));
        await tester.pump();
        expect(find.text(name).hitTestable(), findsOneWidget, reason: name);
        expect(
          tester
              .getRect(find.byKey(const ValueKey('usage-breakdown-slot')))
              .size,
          frame.size,
        );
      }
      expect(find.text(last).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic analytics recovery retains content without a Wing pulse',
    (tester) async {
      await show(tester);
      fixture.override = (_, _, _, _) async =>
          throw const SocketException('Offline');
      await tap(tester, find.byTooltip('Refresh usage'));
      final notice = find.byKey(const ValueKey('usage-retained-year-error'));
      await reveal(tester, notice);
      final noticeHeight = tester.getSize(notice).height;
      const modelError = 'usage-retained-models-error';
      final original = await sectionGeometry(tester, extra: [modelError]);
      final recovered = {
        for (final entry in original.entries)
          if (entry.key != modelError)
            entry.key: switch (entry.key) {
              'usage-calendar-slot' => entry.value,
              'usage-trend-group' ||
              'usage-trend-slot' => entry.value.translate(
                0,
                -noticeHeight - original[modelError]!.height,
              ),
              _ => entry.value.translate(0, -noticeHeight),
            },
      };
      final pending = Completer<Map<String, dynamic>>();
      fixture.override = (_, path, _, _) => path == 'analytics/models'
          ? pending.future
          : Future.value(dailyData());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(find.byType(StudioLoading), findsNothing);
      expectSameGeometry(await sectionGeometry(tester), {
        ...recovered,
        for (final id in ['usage-trend-group', 'usage-trend-slot'])
          id: recovered[id]!.translate(0, original[modelError]!.height),
      });
      expect(find.text('USD 5.44'), findsOneWidget);
      expect(notice, findsNothing);
      pending.complete({
        'models': [_paid()..['cache_read_tokens'] = 0],
      });
      await tester.pumpAndSettle();
      expectSameGeometry(await sectionGeometry(tester), recovered);
      expect(find.text('USD 3.00'), findsOneWidget);
      expect(find.byType(StudioLoading), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('period totals, title switches and day selection stay local', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await show(tester);
      expect(find.text('API-equivalent cost'), findsOneWidget);
      expect(find.text('USD 5.44'), findsOneWidget);
      expect(find.text('1.4M'), findsOneWidget);
      expect(find.text('Breakdown per model'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('usage-breakdown-group')));
      await reveal(tester, find.byType(UsageAreaChart));
      expect(find.text('Trend per token type'), findsOneWidget);
      expect(find.byType(UsageAreaChart), findsOneWidget);
      expect(fixture.requests.length, 3);
      expect(find.text('Cached input'), findsWidgets);
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      await tap(tester, find.byKey(ValueKey('usage-day-$today')));
      expect(find.text('12.0K'), findsOneWidget);
      expect(find.text('35.0K'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('51,000 tokens')), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('usage-breakdown-group')));
      expect(
        find.text('Hermes does not provide a model breakdown by day.'),
        findsOneWidget,
      );
      expect(find.byType(UsageComposition), findsNothing);
      await tap(tester, find.text('Show daily tokens'));
      expect(find.text('12.0K'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('usage-trend-group')));
      await tap(tester, find.text('Show token trend'));
      await reveal(tester, find.byType(UsageAreaChart));
      expect(find.byType(UsageAreaChart), findsOneWidget);
      expect(fixture.requests.length, 3);
      await tap(tester, find.text('Selected period'));
      expect(find.text('300K'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('missing API rate catalog shows unavailable', (tester) async {
    fixture.apiPrices = ModelsDevPrices({});
    fixture.override = (_, path, query, _) async => path == 'model/options'
        ? {
            'providers': [
              {
                'slug': 'openai-codex',
                'name': 'Subscription',
                'models': ['gpt-6-astra', 'gpt-5.6-sol'],
              },
            ],
          }
        : path == 'analytics/usage'
        ? dailyData()
        : {'models': rows};
    await show(tester);
    expect(find.text('API-equivalent cost'), findsOneWidget);
    expect(find.text('Unavailable'), findsWidgets);
    expect(find.text('USD 0.00'), findsNothing);
    expect(find.text('USD 5.44'), findsNothing);
    expect(find.text('1.4M'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('period chips cap at 365 and cache previously loaded periods', (
    tester,
  ) async {
    await show(tester);
    for (final label in ['1D', '7D', '30D', '90D', '365D']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('ALL'), findsNothing);
    await tap(tester, find.text('365D'));
    expect(fixture.requests.length, 4);
    expect(
      fixture.requests.where((r) => r.$2 == 'analytics/models').last.$3['days'],
      '365',
    );
    await tap(tester, find.text('7D'));
    expect(fixture.requests.length, 4);
    await tap(tester, find.text('365D'));
    await tester.drag(
      find.byKey(const ValueKey('usage-year-band')),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('usage-year-band')), findsOneWidget);
    expect(fixture.requests.length, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cost and token controls are independent and model rows are passive',
    (tester) async {
      await show(tester);
      await tap(tester, find.byKey(const ValueKey('usage-breakdown-group')));
      await tap(tester, find.byKey(const ValueKey('usage-breakdown-cost')));
      expect(find.text('Breakdown per token type'), findsOneWidget);
      expect(find.text('USD 2.70'), findsOneWidget);
      expect(find.text('USD 1.04'), findsOneWidget);
      expect(find.text('USD 1.70'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('usage-breakdown-group')));
      await tap(tester, find.text('gpt-6-astra'));
      expect(find.text('Model details'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        fixture.requests.every(
          (r) => r.$1 == 'GET' && r.$3['profile'] == 'personal',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mixed providers never infer token-type costs', (tester) async {
    rows = [_astra(), _paid()];
    await show(tester);
    expect(find.text('Estimated usage value'), findsOneWidget);
    expect(find.text('USD 8.00'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('usage-breakdown-group')));
    await tap(tester, find.byKey(const ValueKey('usage-breakdown-cost')));
    expect(
      find.textContaining('Cost per token type is available only'),
      findsOneWidget,
    );
    expect(find.byType(UsageComposition), findsNothing);
  });

  testWidgets('unknown prices and counters stay partial, never free', (
    tester,
  ) async {
    rows = [
      _astra(),
      _sol()..['model'] = 'unpriced',
      _sol()..remove('cache_read_tokens'),
    ];
    await show(tester);
    expect(find.text('USD 5.00'), findsOneWidget);
    expect(find.text('Partial total'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('usage-breakdown-cost')));
    expect(find.textContaining('Partial breakdown'), findsOneWidget);
    expect(find.textContaining('USD 0.00'), findsNothing);
    expect(find.textContaining('Unavailable'), findsWidgets);
  });

  testWidgets('duplicate contributions are combined in one passive model row', (
    tester,
  ) async {
    rows = [_astra(), _astra()];
    await show(tester);
    expect(find.text('USD 10.00'), findsOneWidget);
    expect(find.text('gpt-6-astra'), findsOneWidget);
    await tap(tester, find.text('gpt-6-astra'));
    expect(find.text('Model details'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sub-cent estimates are never rounded to free', (tester) async {
    rows = [
      _sol()..addAll({
        'input_tokens': 1,
        'cache_read_tokens': 0,
        'output_tokens': 0,
      }),
    ];
    await show(tester);
    await reveal(tester, find.text('< USD 0.01'));
    expect(find.textContaining('USD 0.00'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed refresh retains data and independent retry recovers', (
    tester,
  ) async {
    await show(tester);
    offline = true;
    await tap(tester, find.byTooltip('Refresh usage'));
    await reveal(tester, find.text('USD 5.44'));
    await reveal(
      tester,
      find.widgetWithText(StudioError, 'Could not load model totals.'),
    );
    expect(
      find.widgetWithText(StudioError, 'Could not load model totals.'),
      findsOneWidget,
    );
    await snapshot(tester, 'refresh-error');
    offline = false;
    rows = [_astra()];
    await tap(tester, find.byTooltip('Refresh usage'));
    await reveal(tester, find.text('USD 5.00'));
    expect(find.textContaining('Could not load'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'stale visit is quiet and explicit refresh joins ${brightness.name} $scale',
        (tester) async {
          rows = [_paid()..['estimated_cost'] = 7];
          final past = DateTime.now().subtract(const Duration(minutes: 6));
          final warmup = UsageAnalyticsSession(
            UsageAnalyticsReader(fixture.server.usageAnalytics, [
              'personal',
            ], now: () => past),
          );
          await warmup.load();
          warmup.dispose();
          final held = Completer<void>();
          fixture.override = (_, path, _, _) async {
            await held.future;
            throw StateError('Offline');
          };
          await show(
            tester,
            brightness: brightness,
            scale: scale,
            settle: false,
          );
          expect(find.text('USD 7.00'), findsOneWidget);
          expect(find.byType(StudioLoading), findsNothing);
          expect(fixture.requests.length, 6);
          final refresh = find.byTooltip('Refresh usage');
          await reveal(tester, refresh);
          final updated = tester
              .widget<Text>(find.textContaining('Updated '))
              .data;
          expect(updated, isNotNull);
          await snapshot(tester, 'stale-quiet-${brightness.name}-$scale');
          await tester.tap(refresh);
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(fixture.requests.length, 6);
          await snapshot(tester, 'stale-refresh-${brightness.name}-$scale');
          held.complete();
          await tester.pumpAndSettle(const Duration(milliseconds: 250));
          expect(find.byType(StudioLoading), findsNothing);
          await reveal(tester, find.textContaining('Updated '));
          expect(find.text(updated!), findsOneWidget);
          await reveal(tester, find.text('USD 7.00'));
          expect(find.text('USD 7.00'), findsOneWidget);
          fixture.override = (_, path, _, _) async => path == 'analytics/models'
              ? {
                  'models': [_paid()..['estimated_cost'] = 5],
                }
              : dailyData();
          await tap(tester, refresh);
          await reveal(tester, find.text('USD 5.00'));
          expect(find.text('USD 5.00'), findsOneWidget);
          expect(fixture.requests.length, 9);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'initial failure is distinct from empty history and retries ${brightness.name} $scale',
        (tester) async {
          final pending = Completer<Map<String, dynamic>>();
          fixture.override = (_, _, _, _) => pending.future;
          await show(
            tester,
            brightness: brightness,
            scale: scale,
            settle: false,
          );
          expect(find.byType(StudioLoading), findsOneWidget);
          pending.completeError(StateError('Offline'));
          await tester.pumpAndSettle(const Duration(milliseconds: 250));
          for (final (section, message) in [
            (
              'calendar',
              'Could not load the activity year. Use Refresh to retry.',
            ),
            ('breakdown', 'Could not load model totals.'),
            ('trend', 'Could not load daily usage.'),
          ]) {
            final failure = find.widgetWithText(StudioError, message);
            await reveal(tester, failure);
            expect(failure, findsOneWidget);
            expect(find.text(message), findsOneWidget);
            await snapshot(
              tester,
              'initial-$section-error-${brightness.name}-$scale',
            );
          }
          expect(find.text('Period breakdown unavailable.'), findsNothing);
          expect(find.text('Daily usage unavailable.'), findsNothing);
          expect(
            find.text('No recorded model usage in this period.'),
            findsNothing,
          );
          fixture.override = (_, path, _, _) async =>
              path == 'analytics/models' ? {'models': []} : {'daily': []};
          await tap(tester, find.byTooltip('Refresh usage'));
          await reveal(
            tester,
            find.text('No recorded model usage in this period.'),
          );
          expect(find.textContaining('Could not load'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('late period responses cannot replace the selected range', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    fixture.override = withSubscriptionModelOptions((_, path, query, _) async {
      if (path == 'analytics/usage') return dailyData();
      if (query['days'] == '30') return pending.future;
      return {
        'models': [_paid()..['estimated_cost'] = 7],
      };
    });
    await show(tester);
    await tester.tap(find.text('30D'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Loading usage…'), findsNothing);
    // This newly selected range has no observation yet; its chart is blocked.
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.bySemanticsLabel('Loading usage'), findsOneWidget);
    await tester.tap(find.text('7D'));
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
    pending.complete({
      'models': [_paid()..['estimated_cost'] = 30],
    });
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
    expect(find.text('USD 7.00'), findsOneWidget);
    expect(find.text('USD 30.00'), findsNothing);
    await tap(tester, find.text('30D'));
    expect(find.text('USD 30.00'), findsOneWidget);
    expect(fixture.requests.length, 5);
  });

  testWidgets(
    'older day selects year counts without changing period or refetching',
    (tester) async {
      final date = DateTime.now().toUtc().subtract(const Duration(days: 100));
      final id = date.toIso8601String().substring(0, 10);
      fixture.override = withSubscriptionModelOptions((
        _,
        path,
        query,
        _,
      ) async {
        if (path == 'analytics/models') {
          return {
            'models': [_astra()],
          };
        }
        return {
          'daily': [
            if (query['days'] == '365')
              {
                'day': id,
                'input_tokens': 123,
                'cache_read_tokens': 456,
                'output_tokens': 789,
              },
          ],
        };
      });
      await show(tester);
      await tap(tester, find.byKey(ValueKey('usage-day-$id')));
      await tap(tester, find.text('Show daily tokens'));
      await reveal(tester, find.text('123'));
      expect(find.text('456'), findsOneWidget);
      expect(find.text('789'), findsOneWidget);
      expect(find.text('Selected period'), findsOneWidget);
      expect(fixture.requests.length, 3);
      await tap(tester, find.text('Selected period'));
      expect(find.text('Last 7 days · all models'), findsOneWidget);
    },
  );

  testWidgets('one passive row per model combines provider tokens and costs', (
    tester,
  ) async {
    rows = [
      _astra(),
      _astra()..addAll({'provider': 'openai', 'estimated_cost': 7}),
    ];
    await show(tester);
    await reveal(tester, find.text('gpt-6-astra'));
    expect(find.text('gpt-6-astra'), findsOneWidget);
    final tokenSegments = tester
        .widget<UsageComposition>(find.byType(UsageComposition))
        .segments;
    expect(tokenSegments.single.value, 2560000);
    final color = tokenSegments.single.color;
    await tap(tester, find.byKey(const ValueKey('usage-breakdown-cost')));
    final costSegments = tester
        .widget<UsageComposition>(find.byType(UsageComposition))
        .segments;
    expect(costSegments.single.value, 12);
    expect(costSegments.single.color, color);
    await tap(tester, find.text('gpt-6-astra'));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Model details'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'server date rollover ${brightness.name} at $scale text retains independent year data',
        (tester) async {
          fixture.override = withSubscriptionModelOptions((
            _,
            path,
            query,
            _,
          ) async {
            if (path == 'analytics/models') {
              return {
                'models': [_astra()],
              };
            }
            return {
              'daily': [
                {
                  'day': query['days'] == '365' ? '2026-12-31' : '2027-01-01',
                  'input_tokens': query['days'] == '365' ? 123 : 100,
                  'cache_read_tokens': 0,
                  'output_tokens': 50,
                },
              ],
            };
          });
          await show(tester, brightness: brightness, scale: scale);
          await tap(tester, find.byKey(const ValueKey('usage-day-2027-01-01')));
          expect(
            find.textContaining('No returned year data', findRichText: true),
            findsOneWidget,
          );
          expect(find.text('Selected period'), findsNothing);
          await snapshot(tester, '${brightness.name}-$scale-server-date');
          await tap(tester, find.byKey(const ValueKey('usage-day-2026-12-31')));
          await tap(tester, find.text('Show daily tokens'));
          expect(find.text('123'), findsOneWidget);
          expect(fixture.requests.length, 3);
          await tap(tester, find.text('Selected period'));
          await reveal(tester, find.byType(UsageAreaChart));
          expect(find.text('150 tokens / day'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await snapshot(tester, '${brightness.name}-$scale-single-date-trend');
        },
      );
      testWidgets('usage renders ${brightness.name} at $scale text', (
        tester,
      ) async {
        final today = DateTime.now().toUtc();
        fixture.override = withSubscriptionModelOptions((
          _,
          path,
          query,
          _,
        ) async {
          if (path == 'analytics/usage') {
            final days = int.parse(query['days']!);
            return {
              'daily': [
                for (var i = 0; i < days && i < 90; i++)
                  if (i % 7 != 2 && i % 7 != 4)
                    {
                      'day': today
                          .subtract(Duration(days: i))
                          .toIso8601String()
                          .substring(0, 10),
                      'input_tokens': i % 13 == 3 ? 0 : 12000 + i * 1000,
                      'cache_read_tokens': 0,
                      'output_tokens': 0,
                    },
              ],
            };
          }
          return {'models': rows, 'period_days': int.parse(query['days']!)};
        });
        await show(tester, brightness: brightness, scale: scale);
        await snapshot(tester, '${brightness.name}-$scale-summary');
        await reveal(tester, find.byType(UsageAreaChart));
        await snapshot(tester, '${brightness.name}-$scale-trend');
        await tap(tester, find.text('90D'));
        await snapshot(tester, '${brightness.name}-$scale-calendar');
        final band = find.byKey(const ValueKey('usage-year-band'));
        await reveal(tester, find.byKey(const ValueKey('usage-activity-grid')));
        await tester.drag(band, const Offset(140, 0));
        await tester.pumpAndSettle(const Duration(milliseconds: 250));
        await snapshot(tester, '${brightness.name}-$scale-scrolled');
        await tester.drag(band, const Offset(-300, 0));
        await tester.pumpAndSettle(const Duration(milliseconds: 250));
        await tap(tester, find.text('365D'));
        await reveal(tester, find.byKey(const ValueKey('usage-activity-grid')));
        await snapshot(tester, '${brightness.name}-$scale-year');
        final todayId = today.toIso8601String().substring(0, 10);
        await tap(tester, find.byKey(ValueKey('usage-day-$todayId')));
        await snapshot(tester, '${brightness.name}-$scale-day-tooltip');
        await tap(tester, find.text('Selected period'));
        await tap(tester, find.text('gpt-6-astra'));
        await reveal(tester, find.text('gpt-6-astra'));
        await snapshot(tester, '${brightness.name}-$scale-breakdown');
        await reveal(tester, find.byTooltip('Refresh usage'));
        expect(find.byTooltip('Refresh usage').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
