import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/profile_connectors.dart';
import 'connection_manager.dart' show DashboardHttpException;
import 'administration_repository.dart';
import 'mcp_error.dart';
import 'ws_client.dart';

enum McpAuthentication { browser, bearer, none, headers }

String mcpOperationError(Object error, String summary) =>
    mcpErrorMessage(switch (error) {
      AdministrationFailure(:final serverError, :final message) =>
        serverError ?? message,
      JsonRpcError(:final message) => message,
      _ => null,
    }, summary: summary);

/// New-connector provisioning only. Editing an existing auth mode would need
/// deletion semantics that stock deep-merge configuration writes do not offer.
class McpSetup {
  final String name;
  final String address;
  final bool subprocess;
  final List<String> arguments;
  final McpAuthentication authentication;
  final String token;
  final Map<String, String> credentials;
  final String clientId;
  final String clientSecret;
  final String tokenEndpointAuthMethod;
  final String scope;
  final String redirect;
  final String clientCert;
  final String clientKey;
  final String caPath;

  McpSetup({
    required this.name,
    required this.address,
    this.subprocess = false,
    List<String> arguments = const [],
    this.authentication = McpAuthentication.browser,
    this.token = '',
    Map<String, String> credentials = const {},
    this.clientId = '',
    this.clientSecret = '',
    this.tokenEndpointAuthMethod = '',
    this.scope = '',
    this.redirect = '',
    this.clientCert = '',
    this.clientKey = '',
    this.caPath = '',
  }) : arguments = List.unmodifiable(arguments),
       credentials = Map.unmodifiable(credentials);

  void validate() {
    void require(bool valid, String reason) {
      if (!valid) throw AdministrationFailure(reason);
    }

    require(
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$').hasMatch(name),
      'Use a connector name with letters, numbers, dashes or underscores.',
    );
    require(
      address.trim().isNotEmpty,
      subprocess ? 'Enter a command.' : 'Enter the MCP address.',
    );
    if (!subprocess) {
      final uri = Uri.tryParse(address);
      require(
        uri != null &&
            {'http', 'https'}.contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            !uri.hasFragment,
        'Enter an HTTP or HTTPS address without embedded credentials.',
      );
      if (authentication == McpAuthentication.bearer) {
        require(token.trim().isNotEmpty, 'Enter the API key or bearer token.');
      }
      if (authentication == McpAuthentication.headers) {
        require(
          credentials.isNotEmpty,
          'Add at least one authentication header.',
        );
      }
      require(
        {
          '',
          'none',
          'client_secret_post',
          'client_secret_basic',
        }.contains(tokenEndpointAuthMethod),
        'Choose a supported client authentication method.',
      );
      require(
        authentication != McpAuthentication.browser ||
            clientSecret.isEmpty ||
            clientId.isNotEmpty,
        'Enter the client ID for this client secret.',
      );
      if (authentication == McpAuthentication.browser && redirect.isNotEmpty) {
        final uri = Uri.tryParse(redirect);
        require(
          uri != null &&
              {'http', 'https'}.contains(uri.scheme) &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty &&
              !uri.hasQuery &&
              !uri.hasFragment,
          'Enter the exact registered callback address without query parameters.',
        );
      }
      require(
        clientKey.isEmpty || clientCert.isNotEmpty,
        'Enter the certificate path for this private key.',
      );
    }
    final keyPattern = subprocess
        ? RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$')
        : RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
    for (final entry in credentials.entries) {
      require(
        keyPattern.hasMatch(entry.key) &&
            entry.value.isNotEmpty &&
            (subprocess || !entry.value.contains(RegExp(r'[\r\n]'))),
        subprocess
            ? 'Enter a valid environment variable name and value.'
            : 'Enter a valid header name and value.',
      );
    }
  }
}

