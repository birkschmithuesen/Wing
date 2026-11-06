import 'package:wing/core/models/health_finding.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/administration_health.dart';
import 'package:wing/core/services/administration_overview.dart';
import 'package:wing/core/services/profile_connectors_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/health_alerts_fixture.dart';
import 'support/host_resources_fixture.dart';
import 'package:wing/core/services/health_alert_incident_store.dart';

import 'support/administration_fixture.dart';

void main() {
  late AdministrationFixture fixture;
  late AdministrationOverview overview;
  late AdministrationHealth health;
  var servers = <Map<String, dynamic>>[];
  late Future<Map<String, dynamic>> Function(String) probe;
  var inventoryOffline = false;
  var malformedInventory = false;

  setUp(() {
    fixture = AdministrationFixture();
    servers = [];
    inventoryOffline = false;
    malformedInventory = false;
    probe = (_) async => {'ok': true};
    fixture.override = (method, path, query, body) async {
      if (path == 'system/stats') return hostStatsPayload();
      if (path == 'status') return hostPressurePayload();
      expectSync(query['profile'], 'work');
      if (method == 'GET' && path == 'mcp/servers') {
        if (inventoryOffline) throw StateError('Offline');
        if (malformedInventory) {
          return {
            'servers': [{}],
          };
        }
        return {
          'servers': [
            for (final row in servers)
              {
                'transport': 'http',
                'auth': null,
                'source': 'config',
                'plugin': null,
                ...row,
              },
          ],
        };
      }
      expect(method, 'POST');
      return probe(path);
    };
    overview = AdministrationOverview(fixture.server.profile('work'));
    health = AdministrationHealth(fixture.server)..selectProfile(overview);
  });
  tearDown(() {
    health.dispose();
    overview.dispose();
    fixture.server.close();
  });
  Future<void> refresh() =>
      overview.refresh(keys: {'connectors'}, testConnectors: true);
  AdministrationHealthFinding finding() => health.profileFindings.singleWhere(
    (f) => f.title == 'Connector settings',
  );

  testWidgets('connector inventory refresh retires a removed connector alert', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final alerts = HealthAlertsFixture(
      await SharedPreferences.getInstance(),
      repository: fixture.server,
    );
    final connectors = ProfileConnectorsSession(fixture.server.profile('work'));
    alerts.owner.healthSession().health.selectProfile(overview);
    servers = [
      for (final name in ['grokbot', 'healthy'])
        {
          'name': name,
          'enabled': true,
          'transport': 'http',
          'auth': null,
          'source': 'config',
          'plugin': null,
        },
    ];
    probe = (path) async => {'ok': !path.contains('/grokbot/')};
    await refresh();
    expect(alerts.coordinator.alerts.single.connectorNames, ['grokbot']);
    servers.removeWhere((row) => row['name'] == 'grokbot');
    await connectors.refresh();
    expect(connectors.state.connectors.map((row) => row.name), ['healthy']);
    expect(alerts.coordinator.alerts, isEmpty);
    connectors.dispose();
    alerts.dispose();
  });

  for (final disabled in [false, true]) {
    testWidgets(
      'automatic inventory checks retire ${disabled ? 'disabled' : 'removed'} failures across profiles',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final alerts = HealthAlertsFixture(
          preferences,
          repository: fixture.server,
        );
        final other = AdministrationOverview(
          fixture.server.profile('personal'),
        );
        try {
          alerts.owner.healthSession().health.selectProfile(overview);
          servers = [
            {'name': 'grokbot', 'enabled': true},
            {'name': 'healthy', 'enabled': true},
          ];
          probe = (path) async => {'ok': !path.contains('/grokbot/')};
          await refresh();
          final issue = alerts.coordinator.alerts.single;
          await alerts.coordinator.acknowledge(issue);
          alerts.owner.healthSession().health.selectProfile(other);
          fixture.requests.clear();

          // Neither an unavailable nor a malformed list proves disappearance.
          inventoryOffline = true;
          await tester.pump(const Duration(seconds: 15));
          expect(alerts.coordinator.alerts.single.occurrence, issue.occurrence);
          expect(alerts.coordinator.alerts.single.acknowledged, isTrue);
          inventoryOffline = false;
          malformedInventory = true;
          await tester.pump(const Duration(seconds: 15));
          expect(alerts.coordinator.alerts.single.occurrence, issue.occurrence);
          malformedInventory = false;
          if (disabled) {
            servers.first['enabled'] = false;
          } else {
            servers.removeAt(0);
          }
          await tester.pump(const Duration(seconds: 15));
          expect(alerts.coordinator.alerts, isEmpty);
          expect(alerts.owner.healthSession().health.profileName, 'personal');
          expect(fixture.requests.where((r) => r.$1 != 'GET'), isEmpty);
          expect(
            fixture.requests.where((r) => r.$2 == 'mcp/servers'),
            hasLength(3),
          );
          expect(overview.connectorChecks, isNot(contains('grokbot')));
          expect(
            HealthAlertIncidentStore(
              preferences,
            ).read(fixture.server.connectionIdentity),
            isEmpty,
          );
          final snapshot = overview.healthSnapshot();
          final restored = AdministrationOverview(
            fixture.server.profile('work'),
          );
          restored.restoreHealth(snapshot);
          alerts.owner.healthSession().health.selectProfile(restored);
          expect(alerts.coordinator.alerts, isEmpty);
          alerts.owner.healthSession().health.selectProfile(other);
          restored.dispose();
          fixture.requests.clear();
          await tester.pump(const Duration(seconds: 30));
          expect(fixture.requests.where((r) => r.$2 == 'mcp/servers'), isEmpty);
        } finally {
          alerts.dispose();
          other.dispose();
        }
      },
    );
  }

  testWidgets(
    'restored connector incident rechecks on resume without selecting its profile',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      var alerts = HealthAlertsFixture(preferences, repository: fixture.server);
      alerts.owner.healthSession().health.selectProfile(overview);
      servers = [
        {'name': 'grokbot', 'enabled': true},
      ];
      probe = (_) async => {'ok': false};
      await refresh();
      final issue = alerts.coordinator.alerts.single;
      await alerts.coordinator.snooze(issue);
      alerts.dispose();
      inventoryOffline = true;
      alerts = HealthAlertsFixture(preferences, repository: fixture.server);
      try {
        await tester.pump();
        expect(alerts.coordinator.alerts.single.snoozedUntil, isNotNull);
        expect(alerts.coordinator.alerts.single.lastKnown, isTrue);
        alerts.coordinator.setForeground(false);
        fixture.requests.clear();
        await tester.pump(const Duration(seconds: 30));
        expect(fixture.requests, isEmpty);
        inventoryOffline = false;
        servers = [];
        alerts.coordinator.setForeground(true);
        await tester.pump();
        expect(alerts.coordinator.alerts, isEmpty);
        expect(alerts.owner.healthSession().health.profileName, isNull);
        expect(
          fixture.requests.where((r) => r.$2 == 'mcp/servers'),
          hasLength(1),
        );
        expect(fixture.requests.where((r) => r.$1 != 'GET'), isEmpty);
        expect(
          HealthAlertIncidentStore(
            preferences,
          ).read(fixture.server.connectionIdentity),
          isEmpty,
        );
      } finally {
        alerts.dispose();
      }
    },
  );

  test('mutation invalidation fences an older inventory completion', () async {
    final oldResponse = Completer<Map<String, dynamic>>();
    final started = Completer<void>();
    fixture.override = (_, path, query, _) {
      expect(path, 'mcp/servers');
      expectSync(query['profile'], 'work');
      if (!started.isCompleted) {
        started.complete();
        return oldResponse.future;
      }
      return Future.value({'servers': <Object>[]});
    };
    final inventory = fixture.server.connectorInventory;
    final oldRead = inventory.refresh('work');
    await started.future;
    inventory.invalidate('work');
    await inventory.refresh('work');
    oldResponse.complete({
      'servers': [
        {
          'name': 'grokbot',
          'enabled': true,
          'transport': 'http',
          'auth': null,
          'source': 'config',
          'plugin': null,
        },
      ],
    });
    await oldRead;
    expect(inventory.observations['work']!.enabled, isEmpty);
  });

  testWidgets(
    'a probe completing after removal cannot restore the retired failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final alerts = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
        repository: fixture.server,
      );
      try {
        alerts.owner.healthSession().health.selectProfile(overview);
        servers = [
          {'name': 'grokbot', 'enabled': true},
        ];
        probe = (_) async => {'ok': false};
        await refresh();
        final pending = Completer<Map<String, dynamic>>();
        final started = Completer<void>();
        probe = (_) {
          started.complete();
          return pending.future;
        };
        final oldCheck = refresh();
        await started.future;
        servers = [];
        await fixture.server.connectorInventory.refresh('work');
        expect(alerts.coordinator.alerts, isEmpty);
        pending.complete({'ok': false});
        await oldCheck;
        expect(alerts.coordinator.alerts, isEmpty);
        expect(overview.connectorChecks, isEmpty);
      } finally {
        alerts.dispose();
      }
    },
  );

  test('empty and disabled connector lists need no probes', () async {
    await refresh();
    expect(finding().detail, 'No connectors configured');
    expect(health.failedConnectorNames, isEmpty);
    expect(finding().destination, 'MCP connectors');
    servers = [
      {'name': 'disabled', 'enabled': false},
    ];
    await refresh();
    expect(finding().detail, 'No connectors enabled');
    expect(fixture.requests.every((r) => r.$1 == 'GET'), isTrue);
  });

  test('only enabled connectors are tested in the captured profile', () async {
    servers = [
      {'name': 'service / one', 'enabled': true},
      {'name': 'disabled', 'enabled': false},
    ];
    await refresh();
    expect(fixture.requests.map((r) => r.$2), [
      'mcp/servers',
      'mcp/servers/service%20%2F%20one/test',
    ]);
    expect(finding().detail, '1 of 1 connection check passed');
    expect(finding().status, AdministrationHealthStatus.healthy);
  });

  test('failed and unavailable probes are distinct and can recover', () async {
    servers = [
      {'name': 'first', 'enabled': true},
      {'name': 'second', 'enabled': true},
    ];
    probe = (path) async =>
        path.contains('/first/') ? {'ok': false} : throw StateError('Offline');
    await refresh();
    expect(finding().detail, '0 passed · 1 failed · 1 couldn’t be checked');
    expect(finding().status, AdministrationHealthStatus.warning);
    expect(overview.connectorChecks, {'first': false, 'second': null});
    expect(health.failedConnectorNames, ['first']);
    probe = (_) async => {'ok': 'invalid'};
    await refresh();
    expect(finding().status, AdministrationHealthStatus.unknown);
    expect(finding().detail, '0 passed · 2 couldn’t be checked');
    probe = (_) async => {'ok': true};
    await refresh();
    expect(finding().detail, '2 of 2 connection checks passed');
    expect(health.failedConnectorNames, isEmpty);
  });

  test('late connector checks cannot overwrite a newer refresh', () async {
    servers = [
      {'name': 'first', 'enabled': true},
    ];
    final pending = Completer<Map<String, dynamic>>();
    final started = Completer<void>();
    probe = (_) {
      started.complete();
      return pending.future;
    };
    final old = refresh();
    await started.future;
    probe = (_) async => {'ok': true};
    await refresh();
    pending.complete({'ok': false});
    await old;
    expect(finding().detail, '1 of 1 connection check passed');
  });
}
