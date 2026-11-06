import 'canonical_gateway_fixture.dart';
import 'package:wing/core/services/group_observations.dart';
import 'dart:async';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/bots_session.dart';

/// Authored UI data, never used by the production application or a live server.
class ProfileBrowserFixture {
  final canonicalRevisions = <String, int>{};
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  final delays = <String, Completer<void>>{};
  final calls = <(String, String, Map<String, dynamic>)>[];
  final reads = <(String, Map<String, String>)>[];
  final pageDelays = <(String, int), Completer<void>>{};
  final pageFailures = <(String, int)>{};
  bool failWork = false;
  bool failProjects = false;
  bool failHistory = false;
  String? historySessionIdOverride;
  bool failSearch = false;
  final historyDelays = <(String, int), Completer<void>>{};
  final searchDelays = <String, Completer<void>>{};
  final sessionMetadataDelays = <(String, String), Completer<void>>{};
  final liveSessions = <String, List<Map<String, dynamic>>>{};
  final detachedSessions = <String, List<Map<String, dynamic>>>{};
  final hiddenSessions = <String, List<Map<String, dynamic>>>{};
  final compressionTips = <String, String>{};
  final botMetadata = <String, Map<String, dynamic>>{};
  final botAvatars = <String, String>{};
  Completer<void>? botAppearanceDelay;
  bool failBotAppearance = false;
  Future<Map<ProfileSessionKey, BotRecord>> botAppearances(
    Iterable<ProfileSessionKey> conversations,
  ) async {
    if (failBotAppearance) throw StateError('Appearance unavailable');
    final keys = conversations.toList();
    final workspace = keys.first.workspace;
    final source = BotsRepository(
      groupObservations: GroupObservations(workspace),
      scope: workspace,
      instance: 'Test',
      savedHistory: (_, _, _) async =>
          throw StateError('Appearance does not read history'),
      read: (profile, method, params) => gateway(
        WorkspaceScope(
          connectionId: workspace.connectionId,
          connectionIdentity: workspace.connectionIdentity,
          profileName: profile,
        ),
      ).call(method, params),
      command: (_, _, _, _, _) async => throw StateError('Passive appearance'),
      ownership: (_, _) async => throw StateError('No presence reads'),
    );
    final session = BotsSession((_) async => [source]);
    try {
      return await session.appearancesForConversations(
        keys,
        canRead: () => true,
      );
    } finally {
      session.dispose();
    }
  }

  List<Map<String, dynamic>> historyRows(String profile, String id) => [];
  List<Map<String, dynamic>> searchRows(String profile, String query) => [
    for (final row in [
      ...sessions(profile),
      ...?hiddenSessions[profile],
    ].where((r) => r['title'].toString().toLowerCase().contains(query)))
      (Map<String, dynamic>.from({...row, 'session_id': row['id']})
        ..remove('hidden')),
  ];
  List<Map<String, dynamic>> projectSessions(String profile, String id) =>
      sessions(profile)
          .where(
            (r) =>
                id == (profile == 'work' ? 'work-project' : 'p2') &&
                r['id'] == (profile == 'work' ? 'newest' : 'project-only'),
          )
          .toList();
  List<Map<String, dynamic>> projects(String profile) => profile == 'work'
      ? [
          {
            'id': 'work-project',
            'label': 'Work project',
            'path': '/work',
            'lastActive': now,
          },
        ]
      : [
          {
            'id': 'home',
            'label': 'Home',
            'isNoProject': true,
            'lastActive': now,
          },
          for (final entry in [
            (1, 'Archive', 6),
            (2, 'Mobile app', 1),
            (3, 'Home lab', 4),
            (4, 'Website', 2),
            (5, 'Utilities', 5),
            (6, 'Notes', 3),
          ])
            {
              'id': 'p${entry.$1}',
              'label': entry.$2,
              'path': '/${entry.$2}',
              'lastActive': now - entry.$3 * 3600,
            },
        ];

