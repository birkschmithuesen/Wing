import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/services/doctor_finding_draft_session.dart';
import 'package:wing/core/models/administration_operation.dart';
import 'support/administration_operation_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/administration/admin_operations_page.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/wing_icons.dart';

import 'support/administration_fixture.dart';
import 'support/profile_browser_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_DOCTOR');
  const summary =
      'Found 3 issue(s) to address:\n\n'
      '1. state.db is large — enable sessions.auto_prune in config.yaml\n'
      '2. Browser tools (agent-browser) has 2 npm vulnerabilities\n'
      '3. web workspace has 6 npm vulnerabilities\n\n'
      "Tip: run 'hermes doctor --fix' to auto-fix what's possible.";
  final lines = ['  ✓ Profiles checked', '─' * 60, summary];

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
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
    await (FontLoader('WingIcons')..addFont(
          File(
            'assets/fonts/wing-icons.ttf',
          ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
        ))
        .load();
  });

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/doctor-preview/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Doctor summary ${brightness.name} at $scale text', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = AdministrationFixture();
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: SavedConnection(
              id: fixture.id,
              label: fixture.id,
              host: 'localhost',
              port: 1,
              apiKey: '',
            ),
            dashboardOAuth: null,
          ),
          connectionIdentity: fixture.server.connectionIdentity,
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: ProfileBrowserFixture().gateway,
        );
        await controller.initialize();
        addTearDown(controller.dispose);
        var runs = 0;
        var opening = Completer<void>();
        var opened = 0;
        addTearDown(() {
          if (!opening.isCompleted) opening.complete();
        });
        fixture.override = (method, path, query, body) async {
          return {
            'name': 'doctor',
            'pid': 7,
            'running': false,
            'exit_code': 1,
            'lines': lines,
          };
        };
        final operation = fixtureOperation(
          fixture.server,
          const AdministrationAction('doctor', 7),
        );
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
              operation: operation,
              title: 'Doctor',
              createDraftSession: () =>
                  DoctorFindingDraftSession(operation, controller),
              onOpenSession: (_) {
                opened++;
                return opening.future;
              },
              onRunAgain: () async {
                runs++;
              },
              scope: 'Home server',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('3 issues found'), findsOneWidget);
        expect(find.text('Failed'), findsNothing);
        expect(find.text('Ask Hermes'), findsNWidgets(3));
        expect(find.text(lines.join('\n')), findsNothing);
        expect(find.text('Completed'), findsNothing);
        expect(find.text('state.db is large'), findsOneWidget);
        expect(find.text('2 npm vulnerabilities'), findsOneWidget);
        expect(find.text('Check progress'), findsNothing);
        expect(find.text(summary), findsNothing);
        expect(tester.takeException(), isNull);
        await snapshot(tester, '${brightness.name}-$scale');

        await tester.ensureVisible(find.text('Ask Hermes').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ask Hermes').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(find.bySemanticsLabel('Opening chat'), findsOneWidget);
        expect(opened, 1);
        expect(find.byIcon(WingIcons.newChat), findsNWidgets(3));
        expect(
          tester
              .widgetList<TextButton>(find.byType(TextButton))
              .every((button) => button.onPressed == null),
          isTrue,
        );
        await snapshot(tester, '${brightness.name}-$scale-opening');
        opening.completeError(StateError('Chat connection unavailable'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not open the chat.').hitTestable(),
          findsOneWidget,
        );
        await snapshot(tester, '${brightness.name}-$scale-chat-error');
        expect(find.bySemanticsLabel('Opening chat'), findsNothing);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        opening = Completer<void>();
        await tester.ensureVisible(find.text('Ask Hermes').last);
        await tester.tap(find.text('Ask Hermes').last);
        await tester.pump();
        await tester.pump();
        expect(find.bySemanticsLabel('Opening chat'), findsOneWidget);
        expect(opened, 2);
        opening.complete();
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Opening chat'), findsNothing);

        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(
          find.text('Diagnostic output'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Diagnostic output'));
        await tester.pumpAndSettle();
        expect(find.text(lines.join('\n')), findsOneWidget);
        await tester.ensureVisible(find.text('Diagnostic output'));
        await tester.tap(find.text('Diagnostic output'));
        await tester.pumpAndSettle();

        await tester.pumpAndSettle();
        await snapshot(tester, '${brightness.name}-$scale-bottom');
        expect(find.byTooltip('Refresh result'), findsNothing);
        expect(find.text('Run Doctor again'), findsNothing);
        await tester.tap(find.byTooltip('Run Doctor again'));
        await tester.pumpAndSettle();
        expect(find.text('3 issues found'), findsOneWidget);
        expect(runs, 1);
        expect(fixture.requests.where((r) => r.$1 != 'GET'), isEmpty);
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
        await tester.pumpAndSettle();
        await snapshot(tester, '${brightness.name}-$scale-run-action');
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final failed in [false, true]) {
      testWidgets('Doctor outcome ${brightness.name} failed=$failed', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = AdministrationFixture();
        fixture.override = (method, path, query, body) async => {
          'name': 'doctor',
          'pid': 7,
          'running': false,
          'exit_code': failed ? 1 : 0,
          'lines': failed
              ? ['Doctor could not finish: configuration is unreadable.']
              : ['─' * 60, 'All checks passed! 🎉'],
        };
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            builder: (context, child) =>
                RepaintBoundary(key: const ValueKey('capture'), child: child!),
            home: AdminActionPage(
              operation: fixtureOperation(
                fixture.server,
                const AdministrationAction('doctor', 7),
              ),
              title: 'Doctor',
              scope: 'Home server',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(failed ? 'Failed' : 'No issues found'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await snapshot(
          tester,
          '${brightness.name}-${failed ? 'failed' : 'healthy'}',
        );
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'running Doctor uses a status timestamp ${brightness.name} at $scale text',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = AdministrationFixture();
          var running = true;
          fixture.override = (method, path, query, body) async => {
            'name': 'doctor',
            'pid': 7,
            'running': running,
            'exit_code': running ? null : 0,
            'lines': running ? lines : ['Operation done'],
          };
          final operation = fixtureOperation(
            fixture.server,
            const AdministrationAction('doctor', 7),
          );
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: const ValueKey('capture'),
                child: AdminActionPage(
                  operation: operation,
                  title: 'Doctor',
                  scope: 'Home server',
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Running'), findsOneWidget);
          expect(find.textContaining('Last updated '), findsOneWidget);
          expect(find.textContaining('Checked '), findsNothing);
          expect(find.text(summary), findsNothing);
          expect(tester.takeException(), isNull);
          await snapshot(tester, '${brightness.name}-$scale-running');
          running = false;
          await operation.refresh();
          await tester.pumpAndSettle();
          expect(find.text('Running'), findsNothing);
          expect(find.textContaining('Last updated '), findsNothing);
          expect(find.textContaining('Checked '), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          operation.dispose();
        },
      );
    }
  }
}
