import 'package:wing/core/services/chat_outputs_session.dart';
import 'package:wing/core/services/usage_analytics.dart';
import 'package:wing/core/services/usage_analytics_session.dart';
import 'package:wing/core/models/provider_inventory.dart';
import 'package:wing/core/screens/administration/admin_provider_credentials.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_connectors_page.dart';
import 'package:wing/core/screens/administration/admin_usage_dashboard.dart';
import 'package:wing/core/screens/chat_outputs_screen.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/mcp_oauth.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'support/administration_fixture.dart';
import 'administration_mcp_test.dart' show fixtureWith, started, fakeLoopback;
import 'read_recovery_test.dart' show resume;

Future<void> exhaustReadRetries(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

void main() {
  for (final temporary in [true, false]) {
    testWidgets(
      'provider status recovers temporary=$temporary without restarting sign-in',
      (tester) async {
        final fixture = AdministrationFixture();
        addTearDown(fixture.server.close);
        var fail = true;
        fixture.override = (method, path, query, body) async {
          if (path == 'profiles') {
            return {
              'profiles': [
                {'name': 'personal'},
              ],
            };
          }
          if (path == 'profiles/active') return {'current': 'personal'};
          if (path.endsWith('/start')) {
            return {
              'session_id': 'session',
              'flow': 'device_code',
              'verification_url': 'https://example.invalid/sign-in',
              'expires_in': 900,
              'user_code': 'code',
              'poll_interval': 60,
            };
          }
          if (path.contains('/poll/')) {
            if (fail) {
              if (temporary) throw TimeoutException('offline');
              throw const FormatException('invalid status');
            }
            return {'session_id': 'session', 'status': 'approved'};
          }
          throw StateError('Unexpected request');
        };
        await tester.pumpWidget(
          MaterialApp(
            home: AdminProviderSignIn(
              profile: fixture.server.profile('personal'),
              target: const ProviderSignInTarget(
                id: 'provider',
                name: 'Provider',
              ),
            ),
          ),
        );
        await tester.tap(find.text('Start sign-in'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Check status'));
        await exhaustReadRetries(tester);
        final before = fixture.requests.length;
        fail = false;
        await resume(tester);
        await tester.pumpAndSettle();
        expect(fixture.requests.length, before + (temporary ? 1 : 0));
        expect(fixture.requests.where((r) => r.$1 != 'GET').length, 1);
        expect(
          fixture.requests
              .where((r) => r.$2.startsWith('providers/'))
              .every((r) => r.$3['profile'] == 'personal'),
          isTrue,
        );
        if (temporary) {
          expect(find.textContaining('Sign-in saved.'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('browser return reads the existing pending provider session', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    addTearDown(fixture.server.close);
    fixture.override = (_, path, _, _) async {
      if (path == 'profiles') {
        return {
          'profiles': [
            {'name': 'personal'},
          ],
        };
      }
      if (path == 'profiles/active') return {'current': 'personal'};
      return path.endsWith('/start')
          ? {
              'session_id': 'session',
              'flow': 'device_code',
              'verification_url': 'https://example.invalid/sign-in',
              'user_code': 'fixture-code',
              'expires_in': 900,
              'poll_interval': 60,
            }
          : {'session_id': 'session', 'status': 'approved'};
    };
    await tester.pumpWidget(
      MaterialApp(
        home: AdminProviderSignIn(
          profile: fixture.server.profile('personal'),
          target: const ProviderSignInTarget(id: 'provider', name: 'Provider'),
        ),
      ),
    );
    await tester.tap(find.text('Start sign-in'));
    await tester.pumpAndSettle();
    await resume(tester);
    await tester.pumpAndSettle();
    expect(
      fixture.requests
          .where((r) => r.$2.startsWith('providers/'))
          .map((r) => r.$2),
      [
        'providers/oauth/provider/start',
        'providers/oauth/provider/poll/session',
      ],
    );
    await resume(tester);
    await tester.pumpAndSettle();
    expect(fixture.requests.length, 4);
  });

  testWidgets(
    'MCP poll resumes after failure, keeping pasted callback and session',
    (tester) async {
      final fixture = fixtureWith({});
      addTearDown(fixture.server.close);
      var fail = true;
      var approved = false;
      fixture.rpcOverride = (method, params) async {
        if (method.endsWith('.start')) return started(params);
        if (method.endsWith('.poll')) {
          if (fail) throw TimeoutException('offline');
          return {'ok': true, 'status': approved ? 'approved' : 'pending'};
        }
        throw StateError('Unexpected mutation $method');
      };
      await tester.pumpWidget(
        MaterialApp(
          home: AdminMcpSignIn(
            createFlow: () => McpOAuth(
              profile: fixture.server.profile('personal'),
              name: 'aspire',
              bindLoopback: fakeLoopback,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start sign-in'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'unsent callback');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      fail = false;
      await resume(tester);
      await tester.pumpAndSettle();
      expect(find.text('unsent callback'), findsOneWidget);
      approved = true;
      await resume(tester);
      await tester.pumpAndSettle();
      expect(fixture.rpcRequests.map((r) => r.$2), [
        'mcp.servers.oauth.start',
        'mcp.servers.oauth.poll',
        'mcp.servers.oauth.poll',
        'mcp.servers.oauth.poll',
      ]);
      expect(find.textContaining('Signed in.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(fixture.rpcRequests.length, 4);
    },
  );

  testWidgets(
    'outputs retry the failed page without opening or sharing files',
    (tester) async {
      final offsets = <int>[];
      var fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ChatOutputsScreen(
            chatTitle: 'Chat',
            createSession: () => ChatOutputsSession(
              loadHistory: (offset) async {
                offsets.add(offset);
                if (offset == 1 && fail) throw TimeoutException('offline');
                return ProfileHistoryPage(
                  'chat',
                  [
                    {
                      'role': 'assistant',
                      'content': '[file$offset](/tmp/file$offset.txt)',
                    },
                  ],
                  offset,
                  1,
                  isComplete: offset == 1,
                );
              },
              download: (_) => throw StateError('Unexpected download'),
              readText: (_) => throw StateError('Unexpected preview'),
              deliver: (_) => throw StateError('Unexpected share'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load older outputs'));
      await tester.pumpAndSettle();
      expect(find.text('/tmp/file0.txt'), findsOneWidget);
      fail = false;
      await resume(tester);
      await tester.pumpAndSettle();
      expect(offsets, [0, 1, 1]);
      expect(find.text('/tmp/file0.txt'), findsOneWidget);
      expect(find.text('/tmp/file1.txt'), findsOneWidget);
      await resume(tester);
      expect(offsets, [0, 1, 1]);
    },
  );

  testWidgets('usage recovers only failed aggregates and keeps healthy cache', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    addTearDown(fixture.server.close);
    var fail = true;
    fixture.override = (_, path, query, _) async {
      if (fail && (path == 'analytics/models' || query['days'] == '365')) {
        throw TimeoutException('offline');
      }
      return path == 'analytics/models' ? {'models': []} : {'daily': []};
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UsageDashboard(
            createSession: () => UsageAnalyticsSession(
              UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
            ),
          ),
        ),
      ),
    );
    await exhaustReadRetries(tester);
    expect(
      fixture.requests
          .where((r) => r.$3['days'] == '7' && r.$2 == 'analytics/usage')
          .length,
      1,
    );
    final before = fixture.requests.length;
    fail = false;
    await resume(tester);
    await tester.pumpAndSettle();
    expect(fixture.requests.length, before + 2);
    expect(
      fixture.requests
          .where((r) => r.$3['days'] == '7' && r.$2 == 'analytics/usage')
          .length,
      1,
    );
    expect(find.textContaining('Could not load'), findsNothing);
    await resume(tester);
    await tester.pumpAndSettle();
    expect(fixture.requests.length, before + 2);
  });

  testWidgets('outputs leave access failures for explicit retry', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatOutputsScreen(
          chatTitle: 'Chat',
          createSession: () => ChatOutputsSession(
            loadHistory: (_) async {
              calls++;
              throw DashboardHttpException(401, 'Unauthorized');
            },
            download: (_) => throw StateError('Unexpected download'),
            readText: (_) => throw StateError('Unexpected preview'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await resume(tester);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });
}
