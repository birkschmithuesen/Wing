import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/services/profile_overview_session.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/analytics_content.dart';
import 'package:wing/core/screens/administration/admin_profile_overview.dart';
import 'package:wing/core/screens/administration/admin_providers_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/administration_design_fixture.dart';
import 'support/administration_fixture.dart';
import 'support/scheduled_tasks_fixture.dart';

void main() {
  testWidgets('zero and unknown costs stay distinct in usage composition', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    fixture.override = (_, path, _, _) async => path == 'analytics/usage'
        ? {'daily': []}
        : {
            'models': [
              {'model': 'Zero', 'estimated_cost': 0},
              {'model': 'Missing'},
              {'model': 'Invalid', 'estimated_cost': -1},
            ],
          };
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: AnalyticsPage(profile: fixture.server.profile('personal')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(StudioLoading), findsNothing);
    expect(find.text('Partial total'), findsOneWidget);
    expect(find.text('USD 0.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'usage compares known costs, leaves model rows passive and changes range',
    (tester) async {
      final fixture = AdministrationDesignFixture();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: AnalyticsPage(profile: fixture.server.profile('personal')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Partial total'), findsOneWidget);
      expect(find.text('USD 12.50'), findsOneWidget);
      final group = find.byKey(const ValueKey('usage-breakdown-group'));
      await tester.ensureVisible(group);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Research model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Research model'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('365D'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('365D'));
      await tester.pumpAndSettle();
      expect(
        fixture.requests
            .where((r) => r.$2 == 'analytics/models')
            .last
            .$3['days'],
        '365',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task overview finds actual next task independently of attention and does not infer run success',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = AdministrationDesignFixture();
      final overviewPreferences = await SharedPreferences.getInstance();
      fixture.jobs.addAll([
        taskJson(id: 'running', name: 'Working now', state: 'running'),
        taskJson(id: 'next', name: 'Actual next task')
          ..['next_run_at'] = '2026-09-18T01:00:00Z',
        taskJson(id: 'later', name: 'Later task')
          ..['next_run_at'] = '2026-09-19T01:00:00Z',
      ]);
      final session = ProfileOverviewSession(
        fixture.server.profile('personal'),
        overviewPreferences,
        refreshWorkspace: () async {},
      );
      addTearDown(session.dispose);
      unawaited(session.load());
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: AdminProfileOverview(
              metadata: null,
              session: session,
              selector: const Text('Personal'),
              search: const TextField(
                decoration: InputDecoration(hintText: 'Search settings'),
              ),
              destinations: const {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Actual next task'),
        160,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      expect(find.textContaining('1 running'), findsOneWidget);
      expect(find.textContaining('Last listed run'), findsOneWidget);
      expect(find.textContaining('Outcome unavailable'), findsOneWidget);
      expect(find.text('Later task'), findsNothing);
      expect(find.textContaining('Success'), findsNothing);
      expect(fixture.requests.every((r) => r.$1 == 'GET'), isTrue);
      expect(fixture.requests.where((r) => r.$2 == 'cron/jobs'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'service-key addition is explicit and shared detail uses canonical owner',
    (tester) async {
      final fixture = AdministrationDesignFixture();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: AdminProvidersPage(profile: fixture.server.profile('personal')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Add service key'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add service key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search service'));
      await tester.pumpAndSettle();
      expect(find.text('SEARCH_API_KEY'), findsWidgets);
      expect(fixture.requests.every((r) => r.$1 == 'GET'), isTrue);
      expect(fixture.requests.every((r) => !r.$2.contains('/reveal')), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
