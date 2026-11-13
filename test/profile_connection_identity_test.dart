import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';

class MemoryIdentityStore implements CredentialStore {
  final values = <String, String>{};
  int writes = 0;
  bool failRead = false;
  bool failVerify = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('private platform error');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (!failVerify) values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

SavedConnection identityTestConnection() => SavedConnection(
  id: 'same-id',
  label: 'Host',
  host: 'localhost',
  port: 1234,
  dashboardPortOverride: 1234,
  apiKey: 'private-api-key',
  dashboardUsername: 'user',
  dashboardPassword: 'private-password',
);

void main() {
  test('identity survives process recreation and label-only edits', () async {
    final store = MemoryIdentityStore();
    final connection = identityTestConnection();
    final original = await ProfileConnectionIdentity(
      credentialStore: store,
    ).resolve(connection);
    final restored = ProfileConnectionIdentity(credentialStore: store);
    expect(
      await restored.resolve(connection.copyWith(label: 'Renamed')),
      original,
    );
    expect(store.writes, 1);
    expect(
      await restored.resolve(connection.copyWith(icon: ConnectionIcon.rocket)),
      original,
    );
    expect(original, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(jsonEncode(store.values), isNot(contains('private-')));
    expect(
      original,
      isNot(
        await ProfileConnectionIdentity(
          credentialStore: MemoryIdentityStore(),
        ).resolve(connection),
      ),
    );
  });

  test(
    'every endpoint and authentication setting partitions ownership',
    () async {
      final identities = ProfileConnectionIdentity(
        credentialStore: MemoryIdentityStore(),
      );
      final connection = identityTestConnection();
      final original = await identities.resolve(connection);
      final changes = [
        connection.copyWith(host: 'replacement'),
        connection.copyWith(port: 9999),
        connection.copyWith(useHttps: true),
        connection.copyWith(dashboardPortOverride: 9999),
        connection.copyWith(gatewayPrefix: '/gateway'),
        connection.copyWith(dashboardPrefix: '/dashboard'),
        connection.copyWith(dashboardProxied: true),
        connection.copyWith(desktopGatewayUrl: 'http://replacement:1234'),
        connection.copyWith(dashboardUsername: 'another-user'),
        connection.copyWith(dashboardPassword: 'another-password'),
        connection.copyWith(clearDashboardPassword: true),
        connection.copyWith(apiKey: 'another-api-key'),
        connection.copyWith(
          gatewayHeaders: const {'X-Access-Secret': 'another-secret'},
        ),
      ];
      for (final changed in changes) {
        expect(await identities.resolve(changed), isNot(original));
      }
    },
  );

  test('gateway header identity is case and order stable', () async {
    final identities = ProfileConnectionIdentity(
      credentialStore: MemoryIdentityStore(),
    );
    final first = identityTestConnection().copyWith(
      gatewayHeaders: const {
        'X-Access-Client': 'mobile',
        'X-Access-Secret': 'private-secret',
      },
    );
    final reordered = identityTestConnection().copyWith(
      gatewayHeaders: const {
        'x-access-secret': 'private-secret',
        'x-access-client': 'mobile',
      },
    );

    expect(
      await identities.resolve(reordered),
      await identities.resolve(first),
    );
    expect(
      await identities.resolve(
        reordered.copyWith(
          gatewayHeaders: const {
            'x-access-secret': 'rotated',
            'x-access-client': 'mobile',
          },
        ),
      ),
      isNot(await identities.resolve(first)),
    );
  });

  test('concurrent first resolution creates only one secure key', () async {
    final store = MemoryIdentityStore();
    final identities = ProfileConnectionIdentity(credentialStore: store);
    final results = await Future.wait(
      List.generate(10, (_) => identities.resolve(identityTestConnection())),
    );
    expect(results.toSet(), hasLength(1));
    expect(store.writes, 1);
  });

  test('missing secure storage and failed verification fail closed', () async {
    for (final store in [
      MemoryIdentityStore()..failRead = true,
      MemoryIdentityStore()..failVerify = true,
    ]) {
      await expectLater(
        ProfileConnectionIdentity(
          credentialStore: store,
        ).resolve(identityTestConnection()),
        throwsA(
          isA<CredentialStorageException>().having(
            (e) => e.message,
            'safe message',
            isNot(contains('private')),
          ),
        ),
      );
    }
  });

  test('corrupt secure key is not silently replaced', () async {
    final store = MemoryIdentityStore();
    await ProfileConnectionIdentity(
      credentialStore: store,
    ).resolve(identityTestConnection());
    store.values[store.values.keys.single] = base64Encode([1, 2]);
    await expectLater(
      ProfileConnectionIdentity(
        credentialStore: store,
      ).resolve(identityTestConnection()),
      throwsA(isA<CredentialStorageException>()),
    );
    expect(store.writes, 1);
  });
}
