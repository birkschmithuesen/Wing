import 'package:wing/core/models/administration_operation.dart';
import 'support/administration_operation_fixture.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_operations_page.dart';
import 'package:wing/core/screens/administration/admin_runtime_health.dart';
import 'package:wing/core/services/administration_health.dart';
import 'package:wing/core/theme/wing_theme.dart';

import 'support/administration_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_SECURITY_AUDIT');
  final lines = File('test/fixtures/security_audit.txt').readAsLinesSync();
  const summary = '21 vulnerabilities found across 177 components';

  setUpAll(() async {
    if (!capture) return;
    for (final font in {
      'Roboto': 'roboto-regular.ttf',
      'MaterialIcons': 'materialicons-regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '/tmp/wing-header-fonts/${font.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
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
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/security-audit-preview/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Security audit groups ${brightness.name} at $scale text', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = AdministrationFixture();
        addTearDown(fixture.server.close);
        var runs = 0;
        fixture.override = (method, path, query, body) async {
          return {
            'name': 'security-audit',
            'pid': 7,
            'running': false,
            'exit_code': 1,
            'lines': lines,
          };
        };
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
            home: AdminActionPage(
              operation: fixtureOperation(
                fixture.server,
                const AdministrationAction('security-audit', 7),
              ),
              title: 'Security audit',
              onRunAgain: () async {
                runs++;
              },
              scope: 'Home server',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(summary), findsOneWidget);
        for (final label in [
          'High · 4',
          'Moderate · 6',
          'Low · 2',
          'Unknown · 9',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text('Critical · 0'), findsNothing);
        expect(find.text('Failed'), findsNothing);
        expect(find.text('Completed'), findsNothing);
        expect(find.text(lines.join('\n')), findsNothing);
        expect(fixture.requests.single.$3, {'lines': '2000'});
        expect(tester.takeException(), isNull);
        await snapshot(tester, '${brightness.name}-$scale-summary');

        await tester.ensureVisible(find.text('High · 4'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('High · 4'));
        await tester.pumpAndSettle();
        expect(find.text('httpcore2 2.7.0'), findsOneWidget);
        expect(find.text('Fixed in: 2.10.0'), findsNWidgets(2));
        expect(find.text('venv · GHSA-7mj9-2mp8-4m2p'), findsNWidgets(2));
        await tester.ensureVisible(find.text('httpcore2 2.7.0'));
        await tester.pumpAndSettle();
        await snapshot(tester, '${brightness.name}-$scale-expanded');
        await tester.ensureVisible(find.text('High · 4'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('High · 4'));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Audit notices'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Audit notices'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('did not restart running gateways'),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Audit notices'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Audit notices'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Diagnostic output'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Diagnostic output'));
        await tester.pumpAndSettle();
        expect(find.text(lines.join('\n')), findsOneWidget);
        await tester.ensureVisible(find.text('Diagnostic output'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Diagnostic output'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Refresh result'), findsNothing);
        expect(find.text('Run Security audit again'), findsNothing);
        await tester.tap(find.byTooltip('Run Security audit again'));
        await tester.pumpAndSettle();
        expect(find.text(summary), findsOneWidget);
        expect(runs, 1);
        expect(fixture.requests.every((r) => r.$1 == 'GET'), isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final (name, running, exitCode, output, expected) in [
    ('running', true, null, lines, 'Running'),
    (
      'incomplete',
      false,
      0,
      lines.take(15).toList(),
      'Audit summary unavailable',
    ),
    ('unknown', false, null, lines, 'Audit summary unavailable'),
    (
      'failed',
      false,
      2,
      ['audit failed: OSV batch query failed: offline'],
      'Failed',
    ),
    (
      'healthy',
      false,
      0,
      ['No known vulnerabilities found across 177 component(s).'],
      'No known vulnerabilities found across 177 components',
    ),
  ]) {
    testWidgets('Security audit $name preserves its actual outcome', (
      tester,
    ) async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      fixture.override = (method, path, query, body) async => {
        'name': 'security-audit',
        'pid': 7,
        'running': running,
        'exit_code': exitCode,
        'lines': output,
      };
      final operation = fixtureOperation(
        fixture.server,
        const AdministrationAction('security-audit', 7),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AdminActionPage(
            operation: operation,
            title: 'Security audit',
            scope: 'Home server',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(expected), findsOneWidget);
      if (name == 'running' || name == 'unknown') {
        expect(find.textContaining('Last updated '), findsOneWidget);
        expect(find.textContaining('Checked '), findsNothing);
      }
      expect(find.text(summary), findsNothing);
      expect(find.text('High · 4'), findsNothing);
      expect(find.text(output.join('\n')), findsNothing);
      await tester.tap(find.text('Diagnostic output'));
      await tester.pumpAndSettle();
      expect(find.text(output.join('\n')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      operation.dispose();
    });
  }

  testWidgets('Health shows audit count when background polling completes', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    final health = AdministrationHealth(fixture.server);
    addTearDown(health.dispose);
    addTearDown(fixture.server.close);
    var running = true;
    fixture.override = (method, path, query, body) async => switch (path) {
      'profiles/active' => {'current': 'default'},
      'profiles' => {
        'profiles': [
          {'name': 'default', 'is_default': true},
        ],
      },
      'ops/security-audit' => {'ok': true, 'name': 'security-audit', 'pid': 7},
      'actions/security-audit/status' => {
        'name': 'security-audit',
        'pid': 7,
        'running': running,
        'exit_code': running ? null : 1,
        'lines': lines,
      },
      _ => throw StateError('Unexpected $method $path'),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminRuntimeHealth(health: health)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Security audit'),
        matching: find.text('Run'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Run'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AdminActionPage), findsNothing);
    expect(find.textContaining('21 vulnerabilities found'), findsNothing);
    running = false;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('21 vulnerabilities found'), findsOneWidget);
    expect(find.byType(AdminActionPage), findsNothing);
    await tester.tap(find.text('Security audit'));
    await tester.pumpAndSettle();
    expect(find.text(summary), findsOneWidget);
    expect(find.text('Failed'), findsNothing);
    expect(fixture.requests.where((r) => r.$1 == 'POST'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
