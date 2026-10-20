import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/porter_wake/porter_wake_device_id.dart';

/// Shared with the module and settings tests.
class MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  @override
  String? readCached(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('the device id is created once, matches the contract and stays stable', () async {
    final memory = MemoryCredentialStore();
    final first = await PorterDeviceIdStore(store: memory).read();
    final again = await PorterDeviceIdStore(store: memory).read();
    expect(first, matches(RegExp(r'^wing-[0-9a-f]{16}$')));
    expect(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(first), isTrue);
    expect(again, first);
    expect(memory.values[PorterDeviceIdStore.key], first);
  });

  test('two installs get different ids', () async {
    final a = await PorterDeviceIdStore(store: MemoryCredentialStore()).read();
    final b = await PorterDeviceIdStore(store: MemoryCredentialStore()).read();
    expect(a, isNot(b));
  });
}
