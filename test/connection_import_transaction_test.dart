import 'package:wing/core/models/dashboard_oauth_grant.dart';
import 'package:wing/core/services/dashboard_oauth_session.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';

const _journalKey = 'connection_transaction_v1';
String _key(String id) =>
    'connection_credentials_v1.${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}';

class _Secrets implements CredentialStore {
  _Secrets([Map<String, String>? durable]) : values = durable ?? {};
  final Map<String, String> values;
  Future<void> Function(String operation, String key, String? value)? before;
  Future<void> Function(String operation, String key, String? value)? after;

  @override
  Future<String?> read(String key) async {
    await before?.call('read', key, null);
    final value = values[key];
    await after?.call('read', key, value);
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    await before?.call('write', key, value);
    values[key] = value;
    await after?.call('write', key, value);
  }

  @override
  Future<void> delete(String key) async {
    await before?.call('delete', key, null);
    values.remove(key);
    await after?.call('delete', key, null);
  }
}

/// Models optimistic preference cache, independently from the durable value.
class _Preferences extends Fake implements SharedPreferences {
  List<String>? durable;
  List<String>? cached;
  bool failWrite = false;
  bool throwAfterWrite = false;

  @override
  List<String>? getStringList(String key) =>
      cached == null ? null : List.of(cached!);
  @override
  Future<bool> setStringList(String key, List<String> value) async {
    cached = List.of(value);
    if (failWrite) {
      failWrite = false;
      return false;
    }
    durable = List.of(value);
    if (throwAfterWrite) {
      throwAfterWrite = false;
      throw StateError('synthetic metadata failure');
    }
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    cached = null;
    durable = null;
    return true;
  }

  @override
  Future<void> reload() async =>
      cached = durable == null ? null : List.of(durable!);
}

SavedConnection _connection(
  String id,
  String host,
  String secret, {
  DashboardOAuthGrant? oauth,
}) => SavedConnection(
  id: id,
  label: id,
  host: host,
  port: 443,
  useHttps: true,
  apiKey: secret,
  dashboardPassword: secret.isEmpty ? null : 'password-$secret',
  gatewayHeaders: secret.isEmpty ? {} : {'X-Access-Secret': 'header-$secret'},
  cloudInstanceId: oauth == null ? null : 'cloud-$id',
  dashboardGrant: oauth,
);

Future<ConnectionManager> _seed(
  _Preferences prefs,
  _Secrets store, {
  http.Client Function()? oauthClient,
}) async {
  final manager = await ConnectionManager.create(
    prefs,
    credentialStore: store,
    createOAuthSession: (grant) =>
        DashboardOAuthSession(grant, createClient: oauthClient),
  );
  await manager.importConnections(
    [
      _connection('a', 'old-a.example', 'old-a'),
      _connection('removed', 'old-removed.example', 'old-removed'),
    ],
    replaceExisting: true,
    canCommit: () => true,
  );
  return manager;
}

List<SavedConnection> get _incoming => [
  _connection('a', 'new-a.example', 'new-a'),
  _connection('added', 'new-added.example', 'new-added'),
];

