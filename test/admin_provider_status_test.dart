import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_providers_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'support/administration_fixture.dart';
import 'support/form_family_capture.dart';

Map<String, dynamic> provider(
  String id,
  Map<String, dynamic> status, {
  String flow = 'device_code',
}) => {
  'id': id,
  'name': id,
  'status': status,
  'flow': flow,
  'disconnectable': true,
};

void main() {
  setUpAll(loadFormFamilyFonts);
  final pageScroll = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;
  testWidgets(
    'multiple connected providers, expired tokens and defaults remain independent',
    (tester) async {
      final fixture = AdministrationFixture();
      var fail = false;
      fixture.override = (method, path, query, body) async {
        if (fail) throw StateError('Offline');
        if (path == 'env') return {};
        if (path == 'profiles') {
          return {
            'profiles': [
              {'name': 'personal', 'provider': 'alpha'},
              {'name': 'work', 'provider': 'beta'},
            ],
          };
        }
        return {
          'providers': [
            provider('alpha', {'logged_in': true}),
            provider('beta', {'logged_in': true}),
            provider('expired', {
              'logged_in': true,
              'expires_at': '2020-01-01T00:00:00Z',
              'has_refresh_token': true,
            }),
            provider('unused', {'logged_in': false}),
          ],
        };
      };
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: AdminProvidersPage(profile: fixture.server.profile('default')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Stored (2)'), findsOneWidget);
      expect(find.text('Needs attention (1)'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('provider-expired'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('provider-alpha'))).dy,
        ),
      );
      expect(find.byTooltip('Sign in to expired again'), findsOneWidget);
      await tester.tap(find.text('Stored (2)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Access token expired'), findsNothing);
      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      expect(find.text('Server A / default'), findsOneWidget);
      expect(find.text('Manage shared account'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta'));
      await tester.pumpAndSettle();
      expect(find.text('Server A / default'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      final accountReads = fixture.requests
          .where((request) => request.$2 == 'providers/oauth')
          .toList();
      expect(accountReads, isNotEmpty);
      expect(
        accountReads.map((request) => request.$3['profile']),
        everyElement('default'),
      );
      fail = true;
      await tester.scrollUntilVisible(
        find.text('Check status'),
        -250,
        scrollable: pageScroll,
      );
      await tester.tap(find.text('Check status'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Last checked'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Stored (2)'),
        -250,
        scrollable: pageScroll,
      );
      expect(find.text('Stored (2)'), findsOneWidget);
      expect(fixture.requests.every((r) => r.$1 == 'GET'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'provider inventory survives a selection read failure ${brightness.name} $scale',
        (tester) async {
          final fixture = AdministrationFixture();
          addTearDown(fixture.server.close);
          var fail = true;
          fixture.override = (method, path, query, body) async {
            if (path == 'profiles') {
              if (fail) throw StateError('Unavailable');
              return {
                'profiles': [
                  {'name': 'personal', 'provider': 'openai-codex'},
                ],
              };
            }
            if (path == 'env') return {};
            return {
              'providers': [
                provider('External provider with a long display name', {
                  'logged_in': false,
                }, flow: 'external'),
              ],
            };
          };
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: formFamilyCapture, child: child!),
              ),
              home: AdminProvidersPage(
                profile: fixture.server.profile('personal'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final error = find.widgetWithText(
            StudioError,
            'Profile selections could not be loaded. Refresh to retry.',
          );
          await tester.scrollUntilVisible(error, 200, scrollable: pageScroll);
          await tester.ensureVisible(error);
          await tester.pumpAndSettle();
          expect(error, findsOneWidget);
          await captureFormFamily(
            tester,
            'error-screen-provider-inventory-${brightness.name}-$scale',
          );
          fail = false;
          final refresh = find.text('Check status');
          await tester.ensureVisible(refresh);
          await tester.pumpAndSettle();
          await tester.tap(refresh);
          await tester.pumpAndSettle();
          expect(error, findsNothing);
          await tester.scrollUntilVisible(
            find.text('External provider with a long display name'),
            200,
            scrollable: pageScroll,
          );
          await tester.ensureVisible(
            find.text('External provider with a long display name'),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.text('External provider with a long display name'),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Credential details'),
            200,
            scrollable: pageScroll,
          );
          await tester.ensureVisible(find.text('Credential details'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Credential details'));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Check external sign-in'),
            -200,
            scrollable: pageScroll,
          );
          expect(find.text('Check external sign-in'), findsOneWidget);
          expect(find.text('Disconnect'), findsNothing);
          expect(find.text('Remove profile account'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
