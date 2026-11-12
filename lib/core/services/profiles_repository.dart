import 'connection_access.dart';
import '../models/hermes_profile.dart';
import 'connection_manager.dart';

typedef ProfileApiGet = Future<Map<String, dynamic>> Function(String endpoint);

class ProfileDiscovery {
  final List<HermesProfile> profiles;
  final String? currentName;
  final String? activeName;

  const ProfileDiscovery({
    required this.profiles,
    required this.currentName,
    required this.activeName,
  });

  HermesProfile? named(String? name) {
    if (name == null) return null;
    for (final profile in profiles) {
      if (profile.name == name) return profile;
    }
    return null;
  }

  HermesProfile get serverPreferred =>
      named(currentName) ?? named(activeName) ?? profiles.first;
}

/// Discovers profiles through the authenticated modern dashboard contract.
///
/// There is deliberately no legacy fallback here. An absent or unhealthy
/// profile endpoint fails discovery, never granting permission to send
/// an unscoped request to the server's default profile.
class ProfilesRepository {
  final ProfileApiGet _get;
  final DashboardClient? _ownedClient;

  ProfilesRepository(ProfileApiGet get) : _get = get, _ownedClient = null;

  ProfilesRepository._owned(DashboardClient client)
    : _get = client.apiGet,
      _ownedClient = client;

  factory ProfilesRepository.forConnection(ConnectionAccess access) {
    final connection = access.connection;
    return ProfilesRepository._owned(
      DashboardClient(
        host: connection.host,
        port: connection.dashboardPort,
        useHttps: connection.useHttps,
        pathPrefix: connection.dashboardPrefix ?? '',
        proxied: connection.dashboardProxied,
        username: connection.dashboardUsername,
        password: connection.dashboardPassword,
        dashboardOAuth: access.dashboardOAuth,
        requiresOAuth: connection.isCloud,
        gatewayHeaders: connection.gatewayHeaders,
        authentication: access.dashboardAuthentication,
      ),
    );
  }

  Future<ProfileDiscovery> discover() async {
    final profilesPayload = await _get('profiles');
    final activePayload = await _get('profiles/active');
    final rawProfiles = profilesPayload['profiles'];
    if (rawProfiles is! List || rawProfiles.isEmpty) {
      throw const FormatException(
        'The server returned no valid Hermes profiles.',
      );
    }

    final profiles = <HermesProfile>[];
    final names = <String>{};
    for (final raw in rawProfiles) {
      if (raw is! Map) {
        throw const FormatException('The server returned an invalid profile.');
      }
      final profile = HermesProfile.fromJson(Map<String, dynamic>.from(raw));
      if (!names.add(profile.name)) {
        throw FormatException(
          'The server returned duplicate profile ${profile.name}.',
        );
      }
      profiles.add(profile);
    }

    String? optionalCanonicalName(String key) {
      final value = activePayload[key];
      if (value == null) return null;
      if (value is! String || !HermesProfile.isCanonicalName(value)) {
        throw FormatException('The server returned an invalid $key profile.');
      }
      return value;
    }

    return ProfileDiscovery(
      profiles: List.unmodifiable(profiles),
      currentName: optionalCanonicalName('current'),
      activeName: optionalCanonicalName('active'),
    );
  }

  void close() => _ownedClient?.close();
}
