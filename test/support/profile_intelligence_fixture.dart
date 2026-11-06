import 'dart:async';

import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'profile_browser_fixture.dart';

/// Isolated gateway responses for the real profile screen/controller device check.
class ProfileIntelligenceFixture extends ProfileBrowserFixture {
  static const modelWarning = '''!!! LARGE CONTEXT MODEL SWITCH !!!

This session holds ~169,028 tokens of context.
Switching to gpt-5.6-sol makes the next reply re-read all of it uncached (providers key prompt caches per model) — a one-time full-price input cost.

Threshold: model.switch_context_confirm_tokens (currently 100,000; 0 disables this check).
Confirm only if you intend to switch now.''';
  int _createdSessions = 0;
  final writes = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic>)? onAcceptedWrite;
  String? resumedRuntimeId;
  bool failReasoning = false;
  bool deferMutation = false;
  bool failFast = false;
  String fastMode = 'normal';
  bool confirmModel = false;
  bool repeatConfirmation = false;
  bool failConfirmedModel = false;
  bool codexAppearsOnRefresh = false;
  bool mixedCatalog = false;
  final modelOptionReads = <Map<String, String>>[];
  Completer<void>? configGetStarted;
  Completer<void>? configGetDelay;
  Completer<void>? configSetDelay;
  Completer<Map<String, dynamic>>? contextResponse;
  Map<String, dynamic> contextStats = const {};
  String configGetValue = 'high';
  String resumedReasoningEffort = 'high';
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: (path, query) async {
        if (path == 'model/info') {
          return {'model': 'gpt-6-astra', 'provider': 'openai-codex'};
        }
        if (path == 'model/options') {
          modelOptionReads.add(Map.of(query));
          return {
            'providers': [
              if (mixedCatalog)
                {
                  'slug': 'openrouter',
                  'name': 'OpenRouter',
                  'models': ['gpt-6.1-sol', 'anthropic/claude-sonnet-4.6'],
                },
              if (!codexAppearsOnRefresh || query['refresh'] == '1')
                {
                  'slug': 'openai-codex',
                  'name': 'OpenAI subscription',
                  'models': [
                    'gpt-6-astra',
                    'gpt-5.6-sol',
                    'gpt-5.4-mini',
                    if (mixedCatalog) 'gpt-6.1-sol',
                  ],
                  'capabilities': {
                    for (final model in [
                      'gpt-6-astra',
                      'gpt-5.6-sol',
                      'gpt-5.4-mini',
                      if (mixedCatalog) 'gpt-6.1-sol',
                    ])
                      model: {'reasoning': true, 'fast': true},
                  },
                },
              if (codexAppearsOnRefresh && query['refresh'] != '1')
                {
                  'slug': 'openrouter',
                  'name': 'OpenRouter',
                  'models': ['openai/gpt-6-astra'],
                },
            ],
          };
        }
        return base.read(path, query);
      },
      rpc: (method, params) async {
        if (method == 'session.stats') return contextStats;
        if (method == 'session.context_breakdown' && contextResponse != null) {
          return contextResponse!.future;
        }
        if (method == 'config.get') {
          if (params['key'] == 'fast') return {'value': fastMode};
          if (params['key'] != 'reasoning') {
            throw StateError('Unexpected intelligence read: ${params['key']}');
          }
          final started = configGetStarted;
          if (started != null && !started.isCompleted) started.complete();
          await configGetDelay?.future;
          return {'value': configGetValue};
        }
        if (method == 'session.mutate') {
          final operation = params['operation'];
          final payload = Map<String, dynamic>.from(params['payload'] as Map);
          writes.add(Map.of(params));
          await configSetDelay?.future;
          if (payload['confirm'] != null && failConfirmedModel) {
            throw StateError('Model rejected');
          }
          if (operation == 'model' &&
              confirmModel &&
              (payload['confirm'] == null || repeatConfirmation)) {
            return {
              'status': 'confirmation_required',
              'confirm_required': true,
              'confirm': 'fixture-model-confirmation',
              'confirm_message': modelWarning,
            };
          }
          if ((operation == 'reasoning' ||
                  (operation == 'model' && payload.containsKey('reasoning'))) &&
              failReasoning) {
            throw StateError('Reasoning rejected');
          }
          onAcceptedWrite?.call(params);
          canonicalRevisions['${scope.profileName}:${params['session_id']}'] =
              (params['expected_revision'] as int) + 1;
          return {
            'session_id': params['session_id'],
            'operation': operation,
            'status': deferMutation ? 'deferred' : 'applied',
            'revision': (params['expected_revision'] as int) + 1,
            'execution_generation': params['expected_generation'],
          };
        }
        if (method == 'config.set') {
          if (params['key'] != 'fast') {
            throw StateError('Unexpected intelligence write: ${params['key']}');
          }
          writes.add(Map.of(params));
          await configSetDelay?.future;
          if (failFast) throw StateError('Fast rejected');
          fastMode = params['value'] as String;
          onAcceptedWrite?.call(params);
          return {'status': 'ok', 'value': params['value']};
        }
        final result = await base.call(method, params);
        if (method == 'session.resume' || method == 'session.create') {
          if (method == 'session.create') _createdSessions++;
          return {
            ...result,
            if (method == 'session.create' && _createdSessions > 1) ...{
              'session_id': 'runtime-$_createdSessions',
              'stored_session_id': 'new-chat-$_createdSessions',
            },
            if (method == 'session.resume' && resumedRuntimeId != null)
              'session_id': resumedRuntimeId,
            'info': {
              'profile_name': scope.profileName,
              'model': 'gpt-6-astra',
              'provider': 'openai-codex',
              'reasoning_effort': resumedReasoningEffort,
            },
          };
        }
        return result;
      },
    );
  }
}
