import 'connection_diagnostics.dart';
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/connection.dart';
import '../models/connection_import_result.dart';
import '../models/dashboard_oauth_grant.dart';
import 'connection_access.dart';
import 'dashboard_oauth_session.dart';
import 'dashboard_authentication.dart';
import 'dashboard_read_transport.dart';

// Re-export for convenience
export '../models/connection.dart';

/// Injectable secret storage boundary used by [ConnectionManager].
///
/// The production implementation is backed by Android Keystore through
/// `flutter_secure_storage`; tests use a deterministic in-memory fake.
abstract interface class CredentialStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class FlutterSecureCredentialStore implements CredentialStore {
  static const AndroidOptions _androidOptions = AndroidOptions(
    resetOnError: false,
    migrateWithBackup: true,
    storageNamespace: 'wing_connections',
  );

  final FlutterSecureStorage _storage;

  FlutterSecureCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? FlutterSecureStorage(aOptions: _androidOptions);

  @override
  Future<String?> read(String key) async {
    final value = await _storage.read(key: key);
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }
}

class CredentialStorageException implements Exception {
  final String message;

  const CredentialStorageException(this.message);

  @override
  String toString() => message;
}

/// HTTP failure from an authenticated Dashboard API request.
///
/// Keeping the status code typed lets capability probes distinguish missing
/// routes from authentication failures without parsing exception prose.
class DashboardHttpException implements Exception {
  final int statusCode;
  final String endpoint;
  final Object? responseDetail;

  const DashboardHttpException(
    this.statusCode,
    this.endpoint, {
    this.responseDetail,
  });

  factory DashboardHttpException.response(
    http.Response response,
    String endpoint,
  ) {
    Object? detail;
    try {
      final body = jsonDecode(response.body);
      if (body is Map) detail = _immutableErrorDetail(body['detail']);
    } on FormatException {
      // HTML and malformed bodies are not actionable server descriptors.
    }
    return DashboardHttpException(
      response.statusCode,
      endpoint,
      responseDetail: detail,
    );
  }

  String? get serverCode => responseDetail is Map
      ? _errorText((responseDetail as Map)['code'])
      : null;
  String? get serverMessage => responseDetail is String
      ? _errorText(responseDetail)
      : responseDetail is Map
      ? _errorText((responseDetail as Map)['message'])
      : null;

  @override
  String toString() => [
    'HTTP $statusCode',
    ?serverMessage,
    if (serverCode case final code?) '($code)',
  ].join(' · ');
}

String? _errorText(Object? value) => value is String && value.trim().isNotEmpty
    ? value.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f]'), '').trim()
    : null;
Object? _immutableErrorDetail(Object? value) => switch (value) {
  final Map map => Map<String, Object?>.unmodifiable({
    for (final entry in map.entries)
      if (entry.key is String)
        entry.key as String: _immutableErrorDetail(entry.value),
  }),
  final List list => List<Object?>.unmodifiable(
    list.map(_immutableErrorDetail),
  ),
  String() || num() || bool() || null => value,
  _ => null,
};

/// Exact stock session-detail absence, distinct from a missing profile or route.
/// No server prose or response payload is retained in this failure.
class DashboardSessionNotFound extends DashboardHttpException {
  const DashboardSessionNotFound(String endpoint) : super(404, endpoint);
}

/// Authentication failed before the API request could be dispatched.
class DashboardRequestNotSentException implements Exception {
  const DashboardRequestNotSentException(this.cause);
  final Object cause;
}

class CronHttpException extends DashboardHttpException {
  const CronHttpException(super.statusCode, super.endpoint, this.detail);
  final Object? detail;
  bool get uncertain => statusCode >= 500 || statusCode == 408;
  String get description {
    if (statusCode == 424) {
      return 'The task was saved, but its schedule could not be registered. Review it before creating another.';
    }
    if (statusCode == 404) {
      return 'This task or scheduling feature is no longer available. Refresh the list.';
    }
    if (statusCode == 401 || statusCode == 403) {
      return 'Sign in to this server again to manage scheduled tasks.';
    }
    if ({400, 409, 422}.contains(statusCode) && detail is String) {
      final text = (detail as String)
          .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f]'), '')
          .trim();
      return text.length > 500 ? '${text.substring(0, 500)}…' : text;
    }
    return 'The server could not confirm this request (HTTP $statusCode).';
  }
}

class DashboardResponseTooLargeException implements Exception {
  final int maxBytes;

  const DashboardResponseTooLargeException(this.maxBytes);
}

class _ConnectionCredentials {
  final String apiKey;
  final String? dashboardPassword;
  final Map<String, String> gatewayHeaders;
  final DashboardOAuthGrant? dashboardGrant;

  const _ConnectionCredentials({
    required this.apiKey,
    required this.dashboardPassword,
    this.gatewayHeaders = const <String, String>{},
    this.dashboardGrant,
  });

  bool get isEmpty =>
      apiKey.isEmpty &&
      dashboardPassword == null &&
      gatewayHeaders.isEmpty &&
      dashboardGrant == null;

  String encode() => jsonEncode(<String, Object>{
    if (apiKey.isNotEmpty) 'api_key': apiKey,
    if (dashboardGrant != null) 'dashboard_oauth': dashboardGrant!.toMap(),
    'dashboard_password': ?dashboardPassword,
    if (gatewayHeaders.isNotEmpty) 'gateway_headers': gatewayHeaders,
  });

