import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart'
    show MemoryIdentityStore, identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

void main() {
  late SharedPreferences prefs;
  late MemoryIdentityStore secrets;
  late ProfileWorkspaceRegistry registry;
  late Map<String, Host> hosts;
  ProfileWorkspaceRegistry newRegistry() => ProfileWorkspaceRegistry(
    identities: ProfileConnectionIdentity(credentialStore: secrets),
    create: (connection, identity) => ProfileWorkspaceController(
      connection: connection,
      connectionIdentity: identity,
      preferences: prefs,
      gatewayFactory: (hosts[identity] = Host()).gateway,
    ),
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemoryIdentityStore();
    hosts = {};
    registry = newRegistry();
  });
  tearDown(() => registry.dispose());

  test(
    'editing connection isolates clients, duplicate IDs, drafts and activity',
    () async {
      final connection = identityTestConnection();
      final original = await registry.forConnection(connection);
      await original.initialize();
      final chat = await original.createChat();
      chat.draft = 'original turn';
      await original.send(chat);
      expect(
        await registry.forConnection(connection.copyWith(label: 'New label')),
        same(original),
      );
      final replacement = await registry.forConnection(
        connection.copyWith(host: 'replacement'),
      );
      await replacement.initialize();
      final other = await replacement.createChat();
      other.draft = 'replacement draft';
      expect(other.key.sessionId, chat.key.sessionId);
      expect(other.key, isNot(chat.key));
      expect(
        other.key.workspace.storageNamespace,
        isNot(chat.key.workspace.storageNamespace),
      );
      hosts[original.connectionIdentity]!.event('a', 'message.delta', {
        'text': 'original output',
      });
      expect(chat.streaming, 'original output');
      expect(other.streaming, isEmpty);
      expect(other.draft, 'replacement draft');
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
      final chat = await original.createChat();
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
      final chat = await original.createChat();
      chat.draft = 'running original turn';
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
      expect(restored.activity.single.status, ProfileTurnStatus.running);
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
      await manager.importConnections([connection], replaceExisting: false);
      final original = await registry.forConnection(
        (await manager.loadConnectionsWithSecrets()).single,
      );
      await original.initialize();
      final chat = await original.createChat();
      await manager.importConnections([
        connection.copyWith(host: 'imported-host'),
      ], replaceExisting: true);
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
