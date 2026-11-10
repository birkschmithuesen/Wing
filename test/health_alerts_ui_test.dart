import 'package:wing/core/services/health_alert_incident_store.dart';
import 'package:wing/core/screens/health_alert_health_screen.dart';
import 'package:wing/core/widgets/health_alerts/health_alert_notice.dart';
import 'package:wing/core/models/health_alert.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/health_alert_settings_screen.dart';
import 'package:wing/core/screens/administration/admin_health_page.dart';
import 'package:wing/core/services/background_monitoring_service.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/health_alert_settings_session.dart';
import 'package:wing/core/services/health_alert_settings_store.dart';
import 'package:wing/core/services/health_alerts_coordinator.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/compact_switch.dart';
import 'package:wing/core/widgets/health_alerts/health_alerts_scope.dart';
import 'package:wing/core/services/administration_overview.dart';
import 'package:wing/core/screens/administration/admin_connectors_page.dart';
import 'support/administration_fixture.dart';
import 'package:wing/core/screens/administration/admin_providers_page.dart';
import 'package:wing/core/screens/administration/admin_defaults_page.dart';
import 'package:wing/core/screens/administration/admin_scheduled_tasks_page.dart';
import 'package:wing/core/screens/profile_capabilities_screen.dart';
import 'support/host_resources_fixture.dart';
import 'support/health_alerts_fixture.dart';
import 'package:wing/core/widgets/studio_loading.dart';

class _DelayedSettingsStore extends HealthAlertSettingsStore {
  _DelayedSettingsStore(super.preferences);
  final gate = Completer<void>();
  bool fail = true;
  @override
  Future<void> write(HealthAlertSettings settings) async {
    await gate.future;
    if (fail) throw StateError('Storage unavailable');
    await super.write(settings);
  }
}

class _DelayedIncidentStore extends HealthAlertIncidentStore {
  _DelayedIncidentStore(super.preferences);
  Completer<void>? gate;
  bool fail = false;
  @override
  Future<void> write(String connection, List<HealthAlert> alerts) async {
    if (gate case final held?) await held.future;
    if (fail) throw StateError('Storage unavailable');
    await super.write(connection, alerts);
  }
}

