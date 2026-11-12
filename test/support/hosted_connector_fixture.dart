import 'dart:async';
import 'administration_fixture.dart';

/// Stock connector contracts, with two same-service accounts to exercise exact
/// identity rather than matching the connector name.
class HostedConnectorFixture extends AdministrationFixture {
  HostedConnectorFixture() {
    rpcOverride = rpc;
  }
  final calls = <(String, Map<String, dynamic>)>[];
  final accounts = <Map<String, dynamic>>[
    account('work-id', 'work'),
    account('personal-id', 'personal'),
  ];
  Completer<void>? mutationGate;
  Completer<void>? accountsGate;
  bool failMutation = false;
  int sequence = 1;
  bool settled = false;
  static Map<String, dynamic> account(String id, String alias) => {
    'connection_id': id,
    'connector': 'calendar',
    'label': 'Calendar account',
    'alias': alias,
    'status': 'active',
    'status_reason': null,
    'active': true,
    'disabled': false,
    'created_at': '2026-10-27T00:00:00Z',
    'updated_at': '2026-10-27T00:00:00Z',
  };
  Map<String, dynamic> operation() => {
    'op_id': 'authorize-1',
    'seq': sequence,
    'deadline_at': 2000000000,
    'settled': settled,
    'targets': [
      {
        'name': 'calendar',
        'kind': 'connector',
        'action': 'authorize',
        'state': settled ? 'connected' : 'initiated',
        'connect_url': 'https://example.invalid/authorize',
        'alias': 'work',
        'detail': settled ? 'Connected' : 'Open sign-in to continue',
      },
    ],
  };
  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method, Map.of(params)));
    switch (method) {
      case 'connectors.catalog':
        return {
          'connectors': [
            {
              'slug': 'calendar',
              'name': 'Calendar',
              'description': 'Read and update events',
              'category': 'productivity',
            },
          ],
        };
      case 'connectors.accounts':
        await accountsGate?.future;
        return {
          'accounts': [for (final account in accounts) Map.of(account)],
        };
      case 'connectors.operation.status':
        return operation();
      case 'connectors.connect':
        await mutationGate?.future;
        if (failMutation) throw TimeoutException('Authorization response lost');
        return operation();
      case 'connectors.accounts.rename':
        await mutationGate?.future;
        if (failMutation) throw TimeoutException('Rename response lost');
        final row = accounts.singleWhere(
          (row) => row['connection_id'] == params['connection_id'],
        );
        row['alias'] = params['alias'];
        return Map.of(row);
      case 'connectors.accounts.remove':
        await mutationGate?.future;
        if (failMutation) throw TimeoutException('Remove response lost');
        accounts.removeWhere(
          (row) => row['connection_id'] == params['connection_id'],
        );
        return {
          'connection_id': params['connection_id'],
          'connector': 'calendar',
          'status': 'removed',
        };
      default:
        throw StateError('Unexpected connector RPC $method');
    }
  }
}
