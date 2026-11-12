import 'package:wing/core/services/administration_logs_session.dart';
import 'package:wing/core/screens/administration/admin_logs_page.dart';
import 'package:wing/core/models/administration_operation.dart';
import 'support/administration_operation_fixture.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/analytics_content.dart';
import 'package:wing/core/screens/administration/admin_operations_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/administration_design_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_HEALTH_DETAILS');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'roboto-regular.ttf',
      'MaterialIcons': 'materialicons-regular.otf',
      'monospace': 'mono.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '/tmp/wing-header-fonts/${entry.value}',
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });
  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/health-details/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final page in ['usage', 'logs', 'audit']) {
        testWidgets('$page ${brightness.name} at $scale', (tester) async {
          final fixture = AdministrationDesignFixture();
          addTearDown(fixture.server.close);
          if (page != 'usage') {
            fixture.override = (method, path, query, body) async =>
                switch (path) {
                  'logs' => {
                    'file': query['file'],
                    'lines': [
                      '2026-09-18 02:15:03 INFO Gateway connected',
                      '2026-09-18 02:15:05 WARNING Provider connection retry',
                      '2026-09-18 02:15:06 INFO Provider connection restored',
                    ],
                  },
                  'actions/security-audit/status' => {
                    'name': 'security-audit',
                    'pid': 7,
                    'running': false,
                    'exit_code': 0,
                    'lines': [
                      'Security audit completed.',
                      'Review access permissions and local configuration.',
                    ],
                  },
                  _ => throw StateError('Unexpected $path'),
                };
          }
          tester.view.physicalSize = Size(scale == 2 ? 320 : 412, 832);
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
                child: RepaintBoundary(
                  key: const ValueKey('capture'),
                  child: child!,
                ),
              ),
              home: switch (page) {
                'usage' => AnalyticsPage(
                  profile: fixture.server.profile('client-work'),
                ),
                'logs' => AdminLogsPage(
                  createSession: () =>
                      AdministrationLogsSession(fixture.server),
                ),
                _ => AdminActionPage(
                  operation: fixtureOperation(
                    fixture.server,
                    const AdministrationAction('security-audit', 7),
                  ),
                  title: 'Security audit',
                  scope: 'Home server',
                ),
              },
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await snapshot(tester, '$page-${brightness.name}-$scale');
          if (page == 'usage') {
            expect(
              fixture.requests
                  .where((r) => r.$2 == 'analytics/models')
                  .single
                  .$3,
              {'profile': 'client-work', 'days': '7'},
            );
            final group = find.byKey(const ValueKey('usage-breakdown-group'));
            await tester.scrollUntilVisible(
              group,
              120,
              scrollable: find
                  .descendant(
                    of: find.byType(ListView),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(
              find.text('Research model'),
              200,
              scrollable: find
                  .descendant(
                    of: find.byType(ListView),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.ensureVisible(find.text('Research model'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Research model'));
            await tester.pumpAndSettle();
            expect(find.byType(BottomSheet), findsNothing);
            expect(find.text('Research model'), findsOneWidget);
            await snapshot(tester, '$page-${brightness.name}-$scale-breakdown');
          } else {
            expect(fixture.requests, isNotEmpty);
            if (page == 'audit') {
              await tester.tap(find.text('Diagnostic output'));
              await tester.pumpAndSettle();
            }
            expect(
              find.textContaining(
                page == 'logs'
                    ? 'Gateway connected'
                    : 'Security audit completed.',
              ),
              findsOneWidget,
            );
            expect(
              fixture.requests.every(
                (r) => r.$1 == 'GET' && !r.$3.containsKey('profile'),
              ),
              isTrue,
            );
            await tester.drag(
              find.byType(Scrollable).first,
              const Offset(0, -450),
            );
            await tester.pumpAndSettle();
            await snapshot(tester, '$page-${brightness.name}-$scale-lower');
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
