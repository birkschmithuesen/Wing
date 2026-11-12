import 'profile_model_catalog.dart';
import 'connector_inventory.dart';
import 'models_dev_pricing.dart';
import 'usage_analytics.dart';
import 'skill_reader_session.dart';
import '../models/skill_reader.dart';
import 'connection_access.dart';
import 'bot_display_client.dart';
import 'dart:async';
import 'dart:io';

import '../models/hermes_profile.dart';
import '../models/administration_operation.dart';
import '../models/model_choice.dart';
import '../models/settings_edit.dart';
import '../models/profile_identity_edit.dart';
import 'connection_manager.dart';
import 'profile_gateway.dart';
import 'provider_console.dart';
import 'profiles_repository.dart';
import 'profile_identity_repository.dart';
import 'server_connection_status.dart';
import 'workspace_connection_failure.dart';
import 'ws_client.dart';

typedef AdministrationRequest =
    Future<Map<String, dynamic>> Function(
      String method,
      String endpoint,
      Map<String, String> query,
      Map<String, dynamic>? body,
    );

typedef AdministrationSettingsWrite =
    Future<Map<String, dynamic>> Function(
      String profile,
      Map<String, dynamic> patch,
      bool Function() canDispatch,
      void Function() onDispatched,
    );

typedef AdministrationMutation =
    Future<Map<String, dynamic>> Function(
      String method,
      String endpoint,
      Map<String, String> query,
      Map<String, dynamic> body,
      bool Function() canDispatch,
      void Function() onDispatched,
    );

/// One connection, independent of the currently selected workspace.
/// Profile views capture an explicit canonical scope.
class AdministrationRepository {
  ConnectorInventory? _connectorInventory;
  ConnectorInventory get connectorInventory =>
      _connectorInventory ??= ConnectorInventory(
        (name) => profile(name).read('mcp/servers'),
        (name) => profile(name).rpc('mcp.servers.status'),
      );
  late final _skillReader = SkillReaderRepository(
    (endpoint, query) => read(endpoint, query),
  );
  SkillReaderSession skillReader(SkillReaderTarget document, String profile) =>
      SkillReaderSession(
        repository: _skillReader,
        document: document,
        profile: profile,
        retain: retain,
        release: release,
      );
  final _modelCatalogs = <String, ProfileModelCatalog>{};
  UsageAnalyticsRepository? _usageAnalytics;
  UsageAnalyticsRepository get usageAnalytics {
    if (_closed) throw StateError('Administration connection is closed');
    return _usageAnalytics ??= UsageAnalyticsRepository(
      read: (name, endpoint, query) => profile(name).read(endpoint, query),
      apiPricing: _apiPricing ?? ModelsDevPricing.shared.load,
    );
  }

  ProfileModelCatalog _modelCatalog(String name) {
    if (_closed) {
      throw StateError('Administration connection is closed');
    }
    return _modelCatalogs.putIfAbsent(
      name,
      () => ProfileModelCatalog(
        scope: profile(name).scope,
        apiPricing: _apiPricing,
        read: ({required refresh, required explicitOnly}) =>
            read('model/options', {
              'profile': name,
              if (refresh) 'refresh': '1',
              if (explicitOnly) 'explicit_only': '1',
            }),
      ),
    );
  }

  void _closeModelCatalogs() {
    for (final owner in _modelCatalogs.values) {
      owner.close();
    }
    _modelCatalogs.clear();
  }

  final ApiPricingRead? _apiPricing;
  final String connectionId;
  final String connectionIdentity;
  final String connectionLabel;
  final AdministrationRequest request;
  final AdministrationSettingsWrite _settingsWrite;
  final AdministrationMutation ownedMutation;
  final ProfileGateway Function(String name) gateway;
  final ProviderConsoleCommand? providerCommand;
  final Future<BotDisplayClient> Function(String ticket)? displayConnect;
  final void Function() _close;
  int _leases = 0;
  bool _closing = false;
  bool _closed = false;

