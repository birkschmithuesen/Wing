import 'support/composer_fixture.dart' show stockChatReply;
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:wing/core/services/background_monitoring_service.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/ws_client.dart';

import 'profile_connection_identity_test.dart'
    show MemoryIdentityStore, identityTestConnection;
import 'profile_notification_coverage_test.dart'
    show NotificationCoverageHost, row, waitForReads;
import 'profile_workspace_controller_test.dart' show Host;
import 'support/bots_fixture.dart';

BotRecord monitoringBot(
  ProfileSessionKey root, {
  String title = 'Research bot',
  ProfileSessionKey? tip,
}) => BotRecord(
  scope: root.workspace,
  instance: 'Test server',
  profile: HermesProfile(name: root.workspace.profileName),
  title: title,
  shape: 'circle',
  color: '#123456',
  pinned: false,
  hidden: false,
  hasAvatar: false,
  revision: 1,
  metadata: const {},
  chat: root,
  resolvedChat: tip,
);

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late AppPreferences appPreferences;
  late ProfileWorkspaceRegistry registry;
  late Map<String, Host> hosts;
  late List<bool> transitions;
  late List<ProfileNotification> delivered;
  Completer<void>? notificationGate;
  var notificationStarted = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    hosts = {};
    transitions = [];
    delivered = [];
    notificationGate = null;
    notificationStarted = false;
    registry = ProfileWorkspaceRegistry(
      identities: ProfileConnectionIdentity(
        credentialStore: MemoryIdentityStore(),
      ),
      create: (connection, identity) => ProfileWorkspaceController(
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        connectionIdentity: identity,
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: (hosts[identity] = Host()).gateway,
        onAttention: (notification) async {
          notificationStarted = true;
          await notificationGate?.future;
          delivered.add(notification);
        },
      ),
    );
    registry.addListener(() {
      if (transitions.lastOrNull != registry.hasActiveChats &&
          (transitions.isNotEmpty || registry.hasActiveChats)) {
        transitions.add(registry.hasActiveChats);
      }
    });
  });

  tearDown(() {
    registry.dispose();
    appPreferences.dispose();
  });

  test(
    'many unnamed reconnecting chats have a bounded identifiable summary',
    () async {
      final host = NotificationCoverageHost();
      String sessionId(int index) =>
          '20261101_120000_${index.toString().padLeft(8, '0')}';
      host.saved['a'] = [
        for (var i = 0; i < 12; i++) {'id': sessionId(i), 'profile': 'a'},
      ];
      final watch = ProfileWorkspaceRegistry(
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
          onAttention: (_) async {},
        ),
      );
      addTearDown(watch.dispose);
      final owner = await watch.forConnection(identityTestConnection());
      await owner.initialize();
      final reads = host.activeReads;
      host.active = [
        for (var i = 0; i < 12; i++) row('runtime-$i', sessionId(i), 'working'),
      ];
      host.changed();
      await waitForReads(host, reads + 1);
      owner.networkUnavailable();
      final summary = watch.monitoringSummary;
      expect(summary['text']!.split('\n'), hasLength(4));
      expect(
        summary['text'],
        'Hermes session · 00000000 · reconnecting\n'
        'Hermes session · 00000001 · reconnecting\n'
        'Hermes session · 00000002 · reconnecting\n'
        '9 more chats',
      );
      expect(summary['payload'], isEmpty);
      expect(owner.notificationMonitoringChats, hasLength(12));
      expect(
        owner.notificationMonitoringChats.map((chat) => chat.key).toSet(),
        hasLength(12),
      );
      expect(watch.hasActiveChats, isTrue);

      host.history = [
        {'id': 1, 'role': 'assistant', 'content': 'Finished'},
      ];
      for (final remaining in [4, 1, 0]) {
        final reads = host.activeReads;
        host.active = [
          for (var i = 0; i < 12; i++)
            row('runtime-$i', sessionId(i), i < remaining ? 'working' : 'idle'),
        ];
        host.changed();
        await waitForReads(host, reads + 1);
        expect(owner.notificationMonitoringChats, hasLength(remaining));
        final recovered = watch.monitoringSummary;
        if (remaining == 4) {
          expect(recovered['text']!.split('\n').last, '1 more chat');
          expect(recovered['payload'], isEmpty);
        } else if (remaining == 1) {
          expect(recovered['text'], 'Hermes session · 00000000 · working');
          expect(
            jsonDecode(recovered['payload']!),
            owner.notificationMonitoringChats.single.key!.toJson(),
          );
        } else {
          expect(recovered['text'], isEmpty);
          await until(() => !watch.hasActiveChats);
        }
      }
    },
  );

  test('shared discussion retains monitoring across idle bot turns', () async {
    final host = NotificationCoverageHost();
    host.groups = [
      {'room_id': 'discussion', 'name': 'Shared discussion'},
    ];
    host.groupStates['discussion'] = {
      'room': {
        'room_id': 'discussion',
        'name': 'Shared discussion',
        'latest_seq': 0,
      },
      'driver_status': {
        'working': true,
        'blocked': false,
        'pending_actions': [],
      },
    };
    final owner = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'discussion-monitoring',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      onAttention: (_) async {},
    );
    addTearDown(owner.dispose);
    await owner.initialize();
    expect(host.active, isEmpty);
    expect(
      owner.hasActiveChats,
      isTrue,
      reason: 'The shared room is working even when every bot session is idle',
    );
    expect(owner.notificationMonitoringChats.single.title, 'Shared discussion');
    expect(jsonDecode(owner.notificationMonitoringChats.single.payload), {
      'connection': owner.connection.id,
      'connection_identity': owner.connectionIdentity,
      'room': 'discussion',
    });
  });

  for (final profile in ['a', 'b']) {
    test(
      'human send in hidden Bot Chat starts monitoring in $profile',
      () async {
        final host = NotificationCoverageHost();
        final botRegistry = ProfileWorkspaceRegistry(
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
            onAttention: (notice) async => delivered.add(notice),
          ),
        );
        addTearDown(botRegistry.dispose);
        final owner = await botRegistry.forConnection(identityTestConnection());
        host.saved[profile] = [
          {
            'id': 'outside',
            'title': 'Bot Chat',
            'source': 'desktop',
            'hidden': true,
            'profile': profile,
          },
        ];
        await owner.initialize();
        final chat = (await owner.openSession(
          ProfileSessionKey(
            WorkspaceScope(
              connectionId: owner.connection.id,
              connectionIdentity: owner.connectionIdentity,
              profileName: profile,
            ),
            'outside',
          ),
        ))!;
        expect(botRegistry.hasActiveChats, isFalse);
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(BackgroundMonitoringService.channel, (
              call,
            ) async {
              calls.add(call);
              return call.method == 'start'
                  ? {'running': true, 'batteryUnrestricted': true}
                  : null;
            });
        final service = BackgroundMonitoringService(
          preferences: appPreferences,
          supported: true,
          hasActiveChats: () => botRegistry.hasActiveChats,
          summary: () => botRegistry.monitoringSummary,
          notificationsEnabled: () async => true,
        );
        void changed() => unawaited(service.sync());
        botRegistry.addListener(changed);
        addTearDown(() async {
          botRegistry.removeListener(changed);
          service.dispose();
          await service.sync();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                BackgroundMonitoringService.channel,
                null,
              );
        });
        chat.composer.editText('Please investigate this task');
        await owner.send(chat);
        await service.sync();
        expect(service.state.value, BackgroundMonitoringState.active);
        expect(calls.last.method, 'start');
        expect(calls.last.arguments['text'], '$profile · working');
        final otherProfile = ProfileSessionKey(
          WorkspaceScope(
            connectionId: owner.connection.id,
            connectionIdentity: owner.connectionIdentity,
            profileName: profile == 'a' ? 'b' : 'a',
          ),
          chat.key.sessionId,
        );
        botRegistry.observeMonitoringBotIdentity(
          otherProfile.workspace,
          monitoringBot(otherProfile, title: 'Other profile bot'),
        );
        final otherInstance = ProfileSessionKey(
          WorkspaceScope(
            connectionId: owner.connection.id,
            connectionIdentity: 'another-server',
            profileName: profile,
          ),
          chat.key.sessionId,
        );
        botRegistry.observeMonitoringBotIdentity(
          otherInstance.workspace,
          monitoringBot(otherInstance, title: 'Other instance bot'),
        );
        expect(botRegistry.monitoringSummary['text'], '$profile · working');
        final root = ProfileSessionKey(chat.key.workspace, 'canonical-root');
        botRegistry.observeMonitoringBotIdentity(
          chat.key.workspace,
          monitoringBot(root, tip: chat.key),
        );
        await service.sync();
        expect(calls.last.arguments['text'], 'Research bot · working');
        botRegistry.observeMonitoringBotIdentity(
          chat.key.workspace,
          monitoringBot(root, title: 'Renamed bot', tip: chat.key),
        );
        await service.sync();
        expect(calls.last.arguments['text'], 'Renamed bot · working');
        botRegistry.observeMonitoringBotIdentity(
          chat.key.workspace,
          monitoringBot(root, title: 'Replacement bot'),
        );
        await service.sync();
        expect(calls.last.arguments['text'], '$profile · working');
        botRegistry.observeMonitoringBotIdentity(chat.key.workspace, null);
        expect(botRegistry.monitoringSummary['text'], '$profile · working');
        owner.current!.gateway.onEvent!(
          StreamEvent(
            type: 'message.complete',
            sessionId: chat.runtime.runtimeId,
            data: const {'text': 'Done'},
          ),
        );
        await until(() => !botRegistry.hasActiveChats);
        await service.sync();
        expect(service.state.value, BackgroundMonitoringState.idle);
        expect(calls.last.method, 'stop');
      },
    );
  }

  test(
    'Bots reads publish names, renames and removed profile identities',
    () async {
      final fixture = BotsFixture();
      final observed = <WorkspaceScope, BotRecord>{};
      final bots = BotsSession(
        (_) async => [fixture.repository],
        onIdentityChanged: (scope, bot) {
          if (bot == null) {
            observed.remove(scope);
          } else {
            observed[scope] = bot;
          }
        },
      );
      addTearDown(bots.dispose);
      await bots.refresh();
      final atlas = observed.values.singleWhere(
        (bot) => bot.profile.name == 'atlas',
      );
      expect(atlas.title, 'Atlas');
      fixture.profiles.first['ui_meta']['hermes-bots']['title'] =
          'Renamed Atlas';
      bots.invalidateAppearances();
      await bots.identitiesForProfiles([atlas.scope], canRead: () => true);
      expect(observed[atlas.scope]!.title, 'Renamed Atlas');
      fixture.profiles.removeAt(0);
      bots.invalidateAppearances();
      await bots.identitiesForProfiles([atlas.scope], canRead: () => true);
      expect(observed.containsKey(atlas.scope), isFalse);
    },
  );

  test('group work starts the service and releases it when idle', () async {
    final host = NotificationCoverageHost();
    host.groups = [
      {'room_id': 'discussion', 'name': 'Shared discussion'},
    ];
    void groupState(bool working) {
      host.groupStates['discussion'] = {
        'room': {
          'room_id': 'discussion',
          'name': 'Shared discussion',
          'latest_seq': 0,
        },
        'driver_status': {'working': working, 'blocked': false},
      };
    }

    groupState(false);
    host.saved['a']!.first.addAll({
      'source': 'bot_room',
      'title': 'Group: private-room-id',
      'hidden': true,
    });
    final groupRegistry = ProfileWorkspaceRegistry(
      identities: ProfileConnectionIdentity(
        credentialStore: MemoryIdentityStore(),
      ),
      create: (connection, identity) => ProfileWorkspaceController(
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        connectionIdentity: identity,
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (notice) async => delivered.add(notice),
      ),
    );
    addTearDown(groupRegistry.dispose);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BackgroundMonitoringService.channel, (
          call,
        ) async {
          calls.add(call);
          return call.method == 'start'
              ? {'running': true, 'batteryUnrestricted': true}
              : null;
        });
    final service = BackgroundMonitoringService(
      preferences: appPreferences,
      supported: true,
      hasActiveChats: () => groupRegistry.hasActiveChats,
      summary: () => groupRegistry.monitoringSummary,
      notificationsEnabled: () async => true,
    );
    void changed() => unawaited(service.sync());
    groupRegistry.addListener(changed);
    addTearDown(() async {
      groupRegistry.removeListener(changed);
      service.dispose();
      await service.sync();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BackgroundMonitoringService.channel, null);
    });
    final owner = await groupRegistry.forConnection(identityTestConnection());
    await owner.initialize();
    await service.sync();
    expect(service.state.value, BackgroundMonitoringState.idle);

    var reads = host.activeReads;
    groupState(true);
    host.active = [row('outside-runtime', 'outside', 'idle')];
    host.changed();
    await waitForReads(host, ++reads);
    await owner.refreshGroupNotifications();
    await service.sync();
    expect(service.state.value, BackgroundMonitoringState.active);
    expect(calls.last.method, 'start');
    expect(calls.last.arguments['text'], 'Shared discussion · working');
    expect(jsonDecode(calls.last.arguments['payload'] as String), {
      'connection': owner.connection.id,
      'connection_identity': owner.connectionIdentity,
      'room': 'discussion',
    });

    host.groupFails = true;
    host.changed();
    await waitForReads(host, ++reads);
    await owner.refreshGroupNotifications();
    await service.sync();
    expect(service.state.value, BackgroundMonitoringState.active);
    expect(calls.last.arguments['text'], 'Shared discussion · reconnecting');

    host.groupFails = false;
    groupState(false);
    host.active = [row('outside-runtime', 'outside', 'working')];
    host.changed();
    await waitForReads(host, ++reads);
    await owner.refreshGroupNotifications();
    await service.sync();
    expect(service.state.value, BackgroundMonitoringState.idle);
    expect(host.resumeCalls, isEmpty);

    groupState(true);
    host.active = [row('outside-runtime', 'outside', 'idle')];
    host.changed();
    await waitForReads(host, ++reads);
    await owner.refreshGroupNotifications();
    await service.sync();
    expect(service.state.value, BackgroundMonitoringState.active);

    groupState(false);
    host.historyFails = true;
    host.active = [row('outside-runtime', 'outside', 'idle')];
    host.changed();
    await waitForReads(host, ++reads);
    await owner.refreshGroupNotifications();
    await service.sync();
    expect(service.state.value, BackgroundMonitoringState.idle);
    expect(calls.last.method, 'stop');
    expect(delivered, isEmpty);
    expect(groupRegistry.monitoringSummary['text'], isEmpty);
  });

  test(
    'idle chats stay off; all connections share the working-chat lifetime',
    () async {
      final first = await registry.forConnection(identityTestConnection());
      final second = await registry.forConnection(
        identityTestConnection().copyWith(host: 'second-host'),
      );
      await first.initialize();
      await second.initialize();
      final one = await first.createChat(canDispatch: () => true);
      final two = await second.createChat(canDispatch: () => true);
      expect(registry.hasActiveChats, isFalse);
      expect(transitions, isEmpty);
      expect(registry.monitoringSummary['text'], isEmpty);

      one.composer.editText('First task');
      await first.send(one);
      expect(
        jsonDecode(registry.monitoringSummary['payload']!),
        one.key.toJson(),
      );
      two.composer.editText('Second task');
      await second.send(two);
      expect(
        registry.monitoringSummary['payload'],
        '',
        reason: 'Multiple chats open Recents',
      );
      expect(transitions, [true]);
      expect(
        registry.monitoringSummary['text'],
        'First task · working\nSecond task · working',
      );

      hosts[first.connectionIdentity]!.event('a', 'clarify', {
        'request_id': 'question',
        'question': 'Continue?',
      });
      await until(() => delivered.length == 1);
      expect(registry.hasActiveChats, isTrue);
      expect(
        registry.monitoringSummary['text'],
        'First task · needs input\nSecond task · working',
      );

      hosts[second.connectionIdentity]!.event('a', 'message.complete', {
        'text': 'Done',
      });
      await until(() => !registry.hasActiveChats);
      expect(one.runtime.needsInput, isTrue);
      expect(transitions, [true, false]);
      expect(registry.monitoringSummary['text'], 'First task · needs input');
      expect(
        jsonDecode(registry.monitoringSummary['payload']!),
        one.key.toJson(),
      );

      await first.clarify(one, 'Yes');
      expect(registry.hasActiveChats, isTrue);
      hosts[first.connectionIdentity]!.event('a', 'message.complete', {
        'text': 'Done',
      });
      await until(() => !registry.hasActiveChats);
      expect(transitions, [true, false, true, false]);
    },
  );

  test('last question is posted before monitoring becomes idle', () async {
    final owner = await registry.forConnection(identityTestConnection());
    await owner.initialize();
    final chat = await owner.createChat(canDispatch: () => true);
    chat.composer.editText('Start');
    await owner.send(chat);
    notificationGate = Completer<void>();
    hosts[owner.connectionIdentity]!.event('a', 'clarify', {
      'request_id': 'question',
      'question': 'Continue?',
    });
    await until(() => notificationStarted);
    expect(chat.runtime.needsInput, isTrue);
    expect(registry.hasActiveChats, isTrue);
    expect(delivered, isEmpty);
    notificationGate!.complete();
    await until(() => !registry.hasActiveChats);
    expect(delivered.single.content.needsAttention, isTrue);
    expect(chat.runtime.pendingQuestion?.question, 'Continue?');

    // A disconnected waiting chat must not restart monitoring by itself.
    hosts[owner.connectionIdentity]!.gateways['a']!.onConnectionChanged!(false);
    expect(registry.hasActiveChats, isFalse);
  });

  test(
    'final reply retains monitoring until posting finishes or fails',
    () async {
      final owner = await registry.forConnection(identityTestConnection());
      await owner.initialize();
      final chat = await owner.createChat(canDispatch: () => true);
      chat.composer.editText('Start');
      await owner.send(chat);
      notificationGate = Completer<void>();
      hosts[owner.connectionIdentity]!.event('a', 'message.complete', {
        'text': 'Done',
      });
      await until(() => notificationStarted);
      expect(registry.hasActiveChats, isTrue);
      notificationGate!.completeError(StateError('Posting unavailable'));
      await until(() => !registry.hasActiveChats);
      expect(chat.runtime.execution, ChatExecution.completed);
    },
  );

  test(
    'desktop work on an already loaded idle chat starts monitoring',
    () async {
      final host = NotificationCoverageHost();
      final replies = <ProfileNotification>[];
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'desktop-loaded-activity',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (notice) async => replies.add(notice),
      );
      addTearDown(owner.dispose);
      await owner.initialize();
      final chat = await owner.createChat(canDispatch: () => true);
      expect(owner.hasActiveChats, isFalse);
      final reads = host.activeReads;
      host.workingProfiles.add('a');
      host.active = [
        row(chat.runtime.runtimeId, chat.key.sessionId, 'working'),
      ];
      host.changed();
      await waitForReads(host, reads + 1);
      await until(() => owner.hasActiveChats);
      expect(host.resumeCalls.single['display_projection'], isTrue);
      expect(chat.runtime.execution, ChatExecution.running);
      host.changed();
      await waitForReads(host, reads + 2);
      expect(
        host.resumeCalls,
        hasLength(1),
        reason: 'Do not reattach a running chat on every snapshot',
      );
      host.gateways['a']!.onEvent!(
        StreamEvent(
          type: 'message.complete',
          sessionId: chat.runtime.runtimeId,
          data: const {'text': 'WING-LIVE-4: Replacement after reconnect'},
        ),
      );
      await until(() => replies.isNotEmpty && !owner.hasActiveChats);
      expect(
        replies.single.content.preview,
        'WING-LIVE-4: Replacement after reconnect',
      );
    },
  );

  test('live completion overtakes a delayed desktop reattachment', () async {
    final host = NotificationCoverageHost();
    final replies = <ProfileNotification>[];
    final owner = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'desktop-reattach-race',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      onAttention: (notice) async => replies.add(notice),
    );
    addTearDown(owner.dispose);
    await owner.initialize();
    final chat = await owner.createChat(canDispatch: () => true);
    host.workingProfiles.add('a');
    host.resumeDelay = Completer<void>();
    host.active = [row(chat.runtime.runtimeId, chat.key.sessionId, 'working')];
    host.changed();
    await until(() => host.resumeCalls.isNotEmpty);
    for (final type in ['message.start', 'message.complete']) {
      host.gateways['a']!.onEvent!(
        StreamEvent(
          type: type,
          sessionId: chat.runtime.runtimeId,
          data: stockChatReply(host.gateways['a']!, type, {
            'text': 'Finished while reconnecting',
          }),
        ),
      );
    }
    await until(
      () =>
          chat.runtime.execution == ChatExecution.completed &&
          replies.isNotEmpty,
    );
    host.resumeDelay!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(chat.runtime.execution, ChatExecution.completed);
    expect(owner.hasActiveChats, isFalse);
    expect(replies.single.content.preview, 'Finished while reconnecting');
  });

  test(
    'remote working state survives uncertain reads, but waiting stops it',
    () async {
      final host = NotificationCoverageHost();
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'remote-activity',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (_) async {},
      );
      addTearDown(owner.dispose);
      await owner.initialize();
      expect(owner.hasActiveChats, isFalse);
      var reads = host.activeReads;
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await waitForReads(host, ++reads);
      expect(owner.hasActiveChats, isTrue);
      host.activeFails = true;
      host.changed();
      await waitForReads(host, ++reads);
      expect(owner.hasActiveChats, isTrue);
      host.activeFails = false;
      host.active = [row('outside-runtime', 'outside', 'unknown')];
      host.changed();
      await waitForReads(host, ++reads);
      expect(owner.hasActiveChats, isTrue);
      host.active = [row('outside-runtime', 'outside', 'waiting')];
      host.changed();
      await waitForReads(host, ++reads);
      await until(() => !owner.hasActiveChats);
      host.active = [
        {
          ...row('outside-runtime', 'outside', 'waiting'),
          'side_tasks_running': 1,
        },
      ];
      host.changed();
      await waitForReads(host, ++reads);
      expect(owner.hasActiveChats, isTrue);
      host.active = [];
      host.changed();
      await waitForReads(host, ++reads);
      expect(
        owner.hasActiveChats,
        isFalse,
        reason: 'A retired runtime no longer owns a background watch',
      );
      host.active = [row('outside-runtime', 'outside', 'waiting')];
      host.changed();
      await waitForReads(host, ++reads);
      await until(() => !owner.hasActiveChats);
    },
  );
}
