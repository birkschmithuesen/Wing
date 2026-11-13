import '../models/connection.dart';
import 'dashboard_oauth_session.dart';
import 'dashboard_authentication.dart';

/// Captured connection descriptor and its shared application-owned sign-in.
/// The descriptor is never used to reconstruct a second refresh owner.
class ConnectionAccess {
  ConnectionAccess({
    required this.connection,
    required this.dashboardOAuth,
    DashboardAuthentication? dashboardAuthentication,
  }) : dashboardAuthentication =
           dashboardAuthentication ?? DashboardAuthentication() {
    final grant = connection.dashboardGrant;
    final owner = dashboardOAuth;
    if (grant == null && owner != null ||
        grant != null &&
            (owner == null ||
                owner.currentGrant.id != grant.id ||
                owner.currentGrant.baseUrl != grant.baseUrl)) {
      throw StateError('Connection access does not match its saved sign-in.');
    }
  }

  final SavedConnection connection;
  final DashboardOAuthSession? dashboardOAuth;
  final DashboardAuthentication dashboardAuthentication;

  /// Capture rotated provisional credentials at the explicit save boundary.
  SavedConnection get persistenceSnapshot =>
      connection.copyWith(dashboardGrant: dashboardOAuth?.activeGrant);
}