  AdministrationRepository({
    ApiPricingRead? apiPricing,
    required this.connectionId,
    required this.connectionIdentity,
    required this.connectionLabel,
    required this.request,
    required AdministrationSettingsWrite settingsWrite,
    required this.ownedMutation,
    required this.gateway,
    this.providerCommand,
    this.displayConnect,
    void Function()? close,
  }) : // The named dependency is an injectable public seam.
       // ignore: prefer_initializing_formals
       _apiPricing = apiPricing,
       // ignore: prefer_initializing_formals
       _settingsWrite = settingsWrite,
       _close = close ?? _noop;
  static void _noop() {}

  /// Only the write response can establish a definite rejection. A later
  /// readback refusal cannot undo an acknowledged write. All settings consumers
  /// share this classification while retaining their own edit/receipt lifetime.
  Future<Map<String, dynamic>> settingsWrite(
    String profile,
    Map<String, dynamic> patch,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    try {
      return await _settingsWrite(profile, patch, canDispatch, onDispatched);
    } catch (error) {
      final refusal = SettingsWriteRejected.fromFailure(error);
      if (refusal != null) throw refusal;
      rethrow;
    }
  }

  factory AdministrationRepository.forConnection(
    ConnectionAccess access,
    String identity, {
    required ServerConnectionStatus connectionStatus,
  }) {
    final connection = access.connection;
    final dashboard = DashboardClient(
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
    );
    final gateways = <String, ProfileGateway>{};
    final console = ProviderConsole.dashboard(
      dashboard,
      connection.gatewayHeaders,
    );
    return AdministrationRepository(
      apiPricing: ModelsDevPricing.shared.load,
      connectionId: connection.id,
      connectionIdentity: identity,
      connectionLabel: connection.label,
      providerCommand: console.run,
      displayConnect: (ticket) => BotDisplayClient.connect(
        connection.desktopGatewayUrl ?? dashboard.baseUrl,
        ticket,
        connection.gatewayHeaders,
      ),
      ownedMutation:
          (method, endpoint, query, body, canDispatch, onDispatched) async {
            var dispatchAllowed = true;
            bool active() => dispatchAllowed && canDispatch();
            try {
              return await connectionStatus.observeAccess(
                () => dashboard
                    .apiWriteOwned(
                      method,
                      Uri.parse(
                        endpoint,
                      ).replace(queryParameters: query).toString(),
                      body: body,
                      canDispatch: active,
                      onDispatched: onDispatched,
                    )
                    .timeout(const Duration(seconds: 45)),
              );
            } finally {
              // A timed-out authentication future may still finish. Its command
              // loses physical dispatch authority as soon as this call settles.
              dispatchAllowed = false;
            }
          },
      settingsWrite: (profile, patch, canDispatch, onDispatched) {
        final path = Uri(
          path: 'config',
          queryParameters: {'profile': profile},
        ).toString();
        return connectionStatus.observeAccess(
          () => dashboard
              .apiWriteOwned(
                'PUT',
                path,
                body: {'profile': profile, 'config': patch},
                canDispatch: canDispatch,
                onDispatched: onDispatched,
              )
              .timeout(const Duration(seconds: 45)),
        );
      },
      request: (method, endpoint, query, body) async {
        if (endpoint.startsWith('cron/')) {
          return connectionStatus.observeAccess(
            () => dashboard.cronRequest(method, endpoint, query, body),
          );
        }
        final path = Uri.parse(
          endpoint,
        ).replace(queryParameters: query.isEmpty ? null : query).toString();
        final Future<Map<String, dynamic>> response = switch (method) {
          'GET' => dashboard.apiGet(endpoint, queryParameters: query),
          'POST' => dashboard.apiPost(path, body: body),
          'PUT' => dashboard.apiPut(path, body: body),
          'PATCH' => dashboard.apiPatch(path, body: body ?? {}),
          'DELETE' => dashboard.apiDeleteResult(path, body: body),
          _ => throw ArgumentError('Unsupported administration request'),
        };
        return connectionStatus.observeAccess(
          () => response.timeout(const Duration(seconds: 45)),
        );
      },
      gateway: (name) => gateways.putIfAbsent(
        name,
        () =>
            ProfileGateway.forConnection(
                access,
                WorkspaceScope(
                  connectionId: connection.id,
                  connectionIdentity: identity,
                  profileName: name,
                ),
              )
              ..connectionStatus = connectionStatus
              ..reportsLiveChat = false,
      ),
      close: () {
        for (final gateway in gateways.values) {
          gateway.close();
        }
        dashboard.close();
        console.close();
      },
    );
  }

