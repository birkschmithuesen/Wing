import 'package:wing/core/models/administration_operation.dart';
import 'support/administration_operation_fixture.dart';
import 'support/health_alerts_fixture.dart';
import 'support/host_resources_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/health_alert.dart';
import 'package:wing/core/screens/administration/admin_runtime_health.dart';
import 'package:wing/core/services/administration_health_session.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/scheduled_tasks_controller.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';

void main() {
  late SharedPreferences preferences;
  late AdministrationRepository server;
  late DateTime now;
  late List<(String, String, String?)> requests;
  late Map<String, ProfileWorkspaceData> workspaces;
  Completer<Map<String, dynamic>>? accessGate;
  var diagnosticRunning = false;
  var tasksOffline = false;
  var taskRows = <Map<String, dynamic>>[];
  var connectorRows = <Map<String, dynamic>>[];
  var nextPid = 8;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    now = DateTime(2026, 9, 19, 12);
    requests = [];
    workspaces = {};
    accessGate = null;
    diagnosticRunning = false;
    tasksOffline = false;
    taskRows = [];
    connectorRows = [];
    nextPid = 8;
    ProfileGateway gateway(String name) => ProfileGateway(
      scope: WorkspaceScope(
        connectionId: 'server',
        connectionIdentity: 'endpoint',
        profileName: name,
      ),
      get: (_, _) async => {},
      discover: () async => const ProfileDiscovery(
        currentName: 'default',
        activeName: 'default',
        profiles: [
          HermesProfile(name: 'default', isDefault: true),
          HermesProfile(name: 'work'),
        ],
      ),
      rpc: (method, params) async {
        requests.add(('RPC', method, name));
        if (method == 'mcp.servers.status') {
          return {
            'checked_at': DateTime.now().millisecondsSinceEpoch,
            'servers': [
              for (final row in connectorRows)
                {
                  'name': row['name'],
                  'transport': row['transport'],
                  'source': row['source'],
                  'plugin': row['plugin'],
                  'tools': 0,
                  'connected': false,
                  'disabled': row['enabled'] == false,
                  'status': row['enabled'] == false ? 'disabled' : 'configured',
                  'needs_auth': false,
                },
            ],
          };
        }
        if (method == 'setup.runtime_check' &&
            name == 'default' &&
            accessGate != null) {
          return accessGate!.future;
        }
        return {
          'profile': name,
          'ok': true,
          'provider_configured': true,
          'model': 'model-$name',
          'provider': 'provider',
        };
      },
    );
    server = AdministrationRepository(
      ownedMutation: (method, path, query, body, active, dispatched) async {
        if (!active()) throw StateError('Retired diagnostic');
        dispatched();
        return server.request(method, path, query, body);
      },
      settingsWrite: (_, _, _, _) async =>
          throw StateError('Unexpected settings write'),
      connectionId: 'server',
      connectionIdentity: 'endpoint',
      connectionLabel: 'Server',
      gateway: gateway,
      request: (method, path, query, body) async {
        final name = query['profile'];
        requests.add((method, path, name));
        return switch (path) {
          'system/stats' => hostStatsPayload(),
          'status' => hostPressurePayload(now: now),
          'model/info' => {
            'model': 'model-$name',
            'provider': 'provider',
            'api_key': 'must-not-save',
          },
          'providers/oauth' => {'providers': []},
          'tools/toolsets' => {
            'data': [
              {
                'name': 'tool-$name',
                'enabled': true,
                'configured': name == 'default',
              },
            ],
          },
          'mcp/servers' => {'servers': connectorRows},
          'mcp/servers/grokbot/test' => {'ok': false},
          'cron/jobs' =>
            tasksOffline
                ? throw StateError('offline')
                : {
                    'data': [
                      for (final task in taskRows)
                        {...task, 'profile': name!, 'profile_name': name},
                    ],
                  },
          'ops/doctor' || 'ops/security-audit' => {
            'ok': true,
            'name': path.substring(4),
            'pid': ++nextPid,
          },
          'actions/doctor/status' || 'actions/security-audit/status' => {
            'name': path.split('/')[1],
            'pid': nextPid,
            'running': diagnosticRunning,
            'exit_code': diagnosticRunning ? null : 0,
            'lines': ['Stored diagnostic output'],
          },
          _ => throw StateError('Unexpected $method $path'),
        };
      },
    );
    for (final name in ['default', 'work']) {
      workspaces[name] = ProfileWorkspaceData(gateway(name));
    }
  });
  tearDown(() {
    server.close();
  });

  AdministrationHealthSession create() =>
      AdministrationHealthSession(server, preferences, now: () => now);
  Future<void> select(AdministrationHealthSession session, String name) async {
    session.select(workspaces[name]?.gateway);
    await session.refresh(workspaces[name]!.gateway);
    await session.saved;
  }

  void completed(
    AdministrationHealthSession session,
    String path,
    DateTime at,
  ) {
    restoreDiagnostic(
      session.health,
      path,
      AdminDiagnosticObservation(
        AdministrationAction(path.substring(4), nextPid),
        {
          'pid': nextPid,
          'running': false,
          'exit_code': 0,
          'lines': ['Stored diagnostic output'],
        },
        at,
      ),
    );
  }

  testWidgets(
    'profile results survive restart, stay separate, and expire independently',
    (tester) async {
      var session = create();
      await select(session, 'default');
      now = now.add(const Duration(hours: 2));
      await select(session, 'work');
      expect(
        session.health.profileFindings.any(
          (f) => f.detail == '1 enabled · 1 needs setup',
        ),
        isTrue,
      );
      session.dispose();
      await session.saved;
      final stored = preferences
          .getKeys()
          .where((k) => k.startsWith('health-results:'))
          .single;
      expect(preferences.getString(stored), isNot(contains('must-not-save')));
      // Recreate preferences too, exercising the serialized state rather than a registry.
      SharedPreferences.setMockInitialValues({
        stored: preferences.getString(stored)!,
      });
      preferences = await SharedPreferences.getInstance();
      requests.clear();
      session = create();
      session.select(workspaces['default']?.gateway);
      await tester.pump();
      expect(requests, isEmpty);
      expect(
        session.health.profileFindings.any(
          (f) => f.detail == '1 enabled · All set up',
        ),
        isTrue,
      );
      expect(
        session
            .checksFor(workspaces['default']!.gateway)
            .healthObservation
            .finding
            ?.detail,
        'Access is set up',
      );
      session.select(workspaces['work']?.gateway);
      await tester.pump();
      expect(requests, isEmpty);
      expect(
        session.health.profileFindings.any(
          (f) => f.detail == '1 enabled · 1 needs setup',
        ),
        isTrue,
      );
      now = now.add(const Duration(hours: 22));
      session.select(workspaces['work']?.gateway);
      await tester.pump();
      expect(requests, isEmpty);
      session.select(workspaces['default']?.gateway);
      await tester.pumpAndSettle();
      expect(
        requests.where((r) => r.$2 == 'setup.runtime_check').map((r) => r.$3),
        ['default'],
      );
      session.dispose();
    },
  );

  testWidgets('checks finish off-screen and are reused on returning', (
    tester,
  ) async {
    final session = create();
    accessGate = Completer();
    session.select(workspaces['default']?.gateway);
    await tester.pump();
    expect(session.checking('default'), isTrue);
    session.select(workspaces['work']?.gateway);
    await tester.pumpAndSettle();
    accessGate!.complete({
      'ok': true,
      'profile': 'default',
      'model': 'model-default',
      'provider': 'provider',
    });
    await tester.pumpAndSettle();
    requests.clear();
    session.select(workspaces['default']?.gateway);
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(session.checking('default'), isFalse);
    expect(
      session
          .checksFor(workspaces['default']!.gateway)
          .healthObservation
          .finding
          ?.detail,
      'Access is set up',
    );
    session.dispose();
  });

  testWidgets('retained health overview registry rejects external changes', (
    tester,
  ) async {
    final session = create();
    await select(session, 'default');
    final registry = session.overviews;
    expect(() => registry.clear(), throwsUnsupportedError);
    expect(() => registry.remove('default'), throwsUnsupportedError);
    await select(session, 'work');
    expect(registry.keys, ['default']);
    expect(session.overviews.keys, ['default', 'work']);
    session.dispose();
  });

  testWidgets('access review keeps its profile through reentrant selection', (
    tester,
  ) async {
    final session = create();
    await select(session, 'default');
    await select(session, 'work');
    session.select(workspaces['default']!.gateway);
    final checks = session.checksFor(workspaces['default']!.gateway);
    var changedSelection = false;
    void selected() {
      if (changedSelection) return;
      changedSelection = true;
      session.select(workspaces['work']!.gateway);
    }

    checks.addListener(selected);
    requests.clear();
    await session.reviewAccess(workspaces['default']!.gateway, (profile) async {
      expect(profile.scope, workspaces['default']!.scope);
    });
    expect(changedSelection, isTrue);
    expect(session.health.profileName, 'work');
    expect(
      requests.where((r) => r.$2 == 'setup.runtime_check').map((r) => r.$3),
      ['default'],
    );
    expect(session.checksFor(workspaces['default']!.gateway), same(checks));
    checks.removeListener(selected);
    session.dispose();
  });

  testWidgets('access review drains invalidated work before a fresh check', (
    tester,
  ) async {
    final session = create();
    await select(session, 'default');
    accessGate = Completer();
    final older = session.refresh(workspaces['default']!.gateway);
    await tester.pump();
    expect(session.checking('default'), isTrue);
    requests.clear();
    final review = session.reviewAccess(
      workspaces['default']!.gateway,
      (_) async {},
    );
    await tester.pump();
    expect(requests.where((r) => r.$2 == 'setup.runtime_check'), isEmpty);
    final gate = accessGate!;
    accessGate = null;
    gate.complete({'ok': false, 'profile': 'default'});
    await older;
    await review;
    expect(
      requests.where((r) => r.$2 == 'setup.runtime_check').map((r) => r.$3),
      ['default'],
    );
    expect(
      session
          .checksFor(workspaces['default']!.gateway)
          .healthObservation
          .finding
          ?.detail,
      'Access is set up',
    );
    session.dispose();
  });

  testWidgets(
    'retiring the health owner while an editor is open stops rechecks',
    (tester) async {
      final session = create();
      await select(session, 'default');
      final editor = Completer<void>();
      var opened = 0;
      final review = session.reviewAccess(workspaces['default']!.gateway, (_) {
        opened++;
        return editor.future;
      });
      expect(opened, 1);
      session.dispose();
      await session.saved;
      requests.clear();
      editor.complete();
      await review;
      await session.reviewAccess(workspaces['default']!.gateway, (_) async {
        opened++;
      });
      expect(opened, 1);
      expect(requests, isEmpty);
    },
  );

  testWidgets(
    'access review refuses foreign connection authority before navigation',
    (tester) async {
      final session = create();
      await select(session, 'default');
      final checks = session.checksFor(workspaces['default']!.gateway);
      for (final scope in [
        WorkspaceScope(
          connectionId: 'other',
          connectionIdentity: 'endpoint',
          profileName: 'default',
        ),
        WorkspaceScope(
          connectionId: 'server',
          connectionIdentity: 'other',
          profileName: 'default',
        ),
      ]) {
        final foreign = ProfileGateway(
          scope: scope,
          get: (_, _) async => throw StateError('Foreign read'),
          rpc: (_, _) async => throw StateError('Foreign RPC'),
          discover: () async => throw StateError('Foreign discovery'),
        );
        requests.clear();
        var opened = false;
        await expectLater(
          session.reviewAccess(foreign, (_) async {
            opened = true;
          }),
          throwsArgumentError,
        );
        expect(opened, isFalse);
        expect(requests, isEmpty);
        expect(session.checksFor(workspaces['default']!.gateway), same(checks));
      }
      session.dispose();
    },
  );

  testWidgets('retirement while draining a check prevents fresh access work', (
    tester,
  ) async {
    final session = create();
    await select(session, 'default');
    accessGate = Completer();
    final older = session.refresh(workspaces['default']!.gateway);
    await tester.pump();
    expect(session.checking('default'), isTrue);
    final review = session.reviewAccess(
      workspaces['default']!.gateway,
      (_) async {},
    );
    await tester.pump();
    session.dispose();
    requests.clear();
    final gate = accessGate!;
    accessGate = null;
    gate.complete({'ok': true, 'profile': 'default'});
    await older;
    await review;
    expect(requests, isEmpty);
    await session.saved;
  });

  testWidgets(
    'server results survive restart and only expired diagnostics rerun on entry',
    (tester) async {
      var session = create();
      completed(session, 'ops/doctor', now.subtract(const Duration(hours: 25)));
      completed(
        session,
        'ops/security-audit',
        now.subtract(const Duration(hours: 2)),
      );
      session.dispose();
      await session.saved;
      session = create();
      expect(session.health.diagnostics, hasLength(2));
      expect(session.health.diagnostics['ops/doctor']!.lines, [
        'Stored diagnostic output',
      ]);
      expect(requests, isEmpty);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminRuntimeHealth(health: session.health)),
        ),
      );
      await session.health.refreshDiagnostics();
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.$1 == 'POST').map((r) => r.$2), [
        'ops/doctor',
      ]);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminRuntimeHealth(health: session.health)),
        ),
      );
      await session.health.refreshDiagnostics();
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.$1 == 'POST'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'unconfirmed starts are not replayed after navigation or restart',
    (tester) async {
      var session = create();
      final saved = session.health.snapshot();
      for (final path in ['ops/doctor', 'ops/security-audit']) {
        (saved['generations'] as Map)[path] = 1;
        (saved['attempted'] as Map)[path] = {
          'at': now.toUtc().toIso8601String(),
          'generation': 1,
        };
      }
      session.health.restore(saved);
      session.dispose();
      await session.saved;
      session = create();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminRuntimeHealth(health: session.health)),
        ),
      );
      await session.health.refreshDiagnostics();
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.text('Start not confirmed'), findsNWidgets(2));
      expect(session.health.canStartDiagnostic('ops/doctor'), isTrue);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'unfinished diagnostics resume reads after restart without starting again',
    (tester) async {
      var session = create();
      restoreDiagnostic(
        session.health,
        'ops/doctor',
        AdminDiagnosticObservation(AdministrationAction('doctor', nextPid), {
          'running': true,
        }, now),
      );
      session.dispose();
      await session.saved;
      session = create();
      await tester.pump(Duration.zero);
      expect(requests, [('GET', 'actions/doctor/status', null)]);
      expect(session.health.diagnostics['ops/doctor']!.outcome, 'Completed');
      session.dispose();
    },
  );

  for (final removed in [false, true]) {
    testWidgets(
      'task list recovery clears a restored scheduled task alert (removed: $removed)',
      (tester) async {
        now = DateTime.now();
        taskRows = [
          {
            'id': 'failed',
            'enabled': true,
            'state': 'scheduled',
            'last_error': 'Delivery failed',
            'schedule': {'kind': 'interval', 'minutes': 60},
          },
        ];
        var session = create();
        await select(session, 'default');
        session.dispose();
        await session.saved;

        // Saved profile checks suppress a full refresh after reopening Health.
        final fixture = HealthAlertsFixture(preferences, repository: server);
        session = fixture.owner.healthSession();
        requests.clear();
        session.select(workspaces['default']!.gateway);
        await tester.pump();
        expect(requests, isEmpty);
        final alerts = fixture.coordinator;
        final tasks = ScheduledTasksController.acquire(
          server.profile('default'),
          preferences,
        );
        try {
          await fixture.owner.hostResources().refresh();
          expect(alerts.alerts.single.title, 'Scheduled tasks');
          final occurrence = alerts.alerts.single.occurrence;

          // An unavailable task read is not evidence of recovery.
          tasksOffline = true;
          await tasks.refresh();
          expect(alerts.alerts.single.occurrence, occurrence);
          tasksOffline = false;
          if (removed) {
            taskRows.clear();
          } else {
            taskRows.single['last_error'] = '';
          }
          await tasks.refresh();
          expect(tasks.tasks!.any((task) => task.needsAttention), isFalse);
          expect(alerts.alerts, isEmpty);
          await session.saved;
          final finding = session.health.profileFindings.singleWhere(
            (f) => f.title == 'Scheduled tasks',
          );
          expect(
            finding.detail,
            removed ? 'No scheduled tasks' : '1 task · No reported errors',
          );
        } finally {
          tasks.release();
          fixture.dispose();
          await session.saved;
        }
        session = create();
        session.select(workspaces['default']!.gateway);
        expect(
          session.health.profileFindings
              .singleWhere((f) => f.title == 'Scheduled tasks')
              .detail,
          removed ? 'No scheduled tasks' : '1 task · No reported errors',
        );
        session.dispose();
      },
    );
  }

  testWidgets(
    'task data loaded before health selection replaces its saved failure',
    (tester) async {
      taskRows = [
        {
          'id': 'failed',
          'enabled': true,
          'state': 'scheduled',
          'last_error': 'Delivery failed',
          'schedule': {'kind': 'interval', 'minutes': 60},
        },
      ];
      var session = create();
      await select(session, 'default');
      session.dispose();
      await session.saved;
      final tasks = ScheduledTasksController.acquire(
        server.profile('default'),
        preferences,
      );
      taskRows.single['last_error'] = '';
      await tasks.refresh();
      session = create();
      final observedDetails = <String>[];
      session.health.addListener(() {
        for (final finding in session.health.profileFindings) {
          if (finding.title == 'Scheduled tasks') {
            observedDetails.add(finding.detail);
          }
        }
      });
      requests.clear();
      session.select(workspaces['default']!.gateway);
      await tester.pump();
      expect(requests, isEmpty);
      expect(observedDetails, isNotEmpty);
      expect(observedDetails, everyElement('1 task · No reported errors'));
      tasks.release();
      session.dispose();
    },
  );

  testWidgets(
    'fresh task data clears an acknowledged alert for an unselected profile after restart',
    (tester) async {
      now = DateTime.now();
      var fixture = HealthAlertsFixture(preferences, repository: server);
      var session = fixture.owner.healthSession();
      List<HealthAlert> taskAlerts() => fixture.coordinator.alerts
          .where((alert) => alert.title == 'Scheduled tasks')
          .toList();
      await select(session, 'default');
      taskRows = [
        {
          'id': 'failed',
          'enabled': true,
          'state': 'scheduled',
          'last_error': 'Delivery failed',
          'schedule': {'kind': 'interval', 'minutes': 60},
        },
      ];
      await select(session, 'work');
      final issue = taskAlerts().single;
      await fixture.coordinator.acknowledge(issue);
      expect(taskAlerts().single.acknowledged, isTrue);
      fixture.dispose();
      await session.saved;

      fixture = HealthAlertsFixture(preferences, repository: server);
      session = fixture.owner.healthSession();
      session.select(workspaces['default']!.gateway);
      await tester.pump();
      final tasks = ScheduledTasksController.acquire(
        server.profile('work'),
        preferences,
      );
      try {
        expect(session.health.profileName, 'default');
        expect(taskAlerts().single.profileName, 'work');
        taskRows.single['last_error'] = '';
        await tasks.refresh();
        expect(tasks.tasks!.single.needsAttention, isFalse);
        expect(taskAlerts(), isEmpty);
        expect(session.health.profileName, 'default');
      } finally {
        tasks.release();
        fixture.dispose();
        await session.saved;
      }
    },
  );

  testWidgets(
    'restored acknowledged task alerts recheck only their captured profile and recover on resume',
    (tester) async {
      now = DateTime.now();
      var fixture = HealthAlertsFixture(preferences, repository: server);
      var session = fixture.owner.healthSession();
      await select(session, 'default');
      taskRows = [
        {
          'id': 'failed',
          'enabled': true,
          'state': 'scheduled',
          'last_error': 'Delivery failed',
          'schedule': {'kind': 'interval', 'minutes': 60},
        },
      ];
      await select(session, 'work');
      final issue = fixture.coordinator.alerts.singleWhere(
        (alert) => alert.title == 'Scheduled tasks',
      );
      await fixture.coordinator.acknowledge(issue);
      fixture.dispose();
      await session.saved;

      // An offline recovery read must retain the issue and its acknowledgement.
      tasksOffline = true;
      requests.clear();
      fixture = HealthAlertsFixture(preferences, repository: server);
      session = fixture.owner.healthSession();
      try {
        session.select(workspaces['default']!.gateway);
        await tester.pump();
        expect(session.health.profileName, 'default');
        final retained = fixture.coordinator.alerts.singleWhere(
          (alert) => alert.title == 'Scheduled tasks',
        );
        expect(retained.acknowledged, isTrue);
        expect(retained.lastKnown, isTrue);
        expect(retained.occurrence, issue.occurrence);
        expect(requests.where((r) => r.$2 == 'cron/jobs').map((r) => r.$3), [
          'work',
        ]);
        expect(
          requests.any(
            (r) => r.$2.startsWith('setup.') || r.$2.startsWith('ops/'),
          ),
          isFalse,
        );

        fixture.coordinator.setForeground(false);
        tasksOffline = false;
        taskRows.single['last_error'] = '';
        fixture.coordinator.setForeground(true);
        await tester.pump();
        expect(
          fixture.coordinator.alerts.where(
            (alert) => alert.title == 'Scheduled tasks',
          ),
          isEmpty,
        );
        expect(session.health.profileName, 'default');
        expect(requests.where((r) => r.$2 == 'cron/jobs').map((r) => r.$3), [
          'work',
          'work',
        ]);
        expect(
          requests.any(
            (r) => r.$2.startsWith('setup.') || r.$2.startsWith('ops/'),
          ),
          isFalse,
        );
      } finally {
        fixture.dispose();
        await session.saved;
      }
      fixture = HealthAlertsFixture(preferences, repository: server);
      try {
        expect(
          fixture.coordinator.alerts.where(
            (alert) => alert.title == 'Scheduled tasks',
          ),
          isEmpty,
        );
      } finally {
        fixture.dispose();
      }
    },
  );

  testWidgets(
    'connector retirement updates unopened snapshots across two restarts',
    (tester) async {
      now = DateTime.now();
      var fixture = HealthAlertsFixture(preferences, repository: server);
      var session = fixture.owner.healthSession();
      await select(session, 'default');
      connectorRows = [
        {
          'name': 'grokbot',
          'enabled': true,
          'transport': 'http',
          'auth': null,
          'source': 'config',
          'plugin': null,
        },
      ];
      await select(session, 'work');
      expect(
        fixture.coordinator.alerts.where(
          (a) => a.destination == 'MCP connectors',
        ),
        hasLength(1),
      );
      fixture.dispose();
      await session.saved;

      connectorRows = [];
      fixture = HealthAlertsFixture(preferences, repository: server);
      session = fixture.owner.healthSession();
      session.select(workspaces['default']!.gateway);
      await tester.pump();
      await session.saved;
      expect(
        fixture.coordinator.alerts.where(
          (a) => a.destination == 'MCP connectors',
        ),
        isEmpty,
      );
      expect(session.health.profileName, 'default');
      fixture.dispose();
      await session.saved;

      server.connectorInventory.invalidate('work');
      requests.clear();
      fixture = HealthAlertsFixture(preferences, repository: server);
      session = fixture.owner.healthSession();
      try {
        session.select(workspaces['work']!.gateway);
        await tester.pump();
        expect(
          fixture.coordinator.alerts.where(
            (a) => a.destination == 'MCP connectors',
          ),
          isEmpty,
        );
        expect(session.overviews['work']!.connectorChecks, isEmpty);
        expect(
          requests.where((request) => request.$3 != null),
          isEmpty,
          reason:
              'The saved observation must stay retired without another probe',
        );
      } finally {
        fixture.dispose();
        await session.saved;
      }
    },
  );

  testWidgets('failed task refresh keeps the saved observation after restart', (
    tester,
  ) async {
    var session = create();
    await select(session, 'default');
    final original = session.health.profileFindings.singleWhere(
      (f) => f.title == 'Scheduled tasks',
    );
    session.dispose();
    await session.saved;
    now = now.add(const Duration(hours: 25));
    tasksOffline = true;
    session = create();
    session.select(workspaces['default']?.gateway);
    await tester.pumpAndSettle();
    final retained = session.health.profileFindings.singleWhere(
      (f) => f.title == 'Scheduled tasks',
    );
    expect(retained.checkedAt, original.checkedAt);
    expect(retained.detail, contains(original.detail));
    expect(retained.detail, contains('Refresh unavailable'));
    session.dispose();
  });

  testWidgets(
    'changed connection identity does not restore another servers results',
    (tester) async {
      final session = create();
      completed(session, 'ops/doctor', now);
      await select(session, 'default');
      session.dispose();
      await session.saved;
      final other = AdministrationRepository(
        ownedMutation: (_, _, _, _, _, _) async =>
            throw StateError('Unexpected owned model mutation'),
        settingsWrite: (_, _, _, _) async =>
            throw StateError('Unexpected settings write'),
        connectionId: 'server',
        connectionIdentity: 'different-endpoint',
        connectionLabel: 'Server',
        request: server.request,
        gateway: server.gateway,
      );
      final fresh = AdministrationHealthSession(other, preferences);
      expect(fresh.health.diagnostics, isEmpty);
      expect(fresh.overviews, isEmpty);
      fresh.dispose();
      other.close();
    },
  );

  test('snapshot is valid JSON with distinct profile timestamps', () async {
    final session = create();
    await select(session, 'default');
    now = now.add(const Duration(hours: 1));
    await select(session, 'work');
    final key = preferences
        .getKeys()
        .where((k) => k.startsWith('health-results:'))
        .single;
    final json = jsonDecode(preferences.getString(key)!) as Map;
    expect(
      json['profiles']['default']['refreshedAt'],
      isNot(json['profiles']['work']['refreshedAt']),
    );
    session.dispose();
  });
  testWidgets('task counts and partial refresh times survive restart', (
    tester,
  ) async {
    taskRows = [
      for (final (id, enabled, state, error) in [
        ('new', true, 'scheduled', ''),
        ('paused', false, 'paused', ''),
        ('failed', false, 'disabled', 'Delivery failed'),
      ])
        {
          'id': id,
          'enabled': enabled,
          'state': state,
          'last_error': error,
          'schedule': {'kind': 'interval', 'minutes': 60},
        },
    ];
    var session = create();
    await select(session, 'default');
    expect(
      session.health.profileFindings
          .singleWhere((f) => f.title == 'Scheduled tasks')
          .detail,
      '3 tasks · 1 has a reported error',
    );
    expect(session.health.profileCheckIncomplete, isFalse);
    expect(session.checkedAt('default'), now);
    now = now.add(const Duration(minutes: 20));
    tasksOffline = true;
    await session.refresh(workspaces['default']!.gateway);
    expect(session.health.profileCheckIncomplete, isTrue);
    expect(session.checkedAt('default'), now);
    session.dispose();
    await session.saved;
    session = create();
    session.select(workspaces['default']?.gateway);
    await tester.pump();
    expect(session.health.profileCheckIncomplete, isTrue);
    expect(session.checkedAt('default'), now);
    expect(
      session.health.profileFindings
          .singleWhere((f) => f.title == 'Scheduled tasks')
          .detail,
      contains('3 tasks · 1 has a reported error'),
    );
    tasksOffline = false;
    taskRows.removeLast();
    await session.refresh(workspaces['default']!.gateway);
    expect(
      session.health.profileFindings
          .singleWhere((f) => f.title == 'Scheduled tasks')
          .detail,
      '2 tasks · No reported errors',
    );
    expect(session.health.profileCheckIncomplete, isFalse);
    session.dispose();
  });
}