  static _ConnectionCredentials decode(String encoded) {
    try {
      final map = jsonDecode(encoded) as Map<String, dynamic>;
      final apiKey = map['api_key'];
      final dashboardPassword = map['dashboard_password'];
      final rawHeaders = map['gateway_headers'];
      if (apiKey != null && apiKey is! String ||
          dashboardPassword != null && dashboardPassword is! String ||
          rawHeaders != null && rawHeaders is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final headers = <String, String>{};
      if (rawHeaders case final Map<String, dynamic> values) {
        for (final entry in values.entries) {
          if (entry.value is! String) {
            throw const FormatException();
          }
          headers[entry.key] = entry.value as String;
        }
      }
      final password = dashboardPassword as String?;
      return _ConnectionCredentials(
        apiKey: (apiKey as String?) ?? '',
        dashboardPassword: password,
        gatewayHeaders: validateGatewayHeaders(headers),
        dashboardGrant: map['dashboard_oauth'] == null
            ? null
            : DashboardOAuthGrant.fromMap(
                map['dashboard_oauth'] as Map<String, dynamic>,
              ),
      );
    } catch (_) {
      throw const CredentialStorageException(
        'Stored connection credentials could not be read safely.',
      );
    }
  }

  static _ConnectionCredentials fromConnection(SavedConnection connection) {
    final password = connection.dashboardPassword;
    return _ConnectionCredentials(
      apiKey: connection.apiKey,
      dashboardPassword: password,
      gatewayHeaders: connection.gatewayHeaders,
      dashboardGrant: connection.dashboardGrant,
    );
  }
}

/// Shared by managers using the same secure store, including short-lived UI
/// managers. Readers see only a fully hydrated, committed connection snapshot.
class _ConnectionPersistenceState {
  final sessions = <String, DashboardOAuthSession>{};
  final dashboardAuthentications = <String, DashboardAuthentication>{};
  List<SavedConnection>? snapshot;
  bool blocked = false;
}

/// Manages non-secret connection metadata in SharedPreferences and credentials
/// in a platform secure store.
class ConnectionManager {
  static const String _key = 'saved_connections';
  static const String _credentialKeyPrefix = 'connection_credentials_v1.';
  static const Uuid _uuid = Uuid();
  static final CredentialStore _sharedCredentialStore =
      FlutterSecureCredentialStore();

  final SharedPreferences prefs;
  final CredentialStore _credentialStore;
  final DashboardOAuthSession Function(DashboardOAuthGrant) _createOAuthSession;

  static DashboardOAuthSession _newOAuthSession(DashboardOAuthGrant grant) =>
      DashboardOAuthSession(grant);
  static const String _journalKey = 'connection_transaction_v1';
  static final _persistenceStates =
      Expando<Expando<_ConnectionPersistenceState>>();
  static final _persistenceQueues = Expando<Future<void>>();
  _ConnectionPersistenceState get _state {
    final states = _persistenceStates[_credentialStore] ??=
        Expando<_ConnectionPersistenceState>();
    return states[prefs] ??= _ConnectionPersistenceState();
  }

  Future<T> _withPersistenceLock<T>(
    Future<T> Function() action, {
    bool initialize = true,
  }) {
    final state = _state;
    final next = (_persistenceQueues[_credentialStore] ?? Future<void>.value())
        .then((_) async {
          if (initialize && (state.snapshot == null || state.blocked)) {
            await _initializeUnlocked();
          }
          return action();
        });
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _persistenceQueues[_credentialStore] = settled;
    return next.whenComplete(() {
      // Retain the tail while another operation is queued. Otherwise remove it
      // before the caller observes completion, so a future from this execution
      // zone cannot strand later widget-test or lifecycle operations.
      if (identical(_persistenceQueues[_credentialStore], settled)) {
        _persistenceQueues[_credentialStore] = null;
      }
    });
  }

  Map<String, DashboardOAuthSession> get _sessions => _state.sessions;

  DashboardOAuthSession? _bindSession(String id, DashboardOAuthGrant? stored) {
    if (stored == null) {
      _sessions.remove(id)?.retire();
      return null;
    }
    final cached = _sessions[id];
    final session =
        cached?.currentGrant.id == stored.id &&
            cached?.currentGrant.baseUrl == stored.baseUrl
        ? cached!
        : _createOAuthSession(stored);
    if (cached != null && !identical(cached, session)) cached.retire();
    _sessions[id] = session;
    session.persist = () => _withPersistenceLock(() async {
      // A deleted/replaced connection must never be resurrected by an in-flight refresh.
      final current = getConnections();
      final present = current.any((c) => c.id == id && c.isCloud);
      final encoded = await _credentialStore.read(_credentialKey(id));
      if (!present || encoded == null || !identical(_sessions[id], session)) {
        throw const CredentialStorageException(
          'This connection is no longer saved.',
        );
      }
      final credentials = _ConnectionCredentials.decode(encoded);
      if (credentials.dashboardGrant?.id != session.currentGrant.id ||
          credentials.dashboardGrant?.baseUrl != session.currentGrant.baseUrl) {
        throw const CredentialStorageException(
          'This sign-in has been replaced.',
        );
      }
      await _commitTransaction(
        connections: current,
        credentials: {
          id: _ConnectionCredentials(
            apiKey: credentials.apiKey,
            dashboardPassword: credentials.dashboardPassword,
            gatewayHeaders: credentials.gatewayHeaders,
            dashboardGrant: session.currentGrant,
          ),
        },
      );
    });
    return session;
  }

  /// Synchronous readers of nonempty storage must first call [initialize],
  /// or share a preferences/store pair that has already been initialized.
  /// [create] and asynchronous reads/mutations establish that safe state.
  ConnectionManager(
    this.prefs, {
    CredentialStore? credentialStore,
    DashboardOAuthSession Function(DashboardOAuthGrant) createOAuthSession =
        _newOAuthSession,
  }) : _credentialStore = credentialStore ?? _sharedCredentialStore,
       _createOAuthSession = createOAuthSession;

  static Future<ConnectionManager> create(
    SharedPreferences prefs, {
    CredentialStore? credentialStore,
    DashboardOAuthSession Function(DashboardOAuthGrant) createOAuthSession =
        _newOAuthSession,
  }) async {
    final manager = ConnectionManager(
      prefs,
      credentialStore: credentialStore,
      createOAuthSession: createOAuthSession,
    );
    await manager.initialize();
    return manager;
  }

  /// Recovers interrupted writes before exposing any connection credentials.
  Future<void> initialize() =>
      _withPersistenceLock(_initializeUnlocked, initialize: false);

  Future<void> _initializeUnlocked() async {
    _state.blocked = true;
    try {
      final journal = await _credentialStore.read(_journalKey);
      if (journal != null) {
        await _rollbackJournal(journal);
      }
      await _loadSnapshot();
      _state.blocked = false;
    } catch (_) {
      throw const CredentialStorageException(
        'Connection storage could not be recovered safely. Retry before using saved connections.',
      );
    }
  }

