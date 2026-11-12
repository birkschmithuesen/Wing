import 'dashboard_oauth_grant.dart';
import 'connection_icon.dart';

export 'connection_icon.dart';

/// Connection model for remote Hermes Gateway API Server.
class NormalizedConnectionHost {
  final String host;
  final int port;
  final bool useHttps;

  const NormalizedConnectionHost({
    required this.host,
    required this.port,
    this.useHttps = false,
  });
}

final RegExp _gatewayHeaderToken = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

const Set<String> _managedGatewayHeaders = <String>{
  'authorization',
  'connection',
  'content-length',
  'content-type',
  'cookie',
  'host',
  'origin',
  'referer',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'x-hermes-session-token',
};

/// Validates user-supplied access-proxy headers without changing their display
/// spelling or secret values.
Map<String, String> validateGatewayHeaders(Map<String, String> headers) {
  final validated = <String, String>{};
  final seen = <String>{};
  for (final entry in headers.entries) {
    final canonicalName = entry.key.toLowerCase();
    if (!_gatewayHeaderToken.hasMatch(entry.key)) {
      throw const FormatException('Header names must use valid HTTP tokens.');
    }
    if (!seen.add(canonicalName)) {
      throw const FormatException('Header names must be unique.');
    }
    if (_managedGatewayHeaders.contains(canonicalName)) {
      throw FormatException('${entry.key} is managed by Hermes.');
    }
    if (entry.value.trim().isEmpty ||
        entry.value.contains('\r') ||
        entry.value.contains('\n')) {
      throw const FormatException(
        'Header values must be non-empty single-line text.',
      );
    }
    validated[entry.key] = entry.value;
  }
  return Map<String, String>.unmodifiable(validated);
}

/// Raw local header text, including the identity of a hidden saved value.
class GatewayHeaderDraft {
  const GatewayHeaderDraft({
    required this.savedName,
    required this.name,
    required this.value,
  });
  final String? savedName;
  final String name, value;

  bool get keepsSavedValue =>
      savedName != null &&
      name.trim().toLowerCase() == savedName!.toLowerCase() &&
      value.isEmpty;
}

/// A captured header edit. Null update values retain case-insensitive saved rows;
/// omitted rows remove them. Invalid local text produces no publishable update.
class GatewayHeaderEdit {
  GatewayHeaderEdit(Iterable<GatewayHeaderDraft> rows)
    : rows = List.unmodifiable(rows);

  GatewayHeaderEdit.retaining(Iterable<String> names)
    : rows = List.unmodifiable(
        names.map(
          (name) => GatewayHeaderDraft(savedName: name, name: name, value: ''),
        ),
      );

  final List<GatewayHeaderDraft> rows;

