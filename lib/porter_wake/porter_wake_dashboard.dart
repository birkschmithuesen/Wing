import '../core/services/connection_manager.dart';

/// Same construction as the other per-service dashboard clients
/// (profile_gateway.dart `_dashboardFor`).
DashboardClient porterDashboardFor(SavedConnection connection) => DashboardClient(
  host: connection.host,
  port: connection.dashboardPort,
  useHttps: connection.useHttps,
  pathPrefix: connection.dashboardPrefix ?? '',
  proxied: connection.dashboardProxied,
  username: connection.dashboardUsername,
  password: connection.dashboardPassword,
  dashboardOAuth: connection.dashboardOAuth,
  requiresOAuth: connection.isCloud,
  gatewayHeaders: connection.gatewayHeaders,
);
