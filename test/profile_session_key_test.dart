import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';

void main() {
  test('session identity preserves the durable ownership fields', () {
    final key = ProfileSessionKey(
      WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: 'captured-host-access',
        profileName: 'work',
      ),
      'shared-id',
    );
    const persisted = {
      'connection': 'host',
      'connection_identity': 'captured-host-access',
      'profile': 'work',
      'session': 'shared-id',
    };
    expect(key.toJson(), persisted);
    final restored = ProfileSessionKey.fromJson(persisted);
    expect(restored, key);
    expect(restored.hashCode, key.hashCode);
    expect(restored.workspace.storageNamespace, key.workspace.storageNamespace);
  });

  test('the same server row ID cannot collapse distinct captured owners', () {
    ProfileSessionKey key(String profile, String identity) => ProfileSessionKey(
      WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: identity,
        profileName: profile,
      ),
      'shared-id',
    );
    expect({
      key('work', 'first-access'),
      key('personal', 'first-access'),
      key('work', 'second-access'),
      key('work', 'first-access'),
    }, hasLength(3));
  });
}
