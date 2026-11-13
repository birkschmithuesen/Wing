import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/connection.dart';

/// Raised for every backup failure. The message is intentionally generic and
/// never carries platform errors or secret material, so it can be surfaced
/// directly in the UI.
class ConfigBackupException implements Exception {
  final String message;

  const ConfigBackupException(this.message);

  @override
  String toString() => message;
}

/// Shared bounds for file intake, plaintext and encrypted backup envelopes.
class ConfigBackupLimits {
  static const maxBytes = 2 * 1024 * 1024;
  static const maxConnections = 256;
  static const maxPreferences = 2048;
  static const maxStringLength = 64 * 1024;

  static void checkText(String value) {
    if (value.length > maxBytes || utf8.encode(value).length > maxBytes) {
      throw const ConfigBackupException('This backup exceeds the 2 MiB limit.');
    }
  }

  static void checkStructure(Object? value, [int depth = 0]) {
    if (depth > 12 ||
        value is String && value.length > maxStringLength ||
        value is List && value.length > maxPreferences ||
        value is Map && value.length > maxPreferences) {
      throw const ConfigBackupException('This backup exceeds its data limits.');
    }
    if (value is Map) {
      for (final entry in value.entries) {
        checkStructure(entry.key, depth + 1);
        checkStructure(entry.value, depth + 1);
      }
    } else if (value is List) {
      for (final item in value) {
        checkStructure(item, depth + 1);
      }
    }
  }
}

/// A complete, portable snapshot of what the user configured on this device:
/// every saved connection (including its secrets) plus the non-secret app
/// preferences.
///
/// [ConfigBackupCodec] encrypts exports when a passphrase is supplied, or
/// writes plain JSON when the user chooses to leave it empty.
class ConfigBackup {
  static const String format = 'wing-config';
  static const int currentVersion = 2;

  final DateTime createdAt;
  final String appVersion;
  final List<SavedConnection> connections;
  final Map<String, Object> preferences;

  ConfigBackup({
    required this.createdAt,
    required this.appVersion,
    required this.connections,
    required this.preferences,
  });

  Map<String, dynamic> toJson() {
    if (connections.length > ConfigBackupLimits.maxConnections ||
        preferences.length > ConfigBackupLimits.maxPreferences) {
      throw const ConfigBackupException('This backup exceeds its data limits.');
    }
    ConfigBackupLimits.checkStructure(preferences);
    return <String, dynamic>{
      'format': format,
      'version': currentVersion,
      'created_at': createdAt.toUtc().toIso8601String(),
      'app_version': appVersion,
      'connections': connections.map(_connectionToJson).toList(),
      'preferences': preferences.map(
        (key, value) => MapEntry(key, _preferenceToJson(value)),
      ),
    };
  }

