import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/config_backup_operation.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/backup_session.dart';
import 'package:wing/core/services/config_backup.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/services/connection_manager.dart'
    show ConnectionManager, CredentialStore;

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences()
    : super.withData({
        'flutter.theme_mode': 'light',
        'flutter.voice.output': 'local',
        'flutter.plugin.cache': 'kept',
      });

  final writes = <String>[];
  final failedWriteEntered = Completer<void>();
  final failedWriteReleased = Completer<void>();
  bool failSetting = false;
  bool failRollback = false;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key == 'flutter.saved_connections' ? key : '$key=$value');
    if (failSetting && key == 'flutter.voice.output' && value == 'hermes') {
      failedWriteEntered.complete();
      await failedWriteReleased.future;
      // False acknowledgements may follow a physical effect. The real owner
      // must include this failed target in its rollback, not just older writes.
      await super.setValue(type, key, value);
      return false;
    }
    if (failRollback &&
        (key == 'flutter.theme_mode' && value == 'light' ||
            key == 'flutter.voice.output' && value == 'local')) {
      return false;
    }
    return super.setValue(type, key, value);
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

class _Picker extends ConfigBackupIo {
  _Picker(this.contents);
  final String contents;

  @override
  Future<String?> pickBackupFile() async => contents;
}

class _Fixture {
  _Fixture({
    required this.platform,
    required this.credentials,
    required this.manager,
    required this.owner,
    required this.session,
    required this.retainedId,
    required this.removedId,
  });

  final _Preferences platform;
  final _Credentials credentials;
  final ConnectionManager manager;
  final AppPreferences owner;
  final BackupSession session;
  final String retainedId;
  final String removedId;

  Future<ConfigImportResult?> restore(BackupImportOffer offer) =>
      session.restore(
        offer,
        const BackupImportIntent(
          passphrase: '',
          mode: ConfigImportMode.replace,
        ),
      );

  Future<void> expectConfirmedConnections() async {
    // Read back through the actual manager's durable credential boundary.
    final connections = await manager.loadConnectionsWithSecrets();
    expect(connections.map((connection) => connection.id), [
      retainedId,
      'incoming',
    ]);
    expect(connections.first.label, 'Updated');
    expect(connections.first.apiKey, 'fixture-updated');
    expect(connections.last.apiKey, 'fixture-incoming');
    expect(connections.any((connection) => connection.id == removedId), false);
    expect(credentials.values.containsKey('connection_transaction_v1'), false);
    expect(
      credentials.mutations.where(
        (operation) => operation == 'write:connection_transaction_v1',
      ),
      hasLength(1),
    );
    expect(
      platform.writes.where((key) => key == 'flutter.saved_connections'),
      hasLength(1),
    );
  }
}