void main() {
  const capture = bool.fromEnvironment('CAPTURE_ALERTS');
  setUpAll(() async {
    // Touch-target and enlarged-text checks need the production font metrics.
    final packages =
        jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
            as Map;
    final flutter = (packages['packages'] as List).cast<Map>().firstWhere(
      (p) => p['name'] == 'flutter',
    );
    final sdk = Directory.fromUri(
      File(
        '.dart_tool/package_config.json',
      ).absolute.uri.resolve(flutter['rootUri'] as String),
    ).parent.parent;
    final root = const String.fromEnvironment('CAPTURE_FONT_DIR').isEmpty
        ? '${sdk.path}/bin/cache/artifacts/material_fonts'
        : const String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final (family, file) in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(family)..addFont(
            File(
              '$root/$file',
            ).readAsBytes().then((v) => v.buffer.asByteData()),
          ))
          .load();
    }
  });
  Future<void> shot(WidgetTester tester, String name) async {
    if (!capture) return;
    final previousShadows = debugDisableShadows;
    void repaintShadows() {
      for (final object in tester.allRenderObjects) {
        if (object is RenderPhysicalModel || object is RenderPhysicalShape) {
          object.markNeedsPaint();
        }
      }
    }

    debugDisableShadows = false;
    repaintShadows();
    await tester.pump();
    try {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture-alerts')),
      );
      await tester.runAsync(() async {
        final img = await boundary.toImage(pixelRatio: 1);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        const output = String.fromEnvironment('CAPTURE_ALERT_DIR');
        await Directory(output).create(recursive: true);
        await File(
          '$output/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        img.dispose();
      });
    } finally {
      debugDisableShadows = previousShadows;
      repaintShadows();
      await tester.pump();
    }
  }

  testWidgets('main menu opens current Alerts including silenced issues', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final fixture = HealthAlertsFixture(await SharedPreferences.getInstance());
    await fixture.settings.update(
      (current) => current.copyWith(enabled: false),
    );
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      HealthAlertsScope(
        alerts: fixture.coordinator,
        openAlert: (_) async {},
        child: MaterialApp(
          home: Scaffold(
            key: scaffold,
            drawer: AppDrawer(
              selected: AppDestination.chats,
              onSelected: (_) => fail('Alerts should keep the current route'),
            ),
            body: const Text('Current workspace'),
          ),
        ),
      ),
    );

    Future<void> openAlerts() async {
      scaffold.currentState!.openDrawer();
      await tester.pumpAndSettle();
      final entry = find.byKey(const ValueKey('nav-alerts'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(scaffold.currentState!.isDrawerOpen, isFalse);
      expect(find.byType(Dialog), findsOneWidget);
    }

    await openAlerts();
    expect(find.text('No current alerts.'), findsOneWidget);
    await tester.tap(find.byTooltip('Close alerts'));
    await tester.pumpAndSettle();

    void report(String scope, String title) =>
        fixture.coordinator.observeOperationalError(
          fixture.owner,
          scope: scope,
          title: title,
          detail: 'Try refreshing again.',
          failed: true,
        );
    report('group:one', 'Group updates failed');
    report('host-resources', 'Host resources could not refresh');
    final alerts = fixture.coordinator.alerts;
    await fixture.coordinator.acknowledge(alerts.first);
    await fixture.coordinator.snooze(alerts.last);
    expect(fixture.coordinator.attentionAlerts, isEmpty);
    await openAlerts();
    expect(find.text('Group updates failed'), findsOneWidget);
    expect(find.text('Acknowledged.'), findsOneWidget);
    await tester.tap(find.byTooltip('Next issue'));
    await tester.pumpAndSettle();
    expect(find.text('Host resources could not refresh'), findsOneWidget);
    expect(find.textContaining('Snoozed until'), findsOneWidget);
    expect(find.byTooltip('Open Hermes health'), findsNothing);
    await tester.tap(find.byTooltip('Close alerts'));
    await tester.pumpAndSettle();
    expect(find.text('Current workspace'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets(
    'overlapping thresholds explain how to correct the unsaved rule',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final session = HealthAlertSettingsSession(
        HealthAlertSettingsStore(prefs),
      );
      await tester.pumpWidget(
        MaterialApp(home: HealthAlertSettingsScreen(session: session)),
      );
      await tester.tap(find.text('Memory usage'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), '50');
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Not saved: clear below 85% must be lower than alert above 50%.',
        ),
        findsOneWidget,
      );
      expect(session.error, isNull);
      expect(session.settings.rules.values.first.warnAbove, 90);
      expect(
        HealthAlertSettingsStore(prefs).read().rules.values.first.warnAbove,
        90,
      );
      await tester.enterText(fields.at(3), '45');
      await tester.pumpAndSettle();
      expect(find.textContaining('Not saved:'), findsNothing);
      final saved = HealthAlertSettingsStore(prefs).read().rules.values.first;
      expect(saved.warnAbove, 50);
      expect(saved.clearBelow, 45);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'Back never blocks autosave; failed edits remain retryable on return',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = _DelayedSettingsStore(prefs);
      final session = HealthAlertSettingsSession(store);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: IconButton(
                tooltip: 'Open alert settings',
                icon: const Icon(Icons.warning_amber_rounded),
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HealthAlertSettingsScreen(session: session),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Open alert settings'));
      await tester.pumpAndSettle();
      expect(
        find.text('Monitor host thresholds and profile health on this device.'),
        findsOneWidget,
      );
      await tester.tap(
        find.widgetWithText(CompactSwitchListTile, 'Health alerts'),
      );
      await tester.pump();
      expect(session.saving, isTrue);
      expect(session.value.enabled, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(HealthAlertSettingsScreen), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      store.gate.complete();
      await tester.pumpAndSettle();
      expect(session.error, isNotNull);
      expect(session.settings.enabled, isTrue);
      await tester.tap(find.byTooltip('Open alert settings'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CompactSwitchListTile>(
              find.widgetWithText(CompactSwitchListTile, 'Health alerts'),
            )
            .value,
        isFalse,
      );
      expect(
        find.textContaining('Previous settings remain active'),
        findsOneWidget,
      );
      store.fail = false;
      await tester.tap(find.byTooltip('Retry saving alert settings'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Previous settings remain active'),
        findsNothing,
      );
      expect(HealthAlertSettingsStore(prefs).read().enabled, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'collection follows foreground routes or the existing active task monitor',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
      );
      await fixture.owner.hostResources().refresh();
      final count = fixture.host.requests.length;
      fixture.coordinator.setForeground(false);
      await tester.pump(const Duration(seconds: 60));
      expect(fixture.host.requests, hasLength(count));
      fixture.owner.working = true;
      fixture.owner.publishActivity();
      await tester.pump(const Duration(seconds: 60));
      expect(fixture.host.requests, hasLength(count));
      fixture.monitoring.value = BackgroundMonitoringState.active;
      await fixture.owner.hostResources().refresh();
      expect(fixture.host.requests.length, greaterThan(count));
      fixture.monitoring.value = BackgroundMonitoringState.idle;
      final stopped = fixture.host.requests.length;
      await tester.pump(const Duration(seconds: 60));
      expect(fixture.host.requests, hasLength(stopped));
      fixture.coordinator.setForeground(true);
      await fixture.owner.hostResources().refresh();
      expect(fixture.host.requests.length, greaterThan(stopped));
      fixture.owner.mountedRoute = false;
      fixture.owner.publishActivity();
      final retired = fixture.host.requests.length;
      await tester.pump(const Duration(seconds: 60));
      expect(fixture.host.requests, hasLength(retired));
      fixture.dispose();
    },
  );
  Widget healthContent(HealthAlertsFixture fixture) => AdminHealthContent(
    health: fixture.owner.healthSession().health,
    hostResources: fixture.owner.hostResources(),
    profile: null,
    onRefresh: fixture.owner.hostResources().refresh,
    onOpenDestination: (_) async {},
    accessChecks: () => null,
    onReviewAccess: null,
  );

  void expectSavingFeedback(WidgetTester tester) {
    final pending = find.byType(StudioLoading);
    expect(pending, findsOneWidget);
    // The passive glyph deliberately ignores taps. Prove its rendered bounds
    // remain inside the dialog rather than requiring pointer admission.
    final glyph = tester.getRect(pending);
    final dialog = tester.getRect(find.byType(Dialog));
    expect(glyph.width, greaterThan(0));
    expect(glyph.height, greaterThan(0));
    expect(dialog.intersect(glyph), glyph);
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final action in ['Acknowledge issue', 'Snooze for 30 minutes']) {
        testWidgets('alert choice saving feedback $action $brightness $scale', (
          tester,
        ) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final store = _DelayedIncidentStore(prefs);
          final fixture = HealthAlertsFixture(prefs, incidentStore: store);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: scale == 2,
                ),
                child: HealthAlertsScope(
                  alerts: fixture.coordinator,
                  openAlert: (_) async {},
                  child: RepaintBoundary(
                    key: const ValueKey('capture-alerts'),
                    child: child!,
                  ),
                ),
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  appBar: WingAppBar(
                    context: context,
                    title: const Text('Chats'),
                  ),
                ),
              ),
            ),
          );
          await fixture.critical();
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
          await tester.pumpAndSettle();
          store.gate = Completer<void>();
          await tester.tap(find.byTooltip(action));
          await tester.pump();
          await tester.pump();
          expectSavingFeedback(tester);
          expect(find.text('Acknowledged.'), findsNothing);
          for (final icon in [Icons.done, Icons.snooze_outlined]) {
            expect(
              tester
                  .widget<IconButton>(find.widgetWithIcon(IconButton, icon))
                  .onPressed,
              isNull,
            );
          }
          expect(
            tester
                .widget<IconButton>(
                  find.byWidgetPredicate(
                    (w) => w is IconButton && w.tooltip == 'Close alerts',
                  ),
                )
                .onPressed,
            isNotNull,
          );
          await tester.pump(const Duration(seconds: 12));
          expectSavingFeedback(tester);
          await shot(
            tester,
            'choice-held-${brightness.name}-$scale-${action.startsWith('Acknowledge') ? 'ack' : 'snooze'}',
          );
          store.fail = true;
          store.gate!.complete();
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(
            find.textContaining('Could not save').hitTestable(),
            findsOneWidget,
          );
          expect(fixture.coordinator.attentionAlerts, hasLength(1));
          await shot(
            tester,
            'choice-failed-${brightness.name}-$scale-${action.startsWith('Acknowledge') ? 'ack' : 'snooze'}',
          );
          store.fail = false;
          store.gate = Completer<void>();
          await tester.tap(find.byTooltip(action));
          await tester.pump();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          store.gate!.complete();
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(
            action == 'Acknowledge issue'
                ? find.text('Acknowledged.')
                : find.textContaining('Snoozed until'),
            findsOneWidget,
          );
          expect(fixture.coordinator.attentionAlerts, isEmpty);
          await shot(
            tester,
            'choice-saved-${brightness.name}-$scale-${action.startsWith('Acknowledge') ? 'ack' : 'snooze'}',
          );
          await tester.tap(find.byTooltip('Close alerts'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('health-alert-bell')), findsNothing);
          await tester.pumpWidget(const SizedBox());
          fixture.dispose();
        });
      }
    }
  }

  testWidgets('closing the dialog keeps its pending snooze save alive', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _DelayedIncidentStore(prefs);
    final fixture = HealthAlertsFixture(prefs, incidentStore: store);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        builder: (_, child) => HealthAlertsScope(
          alerts: fixture.coordinator,
          openAlert: (_) async {},
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: WingAppBar(context: context, title: const Text('Chats')),
            body: healthContent(fixture),
          ),
        ),
      ),
    );
    await fixture.critical();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
    await tester.pumpAndSettle();
    store.gate = Completer<void>();
    await tester.tap(find.byTooltip('Snooze for 30 minutes'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    await tester.tap(find.byTooltip('Close alerts'));
    await tester.pumpAndSettle();
    expect(fixture.coordinator.saving, isTrue);
    store.gate!.complete();
    await tester.pumpAndSettle();
    expect(fixture.coordinator.saving, isFalse);
    expect(fixture.coordinator.attentionAlerts, isEmpty);
    await tester.tap(find.byKey(const ValueKey('health-alerts-entry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Snoozed until'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('header counts only issues that need attention', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fixture = HealthAlertsFixture(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        builder: (context, child) => HealthAlertsScope(
          alerts: fixture.coordinator,
          openAlert: (_) async {},
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: WingAppBar(context: context, title: const Text('Chats')),
          ),
        ),
      ),
    );
    await fixture.critical();
    await fixture.critical(metric: 'disk');
    await tester.pumpAndSettle();
    expect(fixture.coordinator.alerts, hasLength(2));
    expect(find.text('2'), findsOneWidget);
    final acknowledged = fixture.coordinator.alerts.first;
    await fixture.coordinator.acknowledge(acknowledged);
    await tester.pumpAndSettle();
    expect(fixture.coordinator.attentionAlerts, hasLength(1));
    expect(find.text('1'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(
      find.byTooltip('Health alerts: 1 issue needs attention'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
    await tester.pumpAndSettle();
    expect(find.text(acknowledged.title), findsNothing);
    expect(find.byTooltip('Next issue'), findsNothing);
    await tester.tap(find.byTooltip('Close alerts'));
    await tester.pumpAndSettle();
    final remaining = fixture.coordinator.attentionAlerts.single;
    await fixture.coordinator.snooze(remaining);
    await tester.pumpAndSettle();
    expect(fixture.coordinator.attentionAlerts, isEmpty);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byKey(const ValueKey('health-alert-bell')), findsNothing);
    expect(find.byType(Badge), findsNothing);
    await fixture.owner.hostResources().refresh();
    await tester.pumpAndSettle();
    expect(fixture.coordinator.alerts, hasLength(2));
    expect(fixture.coordinator.attentionAlerts, isEmpty);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        builder: (context, child) => HealthAlertsScope(
          alerts: fixture.coordinator,
          openAlert: (_) async {},
          child: child!,
        ),
        home: Scaffold(body: healthContent(fixture)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('2 current issues · 1 acknowledged · 1 snoozed'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('health-alerts-entry')));
    await tester.pumpAndSettle();
    expect(find.text('Acknowledged.'), findsOneWidget);
    await tester.tap(find.byTooltip('Next issue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Snoozed until'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });
  testWidgets(
    'snooze expiry reminds once; acknowledge cancels reminders across resume',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      SharedPreferences.setMockInitialValues({});
      final fixture = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
      );
      // Fake owner time remains just after the fixture's real sample timestamps.
      var now = DateTime.now().add(const Duration(seconds: 5));
      final coordinator = HealthAlertsCoordinator(
        registry: fixture.registry,
        settings: fixture.settings,
        monitoring: fixture.monitoring,
        incidents: HealthAlertIncidentStore(fixture.preferences),
        now: () => now,
      );
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          theme: wingTheme(Brightness.light),
          builder: (context, child) => HealthAlertsScope(
            alerts: coordinator,
            openAlert: (_) async {},
            child: HealthAlertNotice(navigatorKey: navigatorKey, child: child!),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              appBar: WingAppBar(context: context, title: const Text('Chats')),
            ),
          ),
        ),
      );
      await fixture.critical();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Dismiss health notice'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Snooze for 30 minutes'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Dismiss health notice'), findsNothing);
      expect(find.textContaining('Snoozed until'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.byKey(const ValueKey('health-alert-bell')), findsNothing);
      // Stop collection so the reminder must fire without a new host observation.
      fixture.owner.mountedRoute = false;
      fixture.owner.publishActivity();
      now = now.add(const Duration(minutes: 29));
      await tester.pump(const Duration(minutes: 29));
      expect(find.byTooltip('Dismiss health notice'), findsNothing);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Dismiss health notice'), findsOneWidget);
      expect(find.textContaining('Snoozed until'), findsNothing);
      expect(find.byKey(const ValueKey('health-alert-bell')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(find.byTooltip('Dismiss health notice'), findsNothing);
      // Further publications of this occurrence must not repeat the notice.
      fixture.owner.publishActivity();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Dismiss health notice'), findsNothing);
      // Expiry while inactive waits for foreground return, without polling.
      await tester.tap(find.byTooltip('Snooze for 30 minutes'));
      await tester.pumpAndSettle();
      coordinator.setForeground(false);
      now = now.add(const Duration(minutes: 30));
      await tester.pump(const Duration(minutes: 30));
      expect(find.byTooltip('Dismiss health notice'), findsNothing);
      coordinator.setForeground(true);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Dismiss health notice'), findsOneWidget);
      await tester.tap(find.byTooltip('Snooze for 30 minutes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Acknowledge issue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Acknowledged.'), findsOneWidget);
      var publications = 0;
      void changed() => publications++;
      coordinator.addListener(changed);
      now = now.add(const Duration(minutes: 30));
      await tester.pump(const Duration(minutes: 30));
      expect(publications, 0); // Acknowledge cancels the pending deadline.
      coordinator.removeListener(changed);
      coordinator.setForeground(false);
      now = now.add(const Duration(hours: 1));
      await tester.pump(const Duration(hours: 1));
      coordinator.setForeground(true);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Dismiss health notice'), findsNothing);
      expect(coordinator.alerts.single.acknowledged, isTrue);
      await tester.tap(find.byTooltip('Close alerts'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('health-alert-bell')), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      await tester.pumpWidget(const SizedBox());
      coordinator.dispose();
      fixture.dispose();
    },
  );
  testWidgets('Health drill-down returns to the untouched editor', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final fixture = HealthAlertsFixture(await SharedPreferences.getInstance());
    await fixture.owner.hostResources().refresh();
    await fixture.critical();
    final alert = fixture.coordinator.alerts.single;
    final text = TextEditingController(text: 'Unsent instruction');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextField(controller: text),
                IconButton(
                  tooltip: 'Inspect health',
                  icon: const Icon(Icons.health_and_safety_outlined),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => HealthAlertHealthScreen(
                        controller: fixture.owner,
                        alert: alert,
                        onConnections: () {},
                        onOpenSession: (_) async {},
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Inspect health'));
    await tester.pumpAndSettle();
    expect(find.byType(HealthAlertHealthScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(HealthAlertHealthScreen), findsNothing);
    expect(text.text, 'Unsent instruction');
    await tester.pumpWidget(const SizedBox());
    text.dispose();
    fixture.dispose();
  });
  for (final (destination, pageType) in [
    ('Access and connectors', AdminProvidersPage),
    ('Models and reasoning', AdminDefaultsPage),
    ('Skills and tools', ProfileCapabilitiesScreen),
    ('Scheduled tasks', AdminScheduledTasksPage),
  ]) {
    testWidgets('profile alert opens $destination directly', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final admin = AdministrationFixture();
      final fixture = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
        repository: admin.server,
      );
      fixture.owner.connectionStatus.accessAvailable();
      fixture.owner.connectionStatus.liveChanged('fixture', true);
      final alert = HealthAlert(
        id: 'issue',
        connectionIdentity: admin.server.connectionIdentity,
        connectionLabel: admin.id,
        scope: HealthAlertScope.profile,
        profileName: 'work',
        title: 'Translated problem title',
        detail: 'Needs attention',
        severity: HealthAlertSeverity.warning,
        observedAt: DateTime.now(),
        occurrence: 1,
        destination: destination,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: HealthAlertHealthScreen(
            controller: fixture.owner,
            alert: alert,
            onConnections: () {},
            onOpenSession: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(pageType), findsOneWidget);
      expect(find.text('Hermes health'), findsNothing);
      expect(fixture.owner.current, isNull);
      expect(admin.requests.where((r) => r.$1 != 'GET'), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
      admin.server.close();
    });
  }
  testWidgets(
    'connection failures share one alert and recover from live observations',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
      );
      final connection = fixture.owner.connectionStatus;
      connection.accessAvailable();
      connection.liveChanged('chat', true);
      await fixture.owner.hostResources().refresh();
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => HealthAlertsScope(
            alerts: fixture.coordinator,
            openAlert: (_) async {},
            child: HealthAlertNotice(navigatorKey: navigatorKey, child: child!),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              appBar: WingAppBar(
                context: context,
                title: const Text('Recents'),
              ),
            ),
          ),
        ),
      );
      // A chat-local failure does not establish a gateway outage.
      connection.failRecovery('missing-chat', 'Chat no longer exists');
      await tester.pump();
      expect(fixture.coordinator.alerts, isEmpty);
      connection.endRecovery('missing-chat');
      connection.liveChanged('chat', false);
      await tester.pump();
      expect(fixture.coordinator.alerts, hasLength(1));
      final occurrence = fixture.coordinator.alerts.single.occurrence;
      expect(find.byKey(const ValueKey('health-alert-bell')), findsOneWidget);
      expect(find.byTooltip('Dismiss health notice'), findsOneWidget);

      // Every failing refresh/recovery belongs to this same occurrence.
      for (final failure in [
        const SocketException('offline'),
        TimeoutException('timed out'),
        const DashboardHttpException(401, '/auth'),
        const HandshakeException('certificate rejected'),
      ]) {
        connection.accessFailed(failure);
        connection.beginRecovery('chat');
        await tester.pump();
        expect(fixture.coordinator.alerts, hasLength(1));
        expect(fixture.coordinator.alerts.single.occurrence, occurrence);
      }
      await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Connection interrupted'), findsWidgets);
      await tester.tap(find.byTooltip('Acknowledge issue'));
      await tester.pump();
      await tester.tap(find.byTooltip('Close alerts'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.coordinator.alerts.single.acknowledged, isTrue);
      expect(find.byKey(const ValueKey('health-alert-bell')), findsNothing);
      connection.liveChanged('another-profile', false);
      await tester.pump();
      expect(fixture.coordinator.alerts.single.occurrence, occurrence);
      expect(fixture.coordinator.alerts.single.acknowledged, isTrue);

      // HTTP success or starting retry alone cannot clear failed live sockets.
      connection.accessAvailable();
      connection.liveChanged('chat', true);
      connection.endRecovery('chat');
      await tester.pump();
      expect(fixture.coordinator.alerts, hasLength(1));
      connection.liveChanged('another-profile', true);
      await tester.pump();
      expect(fixture.coordinator.alerts, isEmpty);
      connection.liveChanged('chat', false);
      await tester.pump();
      expect(
        fixture.coordinator.alerts.single.occurrence,
        greaterThan(occurrence),
      );
      expect(fixture.coordinator.alerts.single.acknowledged, isFalse);
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'connection alert recovery controls ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = HealthAlertsFixture(
            await SharedPreferences.getInstance(),
          );
          final connection = fixture.owner.connectionStatus;
          connection.accessAvailable();
          connection.liveChanged('chat', true);
          await fixture.owner.hostResources().refresh();
          final navigatorKey = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: navigatorKey,
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: RepaintBoundary(
                  key: const ValueKey('capture-alerts'),
                  child: HealthAlertsScope(
                    alerts: fixture.coordinator,
                    openAlert: (alert) async {
                      expect(
                        alert.connectionIdentity,
                        fixture.owner.connectionIdentity,
                      );
                      expect(alert.scope, HealthAlertScope.connection);
                      await showServerConnectionDetails(
                        navigatorKey.currentContext!,
                        label: connection.label,
                        status: connection,
                      );
                    },
                    child: HealthAlertNotice(
                      navigatorKey: navigatorKey,
                      child: child!,
                    ),
                  ),
                ),
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  appBar: WingAppBar(
                    context: context,
                    title: const Text('Recents'),
                    contextRow: ServerConnectionLabel(
                      label: connection.label,
                      status: connection,
                    ),
                  ),
                ),
              ),
            ),
          );
          connection.liveChanged('chat', false);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Connection interrupted'), findsWidgets);
          expect(find.byTooltip('Dismiss health notice'), findsNothing);
          final openDetails = find.descendant(
            of: find.byType(Dialog),
            matching: find.byTooltip('Open connection details'),
          );
          expect(openDetails, findsOneWidget);
          await shot(tester, 'connection-alert-${brightness.name}-$scale');
          await tester.tap(openDetails);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Connection details'), findsOneWidget);
          expect(find.byTooltip('Retry connection'), findsOneWidget);
          for (final recovered in [false, true]) {
            final gate = Completer<void>();
            connection.retry = () async {
              connection.beginRecovery('chat');
              await gate.future;
              connection.liveChanged('chat', recovered);
              connection.endRecovery('chat');
            };
            await tester.ensureVisible(find.byTooltip('Retry connection'));
            await tester.pump();
            await tester.tap(find.byTooltip('Retry connection'));
            await tester.pump();
            expect(find.text('Reconnecting'), findsOneWidget);
            expect(fixture.coordinator.alerts, hasLength(1));
            if (!recovered) {
              await shot(tester, 'connection-retry-${brightness.name}-$scale');
            }
            gate.complete();
            await tester.pump();
            expect(
              fixture.coordinator.alerts,
              recovered ? isEmpty : hasLength(1),
            );
          }
          expect(find.text('Connected'), findsOneWidget);
          expect(find.byTooltip('Retry connection'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          fixture.dispose();
        },
      );
    }
  }
  testWidgets(
    'one application notice is transient and opens details only by intent',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
      );
      await fixture.owner.hostResources().refresh();
      var opens = 0;
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => HealthAlertsScope(
            alerts: fixture.coordinator,
            openAlert: (_) async {
              opens++;
            },
            child: HealthAlertNotice(navigatorKey: navigatorKey, child: child!),
          ),
          home: const Scaffold(body: Text('Conversation')),
        ),
      );
      await fixture.critical();
      await tester.pump();
      expect(find.text('Critical memory pressure'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.text('Critical memory pressure'));
      expect(opens, 1);
      await tester.pump();
      expect(find.text('Critical memory pressure'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Critical memory pressure'), findsNothing);
      await fixture.critical();
      await tester.pump();
      expect(find.text('Critical memory pressure'), findsNothing);
      await fixture.settings.update(
        (policy) => policy.copyWith(
          rules: {
            for (final e in policy.rules.entries)
              e.key: HealthAlertRule(
                enabled: false,
                warnAbove: e.value.warnAbove,
                clearBelow: e.value.clearBelow,
                alertMinutes: e.value.alertMinutes,
                clearMinutes: e.value.clearMinutes,
              ),
          },
        ),
      );
      final requests = fixture.host.requests.length;
      await tester.pump(const Duration(seconds: 45));
      expect(fixture.host.requests, hasLength(requests));
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final failedCount in [1, 2]) {
        testWidgets(
          'connector alert opens captured recovery $failedCount ${brightness.name}/$scale',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 393 : 320, 852);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            SharedPreferences.setMockInitialValues({});
            final admin = AdministrationFixture();
            var failProbe = true;
            final removedNames = <String>{};
            final names = [
              'broken / docs',
              if (failedCount == 2) 'broken calendar',
            ];
            admin.override = (method, path, query, body) async {
              if (path == 'system/stats') {
                return hostStatsPayload();
              }
              if (path == 'status') {
                return hostPressurePayload();
              }
              if (path == 'profiles') {
                return {
                  'profiles': [
                    {'name': 'work', 'is_default': false},
                    {'name': 'personal', 'is_default': false},
                    {'name': 'default', 'is_default': true},
                  ],
                };
              }
              if (path == 'profiles/active') {
                return {'current': 'default', 'active': 'work'};
              }
              expect(query['profile'], 'work');
              if (path == 'mcp/servers') {
                return {
                  'servers': [
                    for (final name in [...names, 'healthy'])
                      if (!removedNames.contains(name))
                        {
                          'name': name,
                          'enabled': true,
                          'transport': 'http',
                          'auth': 'oauth',
                          'source': 'config',
                          'plugin': null,
                        },
                  ],
                };
              }
              if (method == 'DELETE') {
                removedNames.add(Uri.decodeComponent(path.split('/').last));
                return {'ok': true};
              }
              expect(method, 'POST');
              return {
                'ok': !failProbe || path.contains('/healthy/'),
                'tools': [],
                'error': 'Sign-in expired',
              };
            };
            final fixture = HealthAlertsFixture(
              await SharedPreferences.getInstance(),
              repository: admin.server,
            );
            fixture.owner.connectionStatus.accessAvailable();
            fixture.owner.connectionStatus.liveChanged('fixture', true);
            final overview = AdministrationOverview(
              admin.server.profile('work'),
            );
            fixture.owner.healthSession().health.selectProfile(overview);
            await overview.refresh(keys: {'connectors'}, testConnectors: true);
            final captured = fixture.coordinator.alerts.single;
            expect(fixture.coordinator.ownerFor(captured), fixture.owner);
            expect(captured.destination, 'MCP connectors');
            expect(captured.connectorNames, names);
            final other = AdministrationOverview(
              admin.server.profile('personal'),
            );
            fixture.owner.healthSession().health.selectProfile(other);
            expect(fixture.coordinator.alerts.single.lastKnown, isTrue);
            expect(fixture.coordinator.alerts.single.connectorNames, names);
            admin.requests.clear();
            final navigatorKey = GlobalKey<NavigatorState>();
            final draft = TextEditingController(
              text: 'Unsent connector question',
            );
            final opened = <HealthAlert>[];
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: navigatorKey,
                theme: wingTheme(brightness),
                builder: (context, child) => HealthAlertsScope(
                  alerts: fixture.coordinator,
                  openAlert: (alert) async {
                    opened.add(alert);
                    await navigatorKey.currentState!.push<void>(
                      MaterialPageRoute(
                        builder: (_) => HealthAlertHealthScreen(
                          controller: fixture.owner,
                          alert: alert,
                          onConnections: () {},
                          onOpenSession: (_) async {},
                        ),
                      ),
                    );
                  },
                  child: MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: RepaintBoundary(
                      key: const ValueKey('capture-alerts'),
                      child: HealthAlertNotice(
                        navigatorKey: navigatorKey,
                        child: child!,
                      ),
                    ),
                  ),
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    appBar: WingAppBar(
                      context: context,
                      title: const Text('Conversation'),
                    ),
                    body: TextField(controller: draft),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
            await tester.pumpAndSettle();
            final action = failedCount == 1
                ? 'Open connector ${names.single}'
                : 'Open MCP connectors';
            expect(find.byTooltip(action), findsOneWidget);
            expect(
              tester.getSize(find.byTooltip(action)).height,
              greaterThanOrEqualTo(48),
            );
            await shot(
              tester,
              'connector-dialog-$failedCount-${brightness.name}-$scale',
            );
            await tester.tap(find.byTooltip('Acknowledge issue'));
            await tester.pumpAndSettle();
            expect(find.text('Acknowledged.'), findsOneWidget);
            expect(
              find.byKey(const ValueKey('health-alert-bell')),
              findsNothing,
            );
            await tester.tap(find.text('Connector settings'));
            await tester.pumpAndSettle();
            expect(opened.single.profileName, 'work');
            expect(find.byType(Dialog), findsNothing);
            if (failedCount == 2) {
              expect(find.byType(AdminConnectorsPage), findsOneWidget);
              expect(find.text('Failed health check · http'), findsNWidgets(2));
              await shot(tester, 'connector-list-${brightness.name}-$scale');
              await tester.tap(find.text(names.first));
              await tester.pumpAndSettle();
            }
            expect(find.byType(AdminConnectorDetail), findsOneWidget);
            expect(find.text(names.first), findsOneWidget);
            expect(find.text('Test connection'), findsOneWidget);
            expect(find.text('Sign in'), findsOneWidget);
            expect(admin.requests.where((r) => r.$1 != 'GET'), isEmpty);
            expect(
              admin.requests.where((r) => r.$2 == 'mcp/servers'),
              isNotEmpty,
            );
            expect(
              admin.requests
                  .where((r) => r.$2 == 'mcp/servers')
                  .every((r) => r.$3['profile'] == 'work'),
              isTrue,
            );
            expect(tester.takeException(), isNull);
            await shot(
              tester,
              'connector-detail-$failedCount-${brightness.name}-$scale',
            );
            await tester.tap(find.text('Test connection'));
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Test'));
            await tester.pumpAndSettle();
            expect(
              admin.requests.last.$2,
              'mcp/servers/broken%20%2F%20docs/test',
            );
            expect(admin.requests.last.$3['profile'], 'work');
            expect(find.text('Connection failed'), findsOneWidget);
            await tester.pageBack();
            await tester.pumpAndSettle();
            if (failedCount == 2) {
              await tester.pageBack();
              await tester.pumpAndSettle();
            }
            expect(find.text('Unsent connector question'), findsOneWidget);
            expect(draft.text, 'Unsent connector question');
            fixture.owner.healthSession().health.selectProfile(overview);
            failProbe = false;
            await overview.refresh(keys: {'connectors'}, testConnectors: true);
            await tester.pumpAndSettle();
            expect(fixture.coordinator.alerts, isEmpty);
            failProbe = true;
            await overview.refresh(keys: {'connectors'}, testConnectors: true);
            await tester.pump();
            await tester.pump(WingMotion.standard);
            expect(
              find.byKey(const ValueKey('health-alert-notice-card')),
              findsOneWidget,
            );
            await tester.tap(find.text('Connector settings'));
            await tester.pumpAndSettle();
            expect(opened, hasLength(2));
            expect(opened.last.connectorNames, names);
            expect(find.byType(Dialog), findsNothing);
            expect(
              find.byKey(const ValueKey('health-alert-notice-card')),
              findsNothing,
            );
            expect(
              failedCount == 1
                  ? find.byType(AdminConnectorDetail)
                  : find.byType(AdminConnectorsPage),
              findsOneWidget,
            );
            for (final name in names) {
              if (failedCount == 2) {
                await tester.tap(find.text(name));
                await tester.pumpAndSettle();
              }
              await tester.ensureVisible(find.text('Remove connector'));
              await tester.tap(find.text('Remove connector'));
              await tester.pumpAndSettle();
              await tester.tap(find.byTooltip('Remove'));
              await tester.pumpAndSettle();
              expect(removedNames, contains(name));
              if (removedNames.length < names.length) {
                expect(fixture.coordinator.alerts.single.connectorNames, [
                  names.last,
                ]);
                expect(
                  HealthAlertIncidentStore(
                    fixture.preferences,
                  ).read(admin.server.connectionIdentity).single.connectorNames,
                  [names.last],
                );
              }
            }
            expect(fixture.coordinator.alerts, isEmpty);
            expect(
              find.byKey(const ValueKey('health-alert-bell')),
              findsNothing,
            );
            await shot(
              tester,
              'connector-removed-$failedCount-${brightness.name}-$scale',
            );
            await tester.pumpWidget(const SizedBox());
            draft.dispose();
            fixture.dispose();
            overview.dispose();
            other.dispose();
            admin.server.close();
          },
        );
      }
      testWidgets(
        'floating notice respects safe areas, text and intent ${brightness.name}/$scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 393 : 320, 852);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          SharedPreferences.setMockInitialValues({});
          final fixture = HealthAlertsFixture(
            await SharedPreferences.getInstance(),
          );
          await fixture.owner.hostResources().refresh();
          final navigatorKey = GlobalKey<NavigatorState>();
          var opens = 0;
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: navigatorKey,
              theme: wingTheme(brightness),
              builder: (context, child) => HealthAlertsScope(
                alerts: fixture.coordinator,
                openAlert: (_) async {
                  opens++;
                },
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    padding: const EdgeInsets.only(top: 24, bottom: 24),
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: scale == 2,
                  ),
                  child: HealthAlertNotice(
                    navigatorKey: navigatorKey,
                    child: RepaintBoundary(
                      key: const ValueKey('capture-alerts'),
                      child: child!,
                    ),
                  ),
                ),
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  appBar: WingAppBar(
                    context: context,
                    title: const Text('Explain /mattpocock…', maxLines: 1),
                    leading: IconButton(
                      tooltip: 'Menu',
                      onPressed: () {},
                      icon: const Icon(Icons.menu),
                    ),
                  ),
                  body: Padding(
                    padding: const EdgeInsets.all(WingSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Expanded(
                          child: SingleChildScrollView(
                            child: Text(
                              'Keep each instruction concrete and easy to act on.\n\n'
                              'For finished work, report what changed, what is '
                              'verified, and what remains. During longer work, '
                              'surface meaningful results, blockers, and decisions.',
                            ),
                          ),
                        ),
                        const TextField(
                          decoration: InputDecoration(
                            hintText: 'Message Hermes or type /',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byType(TextField));
          await tester.enterText(find.byType(TextField), 'Keep this draft');
          await fixture.critical(metric: 'disk');
          await tester.pump();
          await tester.pump(WingMotion.standard);
          final card = find.byKey(const ValueKey('health-alert-notice-card'));
          final rect = tester.getRect(card);
          final toolbar = tester.getRect(find.byType(AppBar));
          expect(rect.top - toolbar.bottom, greaterThanOrEqualTo(24));
          expect(rect.left, greaterThanOrEqualTo(24));
          expect(
            rect.right,
            lessThanOrEqualTo(tester.view.physicalSize.width - 24),
          );
          expect(
            rect.bottom,
            lessThan(tester.getTopLeft(find.byType(TextField)).dy),
          );
          expect(find.byIcon(Icons.error_outline), findsOneWidget);
          expect(
            tester
                .getSize(find.byTooltip('Dismiss health notice'))
                .shortestSide,
            greaterThanOrEqualTo(48),
          );
          expect(tester.testTextInput.isVisible, isTrue);
          expect(opens, 0);
          expect(tester.takeException(), isNull);
          await shot(tester, 'notice-disk-critical-${brightness.name}-$scale');
          await tester.tap(find.byTooltip('Dismiss health notice'));
          await tester.pump();
          expect(card, findsNothing);
          expect(find.text('Keep this draft'), findsOneWidget);
          expect(tester.testTextInput.isVisible, isTrue);
          expect(fixture.coordinator.alerts, hasLength(1));
          expect(opens, 0);

          await fixture.critical();
          await tester.pump();
          await tester.pump(WingMotion.standard);
          expect(find.byIcon(Icons.error_outline), findsOneWidget);
          expect(
            find.text('38.1% used · critical pressure reported'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await shot(tester, 'notice-critical-${brightness.name}-$scale');
          await tester.pump(const Duration(seconds: 6));
          expect(card, findsNothing);
          expect(opens, 0);
          await tester.pumpWidget(const SizedBox());
          fixture.dispose();
        },
      );
      testWidgets(
        'acknowledged issues stay reachable through Health ${brightness.name}/$scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 393 : 320, 852);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final fixture = HealthAlertsFixture(
            await SharedPreferences.getInstance(),
          );
          var opened = 0;
          Future<void> pump(
            String title, {
            Widget? body,
            Widget? contextRow,
          }) async {
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => HealthAlertsScope(
                  alerts: fixture.coordinator,
                  openAlert: (_) async {
                    opened++;
                  },
                  child: MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: RepaintBoundary(
                      key: const ValueKey('capture-alerts'),
                      child: child!,
                    ),
                  ),
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    appBar: WingAppBar(
                      context: context,
                      title: Text(title),
                      leading: const BackButton(),
                      contextRow: contextRow,
                      actions: [
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: () {},
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    body: body,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }

          await pump('Administration');
          expect(find.byKey(const ValueKey('health-alert-bell')), findsNothing);
          await fixture.critical();
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('health-alert-bell')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
          await tester.pumpAndSettle();
          expect(find.text('Critical memory pressure'), findsOneWidget);
          expect(find.byTooltip('Alert settings'), findsNothing);
          expect(find.byTooltip('Acknowledge issue'), findsOneWidget);
          expect(find.byTooltip('Snooze for 30 minutes'), findsOneWidget);
          await tester.tap(find.byTooltip('Close alerts'));
          await tester.pumpAndSettle();
          expect(fixture.coordinator.alerts, hasLength(1));
          await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
          await tester.pumpAndSettle();
          await shot(tester, '${brightness.name}-$scale-alert');
          await tester.tap(find.byTooltip('Snooze for 30 minutes'));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Snoozed until').hitTestable(),
            findsOneWidget,
          );
          expect(
            fixture.coordinator.alerts.single.remindsAt(
              fixture.coordinator.now,
            ),
            isFalse,
          );
          await shot(tester, '${brightness.name}-$scale-snoozed');
          await tester.tap(find.byTooltip('Acknowledge issue'));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Acknowledged.').hitTestable(),
            findsOneWidget,
          );
          expect(find.textContaining('Snoozed until'), findsNothing);
          expect(
            tester
                .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.done))
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.snooze_outlined),
                )
                .onPressed,
            isNull,
          );
          expect(fixture.coordinator.alerts, hasLength(1));
          expect(tester.takeException(), isNull);
          await shot(tester, '${brightness.name}-$scale-acknowledged');
          await tester.tap(find.byTooltip('Close alerts'));
          await tester.pumpAndSettle();
          expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
          expect(find.byKey(const ValueKey('health-alert-bell')), findsNothing);
          expect(find.byType(Badge), findsNothing);
          await shot(tester, '${brightness.name}-$scale-acknowledged-header');
          await pump('Hermes health', body: healthContent(fixture));
          expect(find.text('1 current issue · 1 acknowledged'), findsOneWidget);
          await shot(tester, '${brightness.name}-$scale-retained-health');
          await tester.tap(find.byKey(const ValueKey('health-alerts-entry')));
          await tester.pumpAndSettle();
          expect(find.textContaining('Acknowledged.'), findsOneWidget);
          await tester.tap(find.text('Critical memory pressure'));
          await tester.pumpAndSettle();
          expect(opened, 1);
          await tester.pumpWidget(const SizedBox());
          fixture.dispose();
        },
      );
      testWidgets(
        'health threshold edits validate and persist across reopening ${brightness.name}/$scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 393 : 320, 852);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final fixture = HealthAlertsFixture(
            await SharedPreferences.getInstance(),
          );
          Future<void> pump(
            String title, {
            Widget? body,
            Widget? contextRow,
          }) async {
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => HealthAlertsScope(
                  alerts: fixture.coordinator,
                  openAlert: (_) async {},
                  child: MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: RepaintBoundary(
                      key: const ValueKey('capture-alerts'),
                      child: child!,
                    ),
                  ),
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    appBar: WingAppBar(
                      context: context,
                      title: Text(title),
                      leading: const BackButton(),
                      contextRow: contextRow,
                      actions: [
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: () {},
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    body: body,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }

          await pump('Hermes health', body: healthContent(fixture));
          expect(
            find.byKey(const ValueKey('health-alert-settings-entry')),
            findsOneWidget,
          );
          await shot(tester, '${brightness.name}-$scale-health');
          await tester.tap(
            find.byKey(const ValueKey('health-alert-settings-entry')),
          );
          await tester.pumpAndSettle();
          expect(find.byType(HealthAlertSettingsScreen), findsOneWidget);
          expect(find.text('Server problems'), findsNothing);
          expect(find.text('Server & profile'), findsNothing);
          expect(find.text('Unsaved changes'), findsNothing);
          expect(find.byTooltip('Save health alert settings'), findsNothing);
          expect(find.byTooltip('Reset draft'), findsNothing);
          for (final metric in ['Memory usage', 'Disk usage', 'CPU usage']) {
            expect(
              tester.getSize(find.widgetWithText(ListTile, metric)).height,
              greaterThanOrEqualTo(48),
            );
          }
          await shot(tester, '${brightness.name}-$scale-settings');
          await tester.scrollUntilVisible(
            find.text('Profile problems'),
            120,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(find.text('Profile problems'), findsOneWidget);
          expect(find.text('Server problems'), findsNothing);
          await shot(tester, '${brightness.name}-$scale-settings-profile');
          await tester.scrollUntilVisible(
            find.text('Show a brief notice'),
            160,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(
            find
                .widgetWithText(CompactSwitchListTile, 'Show a brief notice')
                .hitTestable(),
            findsOneWidget,
          );
          await shot(tester, '${brightness.name}-$scale-settings-arrival');
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .jumpTo(0);
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Memory usage'),
            160,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('Memory usage'));
          await tester.pumpAndSettle();
          await shot(tester, '${brightness.name}-$scale-editor');
          const nativeMemoryLabel = 'Native Hermes critical pressure alert';
          final nativeMemory = find.widgetWithText(
            CompactSwitchListTile,
            nativeMemoryLabel,
          );
          expect(nativeMemory, findsOneWidget);
          await tester.ensureVisible(nativeMemory);
          await tester.pumpAndSettle();
          await shot(tester, '${brightness.name}-$scale-native-memory');
          await tester.tap(nativeMemory);
          await tester.pumpAndSettle();
          expect(
            fixture.settings.settings.rules.values.first.nativeCriticalEnabled,
            isFalse,
          );
          expect(fixture.settings.settings.rules.values.first.enabled, isTrue);
          final prefs = await SharedPreferences.getInstance();
          expect(
            HealthAlertSettingsStore(
              prefs,
            ).read().rules.values.first.nativeCriticalEnabled,
            isFalse,
          );
          await tester.ensureVisible(find.text('Usage warning'));
          await tester.pumpAndSettle();
          expect(find.byType(TextField), findsNWidgets(4));
          final fields = find.byType(TextField);
          await tester.enterText(fields.at(1), '0');
          await tester.pumpAndSettle();
          expect(find.textContaining('Not saved:'), findsOneWidget);
          expect(fixture.settings.settings.rules.values.first.warnAbove, 90);
          await tester.enterText(fields.at(1), '50');
          await tester.pumpAndSettle();
          expect(
            find.text(
              'Not saved: clear below 85% must be lower than alert above 50%.',
            ),
            findsOneWidget,
          );
          await shot(tester, '${brightness.name}-$scale-invalid-rule');
          await tester.tap(
            find
                .descendant(
                  of: find.byType(Dialog),
                  matching: find.byType(Switch),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(fixture.settings.settings.rules.values.first.enabled, isFalse);
          expect(fixture.settings.settings.rules.values.first.warnAbove, 90);
          await tester.enterText(fields.at(1), '96.5');
          await tester.enterText(fields.at(3), '85.25');
          await tester.enterText(fields.at(0), '1');
          await tester.enterText(fields.at(2), '3');
          await tester.pumpAndSettle();
          expect(find.textContaining('Not saved:'), findsNothing);
          expect(fixture.settings.settings.rules.values.first.warnAbove, 96.5);
          expect(fixture.settings.settings.rules.values.first.alertMinutes, 1);
          expect(fixture.settings.settings.rules.values.first.clearMinutes, 3);
          expect(
            fixture.settings.settings.rules.values.first.clearBelow,
            85.25,
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 320);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          expect(
            find.byTooltip('Close rule editor').hitTestable(),
            findsOneWidget,
          );
          await shot(tester, '${brightness.name}-$scale-keyboard');
          await tester.tap(find.byTooltip('Close rule editor'));
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          await tester.tap(find.text('Memory usage'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(fields.at(1)).controller!.text,
            '96.5',
          );
          expect(
            tester.widget<TextField>(fields.at(3)).controller!.text,
            '85.25',
          );
          await tester.tap(find.byTooltip('Close rule editor'));
          await tester.pumpAndSettle();
          expect(fixture.settings.settings.rules.values.first.warnAbove, 96.5);
          expect(
            fixture.settings.settings.rules.values.first.clearBelow,
            85.25,
          );
          expect(
            find.descendant(
              of: find.widgetWithText(ListTile, 'Memory usage'),
              matching: find.text('Not watched'),
            ),
            findsOneWidget,
          );
          await tester.scrollUntilVisible(
            find.text('Disk usage'),
            160,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('Disk usage'));
          await tester.pumpAndSettle();
          final nativeDisk = find.widgetWithText(
            CompactSwitchListTile,
            'Native Hermes critical pressure alert',
          );
          expect(nativeDisk, findsOneWidget);
          await tester.ensureVisible(nativeDisk);
          await tester.pumpAndSettle();
          await shot(tester, '${brightness.name}-$scale-native-disk');
          await tester.tap(nativeDisk);
          await tester.pumpAndSettle();
          expect(
            HealthAlertSettingsStore(
              prefs,
            ).read().rules.values.elementAt(1).nativeCriticalEnabled,
            isFalse,
          );
          expect(
            fixture.settings.settings.rules.values.elementAt(1).enabled,
            isTrue,
          );
          await tester.tap(find.byTooltip('Close rule editor'));
          await tester.pumpAndSettle();
          expect(
            find.text('Above 90% for 2 min · native critical off'),
            findsOneWidget,
          );
          await tester.scrollUntilVisible(
            find.text('CPU usage'),
            160,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('CPU usage'));
          await tester.pumpAndSettle();
          expect(find.textContaining('Native Hermes critical'), findsNothing);
          await tester.tap(find.byTooltip('Close rule editor'));
          await tester.pumpAndSettle();
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(HealthAlertSettingsScreen), findsNothing);
          expect(find.text('Discard alert changes?'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          fixture.dispose();
        },
      );
    }
  }
}
