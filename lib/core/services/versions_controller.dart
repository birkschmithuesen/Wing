import 'package:flutter/foundation.dart';

import 'connection_access.dart';
import '../models/hermes_profile.dart';
import 'backend_update_controller.dart';
import 'profile_gateway.dart';

typedef VersionsControllerFactory =
    VersionsController Function(ConnectionAccess? access);

/// Installed version and updates for one captured server connection.
class VersionsController extends ChangeNotifier {
  VersionsController({ProfileGateway? gateway, bool cloudManaged = false})
    : server = gateway == null
          ? null
          : BackendUpdateController(gateway, cloudManaged: cloudManaged) {
    server?.addListener(notifyListeners);
  }

  factory VersionsController.forConnection(ConnectionAccess? access) =>
      VersionsController(
        cloudManaged: access?.connection.cloudManagedUpdates == true,
        gateway: access == null
            ? null
            : ProfileGateway.forConnection(
                access,
                WorkspaceScope(
                  connectionId: access.connection.id,
                  profileName: 'default',
                ),
              ),
      );

  final BackendUpdateController? server;
  Future<void> refresh() async {
    await server?.checkForUpdate();
  }

  @override
  void dispose() {
    server?.removeListener(notifyListeners);
    server?.dispose();
    server?.gateway.close();
    super.dispose();
  }
}
