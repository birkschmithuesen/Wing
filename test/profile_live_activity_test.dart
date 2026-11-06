import 'support/canonical_gateway_fixture.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ActivityHost {
  final calls = <(String, String, Map<String, dynamic>)>[];
  final reads = <(String, String)>[];
  final live = <Map<String, dynamic>>[];
  final saved = <String, List<Map<String, dynamic>>>{
    'a': [
      {'id': 'same', 'title': 'Known phone chat', 'profile': 'a'},
    ],
  };
  final failedProfiles = <String>{};
  final profiles = ['a', 'b'];
  bool resumedRunning = false;
  final searchTips = <String, String>{};
  final metadataFailures = <String, Object>{};
  final metadataOverrides = <String, Map<String, dynamic>>{};

  Future<ProfileDiscovery> discover() async => ProfileDiscovery(
    profiles: profiles.map((name) => HermesProfile(name: name)).toList(),
    currentName: 'a',
    activeName: 'a',
  );

  ProfileGateway gateway(WorkspaceScope scope) => ProfileGateway(
    scope: scope,
    discover: discover,
    get: (path, query) async {
      reads.add((scope.profileName, path));
      if (path == 'sessions/search') {
        if (failedProfiles.contains(scope.profileName)) {
          throw StateError('Profile offline');
        }
        return {
          'results': (saved[scope.profileName] ?? const [])
              .where((row) => row['id'] == query['q'])
              .map(
                (row) => {
                  'session_id': searchTips[row['id']] ?? row['id'],
                  'title': row['title'],
                  'profile': row['profile'],
                },
              )
              .toList(),
        };
      }
      if (RegExp(r'^sessions/[^/]+$').hasMatch(path)) {
        if (failedProfiles.contains(scope.profileName)) {
          throw StateError('Profile offline');
        }
        final failure = metadataFailures[scope.profileName];
        if (failure != null) throw failure;
        final id = Uri.decodeComponent(path.split('/')[1]);
        final matches =
            (saved[scope.profileName] ?? const <Map<String, dynamic>>[])
                .where((row) => row['id'] == id)
                .toList();
        if (matches.isEmpty) throw DashboardSessionNotFound(path);
        return metadataOverrides[scope.profileName] ?? matches.single;
      }
      if (path == 'sessions') {
        final rows = saved[scope.profileName] ?? <Map<String, dynamic>>[];
        return {
          'sessions': rows,
          'offset': int.parse(query['offset']!),
          'limit': int.parse(query['limit']!),
          'total': rows.length,
        };
      }
      return {
        'session_id': path.split('/')[1],
        'messages': <Map<String, dynamic>>[],
        'pagination': {
          'offset': 0,
          'limit': 50,
          'returned': 0,
          'order': 'latest',
        },
      };
    },
    rpc: (method, params) async {
      calls.add((scope.profileName, method, params));
      if (method == 'subagent.roster') return {'sessions': <Object>[]};
      if (method == 'projects.tree') return {'projects': []};
      if (method == 'session.active_list') {
        if (failedProfiles.contains(scope.profileName)) {
          throw StateError('Profile offline');
        }
        return {'sessions': live};
      }
      if (method == 'session.create' || method == 'session.resume') {
        return {
          ...canonicalSnapshotFields,
          'session_id': '${scope.profileName}-runtime',
          'stored_session_id': 'same',
          'running': resumedRunning,
          'info': {'profile_name': scope.profileName},
        };
      }
      return {};
    },
  );
}

