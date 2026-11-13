import 'dart:async';

import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/ws_client.dart';

import 'profile_actions_fixture.dart';

class BrowserMutationsFixture extends ProfileActionsFixture {
  final projectChanges = <String, Map<String, dynamic>>{};
  final deletedProjects = <String>{};
  Completer<void>? projectReadDelay;
  int extraRows = 0;
  bool failPresence = false;
  int presenceReads = 0;
  Completer<void>? presenceDelay;
  Completer<void>? presenceStarted;
  Completer<void>? deleteAckDelay;
  Completer<void>? deleteAcknowledged;
  final wireCalls = <String>[];
  final rpcDelays = <String, Completer<void>>{};
  final rpcStarted = <String, Completer<void>>{};
  final folderCreates = <(String, Map<String, dynamic>)>[];
  Completer<void>? folderCreateGate;
  bool failFolderCreate = false;
  Completer<void>? defaultFolderGate;
  bool failProjectUpdate = false;
  bool failPrimaryFolder = false;
  final resumeRuntimeIds = <String, String>{};

  void event(
    ProfileGateway gateway,
    String runtime,
    String type,
    Map<String, dynamic> data,
  ) {
    gateway.onEvent!(StreamEvent(type: type, sessionId: runtime, data: data));
  }

  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    for (final row in super.sessions(profile))
      {...row, 'input_tokens': 1000, 'output_tokens': 500},
    for (var i = 0; i < extraRows; i++)
      {
        'id': 'extra-$i',
        'title': 'Extra chat $i',
        'profile': profile,
        'last_active': now - (i + 20) * 3600,
        'input_tokens': 1000,
        'output_tokens': 500,
        ...?changes[profile]?['extra-$i'],
      },
  ];

  @override
  List<Map<String, dynamic>> projects(String profile) => [
    for (final project in super.projects(profile))
      if (!deletedProjects.contains('$profile/${project['id']}'))
        {...project, ...?projectChanges['$profile/${project['id']}']},
    ?projectChanges['$profile/created'],
  ];

  Map<String, dynamic> _confirmedProject(Map<String, dynamic> project) => {
    'id': project['id'],
    'name': project['label'],
    'primary_path': project['path'],
    'color': project['color'],
    'icon': project['icon'],
    if (project.containsKey('folders')) 'folders': project['folders'],
  };

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    final gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      ownedPost: (endpoint, body, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(
            StateError('Creation retired'),
          );
        }
        onDispatched();
        folderCreates.add((endpoint, body));
        await folderCreateGate?.future;
        if (failFolderCreate) throw StateError('Directory is not writable');
        return {
          'ok': true,
          'path': body['path'],
          'entry': {'path': body['path'], 'is_directory': true},
        };
      },
      get: (endpoint, query) async {
        final path = Uri.parse(endpoint).path;
        if (path == 'fs/default-cwd') {
          defaultFolderProfiles.add(scope.profileName);
          await defaultFolderGate?.future;
          if (failDefaultFolder) throw StateError('Default folder unavailable');
          return {'cwd': '/${scope.profileName}', 'branch': null};
        }
        if (path == 'files') {
          final location = query['path'] ?? '/work';
          return {
            'path': location,
            'parent': location == '/work' ? null : '/work',
            'entries': location == '/work'
                ? [
                    for (final name in ['new', 'bangkok-oct26'])
                      {
                        'name': name,
                        'path': '/work/$name',
                        'is_directory': true,
                      },
                  ]
                : [],
          };
        }
        if (path != 'sessions/search' &&
            path.startsWith('sessions/') &&
            path.split('/').length == 2) {
          presenceReads++;
          if (presenceStarted != null && !presenceStarted!.isCompleted) {
            presenceStarted!.complete();
          }
          await presenceDelay?.future;
          if (failPresence) {
            throw const DashboardHttpException(503, 'sessions/detail');
          }
          final id = Uri.decodeComponent(path.substring('sessions/'.length));
          final row = sessions(
            scope.profileName,
          ).where((row) => row['id'] == id).firstOrNull;
          if (row == null) throw DashboardSessionNotFound(path);
          return {...row, 'profile': scope.profileName};
        }
        return base.read(endpoint, query);
      },
      ownedPatch: (path, body, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(StateError('Menu retired'));
        }
        onDispatched();
        return await base.updateSession(
          Uri.decodeComponent(path.split('/').last),
          {
            for (final key in ['title', 'pinned', 'archived', 'unread'])
              if (body.containsKey(key)) key: body[key],
          },
          canDispatch: canDispatch,
        );
      },
      ownedDelete: (path, parameters, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(StateError('Menu retired'));
        }
        onDispatched();

        await base.deleteSession(
          Uri.decodeComponent(path.split('/').last),
          canDispatch: canDispatch,
        );
        deleteAcknowledged?.complete();
        await deleteAckDelay?.future;

        return {'ok': true};
      },
      rpc: (method, params) async {
        wireCalls.add(method);
        final started = rpcStarted[method];
        if (started != null && !started.isCompleted) started.complete();
        await rpcDelays[method]?.future;
        if (method == 'session.resume' &&
            resumeRuntimeIds.containsKey(params['session_id'])) {
          final result = await base.call(method, params);
          return {
            ...result,
            'session_id': resumeRuntimeIds[params['session_id']],
            'stored_session_id': params['session_id'],
          };
        }
        if (method == 'commands.catalog') {
          return {
            'pairs': [
              ['custom', 'Controlled fixture command'],
            ],
          };
        }
        if (method == 'command.dispatch') {
          return {'type': 'exec', 'output': 'Accepted'};
        }
        if (method == 'file.attach') {
          return {'attached': true, 'ref_text': 'attached:${params['name']}'};
        }
        if (method == 'projects.add_folder') {
          if (failPrimaryFolder) throw StateError('Folder change rejected');
          final id = params['id'] as String;
          final project = projects(
            scope.profileName,
          ).firstWhere((p) => p['id'] == id);
          final path = params['path'] as String;
          final folders =
              project['folders'] as List? ??
              [
                {'path': project['path'], 'is_primary': true},
              ];
          final updated = {
            ...project,
            'path': path,
            'folders': [
              for (final folder in folders)
                if (folder['path'] != path)
                  {...(folder as Map<String, dynamic>), 'is_primary': false},
              {'path': path, 'is_primary': true},
            ],
          };
          projectChanges['${scope.profileName}/$id'] = updated;
          return {'project': _confirmedProject(updated)};
        }
        if (method == 'projects.get' || method == 'projects.remove_folder') {
          final id = params['id'] as String;
          final project = projects(
            scope.profileName,
          ).firstWhere((p) => p['id'] == id);
          final folders =
              project['folders'] as List? ??
              [
                {'path': project['path'], 'is_primary': true},
              ];
          final updated = {
            ...project,
            'folders': [
              for (final folder in folders)
                if (method != 'projects.remove_folder' ||
                    (folder as Map)['path'] != params['path'])
                  folder,
            ],
          };
          if (method == 'projects.remove_folder') {
            projectChanges['${scope.profileName}/$id'] = updated;
          }
          return {'project': _confirmedProject(updated)};
        }
        if (method == 'projects.update') {
          if (failProjectUpdate) throw StateError('Project details rejected');
          final id = params['id'] as String;
          final project = projects(
            scope.profileName,
          ).firstWhere((p) => p['id'] == id);
          final updated = {
            ...project,
            if (params.containsKey('name')) 'label': params['name'],
            if (params.containsKey('color')) 'color': params['color'],
            if (params.containsKey('icon')) 'icon': params['icon'],
          };
          projectChanges['${scope.profileName}/$id'] = updated;
          return {'project': _confirmedProject(updated)};
        }
        if (method == 'projects.create') {
          final project = {
            'id': 'created',
            'label': params['name'],
            'path': params['primary_path'],
            'color': params['color'],
            'icon': params['icon'],
            'lastActive': now,
          };
          projectChanges['${scope.profileName}/created'] = project;
          return {'project': _confirmedProject(project)};
        }
        if (method == 'projects.delete') {
          deletedProjects.add('${scope.profileName}/${params['id']}');
          return {
            'projects': projects(
              scope.profileName,
            ).map(_confirmedProject).toList(),
            'active_id': null,
          };
        }
        final result = await base.call(method, params);
        if (method == 'projects.tree') await projectReadDelay?.future;
        return result;
      },
    );
    return gateway;
  }
}
