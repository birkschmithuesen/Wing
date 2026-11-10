import 'package:wing/core/services/health_alert_incident_store.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/health_alert.dart';
import 'package:wing/core/models/administration_operation.dart';
import 'package:wing/core/models/health_alert_evaluator.dart';
import 'package:wing/core/models/host_thresholds.dart';
import 'package:wing/core/presentation/health_alert_presentation.dart';
import 'package:wing/core/services/administration_health.dart';
import 'package:wing/core/services/health_alert_settings_session.dart';
import 'package:wing/core/services/health_alert_settings_store.dart';
import 'package:wing/core/services/health_alerts_session.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/host_resources_session.dart';
import 'support/host_resources_fixture.dart';
import 'support/health_alerts_fixture.dart';

class _HeldStore extends HealthAlertSettingsStore {
  _HeldStore(super.preferences);
  final gate = Completer<void>();
  bool fail = false;
  int writes = 0;
  @override
  Future<void> write(HealthAlertSettings settings) async {
    writes++;
    await gate.future;
    if (fail) throw StateError('disk unavailable');
    await super.write(settings);
  }
}

class _HeldIncidentStore extends HealthAlertIncidentStore {
  _HeldIncidentStore(super.preferences);
  Completer<void>? gate;
  bool fail = false;
  Future<void> _tail = Future<void>.value();
  @override
  Future<void> write(String connection, List<HealthAlert> alerts) {
    final held = gate;
    final snapshot = List<HealthAlert>.of(alerts);
    final result = _tail.then((_) async {
      if (held != null) await held.future;
      if (fail) throw StateError('Disk unavailable');
      await super.write(connection, snapshot);
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

String _sharedDurationPolicy(HealthAlertSettings settings) {
  final data = settings.encode();
  data['rules'] = {
    for (final entry in settings.rules.entries)
      entry.key.name: entry.value.encode()
        ..['minutes'] = entry.value.alertMinutes
        ..remove('alertMinutes')
        ..remove('clearMinutes'),
  };
  return jsonEncode(data);
}

void main() {
  final start = DateTime.utc(2026, 10, 9);
  final ram = HostMetric.memoryUsedPercent;
  late HealthAlertEvaluator evaluator;
  late HealthAlertRule rule;
  setUp(() {
    evaluator = HealthAlertEvaluator(
      connectionIdentity: 'exact-endpoint',
      connectionLabel: 'Home',
    );
    rule = HealthAlertRule(
      enabled: true,
      nativeCriticalEnabled: true,
      warnAbove: 90,
      clearBelow: 85,
      alertMinutes: 2,
      clearMinutes: 2,
    );
  });
  void sample(int seconds, double? value, {bool critical = false}) =>
      evaluator.host(
        metric: ram,
        rule: rule,
        now: start.add(Duration(seconds: seconds)),
        sampledAt: value == null && !critical
            ? null
            : start.add(Duration(seconds: seconds)),
        value: value,
        critical: critical,
      );
  void period(int first, int last, double value) {
    for (var i = first; i <= last; i += 15) {
      sample(i, value);
    }
  }

  test(
    'connection snooze survives restart and only confirmed recovery clears it',
    () async {
      SharedPreferences.setMockInitialValues({});
      var prefs = await SharedPreferences.getInstance();
      var fixture = HealthAlertsFixture(prefs);
      var connection = fixture.owner.connectionStatus;
      connection.accessAvailable();
      connection.liveChanged('chat', false);
      final initial = fixture.coordinator.alerts.single;
      expect(initial.scope, HealthAlertScope.connection);
      await fixture.coordinator.snooze(initial);
      final deadline = fixture.coordinator.alerts.single.snoozedUntil!.toUtc();
      final saved = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
      fixture.dispose();
      SharedPreferences.setMockInitialValues(saved);
      prefs = await SharedPreferences.getInstance();
      fixture = HealthAlertsFixture(prefs);
      connection = fixture.owner.connectionStatus;
      expect(fixture.coordinator.alerts.single.lastKnown, isTrue);
      expect(fixture.coordinator.alerts.single.snoozedUntil!.toUtc(), deadline);
      expect(fixture.coordinator.attentionAlerts, isEmpty);
      connection.accessAvailable();
      connection.beginRecovery('chat');
      expect(fixture.coordinator.alerts.single.lastKnown, isTrue);
      connection.liveChanged('chat', false);
      expect(fixture.coordinator.alerts.single.snoozedUntil!.toUtc(), deadline);
      connection.forgetLive('chat');
      expect(fixture.coordinator.alerts.single.lastKnown, isTrue);
      connection.liveChanged('chat', true);
      connection.endRecovery('chat');
      expect(fixture.coordinator.alerts, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(
        HealthAlertIncidentStore(prefs).read(fixture.owner.connectionIdentity),
        isEmpty,
      );
      fixture.dispose();
    },
  );

  test(
    'connection alerts are independent of Health monitoring and pause in background',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
      );
      final connection = fixture.owner.connectionStatus;
      await fixture.settings.update(
        (current) => current.copyWith(profile: false),
      );
      connection.accessAvailable();
      connection.liveChanged('chat', false);
      final initial = fixture.coordinator.alerts.single;
      await fixture.settings.update(
        (current) => current.copyWith(enabled: false),
      );
      expect(fixture.coordinator.alerts.single.occurrence, initial.occurrence);
      connection.liveChanged('chat', false);
      expect(fixture.coordinator.alerts.single.occurrence, initial.occurrence);
      fixture.coordinator.setForeground(false);
      connection.liveChanged('chat', true);
      expect(fixture.coordinator.alerts.single.lastKnown, isTrue);
      fixture.coordinator.setForeground(true);
      expect(fixture.coordinator.alerts, isEmpty);
      fixture.dispose();
      // Retired listeners cannot recreate the removed incident.
      connection.liveChanged('chat', false);
    },
  );

  test(
    'operational observations share the existing incident lifecycle',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
      );
      await fixture.owner.hostResources().refresh();
      await fixture.critical();
      expect(fixture.coordinator.alerts.single.scope, HealthAlertScope.host);
      void observe(String scope, bool failed) =>
          fixture.coordinator.observeOperationalError(
            fixture.owner,
            scope: scope,
            title: 'Group updates could not refresh',
            detail: 'Your messages are kept.',
            failed: failed,
          );

      observe('group:one', true);
      final initial = fixture.coordinator.alerts.singleWhere(
        (alert) => alert.scope == HealthAlertScope.operational,
      );
      await fixture.coordinator.acknowledge(initial);
      await fixture.settings.update(
        (current) => current.copyWith(enabled: false),
      );
      observe('group:one', true);
      observe('group:two', false);
      final retained = fixture.coordinator.alerts.single;
      expect(retained.id, initial.id);
      expect(retained.occurrence, initial.occurrence);
      expect(retained.acknowledged, isTrue);
      expect(fixture.coordinator.attentionAlerts, isEmpty);

      observe('group:one', false);
      expect(fixture.coordinator.alerts, isEmpty);
      observe('group:one', true);
      expect(
        fixture.coordinator.attentionAlerts.single.occurrence,
        isNot(initial.occurrence),
      );

      observe('group:one', false);
      final connection = fixture.owner.connectionStatus;
      connection.accessAvailable();
      connection.liveChanged('chat', false);
      observe('group:one', true);
      expect(fixture.coordinator.alerts, hasLength(2));
      observe('group:one', false);
      connection.accessFailed(const SocketException('offline'));
      observe('group:one', true);
      observe('host-resources', true);
      expect(
        fixture.coordinator.alerts.single.scope,
        HealthAlertScope.connection,
      );
      fixture.dispose();
    },
  );

  test(
    'settled host reads report and clear each operational incident',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
      );
      final host = fixture.owner.hostResources();
      await host.refresh();
      await fixture.settings.update(
        (current) => current.copyWith(enabled: false),
      );
      fixture.host.statsError = StateError('stats unavailable');
      fixture.host.pressureError = StateError('pressure unavailable');
      final held = fixture.host.pressureGate = Completer();
      final refresh = host.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.coordinator.alerts, isEmpty);
      held.complete();
      await refresh;
      expect(fixture.coordinator.alerts, hasLength(2));
      expect(
        fixture.coordinator.alerts.map((alert) => alert.scope),
        everyElement(HealthAlertScope.operational),
      );
      final pressure = fixture.coordinator.alerts.firstWhere(
        (alert) => alert.title == 'Host pressure could not refresh',
      );

