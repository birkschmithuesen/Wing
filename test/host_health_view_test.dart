import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_host_health.dart';
import 'package:wing/core/screens/administration/admin_widgets.dart';
import 'package:wing/core/screens/administration/admin_health_page.dart';
import 'package:wing/core/services/administration_health.dart';
import 'package:wing/core/services/host_resources_session.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/host_resources_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_HOST_HEALTH');
  setUpAll(() async {
    if (!capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final (family, file) in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(family)..addFont(
            File(
              '$root/$file',
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });
  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('host-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final path = File('build/host-health/$name.png');
      await path.parent.create(recursive: true);
      await path.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final scenario in [
        'normal',
        'loading',
        'limited',
        'pressure',
        'error',
      ]) {
        testWidgets('Host ${brightness.name} $scale $scenario', (tester) async {
          final fixture = HostResourcesFixture();
          addTearDown(fixture.server.close);
          final session = HostResourcesSession(fixture.server);
          final health = AdministrationHealth(fixture.server);
          addTearDown(session.dispose);
          addTearDown(health.dispose);
          addTearDown(() {
            final gate = fixture.statsGate;
            if (gate != null && !gate.isCompleted) gate.complete();
          });
          if (scenario == 'loading') fixture.statsGate = Completer();
          if (scenario == 'limited') {
            fixture.stats['psutil'] = false;
            for (final key in [
              'cpu_percent',
              'memory',
              'disk',
              'uptime_seconds',
              'process',
            ]) {
              fixture.stats.remove(key);
            }
          }
          if (scenario == 'pressure') {
            (fixture.pressure['memory'] as Map)['pressure'] = 'critical';
            (fixture.pressure['disk'] as Map)['pressure'] = 'elevated';
          }
          if (scenario == 'error') {
            await session.refresh();
            fixture.statsError = StateError('offline');
          }
          tester.view.physicalSize = Size(scale == 2 ? 320 : 393, 852);
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
                  key: const ValueKey('host-capture'),
                  child: child!,
                ),
              ),
              home: Scaffold(
                appBar: AppBar(title: const Text('Health')),
                body: AdminHealthContent(
                  health: health,
                  hostResources: session,
                  profile: null,
                  accessChecks: () => null,
                  onReviewAccess: null,
                  onRefresh: session.refresh,
                  onOpenDestination: (_) async {},
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.takeException(), isNull);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          if (scenario == 'loading') {
            expect(find.text('Reading resources…'), findsNothing);
            expect(find.text('Reading machine details…'), findsNothing);
            expect(find.byType(StudioLoading), findsNothing);
            final refresh = find.byTooltip('Refresh host resources');
            expect(
              find.descendant(
                of: refresh,
                matching: find.byIcon(Icons.refresh),
              ),
              findsOneWidget,
            );
            expect(
              tester
                  .widget<IconButton>(
                    find.byWidgetPredicate(
                      (w) =>
                          w is IconButton &&
                          w.tooltip == 'Refresh host resources',
                    ),
                  )
                  .onPressed,
              isNull,
            );
          } else {
            expect(find.byType(StudioLoading), findsNothing);
          }
          if (scenario != 'loading') {
            expect(find.text('hermes-nas'), findsOneWidget);
          }
          if (scenario == 'limited') {
            expect(
              find.text(
                'Some resource metrics are not supplied by this server.',
              ),
              findsOneWidget,
            );
            expect(find.text('Unavailable'), findsNWidgets(3));
          }
          if (scenario == 'pressure') {
            expect(find.text('Critical pressure'), findsOneWidget);
            expect(find.text('Elevated pressure'), findsOneWidget);
          }
          if (scenario == 'error') {
            expect(
              find.textContaining('Showing the last resource reading.'),
              findsOneWidget,
            );
            expect(find.textContaining('refresh failed'), findsOneWidget);
          }
          await snapshot(tester, '${brightness.name}-$scale-$scenario');
          if (scenario == 'normal') {
            final position = tester
                .state<ScrollableState>(find.byType(Scrollable))
                .position;
            final hostY =
                tester.getTopLeft(find.text('Host')).dy + position.pixels;
            await tester.scrollUntilVisible(find.text('Server'), 200);
            await tester.pumpAndSettle();
            expect(
              hostY,
              lessThan(
                tester.getTopLeft(find.text('Server')).dy + position.pixels,
              ),
            );
            expect(hostY, isPositive);
            await tester.scrollUntilVisible(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Refresh host resources',
              ),
              -200,
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Refresh host resources'));
            await tester.pumpAndSettle();
            expect(fixture.requests, isNotEmpty);
            expect(
              fixture.requests.every((r) => r.$1 == 'GET' && r.$3.isEmpty),
              isTrue,
            );
            await tester.tap(find.text('hermes-nas'));
            await tester.pumpAndSettle();
            expect(find.byType(AdminHostDetailsPage), findsOneWidget);
            expect(find.text('Host resources'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await snapshot(tester, '${brightness.name}-$scale-details');
          }
          await tester.pumpWidget(const SizedBox());
          if (fixture.statsGate case final gate?) {
            gate.complete();
            await tester.pump();
          }
        });
      }
    }
  }

  testWidgets(
    'background and hidden surfaces pause polling and resume safely',
    (tester) async {
      final fixture = HostResourcesFixture();
      final resources = HostResourcesSession(fixture.server);
      addTearDown(fixture.server.close);
      addTearDown(resources.dispose);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminHostHealth(resources: resources)),
        ),
      );
      await tester.pumpAndSettle();
      final initial = fixture.requests.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 1));
      expect(fixture.requests.length, initial);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.requests.length, initial + 2);
      await tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: false,
            child: Scaffold(body: AdminHostHealth(resources: resources)),
          ),
        ),
      );
      await tester.pump();
      final hidden = fixture.requests.length;
      await tester.pump(const Duration(minutes: 1));
      expect(fixture.requests.length, hidden);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final brightness in Brightness.values) {
    for (final enlarged in [false, true]) {
      for (final details in [false, true]) {
        for (final fails in [false, true]) {
          final name =
              '${brightness.name}-${enlarged ? 'large-reduced' : 'normal'}-${details ? 'details' : 'summary'}-${fails ? 'failure' : 'success'}';
          testWidgets('explicit host refresh retains feedback through $name', (
            tester,
          ) async {
            final fixture = HostResourcesFixture();
            final resources = HostResourcesSession(fixture.server);
            addTearDown(fixture.server.close);
            addTearDown(resources.dispose);
            addTearDown(() {
              for (final gate in [fixture.statsGate, fixture.pressureGate]) {
                if (gate != null && !gate.isCompleted) gate.complete();
              }
            });
            tester.view.physicalSize = Size(enlarged ? 320 : 390, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(enlarged ? 2 : 1),
                    disableAnimations: enlarged,
                  ),
                  child: RepaintBoundary(
                    key: const ValueKey('host-capture'),
                    child: child!,
                  ),
                ),
                home: details
                    ? AdminHostDetailsPage(resources: resources)
                    : AdminPage(
                        title: 'Health',
                        scope: 'Home server',
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: AdminHostHealth(resources: resources),
                          ),
                        ),
                      ),
              ),
            );
            await tester.pumpAndSettle();
            final refresh = find.byTooltip('Refresh host resources');
            final title = find
                .text(details ? 'Host resources' : 'Health')
                .first;
            final titleBefore = tester.getRect(title);
            final hostBefore = tester.getRect(find.text('hermes-nas'));
            final reads = fixture.requests.length;
            fixture.statsGate = Completer<void>();
            fixture.pressureGate = Completer<void>();
            await tester.tap(refresh);
            await tester.pump();
            // The shared header publishes its sibling presentation after build.
            await tester.pump();
            final progress = find.byType(StudioLoading);
            expect(progress, findsOneWidget);
            expect(
              tester.widget<StudioLoading>(progress).label,
              'Refreshing host resources',
            );
            expect(tester.getSize(progress).shortestSide, greaterThan(0));
            expect(
              tester.getRect(progress).bottom,
              lessThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
            );
            expect(tester.getRect(title), titleBefore);
            expect(tester.getRect(find.text('hermes-nas')), hostBefore);
            expect(find.text('Refreshing host resources'), findsNothing);
            await snapshot(tester, 'refresh-$name-held');
            await tester.tap(refresh);
            await tester.pump(const Duration(seconds: 2));
            expect(fixture.requests.length, reads + 2);
            expect(progress, findsOneWidget);
            if (fails) {
              fixture.statsError = StateError('private transport error');
            }
            fixture.statsGate!.complete();
            await tester.pump();
            await tester.pump();
            expect(
              progress,
              findsOneWidget,
              reason: 'Pressure read still belongs to the requested refresh.',
            );
            fixture.pressureGate!.complete();
            await tester.pumpAndSettle();
            expect(progress, findsNothing);
            expect(refresh.hitTestable(), findsOneWidget);
            if (details) {
              await tester.scrollUntilVisible(find.text('hermes-nas'), 200);
              await tester.pumpAndSettle();
            }
            expect(find.text('hermes-nas'), findsOneWidget);
            if (fails) {
              if (details) {
                await tester.scrollUntilVisible(refresh, -200);
                await tester.pumpAndSettle();
              }
              expect(
                find.textContaining('Showing the last resource reading.'),
                findsOneWidget,
              );
              fixture.statsError = null;
              fixture.statsGate = null;
              fixture.pressureGate = null;
              await tester.tap(refresh);
              await tester.pumpAndSettle();
              expect(
                find.textContaining('Showing the last resource reading.'),
                findsNothing,
              );
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          });
        }
      }
    }
  }

  testWidgets(
    'automatic host reads remain quiet and detail navigation stays usable',
    (tester) async {
      final fixture = HostResourcesFixture();
      final resources = HostResourcesSession(fixture.server);
      addTearDown(fixture.server.close);
      addTearDown(resources.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AdminPage(
            title: 'Health',
            scope: 'Home server',
            child: SingleChildScrollView(
              child: AdminHostHealth(resources: resources),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.getRect(find.text('hermes-nas'));
      final gate = fixture.statsGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(resources.state.refreshing, isTrue);
      expect(find.byType(StudioLoading), findsNothing);
      expect(tester.getRect(find.text('hermes-nas')), before);
      await tester.tap(find.text('hermes-nas'));
      await tester.pumpAndSettle();
      expect(find.byType(AdminHostDetailsPage), findsOneWidget);
      expect(find.byType(StudioLoading), findsNothing);
      fixture.stats['hostname'] = 'updated-host';
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('updated-host'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('leaving host details retires held refresh feedback', (
    tester,
  ) async {
    final fixture = HostResourcesFixture();
    final resources = HostResourcesSession(fixture.server);
    addTearDown(fixture.server.close);
    addTearDown(resources.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AdminPage(
          title: 'Health',
          scope: 'Home server',
          child: SingleChildScrollView(
            child: AdminHostHealth(resources: resources),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('hermes-nas'));
    await tester.pumpAndSettle();
    final gate = fixture.statsGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await tester.tap(find.byTooltip('Refresh host resources'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AdminHostDetailsPage), findsNothing);
    expect(find.byType(StudioLoading), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(StudioLoading), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