void main() {
  late ActivityHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
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
      connectionIdentity: 'activity-test',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = ActivityHost();
    await initialize();
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> restorePending(String profile) async {
    final key = ProfileSessionKey(
      WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: 'activity-test',
        profileName: profile,
      ),
      'same',
    );
    await (await SharedPreferences.getInstance()).setStringList(
      'profile_pending_v2_activity-test',
      [jsonEncode(key.toJson())],
    );
    controller.dispose();
    appPreferences.dispose();
    host.resumedRunning = true;
    await initialize();
  }

  test('recovered running chat keeps its saved title in Activity', () async {
    await restorePending('a');
    expect(controller.liveActivity.single.title, 'Known phone chat');
    host.live.add({
      'id': 'a-runtime',
      'session_key': 'same',
      'status': 'working',
    });
    await controller.refreshActivity();
    expect(controller.liveActivity.single.title, 'Known phone chat');
  });

  test(
    'recovery resolves a title in a profile whose list is not loaded',
    () async {
      host.saved['b'] = [
        {'id': 'same', 'title': 'Background profile chat', 'profile': 'b'},
      ];
      await restorePending('b');
      expect(controller.liveActivity.single.title, 'Background profile chat');
      expect(controller.current!.scope.profileName, 'a');
    },
  );

  test(
    'failed title lookup preserves recovery and Activity refresh retries',
    () async {
      host.saved['b'] = [
        {'id': 'same', 'title': 'Background profile chat', 'profile': 'b'},
      ];
      host.failedProfiles.add('b');
      await restorePending('b');
      expect(controller.liveActivity.single.title, 'Hermes session · same');
      expect(controller.liveActivity.single.sessionId, 'same');
      host.failedProfiles.clear();
      host.live.add({
        'id': 'b-runtime',
        'session_key': 'same',
        'status': 'working',
      });
      await controller.refreshActivity();
      expect(controller.liveActivity.single.title, 'Background profile chat');
    },
  );

  test('discovers unopened live sessions without changing selection', () async {
    final selected = await controller.createChat(canDispatch: () => true);
    final selectedScope = controller.current!.scope;
    host.reads.clear();
    host.live.addAll([
      {
        'id': 'a-live',
        'session_key': 'same',
        'status': 'working',
        'last_active': 2,
      },
      {
        'id': 'b-unknown',
        'session_key': 'never-opened',
        'status': 'working',
        'last_active': 1,
      },
    ]);
    host.profiles.add('c');

    await controller.refreshActivity();

    expect(controller.liveActivity, hasLength(1));
    expect(controller.liveActivity.single.workspace.profileName, 'a');
    expect(controller.liveActivity.single.sessionId, 'same');
    expect(controller.liveActivity.single.title, 'Known phone chat');
    expect(
      controller.activityProfileErrors['ownership'],
      'Some live sessions were hidden because their profile could not be verified.',
    );
    expect(
      host.calls.where((call) => call.$2 == 'session.active_list'),
      hasLength(1),
    );
    expect(
      host.reads
          .where((read) => read.$2 == 'sessions/same')
          .map((read) => read.$1)
          .toSet(),
      {'a', 'b', 'c'},
    );
    expect(controller.current!.scope, selectedScope);
    expect(controller.current!.chat, same(selected));
    expect(host.calls.where((call) => call.$2 == 'session.resume'), isEmpty);
  });

  test(
    'verifies live ownership by exact ID when search resolves a compression tip',
    () async {
      host.searchTips['same'] = 'compressed-tip';
      host.live.add({
        'id': 'remote-runtime',
        'session_key': 'same',
        'status': 'working',
      });

      await controller.refreshActivity();

      expect(controller.liveActivity, hasLength(1));
      expect(controller.liveActivity.single.workspace.profileName, 'a');
      expect(controller.liveActivity.single.sessionId, 'same');
      expect(controller.activityProfileErrors, isEmpty);
      expect(host.reads.where((read) => read.$2 == 'sessions/search'), isEmpty);
      expect(host.calls.where((call) => call.$2 == 'session.resume'), isEmpty);
    },
  );

  for (final failure in <Object>[
    const DashboardHttpException(404, 'sessions/same'),
    const DashboardSessionNotFound('sessions/another'),
    const FormatException('Malformed response'),
  ]) {
    test('unavailable profile metadata remains uncertain: $failure', () async {
      host.metadataFailures['b'] = failure;
      host.live.add({
        'id': 'remote-runtime',
        'session_key': 'same',
        'status': 'working',
      });

      await controller.refreshActivity();

      expect(controller.liveActivity, isEmpty);
      expect(
        controller.activityProfileErrors.keys,
        containsAll(['b', 'ownership']),
      );

      host.metadataFailures.clear();
      await controller.refreshActivity();
      expect(controller.liveActivity.single.workspace.profileName, 'a');
      expect(controller.activityProfileErrors, isEmpty);
    });
  }

  for (final invalid in <Map<String, dynamic>>[
    {'id': 'same', 'profile': 'b'},
    {'id': 'compression-tip', 'profile': 'a'},
    {'id': 'same'},
  ]) {
    test('rejects contradictory exact detail metadata: $invalid', () async {
      host.metadataOverrides['a'] = invalid;
      host.live.add({
        'id': 'remote-runtime',
        'session_key': 'same',
        'status': 'working',
      });

      await controller.refreshActivity();

      expect(controller.liveActivity, isEmpty);
      expect(
        controller.activityProfileErrors.keys,
        containsAll(['a', 'ownership']),
      );
    });
  }

  test('removes ended entries from the global snapshot', () async {
    final completed = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, completed, 'message.start');
    emitChatEvent(controller, completed, 'session.info', {
      'open_requests': [],
      'running': false,
    });
    host.live.addAll([
      {'id': 'old-a', 'session_key': 'same', 'status': 'working'},
    ]);
    await controller.refreshActivity();
    expect(controller.liveActivity, hasLength(1));

    host.live.clear();
    await controller.refreshActivity();

    expect(controller.liveActivity, isEmpty);
    expect(controller.activity, contains(completed));
    expect(controller.activityProfileErrors, isEmpty);
    expect(controller.activityLoading, isFalse);
  });

  test('hides a global row with ambiguous saved ownership', () async {
    host.saved['b'] = [
      {'id': 'same', 'title': 'Colliding chat', 'profile': 'b'},
    ];
    host.live.add({
      'id': 'foreign-runtime',
      'session_key': 'same',
      'status': 'working',
    });

    await controller.refreshActivity();

    expect(controller.liveActivity, isEmpty);
    expect(controller.activityProfileErrors['ownership'], isNotNull);
    expect(host.calls.where((call) => call.$2 == 'session.resume'), isEmpty);
  });

  test(
    'hides saved ownership when another profile cannot be checked',
    () async {
      host.failedProfiles.add('b');
      host.live.add({
        'id': 'foreign-runtime',
        'session_key': 'same',
        'status': 'working',
      });

      await controller.refreshActivity();

      expect(controller.liveActivity, isEmpty);
      expect(
        controller.activityProfileErrors.keys,
        containsAll(['b', 'ownership']),
      );
    },
  );

  test(
    'uses an exact local runtime and durable identity to resolve ownership',
    () async {
      final local = await controller.createChat(canDispatch: () => true);
      host.saved['b'] = [
        {'id': local.key.sessionId, 'title': 'Colliding chat', 'profile': 'b'},
      ];
      host.live.add({
        'id': local.runtime.runtimeId,
        'session_key': local.key.sessionId,
        'status': 'working',
      });

      await controller.refreshActivity();

      expect(controller.liveActivity, hasLength(1));
      expect(controller.liveActivity.single.workspace.profileName, 'a');
      expect(controller.activityProfileErrors['ownership'], isNull);
    },
  );
}