  List<Map<String, dynamic>> sessions(String profile) => profile == 'work'
      ? [
          {
            'id': 'newest',
            'title': 'Work chat',
            'profile': 'work',
            'last_active': now - 60,
          },
        ]
      : [
          {
            'id': 'old',
            'title': 'Update the setup guide',
            'profile': profile,
            'last_active': now - 86400,
          },
          {
            'id': 'pinned',
            'title': 'Plan the Android workspace',
            'profile': profile,
            'pinned': true,
            'last_active': now - 1209600,
          },
          {
            'id': 'newest',
            'title': 'Improve the conversation list',
            'profile': profile,
            'last_active': now - 7200,
          },
          {
            'id': 'project-only',
            'title': 'Project-only chat',
            'profile': profile,
            'last_active': now - 10800,
            'cwd': '/not-the-project-path',
          },
          {
            'id': 'pin-two',
            'title': 'Ideas to return to',
            'profile': profile,
            'pinned': true,
            'last_active': now - 1814400,
          },
          {
            'id': 'test',
            'title': 'Verify gateway reconnects',
            'profile': profile,
            'last_active': now - 18000,
          },
          {
            'id': 'docs',
            'title': 'Review documentation changes',
            'profile': profile,
            'last_active': now - 21600,
          },
        ];

