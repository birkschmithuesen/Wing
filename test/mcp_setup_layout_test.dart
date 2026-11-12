import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_connectors_page.dart';
import 'package:wing/core/screens/administration/admin_mcp_setup_page.dart';
import 'package:wing/core/services/mcp_oauth.dart';
import 'package:wing/core/services/mcp_setup.dart';
import 'package:wing/core/widgets/studio_select.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/administration_fixture.dart';

void main() {
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
  for (final brightness in Brightness.values) {
    for (final enlarged in [false, true]) {
      for (final page in [
        'setup',
        'headers',
        'bearer',
        'none',
        'program',
        'advanced',
        'callback',
      ]) {
        final name =
            '$page-${brightness.name}-${enlarged ? 'large' : 'normal'}';
        testWidgets('MCP setup and callback controls remain reachable: $name', (
          tester,
        ) async {
          tester.view.physicalSize = Size(enlarged ? 320 : 390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = AdministrationFixture('Claw');
          fixture.configs['personal']!['mcp_servers'] = {
            'aspire': {
              'url': 'https://aspire-mcp.aspireapp.com/mcp',
              'auth': 'oauth',
            },
          };
          fixture.rpcOverride = (method, params) async => {
            'ok': true,
            'status': 'pending',
            'session_id': 'flow',
            'flow': 'pkce',
            if (method.endsWith('.start'))
              'auth_url': Uri.https('example.test', '/authorize', {
                'state': 'fixture-state',
                'redirect_uri': params['client_redirect_uri'] as String,
              }).toString(),
          };
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
                home: page != 'callback'
                    ? AdminMcpSetupPage(
                        createSession: () =>
                            McpSetupSession(fixture.server.profile('personal')),
                      )
                    : AdminMcpSignIn(
                        createFlow: () => McpOAuth(
                          profile: fixture.server.profile('personal'),
                          name: 'aspire',
                          bindLoopback: (target, _) async =>
                              McpLoopback(close: () async {}),
                        ),
                        openBrowser: (_) async => true,
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          Future<void> reveal(Finder target) async {
            await tester.scrollUntilVisible(
              target,
              160,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
          }

          Future<void> select(Finder target, String option) async {
            await reveal(target);
            await tester.tap(target);
            await tester.pumpAndSettle();
            await tester.tap(find.text(option).last);
            await tester.pumpAndSettle();
          }

          if (page == 'callback') {
            await reveal(find.text('Start sign-in'));
            await tester.tap(find.text('Start sign-in'));
          } else if (page == 'program') {
            await select(find.byType(StudioSelect<bool>), 'Program on Hermes');
            await reveal(find.byTooltip('Add environment variable'));
            await tester.tap(find.byTooltip('Add environment variable'));
          } else if (['headers', 'bearer', 'none'].contains(page)) {
            await select(
              find.byType(StudioSelect<McpAuthentication>),
              switch (page) {
                'headers' => 'Custom headers',
                'bearer' => 'API key / bearer token',
                _ => 'No authentication',
              },
            );
            if (page == 'headers') {
              await reveal(find.byTooltip('Add header'));
              await tester.tap(find.byTooltip('Add header'));
            }
          } else if (page == 'advanced') {
            await reveal(find.text('Advanced'));
            await tester.tap(find.text('Advanced'));
            await tester.pumpAndSettle();
            await reveal(find.text('Client ID'));
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          Future<void> captureScreen(String suffix) async {
            if (!capture) return;
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File('build/mcp-review/$name$suffix.png');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }

          await captureScreen('');
          if (page == 'advanced') {
            await reveal(find.text('Registered callback address'));
            await captureScreen('-callback-field');
          }

          final commit = page == 'callback'
              ? find.text('Complete sign-in')
              : find.byTooltip(
                  ['setup', 'advanced'].contains(page)
                      ? 'Add connector and sign in'
                      : 'Add connector',
                );
          if (page == 'callback') await reveal(commit);
          expect(commit.hitTestable(), findsOneWidget);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await captureScreen('-action');
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
