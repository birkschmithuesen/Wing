import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/services/config_backup.dart';

Map<String, dynamic> _canonical() => ConfigBackup(
  createdAt: DateTime.utc(2026, 10, 4, 12, 30),
  appVersion: 'fixture',
  connections: [
    SavedConnection(
      id: 'fixture-connection',
      label: 'Fixture',
      host: '127.0.0.1',
      port: 8642,
      apiKey: '',
    ),
  ],
  preferences: const {},
).toJson();

Map<String, dynamic> _connection(Map<String, dynamic> json) =>
    (json['connections'] as List).single as Map<String, dynamic>;

void main() {
  for (final encrypted in [false, true]) {
    test(
      'current writer ${encrypted ? 'encrypted' : 'plain'} payload decodes',
      () async {
        final original = ConfigBackup.fromJson(_canonical());
        final passphrase = encrypted ? 'fixture-encryption' : '';
        final contents = await ConfigBackupCodec.encode(
          original,
          passphrase: passphrase,
          iterations: 1000,
        );
        final restored = await ConfigBackupCodec.decode(
          contents,
          passphrase: passphrase,
        );
        expect(restored.toJson(), original.toJson());
        // Nullable settings are explicit current fields, not omitted defaults.
        expect(_connection(restored.toJson())['dashboard_password'], isNull);
        expect(
          _connection(restored.toJson()).containsKey('dashboard_password'),
          isTrue,
        );
      },
    );
  }

  for (final key in [
    'format',
    'version',
    'created_at',
    'app_version',
    'connections',
    'preferences',
  ]) {
    test('version 2 rejects missing required top-level $key', () async {
      final json = _canonical()..remove(key);
      await expectLater(
        ConfigBackupCodec.decode(jsonEncode(json), passphrase: ''),
        throwsA(isA<ConfigBackupException>()),
      );
    });
  }

  for (final key in [
    'id',
    'label',
    'icon',
    'host',
    'port',
    'api_key',
    'use_https',
    'gateway_prefix',
    'dashboard_prefix',
    'dashboard_proxied',
    'desktop_gateway_url',
    'dashboard_port',
    'dashboard_username',
    'dashboard_password',
    'gateway_headers',
  ]) {
    test('version 2 rejects missing required connection $key', () async {
      final json = _canonical();
      _connection(json).remove(key);
      await expectLater(
        ConfigBackupCodec.decode(jsonEncode(json), passphrase: ''),
        throwsA(isA<ConfigBackupException>()),
      );
    });
  }

  final invalidMetadata = <(String, Object?)>[
    ('version', 2.0),
    ('created_at', null),
    ('created_at', ''),
    ('created_at', 'not-a-date'),
    ('app_version', null),
    ('preferences', null),
  ];
  for (var index = 0; index < invalidMetadata.length; index++) {
    final (key, value) = invalidMetadata[index];
    test(
      'version 2 rejects invalid required metadata case $index ($key)',
      () async {
        final json = _canonical()..[key] = value;
        await expectLater(
          ConfigBackupCodec.decode(jsonEncode(json), passphrase: ''),
          throwsA(isA<ConfigBackupException>()),
        );
      },
    );
  }

  final invalidConnection = <(String, Object?)>[
    ('dashboard_proxied', null),
    ('gateway_headers', null),
    ('dashboard_port', 0),
    ('dashboard_port', 65536),
  ];
  for (var index = 0; index < invalidConnection.length; index++) {
    final (key, value) = invalidConnection[index];
    test(
      'version 2 rejects invalid connection settings case $index ($key)',
      () async {
        final json = _canonical();
        _connection(json)[key] = value;
        await expectLater(
          ConfigBackupCodec.decode(jsonEncode(json), passphrase: ''),
          throwsA(isA<ConfigBackupException>()),
        );
      },
    );
  }
}
