import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/services/connection_manager.dart';

/// One push device id per Wing install (contract §3.2), kept in secure storage
/// outside the connection namespace.
class PorterDeviceIdStore {
  PorterDeviceIdStore({CredentialStore? store})
    : _store = store ??
          FlutterSecureCredentialStore(
            storage: const FlutterSecureStorage(
              aOptions: AndroidOptions(
                resetOnError: false,
                storageNamespace: 'wing_porter_wake',
              ),
            ),
          );

  static const key = 'porter_wake_device_id_v1';
  final CredentialStore _store;

  Future<String> read() async {
    final existing = await _store.read(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final hex = [
      for (var i = 0; i < 8; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final id = 'wing-$hex';
    await _store.write(key, id);
    return id;
  }
}
