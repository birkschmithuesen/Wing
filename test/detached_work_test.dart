import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/detached_work.dart';
import 'package:wing/core/models/profile_live_activity.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/screens/workspace_overview_content.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:wing/core/services/workspace_recents_session.dart';
import 'package:wing/core/theme/wing_theme.dart';

import 'profile_connection_identity_test.dart'
    show MemoryIdentityStore, identityTestConnection;
import 'profile_notification_coverage_test.dart'
    show NotificationCoverageHost, row;
import 'support/form_family_capture.dart';

Map<String, dynamic> roster(String id, {int children = 1, int processes = 0}) =>
    {
      'sessions': [
        {'session_id': id, 'subagents': children, 'background': processes},
      ],
    };

Future<void> eventually(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFormFamilyFonts);
  late NotificationCoverageHost host;
  late SharedPreferences preferences;
  late AppPreferences appPreferences;
  late ProfileWorkspaceController owner;
  late List<ProfileNotification> alerts;
  var disposed = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    host = NotificationCoverageHost();
    alerts = [];
    disposed = false;
    owner = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'detached-work',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      onAttention: (notice) async => alerts.add(notice),
    );
    await owner.initialize();
    await owner.refreshActivity();
    host.connectProfiles.clear();
    host.rosterReads.clear();
  });

  tearDown(() {
    if (!disposed) owner.dispose();
    appPreferences.dispose();
  });

  for (final held in ['roster', 'metadata']) {
    for (final activeFails in [false, true]) {
      test(
        'held $held publishes other profiles and canonical activity, activeFails=$activeFails',
        () async {
          host.saved['b'] = [
            {'id': 'remote', 'profile': 'b', 'title': 'Other profile work'},
          ];
          host.rosters['a'] = roster('loaded');
          host.rosters['b'] = roster('remote');
          host.active = [row('outside-runtime', 'outside', 'working')];
          host.activeFails = activeFails;
          var canonicalPublished = false, otherProfilePublished = false;
          void observe() {
            canonicalPublished |= owner.liveActivity.any(
              (item) => item.runtimeId == 'outside-runtime',
            );
            otherProfilePublished |= owner.liveActivity.any(
              (item) =>
                  item.workspace.profileName == 'b' &&
                  item.sessionId == 'remote',
            );
          }

          owner.addListener(observe);
          addTearDown(() => owner.removeListener(observe));
          final gate = Completer<void>();
          if (held == 'roster') {
            host.rosterDelays['a'] = gate;
          } else {
            host.metadataDelays[('a', 'loaded')] = gate;
          }
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          final refresh = owner.refreshActivity();
          await eventually(
            () => owner.liveActivity.any(
              (item) =>
                  item.workspace.profileName == 'b' &&
                  item.sessionId == 'remote',
            ),
          );
          if (activeFails) {
            await eventually(
              () => owner.activityProfileErrors.containsKey('server'),
            );
          } else {
            await eventually(
              () => owner.liveActivity.any(
                (item) => item.runtimeId == 'outside-runtime',
              ),
            );
          }
          expect(owner.activityLoading, isTrue);
          expect(otherProfilePublished, isTrue);
          if (!activeFails) expect(canonicalPublished, isTrue);
          expect(gate.isCompleted, isFalse);

          // Passive event discovery and the cross-owner request poll also remain
          // available while the same coalesced roster refresh is outstanding.
          final before = host.activeReads;
          host.changed();
          await eventually(() => host.activeReads > before);
          if (!activeFails) {
            await eventually(
              () => owner.notificationMonitoringChats.any(
                (item) => item.key?.sessionId == 'outside',
              ),
            );
          }
          await owner
              .reconcileNotificationRequests({})
              .timeout(const Duration(seconds: 1));
          expect(
            owner.notificationMonitoringChats.any(
              (item) => item.key?.workspace.profileName == 'b',
            ),
            isTrue,
          );
          expect(gate.isCompleted, isFalse);
          gate.complete();
          await refresh;
          expect(owner.activityLoading, isFalse);
          expect(
            owner.liveActivity.any((item) => item.sessionId == 'loaded'),
            isTrue,
          );
          expect(host.resumeCalls, isEmpty);
          expect(alerts, isEmpty);
        },
      );
    }
  }

  test(
    'strict roster distinguishes empty, zero work and malformed snapshots',
    () {
      expect(DetachedWork.parseRoster({'sessions': []}), isEmpty);
      final running = DetachedWork.parseRoster(roster('stored', processes: 2));
      expect(running.single.sessionId, 'stored');
      expect(running.single.subagents, 1);
      expect(running.single.background, 2);
      expect(running.single.isRunning, isTrue);
      expect(
        DetachedWork.parseRoster(roster('idle', children: 0)).single.isRunning,
        isFalse,
      );
      for (final bad in <Map<String, dynamic>>[
        {},
        {'sessions': null},
        {
          'sessions': [null],
        },
        {
          'sessions': [
            {'session_id': 'x', 'subagents': 1},
          ],
        },
        roster('', children: 1),
        roster('x', children: -1),
        {
          'sessions': [
            {'session_id': 'x', 'subagents': 1.0, 'background': 0},
          ],
        },
        {
          'sessions': [
            {'session_id': 'x', 'subagents': 1, 'background': 0},
            {'session_id': 'x', 'subagents': 0, 'background': 1},
          ],
        },
      ]) {
        expect(() => DetachedWork.parseRoster(bad), throwsFormatException);
      }
    },
  );

  test(
    'detached discovery uses the source transport and exact target profiles',
    () async {
      host.saved['b'] = [
        {'id': 'outside', 'profile': 'b', 'title': 'Other profile work'},
      ];
      host.rosters['a'] = roster('outside');
      host.rosters['b'] = roster('outside', children: 0, processes: 2);
      await owner.refreshActivity();

      expect(host.rosterReads, [
        (source: 'a', profile: 'a'),
        (source: 'a', profile: 'b'),
      ]);
      expect(host.connectProfiles.toSet(), {'a'});
      expect(host.resumeCalls, isEmpty);
      expect(owner.notificationChats, isEmpty);
      expect(owner.liveActivity, hasLength(2));
      expect(
        owner.liveActivity.map((item) => item.runtimeId),
        everyElement(isNull),
      );
      expect(
        owner.liveActivity.map((item) => item.sideTasksRunning),
        everyElement(0),
      );
      expect(owner.browserRuntimeKeys.toSet(), hasLength(2));
      expect(owner.notificationMonitoringChats, hasLength(2));
      expect(owner.hasActiveChats, isTrue);
      expect(owner.hasRetentionObligations, isTrue);
      for (final notice in owner.notificationMonitoringChats) {
        expect(jsonDecode(notice.payload), notice.key!.toJson());
        expect(notice.key!.workspace.connectionIdentity, 'detached-work');
        expect(notice.key!.sessionId, 'outside');
      }
      expect(alerts, isEmpty);
    },
  );

  test(
    'roster presence survives active-list failure without claiming completion',
    () async {
      host.rosters['a'] = roster('outside');
      host.activeFails = true;
      await owner.refreshActivity();
      expect(owner.liveActivity.single.sessionId, 'outside');
      expect(owner.hasActiveChats, isTrue);
      host.rosters.clear();
      await owner.refreshActivity();
      expect(owner.liveActivity, isEmpty);
      expect(owner.hasActiveChats, isFalse);
      expect(alerts, isEmpty);
      expect(host.resumeCalls, isEmpty);
    },
  );

  test(
    'same stored identity stays isolated across connection owners',
    () async {
      final otherHost = NotificationCoverageHost();
      final other = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'another-endpoint',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: otherHost.gateway,
        onAttention: (notice) async => alerts.add(notice),
      );
      addTearDown(other.dispose);
      await other.initialize();
      await other.refreshActivity();
      host.rosters['a'] = roster('outside');
      otherHost.rosters['a'] = roster('outside');
      await Future.wait([owner.refreshActivity(), other.refreshActivity()]);
      final first = owner.notificationMonitoringChats.single.key!;
      final second = other.notificationMonitoringChats.single.key!;
      expect(first, isNot(second));
      expect(first.workspace.connectionId, second.workspace.connectionId);
      host.rosters.clear();
      await owner.refreshActivity();
      expect(owner.hasActiveChats, isFalse);
      expect(other.hasActiveChats, isTrue);
      expect(other.notificationMonitoringChats.single.key, second);
    },
  );

  test('concurrent observers share one roster refresh', () async {
    host.rosters['a'] = roster('outside');
    final gate = host.rosterDelay = Completer<void>();
    final first = owner.reconcileNotificationRequests({});
    final second = owner.reconcileNotificationRequests({});
    await eventually(() => host.rosterReads.length == 2);
    gate.complete();
    await Future.wait([first, second]);
    await eventually(() => owner.liveActivity.isNotEmpty);
    expect(host.rosterReads, hasLength(2));
    expect(owner.liveActivity.single.sessionId, 'outside');
  });

  test(
    'failed and malformed reads retain uncertainty; valid empty retires only its profile',
    () async {
      host.saved['b'] = [
        {'id': 'outside', 'title': 'B', 'profile': 'b'},
      ];
      host.rosters['a'] = roster('outside');
      host.rosters['b'] = roster('outside');
      await owner.refreshActivity();
      host.rosters['a'] = {'sessions': []};
      host.failedRosters.add('b');
      await owner.refreshActivity();
      expect(owner.liveActivity.single.workspace.profileName, 'b');
      expect(owner.notificationMonitoringChats.single.state, 'reconnecting');
      expect(owner.hasActiveChats, isTrue);
      host.failedRosters.clear();
      host.rosters['b'] = {
        'sessions': [null],
      };
      await owner.refreshActivity();
      expect(owner.notificationMonitoringChats.single.state, 'reconnecting');
      host.rosters['b'] = {'sessions': []};
      await owner.refreshActivity();
      expect(owner.hasActiveChats, isFalse);
      expect(owner.liveActivity, isEmpty);
      expect(owner.activityProfileErrors, isEmpty);
      expect(alerts, isEmpty);
    },
  );

  test(
    'metadata failure preserves verified work without borrowing another profile',
    () async {
      host.rosters['a'] = roster('outside');
      await owner.refreshActivity();
      host.rosters['b'] = roster('outside');
      host.failedMetadataProfiles.addAll(['a', 'b']);
      await owner.refreshActivity();
      expect(owner.liveActivity.single.workspace.profileName, 'a');
      expect(owner.notificationMonitoringChats.single.title, 'Outside task');
      expect(owner.notificationMonitoringChats.single.state, 'reconnecting');
      host.rosters.clear();
      await owner.refreshActivity();
      expect(owner.liveActivity, isEmpty);
      expect(owner.hasActiveChats, isFalse);
    },
  );

  test(
    'active-list overlap produces one row, preserving runtime identity and side-task count',
    () async {
      host.rosters['a'] = roster('outside', children: 3, processes: 2);
      host.active = [
        {
          ...row('outside-runtime', 'outside', 'working'),
          'side_tasks_running': 2,
        },
      ];
      await owner.refreshActivity();
      expect(owner.liveActivity, hasLength(1));
      expect(owner.liveActivity.single.runtimeId, 'outside-runtime');
      expect(owner.liveActivity.single.sideTasksRunning, 2);
      final reads = host.activeReads;
      host.changed();
      await eventually(() => host.activeReads > reads);
      await eventually(() => owner.notificationMonitoringChats.length == 1);
      expect(
        owner.notificationMonitoringChats.single.key!.sessionId,
        'outside',
      );
      expect(host.resumeCalls, isEmpty);
    },
  );

  test(
    'loaded idle parent remains editable while its detached work is monitored',
    () async {
      final chat = await owner.createChat(canDispatch: () => true);
      expect(chat.runtime.blocksTurnAdmission, isFalse);
      host.rosters['a'] = roster('loaded');
      await owner.refreshActivity();
      expect(owner.notificationMonitoringChats.single.key, chat.key);
      expect(
        owner.reportedActivityFor(chat.key),
        ProfileLiveActivityState.running,
      );
      expect(owner.hasActiveChats, isTrue);
      expect(chat.runtime.blocksTurnAdmission, isFalse);
      expect(chat.runtime.runtimeId, 'loaded-runtime');
      expect(host.resumeCalls, isEmpty);
    },
  );

  test(
    'removed catalog profiles retire presence without a completed answer',
    () async {
      host.saved['b'] = [
        {'id': 'outside', 'title': 'B', 'profile': 'b'},
      ];
      host.rosters['b'] = roster('outside');
      await owner.refreshActivity();
      host.profileNames.remove('b');
      await owner.refreshActivity();
      expect(owner.liveActivity, isEmpty);
      expect(owner.hasActiveChats, isFalse);
      expect(alerts, isEmpty);
    },
  );

  test(
    'disconnect invalidates an in-flight empty roster and retains work',
    () async {
      host.rosters['a'] = roster('outside');
      await owner.refreshActivity();
      host.rosters.clear();
      final gate = host.rosterDelay = Completer<void>();
      final before = host.rosterReads.length;
      final refresh = owner.refreshActivity();
      await eventually(() => host.rosterReads.length > before);
      host.connection(false);
      gate.complete();
      host.rosterDelay = null;
      await refresh;
      expect(owner.hasActiveChats, isTrue);
      expect(owner.notificationMonitoringChats.single.state, 'reconnecting');
      await owner.refreshActivity();
      expect(owner.hasActiveChats, isFalse);
    },
  );

  test('disposed owner cannot publish late roster observations', () async {
    host.rosters['a'] = roster('outside');
    final gate = host.rosterDelay = Completer<void>();
    final refresh = owner.refreshActivity();
    await eventually(() => host.rosterReads.isNotEmpty);
    owner.dispose();
    disposed = true;
    gate.complete();
    await refresh;
    expect(owner.liveActivity, isEmpty);
    expect(alerts, isEmpty);
  });

  test(
    'registry retains an obsolete detached owner until a successful empty read',
    () async {
      owner.dispose();
      disposed = true;
      final registry = ProfileWorkspaceRegistry(
        identities: ProfileConnectionIdentity(
          credentialStore: MemoryIdentityStore(),
        ),
        create: (connection, identity) => ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: connection,
            dashboardOAuth: null,
          ),
          connectionIdentity: identity,
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: host.gateway,
          onAttention: (notice) async => alerts.add(notice),
        ),
      );
      addTearDown(registry.dispose);
      final current = await registry.forConnection(identityTestConnection());
      await current.initialize();
      await current.refreshActivity();
      host.rosters['a'] = roster('outside');
      await current.refreshActivity();
      await registry.reconcileConnections([]);
      expect(registry.controllers, contains(current));
      expect(registry.hasActiveChats, isTrue);
      host.failedRosters.add('a');
      await current.refreshActivity();
      await Future<void>.delayed(Duration.zero);
      expect(registry.controllers, contains(current));
      host.failedRosters.clear();
      host.rosters.clear();
      await current.refreshActivity();
      await eventually(() => registry.controllers.isEmpty);
      expect(alerts, isEmpty);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Recents shows and opens detached work ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          host.saved['a']!.first.addAll({
            'source': 'desktop',
            'last_active': DateTime.now().millisecondsSinceEpoch / 1000,
          });
          host.history = [
            {
              'id': 1,
              'role': 'assistant',
              'content': 'Saved answer',
              'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
            },
          ];
          host.rosters['a'] = roster('outside', processes: 1);
          final bots = BotsSession((_) async => const []);
          final recents = WorkspaceRecentsSession(owner, bots);
          ProfileSessionKey? opened;
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            recents.dispose();
            bots.dispose();
          });
          await recents.refresh();
          expect(owner.recentsProfileErrors, isEmpty);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: formFamilyCapture, child: child!),
              ),
              home: Scaffold(
                body: WorkspaceActivityContent(
                  recents: recents,
                  onOpen: (chat, _) => opened = chat.key,
                  onOpenGroup: (_) async {},
                  visible: true,
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text('Outside task'), findsOneWidget);
          expect(find.text('Running'), findsOneWidget);
          await captureFormFamily(
            tester,
            'n20-detached-${brightness.name}-$scale',
          );
          await tester.tap(find.text('Outside task'));
          await tester.pump();
          expect(opened?.workspace.profileName, 'a');
          expect(opened?.workspace.connectionIdentity, 'detached-work');
          expect(opened?.sessionId, 'outside');
          expect(host.resumeCalls, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
