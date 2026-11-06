import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/screens/administration/admin_connectors_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_connectors.dart';
import 'package:wing/core/models/health_alert.dart';
import 'package:wing/core/services/administration_overview.dart';
import 'package:wing/core/services/connector_inventory.dart';
import 'package:wing/core/services/profile_connectors_session.dart';

import 'helpers/journey_controls.dart';
import 'support/administration_fixture.dart';
import 'support/health_alerts_fixture.dart';
import 'support/host_resources_fixture.dart';
import 'support/form_family_capture.dart';

Map<String, dynamic> _member(String name, {String? plugin}) => {
  'name': name,
  'enabled': true,
  'transport': 'http',
  'auth': 'oauth',
  'source': plugin == null ? 'config' : 'plugin',
  'plugin': plugin,
};

Map<String, dynamic> _runtime(
  String name,
  String status, {
  bool auth = false,
  String? plugin,
}) => {
  'name': name,
  'transport': 'http',
  'tools': status == 'connected' ? 3 : 0,
  'connected': status == 'connected',
  'disabled': status == 'disabled',
  'status': status,
  'source': plugin == null ? 'config' : 'plugin',
  'plugin': plugin,
  'needs_auth': auth,
};

Map<String, dynamic> _status(List<Map<String, dynamic>> rows) => {
  'servers': rows,
  'checked_at': DateTime.now().millisecondsSinceEpoch,
};