  factory ConfigBackup.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format) {
      throw const ConfigBackupException(
        'This file is not a Wing configuration backup.',
      );
    }
    final version = json['version'];
    if (version is! int || version != currentVersion) {
      throw const ConfigBackupException(
        'This backup uses an unsupported format version. Export a new backup '
        'using the current app.',
      );
    }

    try {
      ConfigBackupLimits.checkStructure(json);
      const requiredFields = {
        'format',
        'version',
        'created_at',
        'app_version',
        'connections',
        'preferences',
      };
      if (!requiredFields.every(json.containsKey)) {
        throw const ConfigBackupException('Missing required backup settings.');
      }
      final createdAtText = json['created_at'] as String;
      final createdAt = DateTime.tryParse(createdAtText);
      if (createdAt == null ||
          createdAt.toUtc().toIso8601String() != createdAtText) {
        throw const ConfigBackupException('Invalid backup creation date.');
      }
      final appVersion = json['app_version'] as String;
      final rawConnections = json['connections'] as List<dynamic>;
      final rawPreferences = json['preferences'] as Map<String, dynamic>;
      if (rawConnections.length > ConfigBackupLimits.maxConnections ||
          rawPreferences.length > ConfigBackupLimits.maxPreferences) {
        throw const ConfigBackupException(
          'This backup exceeds its data limits.',
        );
      }
      final connections = rawConnections
          .map((entry) => _connectionFromJson(entry as Map<String, dynamic>))
          .toList();
      if (connections.any((c) => c.id.isEmpty) ||
          connections.map((c) => c.id).toSet().length != connections.length) {
        throw const ConfigBackupException(
          'Backup connection IDs must be unique.',
        );
      }

      return ConfigBackup(
        createdAt: createdAt.toUtc(),
        appVersion: appVersion,
        connections: connections,
        preferences: rawPreferences.map(
          (key, value) =>
              MapEntry(key, _preferenceFromJson(value as Map<String, dynamic>)),
        ),
      );
    } on ConfigBackupException {
      rethrow;
    } catch (_) {
      throw const ConfigBackupException(
        'This backup file is damaged and could not be read.',
      );
    }
  }

  static Map<String, dynamic> _connectionToJson(SavedConnection connection) {
    return <String, dynamic>{
      'id': connection.id,
      'label': connection.label,
      'icon': connection.icon.name,
      'host': connection.host,
      'port': connection.port,
      'api_key': connection.apiKey,
      'use_https': connection.useHttps,
      'gateway_prefix': connection.gatewayPrefix,
      'dashboard_prefix': connection.dashboardPrefix,
      'dashboard_proxied': connection.dashboardProxied,
      'desktop_gateway_url': connection.desktopGatewayUrl,
      'dashboard_port': connection.dashboardPortOverride,
      'dashboard_username': connection.dashboardUsername,
      'dashboard_password': connection.dashboardPassword,
      'gateway_headers': connection.gatewayHeaders,
      // Browser identity and rotating grants stay on this device. Restore requires sign-in.
      if (connection.isCloud) 'cloud_instance_id': connection.cloudInstanceId,
      if (connection.cloudOrganization != null)
        'cloud_organization': connection.cloudOrganization,
    };
  }

  static SavedConnection _connectionFromJson(Map<String, dynamic> map) {
    const requiredFields = {
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
    };
    final dashboardPort = map['dashboard_port'];
    if (!requiredFields.every(map.containsKey) ||
        map['icon'] is! String ||
        map['port'] is! int ||
        (map['port'] as int) < 1 ||
        (map['port'] as int) > 65535 ||
        map['use_https'] is! bool ||
        map['dashboard_proxied'] is! bool ||
        map['api_key'] is! String ||
        map['gateway_headers'] is! Map ||
        dashboardPort != null &&
            (dashboardPort is! int ||
                dashboardPort < 1 ||
                dashboardPort > 65535) ||
        map.containsKey('cloud_instance_id') &&
            map['cloud_instance_id'] is! String ||
        map.containsKey('cloud_organization') &&
            map['cloud_organization'] is! String) {
      throw const ConfigBackupException('Invalid backup connection settings.');
    }
    return SavedConnection(
      id: map['id'] as String,
      cloudInstanceId: map['cloud_instance_id'] as String?,
      cloudOrganization: map['cloud_organization'] as String?,
      label: map['label'] as String,
      icon: ConnectionIcon.fromStored(map['icon']),
      host: map['host'] as String,
      port: map['port'] as int,
      apiKey: map['api_key'] as String,
      useHttps: map['use_https'] as bool,
      gatewayPrefix: map['gateway_prefix'] as String?,
      dashboardPrefix: map['dashboard_prefix'] as String?,
      dashboardProxied: map['dashboard_proxied'] as bool,
      desktopGatewayUrl: map['desktop_gateway_url'] as String?,
      dashboardPortOverride: map['dashboard_port'] as int?,
      dashboardUsername: map['dashboard_username'] as String?,
      // Password bytes are credentials, including empty or surrounding space.
      dashboardPassword: map['dashboard_password'] as String?,
      gatewayHeaders: Map<String, String>.from(map['gateway_headers'] as Map),
    );
  }

  /// Preferences are tagged with their runtime type. Without the tag a Dart
  /// `int` would come back as a `double` (or vice versa) after the JSON round
  /// trip and `SharedPreferences` would then reject the write.
  static Map<String, dynamic> _preferenceToJson(Object value) {
    if (value is bool) {
      return <String, dynamic>{'type': 'bool', 'value': value};
    }
    if (value is int) {
      return <String, dynamic>{'type': 'int', 'value': value};
    }
    if (value is double) {
      return <String, dynamic>{'type': 'double', 'value': value};
    }
    if (value is String) {
      return <String, dynamic>{'type': 'string', 'value': value};
    }
    if (value is List<String>) {
      return <String, dynamic>{'type': 'string_list', 'value': value};
    }
    throw const ConfigBackupException(
      'A saved preference has an unsupported type and cannot be exported.',
    );
  }

  static Object _preferenceFromJson(Map<String, dynamic> entry) {
    final type = entry['type'];
    final value = entry['value'];
    switch (type) {
      case 'bool':
        if (value is bool) return value;
        break;
      case 'int':
        if (value is int) return value;
        break;
      case 'double':
        if (value is num) return value.toDouble();
        break;
      case 'string':
        if (value is String) return value;
        break;
      case 'string_list':
        if (value is List) {
          return value.map((item) => item as String).toList();
        }
        break;
    }
    throw const ConfigBackupException(
      'This backup file is damaged and could not be read.',
    );
  }
}

/// Encodes and decodes backups with optional passphrase protection.
///
/// With a passphrase, PBKDF2-HMAC-SHA256 derives an encryption key, and
/// AES-256-GCM provides confidentiality plus authentication. A tampered file
/// fails the MAC check and is rejected instead of being partially imported.
class ConfigBackupCodec {
  static const String envelopeFormat = 'wing-config-encrypted';
  static const int envelopeVersion = 1;
  static const int defaultIterations = 210000;
  static const int _maxIterations = 2000000;
  static const int _saltLength = 16;
  static const int _nonceLength = 12;

  static final Random _random = Random.secure();

