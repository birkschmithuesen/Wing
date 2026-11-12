/// Immutable instance-bound credentials. Network renewal and persistence are
/// owned by the connection's application session, never by this saved value.
class DashboardOAuthGrant {
  const DashboardOAuthGrant({
    required this.id,
    required this.baseUrl,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String id;
  final String baseUrl;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  static String canonicalBase(String value) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Cloud dashboards must use an HTTPS address.',
      );
    }
    return uri
        .replace(
          port: uri.port == 443 ? null : uri.port,
          path: uri.path.replaceAll(RegExp(r'/+$'), ''),
        )
        .toString();
  }

  factory DashboardOAuthGrant.fromMap(Map<String, dynamic> map) {
    final session = DashboardOAuthGrant(
      id: map['id'] as String,
      baseUrl: canonicalBase(map['base_url'] as String),
      accessToken: map['access_token'] as String,
      refreshToken: map['refresh_token'] as String,
      expiresAt: DateTime.parse(map['expires_at'] as String).toUtc(),
    );
    if (session.id.isEmpty ||
        session.accessToken.isEmpty ||
        session.refreshToken.isEmpty) {
      throw const FormatException();
    }
    return session;
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'base_url': baseUrl,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.toIso8601String(),
  };

  static DateTime tokenExpiry(Object? value) {
    if (value is num && value.isFinite && value > 0) {
      return DateTime.fromMillisecondsSinceEpoch(
        (value * 1000).round(),
        isUtc: true,
      );
    }
    throw const FormatException('Missing session expiry.');
  }
}
