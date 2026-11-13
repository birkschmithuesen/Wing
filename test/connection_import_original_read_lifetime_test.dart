import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/models/connection_import_result.dart';
import 'package:wing/core/services/connection_manager.dart'
    show ConnectionManager, CredentialStore;

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.withData({});

  final writes = <String>[];

  @override
  Future<bool> setValue(String type, String key, Object value) {
    writes.add(key);
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) {
    writes.add(key);
    return super.remove(key);
  }
}

class _Credentials implements CredentialStore {
  final values = <String, String>{};
  final mutations = <String>[];
  final originalReadEntered = Completer<void>();
  final originalReadReleased = Completer<void>();
  bool holdOriginalRead = false;

  @override
  Future<String?> read(String key) async {
    if (holdOriginalRead && key.startsWith('connection_credentials_v1.')) {
      holdOriginalRead = false;
      originalReadEntered.complete();
      await originalReadReleased.future;
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    mutations.add('write:$key');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    mutations.add('delete:$key');
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'admitted import settles after revocation during original credential reads',
    () async {
      SharedPreferences.resetStatic();
      final platform = _Preferences();
      SharedPreferencesStorePlatform.instance = platform;
      final storage = await SharedPreferences.getInstance();
      final credentials = _Credentials();
      final manager = await ConnectionManager.create(
        storage,
        credentialStore: credentials,
      );
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      platform.writes.clear();
      credentials.mutations.clear();
      credentials.holdOriginalRead = true;
      var allowed = true;
      var authorityChecks = 0;
      final pending = manager
          .importConnections(
            [
              SavedConnection(
                id: 'incoming',
                label: 'Incoming',
                host: '127.0.0.1',
                port: 8642,
                apiKey: 'fixture-key',
              ),
            ],
            replaceExisting: true,
            canCommit: () {
              authorityChecks++;
              return allowed;
            },
          )
          .then<Object?>((result) => result, onError: (Object error) => error);
      await credentials.originalReadEntered.future;
      expect(authorityChecks, 1);
      expect(credentials.mutations, isEmpty);
      expect(platform.writes, isEmpty);
      expect(manager.getConnections(), isEmpty);

      allowed = false;
      credentials.originalReadReleased.complete();
      final outcome = await pending;

      // The owner admitted this transaction before its original-value reads.
      // Route revocation cannot interrupt its durable reconciliation or replay
      // the transaction. Pre-admission revocation is a separate refused case.
      expect(
        credentials.mutations.where(
          (key) => key == 'write:connection_transaction_v1',
        ),
        hasLength(1),
      );
      expect(
        credentials.mutations.where(
          (key) => key.startsWith('write:connection_credentials_v1.'),
        ),
        hasLength(1),
      );
      expect(platform.writes, ['flutter.saved_connections']);
      expect(
        credentials.values.containsKey('connection_transaction_v1'),
        false,
      );
      expect(manager.getConnections().map((connection) => connection.id), [
        'incoming',
      ]);
      expect(authorityChecks, 1);
      expect(outcome, isA<ConnectionImportResult>());
      final result = outcome as ConnectionImportResult;
      expect(result.added, 1);
      expect(result.updated, 0);
      expect(result.removed, 0);
    },
  );
}
