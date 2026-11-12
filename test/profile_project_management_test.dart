import 'support/canonical_gateway_fixture.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ProjectHost {
  final calls = <(String, String, Map<String, dynamic>)>[];
  final projects = <String, List<Map<String, dynamic>>>{
    'a': [
      {
        'id': 'project-a',
        'label': 'A project',
        'path': '/a',
        'lastActive': 2,
        'color': '#112233',
        'icon': 'folder',
      },
    ],
    'b': [
      {'id': 'project-b', 'label': 'B project', 'path': '/b', 'lastActive': 1},
    ],
  };
  final history = <String, List<Map<String, dynamic>>>{};
  bool rejectUpdateAck = false;
  bool rejectDeleteAck = false;
  bool failDeleteRefresh = false;
  final failNextTree = <String>{};
  Completer<void>? deleteStarted;
  Completer<void>? deleteGate;
  Completer<void>? folderStarted;
  Completer<void>? folderGate;
  bool failFolder = false;
  bool rejectFolderAck = false;
  bool failCreate = false;
  final folderAckOverrides = <String, dynamic>{};
  String? confirmedFolder;

  Future<ProfileDiscovery> discover() async => ProfileDiscovery(
    profiles: const [
      HermesProfile(name: 'a'),
      HermesProfile(name: 'b'),
    ],
    currentName: 'a',
    activeName: 'a',
  );

  ProfileGateway gateway(WorkspaceScope scope) => ProfileGateway(
    scope: scope,
    discover: discover,
    ownedPost: (endpoint, body, canDispatch, onDispatched) async {
      if (!canDispatch()) throw StateError('Creation retired');
      onDispatched();
      calls.add((scope.profileName, endpoint, body));
      expect(Uri.parse(endpoint).path, 'files/mkdir');
      expect(Uri.parse(endpoint).queryParameters['profile'], scope.profileName);
      folderStarted?.complete();
      await folderGate?.future;
      if (failFolder) throw StateError('Directory is not writable');
      final path = confirmedFolder ?? body['path'];
      return {
        'ok': !rejectFolderAck,
        'path': path,
        'entry': {'path': path, 'is_directory': true},
        ...folderAckOverrides,
      };
    },
    get: (path, query) async {
      if (path == 'sessions') {
        return {
          'offset': int.parse(query['offset']!),
          'limit': int.parse(query['limit']!),
          'total': 1,
          'sessions': [
            {
              'id': '${scope.profileName}-chat',
              'title': '${scope.profileName} chat',
              'profile': scope.profileName,
            },
          ],
        };
      }
      if (path.endsWith('/messages')) {
        final id = Uri.decodeComponent(path.split('/')[1]);
        final offset = int.parse(query['offset']!);
        final limit = int.parse(query['limit']!);
        final rows = (history[id] ?? <Map<String, dynamic>>[])
            .skip(offset)
            .take(limit)
            .toList();
        return {
          'session_id': id,
          'messages': rows,
          'pagination': {
            'offset': offset,
            'limit': limit,
            'returned': rows.length,
            'order': 'latest',
          },
        };
      }
      throw StateError('Unexpected read $path');
    },
    rpc: (method, params) async {
      calls.add((scope.profileName, method, params));
      switch (method) {
        case 'projects.create':
          if (failCreate) throw StateError('Project registration failed');
          return {
            'project': {
              'id': 'created',
              'name': params['name'],
              'primary_path': params['primary_path'],
              'color': params['color'],
              'icon': params['icon'],
            },
          };
        case 'session.resume':
          return {
            ...canonicalSnapshotFields,
            'session_id': '${scope.profileName}-runtime',
            'stored_session_id': params['session_id'],
            'status': 'idle',
            'messages':
                history[params['session_id']] ?? <Map<String, dynamic>>[],
            'running': false,
            'info': {'profile_name': scope.profileName},
          };
        case 'projects.tree':
          if (failNextTree.remove(scope.profileName)) {
            throw StateError('Tree refresh failed');
          }
          return {'projects': projects[scope.profileName]};
        case 'projects.project_sessions':
          return {
            'project': {'id': params['project_id'], 'repos': const []},
          };
        case 'projects.update':
          if (rejectUpdateAck) return {};
          final id = params['id'];
          projects[scope.profileName] = [
            for (final project in projects[scope.profileName]!)
              if (project['id'] == id)
                {
                  ...project,
                  if (params['name'] case final String name) 'label': name,
                  if (params.containsKey('color'))
                    'color': params['color'] == '' ? null : params['color'],
                  if (params.containsKey('icon'))
                    'icon': params['icon'] == '' ? null : params['icon'],
                }
              else
                project,
          ];
          return {
            'project': {
              ...projects[scope.profileName]!.firstWhere((p) => p['id'] == id),
              'name': projects[scope.profileName]!.firstWhere(
                (p) => p['id'] == id,
              )['label'],
              'primary_path': projects[scope.profileName]!.firstWhere(
                (p) => p['id'] == id,
              )['path'],
            },
          };
        case 'projects.delete':
          deleteStarted?.complete();
          await deleteGate?.future;
          if (rejectDeleteAck) return {};
          final id = params['id'];
          projects[scope.profileName] = [
            for (final project in projects[scope.profileName]!)
              if (project['id'] != id) project,
          ];
          if (failDeleteRefresh) failNextTree.add(scope.profileName);
          return {'projects': projects[scope.profileName], 'active_id': null};
        default:
          throw StateError('Unexpected RPC $method');
      }
    },
  );
}