  List<SavedConnection> getConnections() {
    final snapshot = _state.snapshot;
    if (!_state.blocked && snapshot == null && _readConnectionMaps().isEmpty) {
      return [];
    }
    if (_state.blocked || snapshot == null) {
      throw const CredentialStorageException(
        'Connection storage must be initialized safely before use.',
      );
    }
    return List<SavedConnection>.of(snapshot);
  }

  /// Captures the current authority without constructing a second refresh owner.
  /// Label/icon edits and token rotation keep authority; replaced credentials or
  /// endpoints cannot revive access through an older immutable descriptor.
  ConnectionAccess accessFor(SavedConnection connection) {
    final current = getConnections().where((c) => c.id == connection.id);
    if (current.length != 1 ||
        _authority(current.single) != _authority(connection)) {
      throw StateError('This connection access has been replaced.');
    }
    return ConnectionAccess(
      connection: connection,
      dashboardOAuth: _sessions[connection.id],
      dashboardAuthentication: _state.dashboardAuthentications.putIfAbsent(
        connection.id,
        DashboardAuthentication.new,
      ),
    );
  }

  static String _authority(SavedConnection connection) {
    final metadata = connection.toMap()
      ..remove('label')
      ..remove('icon');
    return jsonEncode([
      metadata,
      connection.apiKey,
      connection.dashboardPassword,
      canonicalGatewayHeaders(connection.gatewayHeaders),
      connection.dashboardGrant?.id,
      connection.dashboardGrant?.baseUrl,
    ]);
  }

  /// Reads secrets from durable storage under the same lock as mutations.
  Future<List<SavedConnection>> loadConnectionsWithSecrets() =>
      _withPersistenceLock(() async {
        try {
          await _loadSnapshot();
          return getConnections();
        } catch (_) {
          _state.blocked = true;
          throw const CredentialStorageException(
            'Stored connection credentials could not be read safely.',
          );
        }
      });

  Future<void> _loadSnapshot() async {
    final connections = _connectionsFromMaps(_readConnectionMaps());
    final hydrated = <SavedConnection>[];
    for (final connection in connections) {
      final encoded = await _credentialStore.read(
        _credentialKey(connection.id),
      );
      hydrated.add(_hydrate(connection, encoded));
    }
    _publish(hydrated);
  }

  SavedConnection _hydrate(SavedConnection connection, String? encoded) {
    if (encoded == null) {
      return connection;
    }
    final credentials = _ConnectionCredentials.decode(encoded);
    return connection.copyWith(
      apiKey: credentials.apiKey,
      dashboardPassword: credentials.dashboardPassword,
      gatewayHeaders: credentials.gatewayHeaders,
      dashboardGrant: credentials.dashboardGrant,
      clearDashboardPassword: credentials.dashboardPassword == null,
    );
  }

  void _publish(
    List<SavedConnection> connections, {
    Set<String> replaced = const {},
  }) {
    final prior = {
      for (final connection in _state.snapshot ?? <SavedConnection>[])
        connection.id: connection,
    };
    for (final connection in connections) {
      final previous = prior[connection.id];
      if (previous != null && _authority(previous) != _authority(connection)) {
        _sessions.remove(connection.id)?.retire();
        _state.dashboardAuthentications.remove(connection.id);
      }
    }
    for (final id in replaced) {
      _sessions.remove(id)?.retire();
      _state.dashboardAuthentications.remove(id);
    }
    final present = connections.map((connection) => connection.id).toSet();
    _state.dashboardAuthentications.removeWhere(
      (id, _) => !present.contains(id),
    );
    for (final id
        in _sessions.keys.where((id) => !present.contains(id)).toList()) {
      _sessions.remove(id)?.retire();
    }
    for (final connection in connections) {
      _bindSession(connection.id, connection.dashboardGrant);
    }
    _state.snapshot = List<SavedConnection>.of(connections);
  }

  /// Writes a whole set of connections at once, preserving their ids.
  ///
  /// A durable secure-store journal protects the complete import, including
  /// overwritten IDs and removed secrets. Until the journal is deleted and its
  /// absence verified, interruption restores the previous complete set.
  Future<ConnectionImportResult> importConnections(
    List<SavedConnection> incoming, {
    required bool replaceExisting,
    required bool Function() canCommit,
  }) => _withPersistenceLock(() async {
    final current = getConnections();

    final ordered = List<SavedConnection>.of(incoming);

    final List<SavedConnection> next;
    final removed = <SavedConnection>[];
    if (replaceExisting) {
      final keep = ordered.map((connection) => connection.id).toSet();
      removed.addAll(
        current.where((connection) => !keep.contains(connection.id)),
      );
      next = ordered;
    } else {
      final incomingIds = ordered.map((connection) => connection.id).toSet();
      next = <SavedConnection>[
        ...ordered,
        ...current.where((connection) => !incomingIds.contains(connection.id)),
      ];
    }

    if (ordered.map((connection) => connection.id).toSet().length !=
        ordered.length) {
      throw const FormatException('Imported connection IDs must be unique.');
    }
    final currentIds = current.map((connection) => connection.id).toSet();
    final added = ordered.where((c) => !currentIds.contains(c.id)).length;
    final updated = ordered.length - added;
    if (!canCommit()) {
      throw StateError('Connection import was canceled before admission.');
    }
    await _commitTransaction(
      connections: next,
      credentials: {
        for (final connection in ordered)
          connection.id: _ConnectionCredentials.fromConnection(connection),
        for (final connection in removed)
          connection.id: const _ConnectionCredentials(
            apiKey: '',
            dashboardPassword: null,
          ),
      },
      replaced: ordered.map((connection) => connection.id).toSet(),
    );
    return ConnectionImportResult(
      added: added,
      updated: updated,
      removed: removed.length,
    );
  });