  String? nameError(int index) {
    final name = rows[index].name.trim();
    if (name.isEmpty) return 'Header name is required';
    if (rows.indexed.any(
      (entry) =>
          entry.$1 != index &&
          entry.$2.name.trim().toLowerCase() == name.toLowerCase(),
    )) {
      return 'Header names must be unique.';
    }
    try {
      validateGatewayHeaders({name: 'value'});
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  String? valueError(int index) {
    final row = rows[index];
    if (row.keepsSavedValue) return null;
    if (row.value.isEmpty) return 'Value is required';
    try {
      validateGatewayHeaders({'X-Hermes-Validation': row.value});
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  Map<String, String?>? get update {
    final names = <String>{};
    final result = <String, String?>{};
    for (final row in rows) {
      final name = row.name.trim();
      if (name.isEmpty || !names.add(name.toLowerCase())) return null;
      final value = row.keepsSavedValue ? null : row.value;
      try {
        validateGatewayHeaders({name: value ?? 'value'});
      } on FormatException {
        return null;
      }
      result[name] = value;
    }
    return Map.unmodifiable(result);
  }

  Map<String, String> resolve(Map<String, String> existing) {
    final edited = update;
    if (edited == null) throw const FormatException('Invalid header edits.');
    return resolveGatewayHeaderUpdate(existing, edited);
  }
}

/// Resolves an authoritative editor snapshot against existing secret values.
///
/// A null update keeps the complete set. Within a present update, a null value
/// keeps the existing case-insensitive row; omitted rows are deleted.
Map<String, String> resolveGatewayHeaderUpdate(
  Map<String, String> existing,
  Map<String, String?>? update,
) {
  final current = validateGatewayHeaders(existing);
  if (update == null) {
    return current;
  }
  final next = <String, String>{};
  final seen = <String>{};
  for (final entry in update.entries) {
    final canonicalName = entry.key.toLowerCase();
    if (!seen.add(canonicalName)) {
      throw const FormatException('Header names must be unique.');
    }
    if (entry.value case final value?) {
      next[entry.key] = value;
      continue;
    }
    final retained = current.entries.where(
      (candidate) => candidate.key.toLowerCase() == canonicalName,
    );
    if (retained.isEmpty) {
      throw const FormatException('New headers require a value.');
    }
    final existingEntry = retained.single;
    next[existingEntry.key] = existingEntry.value;
  }
  return validateGatewayHeaders(next);
}

/// Canonical stable representation used only as input to keyed/digested local
/// connection identities.
List<List<String>> canonicalGatewayHeaders(Map<String, String> headers) {
  final entries = validateGatewayHeaders(headers).entries.toList()
    ..sort(
      (first, second) =>
          first.key.toLowerCase().compareTo(second.key.toLowerCase()),
    );
  return entries
      .map((entry) => <String>[entry.key.toLowerCase(), entry.value])
      .toList(growable: false);
}

class SavedConnection {
  final String id;
  final String label;
  final ConnectionIcon icon;
  final String host;
  final int port;
  final String apiKey;
  final bool useHttps;
  final String? gatewayPrefix;
  final String? dashboardPrefix;
  final bool dashboardProxied;
  final Map<String, String> gatewayHeaders;

  /// Optional Hermes Desktop remote-gateway origin. This is intentionally
  /// separate from the mobile OpenAI-compatible API and admin dashboard.
  final String? desktopGatewayUrl;

  /// Explicit dashboard port. When null, [dashboardPort] falls back to the
  /// default topology (see below). Set this when the dashboard is exposed on a
  /// non-default port.
  final int? dashboardPortOverride;

  /// Optional dashboard credentials for a basic-auth (password-protected)
  /// dashboard. When both are set, [DashboardClient] performs the
  /// `/auth/password-login` flow and authenticates with the resulting session
  /// cookie (same as hermes-desktop). When empty, it falls back to scraping the
  /// SPA session token, which only works on an insecure (open) dashboard.
  final String? dashboardUsername;
  final String? dashboardPassword;
  final String? cloudInstanceId;
  final String? cloudOrganization;
  final DashboardOAuthGrant? dashboardGrant;
  bool get isCloud => cloudInstanceId != null;

  /// Update ownership also covers a Cloud instance entered as a direct URL.
  /// This does not change how a saved connection authenticates.
  bool get cloudManagedUpdates {
    if (isCloud) return true;
    final endpoint = desktopGatewayUrl ?? host;
    final hostname = Uri.tryParse(
      endpoint.contains('://') ? endpoint : 'https://$endpoint',
    )?.host.toLowerCase();
    return hostname != null &&
        const [
          '.agents.nousresearch.com',
          '.agents.staging-nousresearch.com',
        ].any(hostname.endsWith);
  }

  SavedConnection({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.apiKey,
    this.icon = ConnectionIcon.server,
    this.useHttps = false,
    this.gatewayPrefix,
    this.dashboardPrefix,
    this.dashboardProxied = false,
    Map<String, String> gatewayHeaders = const <String, String>{},
    this.desktopGatewayUrl,
    this.dashboardPortOverride,
    this.dashboardUsername,
    this.dashboardPassword,
    this.cloudInstanceId,
    this.cloudOrganization,
    this.dashboardGrant,
  }) : gatewayHeaders = validateGatewayHeaders(gatewayHeaders);

  String get baseUrl {
    final scheme = useHttps ? 'https' : 'http';
    return '$scheme://$host:$port';
  }

  /// Dashboard/API-server topology differs between local LAN and HTTPS proxy
  /// setups. Local Gateway chat connections normally use 8642 while the
  /// dashboard lives on 9119. HTTPS reverse-proxy deployments usually expose
  /// both API surfaces on the same external HTTPS port. An explicit
  /// [dashboardPortOverride] always wins.
  int get dashboardPort => dashboardPortOverride ?? (useHttps ? port : 9119);

  /// Joins a base URL with an optional path prefix, normalising slashes.
  static String joinBaseUrl(String baseUrl, String pathPrefix) {
    var url = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    if (pathPrefix.isNotEmpty) {
      var prefix = pathPrefix.startsWith('/') ? pathPrefix : '/$pathPrefix';
      prefix = prefix.endsWith('/')
          ? prefix.substring(0, prefix.length - 1)
          : prefix;
      url = '$url$prefix';
    }
    return url;
  }

  /// Parses [input] as a URI and extracts host, port, and HTTPS flag.
  ///
  /// When the user provides an explicit port inside the URL (e.g.
  /// `https://example.com:8443`) that port is always used.
  ///
  /// When the URL has no explicit port, the [fallbackPort] is used.
  /// Callers should set [fallbackPort] to the value typed by the user in the
  /// Port field, so custom HTTPS ports (e.g. 8443) are preserved.
  static NormalizedConnectionHost normalizeHostAndPort(
    String input,
    int fallbackPort,
  ) {
    var raw = input.trim();
    final bool detectedHttps = raw.toLowerCase().startsWith('https://');
    if (raw.isEmpty) {
      return NormalizedConnectionHost(
        host: raw,
        port: fallbackPort,
        useHttps: detectedHttps,
      );
    }

    if (!raw.contains('://')) raw = 'http://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      return NormalizedConnectionHost(
        host: input.trim(),
        port: fallbackPort,
        useHttps: detectedHttps,
      );
    }

    final normalizedPort = uri.hasPort
        ? uri.port
        : detectedHttps && fallbackPort == 8642
        ? 443
        : fallbackPort;

    return NormalizedConnectionHost(
      host: uri.host,
      port: normalizedPort,
      useHttps: detectedHttps || (uri.scheme == 'https'),
    );
  }

  /// Serializes non-secret connection metadata for SharedPreferences.
  ///
  /// [apiKey] and [dashboardPassword] intentionally never cross this boundary;
  /// [ConnectionManager] persists them in the platform secure store instead.
  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{
      'id': id,
      if (cloudInstanceId != null) 'cloud_instance_id': cloudInstanceId,
      if (cloudOrganization != null) 'cloud_organization': cloudOrganization,
      'label': label,
      'icon': icon.name,
      'host': host,
      'port': port,
      'use_https': useHttps,
      'dashboard_port': dashboardPortOverride,
    };
    if (gatewayPrefix != null && gatewayPrefix!.isNotEmpty) {
      m['gateway_prefix'] = gatewayPrefix;
    }
    if (dashboardPrefix != null && dashboardPrefix!.isNotEmpty) {
      m['dashboard_prefix'] = dashboardPrefix;
    }
    if (dashboardProxied) {
      m['dashboard_proxied'] = dashboardProxied;
    }
    if (desktopGatewayUrl != null && desktopGatewayUrl!.isNotEmpty) {
      m['desktop_gateway_url'] = desktopGatewayUrl;
    }
    if (dashboardUsername != null && dashboardUsername!.isNotEmpty) {
      m['dashboard_username'] = dashboardUsername;
    }
    return m;
  }

  factory SavedConnection.fromMap(Map<String, dynamic> map) {
    String? nonEmpty(Object? v) {
      final s = (v as String?)?.trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    if (const {
      'api_key',
      'dashboard_password',
      'gateway_headers',
      'dashboard_oauth',
    }.any(map.containsKey)) {
      throw const FormatException(
        'Connection metadata cannot contain credentials.',
      );
    }
    return SavedConnection(
      id: map['id'] as String,
      cloudInstanceId: nonEmpty(map['cloud_instance_id']),
      cloudOrganization: nonEmpty(map['cloud_organization']),
      label: map['label'] as String,
      icon: ConnectionIcon.fromStored(map['icon']),
      host: map['host'] as String,
      port: (map['port'] as int?) ?? 8642,
      apiKey: '',
      useHttps: (map['use_https'] as bool?) ?? false,
      gatewayPrefix: map['gateway_prefix'] as String?,
      dashboardPrefix: map['dashboard_prefix'] as String?,
      dashboardProxied: (map['dashboard_proxied'] as bool?) ?? false,
      desktopGatewayUrl: nonEmpty(map['desktop_gateway_url']),
      dashboardPortOverride: map['dashboard_port'] as int?,
      dashboardUsername: nonEmpty(map['dashboard_username']),
    );
  }

  /// Returns a copy with the given fields replaced. Pass `clearDashboard*`
  /// flags to explicitly null out optional fields (since null args can't
  /// distinguish "leave unchanged" from "clear").
  SavedConnection copyWith({
    String? label,
    ConnectionIcon? icon,
    String? host,
    int? port,
    String? apiKey,
    bool? useHttps,
    String? gatewayPrefix,
    String? dashboardPrefix,
    bool? dashboardProxied,
    String? desktopGatewayUrl,
    int? dashboardPortOverride,
    String? dashboardUsername,
    String? dashboardPassword,
    String? cloudInstanceId,
    String? cloudOrganization,
    DashboardOAuthGrant? dashboardGrant,
    Map<String, String>? gatewayHeaders,
    bool clearGatewayPrefix = false,
    bool clearDashboardPrefix = false,
    bool clearDashboardPort = false,
    bool clearDashboardUsername = false,
    bool clearDashboardPassword = false,
    bool clearDesktopGatewayUrl = false,
  }) {
    return SavedConnection(
      id: id,
      cloudInstanceId: cloudInstanceId ?? this.cloudInstanceId,
      cloudOrganization: cloudOrganization ?? this.cloudOrganization,
      dashboardGrant: dashboardGrant ?? this.dashboardGrant,
      label: label ?? this.label,
      icon: icon ?? this.icon,
      host: host ?? this.host,
      port: port ?? this.port,
      apiKey: apiKey ?? this.apiKey,
      useHttps: useHttps ?? this.useHttps,
      gatewayPrefix: clearGatewayPrefix
          ? null
          : (gatewayPrefix ?? this.gatewayPrefix),
      dashboardPrefix: clearDashboardPrefix
          ? null
          : (dashboardPrefix ?? this.dashboardPrefix),
      dashboardProxied: dashboardProxied ?? this.dashboardProxied,
      gatewayHeaders: gatewayHeaders ?? this.gatewayHeaders,
      desktopGatewayUrl: clearDesktopGatewayUrl
          ? null
          : (desktopGatewayUrl ?? this.desktopGatewayUrl),
      dashboardPortOverride: clearDashboardPort
          ? null
          : (dashboardPortOverride ?? this.dashboardPortOverride),
      dashboardUsername: clearDashboardUsername
          ? null
          : (dashboardUsername ?? this.dashboardUsername),
      dashboardPassword: clearDashboardPassword
          ? null
          : (dashboardPassword ?? this.dashboardPassword),
    );
  }
}
