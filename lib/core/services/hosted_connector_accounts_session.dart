import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/hosted_connector_accounts.dart';
import 'administration_repository.dart';
import 'ws_client.dart';

/// One captured profile's hosted accounts. Catalog reads never create an
/// identity. Only an explicit connect starts authorization; no uncertain write
/// is retried automatically. Leaving retires polling and pre-dispatch authority.
class HostedConnectorAccountsSession extends ChangeNotifier {
  HostedConnectorAccountsSession(this.profile) {
    profile.server.retain();
  }
  final ProfileAdministration profile;
  List<HostedConnector> _catalog = const [];
  List<HostedConnectorAccount> _accounts = const [];
  HostedConnectionOperation? _operation;
  bool _disposed = false,
      _loading = false,
      _busy = false,
      _observed = false,
      _verified = false,
      _active = true;
  String? _error;
  int _generation = 0;
  Timer? _poll;

  List<HostedConnector> get catalog => _catalog;
  List<HostedConnectorAccount> get accounts => _accounts;
  HostedConnectionOperation? get operation => _operation;
  bool get loading => _loading;
  bool get busy => _busy;
  bool get hasObservation => _observed;
  bool get canMutate => !_disposed && !_loading && !_busy && _verified;
  String? get error => _error;
  String get scopeLabel => profile.label;
  bool _owns(int generation) => !_disposed && generation == _generation;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed || _busy || _loading) return;
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _poll?.cancel();
    _emit();
    try {
      final values = await Future.wait([
        profile.rpc('connectors.catalog'),
        profile.rpc('connectors.accounts'),
      ]);
      final catalog = HostedConnector.decode(values[0]);
      final accounts = HostedConnectorAccount.decode(values[1]);
      if (!_owns(generation)) return;
      _catalog = catalog;
      _accounts = accounts;
      _observed = _verified = true;
      await _readOperation(generation);
    } catch (failure) {
      if (_owns(generation)) {
        _verified = false;
        _error = administrationError(failure);
      }
    } finally {
      if (_owns(generation)) {
        _loading = false;
        _emit();
        _schedulePoll();
      }
    }
  }

  Future<Map<String, dynamic>> _dispatch(
    String method,
    Map<String, dynamic> params,
    int generation,
    void Function() onDispatched,
  ) async {
    await profile.requireProfile();
    if (!_owns(generation)) throw StateError('Connector page closed');
    await profile.gateway.connect();
    if (!_owns(generation)) throw StateError('Connector page closed');
    // No await between this lifetime check and the scoped transport call.
    onDispatched();
    return profile.gateway.call(method, params);
  }

  Future<bool> _mutate(
    String method,
    Map<String, dynamic> params,
    void Function(Map<String, dynamic>) accept, {
    bool Function(List<HostedConnectorAccount>)? confirmsAccounts,
  }) async {
    if (!canMutate) return false;
    final generation = ++_generation;
    _busy = true;
    _error = null;
    _poll?.cancel();
    _emit();
    profile.server.retain();
    var dispatched = false, acknowledged = false;
    try {
      final result = await _dispatch(
        method,
        params,
        generation,
        () => dispatched = true,
      );
      if (!_owns(generation)) return false;
      if (result['ok'] == false) throw AdministrationFailure.rejected(result);
      accept(result);
      acknowledged = true;
      final accounts = HostedConnectorAccount.decode(
        await profile.rpc('connectors.accounts'),
      );
      if (!_owns(generation)) return false;
      _accounts = accounts;
      if (confirmsAccounts != null && !confirmsAccounts(accounts)) {
        throw const FormatException(
          'The account change was not confirmed by the refreshed list',
        );
      }
      _verified = true;
      return true;
    } catch (failure) {
      if (_owns(generation)) {
        final rejected =
            !acknowledged &&
            failure is JsonRpcError &&
            {
              'INVALID_PARAMS',
              'ALIAS_TAKEN',
              'NEEDS_NOUS_AUTH',
              'NOT_OWNER',
              'CONNECTION_NOT_FOUND',
              'CONNECTOR_NOT_FOUND',
              'FORBIDDEN_SCOPE',
              'ORG_REQUIRED',
              'ORG_ACCESS_DENIED',
            }.contains(failure.reason);
        _verified = !dispatched || rejected;
        final reason = failure is JsonRpcError ? failure.reason : null;
        _error = switch (reason) {
          'ALIAS_TAKEN' =>
            'That account name is already used. Choose another name.',
          'NEEDS_NOUS_AUTH' => 'Sign in to Nous for this profile, then retry.',
          'NOT_OWNER' || 'FORBIDDEN_SCOPE' || 'ORG_ACCESS_DENIED' =>
            'This profile does not have access to that account.',
          'ORG_REQUIRED' =>
            'Select an organization in your Nous account before continuing.',
          _ =>
            _verified
                ? administrationError(failure)
                : 'The result could not be confirmed. Refresh accounts before trying again.',
        };
      }
      return false;
    } finally {
      profile.server.release();
      if (_owns(generation)) {
        _busy = false;
        _emit();
        _schedulePoll();
      }
    }
  }

  Future<bool> rename(HostedConnectorAccount account, String alias) async {
    if (!_accounts.contains(account) || !validHostedAccountAlias(alias)) {
      return false;
    }
    return _mutate(
      'connectors.accounts.rename',
      {'connection_id': account.id, 'alias': alias},
      (result) {
        final updated = HostedConnectorAccount.fromJson(result);
        if (updated.id != account.id || updated.alias != alias) {
          throw const FormatException('Account name was not confirmed');
        }
      },
      confirmsAccounts: (rows) =>
          rows.any((row) => row.id == account.id && row.alias == alias),
    );
  }

  Future<bool> remove(HostedConnectorAccount account) async {
    if (!_accounts.contains(account)) return false;
    return _mutate(
      'connectors.accounts.remove',
      {'connection_id': account.id},
      (result) {
        if (result['connection_id'] != account.id ||
            result['status'] != 'removed') {
          throw const FormatException('Account removal was not confirmed');
        }
      },
      confirmsAccounts: (rows) => !rows.any((row) => row.id == account.id),
    );
  }

  Future<bool> connect(
    HostedConnector connector, {
    String? alias,
    HostedConnectorAccount? reconnect,
  }) async {
    if (!_catalog.contains(connector) ||
        alias != null && !validHostedAccountAlias(alias) ||
        reconnect != null &&
            (!_accounts.contains(reconnect) ||
                reconnect.disabled ||
                reconnect.connector != connector.slug)) {
      return false;
    }
    return _mutate(
      'connectors.connect',
      {
        'owner': {'type': 'account'},
        'connectors': [connector.slug],
        'alias': ?alias,
        if (reconnect != null) ...{
          'reconnect': true,
          'connection_id': reconnect.id,
        },
      },
      (result) => _operation = HostedConnectionOperation.fromJson(result),
    );
  }

  void setActive(bool active) {
    _active = active;
    _poll?.cancel();
    if (active) _schedulePoll();
  }

  Future<void> checkAuthorization() async {
    if (_disposed || _loading || _busy || _operation == null) return;
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _emit();
    try {
      await _readOperation(generation);
    } catch (failure) {
      if (_owns(generation)) _error = administrationError(failure);
    } finally {
      if (_owns(generation)) {
        _loading = false;
        _emit();
        _schedulePoll();
      }
    }
  }

  Future<void> _readOperation(int generation) async {
    final operation = _operation;
    if (operation == null || operation.settled) return;
    final result = HostedConnectionOperation.fromJson(
      await profile.rpc('connectors.operation.status', {
        'owner': {'type': 'account'},
        'op_id': operation.id,
      }),
    );
    if (!_owns(generation) || _operation?.id != operation.id) return;
    if (result.id != operation.id) {
      throw const FormatException('Wrong connector operation');
    }
    if (result.sequence <= _operation!.sequence) return;
    _operation = result;
    if (result.settled || result.targets.any((target) => target.connected)) {
      final accounts = HostedConnectorAccount.decode(
        await profile.rpc('connectors.accounts'),
      );
      if (_owns(generation)) _accounts = accounts;
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (_disposed ||
        !_active ||
        _loading ||
        _busy ||
        _operation == null ||
        _operation!.settled) {
      return;
    }
    final generation = _generation;
    _poll = Timer(const Duration(seconds: 3), () async {
      try {
        await _readOperation(generation);
      } catch (failure) {
        if (_owns(generation)) _error = administrationError(failure);
      }
      if (_owns(generation)) {
        _emit();
        _schedulePoll();
      }
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _poll?.cancel();
    profile.server.release();
    super.dispose();
  }
}