  Future<SavedConnection> saveConnection(
    String label,
    String host,
    int port,
    String apiKey, {
    ConnectionIcon icon = ConnectionIcon.server,
    String? gatewayPrefix,
    String? dashboardPrefix,
    bool dashboardProxied = false,
    String? desktopGatewayUrl,
    int? dashboardPort,
    String? dashboardUsername,
    String? dashboardPassword,
    String? cloudInstanceId,
    String? cloudOrganization,
    DashboardOAuthGrant? dashboardGrant,
    Map<String, String> gatewayHeaders = const <String, String>{},
  }) => _withPersistenceLock(() async {
    final normalized = SavedConnection.normalizeHostAndPort(host, port);
    final conn = SavedConnection(
      id: _uuid.v4(),
      label: label,
      icon: icon,
      host: normalized.host,
      port: normalized.port,
      apiKey: apiKey,
      useHttps: normalized.useHttps,
      gatewayPrefix: gatewayPrefix,
      dashboardPrefix: dashboardPrefix,
      dashboardProxied: dashboardProxied,
      desktopGatewayUrl: desktopGatewayUrl?.trim(),
      dashboardPortOverride: dashboardPort,
      dashboardUsername: dashboardUsername,
      dashboardPassword: dashboardPassword,
      cloudInstanceId: cloudInstanceId,
      cloudOrganization: cloudOrganization,
      dashboardGrant: dashboardGrant,
      gatewayHeaders: gatewayHeaders,
    );
    final current = getConnections();
    current.insert(0, conn);
    await _commitCredentialAndMetadata(
      connectionId: conn.id,
      nextCredentials: _ConnectionCredentials.fromConnection(conn),
      connections: current,
    );
    return conn;
  });

  /// Updates all editable fields on an existing connection while preserving its
  /// id and list position. Empty optional strings clear their saved values.
  Future<void> updateConnection(
    String connId,
    String label,
    String host,
    int port,
    String apiKey, {
    ConnectionIcon? icon,
    String? gatewayPrefix,
    String? dashboardPrefix,
    bool dashboardProxied = false,
    String? desktopGatewayUrl,
    int? dashboardPort,
    String? dashboardUsername,
    String? dashboardPassword,
    String? cloudInstanceId,
    String? cloudOrganization,
    DashboardOAuthGrant? dashboardGrant,
    Map<String, String?>? gatewayHeaders,
  }) => _withPersistenceLock(() async {
    final current = getConnections();
    final idx = current.indexWhere((c) => c.id == connId);
    if (idx < 0) {
      return;
    }

    final normalized = SavedConnection.normalizeHostAndPort(host, port);
    final gateway = gatewayPrefix?.trim();
    final dashboard = dashboardPrefix?.trim();
    final dashUser = dashboardUsername?.trim();
    final dashPass = dashboardPassword;
    final desktopGateway = desktopGatewayUrl?.trim();
    final resolvedGatewayHeaders = resolveGatewayHeaderUpdate(
      current[idx].gatewayHeaders,
      gatewayHeaders,
    );

    current[idx] = current[idx].copyWith(
      label: label,
      cloudInstanceId: cloudInstanceId,
      cloudOrganization: cloudOrganization,
      dashboardGrant: dashboardGrant,
      icon: icon,
      host: normalized.host,
      port: normalized.port,
      apiKey: apiKey,
      useHttps: normalized.useHttps,
      gatewayPrefix: gateway == null || gateway.isEmpty ? null : gateway,
      clearGatewayPrefix: gateway != null && gateway.isEmpty,
      dashboardPrefix: dashboard == null || dashboard.isEmpty
          ? null
          : dashboard,
      clearDashboardPrefix: dashboard != null && dashboard.isEmpty,
      dashboardProxied: dashboardProxied,
      gatewayHeaders: resolvedGatewayHeaders,
      desktopGatewayUrl: desktopGateway == null || desktopGateway.isEmpty
          ? null
          : desktopGateway,
      clearDesktopGatewayUrl: desktopGateway != null && desktopGateway.isEmpty,
      dashboardPortOverride: dashboardPort,
      clearDashboardPort: dashboardPort == null,
      dashboardUsername: dashUser == null || dashUser.isEmpty ? null : dashUser,
      clearDashboardUsername: dashUser != null && dashUser.isEmpty,
      dashboardPassword: dashPass == null || dashPass.isEmpty ? null : dashPass,
      clearDashboardPassword: dashPass != null && dashPass.isEmpty,
    );
    await _commitCredentialAndMetadata(
      connectionId: connId,
      nextCredentials: _ConnectionCredentials.fromConnection(current[idx]),
      connections: current,
    );
  });

  /// Changes only device-owned appearance, without touching credentials or
  /// contacting the server.
  Future<void> updateConnectionIcon(
    String connId,
    ConnectionIcon icon,
  ) => _withPersistenceLock(() async {
    final current = getConnections();
    final index = current.indexWhere((connection) => connection.id == connId);
    if (index < 0) {
      throw StateError('Connection no longer exists.');
    }
    current[index] = current[index].copyWith(icon: icon);
    try {
      await _saveAll(current);
      _publish(current);
    } catch (_) {
      // SharedPreferences updates its cache before the platform write finishes.
      // Restore the persisted value so reopening Appearance cannot show a
      // selection whose save failed.
      try {
        await prefs.reload();
      } catch (_) {
        _state.blocked = true;
      }
      rethrow;
    }
  });

  Future<void> deleteConnection(String id) => _withPersistenceLock(() async {
    final current = getConnections();
    final index = current.indexWhere((connection) => connection.id == id);
    if (index < 0) {
      return;
    }
    current.removeWhere((c) => c.id == id);
    await _commitCredentialAndMetadata(
      connectionId: id,
      nextCredentials: const _ConnectionCredentials(
        apiKey: '',
        dashboardPassword: null,
      ),
      connections: current,
    );
  });

  List<Map<String, dynamic>> _readConnectionMaps() {
    try {
      final jsonList = prefs.getStringList(_key) ?? const <String>[];
      final maps = jsonList
          .map((json) => jsonDecode(json) as Map<String, dynamic>)
          .toList();
      if (maps.any(
        (map) => const {
          'api_key',
          'dashboard_password',
          'gateway_headers',
          'dashboard_oauth',
        }.any(map.containsKey),
      )) {
        throw const CredentialStorageException(
          'Plaintext connection credentials are unsupported. Remove the saved connections and configure them again.',
        );
      }
      return maps;
    } on CredentialStorageException {
      rethrow;
    } catch (_) {
      throw const CredentialStorageException(
        'Saved connection metadata could not be read safely.',
      );
    }
  }

