import '../../test/support/canonical_gateway_fixture.dart';
import 'dart:async';

import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/ws_client.dart';

import '../../test/support/profile_history_fixture.dart';
import '../../test/support/backend_update_channel_fixture.dart';
import '../../test/support/git_review_fixture.dart';

/// In-memory gateway data for the roadmap emulator suite.
///
/// Every transport boundary is replaced. The widgets and workspace controller
/// are the production implementations, but this fixture cannot reach a Hermes
/// host or submit work to a model.
class RoadmapEmulatorFixture extends ProfileHistoryFixture {
  final updateSource = BackendUpdateChannelFixture();
  final gitReview = GitReviewFixture();
  Completer<void>? branchGate;
  Completer<void>? branchEntered;
  final gateways = <String, Set<ProfileGateway>>{};
  final configWrites = <Map<String, dynamic>>[];
  final intelligenceConfig = {
    'model': 'openai-codex:gpt-6-astra',
    'reasoning': 'high',
    'fast': 'normal',
  };
  int approvalSequence = 0;
  final approvalResponses = <Map<String, dynamic>>[];
  final clarificationResponses = <Map<String, dynamic>>[];
  Completer<void>? clarificationGate;
  final clarificationLocks = <Map<String, dynamic>>[];
  Completer<void>? clarificationLockGate;
  Completer<void>? clarificationRetryGate;
  bool failClarificationSecond = true;
  final commandDispatches = <Map<String, dynamic>>[];
  final projectCreates = <Map<String, dynamic>>[];
  final projectUpdates = <Map<String, dynamic>>[];
  final projectDeletes = <Map<String, dynamic>>[];
  final sensitiveResponses = <Map<String, dynamic>>[];
  final _sensitiveRequests = <String, ({String profile, String runtime})>{};
  final supervisionRequests = <(String, Map<String, dynamic>)>[];
  final administrationReads = <(String, Map<String, String>)>[];
  final administrationRequests = <(String, Map<String, dynamic>)>[];
  final profileIdentityWrites = <(String, Map<String, dynamic>)>[];
  final backendUpdatePosts = <(String, Map<String, dynamic>)>[];
  final diagnosticPosts = <(String, Map<String, dynamic>)>[];
  final diagnosticPids = <String, int>{};
  final answerActionRequests = <(String, Map<String, dynamic>)>[];
  final createdProjects = <String, List<Map<String, dynamic>>>{};
  final answerHistories = <String, List<Map<String, dynamic>>>{};
  final answerParents = <String, String>{};
  final answerRuntimes = <String, String>{};
  final resumedRuntimes = <(String, String), String>{};
  final scopedHistories = <(String, String), List<Map<String, dynamic>>>{};
  String subagentStatus = 'running';
  String subagentOutput = 'Emulator child is checking the release.';
  String goalStatus = 'active';
  String loopStatus = 'active';
  bool runningProcess = true;
  String profileDescription = 'Roadmap profile';
  String profileSoul = 'Be exact.';
  int updateCheckCount = 0;
  bool updateAvailable = true;
  bool answerActionsEnabled = false;
  bool supervisionEnabled = false;
  int _nextAnswerChild = 0;
  int _nextAnswerRow = 1000;
  int _nextDiagnosticPid = 5000;