  static Future<String> encode(
    ConfigBackup backup, {
    required String passphrase,
    int iterations = defaultIterations,
  }) async {
    final json = backup.toJson();
    ConfigBackupLimits.checkStructure(json);
    final contents = jsonEncode(json);
    ConfigBackupLimits.checkText(contents);
    if (passphrase.isEmpty) return contents;
    if (passphrase.trim().isEmpty) {
      throw const ConfigBackupException(
        'Choose a passphrase — the backup contains your API keys.',
      );
    }
    if (iterations < 1 || iterations > _maxIterations) {
      throw const ConfigBackupException(
        'The backup could not be protected safely.',
      );
    }

    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    final secretKey = await _deriveKey(passphrase, salt, iterations);
    final plaintext = utf8.encode(contents);

    final SecretBox box;
    try {
      box = await AesGcm.with256bits().encrypt(
        plaintext,
        secretKey: secretKey,
        nonce: nonce,
      );
    } catch (_) {
      throw const ConfigBackupException(
        'The backup could not be protected safely.',
      );
    }

    final envelope = jsonEncode(<String, dynamic>{
      'format': envelopeFormat,
      'version': envelopeVersion,
      'kdf': <String, dynamic>{
        'algorithm': 'pbkdf2-hmac-sha256',
        'iterations': iterations,
        'salt': base64Encode(salt),
      },
      'cipher': <String, dynamic>{
        'algorithm': 'aes-256-gcm',
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      },
    });
    ConfigBackupLimits.checkText(envelope);
    return envelope;
  }

  static Future<ConfigBackup> decode(
    String armored, {
    required String passphrase,
  }) async {
    ConfigBackupLimits.checkText(armored);
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(armored) as Map<String, dynamic>;
    } catch (_) {
      throw const ConfigBackupException(
        'This file is not a Wing configuration backup.',
      );
    }

    if (envelope['format'] == ConfigBackup.format) {
      return ConfigBackup.fromJson(envelope);
    }
    if (envelope['format'] != envelopeFormat) {
      throw const ConfigBackupException(
        'This file is not a Wing configuration backup.',
      );
    }
    if (passphrase.isEmpty) {
      throw const ConfigBackupException(
        'Enter the passphrase for this encrypted backup.',
      );
    }
    final version = envelope['version'];
    if (version != envelopeVersion) {
      throw const ConfigBackupException(
        'This backup was made by a newer version of the app and cannot be '
        'imported.',
      );
    }

    final int iterations;
    final List<int> salt;
    final List<int> nonce;
    final List<int> ciphertext;
    final List<int> mac;
    try {
      final kdf = envelope['kdf'] as Map<String, dynamic>;
      final cipher = envelope['cipher'] as Map<String, dynamic>;
      if (kdf['algorithm'] != 'pbkdf2-hmac-sha256' ||
          cipher['algorithm'] != 'aes-256-gcm') {
        throw const ConfigBackupException(
          'This backup uses an unsupported encryption scheme.',
        );
      }
      iterations = kdf['iterations'] as int;
      if ((kdf['salt'] as String).length != 24 ||
          (cipher['nonce'] as String).length != 16 ||
          (cipher['mac'] as String).length != 24 ||
          (cipher['ciphertext'] as String).length >
              ConfigBackupLimits.maxBytes) {
        throw const ConfigBackupException('Invalid encrypted backup data.');
      }
      salt = base64Decode(kdf['salt'] as String);
      nonce = base64Decode(cipher['nonce'] as String);
      ciphertext = base64Decode(cipher['ciphertext'] as String);
      mac = base64Decode(cipher['mac'] as String);
      if (salt.length != _saltLength ||
          nonce.length != _nonceLength ||
          mac.length != 16) {
        throw const ConfigBackupException('Invalid encrypted backup data.');
      }
    } on ConfigBackupException {
      rethrow;
    } catch (_) {
      throw const ConfigBackupException(
        'This backup file is damaged and could not be read.',
      );
    }

    // An untrusted file must never be able to pin the UI thread by asking for
    // an unbounded amount of key-stretching work.
    if (iterations < 1 || iterations > _maxIterations) {
      throw const ConfigBackupException(
        'This backup file is damaged and could not be read.',
      );
    }

    final secretKey = await _deriveKey(passphrase, salt, iterations);

    final List<int> plaintext;
    try {
      plaintext = await AesGcm.with256bits().decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: secretKey,
      );
    } catch (_) {
      // Wrong passphrase and tampered ciphertext are indistinguishable here by
      // design — both fail the GCM authentication tag.
      throw const ConfigBackupException(
        'Wrong passphrase, or this backup file has been altered.',
      );
    }

    try {
      return ConfigBackup.fromJson(
        jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>,
      );
    } on ConfigBackupException {
      rethrow;
    } catch (_) {
      throw const ConfigBackupException(
        'This backup file is damaged and could not be read.',
      );
    }
  }

  static Future<SecretKey> _deriveKey(
    String passphrase,
    List<int> salt,
    int iterations,
  ) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  static Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }
}