  List<SavedConnection> _connectionsFromMaps(List<Map<String, dynamic>> maps) {
    try {
      return maps.map(SavedConnection.fromMap).toList();
    } catch (_) {
      throw const CredentialStorageException(
        'Saved connection metadata could not be read safely.',
      );
    }
  }

  Future<void> _commitCredentialAndMetadata({
    required String connectionId,
    required _ConnectionCredentials nextCredentials,
    required List<SavedConnection> connections,
  }) => _commitTransaction(
    connections: connections,
    credentials: {connectionId: nextCredentials},
  );

  Future<void> _commitTransaction({
    required List<SavedConnection> connections,
    required Map<String, _ConnectionCredentials> credentials,
    Set<String> replaced = const {},
  }) async {
    // Read durable originals, never the cache or mutable OAuth session objects.
    final originals = <String, String?>{};
    try {
      for (final id in credentials.keys) {
        final encoded = await _credentialStore.read(_credentialKey(id));
        if (encoded != null) {
          _ConnectionCredentials.decode(encoded);
        }
        originals[id] = encoded;
      }
    } catch (_) {
      throw const CredentialStorageException(
        'Original connection credentials could not be read safely.',
      );
    }
    final journal = jsonEncode({
      'metadata': prefs.getStringList(_key),
      'credentials': originals,
    });
    try {
      await _writeJournal(journal);
      for (final entry in credentials.entries) {
        await _writeAndVerifyCredentials(entry.key, entry.value);
      }
      await _saveAll(connections);
      await _deleteJournal();
    } catch (_) {
      _state.blocked = true;
      try {
        // Deletion can succeed before throwing or before a failed verification.
        // Re-establish the journal before beginning any rollback writes.
        await _writeJournal(journal);
        await _rollbackJournal(journal);
        await _loadSnapshot();
        _state.blocked = false;
      } catch (_) {
        // Keep the journal and block every reader until recovery succeeds.
      }
      throw const CredentialStorageException(
        'Connection changes could not be saved safely. Retry recovery before using saved connections.',
      );
    }
    // No asynchronous work after the verified journal deletion (commit point).
    _publish([
      for (final connection in connections)
        if (credentials[connection.id] case final bundle?)
          connection.copyWith(
            apiKey: bundle.apiKey,
            dashboardPassword: bundle.dashboardPassword,
            clearDashboardPassword: bundle.dashboardPassword == null,
            gatewayHeaders: bundle.gatewayHeaders,
            dashboardGrant: bundle.dashboardGrant,
          )
        else
          connection,
    ], replaced: replaced);
  }

  Future<void> _writeJournal(String journal) async {
    await _credentialStore.write(_journalKey, journal);
    if (await _credentialStore.read(_journalKey) != journal) {
      throw const CredentialStorageException(
        'Connection journal could not be verified safely.',
      );
    }
  }

  Future<void> _deleteJournal() async {
    await _credentialStore.delete(_journalKey);
    if (await _credentialStore.read(_journalKey) != null) {
      throw const CredentialStorageException(
        'Connection journal could not be cleared safely.',
      );
    }
  }

  Future<void> _rollbackJournal(String journal) async {
    final data = jsonDecode(journal) as Map<String, dynamic>;
    final metadata = (data['metadata'] as List<dynamic>?)?.cast<String>();
    final originals = data['credentials'] as Map<String, dynamic>;
    for (final entry in originals.entries) {
      final encoded = entry.value as String?;
      if (encoded != null) {
        _ConnectionCredentials.decode(encoded);
      }
    }
    // Preserve recovery intent even if journal deletion previously completed.
    await _writeJournal(journal);
    for (final entry in originals.entries) {
      final key = _credentialKey(entry.key);
      final encoded = entry.value as String?;
      if (encoded == null) {
        await _credentialStore.delete(key);
      } else {
        await _credentialStore.write(key, encoded);
      }
      if (await _credentialStore.read(key) != encoded) {
        throw const CredentialStorageException(
          'Original connection credentials could not be restored safely.',
        );
      }
    }
    final restored = metadata == null
        ? await prefs.remove(_key)
        : await prefs.setStringList(_key, metadata);
    if (!restored) {
      await prefs.reload();
      // A platform may report failure after persisting the write. Only durable
      // equality proves that recovery completed.
      if (jsonEncode(prefs.getStringList(_key)) != jsonEncode(metadata)) {
        throw const CredentialStorageException(
          'Original connection metadata could not be restored safely.',
        );
      }
    }
    try {
      await _deleteJournal();
    } catch (_) {
      await _writeJournal(journal);
      rethrow;
    }
  }

  Future<void> _writeAndVerifyCredentials(
    String connectionId,
    _ConnectionCredentials credentials,
  ) async {
    final key = _credentialKey(connectionId);
    if (credentials.isEmpty) {
      await _credentialStore.delete(key);
      final readBack = await _credentialStore.read(key);
      if (readBack != null) {
        throw const CredentialStorageException(
          'Connection credentials could not be cleared safely.',
        );
      }
      return;
    }

    final encoded = credentials.encode();
    await _credentialStore.write(key, encoded);
    final readBack = await _credentialStore.read(key);
    if (readBack != encoded) {
      throw const CredentialStorageException(
        'Connection credentials could not be verified safely.',
      );
    }
  }

  Future<void> _saveAll(List<SavedConnection> list) async {
    try {
      final saved = await prefs.setStringList(
        _key,
        list.map((connection) => jsonEncode(connection.toMap())).toList(),
      );
      if (!saved) {
        throw const CredentialStorageException(
          'Connection metadata could not be saved safely.',
        );
      }
    } on CredentialStorageException {
      rethrow;
    } catch (_) {
      throw const CredentialStorageException(
        'Connection metadata could not be saved safely.',
      );
    }
  }