      fixture.host.statsError = null;
      await host.refresh();
      expect(fixture.coordinator.alerts.single.id, pressure.id);
      expect(fixture.coordinator.alerts.single.occurrence, pressure.occurrence);
      fixture.host.pressureError = null;
      await host.refresh();
      expect(fixture.coordinator.alerts, isEmpty);
      fixture.dispose();
    },
  );

  test(
    'saved owners report operational issues before Chats initializes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final fixture = HealthAlertsFixture(prefs, initialized: false);
      expect(fixture.host.requests, isEmpty);

      fixture.coordinator.observeOperationalError(
        fixture.owner,
        scope: 'bots-roster',
        title: 'Bot list could not refresh',
        detail: 'Open Bots to refresh the list.',
        failed: true,
      );
      final issue = fixture.coordinator.alerts.single;
      await fixture.settings.update(
        (current) => current.copyWith(showNotice: false),
      );
      expect(fixture.coordinator.alerts.single.id, issue.id);
      expect(fixture.host.requests, isEmpty);
      expect(
        HealthAlertIncidentStore(
          prefs,
        ).read(fixture.owner.connectionIdentity).single.id,
        issue.id,
      );
      void reportRead(bool failed) =>
          fixture.coordinator.observeOperationalError(
            fixture.owner,
            scope: 'bot-display',
            title: 'Bot display interrupted',
            detail: 'Open the bot to try again.',
            failed: failed,
          );

      final connection = fixture.owner.connectionStatus;
      connection.accessFailed(const SocketException('offline'));
      reportRead(true);
      expect(
        fixture.coordinator.alerts.map((a) => a.scope),
        unorderedEquals([
          HealthAlertScope.operational,
          HealthAlertScope.connection,
        ]),
      );
      connection.accessAvailable();
      reportRead(false);
      expect(fixture.coordinator.alerts, hasLength(2));
      connection.liveChanged('chat', true);
      reportRead(false);
      expect(fixture.coordinator.alerts.single.id, issue.id);
      fixture.dispose();
    },
  );

  test('acknowledgement survives device-preference reconstruction', () async {
    SharedPreferences.setMockInitialValues({});
    var prefs = await SharedPreferences.getInstance();
    var fixture = HealthAlertsFixture(prefs);
    await fixture.owner.hostResources().refresh();
    await fixture.critical();
    await fixture.coordinator.acknowledge(fixture.coordinator.alerts.single);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.coordinator.attentionAlerts, isEmpty);
    fixture.dispose();
    final saved = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
    SharedPreferences.setMockInitialValues(saved);
    prefs = await SharedPreferences.getInstance();
    fixture = HealthAlertsFixture(prefs);
    await fixture.owner.hostResources().refresh();
    await fixture.critical();
    expect(fixture.coordinator.alerts.single.acknowledged, isTrue);
    expect(fixture.coordinator.attentionAlerts, isEmpty);
    fixture.dispose();
  });

  test('snooze survives restart with its original deadline', () async {
    SharedPreferences.setMockInitialValues({});
    var prefs = await SharedPreferences.getInstance();
    var fixture = HealthAlertsFixture(prefs);
    await fixture.owner.hostResources().refresh();
    await fixture.critical();
    await fixture.coordinator.snooze(fixture.coordinator.alerts.single);
    final until = fixture.coordinator.alerts.single.snoozedUntil!;
    final saved = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
    fixture.dispose();
    SharedPreferences.setMockInitialValues(saved);
    prefs = await SharedPreferences.getInstance();
    fixture = HealthAlertsFixture(prefs);
    expect(fixture.coordinator.alerts.single.lastKnown, isTrue);
    expect(
      fixture.coordinator.alerts.single.snoozedUntil!.isAtSameMomentAs(until),
      isTrue,
    );
    expect(fixture.coordinator.alerts.single.remindsAt(until), isTrue);
    expect(fixture.coordinator.attentionAlerts, isEmpty);
    await fixture.owner.hostResources().refresh();
    await fixture.critical();
    expect(
      fixture.coordinator.alerts.single.snoozedUntil!.isAtSameMomentAs(until),
      isTrue,
    );
    fixture.dispose();
  });

  test(
    'saved profile choices isolate connections/profiles and reset on recovery or escalation',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = HealthAlertIncidentStore(
        await SharedPreferences.getInstance(),
      );
      void finding(
        HealthAlertEvaluator owner,
        String profile,
        int seconds, {
        bool failed = true,
        HealthAlertSeverity severity = HealthAlertSeverity.warning,
      }) => owner.finding(
        key: 'exact-endpoint:profile:$profile:Scheduled tasks',
        title: 'Scheduled tasks',
        detail: 'One reported error',
        scope: HealthAlertScope.profile,
        profileName: profile,
        destination: 'Scheduled tasks',
        at: start.add(Duration(seconds: seconds)),
        failed: failed,
        severity: severity,
      );
      finding(evaluator, 'pace', 0);
      final original = evaluator.alerts.single;
      evaluator.acknowledge(original.id, original.occurrence);
      await store.write('exact-endpoint', evaluator.alerts);
      expect(store.read('other-endpoint'), isEmpty);
      evaluator = HealthAlertEvaluator(
        connectionIdentity: 'exact-endpoint',
        connectionLabel: 'Home',
      )..restore(store.read('exact-endpoint'));
      finding(evaluator, 'pace', 15);
      expect(evaluator.alerts.single.acknowledged, isTrue);
      expect(evaluator.alerts.single.destination, 'Scheduled tasks');
      finding(evaluator, 'other-profile', 15);
      expect(evaluator.alerts.last.acknowledged, isFalse);
      finding(evaluator, 'pace', 30, severity: HealthAlertSeverity.critical);
      final escalated = evaluator.alerts.first;
      expect(escalated.acknowledged, isFalse);
      expect(escalated.occurrence, greaterThan(original.occurrence));
      evaluator.acknowledge(original.id, original.occurrence);
      expect(evaluator.alerts.first.acknowledged, isFalse);
      evaluator.acknowledge(escalated.id, escalated.occurrence);
      finding(evaluator, 'pace', 45, failed: false);
      await store.write('exact-endpoint', evaluator.alerts);
      evaluator = HealthAlertEvaluator(
        connectionIdentity: 'exact-endpoint',
        connectionLabel: 'Home',
      )..restore(store.read('exact-endpoint'));
      finding(evaluator, 'pace', 60);
      expect(evaluator.alerts.last.acknowledged, isFalse);
    },
  );

  test(
    'held save survives disposal and fresh readings without losing the choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = _HeldIncidentStore(prefs);
      final fixture = HealthAlertsFixture(prefs, incidentStore: store);
      await fixture.owner.hostResources().refresh();
      await fixture.critical();
      store.gate = Completer<void>();
      final original = fixture.coordinator.alerts.single;
      final action = fixture.coordinator.acknowledge(original);
      expect(fixture.coordinator.saving, isTrue);
      expect(fixture.coordinator.alerts.single.acknowledged, isFalse);
      await fixture.critical();
      fixture.dispose();
      store.gate!.complete();
      await action;
      expect(
        store.read(original.connectionIdentity).single.acknowledged,
        isTrue,
      );
    },
  );

  test('failed choice remains active and can be retried', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _HeldIncidentStore(prefs);
    final fixture = HealthAlertsFixture(prefs, incidentStore: store);
    await fixture.owner.hostResources().refresh();
    await fixture.critical();
    // Settle the initial incident write before simulating a failed user save.
    await Future<void>.delayed(Duration.zero);
    store.fail = true;
    final alert = fixture.coordinator.alerts.single;
    await fixture.coordinator.acknowledge(alert);
    expect(fixture.coordinator.saving, isFalse);
    expect(fixture.coordinator.attentionAlerts, hasLength(1));
    expect(fixture.coordinator.error(alert), contains('Could not save'));
    store.fail = false;
    await fixture.coordinator.acknowledge(alert);
    expect(fixture.coordinator.error(alert), isNull);
    expect(fixture.coordinator.attentionAlerts, isEmpty);
    expect(store.read(alert.connectionIdentity).single.acknowledged, isTrue);
    fixture.dispose();
  });

  test('recovery while a save is held wins over the old occurrence', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _HeldIncidentStore(prefs);
    final fixture = HostResourcesFixture();
    var now = start;
    fixture.pressure = hostPressurePayload(now: now);
    fixture.pressure['memory']['pressure'] = 'critical';
    final host = HostResourcesSession(fixture.server, now: () => now);
    final health = AdministrationHealth(fixture.server, now: () => now);
    final settings = HealthAlertSettingsSession(
      HealthAlertSettingsStore(prefs),
    );
    final session = HealthAlertsSession(
      connectionStatus: ServerConnectionStatus('Test server'),
      host: host,
      health: health,
      settings: settings,
      incidents: store,
      now: () => now,
    );
    session.setActive(true);
    await host.refresh();
    store.gate = Completer<void>();
    final original = session.alerts.single;
    final action = session.acknowledge(original);
    fixture.pressure = hostPressurePayload(now: now);
    await host.refresh();
    now = now.add(const Duration(minutes: 2));
    await host.refresh();
    expect(session.alerts, isEmpty);
    fixture.pressure = hostPressurePayload(now: now);
    fixture.pressure['memory']['pressure'] = 'critical';
    await host.refresh();
    expect(session.alerts.single.occurrence, greaterThan(original.occurrence));
    store.gate!.complete();
    await action;
    await Future<void>.delayed(Duration.zero);
    expect(session.alerts.single.acknowledged, isFalse);
    expect(store.read(fixture.identity).single.acknowledged, isFalse);
    session.dispose();
    host.dispose();
    health.dispose();
    settings.dispose();
    fixture.server.close();
  });

  for (final acknowledge in [true, false]) {
    test(
      '${acknowledge ? 'acknowledge' : 'snooze'} survives reads and pauses; escalation and recurrence reset it',
      () {
        period(0, 120, 93);
        final warning = evaluator.alerts.single;
        final until = start.add(const Duration(minutes: 30));
        if (acknowledge) {
          evaluator.acknowledge(warning.id, warning.occurrence);
        } else {
          evaluator.snooze(warning.id, warning.occurrence, until);
        }
        sample(135, 94);
        evaluator.pause();
        evaluator.unknown(warning.id);
        final retained = evaluator.alerts.single;
        expect(retained.lastKnown, isTrue);
        expect(
          retained.remindsAt(start.add(const Duration(minutes: 29))),
          isFalse,
        );
        expect(retained.remindsAt(until), !acknowledge);
        sample(150, 97, critical: true);
        final critical = evaluator.alerts.single;
        expect(critical.occurrence, greaterThan(warning.occurrence));
        expect(critical.acknowledged, isFalse);
        expect(critical.snoozedUntil, isNull);
        // A command captured before escalation cannot silence the new occurrence.
        evaluator.acknowledge(warning.id, warning.occurrence);
        evaluator.snooze(warning.id, warning.occurrence, until);
        expect(evaluator.alerts.single.remindsAt(start), isTrue);
        evaluator.acknowledge(critical.id, critical.occurrence);
        sample(165, 80);
        sample(285, 80);
        expect(evaluator.alerts, isEmpty);
        sample(300, 99, critical: true);
        expect(
          evaluator.alerts.single.occurrence,
          greaterThan(critical.occurrence),
        );
        expect(evaluator.alerts.single.remindsAt(start), isTrue);
      },
    );
  }

  test('profile suppression retains its captured recovery destination', () {
    void finding(int seconds) => evaluator.finding(
      key: 'profile:work:connectors',
      title: 'Connector settings',
      detail: 'Sign-in expired',
      scope: HealthAlertScope.profile,
      profileName: 'work',
      destination: 'MCP connectors',
      connectorNames: ['calendar'],
      at: start.add(Duration(seconds: seconds)),
      failed: true,
    );
    finding(0);
    final alert = evaluator.alerts.single;
    evaluator.snooze(
      alert.id,
      alert.occurrence,
      start.add(const Duration(minutes: 30)),
    );
    finding(15);
    expect(evaluator.alerts.single.remindsAt(start), isFalse);
    evaluator.acknowledge(alert.id, alert.occurrence);
    finding(30);
    expect(evaluator.alerts.single.acknowledged, isTrue);
    expect(evaluator.alerts.single.destination, 'MCP connectors');
    expect(evaluator.alerts.single.connectorNames, ['calendar']);
  });

  for (final metric in [ram, HostMetric.diskUsedPercent]) {
    test('native-only ${metric.name} alerts immediately and can recover', () {
      final nativeOnly = rule.copyWith(enabled: false);
      void read(int seconds, double value, {bool critical = false}) =>
          evaluator.host(
            metric: metric,
            rule: nativeOnly,
            now: start.add(Duration(seconds: seconds)),
            sampledAt: start.add(Duration(seconds: seconds)),
            value: value,
            critical: critical,
          );
      read(0, 99);
      read(120, 99);
      expect(evaluator.alerts, isEmpty);
      read(135, 99, critical: true);
      expect(evaluator.alerts.single.severity, HealthAlertSeverity.critical);
      read(150, 80);
      read(270, 80);
      expect(evaluator.alerts, isEmpty);
    });
    test('disabled native ${metric.name} cannot escalate a Wing warning', () {
      final warningOnly = rule.copyWith(nativeCriticalEnabled: false);
      void read(int seconds) => evaluator.host(
        metric: metric,
        rule: warningOnly,
        now: start.add(Duration(seconds: seconds)),
        sampledAt: start.add(Duration(seconds: seconds)),
        value: 99,
        critical: true,
      );
      read(0);
      expect(evaluator.alerts, isEmpty);
      read(120);
      final warning = evaluator.alerts.single;
      expect(warning.severity, HealthAlertSeverity.warning);
      expect(
        healthAlertTriggerSummary(warning),
        '99% used · above 90% for 2 min',
      );
      read(135);
      expect(evaluator.alerts.single.occurrence, warning.occurrence);
    });
  }

  test(
    'older saved rules without native toggles require reconfiguration',
    () async {
      final data = HealthAlertSettings().encode();
      for (final savedRule in (data['rules'] as Map).values) {
        (savedRule as Map).remove('nativeCriticalEnabled');
      }
      SharedPreferences.setMockInitialValues({
        HealthAlertSettingsStore.key: jsonEncode(data),
      });
      final session = HealthAlertSettingsSession(
        HealthAlertSettingsStore(await SharedPreferences.getInstance()),
      );
      expect(session.settings.enabled, isFalse);
      expect(session.error, contains('could not be read'));
      await session.update((current) => current.copyWith(enabled: true));
      expect(session.settings.enabled, isTrue);
      expect(session.error, isNull);
      session.dispose();
    },
  );

  test(
    'native toggles own polling and incidents independently of warnings',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = HostResourcesFixture();
      fixture.pressure = hostPressurePayload(now: start);
      fixture.pressure['memory']['pressure'] = 'critical';
      fixture.pressure['disk']['pressure'] = 'critical';
      final host = HostResourcesSession(fixture.server, now: () => start);
      final health = AdministrationHealth(fixture.server, now: () => start);
      final store = HealthAlertSettingsStore(
        await SharedPreferences.getInstance(),
      );
      final settings = HealthAlertSettingsSession(store);
      await settings.update(
        (current) => current.copyWith(
          rules: {
            for (final entry in current.rules.entries)
              entry.key: entry.value.copyWith(enabled: entry.key == ram),
          },
        ),
      );
      final session = HealthAlertsSession(
        connectionStatus: ServerConnectionStatus('Test server'),
        incidents: HealthAlertIncidentStore(
          await SharedPreferences.getInstance(),
        ),
        host: host,
        health: health,
        settings: settings,
        now: () => start,
      );
      session.setActive(true);
      await host.refresh();
      expect(
        session.alerts.map((a) => a.title),
        unorderedEquals(['Critical memory pressure', 'Critical disk pressure']),
      );
      final memoryAlert = session.alerts.firstWhere(
        (a) => a.title == 'Critical memory pressure',
      );
      await settings.updateRule(
        ram,
        (current) => current.copyWith(enabled: false),
      );
      final retained = session.alerts.firstWhere((a) => a.id == memoryAlert.id);
      expect(retained.occurrence, memoryAlert.occurrence);
      session.setActive(false);
      await settings.updateRule(
        ram,
        (current) => current.copyWith(nativeCriticalEnabled: false),
      );
      expect(session.alerts.single.title, 'Critical disk pressure');
      expect(store.read().rules[ram]!.nativeCriticalEnabled, isFalse);
      expect(
        store.read().rules[HostMetric.diskUsedPercent]!.nativeCriticalEnabled,
        isTrue,
      );
      await settings.updateRule(
        HostMetric.diskUsedPercent,
        (current) => current.copyWith(nativeCriticalEnabled: false),
      );
      expect(session.alerts, isEmpty);
      final requests = fixture.requests.length;
      session.setActive(true);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.requests, hasLength(requests));
      session.dispose();
      host.dispose();
      health.dispose();
      settings.dispose();
      fixture.server.close();
    },
  );

  test('warning and recovery use independent durations', () {
    rule = rule.copyWith(alertMinutes: 1, clearMinutes: 3);
    period(0, 60, 93);
    expect(evaluator.alerts, hasLength(1));
    period(75, 240, 80);
    expect(evaluator.alerts, hasLength(1));
    sample(255, 80);
    expect(evaluator.alerts, isEmpty);
  });

  test('warning duration rejects zero minutes', () {
    expect(() => rule.copyWith(alertMinutes: 0), throwsArgumentError);
  });

  test('recovery duration rejects more than thirty minutes', () {
    expect(() => rule.copyWith(clearMinutes: 31), throwsArgumentError);
  });

  for (final metric in hostAlertMetrics) {
    test('${metric.name} retains the values that triggered the occurrence', () {
      final policy = rule.copyWith(warnAbove: 90.25);
      void reading(int seconds, double value) => evaluator.host(
        metric: metric,
        rule: policy,
        now: start.add(Duration(seconds: seconds)),
        sampledAt: start.add(Duration(seconds: seconds)),
        value: value,
      );
      reading(0, 91);
      reading(120, 93.4);
      final alert = evaluator.alerts.single;
      expect(
        healthAlertTriggerSummary(alert),
        '93.4% used · above 90.25% for 2 min',
      );
      reading(135, 96.1);
      expect(evaluator.alerts.single.trigger, same(alert.trigger));
      expect(evaluator.alerts.single.detail, contains('96% used'));
      evaluator.unknown(alert.id);
      expect(evaluator.alerts.single.trigger, same(alert.trigger));
      expect(evaluator.alerts.single.lastKnown, isTrue);
    });
  }

  for (final minutes in [1, 2, 30]) {
    test('warning retains a gap of exactly 3 times $minutes minutes', () {
      rule = rule.copyWith(alertMinutes: minutes);
      sample(0, 93);
      sample(minutes * 180, 93);
      expect(evaluator.alerts.single.severity, HealthAlertSeverity.warning);
    });
    test('warning restarts beyond 3 times $minutes minutes', () {
      rule = rule.copyWith(alertMinutes: minutes);
      sample(0, 93);
      final resumed = minutes * 180 + 1;
      sample(resumed, 93);
      expect(evaluator.alerts, isEmpty);
      sample(resumed + minutes * 60, 93);
      expect(evaluator.alerts.single.severity, HealthAlertSeverity.warning);
    });
    test('recovery uses its own 3 times $minutes minutes gap', () {
      rule = rule.copyWith(alertMinutes: 30, clearMinutes: minutes);
      sample(0, null, critical: true);
      sample(15, 80);
      sample(15 + minutes * 180, 80);
      expect(evaluator.alerts, isEmpty);
    });
    test('recovery restarts beyond 3 times $minutes minutes', () {
      rule = rule.copyWith(alertMinutes: 30, clearMinutes: minutes);
      sample(0, null, critical: true);
      sample(15, 80);
      final resumed = 15 + minutes * 180 + 1;
      sample(resumed, 80);
      expect(evaluator.alerts, hasLength(1));
      sample(resumed + minutes * 60, 80);
      expect(evaluator.alerts, isEmpty);
    });
  }
  test('warning retention slides from the latest fresh reading', () {
    rule = rule.copyWith(alertMinutes: 1);
    sample(0, 93);
    sample(30, 93);
    sample(210, 93);
    expect(evaluator.alerts, hasLength(1));
  });

  test(
    'approved duration migration preserves policy and writes the new format once',
    () async {
      final original = HealthAlertSettings(
        enabled: false,
        profile: false,
        showNotice: false,
      );
      SharedPreferences.setMockInitialValues({
        HealthAlertSettingsStore.key: _sharedDurationPolicy(original),
      });
      final prefs = await SharedPreferences.getInstance();
      final store = _HeldStore(prefs);
      final session = HealthAlertSettingsSession(store);
      expect(session.settings.enabled, isFalse);
      expect(session.settings.profile, isFalse);
      expect(session.settings.showNotice, isFalse);
      for (final metric in hostAlertMetrics) {
        expect(
          session.settings.rules[metric]!.alertMinutes,
          original.rules[metric]!.alertMinutes,
        );
        expect(
          session.settings.rules[metric]!.clearMinutes,
          original.rules[metric]!.alertMinutes,
        );
        expect(
          session.settings.rules[metric]!.warnAbove,
          original.rules[metric]!.warnAbove,
        );
        expect(
          session.settings.rules[metric]!.clearBelow,
          original.rules[metric]!.clearBelow,
        );
        expect(
          session.settings.rules[metric]!.enabled,
          original.rules[metric]!.enabled,
        );
      }
      expect(store.writes, 1);
      final migrated = session.retry();
      store.gate.complete();
      expect(await migrated, isTrue);
      final encoded =
          jsonDecode(prefs.getString(HealthAlertSettingsStore.key)!) as Map;
      for (final savedRule in (encoded['rules'] as Map).values) {
        expect(savedRule.containsKey('minutes'), isFalse);
        expect(savedRule['alertMinutes'], savedRule['clearMinutes']);
      }
      final reopened = HealthAlertSettingsSession(store);
      expect(store.needsMigration, isFalse);
      expect(store.writes, 1);
      reopened.dispose();
      session.dispose();
    },
  );

  test(
    'failed migration preserves stored data and remains retryable',
    () async {
      final original = _sharedDurationPolicy(HealthAlertSettings());
      SharedPreferences.setMockInitialValues({
        HealthAlertSettingsStore.key: original,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = _HeldStore(prefs)..fail = true;
      final session = HealthAlertSettingsSession(store);
      final migration = session.retry();
      store.gate.complete();
      expect(await migration, isFalse);
      expect(prefs.getString(HealthAlertSettingsStore.key), original);
      expect(session.settings.enabled, isTrue);
      expect(session.error, isNotNull);
      store.fail = false;
      expect(await session.retry(), isTrue);
      expect(prefs.getString(HealthAlertSettingsStore.key), isNot(original));
      session.dispose();
    },
  );

  test(
    'requires sustained fresh samples, ignores duplicate receipts, and uses strict limits',
    () {
      period(0, 120, 90);
      expect(evaluator.alerts, isEmpty);
      sample(135, 93);
      for (var i = 0; i < 20; i++) {
        sample(135, 93);
      }
      expect(evaluator.alerts, isEmpty);
      period(150, 255, 93);
      expect(evaluator.alerts.single.severity, HealthAlertSeverity.warning);
      period(270, 390, 85);
      expect(evaluator.alerts, hasLength(1));
      period(405, 525, 84);
      expect(evaluator.alerts, isEmpty);
    },
  );
  test(
    'expired gaps and unknown readings break progress and retain incidents',
    () {
      sample(0, 93);
      sample(361, 93);
      expect(evaluator.alerts, isEmpty);
      sample(481, 93);
      expect(evaluator.alerts, hasLength(1));
      sample(496, null);
      expect(evaluator.alerts.single.lastKnown, isTrue);
      sample(511, 80);
      sample(872, 80);
      expect(evaluator.alerts, hasLength(1));
      sample(992, 80);
      expect(evaluator.alerts, isEmpty);
    },
  );
  test('unknown readings restart a pending warning', () {
    sample(0, 93);
    sample(30, null);
    sample(120, 93);
    expect(evaluator.alerts, isEmpty);
    sample(240, 93);
    expect(evaluator.alerts, hasLength(1));
  });
  test(
    'critical pressure bypasses duration and does not require a percentage',
    () {
      sample(0, null, critical: true);
      expect(evaluator.alerts.single.severity, HealthAlertSeverity.critical);
      expect(
        healthAlertTriggerSummary(evaluator.alerts.single),
        'Usage unavailable · critical pressure reported',
      );
      final initialOccurrence = evaluator.alerts.single.occurrence;
      sample(15, 99, critical: true);
      expect(evaluator.alerts.single.occurrence, initialOccurrence);
      period(30, 150, 80);
      expect(evaluator.alerts, isEmpty);
      sample(165, 99, critical: true);
      expect(
        evaluator.alerts.single.occurrence,
        greaterThan(initialOccurrence),
      );
      expect(
        healthAlertTriggerSummary(evaluator.alerts.single),
        '99% used · critical pressure reported',
      );
    },
  );
  test('escalation starts a new occurrence and preserves current count', () {
    period(0, 120, 93);
    final initial = evaluator.alerts.single;
    sample(135, 99, critical: true);
    final escalated = evaluator.alerts.single;
    expect(escalated.occurrence, greaterThan(initial.occurrence));
    expect(initial.trigger!.usedPercent, 93);
    expect(escalated.trigger!.usedPercent, 99);
    expect(escalated.trigger!.criticalPressure, isTrue);
    expect(evaluator.alerts, hasLength(1));
  });
  test(
    'profile incidents remain attached to their original scope; unknown is not recovery',
    () {
      for (final name in ['default', 'Research']) {
        evaluator.finding(
          key: 'endpoint:profile:$name:access',
          title: 'Model access',
          destination: 'Access and connectors',
          detail: 'Expired',
          scope: HealthAlertScope.profile,
          at: start,
          failed: true,
          profileName: name,
        );
      }
      evaluator.finding(
        key: 'endpoint:profile:Research:access',
        title: 'Model access',
        destination: 'Access and connectors',
        detail: 'Unknown',
        scope: HealthAlertScope.profile,
        at: null,
        failed: null,
        profileName: 'Research',
      );
      expect(evaluator.alerts, hasLength(2));
      expect(
        evaluator.alerts
            .where((a) => a.profileName == 'Research')
            .single
            .lastKnown,
        isTrue,
      );
      evaluator.finding(
        key: 'endpoint:profile:default:access',
        title: 'Model access',
        destination: 'Access and connectors',
        detail: 'Available',
        scope: HealthAlertScope.profile,
        at: start,
        failed: false,
        profileName: 'default',
      );
      expect(evaluator.alerts.single.profileName, 'Research');
    },
  );
  test(
    'failed autosave retains the selection for retry and the confirmed policy',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = _HeldStore(prefs)..fail = true;
      final session = HealthAlertSettingsSession(store);
      final original = session.settings;
      final saved = session.update(
        (current) => current.copyWith(enabled: false),
      );
      expect(session.saving, isTrue);
      expect(session.value.enabled, isFalse);
      expect(session.settings, same(original));
      store.gate.complete();
      expect(await saved, isFalse);
      expect(session.settings, same(original));
      expect(session.error, isNotNull);
      store.fail = false;
      expect(await session.retry(), isTrue);
      expect(session.error, isNull);
      expect(HealthAlertSettingsStore(prefs).read().enabled, isFalse);
      session.dispose();
    },
  );
  test('rapid independent edits compose and writes never overlap', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _HeldStore(prefs);
    final session = HealthAlertSettingsSession(store);
    final original = session.settings;
    final first = session.update(
      (current) => current.copyWith(showNotice: false),
    );
    final second = session.update(
      (current) => current.copyWith(enabled: false),
    );
    final third = session.updateRule(
      ram,
      (current) => current.copyWith(warnAbove: 96.5),
    );
    expect(store.writes, 1);
    expect(session.settings, same(original));
    expect(session.value.showNotice, isFalse);
    expect(session.value.enabled, isFalse);
    expect(session.value.rules[ram]!.warnAbove, 96.5);
    store.gate.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(await third, isTrue);
    expect(store.writes, 2);
    final restored = HealthAlertSettingsSession(
      HealthAlertSettingsStore(prefs),
    );
    expect(restored.value.showNotice, isFalse);
    expect(restored.value.enabled, isFalse);
    expect(restored.value.rules[ram]!.warnAbove, 96.5);
    restored.dispose();
    session.dispose();
  });
  test('corrupt policy fails closed with a repair path', () async {
    SharedPreferences.setMockInitialValues({
      HealthAlertSettingsStore.key: 'broken',
    });
    final prefs = await SharedPreferences.getInstance();
    final session = HealthAlertSettingsSession(HealthAlertSettingsStore(prefs));
    expect(session.settings.enabled, isFalse);
    expect(session.error, isNotNull);
    expect(
      await session.update((current) => current.copyWith(enabled: true)),
      isTrue,
    );
    expect(session.settings.enabled, isTrue);
    session.dispose();
  });
  for (final exitCode in [1, 2]) {
    testWidgets('Doctor/security results never become alerts (exit $exitCode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = HostResourcesFixture();
      final host = HostResourcesSession(fixture.server, now: () => start);
      final health = AdministrationHealth(fixture.server, now: () => start);
      final settings = HealthAlertSettingsSession(
        HealthAlertSettingsStore(await SharedPreferences.getInstance()),
      );
      final session = HealthAlertsSession(
        connectionStatus: ServerConnectionStatus('Test server'),
        incidents: HealthAlertIncidentStore(
          await SharedPreferences.getInstance(),
        ),
        host: host,
        health: health,
        settings: settings,
        now: () => start,
      );
      session.setActive(true);
      await host.refresh();
      final saved = health.snapshot();
      for (final name in ['doctor', 'security-audit']) {
        final path = 'ops/$name';
        (saved['generations'] as Map)[path] = 1;
        (saved['diagnostics'] as Map)[path] = {
          'name': name,
          'pid': 42,
          'generation': 1,
          'checkedAt': start.toIso8601String(),
          'status': {
            'running': false,
            'exit_code': exitCode,
            'lines': name == 'doctor'
                ? [
                    List.filled(60, '─').join(),
                    'Found 1 issue(s) to address:',
                    '1. Missing optional connector',
                  ]
                : [
                    'Found 1 known vulnerability finding(s) across 1 component(s):',
                    '[node]',
                    '  HIGH example==1.0 GHSA-example',
                  ],
          },
        };
      }
      health.restore(saved);
      expect(health.diagnostics, hasLength(2));
      expect(
        health.diagnostics.values.every((value) => value.exitCode == exitCode),
        isTrue,
      );
      expect(
        health.diagnostics.values.map((value) => value.classification),
        everyElement(
          exitCode == 1
              ? AdministrationOperationOutcome.findings
              : AdministrationOperationOutcome.failed,
        ),
      );
      expect(session.alerts, isEmpty);
      // The same subscribed session must still admit an actual host incident.
      fixture.pressure = hostPressurePayload(now: start);
      fixture.pressure['memory']['pressure'] = 'critical';
      await host.refresh();
      expect(session.alerts.single.title, 'Critical memory pressure');
      session.dispose();
      host.dispose();
      health.dispose();
      settings.dispose();
      fixture.server.close();
    });
  }
  testWidgets(
    'memory alert retains progress through repeated 30 second background pauses',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var now = start;
      final fixture = HostResourcesFixture();
      fixture.stats['memory']['percent'] = 46.2;
      final host = HostResourcesSession(fixture.server, now: () => now);
      final health = AdministrationHealth(fixture.server, now: () => now);
      final settings = HealthAlertSettingsSession(
        HealthAlertSettingsStore(await SharedPreferences.getInstance()),
      );
      await settings.updateRule(
        ram,
        (current) => current.copyWith(
          warnAbove: 35,
          clearBelow: 30,
          alertMinutes: 1,
          clearMinutes: 2,
        ),
      );
      final session = HealthAlertsSession(
        connectionStatus: ServerConnectionStatus('Test server'),
        incidents: HealthAlertIncidentStore(
          await SharedPreferences.getInstance(),
        ),
        host: host,
        health: health,
        settings: settings,
        now: () => now,
      );
      try {
        session.setActive(true);
        await tester.pump();
        for (var seconds = 30; seconds <= 60; seconds += 30) {
          expect(session.alerts, isEmpty);
          session.setActive(false);
          final pausedReads = fixture.requests.length;
          now = start.add(Duration(seconds: seconds));
          fixture.pressure = hostPressurePayload(now: now);
          await tester.pump(const Duration(seconds: 30));
          expect(fixture.requests, hasLength(pausedReads));
          expect(session.alerts, isEmpty);
          session.setActive(true);
          await tester.pump();
        }
        expect(session.alerts.single.title, 'High memory usage');
        expect(session.alerts.single.severity, HealthAlertSeverity.warning);
      } finally {
        session.dispose();
        host.dispose();
        health.dispose();
        settings.dispose();
        fixture.server.close();
      }
    },
  );
  for (final clearing in [false, true]) {
    final minutes = clearing ? 2 : 1;
    for (final gap in [120, minutes * 180, minutes * 180 + 1]) {
      testWidgets(
        '${clearing ? 'recovery' : 'warning'} resumes after $gap seconds only with a fresh response',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          var now = start;
          final fixture = HostResourcesFixture();
          fixture.stats['memory']['percent'] = 46.2;
          final host = HostResourcesSession(fixture.server, now: () => now);
          final health = AdministrationHealth(fixture.server, now: () => now);
          final settings = HealthAlertSettingsSession(
            HealthAlertSettingsStore(await SharedPreferences.getInstance()),
          );
          await settings.updateRule(
            ram,
            (current) => current.copyWith(
              warnAbove: 35,
              clearBelow: 30,
              alertMinutes: 1,
              clearMinutes: 2,
            ),
          );
          final session = HealthAlertsSession(
            connectionStatus: ServerConnectionStatus('Test server'),
            incidents: HealthAlertIncidentStore(
              await SharedPreferences.getInstance(),
            ),
            host: host,
            health: health,
            settings: settings,
            now: () => now,
          );
          final otherWatch = host.watch(active: false);
          try {
            session.setActive(true);
            await host.refresh();
            if (clearing) {
              now = now.add(const Duration(minutes: 1));
              await host.refresh();
              expect(session.alerts.single.title, 'High memory usage');
              now = now.add(const Duration(seconds: 15));
              fixture.stats['memory']['percent'] = 25.0;
              await host.refresh();
            }
            otherWatch.setActive(true);
            session.setActive(false);
            if (clearing) expect(session.alerts.single.lastKnown, isTrue);
            now = now.add(Duration(seconds: gap));
            await tester.pump(Duration(seconds: gap));
            final reads = fixture.requests.length;
            fixture.statsGate = Completer<void>();
            session.setActive(true);
            expect(fixture.requests, hasLength(reads + 2));
            await tester.pump();
            // An unrelated publication must not use the other watch's cache.
            health.restore(health.snapshot());
            expect(session.alerts, hasLength(clearing ? 1 : 0));
            fixture.statsGate!.complete();
            await host.refresh();
            final retained = gap <= minutes * 180;
            expect(session.alerts, hasLength(clearing == retained ? 0 : 1));
            if (!retained) {
              now = now.add(Duration(minutes: minutes));
              await host.refresh();
              expect(session.alerts, hasLength(clearing ? 0 : 1));
            }
          } finally {
            final gate = fixture.statsGate;
            if (gate != null && !gate.isCompleted) gate.complete();
            otherWatch.close();
            session.dispose();
            host.dispose();
            health.dispose();
            settings.dispose();
            fixture.server.close();
          }
        },
      );
    }
  }
  testWidgets(
    'saved limits immediately retire incidents under the replaced rule',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final fixture = HostResourcesFixture();
      fixture.stats['memory']['percent'] = 93.0;
      var now = start;
      final host = HostResourcesSession(fixture.server, now: () => now);
      final health = AdministrationHealth(fixture.server, now: () => now);
      final settings = HealthAlertSettingsSession(
        HealthAlertSettingsStore(prefs),
      );
      final session = HealthAlertsSession(
        connectionStatus: ServerConnectionStatus('Test server'),
        incidents: HealthAlertIncidentStore(
          await SharedPreferences.getInstance(),
        ),
        host: host,
        health: health,
        settings: settings,
        now: () => now,
      );
      var publications = 0;
      session.addListener(() => publications++);
      session.setActive(true);
      for (var seconds = 0; seconds <= 120; seconds += 15) {
        now = start.add(Duration(seconds: seconds));
        fixture.pressure = hostPressurePayload(now: now);
        await host.refresh();
        if (seconds == 60) {
          await settings.updateRule(
            ram,
            (current) => current.copyWith(nativeCriticalEnabled: false),
          );
        }
      }
      expect(session.alerts.single.severity, HealthAlertSeverity.warning);
      final warning = session.alerts.single;
      await settings.updateRule(
        ram,
        (current) => current.copyWith(nativeCriticalEnabled: true),
      );
      expect(session.alerts.single.occurrence, warning.occurrence);
      final before = publications;
      await host.refresh();
      expect(publications, before);
      await settings.updateRule(
        ram,
        (current) => current.copyWith(warnAbove: 96),
      );
      expect(session.alerts, isEmpty);
      session.dispose();
      host.dispose();
      health.dispose();
      settings.dispose();
      fixture.server.close();
    },
  );
  testWidgets(
    'shared watch pauses; late reads cannot create incidents while inactive',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final fixture = HostResourcesFixture();
      var now = start;
      fixture.pressure = hostPressurePayload(now: now);
      fixture.pressure['memory']['pressure'] = 'critical';
      final host = HostResourcesSession(fixture.server, now: () => now);
      final health = AdministrationHealth(fixture.server, now: () => now);
      final settings = HealthAlertSettingsSession(
        HealthAlertSettingsStore(prefs),
      );
      final session = HealthAlertsSession(
        connectionStatus: ServerConnectionStatus('Test server'),
        incidents: HealthAlertIncidentStore(
          await SharedPreferences.getInstance(),
        ),
        host: host,
        health: health,
        settings: settings,
        now: () => now,
      );
      expect(fixture.requests, isEmpty);
      fixture.statsGate = Completer();
      session.setActive(true);
      expect(fixture.requests, hasLength(2));
      session.setActive(false);
      fixture.statsGate!.complete();
      await host.refresh();
      expect(session.alerts, isEmpty);
      await tester.pump(const Duration(minutes: 3));
      expect(fixture.requests, hasLength(2));
      now = now.add(const Duration(minutes: 3));
      fixture.pressure = hostPressurePayload(now: now);
      fixture.pressure['memory']['pressure'] = 'critical';
      session.setActive(true);
      await host.refresh();
      expect(session.alerts.single.severity, HealthAlertSeverity.critical);
      fixture.statsError = StateError('stats unavailable');
      await host.refresh();
      final monitored = session.alerts.singleWhere((a) => a.scope.monitored);
      expect(monitored.severity, HealthAlertSeverity.critical);
      session.setActive(false);
      await tester.pump(const Duration(minutes: 1));
      expect(
        session.alerts.singleWhere((a) => a.id == monitored.id).lastKnown,
        isTrue,
      );
      await settings.update((current) => current.copyWith(enabled: false));
      expect(session.alerts.single.scope, HealthAlertScope.operational);
      session.dispose();
      host.dispose();
      health.dispose();
      settings.dispose();
      fixture.server.close();
    },
  );
}
