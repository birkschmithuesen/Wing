import 'canonical_gateway_fixture.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'dart:async';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'profile_browser_fixture.dart';

class ProfileActionsFixture extends ProfileBrowserFixture {
  final updates = <(String, String, Map<String, dynamic>)>[];
  final deletes = <(String, Map<String, String>)>[];
  final deleteAttempts = <(String, Map<String, String>)>[];
  final moves = <(String, Map<String, dynamic>)>[];
  final _workspaceStorageIds = <String, String>{};
  Completer<void>? movePreparationDelay;
  final movePreparations = <String>[];
  final changes = <String, Map<String, Map<String, dynamic>>>{};
  final removed = <String, Set<String>>{};
  bool failMutation = false;
  bool active = false;
  String activeSessionKey = 'newest';
  String? activeStatus = 'idle';
  String? resumeProfile;
  String resumeSessionId = 'newest';
  bool lazyResume = false;
  Map<String, dynamic> resumeOverrides = {};
  int mutationRevision = 0;
  int mutationGeneration = 0;
  Map<String, dynamic> mutationSnapshotOverrides = {};
  bool claimAfterSnapshot = false;
  bool invalidateRevisionAfterSnapshot = false;
  Completer<void>? snapshotDelay;
  Completer<void>? defaultFolderDelay;
  bool failDefaultFolder = false;
  final defaultFolderProfiles = <String>[];
  bool foreignActive = false;
  Completer<void>? mutationDelay;
  Completer<void>? mutationStarted;
  Completer<void>? titleDelay;
  String? suggestedTitle = 'Conversation list improvements';
  bool failTitle = false;
  final titleRequests = <Map<String, dynamic>>[];
  void _verifyMutationFence(Map<String, dynamic> params) {
    if (params['expected_revision'] != mutationRevision ||
        params['expected_generation'] != mutationGeneration) {
      throw StateError('Mutation conflict');
    }
    if (active && activeStatus != 'idle') throw StateError('Session busy');
  }

  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    for (final row in super.sessions(profile))
      if (!(removed[profile]?.contains(row['id']) ?? false))
        {...row, ...?changes[profile]?[row['id']]},
  ];
  @override
  List<Map<String, dynamic>> projectSessions(String profile, String id) => [
    for (final row in sessions(profile))
      if (row['cwd'] ==
              projects(profile).firstWhere((p) => p['id'] == id)['path'] ||
          (row['cwd'] == '/not-the-project-path' &&
              id == 'p2' &&
              row['id'] == 'project-only'))
        row,
  ];
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: (endpoint, query) async {
        final path = Uri.parse(endpoint).path;
        if (path == 'fs/default-cwd') {
          defaultFolderProfiles.add(scope.profileName);
          await defaultFolderDelay?.future;
          if (failDefaultFolder) throw StateError('Default folder unavailable');
          return {'cwd': '/${scope.profileName}/default'};
        }
        if (path.endsWith('/mutation-snapshot')) {
          reads.add((path, query));
          await snapshotDelay?.future;
          final snapshot = {
            'session_id': Uri.decodeComponent(path.split('/')[1]),
            'exists': true,
            'runtime_revision': mutationRevision,
            'runtime_generation': mutationGeneration,
            ...mutationSnapshotOverrides,
          };
          if (claimAfterSnapshot) {
            active = true;
            activeStatus = 'working';
            mutationGeneration++;
          }
          if (invalidateRevisionAfterSnapshot) mutationRevision++;
          return snapshot;
        }
        if (path != 'sessions/search' &&
            path.startsWith('sessions/') &&
            path.split('/').length == 2) {
          final id = Uri.decodeComponent(path.substring('sessions/'.length));
          final row = sessions(
            scope.profileName,
          ).where((row) => row['id'] == id).firstOrNull;
          if (row == null) throw DashboardSessionNotFound(path);
          return {...row, 'profile': scope.profileName};
        }
        return base.read(endpoint, query);
      },
      rpc: (method, params) async {
        if (method == 'llm.oneshot') {
          titleRequests.add(Map.of(params));
          await titleDelay?.future;
          if (failTitle) {
            throw StateError('Title generation failed. Try again.');
          }
          return {'text': suggestedTitle};
        }
        if (method == 'session.mutate' && params['operation'] == 'rename') {
          calls.add((scope.profileName, method, params));
          final id = active ? activeSessionKey : 'new-chat';
          final title = (params['payload'] as Map)['title'];
          changes.putIfAbsent(scope.profileName, () => {})[id] = {
            'title': title,
          };
          final revision = (params['expected_revision'] as int) + 1;
          canonicalRevisions['${scope.profileName}:${params['session_id']}'] =
              revision;
          return {
            'session_id': params['session_id'],
            'operation': 'rename',
            'revision': revision,
            'execution_generation': params['expected_generation'],
            'status': 'applied',
            'title': title,
          };
        }
        if (method == 'session.workspace.move' || method == 'session.close') {
          throw StateError('Unknown canonical method: $method');
        }
        if (method == 'session.mutate' && params['operation'] == 'workspace') {
          if (params.keys.toSet().difference({
                'profile',
                'session_id',
                'request_id',
                'expected_revision',
                'expected_generation',
                'operation',
                'payload',
              }).isNotEmpty ||
              params.length != 7 ||
              params['profile'] != scope.profileName ||
              params['request_id'] is! String ||
              (params['request_id'] as String).isEmpty ||
              params['payload'] is! Map ||
              (params['payload'] as Map).keys.single != 'cwd') {
            throw StateError('Invalid canonical workspace mutation');
          }
          _verifyMutationFence(params);
          moves.add((scope.profileName, params));
          await mutationDelay?.future;
          if (failMutation) throw StateError('Move rejected');
          _verifyMutationFence(params);
          final ownerId = params['session_id'] as String;
          final id =
              _workspaceStorageIds['${scope.profileName}:$ownerId'] ?? ownerId;
          final cwd = (params['payload'] as Map)['cwd'];
          final profile = changes.putIfAbsent(scope.profileName, () => {});
          profile[id] = {
            ...?profile[id],
            'cwd': cwd,
            'git_branch': null,
            'git_repo_root': null,
          };
          mutationRevision++;
          canonicalRevisions['${scope.profileName}:$ownerId'] =
              mutationRevision;
          return {
            'session_id': ownerId,
            'operation': 'workspace',
            'revision': mutationRevision,
            'execution_generation': mutationGeneration,
            'cwd': cwd,
            'branch': null,
            'git_repo_root': null,
          };
        }
        if (method == 'session.active_list') {
          return {
            'sessions': [
              if (active)
                {
                  'id': 'runtime',
                  'session_key': activeSessionKey,
                  'status': activeStatus,
                },
              if (foreignActive)
                {
                  'id': 'foreign-runtime',
                  'session_key': 'newest',
                  'status': 'working',
                },
            ],
          };
        }
        if (method == 'session.resume') {
          final Map<String, dynamic> result;
          if (params['session_id'] == activeSessionKey) {
            active = true;
            result = {
              ...canonicalSnapshotFields,
              'revision':
                  canonicalRevisions['${scope.profileName}:runtime'] ?? 0,
              'session_id': 'runtime',
              'stored_session_id': resumeSessionId,
              'messages': [],
              'info': {
                'profile_name': resumeProfile ?? scope.profileName,
                if (lazyResume) 'lazy': true,
              },
              ...resumeOverrides,
            };
          } else {
            result = await base.call(method, params);
          }
          final ownerId = result['session_id'] as String;
          _workspaceStorageIds['${scope.profileName}:$ownerId'] =
              result['stored_session_id'] as String;
          if (params['omit_messages'] == true) {
            movePreparations.add(params['session_id'] as String);
            await movePreparationDelay?.future;
            final revision = result['revision'] as int;
            if (revision > mutationRevision) mutationRevision = revision;
            return {
              ...result,
              'revision': mutationRevision,
              'execution_generation': mutationGeneration,
            };
          }
          return result;
        }
        return base.call(method, params);
      },
      ownedPatch: (endpoint, body, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(StateError('Menu retired'));
        }
        onDispatched();
        updates.add((scope.profileName, endpoint, body));
        mutationStarted?.complete();
        await mutationDelay?.future;
        if (failMutation) throw StateError('Write rejected');
        final id = Uri.decodeComponent(endpoint.split('/').last);
        final update = {
          for (final key in ['title', 'pinned', 'archived', 'unread'])
            if (body.containsKey(key)) key: body[key],
        };
        final profile = changes.putIfAbsent(scope.profileName, () => {});
        profile[id] = {...?profile[id], ...update};
        return {'ok': true, 'title': update['title'] ?? 'Chat', ...update};
      },
      ownedDelete: (endpoint, parameters, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(StateError('Menu retired'));
        }
        final query = parameters.map(
          (key, value) => MapEntry(key, value.toString()),
        );
        onDispatched();

        deleteAttempts.add((endpoint, Map.unmodifiable(query)));
        if (failMutation) throw StateError('Delete rejected');
        if (parameters.keys.toSet().difference({
              'profile',
              'request_id',
              'expected_revision',
              'expected_generation',
            }).isNotEmpty ||
            parameters.length != 4 ||
            parameters['profile'] != scope.profileName ||
            parameters['request_id'] is! String ||
            (parameters['request_id'] as String).isEmpty) {
          throw StateError('Invalid canonical delete identity');
        }
        _verifyMutationFence(parameters);
        active = false;
        deletes.add((endpoint, query));
        removed
            .putIfAbsent(scope.profileName, () => {})
            .add(Uri.decodeComponent(endpoint.split('/').last));

        return {'ok': true};
      },
    );
  }
}