void main() {
  late _ProjectHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = _ProjectHost();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      connectionIdentity: 'project-host',
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'creates the folder before registering the confirmed project path',
    () async {
      host.confirmedFolder = '/resolved/new';
      host.folderStarted = Completer<void>();
      host.folderGate = Completer<void>();
      final owner = controller.current!;
      final creating = controller.createProject(
        'New project',
        '/requested/new',
        color: '#112233',
        icon: 'folder',
        canDispatch: () => true,
      );
      await host.folderStarted!.future;
      expect(owner.creatingProject, isTrue);
      expect(host.calls.where((call) => call.$2 == 'projects.create'), isEmpty);
      expect(owner.projects, hasLength(1));
      host.folderGate!.complete();
      await creating;
      final mutations = host.calls
          .where(
            (call) =>
                call.$2.startsWith('files/mkdir') ||
                call.$2 == 'projects.create',
          )
          .toList();
      expect(mutations.map((call) => call.$2), [
        'files/mkdir?profile=a',
        'projects.create',
      ]);
      expect(mutations.first.$3, {'path': '/requested/new'});
      expect(mutations.last.$3, {
        'name': 'New project',
        'folders': ['/resolved/new'],
        'primary_path': '/resolved/new',
        'color': '#112233',
        'icon': 'folder',
        'profile': 'a',
      });
      expect(owner.projects.last['path'], '/resolved/new');
      expect(owner.creatingProject, isFalse);
    },
  );

  for (final rejectAck in [false, true]) {
    test(
      'folder ${rejectAck ? 'missing acknowledgement' : 'failure'} prevents project registration',
      () async {
        host.failFolder = !rejectAck;
        host.rejectFolderAck = rejectAck;
        await expectLater(
          controller.createProject(
            'New project',
            '/new',
            color: '#112233',
            icon: 'folder',
            canDispatch: () => true,
          ),
          throwsStateError,
        );
        expect(
          host.calls.where((call) => call.$2 == 'projects.create'),
          isEmpty,
        );
        expect(controller.current!.projects, hasLength(1));
        expect(controller.current!.creatingProject, isFalse);
      },
    );
  }

  test(
    'retirement after folder creation prevents project registration',
    () async {
      host.folderStarted = Completer<void>();
      host.folderGate = Completer<void>();
      var active = true;
      final creating = controller.createProject(
        'New project',
        '/new',
        color: '#112233',
        icon: 'folder',
        canDispatch: () => active,
      );
      final failure = expectLater(
        creating,
        throwsA(isA<DashboardRequestNotSentException>()),
      );
      await host.folderStarted!.future;
      active = false;
      host.folderGate!.complete();
      await failure;
      expect(host.calls.where((call) => call.$2 == 'projects.create'), isEmpty);
      expect(controller.current!.projects, hasLength(1));
      expect(controller.current!.creatingProject, isFalse);
    },
  );

  test(
    'browser publishes project creation through failure and retry',
    () async {
      final browser = ChatBrowserData(controller);
      addTearDown(browser.dispose);
      final pending = <bool>[];
      browser.addListener(() => pending.add(browser.workspace.mutating));
      host.failFolder = true;
      await browser.run(
        () => controller.createProject(
          'New project',
          '/new',
          color: '#112233',
          icon: 'folder',
          canDispatch: () => true,
        ),
      );
      expect(pending, contains(true));
      expect(pending.last, isFalse);
      expect(browser.notice, contains('project folder'));
      host.failFolder = false;
      expect(
        await browser.run(
          () => controller.createProject(
            'New project',
            '/new',
            color: '#112233',
            icon: 'folder',
            canDispatch: () => true,
          ),
        ),
        isTrue,
      );
      expect(browser.workspace.mutating, isFalse);
      expect(browser.notice, isNull);
    },
  );

  for (final acknowledgement in <Map<String, dynamic>>[
    {'path': ''},
    {'entry': null},
    {
      'entry': {'path': '/new', 'is_directory': false},
    },
    {
      'entry': {'path': '/different', 'is_directory': true},
    },
  ]) {
    test(
      'unconfirmed directory $acknowledgement prevents registration',
      () async {
        host.folderAckOverrides.addAll(acknowledgement);
        await expectLater(
          controller.createProject(
            'New project',
            '/new',
            color: '#112233',
            icon: 'folder',
            canDispatch: () => true,
          ),
          throwsStateError,
        );
        expect(
          host.calls.where((call) => call.$2 == 'projects.create'),
          isEmpty,
        );
        expect(controller.current!.creatingProject, isFalse);
      },
    );
  }

  test('duplicate creation does not dispatch another folder write', () async {
    host.folderStarted = Completer<void>();
    host.folderGate = Completer<void>();
    final creating = controller.createProject(
      'New project',
      '/new',
      color: '#112233',
      icon: 'folder',
      canDispatch: () => true,
    );
    await host.folderStarted!.future;
    await expectLater(
      controller.createProject(
        'Another project',
        '/another',
        color: '#112233',
        icon: 'folder',
        canDispatch: () => true,
      ),
      throwsStateError,
    );
    expect(
      host.calls.where((call) => call.$2.startsWith('files/mkdir')),
      hasLength(1),
    );
    host.folderGate!.complete();
    await creating;
    expect(controller.current!.creatingProject, isFalse);
  });

  test(
    'profile switch after mkdir does not register in either profile',
    () async {
      final original = controller.current!;
      host.folderStarted = Completer<void>();
      host.folderGate = Completer<void>();
      final creating = controller.createProject(
        'New project',
        '/new',
        color: '#112233',
        icon: 'folder',
        canDispatch: () => true,
      );
      final failure = expectLater(
        creating,
        throwsA(isA<DashboardRequestNotSentException>()),
      );
      await host.folderStarted!.future;
      await controller.navigateProfile('b');
      host.folderGate!.complete();
      await failure;
      expect(host.calls.where((call) => call.$2 == 'projects.create'), isEmpty);
      expect(original.projects, hasLength(1));
      expect(original.creatingProject, isFalse);
      expect(controller.current!.projects.single['id'], 'project-b');
    },
  );

  test(
    'registration failure settles progress and leaves confirmed projects unchanged',
    () async {
      host.failCreate = true;
      await expectLater(
        controller.createProject(
          'New project',
          '/new',
          color: '#112233',
          icon: 'folder',
          canDispatch: () => true,
        ),
        throwsStateError,
      );
      expect(
        host.calls.where((call) => call.$2.startsWith('files/mkdir')),
        hasLength(1),
      );
      expect(controller.current!.projects, hasLength(1));
      expect(controller.current!.creatingProject, isFalse);
      expect(host.calls.any((call) => call.$2.contains('delete')), isFalse);
    },
  );

  test('updates server appearance and refreshes selected metadata', () async {
    final resource = controller.current!;
    await controller.selectProject(resource.projects.single);
    await controller.openSession(ProfileSessionKey(resource.scope, 'a-chat'));

    await controller.updateProject(
      resource.scope,
      'project-a',
      name: 'Renamed',
      color: '',
      icon: 'rocket',
      canDispatch: () => true,
    );

    final call = host.calls.lastWhere((entry) => entry.$2 == 'projects.update');
    expect(call.$1, 'a');
    expect(call.$3, {
      'id': 'project-a',
      'name': 'Renamed',
      'color': '',
      'icon': 'rocket',
      'profile': 'a',
    });
    expect(resource.projects.single['name'], 'Renamed');
    expect(resource.projects.single['color'], isNull);
    expect(resource.projects.single['icon'], 'rocket');
    expect(resource.selectedProject, same(resource.projects.single));
    expect(resource.selectedSession, 'a-chat');
  });

  test(
    'late delete changes only its owner and preserves chat records',
    () async {
      final resourceA = controller.current!;
      host.history['a-chat'] = [
        {'id': 1, 'role': 'assistant', 'content': 'Keep this answer'},
      ];
      await controller.selectProject(resourceA.projects.single);
      final cachedChat = await openFixtureChat(
        controller: controller,
        key: ProfileSessionKey(resourceA.scope, 'a-chat'),
        title: 'A chat',
        select: false,
      );
      await cachedChat.composer.editText('Keep this draft');

      host.deleteStarted = Completer<void>();
      host.deleteGate = Completer<void>();

      final deleting = controller.deleteProject(
        resourceA.scope,
        'project-a',
        canDispatch: () => true,
      );
      await host.deleteStarted!.future;
      await controller.openSession(
        ProfileSessionKey(resourceA.scope, 'a-chat'),
      );
      await controller.navigateProfile('b');
      final resourceB = controller.current!;
      await controller.selectProject(resourceB.projects.single);

      host.deleteGate!.complete();
      await deleting;

      expect(controller.current, same(resourceB));
      expect(resourceB.selectedProject?['id'], 'project-b');
      expect(resourceB.projects.single['id'], 'project-b');
      expect(resourceA.projects, isEmpty);
      expect(resourceA.selectedProject, isNull);
      expect(resourceA.selectedSession, 'a-chat');
      expect(resourceA.sessions.single['id'], 'a-chat');
      expect(resourceA.visibleSessions.single['id'], 'a-chat');
      expect(cachedChat.projectId, isNull);
      expect(cachedChat.composer.observation.text, 'Keep this draft');
      expect(cachedChat.reading.messages.single['content'], 'Keep this answer');
    },
  );

  for (final operation in ['update', 'delete']) {
    test(
      'failed $operation acknowledgement retains project selection',
      () async {
        final resource = controller.current!;
        await controller.selectProject(resource.projects.single);
        final selected = resource.selectedProject;
        host.rejectUpdateAck = true;
        host.rejectDeleteAck = true;
        await expectLater(
          operation == 'update'
              ? controller.updateProject(
                  resource.scope,
                  'project-a',
                  name: 'Ignored',
                  canDispatch: () => true,
                )
              : controller.deleteProject(
                  resource.scope,
                  'project-a',
                  canDispatch: () => true,
                ),
          throwsA(isA<FormatException>()),
        );
        expect(resource.projects.single['id'], 'project-a');
        expect(resource.projects.single['name'], 'A project');
        expect(resource.selectedProject, same(selected));
      },
    );
  }

  test(
    'acknowledged delete finishes without a follow-up project read',
    () async {
      final resource = controller.current!;
      await controller.selectProject(resource.projects.single);
      host.failDeleteRefresh = true;
      host.calls.clear();

      await controller.deleteProject(
        resource.scope,
        'project-a',
        canDispatch: () => true,
      );

      expect(resource.projects, isEmpty);
      expect(resource.selectedProject, isNull);
      expect(resource.projectsError, isNull);
      expect(host.calls.where((call) => call.$2 == 'projects.tree'), isEmpty);
    },
  );
}