  static String _credentialKey(String connectionId) {
    final encodedId = base64Url
        .encode(utf8.encode(connectionId))
        .replaceAll('=', '');
    return '$_credentialKeyPrefix$encodedId';
  }
}

/// Client for the Hermes Dashboard REST API.
///
/// Explicit auth modes, picked by connection configuration:
///
///  * **Cloud OAuth** — an instance-bound bearer grant, renewed through the
///    native broker. A missing/rejected grant requires sign-in, never another mode.
///  * **Proxied dashboard** — when [proxied] is true, upstream infrastructure
///    injects auth and the app sends clean JSON requests with no dashboard
///    session token or cookie.
///  * **Password (gated) dashboard** — when [username] and [password] are set,
///    performs the `/auth/password-login` flow (provider `basic`) and
///    authenticates subsequent `/api/` calls with the returned
///    `hermes_session_at` session cookie. This is what hermes-desktop does and
///    is required when the dashboard runs with basic-auth.
///  * **Insecure (open) dashboard** — when no credentials are given, falls back
///    to scraping the ephemeral SPA session token from the homepage. Only works
///    on a dashboard started with `--insecure`.
///
/// Used for Dashboard-only features: cron, memory, skills, settings.
class _NoRedirectClient extends http.BaseClient {
  final http.Client _inner;

  _NoRedirectClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.followRedirects = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

class DashboardClient {
  bool _closed = false;
  final http.Client _http;
  final String _baseUrl;
  final bool _proxied;
  final String? _username;
  final String? _password;
  final Map<String, String> _gatewayHeaders;
  final DashboardOAuthSession? _oauth;
  final bool _requiresOAuth;
  final Duration readTimeout;
  late final _reads = DashboardReadTransport(_http, timeout: readTimeout);
  final DashboardAuthentication _authentication;
  final DashboardClient? _authenticationOwner;

  String get baseUrl => _baseUrl;

  bool get _usesPasswordAuth =>
      (_username?.isNotEmpty ?? false) && (_password?.isNotEmpty ?? false);

  DashboardClient({
    required String host,
    int port = 9119,
    bool useHttps = false,
    String pathPrefix = '',
    bool proxied = false,
    String? username,
    String? password,
    DashboardOAuthSession? dashboardOAuth,
    bool requiresOAuth = false,
    Map<String, String> gatewayHeaders = const <String, String>{},
    http.Client? httpClient,
    DashboardAuthentication? authentication,
    this.readTimeout = const Duration(seconds: 45),
  }) : _authentication = authentication ?? DashboardAuthentication(),
       _authenticationOwner = null,
       _oauth = dashboardOAuth,
       _requiresOAuth = requiresOAuth || dashboardOAuth != null,
       _proxied = proxied,
       _username = username,
       _password = password,
       _gatewayHeaders = validateGatewayHeaders(gatewayHeaders),
       _baseUrl = SavedConnection.joinBaseUrl(
         '${useHttps ? 'https' : 'http'}://$host:$port',
         pathPrefix,
       ),
       // The app's session-token header is a credential even when the user
       // has not configured custom proxy headers. Never redirect either.
       _http = _NoRedirectClient(
         httpClient ?? IOClient(HttpClient()..connectionTimeout = readTimeout),
       );

  /// Independent cancellable reads sharing this origin's sign-in and renewal.
  DashboardClient forkReads() {
    if (_closed) throw StateError('Dashboard client is closed');
    return DashboardClient._readClient(this);
  }

  DashboardClient._readClient(DashboardClient owner)
    : _authentication = owner._authentication,
      _authenticationOwner = owner._authenticationOwner ?? owner,
      _oauth = owner._oauth,
      _requiresOAuth = owner._requiresOAuth,
      _proxied = owner._proxied,
      _username = owner._username,
      _password = owner._password,
      _gatewayHeaders = owner._gatewayHeaders,
      _baseUrl = owner._baseUrl,
      readTimeout = owner.readTimeout,
      _http = _NoRedirectClient(
        IOClient(HttpClient()..connectionTimeout = owner.readTimeout),
      );

  Map<String, String> get _jsonHeaders => {
    ..._gatewayHeaders,
    'Content-Type': 'application/json',
  };

  /// Invalidates only the credentials rejected by this particular request.
  void _resetAuth(Map<String, String> rejectedHeaders) {
    String? header(String name) {
      for (final entry in rejectedHeaders.entries) {
        if (entry.key.toLowerCase() == name) {
          return entry.value;
        }
      }
      return null;
    }

    // Parallel profile requests may finish after another request has already
    // renewed the session. Only invalidate the credentials actually rejected;
    // retain any newer credentials and the shared in-flight renewal.
    _oauth?.invalidateRejectedBearer(header('authorization'));
    _authentication.reject(
      _baseUrl,
      DashboardCredentialKind.cookie,
      header('cookie'),
    );
    _authentication.reject(
      _baseUrl,
      DashboardCredentialKind.token,
      header('x-hermes-session-token'),
    );
  }

  /// Cached and concurrent sign-in belongs to the captured connection access.
  Future<String> _getCookie() => _authentication.credential(
    baseUrl: _baseUrl,
    kind: DashboardCredentialKind.cookie,
    authenticate: (_authenticationOwner ?? this)._login,
    isActive: () => !_closed && _authenticationOwner?._closed != true,
  );

  /// Logs in against the `basic` password provider. The shared authentication
  /// owner caches the returned cookie. Rejected credentials propagate.
  Future<String> _login() async {
    final res = await _reads.request(
      'POST',
      Uri.parse('$_baseUrl/auth/password-login'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'provider': 'basic',
        'username': _username,
        'password': _password,
      }),
    );
    if (res.statusCode == 401) {
      throw const DashboardHttpException(401, 'auth/password-login');
    }
    if (res.statusCode != 200) {
      throw DashboardHttpException(res.statusCode, 'auth/password-login');
    }
    final setCookie = res.headers['set-cookie'] ?? '';
    // Match cookie boundaries, not expiry-date commas. Current Hermes Webapp
    // scopes cookies to its gateway and requires the sign-in binding as well.
    // Keep only authentication cookies, within this origin's credential owner.
    final cookies = RegExp(
      r'(?:^|,\s*)((?:__Host-|__Secure-)?hermes_(?:session_(?:at|rt|provider)|webapp_signin)(?:_[A-Za-z0-9_-]+)?)=("[^";]*"|[^;,\s]+)',
    ).allMatches(setCookie).toList();
    if (!cookies.any(
      (cookie) => RegExp(
        r'^(?:__Host-|__Secure-)?hermes_session_at(?:_|$)',
      ).hasMatch(cookie.group(1)!),
    )) {
      throw Exception('Hermes login succeeded but no session cookie found');
    }
    return cookies
        .map((cookie) => '${cookie.group(1)}=${cookie.group(2)}')
        .join('; ');
  }

