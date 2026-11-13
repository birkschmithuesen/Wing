import 'dart:async';
import 'dart:convert';
import 'package:wing/core/models/models_dev_prices.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_gateway.dart';

class AdministrationFixture {
  final String id;
  ModelsDevPrices apiPrices = subscriptionApiPrices();
  final pricingRefreshes = <bool>[];
  Completer<ModelsDevPrices>? pricingGate;
  bool failPricing = false;
  final rpcRequests = <(String, String)>[];
  final requests =
      <(String, String, Map<String, String>, Map<String, dynamic>?)>[];
  final configs = <String, Map<String, dynamic>>{
    'default': {
      'memory': {'memory_enabled': true, 'memory_char_limit': 1500},
    },
    'personal': {
      'memory': {'memory_enabled': true, 'memory_char_limit': 2000},
      'agent': {'max_turns': 20},
      'unrelated': {'keep': true},
    },
    'work': {
      'memory': {'memory_enabled': false, 'memory_char_limit': 3000},
    },
  };
  Map<String, dynamic> updateCheck = {
    'current_version': '1.2.3',
    'install_method': 'git',
    'behind': 3,
    'update_available': true,
    'can_apply': true,
    'commits': [
      {
        'summary': 'Keep scheduled tasks running after reconnecting',
        'sha': 'abc1234',
        'author': 'Example contributor',
        'at': 1789646400,
      },
      {
        'summary':
            'Improve tool discovery for profiles with their own connectors',
        'sha': 'def5678',
        'author': 'Another contributor',
        'at': 1789560000,
      },
    ],
  };
  bool reject = false;
  bool ignoreSave = false;
  bool rootIsDefault = true;
  bool failReads = false;
  Completer<void>? writeGate;
  AdministrationRequest? override;
  AdministrationMutation? mutationOverride;
  int settingsDispatches = 0;
  ScopedRpc? rpcOverride;
  Future<String> Function(String profile, String command, {bool confirm})?
  consoleOverride;
  final consoleRequests = <(String, String, bool)>[];
  late final AdministrationRepository server = AdministrationRepository(
    apiPricing: ({refresh = false}) async {
      pricingRefreshes.add(refresh);
      if (failPricing) throw TimeoutException('API pricing unavailable');
      return pricingGate == null ? apiPrices : await pricingGate!.future;
    },
    ownedMutation:
        (method, path, query, body, canDispatch, onDispatched) async {
          if (mutationOverride case final mutation?) {
            return mutation(
              method,
              path,
              query,
              body,
              canDispatch,
              onDispatched,
            );
          }
          if (!canDispatch()) throw StateError('Owned fixture command retired');
          onDispatched();
          return send(method, path, query, body);
        },
    settingsWrite: (name, patch, canDispatch, onDispatched) async {
      if (!canDispatch()) throw const SettingsEditRetired();
      settingsDispatches++;
      onDispatched();
      return send(
        'PUT',
        'config',
        {'profile': name},
        {'profile': name, 'config': patch},
      );
    },
    connectionId: id,
    connectionIdentity: '$id-endpoint',
    connectionLabel: id,
    request: send,
    providerCommand:
        (
          profile,
          command, {
          confirm = false,
          required canDispatch,
          required onDispatched,
        }) async {
          if (!canDispatch()) {
            throw StateError('Recovery fixture command retired');
          }
          if (confirm) {
            onDispatched();
          }
          consoleRequests.add((profile, command, confirm));
          if (consoleOverride == null) {
            throw StateError('Unexpected console command');
          }
          return consoleOverride!(profile, command, confirm: confirm);
        },
    gateway: (name) => ProfileGateway(
      scope: WorkspaceScope(connectionId: id, profileName: name),
      get: (path, query) => send('GET', path, query, null),
      ownedPut: (path, body, canDispatch, onDispatched) => server.ownedMutation(
        'PUT',
        Uri.parse(path).path,
        Uri.parse(path).queryParameters,
        body,
        canDispatch,
        onDispatched,
      ),
      rpc: (method, params) async {
        rpcRequests.add((name, method));
        if (rpcOverride != null) return rpcOverride!(method, params);
        if (method == 'plugins.manage' && params['action'] == 'list') {
          return {'plugins': []};
        }
        if (method == 'reload.mcp') return {'status': 'reloaded'};
        if (method == 'mcp.servers.status' && override == null) {
          // This fixture's unoverridden configuration has no MCP servers.
          return {
            'servers': [],
            'checked_at': DateTime.now().millisecondsSinceEpoch,
          };
        }
        throw StateError('Unexpected fixture RPC $method $params');
      },
      discover: () => server.discover(),
    ),
  );
  AdministrationFixture([this.id = 'Server A']);
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    requests.add((method, path, {...query}, body == null ? null : {...body}));
    if (override != null) return override!(method, path, query, body);
    if (method != 'GET' && !(method == 'PUT' && path == 'config')) {
      throw StateError('Unexpected fixture request $method $path');
    }
    if (method == 'GET' && failReads) throw StateError('Offline');
    if (path == 'health') {
      return {'ok': true, 'version': updateCheck['current_version']};
    }
    if (path == 'hermes/update/check') return updateCheck;
    if (path == 'profiles') {
      return {
        'profiles': [
          for (final name in configs.keys)
            {
              'name': name,
              'is_default': name == 'default' && rootIsDefault,
              'display_name': name == 'default' ? 'Shared root' : name,
            },
        ],
      };
    }
    if (path == 'profiles/active') {
      return {'current': 'default', 'active': 'work'};
    }
    final name = query['profile'];
    if (path == 'config') {
      if (method == 'PUT') {
        if (writeGate != null) await writeGate!.future;
        if (reject) return {'ok': false};
        if (!ignoreSave) _merge(configs[name]!, body!['config'] as Map);
        return {'ok': true};
      }
      return jsonDecode(jsonEncode(configs[name])) as Map<String, dynamic>;
    }
    if (path == 'config/schema') {
      return {
        'fields': {
          'memory.memory_enabled': {'type': 'boolean'},
          'memory.memory_char_limit': {'type': 'number'},
        },
      };
    }
    if (path == 'learning/graph') return {'memory': [], 'nodes': []};
    if (path == 'model/info') {
      return {'provider': 'Example provider', 'model': 'Research model'};
    }
    if (path == 'model/options') {
      return {
        'providers': [
          {
            'slug': 'example',
            'name': 'Example',
            'models': ['second', 'backup-model'],
          },
        ],
      };
    }
    if (path == 'tools/toolsets') return {'data': []};
    if (path == 'cron/jobs') return {'data': []};
    if (path == 'mcp/servers') return {'servers': []};
    if (path == 'skills') return {'data': []};
    if (path == 'providers/oauth') return {'providers': []};
    if (path == 'env') return {};
    throw StateError('Unexpected $method $path');
  }

  void _merge(Map target, Map patch) {
    for (final key in patch.keys) {
      if (target[key] is Map && patch[key] is Map) {
        _merge(target[key] as Map, patch[key] as Map);
      } else {
        target[key] = patch[key];
      }
    }
  }
}

/// Stock Codex model/options has no API prices.
Map<String, dynamic> subscriptionModelOptions() => {
  'providers': [
    {
      'slug': 'openai-codex',
      'name': 'Subscription',
      'models': ['gpt-6-astra', 'gpt-5.6-sol'],
    },
  ],
};

ModelsDevPrices subscriptionApiPrices({double input = 10}) =>
    ModelsDevPrices.fromJson({
      'openai': {
        'models': {
          'gpt-6-astra': {
            'cost': {'input': input, 'cache_read': 1, 'output': 50},
          },
          'gpt-5.6-sol': {
            'cost': {'input': 4, 'cache_read': 0.4, 'output': 20},
          },
        },
      },
    });

AdministrationRequest withSubscriptionModelOptions(
  AdministrationRequest request,
) =>
    (method, path, query, body) => method == 'GET' && path == 'model/options'
    ? Future.value(subscriptionModelOptions())
    : request(method, path, query, body);
