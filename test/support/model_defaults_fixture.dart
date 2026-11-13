import 'dart:async';
import 'dart:convert';

import 'package:wing/core/services/administration_repository.dart';

import 'administration_fixture.dart';

/// Stock db45b44ab72af81974adfb01c9ecd6967f5bec29 model routes. Holds
/// individual operations explicitly; no sleeps or implicit successful writes.
class ModelDefaultsFixture extends AdministrationFixture {
  ModelDefaultsFixture() : super('Model defaults') {
    this.override = respond;
  }

  @override
  AdministrationRepository get server => _modelServer;
  late final AdministrationRepository _modelServer = AdministrationRepository(
    connectionId: id,
    connectionIdentity: '$id-endpoint',
    connectionLabel: id,
    request: send,
    ownedMutation: mutate,
    settingsWrite: (_, _, _, _) async =>
        throw StateError('This fixture supports helper commands only'),
    gateway: (_) => throw StateError('This fixture does not open model sheets'),
  );

  Completer<void>? mutationGate;
  final mutationEntered = Completer<void>();
  final mutationExited = Completer<void>();
  bool timeoutMutation = false;

  Future<Map<String, dynamic>> mutate(
    String method,
    String endpoint,
    Map<String, String> query,
    Map<String, dynamic> body,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) {
    Future<Map<String, dynamic>> produce() async {
      try {
        if (!mutationEntered.isCompleted) mutationEntered.complete();
        if (mutationGate case final gate?) await gate.future;
        if (!canDispatch()) throw StateError('Owned helper command retired');
        onDispatched();
        return await send(method, endpoint, query, body);
      } finally {
        if (!mutationExited.isCompleted) mutationExited.complete();
      }
    }

    final operation = produce();
    // A real deadline settles the consumer without cancelling its producer.
    // Zero makes the held gate deterministic, without waiting 45 seconds.
    return timeoutMutation ? operation.timeout(Duration.zero) : operation;
  }

  static const tasks = [
    'vision',
    'compression',
    'skills_hub',
    'approval',
    'mcp',
    'title_generation',
    'review',
    'triage_specifier',
    'kanban_decomposer',
    'profile_describer',
    'curator',
  ];
  final helpers = <Map<String, dynamic>>[
    for (final task in tasks)
      {
        'task': task,
        'provider': 'p',
        'model': 'before',
        'base_url': '',
        'reasoning_effort': null,
        'local_endpoint': false,
      },
  ];
  final credentialPresent = <String>{};
  final posts = <Map<String, dynamic>>[];
  List<String> availableModels = ['before', 'after'];
  String provider = 'p', model = 'before';
  bool exists = true,
      requireCost = false,
      failAfterWrite = false,
      failBeforeWrite = false,
      keepResetCredential = false;
  Completer<void>? membership, optionsGate;
  Completer<Map<String, dynamic>>? nextAuxiliary;
  final auxiliaryEntered = Completer<void>();
  final membershipEntered = Completer<void>();
  final optionsEntered = Completer<void>();
  Map<String, dynamic> get vision => helpers.first;
  Map<String, dynamic> copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  Future<Map<String, dynamic>> respond(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    if (method != (path == 'model/set' ? 'POST' : 'GET')) {
      throw StateError('Unexpected helper request $method $path');
    }
    if (path == 'profiles') {
      if (membership != null) {
        if (!membershipEntered.isCompleted) membershipEntered.complete();
        await membership!.future;
      }
      return {
        'profiles': [
          if (exists) {'name': 'personal', 'is_default': false},
        ],
      };
    }
    if (path == 'profiles/active') {
      return {'current': 'personal', 'active': 'work'};
    }
    if (query['profile'] != 'personal') {
      throw StateError('Wrong captured profile');
    }
    if (path == 'model/options') {
      if (optionsGate != null) {
        if (!optionsEntered.isCompleted) optionsEntered.complete();
        await optionsGate!.future;
      }
      return {
        'providers': [
          {
            'slug': 'p',
            'name': 'Provider',
            'models': [
              if (availableModels.contains('before')) 'before',
              if (availableModels.contains('after')) 'after',
            ],
            'capabilities': {
              'before': {'reasoning': true, 'fast': true},
            },
          },
          {
            'slug': 'other',
            'name': 'Other',
            'models': ['other-model'],
          },
        ],
      };
    }
    switch (path) {
      case 'model/info':
        return {'provider': provider, 'model': model};
      case 'model/auxiliary':
        final held = nextAuxiliary;
        nextAuxiliary = null;
        if (held != null) {
          if (!auxiliaryEntered.isCompleted) auxiliaryEntered.complete();
          return held.future;
        }
        return copy({'tasks': helpers});
      case 'providers/oauth':
        return {'providers': []};
      case 'config':
        return {
          'auxiliary': {
            for (final row in helpers)
              row['task'] as String: {
                // Only presence is modeled; no credential values are needed.
                if (credentialPresent.contains(row['task'])) 'api_key': null,
              },
          },
        };
      case 'model/set':
        if (method != 'POST' || body?['profile'] != 'personal') {
          throw StateError('Wrong helper dispatch');
        }
        posts.add(Map.of(body!));
        if (failBeforeWrite) throw TimeoutException('Unknown delivery');
        if (requireCost && body['confirm_expensive_model'] != true) {
          return {
            'ok': false,
            'confirm_required': true,
            'confirm_message': 'Confirm cost',
          };
        }
        for (final row in helpers) {
          if (body['task'] == '__reset__') {
            row.addAll({
              'provider': 'auto',
              'model': '',
              'base_url': '',
              'reasoning_effort': null,
            });
            if (!keepResetCredential) credentialPresent.remove(row['task']);
          } else if (row['task'] == body['task']) {
            final oldProvider = (row['provider'] as String)
                .trim()
                .toLowerCase();
            final newProvider = (body['provider'] as String)
                .trim()
                .toLowerCase();
            if (oldProvider != newProvider && newProvider != 'custom') {
              row['base_url'] = '';
              credentialPresent.remove(row['task']);
            }
            row.addAll({'provider': body['provider'], 'model': body['model']});
          }
        }
        if (failAfterWrite) throw TimeoutException('Acknowledgement lost');
        return {'ok': true};
      default:
        throw StateError('Unexpected $method $path');
    }
  }
}
