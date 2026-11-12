import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'connection_manager.dart';

/// A local, opaque identity for the exact endpoint and authentication settings.
/// Labels are presentation only. Passwords never enter preferences, journals,
/// or notification payloads, even as an unkeyed password-verification hash.
class ProfileConnectionIdentity {
  static const _keyName = 'profile_connection_identity_key_v1';
  static final _platform = ProfileConnectionIdentity._(
    FlutterSecureCredentialStore(),
  );
  final CredentialStore _store;
  List<int>? _key;
  Future<List<int>>? _loadingKey;

  factory ProfileConnectionIdentity({CredentialStore? credentialStore}) =>
      credentialStore == null
      ? _platform
      : ProfileConnectionIdentity._(credentialStore);

  ProfileConnectionIdentity._(this._store);

  Future<List<int>> _loadKey() async {
    try {
      var encoded = await _store.read(_keyName);
      if (encoded == null) {
        final random = Random.secure();
        encoded = base64Encode(List.generate(32, (_) => random.nextInt(256)));
        await _store.write(_keyName, encoded);
        if (await _store.read(_keyName) != encoded) {
          throw const FormatException();
        }
      }
      final bytes = base64Decode(encoded);
      if (bytes.length != 32) throw const FormatException();
      return bytes;
    } catch (_) {
      throw const CredentialStorageException(
        'Connection ownership could not be verified securely.',
      );
    }
  }

  Future<String> resolve(SavedConnection connection) async {
    final List<int> key;
    final cached = _key;
    if (cached != null) {
      key = cached;
    } else {
      final pending = _loadingKey ??= _loadKey();
      try {
        key = await pending;
        _key = key;
      } finally {
        // Keep only in-flight work: a settled Future retains its originating
        // execution zone, which can strand callers in a later widget lifecycle.
        if (identical(_loadingKey, pending)) _loadingKey = null;
      }
    }
    final settings = jsonEncode([
      connection.id,
      connection.host,
      connection.port,
      connection.useHttps,
      connection.dashboardPort,
      connection.gatewayPrefix ?? '',
      connection.dashboardPrefix ?? '',
      connection.dashboardProxied,
      connection.desktopGatewayUrl ?? '',
      connection.dashboardUsername ?? '',
      connection.dashboardPassword ?? '',
      connection.apiKey,
      if (connection.isCloud)
        [
          connection.cloudInstanceId,
          connection.cloudOrganization,
          connection.dashboardGrant?.id,
        ],
      if (connection.gatewayHeaders.isNotEmpty)
        canonicalGatewayHeaders(connection.gatewayHeaders),
    ]);
    return Hmac(sha256, key).convert(utf8.encode(settings)).toString();
  }
}