void main() {
  setUpAll(loadFormFamilyFonts);
  test(
    'cached runtime distinguishes auth, configured, lazy and invalid facts',
    () {
      final runtime = ConnectorRuntimeObservation.decode(
        _status([
          _runtime('auth', 'failed', auth: true),
          _runtime('not-loaded', 'configured'),
          _runtime('lazy', 'lazy'),
        ]),
        DateTime.now(),
      );
      expect(runtime.rows['auth']!.label, 'Sign in again');
      expect(runtime.rows['not-loaded']!.needsAttention, isFalse);
      expect(runtime.rows['not-loaded']!.recovered, isFalse);
      expect(runtime.rows['lazy']!.recovered, isTrue);
      expect(
        runtime.issuesFor([
          ProfileConnector.decode(_member('auth')),
          ProfileConnector.decode(_member('not-loaded')),
        ]).keys,
        ['auth'],
      );
      expect(
        runtime.issuesFor([
          ProfileConnector.decode({..._member('auth'), 'enabled': false}),
        ]),
        isEmpty,
      );
      expect(() => runtime.rows.clear(), throwsUnsupportedError);
      final invalid = _runtime('invalid', 'connected')..remove('needs_auth');
      expect(
        () => ConnectorRuntimeObservation.decode(
          _status([invalid]),
          DateTime.now(),
        ),
        throwsFormatException,
      );
      expect(
        () => ConnectorRuntimeObservation.decode(
          _status([_runtime('a', 'connected'), _runtime('a', 'configured')]),
          DateTime.now(),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'inventory coalesces reads and fences late cached state after invalidation',
    () async {
      final old = Completer<Map<String, dynamic>>();
      var reads = 0;
      final inventory = ConnectorInventory(
        (_) async => {
          'servers': [_member('docs')],
        },
        (_) async {
          reads++;
          return reads == 1
              ? old.future
              : _status([_runtime('docs', 'connected')]);
        },
      );
      addTearDown(inventory.dispose);
      final first = inventory.refresh('work');
      expect(identical(first, inventory.refresh('work')), isTrue);
      await Future<void>.delayed(Duration.zero);
      inventory.invalidate('work');
      await inventory.refresh('work');
      old.complete(_status([_runtime('docs', 'failed', auth: true)]));
      await first;
      expect(reads, 2);
      expect(
        inventory.runtimeObservations['work']!.rows['docs']!.status,
        ConnectorRuntimeStatus.connected,
      );
    },
  );

  test(
    'runtime read failure preserves configuration and last cached provenance',
    () async {
      var fail = false;
      final inventory = ConnectorInventory(
        (_) async => {
          'servers': [_member('docs')],
        },
        (_) async {
          if (fail) throw TimeoutException('cached read');
          return _status([_runtime('docs', 'failed', auth: true)]);
        },
      );
      addTearDown(inventory.dispose);
      await inventory.refresh('work');
      final last = inventory.runtimeObservations['work'];
      fail = true;
      final membership = await inventory.refresh('work');
      expect(membership['servers'], hasLength(1));
      expect(inventory.observations['work']!.enabled['docs'], isTrue);
      expect(identical(inventory.runtimeObservations['work'], last), isTrue);
      expect(inventory.runtimeError('work'), isNotNull);
    },
  );

  test(
    'production connector owner reads exact scoped status without probes or auth',
    () async {
      final fixture = AdministrationFixture();
      final profiles = <String>[];
      fixture.rpcOverride = (method, params) async {
        expect(method, 'mcp.servers.status');
        profiles.add(params['profile'] as String);
        return _status([_runtime('docs', 'failed', auth: true)]);
      };
      fixture.override = (method, path, query, body) async {
        if (path == 'mcp/servers') {
          return {
            'servers': [_member('docs')],
          };
        }
        throw StateError('Unexpected $method $path');
      };
      final session = ProfileConnectorsSession(fixture.server.profile('work'));
      addTearDown(session.dispose);
      await session.refresh();
      expect(session.state.verified, isTrue);
      final row = session.state.connectors.single;
      expect(row.canSignIn, isTrue);
      expect(session.state.runtime!.forConnector(row)!.needsAuth, isTrue);
      expect(session.state.probe, isNull);
      expect(profiles, ['work']);
      expect(fixture.requests.every((request) => request.$1 == 'GET'), isTrue);
    },
  );

  for (final oldPlugin in <String?>[null, 'plugin-a']) {
    testWidgets('held runtime cannot cross owner $oldPlugin to plugin-b', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = AdministrationFixture();
      String? configurationPlugin = oldPlugin;
      String? runtimePlugin = oldPlugin;
      var status = 'configured';
      Completer<void>? gate;
      fixture.rpcOverride = (method, params) async {
        expectSync(method, 'mcp.servers.status');
        expectSync(params['profile'], 'work');
        final response = _status([
          _runtime('docs', status, plugin: runtimePlugin),
        ]);
        await gate?.future;
        return response;
      };
      fixture.override = (method, path, query, body) async {
        if (path == 'system/stats') return hostStatsPayload();
        if (path == 'status') return hostPressurePayload();
        if (path == 'mcp/servers') {
          return {
            'servers': [_member('docs', plugin: configurationPlugin)],
          };
        }
        throw StateError('Unexpected $method $path');
      };
      final alerts = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
        repository: fixture.server,
      );
      final overview = AdministrationOverview(fixture.server.profile('work'));
      final connectors = ProfileConnectorsSession(
        fixture.server.profile('work'),
      );
      final health = alerts.owner.healthSession().health;
      health.selectProfile(overview);
      Future<void> refreshTogether() async {
        await Future.wait([
          overview.refresh(keys: {'connectors'}),
          connectors.refresh(),
        ]);
      }

      Iterable<HealthAlert> runtimeAlerts() => alerts.coordinator.alerts.where(
        (alert) => alert.title == 'Connector runtime',
      );
      await refreshTogether();
      expect(runtimeAlerts(), isEmpty);

      // Membership now belongs to a different owner while the old owner's
      // cached failure arrives late from the concurrently dispatched read.
      configurationPlugin = 'plugin-b';
      status = 'failed';
      gate = Completer<void>();
      final crossingFailure = refreshTogether();
      await tester.pump();
      expect(connectors.state.busy, isTrue);
      gate.complete();
      await crossingFailure;
      expect(
        connectors.state.runtime!.forConnector(
          connectors.state.connectors.single,
        ),
        isNull,
      );
      expect(overview.connectorRuntimeIssues, isEmpty);
      expect(runtimeAlerts(), isEmpty);
      expect(
        health.profileFindings
            .singleWhere((finding) => finding.title == 'Connector settings')
            .detail,
        isNot(contains('runtime connection failed')),
      );

      // Establish a real incident for the current owner, then receive the
      // previous owner's successful runtime. That cannot recover this owner.
      gate = null;
      runtimePlugin = configurationPlugin;
      await refreshTogether();
      expect(overview.connectorRuntimeIssues.keys, ['docs']);
      expect(runtimeAlerts(), hasLength(1));
      runtimePlugin = oldPlugin;
      status = 'connected';
      gate = Completer<void>();
      final crossingRecovery = refreshTogether();
      await tester.pump();
      expect(connectors.state.busy, isTrue);
      gate.complete();
      await crossingRecovery;
      expect(
        connectors.state.runtime!.forConnector(
          connectors.state.connectors.single,
        ),
        isNull,
      );
      expect(overview.connectorRuntimeIssues, isEmpty);
      expect(runtimeAlerts(), hasLength(1));
      expect(runtimeAlerts().single.lastKnown, isTrue);

      // A positively recovered observation for the actual current owner clears.
      gate = null;
      runtimePlugin = configurationPlugin;
      await refreshTogether();
      expect(runtimeAlerts(), isEmpty);
      connectors.dispose();
      overview.dispose();
      alerts.dispose();
      fixture.server.close();
    });
  }

  for (final hasProbeFailure in [false, true]) {
    testWidgets('runtime recovery preserves probe provenance $hasProbeFailure', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = AdministrationFixture();
      var state = 'failed',
          auth = true,
          unavailable = false,
          membershipUnavailable = false;
      fixture.rpcOverride = (method, params) async {
        expect(method, 'mcp.servers.status');
        if (unavailable) throw TimeoutException('runtime status');
        return _status([_runtime('docs', state, auth: auth)]);
      };
      fixture.override = (method, path, query, body) async {
        if (path == 'system/stats') return hostStatsPayload();
        if (path == 'status') return hostPressurePayload();
        if (path == 'mcp/servers') {
          if (membershipUnavailable) {
            throw StateError('configuration unavailable');
          }
          return {
            'servers': [_member('docs')],
          };
        }
        if (path == 'mcp/servers/docs/test') return {'ok': !hasProbeFailure};
        throw StateError('Unexpected $method $path');
      };
      final alerts = HealthAlertsFixture(
        await SharedPreferences.getInstance(),
        repository: fixture.server,
      );
      final overview = AdministrationOverview(fixture.server.profile('work'));
      final other = AdministrationOverview(fixture.server.profile('personal'));
      final health = alerts.owner.healthSession().health;
      health.selectProfile(overview);
      await overview.refresh(
        keys: {'connectors'},
        testConnectors: hasProbeFailure,
      );
      expect(
        alerts.coordinator.alerts.where(
          (alert) => alert.title == 'Connector runtime',
        ),
        hasLength(1),
      );
      if (hasProbeFailure) {
        expect(
          alerts.coordinator.alerts.where(
            (alert) => alert.title == 'Connector settings',
          ),
          hasLength(1),
        );
      }
      final originalCheck = overview.observations['connectors']!.checkedAt;
      membershipUnavailable = true;
      await expectLater(
        fixture.server.connectorInventory.refresh('work'),
        throwsA(isA<StateError>()),
      );
      expect(
        alerts.coordinator.alerts
            .where((alert) => alert.title == 'Connector runtime')
            .single
            .lastKnown,
        isTrue,
      );
      membershipUnavailable = false;
      state = 'configured';
      auth = false;
      await fixture.server.connectorInventory.refresh('work');
      expect(
        alerts.coordinator.alerts
            .where((alert) => alert.title == 'Connector runtime')
            .single
            .lastKnown,
        isTrue,
      );
      state = 'failed';
      auth = true;
      await fixture.server.connectorInventory.refresh('work');
      expect(
        alerts.coordinator.alerts
            .where((alert) => alert.title == 'Connector runtime')
            .single
            .lastKnown,
        isFalse,
      );
      unavailable = true;
      await fixture.server.connectorInventory.refresh('work');
      expect(
        alerts.coordinator.alerts
            .where((alert) => alert.title == 'Connector runtime')
            .single
            .lastKnown,
        isTrue,
      );
      unavailable = false;
      state = 'connected';
      auth = false;
      // A different selected profile must not prevent exact old-profile recovery.
      health.selectProfile(other);
      await fixture.server.connectorInventory.refresh('work');
      expect(
        alerts.coordinator.alerts.where(
          (alert) => alert.title == 'Connector runtime',
        ),
        isEmpty,
      );
      expect(
        alerts.coordinator.alerts.where(
          (alert) => alert.title == 'Connector settings',
        ),
        hasLength(hasProbeFailure ? 1 : 0),
      );
      if (hasProbeFailure) {
        await overview.refresh(keys: {'connectors'});
        expect(overview.connectorChecks['docs'], isFalse);
        expect(overview.observations['connectors']!.checkedAt, originalCheck);
      }
      alerts.dispose();
      overview.dispose();
      other.dispose();
      fixture.server.close();
    });
  }

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('cached connector UI retains test provenance $dark $scale', (
        tester,
      ) async {
        final width = scale == 2 ? 320.0 : 390.0;
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = AdministrationFixture();
        var gate = Completer<void>();
        var unavailable = false;
        fixture.override = (method, path, query, body) async {
          if (path == 'mcp/servers') {
            return {
              'servers': [_member('docs')],
            };
          }
          throw StateError('Unexpected $method $path');
        };
        fixture.rpcOverride = (method, params) async {
          expect(method, 'mcp.servers.status');
          await gate.future;
          if (unavailable) throw TimeoutException('cached status unavailable');
          return _status([_runtime('docs', 'failed', auth: true)]);
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: formFamilyCapture, child: child!),
            ),
            home: AdminConnectorsPage(
              createSession: () =>
                  ProfileConnectorsSession(fixture.server.profile('work')),
              pushSetup: (_, _) async => throw StateError('Unexpected setup'),
              pushDetail: (context, name, createRoute) =>
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => AdminConnectorDetail(
                        createRoute: () => createRoute(name),
                      ),
                    ),
                  ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(StudioLoading), findsWidgets);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('http · Cached: Sign in again'), findsOneWidget);
        expect(
          MediaQuery.sizeOf(tester.element(find.byType(ListView))).width,
          width,
        );
        await captureFormFamily(tester, 'connector-cached-list-$dark-$scale');
        gate = Completer<void>();
        await tester.tap(find.byTooltip('Refresh connectors'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(StudioLoading), findsWidgets);
        expect(find.text('http · Cached: Sign in again'), findsOneWidget);
        await captureFormFamily(
          tester,
          'connector-cached-pending-$dark-$scale',
        );
        unavailable = true;
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          find.text('Cached connector status is unavailable.'),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.text('http · Cached: Sign in again'),
          150,
        );
        await dragViewportToControl(
          tester,
          find.byType(Scrollable),
          find.text('http · Cached: Sign in again'),
        );
        expect(
          find.text('http · Cached: Sign in again').hitTestable(),
          findsOneWidget,
        );
        await captureFormFamily(tester, 'connector-cached-failed-$dark-$scale');
        unavailable = false;
        gate = Completer<void>();
        await tester.scrollUntilVisible(
          find.byTooltip('Refresh connectors'),
          -150,
        );
        await dragViewportToControl(
          tester,
          find.byType(Scrollable),
          find.byTooltip('Refresh connectors'),
        );
        await tester.tap(find.byTooltip('Refresh connectors'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(StudioLoading), findsWidgets);
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          find.text('Cached connector status is unavailable.'),
          findsNothing,
        );
        await captureFormFamily(
          tester,
          'connector-cached-recovered-$dark-$scale',
        );
        await tester.scrollUntilVisible(find.text('docs'), -150);
        await dragViewportToControl(
          tester,
          find.byType(Scrollable),
          find.text('docs'),
        );
        await tester.tap(find.text('docs'));
        await tester.pumpAndSettle();
        expect(find.text('Not tested'), findsOneWidget);
        expect(
          find.textContaining('Cached runtime: Sign in again'),
          findsOneWidget,
        );
        await captureFormFamily(tester, 'connector-cached-detail-$dark-$scale');
        expect(fixture.requests.every((row) => row.$1 == 'GET'), isTrue);
        expect(
          fixture.rpcRequests.every((row) => row.$2 == 'mcp.servers.status'),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