  Future<String> _getToken() => _authentication.credential(
    baseUrl: _baseUrl,
    kind: DashboardCredentialKind.token,
    authenticate: (_authenticationOwner ?? this)._fetchToken,
    isActive: () => !_closed && _authenticationOwner?._closed != true,
  );

  Future<String> _fetchToken() async {
    final res = await _reads.request(
      'GET',
      Uri.parse('$_baseUrl/'),
      headers: _gatewayHeaders,
    );
    if (res.statusCode != 200) {
      throw DashboardHttpException(res.statusCode, '/');
    }
    final match = RegExp(
      r'window\.__HERMES_SESSION_TOKEN__="([^"]+)";',
    ).firstMatch(res.body);
    if (match == null) throw Exception('Session token not found');
    return match.group(1)!;
  }

  void _requireCurrentAccess() {
    if (_closed || _oauth?.isActive == false) {
      throw DashboardRequestNotSentException(
        StateError('This connection access has been retired.'),
      );
    }
  }

  Future<Map<String, String>> _authHeaders() async {
    if (_requiresOAuth) {
      final session = _oauth;
      if (session == null) {
        throw const CloudAccessException(
          'Sign in to Hermes Cloud again from this connection’s settings.',
        );
      }
      final bearer = await session.bearerFor(_baseUrl);
      return {..._jsonHeaders, 'Authorization': 'Bearer $bearer'};
    }
    if (_proxied) {
      return _jsonHeaders;
    }
    if (_usesPasswordAuth) {
      return {
        ..._gatewayHeaders,
        'Cookie': await _getCookie(),
        'Content-Type': 'application/json',
      };
    }
    return {
      ..._gatewayHeaders,
      'X-Hermes-Session-Token': await _getToken(),
      'Content-Type': 'application/json',
    };
  }

  /// Select authentication by configured mode, never by retrying a rejected
  /// ticket as a different auth mechanism. Local Desktop uses its session token.
  Future<({String? token, String? ticket})> gatewayCredentials() async {
    if (_requiresOAuth || _usesPasswordAuth || _proxied) {
      return (token: null, ticket: await mintWebSocketTicket());
    }
    return (token: await _getToken(), ticket: null);
  }

  /// Mints the short-lived, single-use WebSocket ticket required by a secured
  /// Hermes Desktop gateway. The HTTP API cookie stays in this client; only the
  /// ticket is passed to the WebSocket URL.
  Future<String> mintWebSocketTicket({bool retried = false}) async {
    final headers = await _authHeaders();
    _requireCurrentAccess();
    final res = await _reads.request(
      'POST',
      Uri.parse('$_baseUrl/api/auth/ws-ticket'),
      headers: headers,
    );
    if (res.statusCode == 401 && !retried) {
      _resetAuth(headers);
      return mintWebSocketTicket(retried: true);
    }
    if (res.statusCode != 200) {
      throw DashboardHttpException(res.statusCode, 'auth/ws-ticket');
    }
    final data = _decodeMapResponse(res);
    final ticket = data['ticket'] as String?;
    if (ticket == null || ticket.isEmpty) {
      throw Exception('Desktop gateway returned no WebSocket ticket');
    }
    return ticket;
  }