/// Raw editor inputs. The owner, not TextEditingControllers, interprets them.
final class McpSetupInput {
  McpSetupInput({
    this.name = '',
    this.address = '',
    this.subprocess = false,
    this.arguments = '',
    this.authentication = McpAuthentication.browser,
    this.token = '',
    Iterable<(String, String)> credentials = const [],
    this.clientId = '',
    this.clientSecret = '',
    this.tokenEndpointAuthMethod = '',
    this.scope = '',
    this.redirect = '',
    this.clientCert = '',
    this.clientKey = '',
    this.caPath = '',
  }) : credentials = List.unmodifiable(credentials);
  final String name,
      address,
      arguments,
      token,
      clientId,
      clientSecret,
      tokenEndpointAuthMethod,
      scope,
      redirect,
      clientCert,
      clientKey,
      caPath;
  final bool subprocess;
  final McpAuthentication authentication;
  final List<(String, String)> credentials;
  bool get dirty =>
      subprocess ||
      authentication != McpAuthentication.browser ||
      tokenEndpointAuthMethod.isNotEmpty ||
      [
        name,
        address,
        arguments,
        token,
        clientId,
        clientSecret,
        scope,
        redirect,
        clientCert,
        clientKey,
        caPath,
      ].any((s) => s.isNotEmpty) ||
      credentials.any((row) => row.$1.isNotEmpty || row.$2.isNotEmpty);
  McpSetup resolve() {
    final values = <String, String>{};
    if (subprocess || authentication == McpAuthentication.headers) {
      for (final row in credentials) {
        final key = row.$1.trim();
        if (values.containsKey(key) ||
            !subprocess &&
                values.keys.any((k) => k.toLowerCase() == key.toLowerCase())) {
          throw const AdministrationFailure(
            'Each credential needs a different name.',
          );
        }
        values[key] = row.$2;
      }
    }
    return McpSetup(
      name: name.trim(),
      address: address.trim(),
      subprocess: subprocess,
      arguments: arguments
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      authentication: authentication,
      token: token.trim(),
      credentials: values,
      clientId: clientId.trim(),
      clientSecret: clientSecret,
      tokenEndpointAuthMethod: tokenEndpointAuthMethod,
      scope: scope.trim(),
      redirect: redirect.trim(),
      clientCert: clientCert.trim(),
      clientKey: clientKey.trim(),
      caPath: caPath.trim(),
    );
  }
}