Future<_Fixture> _fixture() async {
  SharedPreferences.resetStatic();
  final platform = _Preferences();
  SharedPreferencesStorePlatform.instance = platform;
  final storage = await SharedPreferences.getInstance();
  final credentials = _Credentials();
  final manager = await ConnectionManager.create(
    storage,
    credentialStore: credentials,
  );
  final retained = await manager.saveConnection(
    'Before',
    '127.0.0.1',
    8642,
    'fixture-before',
  );
  final removed = await manager.saveConnection(
    'Removed',
    '127.0.0.1',
    8642,
    'fixture-removed',
  );
  final owner = AppPreferences(storage);
  final contents = await ConfigBackupCodec.encode(
    ConfigBackup(
      createdAt: DateTime.utc(2026, 10, 4),
      appVersion: 'fixture',
      connections: [
        retained.copyWith(label: 'Updated', apiKey: 'fixture-updated'),
        SavedConnection(
          id: 'incoming',
          label: 'Incoming',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'fixture-incoming',
        ),
      ],
      preferences: const {
        'theme_mode': 'dark',
        'voice.output': 'hermes',
        'not_owned_by_app_preferences': true,
      },
    ),
    passphrase: '',
  );
  final session = BackupSession(
    configuration: ConfigBackupService(
      connectionManager: manager,
      appPreferences: owner,
    ),
    io: _Picker(contents),
  );
  platform.writes.clear();
  credentials.mutations.clear();
  addTearDown(() {
    session.close();
    owner.dispose();
    SharedPreferences.setMockInitialValues({});
  });
  return _Fixture(
    platform: platform,
    credentials: credentials,
    manager: manager,
    owner: owner,
    session: session,
    retainedId: retained.id,
    removedId: removed.id,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final rollbackFails in [false, true]) {
    test(
      'confirmed connections survive settings failure with ${rollbackFails ? 'unverified' : 'verified'} rollback',
      () async {
        final f = await _fixture();
        f.platform.failSetting = true;
        f.platform.failRollback = rollbackFails;
        final offer = (await f.session.prepareImport())!;
        final pending = f.restore(offer);
        await f.platform.failedWriteEntered.future;

        // The manager's transaction is already confirmed before settings fail.
        await f.expectConfirmedConnections();
        expect((await f.platform.getAll())['flutter.theme_mode'], 'dark');
        expect(f.owner.current.theme.busy, true);
        expect(f.session.presentation.value.busy, true);
        f.platform.failedWriteReleased.complete();
        final result = await pending;

        // Establish actual disk and authority facts before outcome copy/state.
        await f.expectConfirmedConnections();
        final stored = await f.platform.getAll();
        expect(stored['flutter.theme_mode'], rollbackFails ? 'dark' : 'light');
        expect(
          stored['flutter.voice.output'],
          rollbackFails ? 'hermes' : 'local',
        );
        expect(stored['flutter.plugin.cache'], 'kept');
        expect(
          stored.containsKey('flutter.not_owned_by_app_preferences'),
          false,
        );
        expect(
          f.platform.writes.where((key) => key != 'flutter.saved_connections'),
          [
            'flutter.theme_mode=dark',
            'flutter.voice.output=hermes',
            'flutter.voice.output=local',
            'flutter.theme_mode=light',
          ],
        );
        expect(
          f.owner.current.theme.selected,
          rollbackFails ? null : AppThemePreference.light,
        );
        expect(
          f.owner.current.voiceOutput.selected,
          rollbackFails ? null : AppVoiceProcessing.local,
        );
        expect(f.owner.current.storageVerified, !rollbackFails);
        expect(f.owner.current.unverified.length, rollbackFails ? 2 : 0);
        expect(result, isNotNull);
        expect(result!.connectionsAdded, 1);
        expect(result.connectionsUpdated, 1);
        expect(result.connectionsRemoved, 1);
        expect(result.preferencesApplied, 0);
        expect(result.preferencesSkipped, 1);
        expect(result.complete, false);
        expect(
          result.settingsState,
          rollbackFails
              ? ConfigImportSettingsState.unverified
              : ConfigImportSettingsState.rolledBack,
        );
        expect(result.settingsUnverified, rollbackFails ? 2 : 0);
        expect(f.session.presentation.value.restoreResult, same(result));
        expect(f.session.presentation.value.busy, false);
        expect(f.session.presentation.value.notice, isNull);
        expect(f.session.presentation.value.error, result.summary);
      },
    );
  }

  test(
    'closing after manager admission preserves settlement without late publication',
    () async {
      final f = await _fixture();
      var publications = 0;
      f.session.presentation.addListener(() => publications++);
      final offer = (await f.session.prepareImport())!;
      f.credentials.holdOriginalRead = true;
      final pending = f.restore(offer);
      await f.credentials.originalReadEntered.future;
      expect(f.credentials.mutations, isEmpty);
      expect(f.platform.writes, isEmpty);
      expect(f.manager.getConnections().map((connection) => connection.id), [
        f.removedId,
        f.retainedId,
      ]);
      final beforeClose = publications;

      f.session.close();
      f.credentials.originalReadReleased.complete();
      final result = await pending;

      await f.expectConfirmedConnections();
      final stored = await f.platform.getAll();
      expect(stored['flutter.theme_mode'], 'dark');
      expect(stored['flutter.voice.output'], 'hermes');
      expect(stored['flutter.plugin.cache'], 'kept');
      expect(f.owner.current.theme.selected, AppThemePreference.dark);
      expect(f.owner.current.voiceOutput.selected, AppVoiceProcessing.hermes);
      expect(f.owner.current.storageVerified, true);
      expect(result, isNull);
      expect(publications, beforeClose);
      expect(f.session.beginExport(), isNull);
      expect(await f.session.prepareImport(), isNull);
      expect(
        f.credentials.values.containsKey('connection_transaction_v1'),
        false,
      );
    },
  );
}