  Map<String, dynamic> _decodeMapResponse(http.Response res) {
    final trimmed = res.body.trim();
    if (trimmed.isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return {'data': decoded};
  }

  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    Map<String, String>? queryParameters,
    bool retried = false,
  }) async {
    var stage = 'authentication';
    try {
      final headers = await _authHeaders();
      _requireCurrentAccess();
      final uri = Uri.parse(
        '$_baseUrl/api/$endpoint',
      ).replace(queryParameters: queryParameters);
      stage = 'request';
      final res = await _reads.request('GET', uri, headers: headers);
      stage = 'response';
      if (res.statusCode == 401 && !retried) {
        logConnectionDiagnostic(
          'http.auth_retry',
          details: {
            'endpoint': connectionDiagnosticEndpoint(endpoint),
            'http_status': 401,
          },
        );
        _resetAuth(headers);
        return await apiGet(
          endpoint,
          queryParameters: queryParameters,
          retried: true,
        );
      }
      if (res.statusCode != 200) {
        if (res.statusCode == 404 &&
            RegExp(r'^sessions/[^/?#]+$').hasMatch(endpoint)) {
          try {
            final error = jsonDecode(res.body);
            if (error is Map &&
                error.length == 1 &&
                error['detail'] == 'Session not found') {
              throw DashboardSessionNotFound(endpoint);
            }
          } on FormatException {
            // An invalid response never establishes session absence.
          }
        }
        throw DashboardHttpException.response(res, endpoint);
      }
      stage = 'decode';
      return _decodeMapResponse(res);
    } catch (failure, stack) {
      logConnectionDiagnostic(
        'http.read_failed',
        details: {
          'endpoint': connectionDiagnosticEndpoint(endpoint),
          'auth_retry': retried,
          'stage': stage,
          if (failure is DashboardHttpException)
            'http_status': failure.statusCode,
        },
        error: failure,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<http.Response> apiGetBytes(
    String endpoint, {
    Map<String, String>? queryParameters,
    int? maxBytes,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    _requireCurrentAccess();
    final uri = Uri.parse(
      '$_baseUrl/api/$endpoint',
    ).replace(queryParameters: queryParameters);
    final http.Response res;
    try {
      res = await _reads.request(
        'GET',
        uri,
        headers: headers,
        maxBytes: maxBytes,
      );
    } on DashboardReadTooLarge {
      throw DashboardResponseTooLargeException(maxBytes!);
    }
    if (res.statusCode == 401 && !retried) {
      _resetAuth(headers);
      return apiGetBytes(
        endpoint,
        queryParameters: queryParameters,
        maxBytes: maxBytes,
        retried: true,
      );
    }
    if (res.statusCode != 200) {
      throw DashboardHttpException.response(res, endpoint);
    }
    return res;
  }

  Future<Map<String, dynamic>> apiPost(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final Map<String, String> headers;
    try {
      headers = await _authHeaders().timeout(const Duration(seconds: 15));
    } catch (error) {
      if (error is SocketException ||
          error is TimeoutException ||
          error is http.ClientException ||
          error is DashboardHttpException && error.statusCode >= 500) {
        throw DashboardRequestNotSentException(error);
      }
      rethrow;
    }
    _requireCurrentAccess();
    final res = await _http.post(
      Uri.parse('$_baseUrl/api/$endpoint'),
      headers: headers,
      body: body != null ? jsonEncode(body) : null,
    );
    if (res.statusCode == 401 && !retried) {
      _resetAuth(headers);
      return apiPost(endpoint, body: body, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardHttpException.response(res, endpoint);
    }
    return _decodeMapResponse(res);
  }

  Future<Map<String, dynamic>> apiDeleteResult(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    _requireCurrentAccess();
    final res = await _http.delete(
      Uri.parse('$_baseUrl/api/$endpoint'),
      headers: headers,
      body: body == null ? null : jsonEncode(body),
    );
    if (res.statusCode == 401 && !retried) {
      _resetAuth(headers);
      return apiDeleteResult(endpoint, body: body, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardHttpException.response(res, endpoint);
    }
    return _decodeMapResponse(res);
  }

  Future<Map<String, dynamic>> apiPatch(
    String endpoint, {
    required Map<String, dynamic> body,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    _requireCurrentAccess();
    final res = await _http.patch(
      Uri.parse('$_baseUrl/api/$endpoint'),
      headers: headers,
      body: jsonEncode(body),
    );
    if (res.statusCode == 401 && !retried) {
      _resetAuth(headers);
      return apiPatch(endpoint, body: body, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardHttpException.response(res, endpoint);
    }
    return _decodeMapResponse(res);
  }

  Future<Map<String, dynamic>> apiPut(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) => _apiWrite('PUT', endpoint, body: body, retried: retried);

  /// Owned commands supply exact route authority. Authentication and a 401
  /// refresh cannot turn a retired command into a new HTTP write.
  Future<Map<String, dynamic>> apiWriteOwned(
    String method,
    String endpoint, {
    required Map<String, dynamic> body,
    required bool Function() canDispatch,
    required void Function() onDispatched,
  }) {
    var dispatched = false;
    void dispatchOnce() {
      if (dispatched) return;
      dispatched = true;
      onDispatched();
    }

    return _apiWrite(
      method,
      endpoint,
      body: body,
      retried: false,
      canDispatch: canDispatch,
      onDispatched: dispatchOnce,
    );
  }

  Future<Map<String, dynamic>> _apiWrite(
    String method,
    String endpoint, {
    Map<String, dynamic>? body,
    required bool retried,
    bool Function()? canDispatch,
    void Function()? onDispatched,
  }) async {
    if (!const {'PUT', 'POST', 'PATCH', 'DELETE'}.contains(method)) {
      throw ArgumentError.value(method);
    }
    if (canDispatch != null && (_closed || !canDispatch())) {
      throw DashboardRequestNotSentException(
        StateError('Owned command retired.'),
      );
    }
    final Map<String, String> headers;
    try {
      headers = await _authHeaders();
    } catch (error) {
      if (canDispatch != null) throw DashboardRequestNotSentException(error);
      rethrow;
    }
    final encoded = body != null ? jsonEncode(body) : null;
    _requireCurrentAccess();
    if (canDispatch != null && (_closed || !canDispatch())) {
      throw DashboardRequestNotSentException(
        StateError('Owned command retired.'),
      );
    }
    final uri = Uri.parse('$_baseUrl/api/$endpoint');
    final response = switch (method) {
      'PUT' => _http.put(uri, headers: headers, body: encoded),
      'POST' => _http.post(uri, headers: headers, body: encoded),
      'PATCH' => _http.patch(uri, headers: headers, body: encoded),
      'DELETE' => _http.delete(uri, headers: headers, body: encoded),
      _ => throw ArgumentError.value(method),
    };
    onDispatched?.call();
    final res = await response;
    if (res.statusCode == 401 && !retried) {
      _resetAuth(headers);
      return _apiWrite(
        method,
        endpoint,
        body: body,
        retried: true,
        canDispatch: canDispatch,
        onDispatched: onDispatched,
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      logConnectionDiagnostic(
        'http.write_failed',
        details: {
          'method': method,
          'endpoint': connectionDiagnosticEndpoint(endpoint),
          'http_status': res.statusCode,
        },
      );
      throw DashboardHttpException.response(res, endpoint);
    }
    return _decodeMapResponse(res);
  }

  /// Current cron API, with structured rejection details and a timeout scoped
  /// to the synchronous trigger operation. No transport retry after uncertainty.
  Future<Map<String, dynamic>> cronRequest(
    String method,
    String endpoint,
    Map<String, String> query,
    Map<String, dynamic>? body, {
    bool retried = false,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/api/$endpoint',
    ).replace(queryParameters: query);
    final request = http.Request(method, uri)
      ..headers.addAll(
        await _authHeaders().timeout(const Duration(seconds: 45)),
      );
    if (body != null) {
      request.body = jsonEncode(body);
    }
    final timeout =
        method == 'POST' &&
            RegExp(r'^cron/jobs/[^/]+/trigger$').hasMatch(endpoint)
        ? const Duration(hours: 24)
        : const Duration(seconds: 45);
    final response = await _http
        .send(request)
        .then(http.Response.fromStream)
        .timeout(timeout);
    if (response.statusCode == 401 && !retried) {
      _resetAuth(request.headers);
      return cronRequest(method, endpoint, query, body, retried: true);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      Object? detail;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          detail = decoded['detail'];
        }
      } on FormatException {
        // HTML proxy errors are not safe or useful UI copy.
      }
      throw CronHttpException(response.statusCode, endpoint, detail);
    }
    return _decodeMapResponse(response);
  }

  void close() {
    _closed = true;
    _reads.close();
    _http.close();
  }
}
