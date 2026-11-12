import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_notification_coverage_test.dart'
    show NotificationCoverageHost, row, waitForReads;

class _ReadingWriteProbe extends InMemorySharedPreferencesStore {
  _ReadingWriteProbe() : super.empty();

  final snapshots = <String>[];

  @override
  Future<bool> setValue(String type, String key, Object value) {
    if (key.contains('workspace_reading_v1_')) snapshots.add(value as String);
    return super.setValue(type, key, value);
  }
}

Future<void> _drainObservations() async {
  for (var i = 0; i < 100; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'unchanged background work refreshes presence without saving reading history',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _ReadingWriteProbe();
      SharedPreferencesStorePlatform.instance = store;
      final preferences = await SharedPreferences.getInstance();
      final settings = AppPreferences(preferences);
      addTearDown(settings.dispose);
      final host = NotificationCoverageHost();
      host.profileNames.addAll(['c', 'd', 'e', 'f', 'g']);
      host.history = [
        for (var i = 0; i < 60; i++)
          {
            'id': i,
            'role': i.isEven ? 'user' : 'assistant',
            'content': 'retained history $i ' * 200,
          },
      ];
      final notices = <ProfileNotification>[];
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'background-work-budget',
        preferences: preferences,
        appPreferences: settings,
        gatewayFactory: host.gateway,
        onAttention: (notice) async => notices.add(notice),
      );
      addTearDown(owner.dispose);
      await owner.initialize();
      final loaded = await owner.createChat(canDispatch: () => true);
      owner.setRouteVisibility(owner, false);
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await _drainObservations();
      // Flush legitimate startup/history dirtiness before observing only work.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      host.changed();
      await _drainObservations();
      expect(store.snapshots.last, contains('retained history'));
      final writes = store.snapshots.length;
      final metadata = host.metadataReads.length;
      final rosters = host.rosterReads.length;
      final active = host.activeReads;
      for (var i = 0; i < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        host.changed();
        await _drainObservations();
      }
      expect(host.activeReads - active, 2);
      expect(
        host.rosterReads.length - rosters,
        14,
        reason: 'Every profile must still discover newly detached work.',
      );
      expect(
        host.metadataReads.length - metadata,
        2,
        reason:
            'Verified unchanged work reads its exact owner, not all profiles.',
      );
      expect(
        store.snapshots.length,
        writes,
        reason: 'Presence updates must not encode and save unchanged history.',
      );
      expect(owner.hasActiveChats, isTrue);
      expect(notices, isEmpty);
      host.history = [
        {'id': 100, 'role': 'assistant', 'content': 'A changed saved answer'},
      ];
      await owner.refreshHistory(loaded);
      await _drainObservations();
      expect(store.snapshots.length, greaterThan(writes));
      expect(store.snapshots.last, contains('A changed saved answer'));
      host.active = [];
      host.changed();
      await _drainObservations();
      expect(owner.hasActiveChats, isFalse);
    },
  );

  test(
    'working owner reuse still revalidates completion and uncertainty',
    () async {
      SharedPreferences.setMockInitialValues({});
      final host = NotificationCoverageHost();
      final preferences = await SharedPreferences.getInstance();
      final settings = AppPreferences(preferences);
      addTearDown(settings.dispose);
      final notices = <ProfileNotification>[];
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'working-owner-budget',
        preferences: preferences,
        appPreferences: settings,
        gatewayFactory: host.gateway,
        onAttention: (notice) async => notices.add(notice),
      );
      addTearDown(owner.dispose);
      await owner.initialize();
      host.active = [row('outside-runtime', 'outside', 'working')];
      Future<List<({String profile, String session})>> observe() async {
        final before = host.metadataReads.length;
        host.changed();
        await _drainObservations();
        return host.metadataReads.skip(before).toList();
      }

      expect((await observe()).map((r) => r.profile), ['a', 'b']);
      host.saved['a']!.first['title'] = 'Renamed active work';
      expect((await observe()).map((r) => r.profile), ['a']);
      expect(
        owner.notificationMonitoringChats.single.title,
        'Renamed active work',
      );
      host.failedMetadataProfiles.add('a');
      await observe();
      expect(owner.hasActiveChats, isTrue);
      expect(owner.notificationMonitoringChats.single.state, 'reconnecting');
      host.failedMetadataProfiles.clear();
      expect((await observe()).map((r) => r.profile), ['a', 'b']);
      host.active = [row('outside-runtime', 'outside', 'idle')];
      host.saved['b'] = [
        {'id': 'outside', 'profile': 'b', 'title': 'Collision'},
      ];
      expect((await observe()).map((r) => r.profile), ['a', 'b']);
      expect(notices, isEmpty, reason: 'An ambiguous completion cannot alert.');
      expect(owner.hasActiveChats, isTrue);
      host.saved['b'] = [];
      host.history = [
        {'id': 90, 'role': 'assistant', 'content': 'Verified answer'},
      ];
      await observe();
      expect(notices.single.content.preview, 'Verified answer');
      expect(owner.hasActiveChats, isFalse);
    },
  );

  test(
    'initializing unopened chats never starts work monitoring or reply alerts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final host = NotificationCoverageHost();
      host.saved['a'] = [
        for (var i = 0; i < 12; i++) {'id': 'chat-$i', 'profile': 'a'},
      ];
      final notices = <ProfileNotification>[];
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'initializing-chats',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (notice) async => notices.add(notice),
      );
      addTearDown(owner.dispose);
      await owner.initialize();
      final loaded = await owner.createChat(canDispatch: () => true);
      final resumeCount = host.resumeCalls.length;
      for (final status in ['starting', 'idle']) {
        final reads = host.activeReads;
        host.active = [
          for (var i = 0; i < 12; i++) row('runtime-$i', 'chat-$i', status),
          row(loaded.runtime.runtimeId, loaded.key.sessionId, status),
        ];
        host.changed();
        await waitForReads(host, reads + 1);
        expect(
          owner.hasActiveChats,
          isFalse,
          reason: 'Agent initialization is not user work',
        );
        expect(owner.notificationMonitoringChats, isEmpty);
        expect(notices, isEmpty);
        expect(
          host.resumeCalls,
          hasLength(resumeCount),
          reason: 'Initializing an idle loaded chat must not attach it as work',
        );
      }
    },
  );

  for (final scenario in ['removed', 'replacement', 'metadata-failure']) {
    test(
      'retired runtime stops monitoring without inventing a reply ($scenario)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final host = NotificationCoverageHost();
        final notices = <ProfileNotification>[];
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final owner = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: identityTestConnection(),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'retired-runtime',
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: host.gateway,
          onAttention: (notice) async => notices.add(notice),
        );
        addTearDown(owner.dispose);
        await owner.initialize();
        Future<void> observe() async {
          final reads = host.activeReads;
          host.changed();
          await waitForReads(host, reads + 1);
        }

        host.active = [row('old-runtime', 'outside', 'working')];
        await observe();
        expect(owner.hasActiveChats, isTrue);
        owner.networkUnavailable();
        host.active = switch (scenario) {
          'replacement' => [row('new-runtime', 'outside', 'idle')],
          'metadata-failure' => [row('other-runtime', 'loaded', 'working')],
          _ => [],
        };
        if (scenario == 'metadata-failure') {
          host.failedMetadataProfiles.add('b');
        }
        await observe();
        expect(
          owner.hasActiveChats,
          isFalse,
          reason:
              'A successful complete live list no longer contains the watched runtime',
        );
        expect(owner.notificationMonitoringChats, isEmpty);
        expect(
          notices,
          isEmpty,
          reason: 'Runtime retirement does not establish a completed answer',
        );
      },
    );
  }

  for (final scenario in [
    'normal',
    'disconnect',
    'failed-read',
    'network-resume',
  ]) {
    test('unopened working chat recovered answer after $scenario', () async {
      SharedPreferences.setMockInitialValues({});
      final host = NotificationCoverageHost();
      final notices = <ProfileNotification>[];
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'outage-investigation',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (notice) async => notices.add(notice),
      );
      addTearDown(owner.dispose);
      await owner.initialize();
      final initialReads = host.activeReads;
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await waitForReads(host, initialReads + 1);
      expect(owner.hasActiveChats, isTrue);
      if (scenario == 'disconnect' || scenario == 'network-resume') {
        owner.networkUnavailable();
        expect(owner.notificationMonitoringChats.toList(), [
          (
            key: ProfileSessionKey(owner.current!.scope, 'outside'),
            payload: jsonEncode(
              ProfileSessionKey(owner.current!.scope, 'outside').toJson(),
            ),
            title: 'Outside task',
            state: 'reconnecting',
          ),
        ]);
        expect(
          owner.hasActiveChats,
          isTrue,
          reason: 'Connectivity loss is not task completion',
        );
      }
      if (scenario == 'failed-read') {
        host.activeFails = true;
        host.changed();
        await waitForReads(host, initialReads + 2);
        expect(owner.hasActiveChats, isTrue);
        host.activeFails = false;
      }
      host.history = [
        {
          'id': 42,
          'role': 'assistant',
          'content':
              'WING-RECOVERY-2332: Reconnected successfully. The latest answer is ready to read.',
        },
      ];
      host.active = [row('outside-runtime', 'outside', 'idle', 2)];
      if (scenario == 'network-resume') {
        await owner.resumeConnection(networkChanged: true);
      } else {
        host.changed();
        await waitForReads(
          host,
          initialReads + (scenario == 'failed-read' ? 3 : 2),
        );
      }
      // Delivery is intentionally retained until the async notification sink
      // acknowledges it, including when public reconnect itself has returned.
      await Future<void>.delayed(Duration.zero);
      expect(
        notices.map((n) => n.content.preview),
        [host.history.single['content']],
        reason:
            'A known working chat must reconcile its actual answer after the outage',
      );
      expect(owner.hasActiveChats, isFalse);
      host.changed();
      await waitForReads(host, host.activeReads + 1);
      expect(notices, hasLength(1), reason: 'Recovery alerts only once');
    });
  }

  for (final uncertain in [
    'unknown',
    'starting',
    'malformed',
    'duplicate-runtime',
    'ambiguous-owner',
    'history-failure',
  ]) {
    test(
      'retains verified work through $uncertain until exact recovery',
      () async {
        SharedPreferences.setMockInitialValues({});
        final host = NotificationCoverageHost();
        final notices = <ProfileNotification>[];
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final owner = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: identityTestConnection(),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'outage-safeguard',
          preferences: preferences,
          appPreferences: appPreferences,
          gatewayFactory: host.gateway,
          onAttention: (notice) async => notices.add(notice),
        );
        addTearDown(owner.dispose);
        await owner.initialize();
        Future<void> observe() async {
          final reads = host.activeReads;
          host.changed();
          await waitForReads(host, reads + 1);
        }

        host.active = [row('outside-runtime', 'outside', 'working')];
        await observe();
        owner.networkUnavailable();
        host.history = [
          {'id': 77, 'role': 'assistant', 'content': 'Recovered exact answer'},
        ];
        host.active = switch (uncertain) {
          'unknown' => [row('outside-runtime', 'outside', 'unknown')],
          'starting' => [row('outside-runtime', 'outside', 'starting')],
          'malformed' => [{}],
          'duplicate-runtime' => [
            row('outside-runtime', 'outside', 'idle'),
            row('outside-runtime', 'loaded', 'idle'),
          ],
          _ => [row('outside-runtime', 'outside', 'idle')],
        };
        if (uncertain == 'ambiguous-owner') {
          host.saved['b'] = [
            {'id': 'outside', 'title': 'Collision', 'profile': 'b'},
          ];
        }
        host.historyFails = uncertain == 'history-failure';
        await observe();
        expect(notices, isEmpty);
        expect(owner.hasActiveChats, isTrue);
        expect(owner.notificationMonitoringChats.toList(), [
          (
            key: ProfileSessionKey(owner.current!.scope, 'outside'),
            payload: jsonEncode(
              ProfileSessionKey(owner.current!.scope, 'outside').toJson(),
            ),
            title: 'Outside task',
            state: 'reconnecting',
          ),
        ]);
        host.saved['b'] = [];
        host.historyFails = false;
        host.active = [row('outside-runtime', 'outside', 'idle')];
        await observe();
        expect(notices.single.content.preview, 'Recovered exact answer');
        expect(notices.single.focus?.messageId, 77);
        expect(owner.hasActiveChats, isFalse);
      },
    );
  }

  test(
    'monitoring outlives delayed answer fetch and notification acknowledgement',
    () async {
      SharedPreferences.setMockInitialValues({});
      final host = NotificationCoverageHost();
      final notices = <ProfileNotification>[];
      final delivered = Completer<void>();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'outage-delivery',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (notice) async {
          notices.add(notice);
          await delivered.future;
        },
      );
      addTearDown(owner.dispose);
      await owner.initialize();
      var reads = host.activeReads;
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await waitForReads(host, reads + 1);
      owner.networkUnavailable();
      host.history = [
        {'id': 9, 'role': 'assistant', 'content': 'Ready'},
      ];
      host.historyDelay = Completer<void>();
      host.active = [row('outside-runtime', 'outside', 'idle')];
      reads = host.activeReads;
      host.changed();
      await waitForReads(host, reads + 1);
      expect(owner.hasActiveChats, isTrue);
      expect(notices, isEmpty);
      host.historyDelay!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(notices.single.content.preview, 'Ready');
      expect(
        owner.hasActiveChats,
        isTrue,
        reason: 'Notification is still being posted',
      );
      delivered.complete();
      await Future<void>.delayed(Duration.zero);
      expect(owner.hasActiveChats, isFalse);
    },
  );

  test(
    'cold idle answers stay silent after disconnect and failed discovery',
    () async {
      SharedPreferences.setMockInitialValues({});
      final host = NotificationCoverageHost();
      final notices = <ProfileNotification>[];
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'cold-idle',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (notice) async => notices.add(notice),
      );
      addTearDown(owner.dispose);
      await owner.initialize();
      owner.networkUnavailable();
      host.activeFails = true;
      var reads = host.activeReads;
      host.changed();
      await waitForReads(host, reads + 1);
      host.activeFails = false;
      host.active = [row('outside-runtime', 'outside', 'idle')];
      host.history = [
        {'id': 1, 'role': 'assistant', 'content': 'Old answer'},
      ];
      reads = host.activeReads;
      host.changed();
      await waitForReads(host, reads + 1);
      expect(notices, isEmpty);
      expect(owner.hasActiveChats, isFalse);
    },
  );
}