  void retain() {
    if (_closed) {
      throw StateError('Administration connection is closed');
    }
    _leases++;
  }

  void release() {
    _leases--;
    if (_closing && _leases == 0) {
      close();
    }
  }

  void close() {
    _closing = true;
    if (_leases == 0 && !_closed) {
      _closed = true;
      _usageAnalytics?.close();
      _connectorInventory?.dispose();
      _closeModelCatalogs();
      _close();
    }
  }

  Future<Map<String, dynamic>> read(
    String endpoint, [
    Map<String, String> query = const {},
  ]) => _retry(
    () => request('GET', endpoint, query, null),
    isTemporaryWorkspaceFailure,
  );

  /// Diagnostic starts have no idempotency key in stock Hermes. Only retry
  /// failures known to precede delivery; a timeout/reset may hide a real run.
  Future<AdministrationAction> startDiagnostic(
    String endpoint, {
    required bool Function() isActive,
  }) async {
    if (!{'ops/doctor', 'ops/security-audit'}.contains(endpoint)) {
      throw ArgumentError('Unknown diagnostic');
    }
    retain();
    var authority = true;
    bool active() => authority && !_closed && isActive();
    try {
      final receipt = await _retry(
        () async {
          if (!active()) {
            throw const AdministrationFailure('Diagnostic start canceled.');
          }
          return ownedMutation(
            'POST',
            endpoint,
            const {},
            const {},
            active,
            _noop,
          );
        },
        _diagnosticWasNotSent,
        isActive: active,
      );
      try {
        if (receipt['ok'] != true) {
          throw const FormatException('Unacknowledged diagnostic');
        }
        return AdministrationAction.fromJson(receipt);
      } on FormatException {
        throw const AdministrationFailure(
          'Operation started, but tracking is unavailable. Refresh its result.',
        );
      }
    } finally {
      authority = false;
      release();
    }
  }

  Future<T> _retry<T>(
    Future<T> Function() operation,
    bool Function(Object) retryable, {
    bool Function()? isActive,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await operation();
      } catch (error) {
        if (attempt == 2 ||
            !retryable(error) ||
            _closed ||
            isActive?.call() == false) {
          rethrow;
        }
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
        if (_closed || isActive?.call() == false) {
          rethrow;
        }
      }
    }
  }

  Future<ProfileDiscovery> discover() =>
      ProfilesRepository((endpoint) => read(endpoint)).discover();

  ProfileAdministration profile(String name) {
    if (!HermesProfile.isCanonicalName(name) || name == 'current') {
      throw ArgumentError('An explicit canonical profile is required');
    }
    return ProfileAdministration._(this, name);
  }
}

class ProfileAdministration {
  final AdministrationRepository server;
  final String name;
  ProfileAdministration._(this.server, this.name);
  String get label => '${server.connectionLabel} / $name';
  WorkspaceScope get scope => WorkspaceScope(
    connectionId: server.connectionId,
    connectionIdentity: server.connectionIdentity,
    profileName: name,
  );
  ProfileGateway get gateway => server.gateway(name);
  ProfileModelCatalog get modelCatalog => server._modelCatalog(name);

  Future<Map<String, dynamic>> read(
    String endpoint, [
    Map<String, String> query = const {},
  ]) => server.read(endpoint, {...query, 'profile': name});

  Future<void> requireProfile() async {
    if ((await server.discover()).named(name) == null) {
      throw const AdministrationFailure(
        'This profile is no longer available. Your edits are kept.',
      );
    }
  }

