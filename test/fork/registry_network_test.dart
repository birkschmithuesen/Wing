import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';

import '../profile_connection_identity_test.dart'
    show MemoryIdentityStore, identityTestConnection;
import '../profile_workspace_controller_test.dart' show Host;

void main() {
  late SharedPreferences prefs;
  late AppPreferences appPreferences;
  late MemoryIdentityStore secrets;
  late ProfileWorkspaceRegistry registry;
  late Map<String, Host> hosts;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(prefs);
    secrets = MemoryIdentityStore();
    hosts = {};
    registry = ProfileWorkspaceRegistry(
      identities: ProfileConnectionIdentity(credentialStore: secrets),
      create: (connection, identity) => ProfileWorkspaceController(
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        connectionIdentity: identity,
        preferences: prefs,
        appPreferences: appPreferences,
        gatewayFactory: (hosts[identity] = Host()).gateway,
      ),
    );
  });
  tearDown(() {
    registry.dispose();
    appPreferences.dispose();
  });

  test(
    'recoverConnections clears the device network flag before any reconnect attempt',
    () async {
      final owner = await registry.forConnection(identityTestConnection());
      registry.networkUnavailable();
      expect(owner.connectionStatus.networkAvailable, isFalse);
      registry.recoverConnections();
      expect(owner.connectionStatus.networkAvailable, isTrue);
    },
  );

  test(
    'resumeConnections (foreground entry) does not lift the device network gate',
    () async {
      final owner = await registry.forConnection(identityTestConnection());
      registry.networkUnavailable();
      expect(owner.connectionStatus.networkAvailable, isFalse);
      registry.resumeConnections();
      expect(owner.connectionStatus.networkAvailable, isFalse);
    },
  );
}
