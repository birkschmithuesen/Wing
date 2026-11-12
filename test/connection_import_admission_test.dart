import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/services/connection_manager.dart'
    show ConnectionManager, CredentialStore;

class _HeldCredentials implements CredentialStore {
  final values = <String, String>{};
  final entered = Completer<void>();
  final release = Completer<void>();
  bool _hold = true;
  int writes = 0;

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (_hold) {
      _hold = false;
      entered.complete();
      await release.future;
    }
    values[key] = value;
  }
}

SavedConnection _incoming() => SavedConnection(
  id: 'incoming',
  label: 'Incoming',
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'queued import checks authority after the older transaction settles',
    () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await SharedPreferences.getInstance();
      final credentials = _HeldCredentials();
      final manager = await ConnectionManager.create(
        storage,
        credentialStore: credentials,
      );
      final older = manager.saveConnection('Older', '127.0.0.1', 8642, '');
      await credentials.entered.future;
      var allowed = true;
      var checks = 0;
      final pending = manager
          .importConnections(
            [_incoming()],
            replaceExisting: true,
            canCommit: () {
              checks++;
              return allowed;
            },
          )
          .then<Object>((result) => result, onError: (Object error) => error);
      expect(checks, 0);
      expect(manager.getConnections(), isEmpty);

      allowed = false;
      credentials.release.complete();
      final saved = await older;
      final writesAfterOlder = credentials.writes;
      final outcome = await pending;

      // Assert effects before refusal classification.
      expect(credentials.writes, writesAfterOlder);
      expect(manager.getConnections().map((c) => c.id), [saved.id]);
      expect(checks, 1);
      expect(outcome, isA<StateError>());
    },
  );

  test(
    'import counts use membership established by the older queued transaction',
    () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await SharedPreferences.getInstance();
      final credentials = _HeldCredentials();
      final manager = await ConnectionManager.create(
        storage,
        credentialStore: credentials,
      );
      final older = manager.saveConnection('Older', '127.0.0.1', 8642, '');
      await credentials.entered.future;
      final pending = manager.importConnections(
        [_incoming()],
        replaceExisting: true,
        canCommit: () => true,
      );
      expect(manager.getConnections(), isEmpty);

      credentials.release.complete();
      await older;
      final result = await pending;

      expect(manager.getConnections().map((c) => c.id), ['incoming']);
      expect(result.added, 1);
      expect(result.updated, 0);
      expect(result.removed, 1);
    },
  );
}
