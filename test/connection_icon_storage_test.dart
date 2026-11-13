import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/config_backup.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/models/config_backup_operation.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';

class _Secrets implements CredentialStore {
  final values = <String, String>{};
  int writes = 0;

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Reproduces SharedPreferences' optimistic cache when a platform write fails.
class _FailedWritePreferences extends Fake implements SharedPreferences {
  _FailedWritePreferences(this.persisted) : cached = List.of(persisted);
  final List<String> persisted;
  List<String> cached;

  @override
  List<String>? getStringList(String key) => List.of(cached);

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    cached = List.of(value);
    return false;
  }

  @override
  Future<void> reload() async => cached = List.of(persisted);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a failed icon write restores the last saved selection', () async {
    final connection = SavedConnection(
      id: 'existing',
      label: 'Claw',
      host: 'hermes.example',
      port: 443,
      apiKey: '',
      icon: ConnectionIcon.cloud,
    );
    final prefs = _FailedWritePreferences([jsonEncode(connection.toMap())]);
    final manager = ConnectionManager(prefs, credentialStore: _Secrets());
    await expectLater(
      manager.updateConnectionIcon(connection.id, ConnectionIcon.rocket),
      throwsA(isA<CredentialStorageException>()),
    );
    expect(manager.getConnections().single.icon, ConnectionIcon.cloud);
  });

  test('existing metadata without an icon loads with Server', () async {
    SharedPreferences.setMockInitialValues({
      'saved_connections': [
        jsonEncode({
          'id': 'existing',
          'label': 'Claw',
          'host': 'hermes.example',
          'port': 443,
          'use_https': true,
        }),
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(
      prefs,
      credentialStore: _Secrets(),
    );
    expect(manager.getConnections().single.icon, ConnectionIcon.server);
    await manager.updateConnectionIcon('existing', ConnectionIcon.home);
    expect(manager.getConnections().single.icon, ConnectionIcon.home);
  });

  test(
    'all icons survive restart and appearance edits leave secrets intact',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final secrets = _Secrets();
      final manager = await ConnectionManager.create(
        prefs,
        credentialStore: secrets,
      );
      final saved = await manager.saveConnection(
        'Claw',
        'https://hermes.example',
        443,
        'api-secret',
        icon: ConnectionIcon.cloud,
        dashboardPassword: 'dashboard-secret',
        gatewayHeaders: {'X-Access-Secret': 'header-secret'},
      );
      expect(manager.getConnections().single.icon, ConnectionIcon.cloud);
      final originalSecrets = Map.of(secrets.values);
      final writes = secrets.writes;
      for (final icon in ConnectionIcon.values) {
        await manager.updateConnectionIcon(saved.id, icon);
        final restarted = await ConnectionManager.create(
          prefs,
          credentialStore: secrets,
        );
        final loaded = (await restarted.loadConnectionsWithSecrets()).single;
        expect(loaded.icon, icon);
        expect(loaded.copyWith(label: 'Renamed').icon, icon);
        expect(loaded.id, saved.id);
        expect(loaded.apiKey, saved.apiKey);
        expect(loaded.dashboardPassword, saved.dashboardPassword);
        expect(loaded.gatewayHeaders, saved.gatewayHeaders);
        final metadata = jsonDecode(
          prefs.getStringList('saved_connections')!.single,
        );
        expect(metadata['icon'], icon.name);
        expect(jsonEncode(metadata), isNot(contains('secret')));
      }
      expect(secrets.values, originalSecrets);
      expect(secrets.writes, writes);
    },
  );

  for (final replacement in [null, ConnectionIcon.star]) {
    test(
      'connection edit ${replacement == null ? 'preserves its selected icon' : 'applies an explicit icon replacement'}',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final manager = await ConnectionManager.create(
          prefs,
          credentialStore: _Secrets(),
        );
        final saved = await manager.saveConnection(
          'Claw',
          'https://hermes.example',
          443,
          '',
          icon: ConnectionIcon.cloud,
        );
        await manager.updateConnection(
          saved.id,
          'Renamed',
          saved.baseUrl,
          saved.port,
          saved.apiKey,
          icon: replacement,
        );
        expect(
          manager.getConnections().single.icon,
          replacement ?? ConnectionIcon.cloud,
        );
      },
    );
  }

  for (final mode in ConfigImportMode.values) {
    for (final passphrase in ['', 'test-passphrase']) {
      test(
        'icons export and restore with ${mode.name}, encrypted=${passphrase.isNotEmpty}',
        () async {
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final manager = await ConnectionManager.create(
            prefs,
            credentialStore: _Secrets(),
          );
          final owner = AppPreferences(prefs);
          addTearDown(owner.dispose);
          final service = ConfigBackupService(
            connectionManager: manager,
            appPreferences: owner,
          );
          final saved = await manager.saveConnection(
            'Claw',
            'https://hermes.example',
            443,
            'secret',
            icon: ConnectionIcon.rocket,
          );
          final backup = await service.export(appVersion: 'test');
          final encoded = await ConfigBackupCodec.encode(
            backup,
            passphrase: passphrase,
            iterations: 1000,
          );
          await manager.updateConnectionIcon(saved.id, ConnectionIcon.book);
          final other = await manager.saveConnection(
            'Other',
            'other.example',
            8642,
            '',
            icon: ConnectionIcon.home,
          );
          final decoded = await ConfigBackupCodec.decode(
            encoded,
            passphrase: passphrase,
          );
          await service.import(decoded, mode: mode, canCommit: () => true);
          final connections = manager.getConnections();
          expect(
            connections.firstWhere((c) => c.id == saved.id).icon,
            ConnectionIcon.rocket,
          );
          expect(
            connections.any((c) => c.id == other.id),
            mode == ConfigImportMode.merge,
          );
          if (mode == ConfigImportMode.merge) {
            expect(
              connections.firstWhere((c) => c.id == other.id).icon,
              ConnectionIcon.home,
            );
          }
          expect(
            (await manager.loadConnectionsWithSecrets())
                .firstWhere((c) => c.id == saved.id)
                .apiKey,
            'secret',
          );
        },
      );
    }
  }
}