  /// A probe does not edit configuration. Keep `ok: false` as an observation
  /// instead of treating it as a rejected settings write.
  Future<Map<String, dynamic>> testConnector(String connector) =>
      server.request(
        'POST',
        'mcp/servers/${Uri.encodeComponent(connector)}/test',
        {'profile': name},
        const {},
      );

  Future<Map<String, dynamic>> write(
    String method,
    String endpoint, [
    Map<String, dynamic> body = const {},
  ]) async {
    await requireProfile();
    final result = await server.request(
      method,
      endpoint,
      {'profile': name},
      {...body, 'profile': name},
    );
    if (result['ok'] == false && result['confirm_required'] != true) {
      throw AdministrationFailure.rejected(result);
    }
    return result;
  }

  Future<Map<String, dynamic>> rpc(
    String method, [
    Map<String, dynamic> params = const {},
    bool mutation = false,
  ]) async {
    if (mutation) {
      await requireProfile();
    }
    Future<Map<String, dynamic>> call() async {
      await gateway.connect();
      return gateway.call(method, params);
    }

    final result = method == 'setup.status'
        ? await server._retry(call, isTemporaryWorkspaceFailure)
        : await call();
    if (result['ok'] == false) {
      throw AdministrationFailure.rejected(result);
    }
    return result;
  }

  Future<Map<String, dynamic>> config() => read('config');

  ProfileIdentityRepository get _identity => ProfileIdentityRepository(
    name: name,
    read: (endpoint, query) => server.read(endpoint, query),
    write: server.ownedMutation,
  );

  Future<ProfileIdentityObservation> loadIdentity() => _identity.load();

  Future<ProfileIdentitySaveResult> saveIdentity(
    ProfileIdentityEditIntent intent, {
    required bool Function() canDispatch,
    required void Function(ProfileIdentityField) onDispatched,
  }) async {
    server.retain();
    try {
      return await _identity.save(
        intent,
        canDispatch: () => !server._closed && canDispatch(),
        onDispatched: onDispatched,
      );
    } finally {
      server.release();
    }
  }

  /// A typed sparse intent is rechecked against fresh config and canonical
  /// model/info before membership/authority fencing and owned HTTP dispatch.
  /// Stock has no expected-version/model write precondition: concurrent writes
  /// after this preflight remain possible and require authoritative readback.
  Future<Map<String, dynamic>> saveSettings(
    SettingsEditIntent intent, {
    required bool Function() canDispatch,
    required void Function() onDispatched,
    ConfiguredModel? expectedModel,
  }) async {
    var dispatchAllowed = true;
    bool active() =>
        // Closing drains existing retained operations, including queued autosaves.
        // Physical closure and this command's authority still forbid dispatch.
        dispatchAllowed && !server._closed && canDispatch();
    void checkActive() {
      if (!active()) {
        throw const SettingsEditRetired();
      }
    }

    checkActive();
    final latest = await config();
    checkActive();
    if (expectedModel != null) {
      final current = ConfiguredModel.fromInfo(await read('model/info'));
      checkActive();
      if (current.provider != expectedModel.provider ||
          current.model != expectedModel.model) {
        throw const AdministrationFailure(
          'The default model changed elsewhere. Reopen its reasoning and speed settings. Your edits are kept.',
        );
      }
    }
    final resolution = intent.resolve(latest);
    if (resolution.conflicts.isNotEmpty) {
      throw SettingsEditConflict(resolution.conflicts);
    }
    if (resolution.updates.isEmpty) {
      return latest;
    }
    final patch = <String, dynamic>{};
    for (final entry in resolution.updates.entries) {
      setSetting(patch, entry.key, entry.value);
    }
    await requireProfile();
    checkActive();
    var dispatched = false;
    void markDispatched() {
      if (dispatched) {
        return;
      }
      dispatched = true;
      onDispatched();
    }

    try {
      final response = await server.settingsWrite(
        name,
        patch,
        active,
        markDispatched,
      );
      if (response['ok'] == false) {
        throw const SettingsWriteRejected('The server rejected this change.');
      }
      if (response['ok'] != true) {
        throw const SettingsSaveUnconfirmed();
      }
      final saved = await config();
      for (final entry in resolution.updates.entries) {
        if (!sameSetting(setting(saved, entry.key), entry.value)) {
          throw const SettingsSaveUnconfirmed();
        }
      }
      if (expectedModel != null) {
        final current = ConfiguredModel.fromInfo(await read('model/info'));
        if (current.provider != expectedModel.provider ||
            current.model != expectedModel.model) {
          throw const SettingsSaveUnconfirmed();
        }
      }
      return saved;
    } catch (error) {
      if (!dispatched) {
        if (!active()) {
          throw const SettingsEditRetired();
        }
        rethrow;
      }
      if (error is SettingsWriteRejected) {
        rethrow;
      }
      throw const SettingsSaveUnconfirmed();
    } finally {
      dispatchAllowed = false;
    }
  }
}

