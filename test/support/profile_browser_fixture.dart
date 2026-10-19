import 'dart:async';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/ws_client.dart';

/// Authored UI data, never used by the production application or a live server.
class ProfileBrowserFixture {
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
  int promptSubmitFailures = 0;
  Map<String, dynamic> steerResult = {'status': 'queued'};
  final historyDelays = <(String, int), Completer<void>>{};
  final searchDelays = <String, Completer<void>>{};
  final liveSessions = <String, List<Map<String, dynamic>>>{};
  List<Map<String, dynamic>> historyRows(String profile, String id) => [];
  List<Map<String, dynamic>> searchRows(String profile, String query) => [
    for (final row in sessions(
      profile,
    ).where((r) => r['title'].toString().toLowerCase().contains(query)))
      {...row, 'session_id': row['id']},
  ];
  List<Map<String, dynamic>> projectSessions(String profile, String id) =>
      sessions(profile)
          .where(
            (r) => r['id'] == (profile == 'work' ? 'newest' : 'project-only'),
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
      return path == 'sessions'
          ? {
              'sessions': page,
              'offset': offset,
              'limit': limit,
              'total': rows.length,
            }
          : {'messages': []};
    },
    rpc: (method, params) async {
      calls.add((scope.profileName, method, params));
      if (method == 'session.active_list') {
        return {
          'sessions': liveSessions.values.expand((rows) => rows).toList(),
        };
      }
      if (method == 'projects.tree') {
        if (failProjects) throw StateError('Projects unavailable');
        return {
          'projects': [
            for (final project in projects(scope.profileName))
              {
                ...project,
                if (!project.containsKey('sessionIds'))
                  'sessionIds':
                      project['id'] == 'p2' || project['id'] == 'work-project'
                      ? projectSessions(
                          scope.profileName,
                          project['id'] as String,
                        ).map((r) => r['id']).toList()
                      : <String>[],
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
      if (method == 'session.resume' || method == 'session.create') {
        return {
          'session_id': 'runtime',
          'stored_session_id': 'new-chat',
          'messages': [],
          'info': {'profile_name': scope.profileName},
        };
      }
      if (method == 'session.steer') return steerResult;
      if (method == 'prompt.submit' && promptSubmitFailures > 0) {
        promptSubmitFailures--;
        throw JsonRpcError(method, 'Connection closed', reason: 'connection_closed');
      }
      return {};
    },
  );
}