void _expectOriginals(ConnectionManager manager) {
  final connections = manager.getConnections();
  expect(connections.map((c) => c.id), ['a', 'removed']);
  expect(connections.first.host, 'old-a.example');
  expect(connections.first.apiKey, 'old-a');
  expect(connections.first.dashboardPassword, 'password-old-a');
  expect(connections.first.gatewayHeaders, {'X-Access-Secret': 'header-old-a'});
  expect(connections.last.apiKey, 'old-removed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Each failure happens after the boundary's durable mutation/read, so tests
  // include storage APIs that apply an operation and then throw.
  for (final boundary in [
    ('write', _journalKey),
    ('read', _journalKey),
    ('write', _key('a')),
    ('read', _key('a')),
    ('write', _key('added')),
    ('read', _key('added')),
    ('delete', _key('removed')),
    ('read', _key('removed')),
    ('delete', _journalKey),
    ('read-deleted', _journalKey),
  ]) {
    test(
      'failed import restores exact originals after ${boundary.$1} ${boundary.$2}',
      () async {
        final prefs = _Preferences();
        final store = _Secrets();
        final manager = await _seed(prefs, store);
        final originalValues = Map.of(store.values);
        final originalMetadata = List.of(prefs.durable!);
        var started = false;
        var failed = false;
        store.after = (operation, key, value) async {
          if (operation == 'write' && key == _journalKey) started = true;
          if (!started || failed || key != boundary.$2) return;
          final matches = boundary.$1 == 'read-deleted'
              ? operation == 'read' && value == null
              : operation == boundary.$1 &&
                    (operation != 'read' ||
                        value != null ||
                        key != _journalKey);
          if (matches) {
            failed = true;
            throw StateError('synthetic boundary failure');
          }
        };
        await expectLater(
          manager.importConnections(
            _incoming,
            replaceExisting: true,
            canCommit: () => true,
          ),
          throwsA(isA<CredentialStorageException>()),
        );
        expect(failed, true);
        _expectOriginals(manager);
        expect(store.values, originalValues);
        expect(prefs.durable, originalMetadata);
        expect(prefs.cached, originalMetadata);
        // Cold store wrappers have no cached secrets or shared published state.
        final cold = await ConnectionManager.create(
          prefs,
          credentialStore: _Secrets(store.values),
        );
        _expectOriginals(cold);
      },
    );
  }

  for (final throwAfterWrite in [false, true]) {
    test(
      'metadata failure rolls back credentials and optimistic cache, applied=$throwAfterWrite',
      () async {
        final prefs = _Preferences();
        final store = _Secrets();
        final manager = await _seed(prefs, store);
        final originalValues = Map.of(store.values);
        final originalMetadata = List.of(prefs.durable!);
        if (throwAfterWrite) {
          prefs.throwAfterWrite = true;
        } else {
          prefs.failWrite = true;
        }
        await expectLater(
          manager.importConnections(
            _incoming,
            replaceExisting: true,
            canCommit: () => true,
          ),
          throwsA(isA<CredentialStorageException>()),
        );
        _expectOriginals(manager);
        expect(store.values, originalValues);
        expect(prefs.durable, originalMetadata);
        expect(prefs.cached, originalMetadata);
      },
    );
  }

  test(
    'failed rollback retains journal and blocks every reader until recovery',
    () async {
      final prefs = _Preferences();
      final store = _Secrets();
      final manager = await _seed(prefs, store);
      final originals = Map.of(store.values);
      var newWritten = false;
      store.before = (operation, key, value) async {
        if (operation == 'write' &&
            key == _key('a') &&
            value!.contains('new-a')) {
          newWritten = true;
        }
        if (newWritten && operation == 'write' && key == _key('added')) {
          throw StateError('import failure');
        }
        if (newWritten &&
            operation == 'write' &&
            key == _key('a') &&
            value!.contains('old-a')) {
          throw StateError('rollback failure');
        }
      };
      await expectLater(
        manager.importConnections(
          _incoming,
          replaceExisting: true,
          canCommit: () => true,
        ),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(store.values, contains(_journalKey));
      expect(
        manager.getConnections,
        throwsA(isA<CredentialStorageException>()),
      );
      await expectLater(
        manager.loadConnectionsWithSecrets(),
        throwsA(isA<CredentialStorageException>()),
      );
      final coldStore = _Secrets(store.values)..before = store.before;
      final cold = ConnectionManager(prefs, credentialStore: coldStore);
      await expectLater(
        cold.initialize(),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(cold.getConnections, throwsA(isA<CredentialStorageException>()));
      store.before = null;
      coldStore.before = null;
      await cold.initialize();
      _expectOriginals(cold);
      await manager.initialize();
      _expectOriginals(manager);
      expect(store.values, originals);
    },
  );

  for (final point in [
    'journal',
    'overwrite',
    'addition',
    'removal',
    'metadata',
  ]) {
    test('cold startup rolls back process interruption after $point', () async {
      final prefs = _Preferences();
      final store = _Secrets();
      await _seed(prefs, store);
      final originalValues = Map.of(store.values);
      final originalMetadata = List.of(prefs.durable!);
      store.values[_journalKey] = jsonEncode({
        'metadata': originalMetadata,
        'credentials': {
          'a': originalValues[_key('a')],
          'added': null,
          'removed': originalValues[_key('removed')],
        },
      });
      if (point != 'journal') {
        store.values[_key('a')] = jsonEncode({'api_key': 'new-a'});
      }
      if (['addition', 'removal', 'metadata'].contains(point)) {
        store.values[_key('added')] = jsonEncode({'api_key': 'new-added'});
      }
      if (['removal', 'metadata'].contains(point)) {
        store.values.remove(_key('removed'));
      }
      if (point == 'metadata') {
        await prefs.setStringList(
          'saved_connections',
          _incoming.map((c) => jsonEncode(c.toMap())).toList(),
        );
      }
      final coldStore = _Secrets(store.values);
      final cold = ConnectionManager(prefs, credentialStore: coldStore);
      expect(cold.getConnections, throwsA(isA<CredentialStorageException>()));
      final loaded = await cold.loadConnectionsWithSecrets();
      expect(loaded.first.apiKey, 'old-a');
      _expectOriginals(cold);
      expect(store.values, originalValues);
      expect(prefs.durable, originalMetadata);
    });
  }

  test('deleted journal is re-established before a failing rollback', () async {
    final prefs = _Preferences();
    final store = _Secrets();
    final manager = await _seed(prefs, store);
    final originals = Map.of(store.values);
    var deleted = false;
    store.after = (operation, key, value) async {
      if (operation == 'delete' && key == _journalKey && !deleted) {
        deleted = true;
        throw StateError('delete applied before synthetic failure');
      }
    };
    store.before = (operation, key, value) async {
      if (deleted &&
          operation == 'write' &&
          key == _key('a') &&
          value!.contains('old-a')) {
        expect(store.values, contains(_journalKey));
        throw StateError('rollback unavailable');
      }
    };
    await expectLater(
      manager.importConnections(
        _incoming,
        replaceExisting: true,
        canCommit: () => true,
      ),
      throwsA(isA<CredentialStorageException>()),
    );
    expect(manager.getConnections, throwsA(isA<CredentialStorageException>()));
    expect(store.values, contains(_journalKey));
    final cold = await ConnectionManager.create(
      prefs,
      credentialStore: _Secrets(store.values),
    );
    _expectOriginals(cold);
    expect(store.values, originals);
  });

  test('published credentials are scoped to their preferences owner', () async {
    final store = _Secrets();
    final firstPrefs = _Preferences();
    final first = await _seed(firstPrefs, store);
    final secondPrefs = _Preferences();
    final second = await ConnectionManager.create(
      secondPrefs,
      credentialStore: store,
    );
    expect(second.getConnections(), isEmpty);
    _expectOriginals(first);
  });

  test(
    'unreadable original secrets abort before changing metadata or credentials',
    () async {
      final prefs = _Preferences();
      final store = _Secrets();
      final manager = await _seed(prefs, store);
      final originals = Map.of(store.values);
      final metadata = List.of(prefs.durable!);
      store.before = (operation, key, value) async {
        if (operation == 'read' && key == _key('a')) {
          throw StateError('synthetic error includes private-old-a');
        }
      };
      Object? failure;
      try {
        await manager.importConnections(
          _incoming,
          replaceExisting: true,
          canCommit: () => true,
        );
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<CredentialStorageException>());
      expect(failure.toString(), isNot(contains('private-old-a')));
      _expectOriginals(manager);
      expect(store.values, originals);
      expect(prefs.durable, metadata);
    },
  );

  test(
    'merge import keeps untouched secrets in cached and cold reads',
    () async {
      final prefs = _Preferences();
      final store = _Secrets();
      final manager = await _seed(prefs, store);
      await manager.importConnections(
        [_connection('a', 'new-a.example', 'new-a')],
        replaceExisting: false,
        canCommit: () => true,
      );
      expect(manager.getConnections().last.apiKey, 'old-removed');
      final cold = await ConnectionManager.create(
        prefs,
        credentialStore: _Secrets(store.values),
      );
      expect(cold.getConnections().last.apiKey, 'old-removed');
    },
  );

  test(
    'import serializes save, delete, edits and cold readers across managers',
    () async {
      final prefs = _Preferences();
      final store = _Secrets();
      final manager = await _seed(prefs, store);
      final other = ConnectionManager(prefs, credentialStore: store);
      final entered = Completer<void>();
      final release = Completer<void>();
      store.after = (operation, key, value) async {
        if (operation == 'write' &&
            key == _key('a') &&
            value!.contains('new-a') &&
            !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final importing = manager.importConnections(
        _incoming,
        replaceExisting: true,
        canCommit: () => true,
      );
      await entered.future;
      _expectOriginals(manager);
      _expectOriginals(other);
      var readSettled = false;
      final reading = other.loadConnectionsWithSecrets().then((result) {
        readSettled = true;
        return result;
      });
      final admitted = _incoming.first;
      final update = other.updateConnection(
        admitted.id,
        admitted.label,
        Uri(
          scheme: admitted.useHttps ? 'https' : 'http',
          host: admitted.host,
        ).toString(),
        admitted.port,
        'post-import',
        icon: admitted.icon,
        gatewayPrefix: admitted.gatewayPrefix,
        dashboardPrefix: admitted.dashboardPrefix,
        dashboardProxied: admitted.dashboardProxied,
        desktopGatewayUrl: admitted.desktopGatewayUrl,
        dashboardPort: admitted.dashboardPortOverride,
        dashboardUsername: admitted.dashboardUsername,
        dashboardPassword: admitted.dashboardPassword,
        cloudInstanceId: admitted.cloudInstanceId,
        cloudOrganization: admitted.cloudOrganization,
        dashboardGrant: admitted.dashboardGrant,
        gatewayHeaders: admitted.gatewayHeaders,
      );
      final icon = other.updateConnectionIcon('a', ConnectionIcon.home);
      final deletion = other.deleteConnection('added');
      final saving = other.saveConnection(
        'Concurrent',
        'saved.example',
        443,
        'save-secret',
      );
      await Future<void>.delayed(Duration.zero);
      expect(readSettled, false);
      _expectOriginals(manager);
      release.complete();
      await importing;
      expect((await reading).first.host, 'new-a.example');
      await Future.wait([update, icon, deletion]);
      await saving;
      final result = manager.getConnections();
      expect(result.map((c) => c.label), ['Concurrent', 'a']);
      expect(result.last.host, 'new-a.example');
      expect(result.last.apiKey, 'post-import');
      expect(result.last.icon, ConnectionIcon.home);
      expect(result.last.dashboardPassword, 'password-new-a');
      expect(store.values.containsKey(_journalKey), false);
      final cold = await ConnectionManager.create(
        prefs,
        credentialStore: _Secrets(store.values),
      );
      expect(cold.getConnections().last.apiKey, 'post-import');
    },
  );

  for (final replaceCloud in [false, true]) {
    test(
      'OAuth renewal queued behind import cannot overwrite replaced sign-in, replaced=$replaceCloud',
      () async {
        final prefs = _Preferences();
        final store = _Secrets();
        final manager = await _seed(
          prefs,
          store,
          oauthClient: () => MockClient(
            (_) async => http.Response(
              jsonEncode({
                'provider': 'nous',
                'access_token': 'rotated-access',
                'refresh_token': 'rotated-refresh',
                'expires_at':
                    DateTime.now()
                        .add(const Duration(hours: 1))
                        .millisecondsSinceEpoch /
                    1000,
              }),
              200,
            ),
          ),
        );
        final initialGrant = DashboardOAuthGrant(
          id: 'grant',
          baseUrl: 'https://cloud.example',
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          expiresAt: DateTime.utc(2020),
        );
        await manager.importConnections(
          [_connection('cloud', 'cloud.example', '', oauth: initialGrant)],
          replaceExisting: false,
          canCommit: () => true,
        );
        final session = manager
            .accessFor(
              manager.getConnections().firstWhere((c) => c.id == 'cloud'),
            )
            .dashboardOAuth!;
        final entered = Completer<void>();
        final release = Completer<void>();
        store.after = (operation, key, value) async {
          if (operation == 'write' &&
              key == _key('a') &&
              value!.contains('new-a') &&
              !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        final replacement = DashboardOAuthGrant(
          id: 'grant',
          baseUrl: session.currentGrant.baseUrl,
          accessToken: 'import-access',
          refreshToken: 'import-refresh',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        );
        final importing = manager.importConnections(
          [
            ..._incoming,
            if (replaceCloud)
              _connection('cloud', 'cloud.example', '', oauth: replacement),
          ],
          replaceExisting: replaceCloud,
          canCommit: () => true,
        );
        await entered.future;
        final renewing = session.bearerFor(session.currentGrant.baseUrl);
        // Attach the rejection observer before releasing the queue.
        final renewalExpectation = replaceCloud
            ? expectLater(renewing, throwsA(isA<CloudAccessException>()))
            : expectLater(renewing, completion('rotated-access'));
        await Future<void>.delayed(Duration.zero);
        release.complete();
        await importing;
        await renewalExpectation;
        final encoded =
            jsonDecode(store.values[_key('cloud')]!) as Map<String, dynamic>;
        expect(
          encoded['dashboard_oauth']['refresh_token'],
          replaceCloud ? 'import-refresh' : 'rotated-refresh',
        );
      },
    );
  }
}
