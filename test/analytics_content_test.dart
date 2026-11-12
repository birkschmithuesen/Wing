import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/analytics_content.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'support/administration_fixture.dart';
import 'support/profile_browser_fixture.dart';
import 'support/host_resources_fixture.dart';
import 'support/loopback_http_fixtures.dart';

void main() {
  testWidgets(
    'analytics profile changes discard pending results from the old owner',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final browser = ProfileBrowserFixture();
      final server = AdministrationFixture();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Claw',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'analytics',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: browser.gateway,
      );
      addTearDown(controller.dispose);
      addTearDown(server.server.close);
      await controller.initialize();
      final pending = Completer<Map<String, dynamic>>();
      Map<String, dynamic> models(num cost) => {
        'models': [
          {
            'model': 'example',
            'provider': 'example',
            'estimated_cost': cost,
            'input_tokens': 100,
            'output_tokens': 10,
            'cache_read_tokens': 0,
          },
        ],
      };
      server.override = (_, path, query, _) async {
        if (path == 'analytics/usage') return {'daily': []};
        if (query['profile'] == 'personal') return pending.future;
        return models(7);
      };
      String? profileName;
      late StateSetter select;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              appBar: WingAppBar(
                context: context,
                title: const Text('Analytics'),
              ),
              body: StatefulBuilder(
                builder: (context, setState) {
                  select = setState;
                  return HermesAnalyticsContent(
                    controller: controller,
                    repository: server.server,
                    profileName: profileName,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Loading usage…'), findsNothing);
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(find.bySemanticsLabel('Loading usage'), findsOneWidget);
      expect(server.requests, hasLength(6));
      expect(server.requests.map((r) => r.$3['profile']).toSet(), {
        'personal',
        'work',
      });
      final callsBefore = browser.calls.length;
      select(() => profileName = 'work');
      await tester.pumpAndSettle();
      expect(server.requests.skip(6), isEmpty);
      expect(
        server.requests.skip(6).every((r) => r.$3['profile'] == 'work'),
        isTrue,
      );
      expect(find.text('USD 7.00'), findsOneWidget);
      expect(controller.current!.scope.profileName, 'personal');
      pending.complete(models(99));
      await tester.pumpAndSettle();
      expect(find.text('USD 7.00'), findsOneWidget);
      expect(find.text('USD 99.00'), findsNothing);
      expect(
        server.requests.every(
          (r) => r.$1 == 'GET' && r.$2.startsWith('analytics/'),
        ),
        isTrue,
      );
      expect(
        browser.calls
            .skip(callsBefore)
            .where((c) => c.$2 == 'setup.runtime_check'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  group('connection-owned analytics access', () {
    useRealHttpClientsForLoopbackFixtures();
    testWidgets('reentry shares authentication with the active host watcher', (
      tester,
    ) async {
      // Current stock Hermes permits ten password logins per client IP in a
      // sixty-second sliding window. Normal reads reuse the issued cookie.
      final requests = <(String, Uri)>[];
      final allowedLogins = <DateTime>[];
      var loginRequests = 0;
      final transport = (await tester.runAsync(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          requests.add((request.method, request.uri));
          request.response.headers.contentType = ContentType.json;
          Map<String, dynamic> response;
          if (request.uri.path == '/auth/password-login') {
            loginRequests++;
            final now = DateTime.now();
            allowedLogins.removeWhere(
              (at) => now.difference(at) > const Duration(seconds: 60),
            );
            if (allowedLogins.length >= 10) {
              request.response.statusCode = HttpStatus.tooManyRequests;
              response = {
                'detail': 'Too many login attempts. Try again shortly.',
              };
            } else {
              allowedLogins.add(now);
              request.response.headers.add(
                HttpHeaders.setCookieHeader,
                'hermes_session_at=fixture-session; Path=/; HttpOnly',
              );
              response = {'ok': true};
            }
          } else if (request.headers.value(HttpHeaders.cookieHeader) !=
              'hermes_session_at=fixture-session') {
            request.response.statusCode = HttpStatus.unauthorized;
            response = {'detail': 'Not authenticated'};
          } else {
            response = switch (request.uri.path) {
              '/api/system/stats' => hostStatsPayload(),
              '/api/status' => hostPressurePayload(),
              '/api/analytics/models' => {
                'models': [
                  {
                    'model': 'example',
                    'provider': 'example',
                    'estimated_cost': 2,
                    'input_tokens': 100,
                    'cache_read_tokens': 0,
                    'output_tokens': 10,
                  },
                ],
              },
              '/api/analytics/usage' => {
                'daily': [
                  {
                    'day': '2026-10-09',
                    'input_tokens': 100,
                    'cache_read_tokens': 0,
                    'output_tokens': 10,
                  },
                ],
              },
              _ => {'detail': 'Unexpected request'},
            };
          }
          request.response.write(jsonEncode(response));
          await request.response.close();
        });
        return (server: server, subscription: subscription);
      }))!;
      final server = transport.server;
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      final browser = ProfileBrowserFixture();
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'analytics-auth',
            label: 'Test',
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
            dashboardPortOverride: server.port,
            dashboardUsername: 'fixture-user',
            dashboardPassword: 'fixture-password',
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'analytics-auth-http',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: browser.gateway,
      );
      await controller.initialize();
      final host = controller.hostResources();
      final watch = host.watch();
      var closed = false;
      Future<void> closeFixture() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        watch.close();
        controller.dispose();
        appPreferences.dispose();
        await tester.runAsync(() async {
          await server.close(force: true);
          await transport.subscription.cancel();
        });
        await tester.pump();
      }

      addTearDown(closeFixture);
      try {
        host.refresh();
        for (
          var attempt = 0;
          attempt < 500 && host.state.refreshing;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(host.state.refreshing, isFalse);
        expect(host.state.stats.error, isNull);
        expect(loginRequests, 1);
        Future<void> finishReads() async {
          for (var attempt = 0; attempt < 500; attempt++) {
            await tester.pump(const Duration(milliseconds: 20));
            if (find.text('Loading usage…').evaluate().isEmpty &&
                find.byType(StudioLoading).evaluate().isEmpty) {
              return;
            }
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          fail('Analytics reads did not finish');
        }

        var sawUnavailable = false;
        for (var visit = 0; visit < 12; visit++) {
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  appBar: WingAppBar(
                    context: context,
                    title: const Text('Analytics'),
                  ),
                  body: HermesAnalyticsContent(controller: controller),
                ),
              ),
            ),
          );
          await finishReads();
          if (find
              .textContaining('Could not load model totals.')
              .evaluate()
              .isNotEmpty) {
            sawUnavailable = true;
            expect(
              find.textContaining('Could not load daily usage.'),
              findsOneWidget,
            );
            await tester.scrollUntilVisible(
              find.byTooltip('Refresh usage'),
              300,
            );
            await tester.tap(find.byTooltip('Refresh usage'));
            await finishReads();
            expect(find.textContaining('Could not load'), findsWidgets);
            debugPrint(
              'Analytics unavailable on visit ${visit + 1}; password POSTs=$loginRequests; Refresh still unavailable.',
            );
            break;
          }
          expect(find.text('USD 4.00'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
        }
        expect(
          sawUnavailable,
          isFalse,
          reason:
              'Normal Analytics reentry must not exhaust password login admission.',
        );
        expect(loginRequests, 1);
        final analytics = requests.where(
          (r) => r.$2.path.startsWith('/api/analytics/'),
        );
        expect(analytics, hasLength(6));
        expect(analytics.map((r) => r.$2.queryParameters['profile']).toSet(), {
          'personal',
          'work',
        });
        // Leaving Analytics retires its readers, not the shared host transport.
        final before = requests.length;
        host.refresh();
        for (
          var attempt = 0;
          attempt < 500 && host.state.refreshing;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(host.state.refreshing, isFalse);
        expect(host.state.stats.error, isNull);
        expect(requests.length, greaterThan(before));
        expect(tester.takeException(), isNull);
      } finally {
        await closeFixture();
      }
    });
  });
}
