import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';
import 'package:wing/core/services/profile_connectors_session.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_connectors_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/services/mcp_error.dart';
import 'package:wing/core/screens/administration/admin_connector_routes.dart';
import 'package:wing/core/services/mcp_oauth.dart';
import 'package:wing/core/services/ws_client.dart';
import 'support/administration_fixture.dart';

AdministrationFixture fixtureWith(Map<String, dynamic> result) {
  final fixture = AdministrationFixture('Claw');
  fixture.override = (method, path, query, body) async {
    if (path == 'mcp/servers') {
      return {
        'servers': [
          {
            'name': 'aspire',
            'auth': 'oauth',
            'transport': 'http',
            'enabled': true,
            'source': 'config',
            'plugin': null,
          },
        ],
      };
    }
    if (path == 'profiles') {
      return {
        'profiles': [
          {'name': 'personal'},
        ],
      };
    }
    if (path == 'profiles/active') return {'current': 'personal'};
    if (path == 'config') {
      return {
        'mcp_servers': {
          'aspire': {'url': 'https://example.test/mcp', 'auth': 'oauth'},
        },
      };
    }
    return Map<String, dynamic>.from(result);
  };
  return fixture;
}

Future<McpLoopback> fakeLoopback(
  Uri target,
  Future<bool> Function(Uri) receive,
) async => McpLoopback(close: () async {});

Map<String, dynamic> started(Map<String, dynamic> params) => {
  'ok': true,
  'session_id': 'oauth-session',
  'flow': 'pkce',
  'auth_url': Uri.https('oauth.example.test', '/authorize', {
    'state': 'fixture-state',
    'redirect_uri': params['client_redirect_uri'] as String,
  }).toString(),
};