  ProfileGateway gateway(WorkspaceScope scope) => ProfileGateway(
    scope: scope,
    discover: () async => const ProfileDiscovery(
      profiles: [
        HermesProfile(name: 'personal'),
        HermesProfile(name: 'work'),
      ],
      currentName: 'personal',
      activeName: 'personal',
    ),
    get: (path, query) async {
      reads.add((path, query));
      if (RegExp(r'^sessions/[^/]+/mutation-snapshot$').hasMatch(path)) {
        return {
          'session_id': Uri.decodeComponent(path.split('/')[1]),
          'exists': true,
          'runtime_revision': 0,
          'runtime_generation': 0,
        };
      }
      if (path == 'logs') return {'file': 'gui', 'lines': <String>[]};
      // Browser-only scenarios expose no configured models. Model-selection
      // scenarios override these explicit observations with their own catalog.
      if (path == 'model/options') return {'providers': <Object>[]};
      if (path == 'model/info') return <String, dynamic>{};
      final offset = int.parse(query['offset'] ?? '0');
      final limit = int.parse(query['limit'] ?? '50');
      if (path.endsWith('/messages')) {
        final id = Uri.decodeComponent(path.split('/')[1]);
        final rows = historyRows(
          scope.profileName,
          id,
        ).reversed.skip(offset).take(limit).toList().reversed.toList();
        await historyDelays[(id, offset)]?.future;
        if (failHistory) throw StateError('History offline');
        return {
          'session_id': historySessionIdOverride ?? id,
          'messages': rows,
          'pagination': {
            'offset': offset,
            'limit': limit,
            'returned': rows.length,
            'order': 'latest',
          },
        };
      }
      if (path == 'sessions/search') {
        final q = query['q']!;
        final rows = searchRows(scope.profileName, q);
        await searchDelays[q]?.future;
        if (failSearch) throw StateError('Search offline');
        return {'results': rows};
      }
      if (RegExp(r'^sessions/[^/]+$').hasMatch(path)) {
        final id = Uri.decodeComponent(path.split('/')[1]);
        await sessionMetadataDelays[(scope.profileName, id)]?.future;
        final rows = [
          ...sessions(scope.profileName),
          ...?hiddenSessions[scope.profileName],
        ].where((row) => row['id'] == id).toList();
        if (rows.isEmpty) throw DashboardSessionNotFound(path);
        return rows.single;
      }
      if (path != 'sessions') {
        throw StateError('Unhandled fixture GET: $path');
      }
      final rows =
          sessions(scope.profileName)
              .where(
                (row) =>
                    query['archived'] == 'include' ||
                    (row['archived'] == true) == (query['archived'] == 'only'),
              )
              .toList()
            ..sort(
              (a, b) =>
                  (b['last_active'] as num).compareTo(a['last_active'] as num),
            );
      final page = rows.skip(offset).take(limit).toList();
      final seen = page.map((row) => row['id']).toSet();
      page.addAll(
        rows.where((r) => r['pinned'] == true && !seen.contains(r['id'])),
      );
      await delays[scope.profileName]?.future;
      await pageDelays[(scope.profileName, offset)]?.future;
      if (pageFailures.contains((scope.profileName, offset))) {
        throw StateError('Page offline');
      }
      if (failWork && scope.profileName == 'work') throw StateError('Offline');
      return {
        'sessions': page,
        'offset': offset,
        'limit': limit,
        'total': rows.length,
      };
    },
    rpc: (method, params) async {
      calls.add((scope.profileName, method, params));
      if (method == 'profiles.list') {
        await botAppearanceDelay?.future;
        if (failBotAppearance) throw StateError('Appearance unavailable');
        return {
          'install_id': 'fixture',
          'bot_mode_protocol': true,
          'profiles': [
            for (final profile in ['personal', 'work'])
              {
                'name': profile,
                'has_avatar': botAvatars.containsKey(profile),
                'ui_meta': {
                  'hermes-bots': {
                    'title': profile,
                    'shape': 'circle',
                    'color': '#65c7bc',
                    ...?botMetadata[profile],
                  },
                },
                if ([
                      ...sessions(profile),
                      ...?hiddenSessions[profile],
                    ].where((row) => row['title'] == 'Bot Chat').firstOrNull
                    case final canonical?)
                  'canonical_session': {
                    'id': canonical['id'],
                    'resolved_id':
                        compressionTips[canonical['id']] ?? canonical['id'],
                  },
              },
          ],
        };
      }
      if (method == 'profiles.get_asset') {
        return {
          'found': botAvatars.containsKey(scope.profileName),
          'data': botAvatars[scope.profileName],
        };
      }
      if (method == 'commands.catalog') {
        return {'pairs': <List<String>>[]};
      }
      if (method == 'session.active_list') {
        return {
          'sessions': liveSessions.values.expand((rows) => rows).toList(),
        };
      }
      if (method == 'subagent.roster') {
        return {'sessions': detachedSessions[params['profile']] ?? <Object>[]};
      }
      if (method == 'session.list') {
        final rows = [
          ...sessions(scope.profileName),
          ...?hiddenSessions[scope.profileName],
        ].where((row) => row['title'] == params['title']).toList();
        return {
          'sessions': [
            for (final row in rows.take(1))
              {...row, 'resolved_id': compressionTips[row['id']] ?? row['id']},
          ],
        };
      }
      if (method == 'projects.tree') {
        if (failProjects) throw StateError('Projects unavailable');
        final projectRows = projects(scope.profileName);
        final assignedIds = {
          for (final project in projectRows)
            if (project['isNoProject'] != true)
              ...project.containsKey('sessionIds')
                  ? project['sessionIds'] as List
                  : projectSessions(
                      scope.profileName,
                      project['id'] as String,
                    ).map((row) => row['id']),
        };
        return {
          'projects': [
            for (final project in projectRows)
              {
                ...project,
                if (!project.containsKey('sessionIds'))
                  'sessionIds': project['isNoProject'] == true
                      ? sessions(scope.profileName)
                            .where((row) => !assignedIds.contains(row['id']))
                            .map((row) => row['id'])
                            .toList()
                      : projectSessions(
                          scope.profileName,
                          project['id'] as String,
                        ).map((row) => row['id']).toList(),
              },
          ],
        };
      }
      if (method == 'projects.project_sessions') {
        return {
          'project': {
            'id': params['project_id'],
            'repos': [
              {
                'groups': [
                  {
                    'sessions': projectSessions(
                      scope.profileName,
                      params['project_id'] as String,
                    ),
                  },
                ],
              },
            ],
          },
        };
      }
      if (method == 'prompt.submit') {
        if (params['submission_id'] is! String) {
          throw const FormatException('Missing submission identity');
        }
        return canonicalReceipt(
          params,
          admissionId: 'fixture-${params['submission_id']}',
        );
      }
      if (method == 'session.mutate') {
        canonicalRevisions['${scope.profileName}:${params['session_id']}'] =
            (params['expected_revision'] as int) + 1;
        return {
          'session_id': params['session_id'],
          'operation': params['operation'],
          'revision': (params['expected_revision'] as int) + 1,
          'execution_generation': params['expected_generation'],
          'status': 'applied',
        };
      }
      if (method == 'session.resume' || method == 'session.create') {
        final stored = [
          ...sessions(scope.profileName),
          ...?hiddenSessions[scope.profileName],
        ].where((row) => row['id'] == params['session_id']).firstOrNull;
        final runtimeId = method == 'session.create'
            ? 'runtime'
            : (liveSessions[scope.profileName] ?? [])
                      .where(
                        (row) => row['session_key'] == params['session_id'],
                      )
                      .firstOrNull?['id'] ??
                  'runtime-${params['session_id']}';
        return {
          ...canonicalSnapshotFields,
          'revision':
              canonicalRevisions['${scope.profileName}:$runtimeId'] ?? 0,
          'session_id': runtimeId,
          'stored_session_id': method == 'session.create'
              ? 'new-chat'
              : params['session_id'],
          'messages': [],
          'info': {
            'profile_name': scope.profileName,
            if (method == 'session.resume') 'source': stored?['source'],
            if (method == 'session.resume') 'title': stored?['title'],
            if (method == 'session.create') 'cwd': params['cwd'] ?? '/default',
          },
        };
      }
      return {};
    },
  );
}