  @override
  List<Map<String, dynamic>> projects(String profile) => [
    ...super.projects(profile),
    ...createdProjects[profile] ?? const [],
  ];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) =>
      scopedHistories[(profile, id)] ??
      (answerActionsEnabled
          ? _answerHistory(profile, id)
          : [
              for (var i = 1; i <= messageCount; i++)
                {
                  'id': i,
                  'role': i.isEven ? 'assistant' : 'user',
                  'content': i == 618
                      ? 'Roadmap needle: the emulator found this saved answer.'
                      : i == 616
                      ? 'Saved /tmp/roadmap-notes.md for the emulator review.'
                      : '$profile message $i',
                  'display_content': i == 618
                      ? 'Roadmap needle: the emulator found this saved answer.'
                      : i == 616
                      ? 'Saved /tmp/roadmap-notes.md for the emulator review.'
                      : '$profile message $i',
                },
            ]);

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway fixtureGateway;
    fixtureGateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      serverResponse: (requestId, result) async {
        final pending = _sensitiveRequests[requestId];
        if (pending == null || pending.profile != scope.profileName) {
          throw StateError('No secure request belongs to this fixture profile');
        }
        _sensitiveRequests.remove(requestId);
        sensitiveResponses.add({
          'id': requestId,
          'result': Map<String, dynamic>.from(result),
        });
        _emit(
          scope.profileName,
          StreamEvent(
            type: 'request.cancel',
            sessionId: pending.runtime,
            data: {
              'id': requestId,
              'method': 'vault.unlock_prompt',
              'reason': 'resolved',
            },
          ),
        );
      },
      connect: base.connect,
      close: () {
        gateways[scope.profileName]?.remove(fixtureGateway);
        base.close();
      },
      get: (path, query) async {
        if (path == 'profiles') {
          return {
            'profiles': [
              {
                'name': scope.profileName,
                'path': BackendUpdateChannelFixture.home,
              },
            ],
          };
        }
        final metadata = updateSource.read(path, query);
        if (metadata != null) return metadata;
        if (path == 'files') {
          final directory = query['path'] ?? '/srv';
          if (!const {'/srv', '/srv/wing'}.contains(directory)) {
            throw StateError('Unexpected roadmap directory: $directory');
          }
          return {
            'path': directory,
            'parent': directory == '/srv' ? null : '/srv',
            'entries': [
              if (directory == '/srv')
                {'name': 'wing', 'path': '/srv/wing', 'is_directory': true},
            ],
          };
        }
        if (path == 'analytics/usage') {
          administrationReads.add((path, Map<String, String>.from(query)));
          final today = DateTime.now().toUtc();
          return {
            'daily': [
              for (var i = 0; i < 6; i++)
                {
                  'day': today
                      .subtract(Duration(days: i))
                      .toIso8601String()
                      .substring(0, 10),
                  'input_tokens': 5600 + i * 100,
                  'cache_read_tokens': 0,
                  'output_tokens': 780 + i * 10,
                },
            ],
          };
        }
        if (path == 'analytics/models') {
          administrationReads.add((path, Map<String, String>.from(query)));
          return {
            'models': const [
              {
                'model': 'openai/gpt-6-astra',
                'provider': 'openai',
                'sessions': 12,
                'api_calls': 34,
                'input_tokens': 5600,
                'cache_read_tokens': 0,
                'output_tokens': 780,
                'estimated_cost': 1.25,
              },
              {'model': 'local/missing-cost', 'sessions': 1},
            ],
          };
        }
        if (path == 'hermes/update/check') {
          administrationReads.add((path, Map<String, String>.from(query)));
          updateCheckCount++;
          updateSource.fetchedAt++;
          return {
            'current_version': '1.2.3',
            'install_method': 'git',
            'behind': updateAvailable ? 2 : 0,
            'update_available': updateAvailable,
            'can_apply': true,
          };
        }
        if (path == 'health') {
          return {
            'ok': true,
            'version': '1.2.3',
            'commit': BackendUpdateChannelFixture.currentSha,
          };
        }
        if (path == 'model/info') {
          return {'model': 'gpt-6-astra', 'provider': 'openai-codex'};
        }
        if (path == 'model/options') {
          return {
            'providers': [
              {
                'slug': 'openai-codex',
                'name': 'OpenAI subscription',
                'models': ['gpt-6-astra', 'gpt-5.6-sol'],
                'capabilities': {
                  for (final model in ['gpt-6-astra', 'gpt-5.6-sol'])
                    model: {'reasoning': true, 'fast': true},
                },
              },
              {
                'slug': 'nous',
                'name': 'Nous',
                'models': ['large-demo', 'free-demo'],
                'usage_levels': {'large-demo': 'top_tier', 'free-demo': 'free'},
                'plan_usage': {
                  'kind': 'usage_window',
                  'plan': 'Fixture plan',
                  'credits_pay': false,
                  'featured_model_ids': ['free-demo'],
                  'gauges': [
                    {
                      'label': 'day',
                      'scope': 'all',
                      'left_fraction': 0,
                      'style': 'red',
                      'resets_at_ms': 1893456000000,
                    },
                  ],
                },
              },
            ],
          };
        }
        return base.read(path, query);
      },
      ownedPatch: (path, body, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(StateError('Menu retired'));
        }
        onDispatched();
        if (!path.startsWith('sessions/') || body['unread'] != false) {
          throw StateError('Unexpected journey mutation: $path');
        }
        return {'ok': true, ...body};
      },
      ownedPost: (path, body, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(
            StateError('Journey action retired'),
          );
        }
        onDispatched();
        if (path == 'files/mkdir?profile=${scope.profileName}') {
          if (body['path'] != '/srv/wing') {
            throw StateError('Unexpected roadmap mkdir: $body');
          }
          return {
            'ok': true,
            'path': '/srv/wing',
            'entry': {'path': '/srv/wing', 'is_directory': true},
          };
        }
        if (path != 'hermes/update?profile=${scope.profileName}') {
          throw StateError('Unexpected roadmap mutation: $path');
        }
        backendUpdatePosts.add((path, Map<String, dynamic>.from(body)));
        return {
          'ok': true,
          'name': 'hermes-update',
          'pid': 4242,
          'action_id': 'roadmap-update',
        };
      },
      rpc: (method, params) async {
        switch (method) {
          case 'setup.status':
            administrationRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            return {'provider_configured': false};
          case 'setup.runtime_check':
            administrationRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            throw StateError('private roadmap runtime detail');
          case 'profiles.describe':
            administrationRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            return {
              'name': scope.profileName,
              'description': profileDescription,
              'soul': profileSoul,
              'skills': const [],
              'toolsets': const [],
            };
          case 'session.context_breakdown':
            return {
              'context_used': 32768,
              'context_max': 131072,
              'context_percent': 25,
            };
          case 'config.get':
            return switch (params['key']) {
              'reasoning' => {'value': intelligenceConfig['reasoning']},
              'fast' => {'value': intelligenceConfig['fast']},
              _ => throw StateError(
                'Unexpected intelligence key: ${params['key']}',
              ),
            };
          case 'session.mutate':
            canonicalRevisions['${scope.profileName}:${params['session_id']}'] =
                (params['expected_revision'] as int) + 1;
            final operation = params['operation'];
            final payload = Map<String, dynamic>.from(params['payload'] as Map);
            if (operation == 'model' || operation == 'reasoning') {
              if (operation == 'model') {
                intelligenceConfig['model'] =
                    '${payload['provider']}:${payload['model']}';
                intelligenceConfig['reasoning'] =
                    payload['reasoning'] as String;
              } else {
                intelligenceConfig['reasoning'] = payload['effort'] as String;
              }
              configWrites.add(Map<String, dynamic>.from(params));
            } else if (operation == 'branch' && answerActionsEnabled) {
              answerActionRequests.add((
                method,
                Map<String, dynamic>.from(params),
              ));
              if (branchGate != null) {
                branchEntered!.complete();
                await branchGate!.future;
              }
              final source = answerRuntimes[params['session_id']]!;
              final child = 'roadmap-branch-${++_nextAnswerChild}';
              final rows = _answerHistory(scope.profileName, source);
              final through = rows.indexWhere(
                (row) => row['id'] == payload['through_message_id'],
              );
              if (through < 0) throw StateError('Missing branch boundary');
              final copied = rows
                  .take(through + 1)
                  .map((row) => {...row, 'id': ++_nextAnswerRow})
                  .toList();
              answerHistories['${scope.profileName}/$child'] = copied;
              answerParents[child] = source;
              answerRuntimes['runtime-$child'] = child;
              return {
                'session_id': params['session_id'],
                'operation': operation,
                'status': 'applied',
                'branched_session_id': child,
                'revision': (params['expected_revision'] as int) + 1,
                'execution_generation': params['expected_generation'],
              };
            } else if (operation == 'rewind' && answerActionsEnabled) {
              answerActionRequests.add((
                method,
                Map<String, dynamic>.from(params),
              ));
              final id = answerRuntimes[params['session_id']]!;
              final rows = _answerHistory(scope.profileName, id);
              final index = rows.indexWhere(
                (row) => row['id'] == payload['target_message_id'],
              );
              if (index < 0) throw StateError('Missing rewind target');
              rows.removeRange(index, rows.length);
            } else {
              return base.call(method, params);
            }
            return {
              'session_id': params['session_id'],
              'operation': operation,
              'status': 'applied',
              'revision': (params['expected_revision'] as int) + 1,
              'execution_generation': params['expected_generation'],
            };
          case 'config.set':
            final key = params['key'] as String;
            if (!intelligenceConfig.containsKey(key)) {
              throw StateError('Unexpected intelligence key: $key');
            }
            intelligenceConfig[key] = params['value'] as String;
            configWrites.add(Map<String, dynamic>.from(params));
            return {'status': 'ok', 'value': params['value']};
          case 'commands.catalog':
            return {
              'pairs': [
                ['/roadmap-check', 'Run the isolated roadmap check'],
              ],
              'canon': <String, String>{},
              'categories': [
                {
                  'name': 'Checks',
                  'pairs': [
                    ['/roadmap-check', 'Run the isolated roadmap check'],
                  ],
                },
              ],
            };
          case 'complete.slash':
            return {'items': <Map<String, dynamic>>[], 'replace_from': 0};
          case 'command.dispatch':
            commandDispatches.add(Map<String, dynamic>.from(params));
            return {
              'type': 'exec',
              'output': 'Roadmap fixture command complete',
            };
          case 'clarify.lock':
            if (params['request_id'] != 'native-batch' ||
                !{'q1', 'q2'}.contains(params['question_id']) ||
                params['answer'] is! String) {
              throw StateError('Expected the captured whole-set clarification');
            }
            clarificationLocks.add(Map.of(params));
            if (params['question_id'] == 'q1') {
              await clarificationLockGate?.future;
              return {
                'status': 'ok',
                'remaining': ['q2'],
              };
            }
            if (failClarificationSecond) {
              throw StateError('Second answer was not accepted');
            }
            await clarificationRetryGate?.future;
            return {'status': 'ok', 'remaining': []};
          case 'clarify.respond':
            if (params['prompt_id'] is! String ||
                params['execution_generation'] is! int ||
                params['answer'] is! String ||
                params.containsKey('request_id')) {
              throw StateError(
                'Expected a generation-bound clarification response',
              );
            }
            clarificationResponses.add(Map.of(params));
            await clarificationGate?.future;
            return {'status': 'resolved', 'prompt_id': params['prompt_id']};
          case 'approval.respond':
            if (params['prompt_id'] is! String ||
                params['execution_generation'] is! int ||
                params.containsKey('request_id')) {
              throw StateError('Expected a generation-bound approval response');
            }
            approvalResponses.add(Map<String, dynamic>.from(params));
            return {'status': 'resolved', 'prompt_id': params['prompt_id']};
          case 'projects.discover_repos':
            return {
              'repos': const [
                {'root': '/srv/wing', 'label': 'Wing'},
              ],
            };
          case 'projects.create':
            projectCreates.add(Map<String, dynamic>.from(params));
            final project = <String, dynamic>{
              'id': 'roadmap-created',
              'name': params['name'],
              'label': params['name'],
              'path': params['primary_path'],
              'primary_path': params['primary_path'],
              'color': params['color'],
              'icon': params['icon'],
              'lastActive': now + 1,
            };
            createdProjects
                .putIfAbsent(scope.profileName, () => [])
                .add(project);
            return {'project': Map<String, dynamic>.from(project)};
          case 'projects.update':
            projectUpdates.add(Map<String, dynamic>.from(params));
            final project = createdProjects[scope.profileName]!.singleWhere(
              (project) => project['id'] == params['id'],
            );
            if (params.containsKey('name')) {
              project['name'] = params['name'];
              project['label'] = params['name'];
            }
            return {'project': Map<String, dynamic>.from(project)};
          case 'projects.delete':
            projectDeletes.add(Map<String, dynamic>.from(params));
            createdProjects[scope.profileName]!.removeWhere(
              (project) => project['id'] == params['id'],
            );
            return {'projects': projects(scope.profileName), 'active_id': null};
          case 'subagent.list':
            supervisionRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            return {
              'subagents': [
                {
                  'subagent_id': 'roadmap-child',
                  'goal': 'Inspect the emulator release',
                  'status': subagentStatus,
                  'model': 'gpt-5.6-sol',
                  'last_tool': 'read_file',
                  'accepting_steer': subagentStatus == 'running',
                },
              ],
              'delegations': const [],
            };
          case 'subagent.tail':
            supervisionRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            return {
              'subagent_id': 'roadmap-child',
              'available': true,
              'text': subagentOutput,
              'truncated': false,
            };
          case 'subagent.steer':
            supervisionRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            return {'status': 'queued', 'subagent_id': params['subagent_id']};
          case 'session.control.read':
            supervisionRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            return {'control': _sessionControl};
          case 'session.control':
            supervisionRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            if (params['action'] == 'goal.pause') goalStatus = 'paused';
            if (params['action'] == 'loop.pause') loopStatus = 'paused';
            return {
              'control': _sessionControl,
              'dispatch': const {
                'type': 'exec',
                'output': 'Roadmap supervision updated.',
                'notice': null,
                'message': null,
                'display': null,
              },
            };
          case 'process.list':
            supervisionRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            return {
              'processes': [
                if (runningProcess)
                  const {
                    'session_id': 'roadmap-process-running',
                    'command': 'dart run roadmap_worker.dart',
                    'status': 'running',
                    'pid': 4242,
                  },
                const {
                  'session_id': 'roadmap-process-finished',
                  'command': 'dart test roadmap_check.dart',
                  'status': 'exited',
                  'exit_code': 0,
                },
              ],
            };
          case 'process.kill':
            supervisionRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            runningProcess = false;
            return {'status': 'killed', 'session_id': params['process_id']};
          case 'session.history' when answerActionsEnabled:
            final id = answerRuntimes[params['session_id']]!;
            return {
              'messages': _answerRpcRows(_answerHistory(scope.profileName, id)),
            };
          case 'prompt.submit' when answerActionsEnabled:
            answerActionRequests.add((
              method,
              Map<String, dynamic>.from(params),
            ));
            final id = answerRuntimes[params['session_id']]!;
            final rows = _answerHistory(scope.profileName, id);
            rows.add({
              'id': ++_nextAnswerRow,
              'role': 'user',
              'content': params['text'],
              'display_content': params['text'],
            });
            rows.add({
              'id': ++_nextAnswerRow,
              'role': 'assistant',
              'content': 'Acknowledged ${params['text']}',
              'display_content': 'Acknowledged ${params['text']}',
            });
            return canonicalReceipt(
              params,
              admissionId: 'roadmap-${params['submission_id']}',
            );
          case 'session.resume':
          case 'session.create':
            if (answerActionsEnabled && method == 'session.resume') {
              final id = params['session_id'] as String;
              final runtime = 'runtime-$id';
              answerRuntimes[runtime] = id;
              return {
                ...canonicalSnapshotFields,
                'revision':
                    canonicalRevisions['${scope.profileName}:runtime-$id'] ?? 0,
                'session_id': runtime,
                'stored_session_id': id,
                if (answerParents.containsKey(id))
                  'parent_session_id': answerParents[id],
                'messages': _answerRpcRows(
                  _answerHistory(scope.profileName, id),
                ),
                'info': {
                  'profile_name': scope.profileName,
                  'model': 'gpt-6-astra',
                  'provider': 'openai-codex',
                  'reasoning_effort': 'high',
                },
              };
            }
            final response = await base.call(method, params);
            return {
              ...response,
              if (method == 'session.resume' &&
                  resumedRuntimes.containsKey((
                    scope.profileName,
                    params['session_id'],
                  )))
                'session_id':
                    resumedRuntimes[(scope.profileName, params['session_id'])],
              'info': {
                'profile_name': scope.profileName,
                'model': 'gpt-6-astra',
                'provider': 'openai-codex',
                'reasoning_effort': 'high',
                'terminal_backend': 'local',
                'cwd': '/srv/wing',
              },
            };
          default:
            return base.call(method, params);
        }
      },
    );
    (gateways[scope.profileName] ??= {}).add(fixtureGateway);
    return fixtureGateway;
  }

  void enableAnswerActions() {
    answerActionsEnabled = true;
    answerRuntimes['runtime-chat-0'] = 'chat-0';
  }

  List<Map<String, dynamic>> _answerHistory(String profile, String id) =>
      answerHistories.putIfAbsent(
        '$profile/$id',
        () => [
          {
            'id': 1,
            'role': 'user',
            'content': 'Original emulator prompt',
            'display_content': 'Original emulator prompt',
          },
          {
            'id': 2,
            'role': 'assistant',
            'content': 'Original emulator answer',
            'display_content': 'Original emulator answer',
          },
          {
            'id': 3,
            'role': 'user',
            'content': 'Latest emulator prompt',
            'display_content': 'Latest emulator prompt',
          },
          {
            'id': 4,
            'role': 'assistant',
            'content': 'Latest emulator answer',
            'display_content': 'Latest emulator answer',
          },
        ],
      );

  List<Map<String, dynamic>> _answerRpcRows(List<Map<String, dynamic>> rows) =>
      rows.map((row) {
        final rpc = Map<String, dynamic>.from(row);
        rpc['row_id'] = rpc.remove('id');
        return rpc;
      }).toList();

  void completeAnswerAction(String profile, String runtimeId) {
    _emit(
      profile,
      StreamEvent(
        type: 'message.complete',
        sessionId: runtimeId,
        data: const {},
      ),
    );
  }

  Map<String, dynamic> get _sessionControl => !supervisionEnabled
      ? {
          'goal': null,
          'loop': null,
          'heartbeat': null,
          'revision': 'roadmap-empty-control',
          'updated_at': 1,
        }
      : {
          'goal': {
            'title': 'Verify the emulator roadmap',
            'status': goalStatus,
            'turns_used': 2,
            'max_turns': 8,
            'contract': const {
              'outcome': 'Verify the client',
              'verification': 'Recorded checks pass',
              'constraints': 'Local fixtures',
              'boundaries': 'Android client',
              'stop_when': 'Checks complete',
            },
            'subgoals': const ['Run the isolated checks'],
            'gates': const [],
          },
          'loop': {
            'prompt': 'Check the release queue',
            'status': loopStatus,
            'mode': 'interval',
            'interval_seconds': 300,
            'current_delay': 300,
            'times': 4,
            'until': '',
            'max_ticks': 0,
            'ticks_fired': 2,
            'created_at': 1,
            'last_fired_at': 2,
            'next_due_at': 1893456000,
            'awaiting_response': false,
            'deferred_by_goal': goalStatus == 'active',
          },
          'heartbeat': const {
            'prompt': 'Report emulator health',
            'status': 'active',
            'interval_seconds': 900,
            'created_at': 1,
            'last_fired_at': 2,
            'fire_count': 3,
          },
          'revision': 'roadmap-supervision-revision',
          'updated_at': 3,
        };

  void requestApproval(String profile, String runtimeId) {
    _emit(
      profile,
      StreamEvent(
        type: 'approval.request',
        sessionId: runtimeId,
        data: {
          'kind': 'approval',
          'execution_generation': 0,
          'prompt_id': 'roadmap-approval-${++approvalSequence}',
          'command': 'echo isolated-roadmap-check',
          'choices': ['once', 'session', 'deny'],
        },
      ),
    );
  }

  void deliverReview(String profile, String runtimeId) {
    _emit(
      profile,
      StreamEvent(
        type: 'review.summary',
        sessionId: runtimeId,
        envelope: const {'seq': 1},
        data: const {'text': 'Roadmap review needs a human check.'},
      ),
    );
  }

  void requestVaultUnlock(String profile, String runtimeId) {
    const requestId = 'roadmap-vault-unlock';
    _sensitiveRequests[requestId] = (profile: profile, runtime: runtimeId);
    _emit(
      profile,
      StreamEvent(
        type: 'vault.unlock_prompt',
        sessionId: runtimeId,
        data: const {
          'request_id': requestId,
          'backend': 'roadmap-vault',
          'display_name': 'Roadmap Vault',
        },
      ),
    );
  }

  Map<String, dynamic> startDiagnostic(String path, Map<String, dynamic> body) {
    if (!const {'ops/doctor', 'ops/security-audit'}.contains(path)) {
      throw StateError('Unexpected diagnostic: $path');
    }
    diagnosticPosts.add((path, Map<String, dynamic>.from(body)));
    final name = path.substring(4);
    final pid = diagnosticPids[name] = ++_nextDiagnosticPid;
    return {'ok': true, 'name': name, 'pid': pid};
  }

  Map<String, dynamic> readDiagnosticStatus(
    String path,
    Map<String, String> query,
  ) {
    if (!const {
      'actions/doctor/status',
      'actions/security-audit/status',
    }.contains(path)) {
      throw StateError('Unexpected diagnostic status: $path');
    }
    administrationReads.add((path, Map<String, String>.from(query)));
    final name = path.split('/')[1];
    final pid = diagnosticPids[name];
    if (pid == null) throw StateError('Diagnostic was not started');
    return {
      'name': name,
      'pid': pid,
      'running': false,
      'exit_code': 0,
      'lines': name == 'doctor'
          ? [
              '=== doctor started roadmap-fixture ===',
              '─' * 60,
              'All checks passed! 🎉',
            ]
          : [
              '=== security-audit started roadmap-fixture ===',
              'No known vulnerabilities found across 2 component(s).',
            ],
    };
  }

  void _emit(String profile, StreamEvent event) {
    final listeners = [
      for (final gateway in gateways[profile] ?? const <ProfileGateway>{})
        ?gateway.onEvent,
    ];
    if (listeners.isEmpty) {
      throw StateError('No live fixture listener for $profile');
    }
    for (final listener in listeners) {
      listener(event);
    }
  }
}

class RoadmapMemoryCredentialStore implements CredentialStore {
  final _values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    final value = _values[key];
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}
