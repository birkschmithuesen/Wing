import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/usage_analytics.dart';
import 'package:wing/core/screens/administration/usage_charts.dart';
import 'package:wing/core/theme/wing_theme.dart';

void main() {
  testWidgets('range outline includes reported and missing zero-usage days', (
    tester,
  ) async {
    final daily = UsageDaily.fromJson({
      'daily': [
        for (final (date, count) in [
          ('2026-09-14', 10),
          ('2026-09-15', 20),
          ('2026-09-16', 0),
          ('2026-09-18', 30),
          ('2026-09-19', 40),
        ])
          {
            'day': date,
            'input_tokens': count,
            'cache_read_tokens': 0,
            'output_tokens': 0,
          },
      ],
    }, period: 365);
    Future<void> show(Set<String> dates) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: UsageCalendar(
              daily: daily,
              periodDates: dates,
              selected: null,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
    }

    CustomPainter rangePainter() => tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byKey(const ValueKey('usage-year-band')),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter!;
    await show({'2026-09-15', '2026-09-18'});
    final sparse = rangePainter();
    for (final id in ['2026-09-15', '2026-09-16', '2026-09-17', '2026-09-18']) {
      final label = tester
          .widget<Semantics>(find.byKey(ValueKey(id)))
          .properties
          .label!;
      expect(label, contains('selected period'), reason: id);
      if (id == '2026-09-16' || id == '2026-09-17') {
        expect(label, contains('0 tokens'));
      }
    }
    for (final id in ['2026-09-14', '2026-09-19']) {
      expect(
        tester.widget<Semantics>(find.byKey(ValueKey(id))).properties.label,
        isNot(contains('selected period')),
      );
    }
    await show({'2026-09-15', '2026-09-16', '2026-09-17', '2026-09-18'});
    expect(rangePainter().shouldRepaint(sparse), isFalse);
    await show({});
    expect(
      tester
          .widget<Semantics>(find.byKey(const ValueKey('2026-09-16')))
          .properties
          .label,
      isNot(contains('selected period')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'server date placeholders differ from verified zero and retained period dates remain reachable',
    (tester) async {
      final daily = UsageDaily.fromJson({
        'daily': [
          {
            'day': '2027-01-01',
            'input_tokens': 0,
            'cache_read_tokens': 0,
            'output_tokens': 0,
          },
        ],
      }, period: 365);
      final selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: UsageCalendar(
              daily: daily,
              periodDates: const {'2027-01-02'},
              selected: null,
              onSelected: (day) => selected.add(day.id),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('usage-day-2027-01-02')));
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(
        find.textContaining('No returned year data', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('UTC'), findsNothing);
      expect(selected, isEmpty);
      await tester.tap(find.byKey(const ValueKey('usage-day-2027-01-01')));
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(
        find.textContaining('0 tokens', findRichText: true),
        findsOneWidget,
      );
      expect(selected, ['2027-01-01']);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'day tooltips replace each other and distinguish zero from unknown',
    (tester) async {
      final daily = UsageDaily.fromJson({
        'daily': [
          {
            'day': '2026-09-16',
            'input_tokens': 0,
            'cache_read_tokens': 0,
            'output_tokens': 0,
          },
          {'day': '2026-09-18', 'input_tokens': 10, 'output_tokens': 20},
          {
            'day': '2026-09-19',
            'input_tokens': 297927473,
            'cache_read_tokens': 0,
            'output_tokens': 0,
          },
        ],
      }, period: 365);
      final selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: UsageCalendar(
              daily: daily,
              periodDates: daily.reportedDates,
              selected: null,
              onSelected: (day) => selected.add(day.id),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('usage-day-2026-09-17')));
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(
        find.textContaining('0 tokens', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('usage-day-2026-09-18')));
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(
        find.textContaining('Tokens unavailable', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('0 tokens', findRichText: true), findsNothing);
      expect(selected, ['2026-09-17', '2026-09-18']);
      await tester.tap(find.byKey(const ValueKey('usage-day-2026-09-19')));
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(
        find.textContaining('298M tokens', findRichText: true),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Semantics>(find.byKey(const ValueKey('2026-09-19')))
            .properties
            .label,
        contains('297,927,473 tokens'),
      );

      await tester.tapAt(
        tester.getBottomRight(find.byType(Scaffold)) - const Offset(16, 16),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(
        find.textContaining('298M tokens', findRichText: true),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  // Every server date remains reachable through the single browsing band.
  for (var weekday = 0; weekday < 7; weekday++) {
    testWidgets(
      'single band scrolls through year and keeps range geometry, weekday $weekday',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final last = DateTime.utc(2026, 9, 13 + weekday);
        final daily = UsageDaily.fromJson({
          'daily': [
            for (final date in [last.subtract(const Duration(days: 365)), last])
              {
                'day': date.toIso8601String().substring(0, 10),
                'input_tokens': 0,
                'cache_read_tokens': 0,
                'output_tokens': 0,
              },
          ],
        }, period: 365);
        var width = 358.0, period = 7;
        UsageDay? selected;
        Future<void> show() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(Brightness.dark),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: UsageCalendar(
                      daily: daily,
                      periodDates: {
                        for (final day in daily.days.skip(
                          daily.days.length - period - 1,
                        ))
                          day.id,
                      },
                      selected: selected?.id,
                      onSelected: (day) => selected = day,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 250));
        }

        Finder day(String id) => find.byKey(ValueKey('usage-day-$id'));
        await show();
        final band = find.byKey(const ValueKey('usage-year-band'));
        final scroll = find.byKey(const ValueKey('usage-calendar-scroll'));
        ScrollPosition position() => tester
            .state<ScrollableState>(
              find.descendant(of: scroll, matching: find.byType(Scrollable)),
            )
            .position;
        List<String> visible() {
          final viewport = tester.getRect(band);
          return find
              .byType(InkWell)
              .evaluate()
              .where((element) {
                final box = element.renderObject! as RenderBox;
                final center = box.localToGlobal(box.size.center(Offset.zero));
                return center.dx >= viewport.left &&
                    center.dx <= viewport.right;
              })
              .map(
                (element) => (element.widget.key! as ValueKey<String>).value
                    .substring('usage-day-'.length),
              )
              .toList()
            ..sort();
        }

        Future<void> drag(double dx) async {
          await tester.drag(band, Offset(dx, 0));
          await tester.pumpAndSettle(const Duration(milliseconds: 250));
        }

        expect(band, findsOneWidget);
        expect(find.byTooltip('Earlier dates'), findsNothing);
        expect(find.byTooltip('Later dates'), findsNothing);
        expect(position().pixels, 0);
        final latest = visible();
        expect(latest.length, lessThan(366));
        expect(latest.last, daily.days.last.id);
        final samples = [latest.first, latest.last];
        final bounds = {for (final id in samples) id: tester.getRect(day(id))};
        for (final range in usagePeriods) {
          period = range;
          await show();
          expect(visible(), latest);
          for (final id in samples) {
            expect(tester.getRect(day(id)), bounds[id]);
          }
        }
        String label() => tester
            .widget<Text>(find.byKey(const ValueKey('usage-visible-dates')))
            .data!;
        final latestLabel = label();
        final gesture = await tester.startGesture(tester.getCenter(band));
        await gesture.moveBy(const Offset(25, 0));
        await gesture.moveBy(const Offset(60, 0));
        await tester.pump();
        expect(position().pixels, greaterThan(0));
        expect(label(), isNot(latestLabel));
        expect(selected, isNull);
        await gesture.moveBy(const Offset(-35, 0));
        await tester.pump();
        expect(label(), isNot(latestLabel));
        await gesture.up();
        await tester.pumpAndSettle(const Duration(milliseconds: 250));
        await drag(-400);
        expect(label(), latestLabel);
        if (weekday == 0) {
          await tester.tap(day(daily.days.last.id));
          await tester.pumpAndSettle(const Duration(milliseconds: 250));
          expect(
            find.textContaining('0 tokens', findRichText: true),
            findsOneWidget,
          );
          await tester.fling(band, const Offset(70, 0), 700);
          await tester.pump();
          final releasedAt = position().pixels;
          final releasedLabel = label();
          await tester.pump(const Duration(milliseconds: 100));
          expect(position().pixels, greaterThan(releasedAt));
          expect(label(), isNot(releasedLabel));
          await tester.pumpAndSettle(const Duration(milliseconds: 250));
          expect(
            find.textContaining('0 tokens', findRichText: true),
            findsNothing,
          );
          await drag(-1000);
        }
        final visited = latest.toSet();
        // Exhaustively verify date reachability without replaying the gesture
        // animation at every position. Drag/fling behavior is checked above.
        final step = position().viewportDimension / 2;
        expect(step, greaterThan(0));
        while (position().pixels < position().maxScrollExtent) {
          position().jumpTo(
            (position().pixels + step)
                .clamp(0, position().maxScrollExtent)
                .toDouble(),
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 250));
          visited.addAll(visible());
        }
        expect(visited, daily.days.map((d) => d.id).toSet());
        final oldest = visible().first;
        await tester.tap(day(oldest));
        expect(selected?.id, oldest);
        width = 288;
        await show();
        expect(
          position().pixels,
          inInclusiveRange(0, position().maxScrollExtent),
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('usage-activity-grid')))
              .width,
          closeTo(width, .01),
        );
        position().jumpTo(0);
        await tester.pumpAndSettle(const Duration(milliseconds: 250));
        expect(visible().last, daily.days.last.id);
        width = 900;
        await show();
        // Wide layouts keep the same 52-column frame across loading and data.
        // The handful of older dates beyond it remain reachable by scrolling.
        expect(visible().last, daily.days.last.id);
        position().jumpTo(position().maxScrollExtent);
        await tester.pumpAndSettle(const Duration(milliseconds: 250));
        expect(visible().first, daily.days.first.id);
        expect(find.byTooltip('Earlier dates'), findsNothing);
        expect(find.byKey(const ValueKey('usage-year-band')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
