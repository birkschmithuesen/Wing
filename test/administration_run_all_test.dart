import 'package:wing/core/services/host_resources_session.dart';
import 'support/host_resources_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/administration_operation.dart';
import 'package:wing/core/screens/administration/admin_health_page.dart';
import 'package:wing/core/screens/administration/admin_operations_page.dart';
import 'package:wing/core/services/administration_health.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_error.dart';

import 'support/administration_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_RUN_ALL');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'roboto-regular.ttf',
      'MaterialIcons': 'materialicons-regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '/tmp/wing-header-fonts/${entry.value}',
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
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/run-all-preview/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('run all ${brightness.name} at $scale', (tester) async {
        final fixture = AdministrationFixture();
        final health = AdministrationHealth(fixture.server);
        final host = HostResourcesSession(fixture.server);
        addTearDown(host.dispose);
        addTearDown(health.dispose);
        addTearDown(fixture.server.close);
        final starts = Completer<void>();
        var doctorRunning = true;
        var auditRunning = true;
        fixture.override = (method, path, query, body) async {
          if (path == 'system/stats') return hostStatsPayload();
          if (path == 'status') return hostPressurePayload();
          if (path.startsWith('ops/')) {
            await starts.future;
            return {'ok': true, 'name': path.substring(4), 'pid': 7};
          }
          if (path.startsWith('actions/')) {
            final running = path.contains('/doctor/')
                ? doctorRunning
                : auditRunning;
            return {
              'name': path.split('/')[1],
              'pid': 7,
              'running': running,
              'exit_code': running ? null : 0,
              'lines': ['─' * 60, 'All checks passed! 🎉'],
            };
          }
          throw StateError('Unexpected $method $path');
        };
        tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
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
            home: Scaffold(
              appBar: AppBar(title: const Text('Hermes health')),
              body: AdminHealthContent(
                health: health,
                hostResources: host,
                accessChecks: () => null,
                onReviewAccess: null,
                profile: fixture.server.profile('default'),
                onRefresh: () async => fail('Must not refresh'),
                onOpenDestination: (_) async {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final runAll = find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Run all diagnostics',
        );
        await tester.scrollUntilVisible(runAll, 200);
        await tester.pumpAndSettle();
        bool enabled() => tester.widget<IconButton>(runAll).onPressed != null;
        expect(enabled(), isTrue);
        expect(
          find.descendant(of: runAll, matching: find.byIcon(Icons.refresh)),
          findsOneWidget,
        );
        expect(find.byTooltip('Refresh health'), findsNothing);
        expect(find.textContaining('Runtime profile'), findsNothing);
        expect(
          fixture.requests.map((r) => r.$2),
          unorderedEquals(['system/stats', 'status']),
        );
        fixture.requests.clear();
        await tester.ensureVisible(runAll);
        await tester.pumpAndSettle();
        await snapshot(tester, '${brightness.name}-$scale-idle');
        await tester.tap(runAll);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(AlertDialog), findsNothing);
        expect(enabled(), isFalse);
        expect(
          find.descendant(of: runAll, matching: find.byIcon(Icons.refresh)),
          findsOneWidget,
        );
        expect(find.text('Starting…'), findsNWidgets(2));
        expect(
          fixture.requests.map((r) => r.$2),
          unorderedEquals(['ops/doctor', 'ops/security-audit']),
        );
        await tester.tap(runAll);
        await tester.pump();
        expect(fixture.requests, hasLength(2));
        await snapshot(tester, '${brightness.name}-$scale-starting');
        starts.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(AdminActionPage), findsNothing);
        expect(find.textContaining('Running'), findsNWidgets(2));
        expect(enabled(), isFalse);
        expect(
          find.descendant(of: runAll, matching: find.byIcon(Icons.refresh)),
          findsOneWidget,
        );
        await snapshot(tester, '${brightness.name}-$scale-running');
        doctorRunning = false;
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(enabled(), isFalse);
        expect(
          find.descendant(of: runAll, matching: find.byIcon(Icons.refresh)),
          findsOneWidget,
        );
        expect(find.textContaining('No issues found'), findsOneWidget);
        auditRunning = false;
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(enabled(), isTrue);
        expect(
          find.descendant(of: runAll, matching: find.byIcon(Icons.refresh)),
          findsOneWidget,
        );
        expect(find.textContaining('Completed'), findsOneWidget);
        await snapshot(tester, '${brightness.name}-$scale-completed');
        expect(
          fixture.requests.every((r) => !r.$3.containsKey('profile')),
          isTrue,
        );
        expect(fixture.requests.where((r) => r.$1 == 'POST'), hasLength(2));
        await tester.tap(runAll);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(fixture.requests.where((r) => r.$1 == 'POST'), hasLength(4));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('one failed start does not prevent the other diagnostic', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    final health = AdministrationHealth(fixture.server);
    final host = HostResourcesSession(fixture.server);
    addTearDown(host.dispose);
    addTearDown(health.dispose);
    addTearDown(fixture.server.close);
    fixture.override = (method, path, query, body) async => switch (path) {
      'system/stats' => hostStatsPayload(),
      'status' => hostPressurePayload(),
      'ops/doctor' => throw StateError('Doctor unavailable'),
      'ops/security-audit' => {'ok': true, 'name': 'security-audit', 'pid': 8},
      'actions/security-audit/status' => {
        'name': path.split('/')[1],
        'pid': 8,
        'running': false,
        'exit_code': 1,
        'lines': File('test/fixtures/security_audit.txt').readAsLinesSync(),
      },
      _ => throw StateError('Unexpected $method $path'),
    };
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            RepaintBoundary(key: const ValueKey('capture'), child: child!),
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: AdminHealthContent(
            health: health,
            hostResources: host,
            accessChecks: () => null,
            onReviewAccess: null,
            profile: null,
            onRefresh: () async {},
            onOpenDestination: (_) async {},
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.byTooltip('Run all diagnostics'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Run all diagnostics',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(fixture.requests.where((r) => r.$1 == 'POST'), hasLength(2));
    expect(
      find.widgetWithText(StudioError, 'Start not confirmed'),
      findsOneWidget,
    );
    expect(
      health.diagnostics['ops/security-audit']!.classification,
      AdministrationOperationOutcome.findings,
    );
    expect(find.textContaining('21 vulnerabilities found'), findsOneWidget);
    expect(health.diagnostics.keys, ['ops/security-audit']);
    expect(health.starting, isEmpty);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Run all diagnostics',
            ),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    await snapshot(tester, 'failed-start');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
