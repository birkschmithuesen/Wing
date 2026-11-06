import 'dart:convert';
import 'package:wing/core/services/connection_manager.dart';
import 'administration_fixture.dart';
import 'model_defaults_fixture.dart';

/// Deterministic observations for rendering and native UI checks; no real server.
class AdministrationDesignFixture extends AdministrationFixture {
  AdministrationDesignFixture() : super('Home server') {
    configs['personal'] = {
      'memory': {
        'memory_enabled': true,
        'user_profile_enabled': true,
        'memory_char_limit': 2400,
        'user_char_limit': 1200,
      },
      'agent': {
        'reasoning_effort': 'high',
        'max_turns': 30,
        'run_budget_seconds': 0,
        'api_max_retries': 3,
      },
      'compression': {
        'enabled': true,
        'threshold': 0.85,
        'target_ratio': 0.5,
        'protect_last_n': 6,
      },
      'approvals': {'mode': 'smart', 'timeout': 60},
    };
  }
  final jobs = <Map<String, dynamic>>[];
  bool partialIdentity = false;
  bool toolEnabled = true;
  String description = 'Research, planning and everyday questions';
  String soul =
      'Be curious and precise.\n\nExplain what you know, what remains uncertain, and how to proceed.\n\nUse clear language. Keep the user in control of consequential decisions.';
  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    final expectedMethod = switch (path) {
      'ops/doctor' => 'POST',
      'profiles/personal/description' || 'tools/toolsets/web' => 'PUT',
      'profiles/personal/soul' when method == 'PUT' => 'PUT',
      'config' when method == 'PUT' => 'PUT',
      _ => 'GET',
    };
    if (method != expectedMethod) {
      throw StateError('Unexpected design request $method $path');
    }
    if (method == 'GET' && path == 'profiles') {
      final result = await super.send(method, path, query, body);
      return {
        ...result,
        'profiles': [
          for (final row in result['profiles'] as List)
            {...row as Map, 'path': '/fixture/${row['name']}'},
        ],
      };
    }
    if (method == 'GET' && path == 'files/read') {
      if (query['path'] != '/fixture/personal/profile.yaml') {
        throw StateError('Unexpected identity metadata scope');
      }
      requests.add((method, path, {...query}, body));
      final bytes = utf8.encode('description: ${jsonEncode(description)}\n');
      return {
        'name': 'profile.yaml',
        'path': '/fixture/personal/profile.yaml',
        'size': bytes.length,
        'mime_type': 'application/octet-stream',
        'data_url':
            'data:application/octet-stream;base64,${base64Encode(bytes)}',
      };
    }
    if (path == 'profiles/personal/soul') {
      requests.add((method, path, {...query}, body));
      if (method == 'GET') return {'content': soul, 'exists': true};
      if (partialIdentity) {
        throw const DashboardHttpException(403, 'profiles/personal/soul');
      }
      soul = body!['content'] as String;
      return {'ok': true};
    }
    if (method == 'PUT' && path == 'profiles/personal/description') {
      requests.add((method, path, {...query}, body));
      description = body!['description'] as String;
      return {
        'ok': true,
        'description': description,
        'description_auto': false,
      };
    }
    if (method == 'PUT' && path == 'tools/toolsets/web') {
      requests.add((method, path, {...query}, body));
      toolEnabled = body!['enabled'] as bool;
      return {'ok': true, 'name': 'web', 'enabled': toolEnabled};
    }
    final result = switch (path) {
      'ops/doctor' => {'ok': true, 'name': 'doctor', 'pid': 11},
      'actions/doctor/status' => {
        'name': 'doctor',
        'pid': 11,
        'running': false,
        'exit_code': 1,
        'lines': [
          'A required dependency was not found. Inspect the server configuration before retrying.',
        ],
      },
      'cron/jobs' => {
        'data': [
          for (final job in jobs)
            {
              ...job,
              'profile': query['profile']!,
              'profile_name': query['profile']!,
            },
        ],
      },
      'providers/oauth' => {
        'providers': [
          {
            'id': 'research',
            'name': 'Research provider',
            'flow': 'device_code',
            'disconnectable': true,
            'status': {
              'logged_in': true,
              'source_label': 'Shared server credentials',
            },
          },
          {
            'id': 'expired',
            'name': 'Expired provider',
            'flow': 'device_code',
            'disconnectable': true,
            'status': {'logged_in': true, 'expires_at': '2020-01-01T00:00:00Z'},
          },
        ],
      },
      'env' => {
        'SEARCH_API_KEY': {
          'provider_label': 'Search service',
          'is_set': false,
          'channel_managed': false,
          'category': 'api_keys',
        },
      },
      'model/info' => {'provider': 'research', 'model': 'Research model'},
      'model/options' => {'providers': []},
      'model/auxiliary' => {
        'tasks': [
          for (final task in ModelDefaultsFixture.tasks)
            {
              'task': task,
              'provider': 'auto',
              'model': '',
              'base_url': '',
              'reasoning_effort': null,
              'local_endpoint': false,
            },
        ],
      },
      'analytics/usage' => {
        'daily': [
          for (var i = 0; i < 7; i++)
            {
              'day': DateTime.now()
                  .toUtc()
                  .subtract(Duration(days: i))
                  .toIso8601String()
                  .substring(0, 10),
              'input_tokens': 10000 + i * 5000,
              'cache_read_tokens': 20000 + i * 3000,
              'output_tokens': 4000 + i * 2000,
            },
        ],
      },
      'analytics/models' => {
        'models': [
          {
            'provider': 'Research provider',
            'model': 'Research model',
            'api_calls': 1234,
            'sessions': 42,
            'input_tokens': 321000,
            'cache_read_tokens': 100000,
            'output_tokens': 42000,
            'estimated_cost': 12.5,
          },
          {
            'provider': 'Local provider',
            'model': 'Local writing model',
            'api_calls': 600,
            'sessions': 12,
            'input_tokens': 98000,
            'cache_read_tokens': 50000,
            'output_tokens': 18000,
            'estimated_cost': 0,
          },
          {
            'provider': 'External provider',
            'model': 'Unreported cost model',
            'api_calls': 22,
            'sessions': 2,
            'input_tokens': 9000,
            'cache_read_tokens': 0,
            'output_tokens': 1000,
          },
        ],
      },
      'learning/graph' => {
        'memory': [
          {
            'title': 'How we work together',
            'body':
                'Prefer clear explanations and practical examples. Show uncertainty openly.',
            'source': 'memory',
            'fingerprint': '111111111111',
          },
        ],
        'nodes': [
          {
            'id': 'memory:memory:0:111111111111',
            'kind': 'memory',
            'label': 'How we work together',
            'memorySource': 'memory',
          },
        ],
      },
      'learning/node' => {
        'ok': true,
        'kind': 'memory',
        'id': 'memory:memory:0:111111111111',
        'label': 'How we work together',
        'content':
            'How we work together\n\nPrefer clear explanations and practical examples. Show uncertainty openly.\n\nKeep research notes concise, with evidence for consequential claims.',
      },
      'skills' => {
        'data': [
          {
            'name': 'research',
            'label': 'Research and source review',
            'enabled': true,
            'category': 'Research',
            'provenance': 'Installed',
            'locked': false,
            'description': 'Investigate a question and compare sources.',
          },
        ],
      },
      'tools/toolsets' => {
        'data': [
          {
            'name': 'web',
            'label': 'Web search and research',
            'enabled': toolEnabled,
            'configured': false,
            'platform_label': 'Available on this server',
            'description': 'Find sources and read web pages.',
            'tools': [],
          },
        ],
      },
      _ => null,
    };
    if (result != null) {
      requests.add((method, path, {...query}, body));
      return result;
    }
    return super.send(method, path, query, body);
  }
}