/// New-connector provisioning; no catalog cache or existing-config editor.
class McpSetupSession extends ChangeNotifier {
  McpSetupSession(this._profile) {
    _profile.server.retain();
  }
  final ProfileAdministration _profile;
  String get profileName => _profile.name;
  String get scopeLabel => _profile.label;
  McpSetupInput _input = McpSetupInput();
  McpSetupInput get input => _input;
  bool _busy = false, _review = false, _disposed = false;
  int _revision = 0, _notificationDepth = 0;
  String? _error;
  bool get busy => _busy;
  bool get reviewRequired => _review;
  bool get dirty => _input.dirty;
  String? get error => _error;
  void _emit() {
    if (_disposed) return;
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  void edit(McpSetupInput input) {
    if (_disposed || _busy || _review) return;
    _input = input;
    _error = null;
    _revision++;
    _emit();
  }

  Future<ProfileConnector?> save() async {
    if (_disposed || _busy || _review) return null;
    final McpSetup setup;
    try {
      setup = _input.resolve();
      setup.validate();
    } catch (failure) {
      _error = mcpOperationError(failure, 'Check the connector settings.');
      _emit();
      return null;
    }
    final revision = ++_revision;
    bool active() => !_disposed && revision == _revision;
    var affected = false, createDispatched = false;
    _busy = true;
    _error = null;
    _profile.server.retain();
    _emit();
    try {
      if (!active()) return null;
      await _profile.requireProfile();
      if (!active()) return null;
      final listing = await _profile.rpc('mcp.servers.list');
      final existing = ProfileConnector.decodeList(listing);
      if (!active()) return null;
      if (existing.any((row) => row.name == setup.name)) {
        throw const AdministrationFailure(
          'A connector with this name already exists. Open it from the connector list.',
        );
      }
      final random = Random.secure();
      final suffix = List.generate(
        16,
        (_) => random.nextInt(16).toRadixString(16),
      ).join().toUpperCase();
      final secrets = <String, String>{};
      final prefix = 'MCP_WING_$suffix';
      String reference(String suffix, String value) {
        final key = '${prefix}_$suffix';
        secrets[key] = value;
        return '\${$key}';
      }

      final config = <String, dynamic>{
        if (setup.subprocess)
          'command': setup.address
        else
          'url': setup.address,
        if (setup.subprocess) 'args': setup.arguments,
      };
      if (setup.subprocess ||
          setup.authentication == McpAuthentication.headers) {
        var index = 0;
        config[setup.subprocess ? 'env' : 'headers'] = {
          for (final entry in setup.credentials.entries)
            entry.key: reference('VALUE_${index++}', entry.value),
        };
      }
      if (!setup.subprocess &&
          setup.authentication == McpAuthentication.browser) {
        config['auth'] = 'oauth';
        config['oauth'] = {
          if (setup.clientId.isNotEmpty) 'client_id': setup.clientId,
          if (setup.tokenEndpointAuthMethod.isNotEmpty)
            'token_endpoint_auth_method': setup.tokenEndpointAuthMethod,
          if (setup.clientSecret.isNotEmpty)
            'client_secret': reference('CLIENT_SECRET', setup.clientSecret),
          if (setup.scope.isNotEmpty) 'scope': setup.scope,
          if (setup.redirect.isNotEmpty) 'redirect_uri': setup.redirect,
        };
      }
      if (!setup.subprocess) {
        if (setup.clientCert.isNotEmpty) {
          config['client_cert'] = setup.clientCert;
        }
        if (setup.clientKey.isNotEmpty) config['client_key'] = setup.clientKey;
        if (setup.caPath.isNotEmpty) config['ssl_verify'] = setup.caPath;
      }
      for (final entry in secrets.entries) {
        await _profile.requireProfile();
        if (!active()) return null;
        final ack = await _profile.server.ownedMutation(
          'PUT',
          'env',
          {'profile': profileName},
          {'key': entry.key, 'value': entry.value, 'profile': profileName},
          active,
          () => affected = true,
        );
        if (ack['ok'] != true || ack['key'] != entry.key) {
          throw const FormatException('Credential save was not acknowledged');
        }
        if (!active()) return null;
      }
      await _profile.requireProfile();
      if (!active()) return null;
      final result = await _profile.gateway.mcpCommand(
        'add',
        {
          'name': setup.name,
          'config': config,
          if (!setup.subprocess &&
              setup.authentication == McpAuthentication.bearer)
            'bearer_token': setup.token,
        },
        canDispatch: active,
        onDispatched: () {
          affected = true;
          createDispatched = true;
        },
      );
      if (result['ok'] != true ||
          result['name'] != setup.name ||
          result['server'] is! Map) {
        throw const FormatException('Connector setup was not acknowledged');
      }
      final created = ProfileConnector.decode(result['server'] as Map);
      if (created.name != setup.name) {
        throw const FormatException('Wrong connector setup acknowledgement');
      }
      if (!active()) return null;
      return created;
    } catch (failure) {
      if (active()) {
        // Credential writes and create are not an atomic server transaction.
        _review = affected && (!createDispatched || !_knownRejection(failure));
        _error = mcpOperationError(
          failure,
          _review
              ? 'Check the connector list before retrying.'
              : 'Connector setup did not complete.',
        );
      }
      return null;
    } finally {
      _profile.server.release();
      if (active()) {
        _busy = false;
        _emit();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_revision;
    _profile.server.release();
    if (_notificationDepth == 0) super.dispose();
  }
}

bool _knownRejection(Object failure) =>
    failure is DashboardHttpException &&
    const {400, 401, 403, 404, 405, 409, 422}.contains(failure.statusCode);
