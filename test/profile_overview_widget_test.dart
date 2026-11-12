import 'package:wing/core/services/profile_overview_session.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_overview_summary.dart';
import 'package:wing/core/screens/administration/admin_profile_overview.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'support/administration_fixture.dart';

void main() {
  late AdministrationFixture fixture;
  late SharedPreferences preferences;
  late ProfileOverviewSession session;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    fixture = AdministrationFixture('Overview widget');
    session = ProfileOverviewSession(
      fixture.server.profile('personal'),
      preferences,
      refreshWorkspace: () async {},
    );
  });
  tearDown(() => session.dispose());
  Future<void> show(
    WidgetTester tester, {
    Widget? results,
    Map<ProfileOverviewDestination, FutureOr<void> Function()?> destinations =
        const {},
    ThemeData? theme,
  }) {
    unawaited(session.load());
    return tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: AdminProfileOverview(
            metadata: null,
            session: session,
            selector: const Text('Personal profile'),
            search: const Text('Search settings'),
            searchResults: results,
            destinations: destinations,
          ),
        ),
      ),
    );
  }

  testWidgets('stock automatic provider renders as automatic routing', (
    tester,
  ) async {
    fixture.override = (_, path, _, _) async {
      if (path == 'model/info') return {'model': 'stock-model', 'provider': ''};
      return switch (path) {
        'config' => {
          'agent': {'reasoning_effort': 'high'},
        },
        'providers/oauth' => {'providers': []},
        'mcp/servers' => {'servers': []},
        _ => {'data': []},
      };
    };
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('stock-model'), findsOneWidget);
    expect(find.text('Automatic provider · Reasoning high'), findsOneWidget);
    expect(find.textContaining('Provider unavailable'), findsNothing);
  });

  testWidgets(
    'returning from a destination refreshes its captured observations',
    (tester) async {
      await show(
        tester,
        destinations: {ProfileOverviewDestination.memory: () async {}},
      );
      await tester.pumpAndSettle();
      fixture.requests.clear();
      await tester.tap(find.byKey(const ValueKey('Memory')));
      await tester.pumpAndSettle();
      expect(fixture.requests.map((r) => r.$2), ['config']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing route while destination is open sends no return reads', (
    tester,
  ) async {
    final navigation = Completer<void>();
    await show(
      tester,
      destinations: {
        ProfileOverviewDestination.models: () => navigation.future,
      },
    );
    await tester.pumpAndSettle();
    fixture.requests.clear();
    await tester.tap(find.byKey(const ValueKey('Models and reasoning')));
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    navigation.complete();
    await tester.pumpAndSettle();
    expect(fixture.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'overview remains reachable at enlarged text ${dark ? 'dark' : 'light'}',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await show(
          tester,
          theme: profileWorkspaceTheme(
            wingTheme(dark ? Brightness.dark : Brightness.light),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('Scheduled tasks')),
          250,
        );
        expect(find.text('No scheduled tasks'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
