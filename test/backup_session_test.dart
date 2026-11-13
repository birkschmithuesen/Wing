import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/models/config_backup_operation.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/backup_session.dart';
import 'package:wing/core/services/config_backup.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/services/connection_manager.dart'
    show ConnectionManager, CredentialStore;

class _Credentials implements CredentialStore {
  final values = <String, String>{};
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
    values[key] = value;
  }
}

class _Platform extends ConfigBackupIo {
  final pickEntered = Completer<void>();
  final versionEntered = Completer<void>();
  final picked = Completer<String?>();
  final version = Completer<String>();
  int delivered = 0;

  @override
  Future<String?> pickBackupFile() {
    if (!pickEntered.isCompleted) pickEntered.complete();
    return picked.future;
  }

  @override
  Future<String> appVersion() {
    if (!versionEntered.isCompleted) versionEntered.complete();
    return version.future;
  }

  @override
  Future<String?> deliverExport(
    String contents, {
    required bool Function() canDispatch,
  }) async {
    if (!canDispatch()) return null;
    delivered++;
    return 'fixture-backup.json';
  }
}

Future<
  ({
    BackupSession session,
    ConnectionManager manager,
    AppPreferences owner,
    SharedPreferences storage,
    _Credentials credentials,
    _Platform platform,
  })
>
_fixture() async {
  SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
  final storage = await SharedPreferences.getInstance();
  final credentials = _Credentials();
  final manager = await ConnectionManager.create(
    storage,
    credentialStore: credentials,
  );
  final owner = AppPreferences(storage);
  final platform = _Platform();
  final session = BackupSession(
    configuration: ConfigBackupService(
      connectionManager: manager,
      appPreferences: owner,
    ),
    io: platform,
  );
  addTearDown(owner.dispose);
  addTearDown(session.close);
  return (
    session: session,
    manager: manager,
    owner: owner,
    storage: storage,
    credentials: credentials,
    platform: platform,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'closing while the picker is held cannot restore or publish late',
    () async {
      final f = await _fixture();
      final contents = await ConfigBackupCodec.encode(
        ConfigBackup(
          createdAt: DateTime.utc(2026, 10, 4),
          appVersion: 'fixture',
          connections: [
            SavedConnection(
              id: 'incoming',
              label: 'Incoming',
              host: '127.0.0.1',
              port: 8642,
              apiKey: '',
            ),
          ],
          preferences: const {'theme_mode': 'light'},
        ),
        passphrase: '',
      );
      var publications = 0;
      f.session.presentation.addListener(() => publications++);
      final pending = f.session.prepareImport();
      await f.platform.pickEntered.future;
      expect(f.session.presentation.value.busy, isTrue);
      expect(f.credentials.writes, 0);
      final beforeClose = publications;

      f.session.close();
      f.platform.picked.complete(contents);

      expect(await pending, isNull);
      expect(f.credentials.writes, 0);
      expect(f.manager.getConnections(), isEmpty);
      expect(f.storage.getString('theme_mode'), 'dark');
      expect(publications, beforeClose);
    },
  );

  test(
    'closing while package lookup is held cannot deliver an export',
    () async {
      final f = await _fixture();
      final attempt = f.session.beginExport()!;
      final pending = f.session.export(
        attempt,
        BackupExportIntent(passphrase: '', confirmation: ''),
      );
      await f.platform.versionEntered.future;
      expect(f.platform.delivered, 0);

      f.session.close();
      f.platform.version.complete('fixture');

      expect(await pending, isNull);
      expect(f.platform.delivered, 0);
      expect(f.credentials.writes, 0);
    },
  );

  test(
    'a held picker retains the single admission across both actions',
    () async {
      final f = await _fixture();
      final first = f.session.prepareImport();
      await f.platform.pickEntered.future;

      expect(f.session.beginExport(), isNull);
      expect(await f.session.prepareImport(), isNull);
      expect(f.credentials.writes, 0);

      f.platform.picked.complete(null);
      expect(await first, isNull);
      expect(f.session.presentation.value.busy, isFalse);
      final next = f.session.beginExport();
      expect(next, isNotNull);
      expect(f.session.cancel(next!), isTrue);
    },
  );
}