class SettingsEditRetired implements Exception {
  const SettingsEditRetired();
}

class SettingsWriteRejected extends AdministrationFailure {
  const SettingsWriteRejected(super.message);

  /// Stock config HTTP refusals deliberately expose safe path/lock information,
  /// never submitted values. HTTP auth/origin refusals share the same shape:
  /// preserve the explanation without inventing a managed-setting diagnosis.
  static SettingsWriteRejected? fromFailure(Object error) {
    if (error is DashboardHttpException &&
        Uri.tryParse(error.endpoint)?.path == 'config' &&
        const {400, 403, 409, 413}.contains(error.statusCode)) {
      return SettingsWriteRejected(
        error.serverMessage ?? 'Hermes refused this settings change.',
      );
    }
    if (error is JsonRpcError && error.reason == 'permission_denied') {
      final field = error.data['field'];
      final detail = error.data['detail'];
      return SettingsWriteRejected(
        [
          'Hermes refused this change.',
          if (field is String && field.trim().isNotEmpty) field.trim(),
          if (detail is String && detail.trim().isNotEmpty) detail.trim(),
        ].join(' '),
      );
    }
    return null;
  }
}

class SettingsSaveUnconfirmed implements Exception {
  const SettingsSaveUnconfirmed();
}

class SettingsEditConflict extends AdministrationFailure {
  SettingsEditConflict(Map<String, Object?> values)
    : values = Map.unmodifiable({
        for (final entry in values.entries)
          entry.key: immutableSetting(entry.value),
      }),
      super(
        'These settings changed elsewhere. Compare the values below, then save your choices.',
      );
  final Map<String, Object?> values;
}

bool _diagnosticWasNotSent(Object error) {
  if (error is DashboardRequestNotSentException) {
    return isTemporaryWorkspaceFailure(error.cause);
  }
  // Linux/Android connect and name-resolution errors. Deliberately exclude
  // timeouts, broken pipes and connection resets, which can follow delivery.
  if ((Platform.isAndroid || Platform.isLinux) && error is SocketException) {
    return {-2, -3, 7, 101, 111, 113}.contains(error.osError?.errorCode);
  }
  return false;
}

class AdministrationFailure implements Exception {
  final String message;
  // Only operation-specific presenters should display this, after redaction.
  final String? serverError;
  const AdministrationFailure(this.message, {this.serverError});
  factory AdministrationFailure.rejected(Map<String, dynamic> result) =>
      AdministrationFailure(
        'The server rejected this change.',
        serverError: result['error'] is String
            ? result['error'] as String
            : null,
      );
  @override
  String toString() => message;
}

String administrationError(Object error, {bool writing = false}) {
  if (error is AdministrationFailure) {
    return error.message;
  }
  if (error is DashboardHttpException &&
      {404, 405, 501}.contains(error.statusCode)) {
    return 'This information is unavailable on this server. Refresh or check the connection.';
  }
  return writing
      ? 'The result could not be confirmed. Your edits are kept. Refresh before retrying.'
      : 'Could not load this information. Check the connection and retry.';
}

List<Map<String, dynamic>> administrationRows(Object? value) {
  if (value is! List || value.any((row) => row is! Map)) {
    throw const FormatException('Invalid administration list');
  }
  return value.map((row) => Map<String, dynamic>.from(row as Map)).toList();
}
