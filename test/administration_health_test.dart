import 'package:wing/core/models/administration_operation.dart';
import 'package:wing/core/models/health_finding.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/administration_health.dart';
import 'package:wing/core/services/administration_overview.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/profile_diagnostics_controller.dart';

void main() {
  test(
    'diagnostic observations retain independent deeply immutable status',
    () {
      final status = <String, dynamic>{
        'running': false,
        'exit_code': 0,
        'lines': ['Confirmed output'],
      };
      final observation = AdminDiagnosticObservation(
        const AdministrationAction('doctor', 7),
        status,
        DateTime.utc(2026, 10, 4),
      );
      status['exit_code'] = 1;
      (status['lines'] as List).add('Later input');
      expect(observation.failed, isFalse);
      expect(observation.lines, ['Confirmed output']);
      expect(
        () => diagnosticStatusSnapshot(observation)['running'] = true,
        throwsUnsupportedError,
      );
      expect(() => observation.lines.clear(), throwsUnsupportedError);
    },
  );

  final observedAt = DateTime.utc(2026, 9, 17, 12);
  late DateTime now;
  late AdministrationRepository server;
  late AdministrationHealth health;
  late Future<Map<String, dynamic>> Function(String) readiness;
  late List<String> calls;
  Future<Map<String, dynamic>> Function(String path)? overviewRead;
  var diagnosticPid = 7;
  var rejectDiagnostic = false;
  var diagnosticExit = 0;

  setUp(() {
    now = observedAt;
    calls = [];
    overviewRead = null;
    diagnosticPid = 7;
    rejectDiagnostic = false;
    diagnosticExit = 0;
    readiness = (profile) async => {
      'profile': profile,
      'provider_configured': true,
    };
    server = AdministrationRepository(
      ownedMutation: (_, path, _, _, active, dispatched) async {
        if (!active() || rejectDiagnostic) {
          throw StateError('Start unavailable');
        }
        dispatched();
        return {'ok': true, 'name': path.substring(4), 'pid': diagnosticPid};
      },
      settingsWrite: (_, _, _, _) async =>
          throw StateError('Unexpected settings write'),
      connectionId: 'server',
      connectionIdentity: 'endpoint',
      connectionLabel: 'Server',
      request: (method, path, query, body) async {
        calls.add('$method $path');
        if (path.startsWith('actions/')) {
          return {
            'name': path.split('/')[1],
            'pid': diagnosticPid,
            'running': false,
            'exit_code': diagnosticExit,
            'lines': ['Finding'],
          };
        }
        if (overviewRead != null &&
            path != 'profiles' &&
            path != 'profiles/active') {
          return overviewRead!(path);
        }
        return switch (path) {
          'profiles/active' => {'current': 'default'},
          'profiles' => {
            'profiles': [
              {'name': 'default', 'is_default': true},
            ],
          },
          _ => throw StateError('Unexpected request'),
        };
      },
      gateway: (name) => ProfileGateway(
        scope: WorkspaceScope(
          connectionId: 'server',
          connectionIdentity: 'endpoint',
          profileName: name,
        ),
        get: (path, query) async => throw StateError('Unexpected GET'),
        discover: () => server.discover(),
        rpc: (method, params) {
          calls.add('$method ${params['profile']}');
          expect(method, 'setup.status');
          return readiness(name);
        },
      ),
    );
    health = AdministrationHealth(server, now: () => now);
  });

  tearDown(() {
    health.dispose();
    server.close();
  });

  AdministrationOverview overview(String name) {
    final value = AdministrationOverview(server.profile(name));
    final data = {
      'model': {'provider': 'example', 'model': 'research'},
      'access': {'providers': <Map<String, dynamic>>[]},
      'tools': {'data': <Map<String, dynamic>>[]},
      'connectors': {'servers': <Map<String, dynamic>>[]},
    };
    value.restoreHealth({
      'observations': {
        for (final entry in data.entries)
          entry.key: AdministrationObservation(
            data: entry.value,
            checkedAt: now,
          ).healthSnapshot(),
      },
      'connectorChecks': <String, bool?>{},
    });
    addTearDown(value.dispose);
    return value;
  }

  AdministrationHealthFinding finding(String title) =>
      health.profileFindings.singleWhere((finding) => finding.title == title);

  test(
    'entry consumes existing observations and never runs diagnostics',
    () async {
      health.selectProfile(overview('default'));
      expect(calls, isEmpty);
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.unknown,
      );
      await health.refreshReadiness();
      expect(calls, ['setup.status default']);
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.healthy,
      );
    },
  );

  test(
    'missing and malformed observations are unknown; refresh retains prior results',
    () async {
      final source = overview('default');
      health.selectProfile(source);
      await health.refreshReadiness();
      overviewRead = (_) async => {};
      await source.refresh(keys: {'model'});
      expect(
        finding('Model selection').status,
        AdministrationHealthStatus.unknown,
      );
      final modelRead = Completer<Map<String, dynamic>>();
      overviewRead = (_) => modelRead.future;
      final refreshing = source.refresh(keys: {'model'});
      expect(
        finding('Model selection').status,
        AdministrationHealthStatus.healthy,
      );
      expect(finding('Model selection').detail, contains('Refreshing'));
      modelRead.complete({'provider': 'example', 'model': 'research'});
      await refreshing;
      overviewRead = (_) async => throw StateError('Offline');
      await source.refresh(keys: {'model'});
      expect(
        finding('Model selection').status,
        AdministrationHealthStatus.unknown,
      );
      overviewRead = (_) async => {'provider': 'example', 'model': 'research'};
      await source.refresh(keys: {'model'});
      overviewRead = (_) async => {
        'data': [<String, dynamic>{}],
      };
      await source.refresh(keys: {'tools'});
      expect(finding('Tool setup').status, AdministrationHealthStatus.unknown);
      overviewRead = (_) async => {'data': []};
      await source.refresh(keys: {'tools'});
      overviewRead = (_) async => {
        'providers': [
          {'id': 'example', 'status': {}},
        ],
      };
      await source.refresh(keys: {'access'});
      expect(
        finding('Provider access').status,
        AdministrationHealthStatus.unknown,
      );
    },
  );

  test(
    'configuration does not establish runtime health or provider access',
    () async {
      health.selectProfile(overview('default'));
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.unknown,
      );
      readiness = (profile) async => {'profile': profile};
      await health.refreshReadiness();
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.unknown,
      );
      readiness = (profile) async => {
        'profile': 'another',
        'provider_configured': true,
      };
      await health.refreshReadiness();
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.unknown,
      );
      readiness = (profile) async => {
        'profile': profile,
        'provider_configured': false,
      };
      await health.refreshReadiness();
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.warning,
      );
    },
  );

  test(
    'expired sign-in and tool setup remain distinct and survive failed refresh',
    () async {
      final source = overview('default');
      health.selectProfile(source);
      await health.refreshReadiness();
      overviewRead = (_) async => {
        'data': [
          {'enabled': true, 'configured': false},
        ],
      };
      await source.refresh(keys: {'tools'});
      expect(finding('Tool setup').status, AdministrationHealthStatus.warning);
      overviewRead = (_) async => {
        'providers': [
          {
            'id': 'example',
            'status': {
              'logged_in': true,
              'expires_at': observedAt
                  .subtract(const Duration(seconds: 1))
                  .toIso8601String(),
            },
          },
        ],
      };
      await source.refresh(keys: {'access'});
      expect(
        finding('Provider access').status,
        AdministrationHealthStatus.failure,
      );
      expect(finding('Tool setup').status, AdministrationHealthStatus.warning);
      overviewRead = (_) async => throw StateError('Offline');
      await source.refresh(keys: {'access'});
      now = observedAt.add(const Duration(minutes: 6));
      expect(
        finding('Provider access').status,
        AdministrationHealthStatus.failure,
      );
      expect(
        health.isStale(
          health.profileFindings
              .where((f) => f.title == 'Provider access')
              .single
              .checkedAt,
        ),
        isTrue,
      );
    },
  );

  test(
    'age alone preserves observations; failed refresh qualifies retained results',
    () async {
      health.selectProfile(overview('default'));
      await health.refreshReadiness();
      now = observedAt.add(const Duration(minutes: 5));
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.healthy,
      );
      expect(
        health.profileFindings.every((f) => health.isStale(f.checkedAt)),
        isTrue,
      );
      now = observedAt;
      readiness = (_) => Future.error(StateError('Offline'));
      await health.refreshReadiness();
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.unknown,
      );
      expect(
        health.profileFindings.first.detail,
        contains('Refresh unavailable'),
      );
      expect(health.profileFindings.first.checkedAt, observedAt);
    },
  );

  test(
    'late readiness remains attached to its profile across an A-B-A selection',
    () async {
      final a = overview('default'), b = overview('work');
      final pending = Completer<Map<String, dynamic>>();
      readiness = (_) => pending.future;
      health.selectProfile(a);
      final read = health.refreshReadiness();
      health.selectProfile(null);
      health.selectProfile(b);
      health.selectProfile(a);
      pending.complete({'profile': 'default', 'provider_configured': true});
      await read;
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.healthy,
      );
      expect(health.profileFindings.first.checkedAt, observedAt);
    },
  );

  test(
    'retained runtime results remain scoped to connection across selection',
    () async {
      const path = 'ops/doctor';
      health.selectProfile(overview('default'));
      await health.refreshReadiness();
      await health.startDiagnostic(AdministrationDiagnostic.doctor);
      await health.diagnosticOperation(path)!.refresh();
      diagnosticExit = 1;
      await health.diagnosticOperation(path)!.refresh();
      health.selectProfile(overview('work'));
      expect(
        health.diagnostics[path]!.classification,
        AdministrationOperationOutcome.failed,
      );
      expect(health.profileName, 'work');
      expect(health.diagnostics[path]!.action.pid, 7);
      final old = health.diagnosticOperation(path)!;
      diagnosticPid = 8;
      diagnosticExit = 0;
      await health.startDiagnostic(AdministrationDiagnostic.doctor);
      await health.diagnosticOperation(path)!.refresh();
      await health.refreshReadiness();
      expect(
        health.diagnostics[path]!.classification,
        AdministrationOperationOutcome.completed,
      );
      await old.refresh();
      expect(health.diagnostics[path]!.action.pid, 8);
      expect(
        health.diagnostics[path]!.classification,
        AdministrationOperationOutcome.completed,
      );
      expect(calls.where((c) => c.startsWith('POST')), isEmpty);
    },
  );

  test('invalid diagnostic exit codes cannot report completed or failed', () {
    final invalid = AdminDiagnosticObservation(
      const AdministrationAction('doctor', 7),
      {'running': false, 'exit_code': '0'},
      now,
    );
    expect(invalid.failed, isFalse);
    expect(invalid.outcome, 'Outcome unavailable');
  });

  test(
    'explicit credential failure remains distinct from configuration and profile scoped',
    () async {
      now = DateTime.now();
      final selected = overview('default');
      health.selectProfile(selected);
      await health.refreshReadiness();
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.healthy,
      );

      final runtime = Completer<Map<String, dynamic>>();
      final checks = ProfileDiagnosticsController(
        gateway: ProfileGateway(
          scope: selected.profile.scope,
          get: (path, query) async {
            expect(path, 'sessions');
            return {};
          },
          rpc: (method, params) async {
            expect(params['profile'], 'default');
            return switch (method) {
              'setup.status' => {
                'profile': 'default',
                'provider_configured': true,
              },
              'setup.runtime_check' => await runtime.future,
              _ => throw StateError('Unexpected diagnostic'),
            };
          },
          discover: () => server.discover(),
        ),
      );
      addTearDown(checks.dispose);
      checks.addListener(
        () => health.updateProfileChecks(checks.healthObservation),
      );
      expect(checks.healthObservation.finding, isNull);

      final checking = checks.check();
      expect(
        finding('Provider credential check').status,
        AdministrationHealthStatus.unknown,
      );
      runtime.complete({'profile': 'default', 'ok': false});
      await checking;
      expect(
        finding('Provider credential check').status,
        AdministrationHealthStatus.failure,
      );
      expect(health.profileFindings.last.detail, 'Provider check failed');
      await health.refreshReadiness();
      expect(
        finding('Provider credential check').status,
        AdministrationHealthStatus.failure,
      );
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.healthy,
      );

      health.selectProfile(overview('work'));
      await health.refreshReadiness();
      expect(
        health.profileFindings.where(
          (f) => f.title == 'Provider credential check',
        ),
        isEmpty,
      );
      health.updateProfileChecks(checks.healthObservation);
      expect(
        health.profileFindings.where(
          (f) => f.title == 'Provider credential check',
        ),
        isEmpty,
      );

      health.selectProfile(selected);
      health.updateProfileChecks(checks.healthObservation);
      await health.refreshReadiness();
      expect(
        finding('Provider credential check').status,
        AdministrationHealthStatus.failure,
      );
    },
  );

  test('an explicit check with unavailable outcome stays unknown', () async {
    now = DateTime.now();
    health.selectProfile(overview('default'));
    await health.refreshReadiness();
    final checks = ProfileDiagnosticsController(
      gateway: ProfileGateway(
        scope: server.profile('default').scope,
        get: (path, query) async => {},
        rpc: (method, params) async => method == 'setup.status'
            ? {'profile': 'default', 'provider_configured': true}
            : {},
        discover: () => server.discover(),
      ),
    );
    addTearDown(checks.dispose);
    checks.addListener(
      () => health.updateProfileChecks(checks.healthObservation),
    );
    await checks.check();
    now = DateTime.now();
    expect(
      finding('Provider credential check').status,
      AdministrationHealthStatus.unknown,
    );
    expect(health.isStale(health.profileFindings.last.checkedAt), isFalse);
    expect(health.profileFindings.last.detail, 'Check incomplete');
  });

  test(
    'connection interruption adds uncertainty alongside current profile findings',
    () async {
      final connection = ServerConnectionStatus('Server')..accessAvailable();
      health.dispose();
      health = AdministrationHealth(
        server,
        now: () => now,
        connectionStatus: connection,
      );
      addTearDown(connection.dispose);
      health.selectProfile(overview('default'));
      await health.refreshReadiness();
      expect(
        health.profileFindings.where((f) => f.title == 'Connection'),
        isEmpty,
      );
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.healthy,
      );
      connection.observeChatEndpoint(false);
      connection.accessAvailable();
      expect(finding('Connection').status, AdministrationHealthStatus.failure);
      expect(finding('Connection').detail, contains('Webapp address'));
      connection.observeChatEndpoint(true);
      connection.beginRecovery('workspace');
      expect(finding('Connection').status, AdministrationHealthStatus.unknown);
      expect(health.profileFindings.first.detail, 'Reconnecting');
      connection.endRecovery('workspace');
      connection.liveChanged('workspace', false);
      expect(finding('Connection').status, AdministrationHealthStatus.unknown);
      connection.liveChanged('workspace', true);
      expect(
        health.profileFindings.where((f) => f.title == 'Connection'),
        isEmpty,
      );
      expect(
        finding('Provider configuration').status,
        AdministrationHealthStatus.healthy,
      );
    },
  );
  test(
    'tool setup counts enabled groups and distinguishes empty from unknown',
    () async {
      final source = overview('default');
      health.selectProfile(source);
      AdministrationHealthFinding finding() =>
          health.profileFindings.singleWhere((f) => f.title == 'Tool setup');
      expect(finding().detail, 'No tools enabled');
      final tools = <String, dynamic>{
        'data': [
          {'name': 'search', 'enabled': true, 'configured': true},
          {'name': 'images', 'enabled': true, 'configured': false},
          {'name': 'disabled', 'enabled': false, 'configured': false},
        ],
      };
      overviewRead = (_) async => tools;
      await source.refresh(keys: {'tools'});
      expect(finding().detail, '2 enabled · 1 needs setup');
      expect(finding().status, AdministrationHealthStatus.warning);
      tools['data'][1]['configured'] = true;
      await source.refresh(keys: {'tools'});
      expect(finding().detail, '2 enabled · All set up');
      expect(finding().status, AdministrationHealthStatus.healthy);
      tools['data'][1].remove('configured');
      await source.refresh(keys: {'tools'});
      expect(finding().status, AdministrationHealthStatus.unknown);
    },
  );

  test(
    'server time advances only when both checks in a refresh finish',
    () async {
      await health.runAllDiagnostics();
      await health.diagnosticOperation('ops/doctor')!.refresh();
      expect(health.serverCheckedAt, isNull);
      expect(health.serverCheckIncomplete, isTrue);
      now = now.add(const Duration(minutes: 1));
      diagnosticExit = 1;
      await health.diagnosticOperation('ops/security-audit')!.refresh();
      final first = now;
      expect(health.serverCheckedAt, first);
      expect(health.serverCheckIncomplete, isFalse);
      now = now.add(const Duration(hours: 2));
      diagnosticExit = 0;
      await health.startDiagnostic(AdministrationDiagnostic.doctor);
      await health.diagnosticOperation('ops/doctor')!.refresh();
      expect(health.serverCheckedAt, first);
      await health.runAllDiagnostics();
      await health.diagnosticOperation('ops/doctor')!.refresh();
      expect(health.serverCheckedAt, first);
      final saved = health.snapshot();
      health.dispose();
      health = AdministrationHealth(server, now: () => now)..restore(saved);
      expect(health.serverCheckIncomplete, isTrue);
      await health.diagnosticOperation('ops/security-audit')!.refresh();
      expect(health.serverCheckedAt, now);
      rejectDiagnostic = true;
      await health.runAllDiagnostics();
      expect(health.serverCheckIncomplete, isTrue);
      rejectDiagnostic = false;
      now = now.add(const Duration(minutes: 1));
      await health.startDiagnostic(AdministrationDiagnostic.doctor);
      await health.diagnosticOperation('ops/doctor')!.refresh();
      await health.startDiagnostic(AdministrationDiagnostic.securityAudit);
      await health.diagnosticOperation('ops/security-audit')!.refresh();
      expect(health.serverCheckIncomplete, isFalse);
      expect(health.serverCheckedAt, now);
    },
  );
}
