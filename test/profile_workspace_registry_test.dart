import 'package:wing/core/models/chat_runtime.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart'
    show MemoryIdentityStore, identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

void main() {
  late SharedPreferences prefs;
  late AppPreferences appPreferences;
  late MemoryIdentityStore secrets;
  late ProfileWorkspaceRegistry registry;
  late Map<String, Host> hosts;
  Future<void> Function(ProfileInputNotification)? onInputs;
  ProfileWorkspaceRegistry newRegistry() => ProfileWorkspaceRegistry(
    identities: ProfileConnectionIdentity(credentialStore: secrets),
    create: (connection, identity) => ProfileWorkspaceController(
      access: ConnectionAccess(connection: connection, dashboardOAuth: null),
      connectionIdentity: identity,
      preferences: prefs,
      appPreferences: appPreferences,
      gatewayFactory: (hosts[identity] = Host()).gateway,
      onNotificationInputs: onInputs,
    ),
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(prefs);
    secrets = MemoryIdentityStore();
    hosts = {};
    onInputs = null;
    registry = newRegistry();
  });
  tearDown(() {
    registry.dispose();
    appPreferences.dispose();
  });

  for (final reconcile in [false, true]) {
    test(
      'saved alias refreshes retained workspace (reconcile: $reconcile)',
      () async {
        final connection = identityTestConnection().copyWith(
          label: 'claw.tarkilnetwork',
        );
        final owner = await registry.forConnection(connection);
        await owner.initialize();
        final chat = await owner.createChat(canDispatch: () => true);
        await owner.updateDraft(chat, 'Keep this draft');
        final host = hosts[owner.connectionIdentity]!;
        final connects = host.connectCalls;
        var observations = 0;
        owner.addListener(() => observations++);
        final renamed = connection.copyWith(label: 'Claw');

        if (reconcile) {
          await registry.reconcileConnections([renamed]);
        } else {
          expect(await registry.forConnection(renamed), same(owner));
        }

        expect(owner.connection.label, 'Claw');
        expect(observations, greaterThan(0));
        expect(owner.current!.chat, same(chat));
        expect(chat.composer.observation.text, 'Keep this draft');
        expect(host.connectCalls, connects);
        expect(host.closed, isEmpty);
        expect(owner.access.connection, same(connection));
      },
    );
  }

  test(
    'foreground retries a mounted workspace whose startup stopped',
    () async {
      final connection = identityTestConnection();
      final owner = await registry.forConnection(connection);
      final host = hosts[owner.connectionIdentity]!;
      owner.setRouteMounted(Object(), true);
      host.discoveryFailure = const DashboardHttpException(400, 'profiles');
      await owner.initialize();
      expect(owner.initialized, isFalse);
      expect(owner.recovering, isFalse);
      expect(owner.error, contains('Couldn’t open this workspace'));
      host.discoveryFailure = null;

      final initialized = Completer<void>();
      void observeInitialization() {
        if (owner.initialized && !initialized.isCompleted) {
          initialized.complete();
        }
      }

      owner.addListener(observeInitialization);
      try {
        registry.resumeConnections();
        await initialized.future;
      } finally {
        owner.removeListener(observeInitialization);
      }

      expect(
        owner.initialized,
        isTrue,
        reason: 'Foreground entry must retry the mounted failed startup',
      );
    },
  );

  for (final trigger in ['network', 'unmounted foreground']) {
    test('$trigger does not retry a permanently failed startup', () async {
      final connection = identityTestConnection();
      final owner = await registry.forConnection(connection);
      final host = hosts[owner.connectionIdentity]!;
      if (trigger == 'network') owner.setRouteMounted(Object(), true);
      host.discoveryFailure = const DashboardHttpException(401, 'profiles');
      await owner.initialize();
      host.discoveryFailure = null;
      if (trigger == 'network') {
        registry.recoverConnections();
      } else {
        registry.resumeConnections();
      }
      await Future<void>.delayed(Duration.zero);
      expect(owner.initialized, isFalse);
      expect(host.connectCalls, 0);
    });
  }

  test(
    'connection edit soak closes settled obsolete sockets and reconnects live owners only',
    () async {
      final base = identityTestConnection();
      final observations = <int>[];
      for (var i = 0; i < 25; i++) {
        final connection = base.copyWith(host: 'host-$i');
        await registry.reconcileConnections([connection]);
        final owner = await registry.forConnection(connection);
        await owner.initialize();
        observations.add(registry.controllers.length);
      }
      expect(observations.toSet(), {1});
      final current = registry.controllers.single;
      final retired = hosts.entries.where(
        (entry) => entry.key != current.connectionIdentity,
      );
      expect(retired, hasLength(24));
      expect(retired.every((entry) => entry.value.closed.isNotEmpty), isTrue);
      final reconnects = {
        for (final entry in retired) entry.key: entry.value.connectCalls,
      };
      registry.recoverConnections();
      await Future<void>.delayed(Duration.zero);
      expect(
        retired.every(
          (entry) => entry.value.connectCalls == reconnects[entry.key],
        ),
        isTrue,
      );
      await registry.reconcileConnections([]);
      expect(registry.controllers, isEmpty);
      expect(hosts[current.connectionIdentity]!.closed, isNotEmpty);
    },
  );

  test(
    'superseded and deleted owners wait for route, draft and queue leases',
    () async {
      final connection = identityTestConnection();
      await registry.reconcileConnections([connection]);
      final original = await registry.forConnection(connection);
      await original.initialize();
      final chat = await original.createChat(canDispatch: () => true);
      final route = Object();
      original.setRouteMounted(route, true);
      original.setRouteVisibility(route, true);
      await original.updateDraft(chat, 'Keep this draft');
      original.setRouteVisibility(route, false);
      final replacement = connection.copyWith(host: 'replacement');
      await registry.reconcileConnections([replacement]);
      expect(registry.controllers, contains(original));
      expect(hosts[original.connectionIdentity]!.closed, isEmpty);
      original.setRouteMounted(route, false);
      await registry.reconcileConnections([]);
      expect(registry.controllers, contains(original));
      await original.updateDraft(chat, '');
      await restoreComposerFixture(
        chat: chat,
        preferences: original.preferences,
        appendQueued: [QueuedPromptDraft(text: 'Queued work')],
      );
      await registry.reconcileConnections([]);
      expect(registry.controllers, contains(original));
      await restoreComposerFixture(
        chat: chat,
        preferences: original.preferences,
        queuedPrompts: const [],
      );
      await Future<void>.delayed(Duration.zero);
      await registry.reconcileConnections([]);
      expect(registry.controllers, isEmpty);
      expect(hosts[original.connectionIdentity]!.closed, isNotEmpty);
    },
  );

  test(
    'deleted owner waits for pending notification delivery after input resolves',
    () async {
      final delivery = Completer<void>();
      onInputs = (_) => delivery.future;
      final connection = identityTestConnection();
      await registry.reconcileConnections([connection]);
      final owner = await registry.forConnection(connection);
      await owner.initialize();
      final chat = await owner.createChat(canDispatch: () => true);
      emitChatEvent(owner, chat, 'approval', {
        'request_id': 'pending',
        'server_request_id': 'pending-server',
        'command': 'Review',
      });
      owner.showList();
      emitChatEvent(owner, chat, 'request.cancel', {
        'id': 'pending-server',
        'method': 'approval',
      });
      owner.showList();
      await registry.reconcileConnections([]);
      expect(registry.controllers, contains(owner));
      expect(hosts[owner.connectionIdentity]!.closed, isEmpty);
      delivery.complete();
      await Future<void>.delayed(Duration.zero);
      await registry.reconcileConnections([]);
      expect(registry.controllers, isEmpty);
      expect(hosts[owner.connectionIdentity]!.closed, isNotEmpty);
    },
  );

  test(
    'deleted owner waits for cold approval hydration and retires after failure',
    () async {
      final connection = identityTestConnection();
      await registry.reconcileConnections([connection]);
      final owner = await registry.forConnection(connection);
      await owner.initialize();
      final host = hosts[owner.connectionIdentity]!;
      final connectionRead = Completer<void>();
      host.connectDelay = connectionRead;
      host.connectError = StateError('Approval connection failed');
      final key = ProfileSessionKey(owner.current!.scope, 'same');
      final hydration = owner.loadNotificationApproval(key);
      final failed = expectLater(hydration, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(owner.findNotificationChat(key), isNull);
      await registry.reconcileConnections([]);
      expect(registry.controllers, contains(owner));
      expect(host.closed, isEmpty);
      connectionRead.complete();
      await failed;
      for (var i = 0; i < 20 && registry.controllers.isNotEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(registry.controllers, isEmpty);
      expect(host.closed, isNotEmpty);
    },
  );

  test(
    'idle obsolete recovery timers retire while recovery owning work stays leased',
    () async {
      final connection = identityTestConnection();
      await registry.reconcileConnections([connection]);
      final idle = await registry.forConnection(connection);
      await idle.initialize();
      idle.networkUnavailable();
      expect(idle.recovering, isTrue);
      final replacement = connection.copyWith(host: 'replacement');
      await registry.reconcileConnections([replacement]);
      expect(registry.controllers, isEmpty);
      expect(hosts[idle.connectionIdentity]!.closed, isNotEmpty);
      final live = await registry.forConnection(replacement);
      await live.initialize();
      final chat = await live.createChat(canDispatch: () => true);
      emitChatEvent(live, chat, 'message.start');
      live.networkUnavailable();
      expect(chat.runtime.reconnecting, isTrue);
      await registry.reconcileConnections([]);
      expect(registry.controllers, contains(live));
      expect(hosts[live.connectionIdentity]!.closed, isEmpty);
    },
  );

  test(
    'editing connection isolates clients, duplicate IDs, drafts and activity',
    () async {
      final connection = identityTestConnection();
      final original = await registry.forConnection(connection);
      await original.initialize();
      final chat = await original.createChat(canDispatch: () => true);
      chat.composer.editText('original turn');
      await original.send(chat);
      expect(
        await registry.forConnection(connection.copyWith(label: 'New label')),
        same(original),
      );
      final replacement = await registry.forConnection(
        connection.copyWith(host: 'replacement'),
      );
      await replacement.initialize();
      final other = await replacement.createChat(canDispatch: () => true);
      other.composer.editText('replacement draft');
      expect(other.key.sessionId, chat.key.sessionId);
      expect(other.key, isNot(chat.key));
      expect(
        other.key.workspace.storageNamespace,
        isNot(chat.key.workspace.storageNamespace),
      );
      hosts[original.connectionIdentity]!.event('a', 'message.delta', {
        'text': 'original output',
      });
      expect(chat.reading.streaming, 'original output');
      expect(other.reading.streaming, isEmpty);
      expect(other.composer.observation.text, 'replacement draft');
      expect(replacement.activity, isEmpty);
      expect(hosts[original.connectionIdentity]!.closed, isEmpty);
      expect(original.connection.host, connection.host);
    },
  );

  test(
    'stale notification rejects changed credentials before any gateway request',
    () async {
      final connection = identityTestConnection();
      final original = await registry.forConnection(connection);
      await original.initialize();
      final chat = await original.createChat(canDispatch: () => true);
      final payload = jsonEncode(chat.key.toJson());
      final key = ProfileSessionKey.fromJson(
        jsonDecode(payload) as Map<String, dynamic>,
      );
      final changed = connection.copyWith(
        dashboardPassword: 'replacement-secret',
      );
      await expectLater(registry.forSession(changed, key), throwsStateError);
      final replacement = await registry.forConnection(changed);
      expect(hosts[replacement.connectionIdentity]!.gateways, isEmpty);
      await expectLater(replacement.openSession(key), throwsArgumentError);
      expect(hosts[replacement.connectionIdentity]!.gateways, isEmpty);
      expect(await registry.forSession(connection, key), same(original));
      expect(payload, isNot(contains('private-password')));
      expect(payload, isNot(contains('localhost')));
    },
  );

  test(
    'process recreation restores only matching owners without resubmitting',
    () async {
      final connection = identityTestConnection();
      final original = await registry.forConnection(connection);
      await original.initialize();
      final chat = await original.createChat(canDispatch: () => true);
      chat.composer.editText('running original turn');
      await original.send(chat);
      await original.switchProfile('b');
      registry.dispose();
      registry = newRegistry();
      final replacement = await registry.forConnection(
        connection.copyWith(host: 'replacement'),
      );
      await replacement.initialize();
      expect(replacement.current!.scope.profileName, 'a');
      expect(replacement.activity, isEmpty);
      expect(
        hosts[replacement.connectionIdentity]!.calls.where(
          (c) => c.$2 == 'session.resume',
        ),
        isEmpty,
      );
      final restored = await registry.forConnection(connection);
      await restored.initialize();
      expect(restored.current!.scope.profileName, 'b');
      expect(restored.activity.single.key, chat.key);
      expect(restored.activity.single.runtime.execution, ChatExecution.running);
      expect(
        hosts[restored.connectionIdentity]!.calls.where(
          (c) => c.$2 == 'session.resume',
        ),
        hasLength(1),
      );
      expect(
        hosts[restored.connectionIdentity]!.calls.where(
          (c) => c.$2 == 'prompt.submit',
        ),
        isEmpty,
      );
    },
  );

  test(
    'config import with the same saved ID cannot reuse original ownership',
    () async {
      final manager = await ConnectionManager.create(
        prefs,
        credentialStore: secrets,
      );
      final connection = identityTestConnection();
      await manager.importConnections(
        [connection],
        replaceExisting: false,
        canCommit: () => true,
      );
      final original = await registry.forConnection(
        (await manager.loadConnectionsWithSecrets()).single,
      );
      await original.initialize();
      final chat = await original.createChat(canDispatch: () => true);
      await manager.importConnections(
        [connection.copyWith(host: 'imported-host')],
        replaceExisting: true,
        canCommit: () => true,
      );
      final imported = (await manager.loadConnectionsWithSecrets()).single;
      await expectLater(
        registry.forSession(imported, chat.key),
        throwsStateError,
      );
      expect(await registry.forConnection(imported), isNot(same(original)));
    },
  );

  test(
    'unbound notification payloads are rejected, not migrated to current host',
    () {
      expect(
        () => ProfileSessionKey.fromJson({
          'connection': 'same-id',
          'profile': 'a',
          'session': 'same',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'closing registry during identity resolution cannot leak a controller',
    () async {
      final pending = registry.forConnection(identityTestConnection());
      registry.dispose();
      await expectLater(pending, throwsStateError);
      expect(hosts, isEmpty);
    },
  );
}