Future<void> testConnection(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.text('Test connection'), 200);
  await tester.tap(find.text('Test connection'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Test'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'connector probe uses accessible progress without repeated text',
    (tester) async {
      final fixture = fixtureWith({'ok': true, 'tools': []});
      addTearDown(fixture.server.close);
      final get = fixture.override!;
      final gate = Completer<Map<String, dynamic>>();
      fixture.override = (method, path, query, body) =>
          method == 'POST' ? gate.future : get(method, path, query, body);
      await tester.pumpWidget(
        MaterialApp(
          home: AdminConnectorDetail(
            createRoute: () {
              final parent = ProfileConnectorsSession(
                fixture.server.profile('personal'),
              );
              addTearDown(parent.dispose);
              return parent.openDetail('aspire', signInOnOpen: false);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Test'));
      await tester.pump();
      expect(find.text('Testing connection…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(StudioLoading), findsNothing);
      expect(find.bySemanticsLabel('Testing connection'), findsOneWidget);
      gate.complete({'ok': true, 'tools': []});
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
    },
  );

  testWidgets(
    'MCP sign-in starts a profile-scoped loopback flow with paste-back',
    (tester) async {
      final fixture = fixtureWith({});
      final calls = <(String, Map<String, dynamic>)>[];
      fixture.rpcOverride = (method, params) async {
        calls.add((method, {...params}));
        return method.endsWith('.start') ? started(params) : {'ok': true};
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
      expect(calls.single.$1, 'mcp.servers.oauth.start');
      expect(calls.single.$2['profile'], 'personal');
      expect(
        Uri.parse(calls.single.$2['client_redirect_uri'] as String).host,
        '127.0.0.1',
      );
      expect(find.widgetWithText(TextField, 'Callback URL'), findsOneWidget);
      expect(find.text('Complete sign-in'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  const capture = bool.fromEnvironment('CAPTURE_MCP');
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

  test('MCP errors redact credentials while retaining the failure reason', () {
    final message = mcpErrorMessage(
      'OAuth discovery failed: HTTP 401 at '
      'https://owner:fixture-pass@example.test/mcp?token=fixture-query#fixture-fragment\n'
      'Authorization: Bearer fixture-bearer\n'
      'Cookie: session=fixture-cookie; second=fixture-second\n'
      'client_secret="fixture-secret" access_token=fixture-token',
      summary: 'Sign-in did not complete.',
    );
    expect(message, contains('OAuth discovery failed: HTTP 401'));
    expect(message, contains('example.test/mcp'));
    expect(message, isNot(contains('fixture-')));
    for (final error in [
      null,
      '',
      '  ',
      {'token': 'fixture-token'},
    ]) {
      expect(mcpErrorMessage(error, summary: 'Failed.'), 'Failed.');
    }
  });

  testWidgets(
    'failed MCP probe shows the server reason in its captured profile',
    (tester) async {
      final fixture = fixtureWith({
        'ok': false,
        'error': 'OAuth authentication required — no token found.',
        'tools': [],
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: AdminConnectorDetail(
            createRoute: () {
              final parent = ProfileConnectorsSession(
                fixture.server.profile('personal'),
              );
              addTearDown(parent.dispose);
              return parent.openDetail('aspire', signInOnOpen: false);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await testConnection(tester);
      expect(find.text('Connection failed'), findsOneWidget);
      expect(
        find.textContaining('OAuth authentication required'),
        findsNothing,
      );
      await tester.tap(find.text('Failure details'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('OAuth authentication required'),
        findsOneWidget,
      );
      expect(find.text('The server rejected this change.'), findsNothing);
      expect(find.textContaining('Connected'), findsNothing);
      final request = fixture.requests.singleWhere((r) => r.$1 == 'POST');
      expect(request.$2, 'mcp/servers/aspire/test');
      expect(request.$3, {'profile': 'personal'});
    },
  );

  for (final polled in [false, true]) {
    testWidgets(
      'MCP sign-in shows ${polled ? 'polled' : 'immediate'} error reason',
      (tester) async {
        final response = <String, dynamic>{
          'flow_id': 'fixture-flow',
          'status': polled ? 'authorization_required' : 'error',
          'error': polled ? null : 'OAuth discovery failed: HTTP 404.',
        };
        final fixture = fixtureWith(response);
        fixture.rpcOverride = (method, params) async {
          if (method.endsWith('.start') && polled) return started(params);
          if (method.endsWith('.poll')) {
            return {
              'ok': true,
              'status': 'error',
              'error_message': 'OAuth discovery failed: HTTP 404.',
            };
          }
          throw JsonRpcError(
            method,
            'OAuth discovery failed: HTTP 404.',
            code: 5024,
          );
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
        if (polled) {
          response['status'] = 'error';
          response['error'] = 'OAuth discovery failed: HTTP 404.';
          await tester.pump(const Duration(seconds: 3));
          await tester.pumpAndSettle();
        }
        expect(
          find.textContaining('OAuth discovery failed: HTTP 404.'),
          findsOneWidget,
        );
        expect(find.text('Open sign-in page'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('a failed retest clears the previous successful capabilities', (
    tester,
  ) async {
    final response = <String, dynamic>{
      'ok': true,
      'tools': [
        {'name': 'fixture_tool', 'description': ''},
      ],
      'prompts': 2,
      'resources': 1,
    };
    final fixture = fixtureWith(response);
    await tester.pumpWidget(
      MaterialApp(
        home: AdminConnectorDetail(
          createRoute: () {
            final parent = ProfileConnectorsSession(
              fixture.server.profile('personal'),
            );
            addTearDown(parent.dispose);
            return parent.openDetail('aspire', signInOnOpen: false);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await testConnection(tester);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('fixture_tool'), findsNothing);
    await tester.tap(find.text('Available tools (1)'));
    await tester.pumpAndSettle();
    expect(find.text('fixture_tool'), findsOneWidget);
    response.addAll({
      'ok': false,
      'error': 'Connection timed out.',
      'tools': [],
    });
    await testConnection(tester);
    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('Available tools (1)'), findsNothing);
    expect(find.textContaining('Connection timed out.'), findsNothing);
    await tester.tap(find.text('Failure details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connection timed out.'), findsOneWidget);
    expect(find.textContaining('Connected'), findsNothing);
    expect(find.text('fixture_tool'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final enlarged in [false, true]) {
      for (final operation in [
        'test',
        'signin',
        'reload',
        'reconnect-page',
        'reconnect-confirm',
        'tools',
        'tools-open',
      ]) {
        final signIn = operation == 'signin';
        final reload = operation == 'reload';
        final reconnect = operation.startsWith('reconnect-');
        final success = operation.startsWith('tools');
        final name =
            '$operation-${brightness.name}-${enlarged ? 'large' : 'normal'}';
        testWidgets('MCP layout $name', (tester) async {
          tester.view.physicalSize = Size(enlarged ? 320 : 390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = fixtureWith({
            if (!signIn) 'ok': success,
            'flow_id': 'fixture-flow',
            'status': 'error',
            'error':
                'OAuth discovery failed: HTTP 404 at https://example.test/mcp.',
            'tools': success
                ? [
                    {
                      'name': 'get_accounting_settings',
                      'description':
                          'Read accounting settings for this business.',
                    },
                    {
                      'name': 'list_chart_of_accounts',
                      'description':
                          'List accounts and their codes, names and categories.',
                    },
                    {
                      'name': 'list_journals',
                      'description': 'List journal entries for this business.',
                    },
                  ]
                : [],
            'servers': [],
          });
          if (reload || signIn) {
            fixture.rpcOverride = (method, _) async => throw JsonRpcError(
              method,
              'OAuth discovery failed: HTTP 404 at https://example.test/mcp.',
              code: 5015,
            );
          }
          await tester.pumpWidget(
            RepaintBoundary(
              key: const ValueKey('capture'),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(enlarged ? 2 : 1)),
                  child: child!,
                ),
                home: reload || reconnect
                    ? profileConnectorsPage(fixture.server.profile('personal'))
                    : signIn
                    ? AdminMcpSignIn(
                        createFlow: () => McpOAuth(
                          profile: fixture.server.profile('personal'),
                          name: 'aspire',
                          bindLoopback: fakeLoopback,
                        ),
                      )
                    : AdminConnectorDetail(
                        createRoute: () {
                          final parent = ProfileConnectorsSession(
                            fixture.server.profile('personal'),
                          );
                          addTearDown(parent.dispose);
                          return parent.openDetail(
                            'aspire',
                            signInOnOpen: false,
                          );
                        },
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (reconnect) {
            await tester.scrollUntilVisible(
              find.byTooltip('Reconnect MCP tools'),
              200,
            );
            await tester.ensureVisible(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Reconnect MCP tools',
              ),
            );
            await tester.pumpAndSettle();
            if (operation == 'reconnect-confirm') {
              await tester.tap(find.byTooltip('Reconnect MCP tools'));
              await tester.pumpAndSettle();
              expect(find.byType(AlertDialog), findsOneWidget);
              expect(
                find.textContaining('all profiles on this server'),
                findsWidgets,
              );
              expect(fixture.rpcRequests, [('personal', 'mcp.servers.status')]);
            }
          } else if (reload) {
            await tester.scrollUntilVisible(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Reconnect MCP tools',
              ),
              200,
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Reconnect MCP tools'));
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Reconnect tools'));
            await tester.pumpAndSettle();
          } else if (signIn) {
            await tester.scrollUntilVisible(find.text('Start sign-in'), 200);
            await tester.tap(find.text('Start sign-in'));
            await tester.pumpAndSettle();
          } else {
            await testConnection(tester);
          }
          if (success) {
            expect(find.text('Connected'), findsOneWidget);
            expect(find.text('get_accounting_settings'), findsNothing);
            if (operation == 'tools-open') {
              await tester.scrollUntilVisible(
                find.text('Available tools (3)'),
                100,
              );
              await tester.tap(find.text('Available tools (3)'));
              await tester.pumpAndSettle();
              expect(find.text('get_accounting_settings'), findsOneWidget);
            }
          } else if (!reload && !reconnect) {
            if (!signIn) {
              await tester.scrollUntilVisible(
                find.text('Failure details'),
                100,
              );
              await tester.tap(find.text('Failure details'));
              await tester.pumpAndSettle();
            }
            await tester.scrollUntilVisible(
              find.textContaining('OAuth discovery failed'),
              -200,
            );
            await tester.pumpAndSettle();
          }
          if (!success && !reconnect) {
            expect(
              find.textContaining('OAuth discovery failed'),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
          if (capture) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File('build/mcp-review/$name.png');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          if (!reload && !reconnect) {
            await tester.scrollUntilVisible(
              signIn ? find.byTooltip('Close') : find.text('Remove connector'),
              200,
            );
          }
          if (operation == 'reconnect-confirm') {
            await tester.tap(find.byTooltip('Reconnect tools'));
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsNothing);
            expect(fixture.rpcRequests, [
              ('personal', 'mcp.servers.status'),
              ('default', 'reload.mcp'),
            ]);
            expect(find.text('MCP tools reconnected.'), findsOneWidget);
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
