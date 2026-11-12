import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/config_backup.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/models/config_backup_operation.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _RecordingPreferences extends InMemorySharedPreferencesStore {
  _RecordingPreferences()
    : super.withData({
        'flutter.verbose_mode': true,
        'flutter.theme_mode': 'dark',
      });

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

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    final value = values[key];
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

Future<(ConfigBackupService, ConnectionManager, SharedPreferences)>
buildService(Map<String, Object> initialPrefs) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(
    prefs,
    credentialStore: _MemoryCredentialStore(),
  );
  final owner = AppPreferences(prefs);
  addTearDown(owner.dispose);
  return (
    ConfigBackupService(connectionManager: manager, appPreferences: owner),
    manager,
    prefs,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConfigBackupService.export', () {
    test(
      'unsupported verbose input is omitted and skipped without settings writes',
      () async {
        SharedPreferences.resetStatic();
        final platform = _RecordingPreferences();
        SharedPreferencesStorePlatform.instance = platform;
        final storage = await SharedPreferences.getInstance();
        final manager = await ConnectionManager.create(
          storage,
          credentialStore: _MemoryCredentialStore(),
        );
        final owner = AppPreferences(storage);
        addTearDown(() {
          owner.dispose();
          SharedPreferences.setMockInitialValues({});
        });
        final service = ConfigBackupService(
          connectionManager: manager,
          appPreferences: owner,
        );
        final exported = await service.export(appVersion: 'fixture');
        expect(exported.preferences.containsKey('verbose_mode'), isFalse);
        platform.writes.clear();

        final result = await service.import(
          ConfigBackup(
            createdAt: DateTime.utc(2026, 10, 4),
            appVersion: 'fixture',
            connections: const [],
            preferences: const {'verbose_mode': false},
          ),
          mode: ConfigImportMode.merge,
          canCommit: () => true,
        );

        // Metadata persistence is owned by the manager; no settings write occurs.
        expect(
          platform.writes.where((key) => key != 'flutter.saved_connections'),
          isEmpty,
        );
        expect(storage.getBool('verbose_mode'), isTrue);
        expect(result.preferencesSkipped, 1);
        expect(result.preferencesApplied, 0);
      },
    );

    test('captures every saved connection with its secrets', () async {
      final (service, manager, _) = await buildService(<String, Object>{});
      await manager.saveConnection(
        'Miniserver',
        'https://carlos-miniserver.ts.net',
        8642,
        'sk-live-key',
        dashboardUsername: 'carlos',
        dashboardPassword: 'dash-pass',
        dashboardPort: 9119,
      );

      final backup = await service.export(appVersion: '2.0.1+2131');

      expect(backup.connections, hasLength(1));
      expect(backup.connections.single.label, 'Miniserver');
      expect(backup.connections.single.apiKey, 'sk-live-key');
      expect(backup.connections.single.dashboardPassword, 'dash-pass');
      expect(backup.appVersion, '2.0.1+2131');
    });

    test('captures user preferences that belong in a backup', () async {
      final (service, _, _) = await buildService(<String, Object>{
        'theme_mode': 'dark',
        AppPreferenceField.voiceInput.storageKey: 'local',
        'workspace_accent_v1': 'iris',
        'composer_running_action': 'queue',
        'web_link_destination': 'externalBrowser',
        'completion_notifications': false,
        'attention_notifications': true,
        'notification_message_previews': true,
        'app_text_size_preference': 'large',
        'voice.android_voice': 'fr-CH-x-fra',
        'session_search.abc.mode': 'ai',
      });

      final backup = await service.export(appVersion: 'test');

      expect(backup.preferences['theme_mode'], 'dark');
      expect(
        backup.preferences[AppPreferenceField.voiceInput.storageKey],
        'local',
      );
      expect(backup.preferences['workspace_accent_v1'], 'iris');
      expect(backup.preferences['composer_running_action'], 'queue');
      expect(backup.preferences['web_link_destination'], 'externalBrowser');
      expect(backup.preferences['completion_notifications'], false);
      expect(backup.preferences['attention_notifications'], true);
      expect(backup.preferences['notification_message_previews'], true);
      expect(backup.preferences['app_text_size_preference'], 'large');
      expect(backup.preferences['voice.android_voice'], 'fr-CH-x-fra');
      expect(
        backup.preferences.containsKey('session_search.abc.mode'),
        isFalse,
      );
    });

    test('never exports the raw connection list or transient state', () async {
      final (service, manager, prefs) = await buildService(<String, Object>{
        'last_connection_id': 'conn-9',
        'gateway_turn_journal_v2': 'huge-blob',
        'flutter.some_plugin_cache': 'noise',
      });
      await manager.saveConnection('L', 'host', 8642, 'k');

      final backup = await service.export(appVersion: 'test');

      // saved_connections is rebuilt from `connections`; re-importing the raw
      // list would resurrect stale metadata alongside it.
      expect(backup.preferences.containsKey('saved_connections'), isFalse);
      expect(backup.preferences.containsKey('last_connection_id'), isFalse);
      expect(
        backup.preferences.containsKey('gateway_turn_journal_v2'),
        isFalse,
      );
      expect(prefs.getStringList('saved_connections'), isNotNull);
    });
  });

  group('ConfigBackupService.import', () {
    test('restores connections and preferences onto a blank install', () async {
      final (source, sourceManager, _) = await buildService(<String, Object>{
        'theme_mode': 'dark',
        AppPreferenceField.voiceInput.storageKey: 'local',
        'workspace_accent_v1': 'iris',
        'composer_running_action': 'queue',
        'web_link_destination': 'externalBrowser',
        'completion_notifications': false,
        'attention_notifications': true,
        'notification_message_previews': true,
      });
      await sourceManager.saveConnection(
        'Miniserver',
        'https://carlos-miniserver.ts.net',
        8642,
        'sk-live-key',
        dashboardUsername: 'carlos',
        dashboardPassword: 'dash-pass',
      );
      final backup = await source.export(appVersion: 'test');

      final (target, targetManager, targetPrefs) = await buildService(
        <String, Object>{},
      );
      final result = await target.import(
        backup,
        mode: ConfigImportMode.merge,
        canCommit: () => true,
      );

      expect(result.connectionsAdded, 1);
      expect(result.connectionsUpdated, 0);
      expect(targetPrefs.getString('theme_mode'), 'dark');
      expect(
        targetPrefs.getString(AppPreferenceField.voiceInput.storageKey),
        'local',
      );
      expect(targetPrefs.getString('workspace_accent_v1'), 'iris');
      expect(targetPrefs.getString('composer_running_action'), 'queue');
      expect(targetPrefs.getString('web_link_destination'), 'externalBrowser');
      expect(targetPrefs.getBool('completion_notifications'), false);
      expect(targetPrefs.getBool('attention_notifications'), true);
      expect(targetPrefs.getBool('notification_message_previews'), true);

      final restored = await targetManager.loadConnectionsWithSecrets();
      expect(restored, hasLength(1));
      expect(restored.single.apiKey, 'sk-live-key');
      expect(restored.single.dashboardPassword, 'dash-pass');
      expect(restored.single.host, 'carlos-miniserver.ts.net');
      expect(restored.single.useHttps, isTrue);
    });

    test('merge updates a connection already present by id', () async {
      final (source, sourceManager, _) = await buildService(<String, Object>{});
      await sourceManager.saveConnection('New label', 'host', 8642, 'new-key');
      final backup = await source.export(appVersion: 'test');
      final importedId = backup.connections.single.id;

      final (target, targetManager, _) = await buildService(<String, Object>{});
      await targetManager.saveConnection('Old label', 'host', 8642, 'old-key');
      // Force an id collision the way a re-import onto the same device would.
      final existing = targetManager.getConnections().single;
      await targetManager.deleteConnection(existing.id);
      await targetManager.importConnections(
        [backup.connections.single.copyWith(label: 'Old label', apiKey: 'old')],
        replaceExisting: false,
        canCommit: () => true,
      );

      final result = await target.import(
        backup,
        mode: ConfigImportMode.merge,
        canCommit: () => true,
      );

      expect(result.connectionsAdded, 0);
      expect(result.connectionsUpdated, 1);
      final restored = await targetManager.loadConnectionsWithSecrets();
      expect(restored, hasLength(1));
      expect(restored.single.id, importedId);
      expect(restored.single.label, 'New label');
      expect(restored.single.apiKey, 'new-key');
    });

    test('merge keeps connections that are not in the backup', () async {
      final (source, sourceManager, _) = await buildService(<String, Object>{});
      await sourceManager.saveConnection('Imported', 'a', 8642, 'k1');
      final backup = await source.export(appVersion: 'test');

      final (target, targetManager, _) = await buildService(<String, Object>{});
      await targetManager.saveConnection('Local only', 'b', 8642, 'k2');

      await target.import(
        backup,
        mode: ConfigImportMode.merge,
        canCommit: () => true,
      );

      final labels = targetManager
          .getConnections()
          .map((connection) => connection.label)
          .toList();
      expect(labels, containsAll(<String>['Imported', 'Local only']));
      expect(labels, hasLength(2));
    });

    test('replace drops connections that are not in the backup', () async {
      final (source, sourceManager, _) = await buildService(<String, Object>{});
      await sourceManager.saveConnection('Imported', 'a', 8642, 'k1');
      final backup = await source.export(appVersion: 'test');

      final (target, targetManager, _) = await buildService(<String, Object>{});
      await targetManager.saveConnection('Local only', 'b', 8642, 'k2');

      final result = await target.import(
        backup,
        mode: ConfigImportMode.replace,
        canCommit: () => true,
      );

      expect(result.connectionsRemoved, 1);
      final restored = await targetManager.loadConnectionsWithSecrets();
      expect(restored, hasLength(1));
      expect(restored.single.label, 'Imported');
      expect(restored.single.apiKey, 'k1');
    });

    test('never writes a preference key the app does not own', () async {
      final backup = ConfigBackup(
        createdAt: DateTime.utc(2026),
        appVersion: 'test',
        connections: const <SavedConnection>[],
        preferences: const <String, Object>{
          'theme_mode': 'dark',
          'saved_connections': 'hostile',
          'gateway_turn_journal_v2': 'hostile',
          'totally_unknown_key': 'hostile',
        },
      );

      final (service, _, prefs) = await buildService(<String, Object>{});
      final result = await service.import(
        backup,
        mode: ConfigImportMode.merge,
        canCommit: () => true,
      );

      expect(prefs.getString('theme_mode'), 'dark');
      // saved_connections is owned by ConnectionManager. It may legitimately be
      // rewritten by the import, but never with the hostile payload.
      expect(prefs.get('saved_connections'), isNot(contains('hostile')));
      expect(prefs.get('gateway_turn_journal_v2'), isNull);
      expect(prefs.get('totally_unknown_key'), isNull);
      expect(result.preferencesSkipped, 3);
      expect(result.preferencesApplied, 1);
    });

    test(
      'rejects invalid voice choices and device permission markers',
      () async {
        final backup = ConfigBackup(
          createdAt: DateTime.utc(2026),
          appVersion: 'test',
          connections: const <SavedConnection>[],
          preferences: const <String, Object>{
            'voice.input': 'unknown',
            'voice.output': 'hermes',
            'voice.android_voice': true,
            'voice.android_rate': '99',
            'microphone_permission_requested': true,
          },
        );
        final (service, _, prefs) = await buildService(<String, Object>{});
        final result = await service.import(
          backup,
          mode: ConfigImportMode.merge,
          canCommit: () => true,
        );
        expect(prefs.getString('voice.output'), 'hermes');
        expect(prefs.get('voice.input'), isNull);
        expect(prefs.get('voice.android_voice'), isNull);
        expect(prefs.get('voice.android_rate'), isNull);
        expect(prefs.get('microphone_permission_requested'), isNull);
        expect(result.preferencesSkipped, 4);
        expect(result.preferencesApplied, 1);
      },
    );

    test('survives a full export → import → export round trip', () async {
      final (source, sourceManager, _) = await buildService(<String, Object>{
        'theme_mode': 'dark',
        'app_text_size_preference': 'large',
      });
      await sourceManager.saveConnection(
        'Miniserver',
        'https://host.ts.net',
        8642,
        'sk-key',
        dashboardPassword: 'dash',
      );
      final original = await source.export(appVersion: 'test');

      final (target, _, _) = await buildService(<String, Object>{});
      await target.import(
        original,
        mode: ConfigImportMode.replace,
        canCommit: () => true,
      );
      final reexported = await target.export(appVersion: 'test');

      expect(reexported.connections.single.apiKey, 'sk-key');
      expect(reexported.connections.single.dashboardPassword, 'dash');
      expect(reexported.connections.single.id, original.connections.single.id);
      expect(reexported.preferences['theme_mode'], 'dark');
      expect(reexported.preferences['app_text_size_preference'], 'large');
    });
  });
}
