import 'package:wing/core/models/dashboard_oauth_grant.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/config_backup.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/models/config_backup_operation.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/models/session_visibility.dart';

class _Store implements CredentialStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

Future<
  (
    SharedPreferences,
    ConnectionManager,
    ProfileConnectionIdentity,
    ConfigBackupService,
    AppPreferences,
  )
>
_device() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = _Store();
  final manager = await ConnectionManager.create(prefs, credentialStore: store);
  final identities = ProfileConnectionIdentity(credentialStore: store);
  final owner = AppPreferences(prefs);
  addTearDown(owner.dispose);
  return (
    prefs,
    manager,
    identities,
    ConfigBackupService(connectionManager: manager, appPreferences: owner),
    owner,
  );
}

ConfigBackup _backup(Map<String, Object> settings) => ConfigBackup(
  createdAt: DateTime.utc(2026, 9, 30),
  appVersion: 'synthetic',
  connections: [],
  preferences: settings,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'known settings reject wrong types and enum values without poisoning reads',
    () async {
      final (prefs, _, _, service, owner) = await _device();
      await owner.setTheme(AppThemePreference.light);
      final settings = <String, Object>{
        'theme_mode': 42,
        'app_text_size_preference': 1.15,
        'workspace_accent_v1': 'unknown',
        'composer_running_action': 'send',
        'verbose_mode': 'true',
        'completion_notifications': 1,
        'attention_notifications': 'false',
        'notification_message_previews': <String>[],
        'voice.android_rate': '99',
        'voice.android_voice': true,
      };
      final result = await service.import(
        _backup(settings),
        mode: ConfigImportMode.merge,
        canCommit: () => true,
      );
      expect(result.preferencesApplied, 0);
      expect(result.preferencesSkipped, settings.length);
      expect(result.summary, contains('${settings.length} settings skipped'));
      expect(prefs.getString('theme_mode'), 'light');
      expect(prefs.getString('app_text_size_preference'), isNull);
      expect(prefs.getBool('completion_notifications'), isNull);
      expect(prefs.getString('voice.android_voice'), isNull);
    },
  );

  test(
    'visibility round trip remaps separate device identities without exporting keys',
    () async {
      final (sourcePrefs, sourceManager, sourceIds, source, sourceOwner) =
          await _device();
      final connection = await sourceManager.saveConnection(
        'Synthetic',
        'localhost',
        8642,
        'synthetic-key',
      );
      final sourceIdentity = await sourceIds.resolve(connection);
      await sourceOwner.setConnectionVisibility(
        connection.id,
        SessionVisibility.all,
      );
      final encoded = await ConfigBackupCodec.encode(
        await source.export(appVersion: 'synthetic'),
        passphrase: '',
      );
      expect(encoded, isNot(contains(sourceIdentity)));
      expect(encoded, isNot(contains('profile_connection_identity_key')));
      final restored = await ConfigBackupCodec.decode(encoded, passphrase: '');
      expect(
        restored.preferences['connection_visibility.${connection.id}'],
        'all',
      );

      final (targetPrefs, targetManager, targetIds, target, _) =
          await _device();
      final result = await target.import(
        restored,
        mode: ConfigImportMode.merge,
        canCommit: () => true,
      );
      final targetConnection =
          (await targetManager.loadConnectionsWithSecrets()).single;
      final targetIdentity = await targetIds.resolve(targetConnection);
      expect(targetIdentity, isNot(sourceIdentity));
      expect(
        targetPrefs.getString(
          SessionVisibility.preferenceKey(targetConnection.id),
        ),
        'all',
      );
      expect(targetPrefs.get('session_visibility_v1_$sourceIdentity'), isNull);
      expect(result.preferencesApplied, 1);
      expect(
        (await target.export(appVersion: 'synthetic')).preferences,
        restored.preferences,
      );
    },
  );

  test('unowned or invalid portable visibility settings are skipped', () async {
    final (prefs, _, _, service, _) = await _device();
    final result = await service.import(
      _backup({
        'connection_visibility.absent': 'all',
        'session_visibility_v1_forged-device-identity': 'all',
        'theme_mode': 'dark',
      }),
      mode: ConfigImportMode.merge,
      canCommit: () => true,
    );
    expect(result.preferencesApplied, 1);
    expect(result.preferencesSkipped, 2);
    expect(
      prefs.getKeys().where((key) => key.startsWith('session_visibility')),
      isEmpty,
    );
  });

  test(
    'restored cloud visibility survives first sign-in and reauthentication',
    () async {
      final (_, manager, identities, service, owner) = await _device();
      final cloud = await manager.saveConnection(
        'Cloud',
        'https://cloud.example',
        443,
        '',
        cloudInstanceId: 'instance',
        cloudOrganization: 'team',
      );
      await service.import(
        ConfigBackup(
          createdAt: DateTime.utc(2026, 9, 30),
          appVersion: 'synthetic',
          connections: [cloud],
          preferences: {'connection_visibility.${cloud.id}': 'all'},
        ),
        mode: ConfigImportMode.merge,
        canCommit: () => true,
      );
      final originalIdentity = await identities.resolve(
        manager.getConnections().single,
      );
      for (final grant in ['first-sign-in', 'new-sign-in']) {
        await manager.updateConnection(
          cloud.id,
          'Cloud',
          'https://cloud.example',
          443,
          '',
          cloudInstanceId: 'instance',
          cloudOrganization: 'team',
          dashboardGrant: DashboardOAuthGrant(
            id: grant,
            baseUrl: 'https://cloud.example:443',
            accessToken: 'synthetic-access',
            refreshToken: 'synthetic-refresh',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        );
        expect(
          await identities.resolve(manager.getConnections().single),
          isNot(originalIdentity),
        );
        expect(owner.visibilityFor(cloud.id).selected, SessionVisibility.all);
        expect((await service.export(appVersion: 'synthetic')).preferences, {
          'connection_visibility.${cloud.id}': 'all',
        });
      }
    },
  );

  test('unsupported backup version has no migration fallback', () async {
    final json = _backup({}).toJson()..['version'] = 1;
    await expectLater(
      ConfigBackupCodec.decode(jsonEncode(json), passphrase: ''),
      throwsA(isA<ConfigBackupException>()),
    );
  });

  test('codec bounds raw input before parsing and bounds structures', () async {
    await expectLater(
      ConfigBackupCodec.decode(
        ' ' * (ConfigBackupLimits.maxBytes + 1),
        passphrase: '',
      ),
      throwsA(isA<ConfigBackupException>()),
    );
    final json = _backup({}).toJson();
    json['preferences'] = {
      for (var i = 0; i <= ConfigBackupLimits.maxPreferences; i++)
        'key$i': {'type': 'string', 'value': 'x'},
    };
    await expectLater(
      ConfigBackupCodec.decode(jsonEncode(json), passphrase: ''),
      throwsA(isA<ConfigBackupException>()),
    );
  });

  test(
    'stream intake counts bytes and cancels immediately over the limit',
    () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final reading = ConfigBackupIo.readBackupStream(stream.stream);
      final rejected = expectLater(
        reading,
        throwsA(isA<ConfigBackupException>()),
      );
      stream.add(List.filled(ConfigBackupLimits.maxBytes, 32));
      stream.add([32]);
      await rejected;
      expect(cancelled, isTrue);
      await stream.close();
    },
  );

  test(
    'stream intake accepts exact limit and rejects malformed UTF-8',
    () async {
      final text = await ConfigBackupIo.readBackupStream(
        Stream.value(List.filled(ConfigBackupLimits.maxBytes, 32)),
      );
      expect(text.length, ConfigBackupLimits.maxBytes);
      await expectLater(
        ConfigBackupIo.readBackupStream(Stream.value([0xff])),
        throwsA(isA<ConfigBackupException>()),
      );
    },
  );
}
