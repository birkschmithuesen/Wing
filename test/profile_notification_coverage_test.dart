import 'support/composer_fixture.dart' show stockChatReply;
import 'support/canonical_gateway_fixture.dart';
import 'dart:convert';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/models/chat_list_status.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_live_activity.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationCoverageHost {
  final gateways = <String, ProfileGateway>{};
  final admissions = <String, Map<String, dynamic>>{};
  final durableIds = <String, String>{};
  final saved = <String, List<Map<String, dynamic>>>{
    'a': [
      {'id': 'outside', 'title': 'Outside task', 'profile': 'a'},
      {'id': 'loaded', 'title': 'Loaded task', 'profile': 'a'},
    ],
    'b': <Map<String, dynamic>>[],
  };
  List<Map<String, dynamic>> active = [];
  final rosters = <String, Map<String, dynamic>>{};
  final rosterReads = <({String source, String profile})>[];
  final failedRosters = <String>{};
  Completer<void>? rosterDelay;
  final rosterDelays = <String, Completer<void>>{};
  final metadataDelays = <(String, String), Completer<void>>{};
  final connectProfiles = <String>[];
  final profileNames = ['a', 'b'];
  List<Map<String, dynamic>> groups = [];
  final groupStates = <String, Map<String, dynamic>>{};
  final groupLogs = <String, List<Map<String, dynamic>>>{};
  int activeReads = 0;
  final resumeCalls = <Map<String, dynamic>>[];
  Completer<void>? resumeDelay;
  final resumeDelays = <int, Completer<void>>{};
  final resumeSnapshots = <int, Map<String, dynamic>>{};
  List<Map<String, dynamic>> history = [];
  final historyByProfile = <String, List<Map<String, dynamic>>>{};
  final createdSessionIds = <String, String>{};
  bool activeFails = false;
  bool groupFails = false;
  bool historyFails = false;
  Completer<void>? historyDelay;
  bool resumeFails = false;
  bool lazyResume = false;
  List<Map<String, dynamic>> pendingApprovals = [];
  final approvalReads = <Map<String, dynamic>>[];
  List<Map<String, dynamic>>? questions;
  Map<String, dynamic> resumeOverrides = {};
  final workingProfiles = <String>{};
  final waitingProfiles = <String>{};
  final failedMetadataProfiles = <String>{};

  Future<ProfileDiscovery> discover() async => ProfileDiscovery(
    profiles: profileNames.map((name) => HermesProfile(name: name)).toList(),
    currentName: 'a',
    activeName: 'a',
  );

  ProfileGateway gateway(WorkspaceScope scope) {
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: discover,
      connect: () async {
        connectProfiles.add(scope.profileName);
        // Short-lived catalog readers have no stream consumer. Events still
        // belong to the retained conversation gateway after those readers close.
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
      },
      get: (path, query) async {
        if (path == 'sessions/search') {
          if (failedMetadataProfiles.contains(scope.profileName)) {
            throw StateError('profile unavailable');
          }
          return {
            'results': (saved[scope.profileName] ?? const [])
                .where((row) => row['id'] == query['q'])
                .map(
                  (row) => {
                    'session_id': row['id'],
                    'title': row['title'],
                    'profile': row['profile'],
                  },
                )
                .toList(),
          };
        }
        if (RegExp(r'^sessions/[^/]+$').hasMatch(path)) {
          if (failedMetadataProfiles.contains(scope.profileName)) {
            throw StateError('profile unavailable');
          }
          final id = Uri.decodeComponent(path.split('/')[1]);
          await metadataDelays[(scope.profileName, id)]?.future;
          final rows =
              (saved[scope.profileName] ?? const <Map<String, dynamic>>[])
                  .where((row) => row['id'] == id)
                  .toList();
          if (rows.isEmpty) throw DashboardSessionNotFound(path);
          return rows.single;
        }
        if (path == 'sessions') {
          final rows = saved[scope.profileName] ?? const [];
          return {
            'sessions': rows,
            'offset': int.parse(query['offset']!),
            'limit': int.parse(query['limit']!),
            'total': rows.length,
          };
        }
        if (path == 'logs') return {'entries': <Map<String, dynamic>>[]};
        await historyDelay?.future;
        if (historyFails) throw StateError('history unavailable');
        final savedHistory = historyByProfile[scope.profileName] ?? history;
        final offset = int.tryParse(query['offset'] ?? '') ?? 0;
        final limit = int.tryParse(query['limit'] ?? '') ?? 50;
        final page = savedHistory.skip(offset).take(limit).toList();
        return {
          'session_id': path.split('/')[1],
          'messages': page,
          'pagination': {
            'offset': offset,
            'limit': limit,
            'returned': page.length,
            'order': 'latest',
          },
        };
      },
      rpc: (method, params) async {
        if (method == 'subagent.roster') {
          final profile = params['profile'] as String;
          rosterReads.add((source: scope.profileName, profile: profile));
          final snapshot = rosters[profile] ?? {'sessions': <Object>[]};
          await (rosterDelays[profile] ?? rosterDelay)?.future;
          if (failedRosters.contains(profile)) {
            throw StateError('Roster offline');
          }
          return snapshot;
        }
        if (method.startsWith('groups.') && groupFails) {
          throw StateError('group unavailable');
        }
        if (method == 'groups.list') {
          return {'rooms': groups, 'next_offset': null};
        }
        if (method == 'groups.state') {
          final state = groupStates[params['room_id']]!;
          return {
            ...state,
            'room': {
              'members': <Map<String, dynamic>>[],
              ...Map<String, dynamic>.from(state['room']),
            },
            'driver_status': {
              'pending_actions': <Map<String, dynamic>>[],
              ...Map<String, dynamic>.from(state['driver_status'] ?? {}),
            },
          };
        }
        if (method == 'groups.log') {
          final events = groupLogs[params['room_id']] ?? [];
          final latest = groupStates[params['room_id']]!['room']['latest_seq'];
          return {
            'events': events
                .where((e) => e['seq'] > params['since_seq'])
                .toList(),
            'cursor': latest,
            'latest_seq': latest,
            'has_more': false,
            'authority': {'gateway_id': 'fixture', 'epoch': 1},
          };
        }
        if (method == 'session.active_list') {
          activeReads++;
          if (activeFails) throw StateError('offline');
          return {'sessions': active};
        }
        if (method == 'projects.tree') return {'projects': []};
        if (method == 'approval.pending') {
          approvalReads.add(Map.of(params));
          return {'approvals': pendingApprovals};
        }
        if (method == 'prompt.submit') {
          if (params['submission_id'] is! String) {
            throw const FormatException('Missing submission identity');
          }
          return admissions.putIfAbsent(
            '${scope.profileName}:${params['session_id']}:${params['submission_id']}',
            () => canonicalReceipt(
              params,
              admissionId: 'notification-admission-${admissions.length + 1}',
              sequence: admissions.length + 1,
            ),
          );
        }
        if (method == 'session.create' || method == 'session.resume') {
          int? resumeCall;
          if (method == 'session.resume') {
            resumeCalls.add(Map.of(params));
            resumeCall = resumeCalls.length;
            await (resumeDelays[resumeCall] ?? resumeDelay)?.future;
            if (resumeFails) throw StateError('resume unavailable');
          }
          final sessionId = method == 'session.create'
              ? createdSessionIds[scope.profileName] ?? 'loaded'
              : durableIds['${scope.profileName}:${params['session_id']}'] ??
                    params['session_id'] as String;
          durableIds['${scope.profileName}:$sessionId-runtime'] = sessionId;
          final pending = admissions.values
              .where(
                (row) =>
                    (row['ref'] as Map)['session_id'] == '$sessionId-runtime' &&
                    (row['ref'] as Map)['profile_id'] ==
                        '/fixture/${scope.profileName}' &&
                    row['status'] != 'terminal',
              )
              .toList();
          if (method == 'session.resume' && lazyResume) {
            return {
              ...canonicalSnapshotFields,
              'pending': pending,
              'running': false,
              'open_requests': <Map<String, dynamic>>[],
              'session_id': '$sessionId-runtime',
              'stored_session_id': sessionId,
              'message_count': 0,
              'messages': <Map<String, dynamic>>[],
              'info': {'profile_name': scope.profileName, 'lazy': true},
            };
          }
          return {
            ...canonicalSnapshotFields,
            'pending': pending,
            'session_id': '$sessionId-runtime',
            'stored_session_id': sessionId,
            'running':
                method == 'session.resume' &&
                workingProfiles.contains(scope.profileName),
            'open_requests': [
              if (method == 'session.resume' &&
                  waitingProfiles.contains(scope.profileName))
                {
                  'id': 'question-${scope.profileName}',
                  'method': 'clarify',
                  'params': {
                    'session_id': '$sessionId-runtime',
                    if (questions == null)
                      'question': 'Continue?'
                    else
                      'questions': questions,
                  },
                },
            ],
            'info': {'profile_name': scope.profileName},
            if (method == 'session.resume') ...resumeOverrides,
            ...?resumeSnapshots[resumeCall],
          };
        }
        return {};
      },
    );
    return gateway;
  }

  void changed() => gateways['a']!.onEvent!(
    StreamEvent(type: 'sessions.changed', data: const {}),
  );

  void connection(bool connected) =>
      gateways['a']!.onConnectionChanged!(connected);

  Iterable<Map<String, dynamic>> _turnAdmissions(
    String profile,
    String runtime,
  ) => admissions.values.where(
    (row) =>
        (row['ref'] as Map)['profile_id'] == '/fixture/$profile' &&
        (row['ref'] as Map)['session_id'] == runtime,
  );

  void _pending(String profile, String runtime) {
    gateways[profile]!.onEvent!(
      StreamEvent(
        type: 'session.info',
        sessionId: runtime,
        data: {
          'pending': _turnAdmissions(
            profile,
            runtime,
          ).where((row) => row['status'] != 'terminal').toList(),
        },
      ),
    );
  }

  /// Model the server claiming an admitted input, including one queued while
  /// foreground recovery was observing an already-working session.
  void startTurn(String profile, String runtime) {
    final pending = _turnAdmissions(
      profile,
      runtime,
    ).where((row) => row['status'] != 'terminal');
    if (pending.isNotEmpty) pending.first['status'] = 'started';
    _pending(profile, runtime);
    gateways[profile]!.onEvent!(
      StreamEvent(
        type: 'message.start',
        sessionId: runtime,
        data: stockChatReply(gateways[profile]!, 'message.start', {}),
      ),
    );
  }

  void completeTurn(String profile, String runtime, String reply) {
    for (final row in _turnAdmissions(profile, runtime)) {
      if (row['status'] == 'started') {
        row['status'] = 'terminal';
        row['outcome'] = 'completed';
      }
    }
    _pending(profile, runtime);
    gateways[profile]!.onEvent!(
      StreamEvent(
        type: 'message.complete',
        sessionId: runtime,
        data: {'text': reply},
      ),
    );
  }
}

Future<void> waitForReads(NotificationCoverageHost host, int count) async {
  for (var i = 0; i < 100 && host.activeReads < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(host.activeReads, count);
  await Future<void>.delayed(Duration.zero);
}

Map<String, dynamic> row(
  String runtime,
  String session,
  String status, [
  double lastActive = 1,
]) => {
  'id': runtime,
  'session_key': session,
  'status': status,
  'last_active': lastActive,
};

void main() {
  late NotificationCoverageHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late bool disposed;
  late List<ProfileInputNotification> inputNotices;
  late List<String> previews;
  late List<({String profile, String session, bool input})> alerts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = NotificationCoverageHost();
    disposed = false;
    alerts = [];
    previews = [];
    inputNotices = [];
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
      connectionIdentity: 'notification-coverage',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      onNotificationInputs: (snapshot) async => inputNotices.add(snapshot),
      onAttention: (notification) async {
        previews.add(notification.content.preview);
        alerts.add((
          profile: notification.key.workspace.profileName,
          session: notification.key.sessionId,
          input: notification.content.needsAttention,
        ));
      },
    );
    await controller.initialize();
    host.activeReads = 0;
    controller.setRouteVisibility(controller, false);
  });

  tearDown(() {
    if (!disposed) controller.dispose();
    appPreferences.dispose();
  });

  test(
    'answered background question settles after reconnect and posts its reply',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      // Startup catalog readers must not replace the live event target used
      // by the background device fixture.
      await controller.refreshRecents();
      // The device fixture exposes working state before the UI submits. A
      // foreground recovery can observe it and correctly enqueue the input.
      host.workingProfiles.add('a');
      await controller.reconnect(chat.key.workspace);
      chat.composer.editText('Native fixture work');
      await controller.send(chat);
      void event(String type, Map<String, dynamic> data) {
        host.gateways['a']!.onEvent!(
          StreamEvent(
            type: type,
            sessionId: chat.runtime.runtimeId,
            data: data,
          ),
        );
      }

      host.startTurn('a', chat.runtime.runtimeId);
      host.waitingProfiles.add('a');
      event('clarify', {'request_id': 'question-a', 'question': 'Continue?'});
      await Future<void>.delayed(Duration.zero);
      expect(alerts, [(profile: 'a', session: 'loaded', input: true)]);
      await controller.reconnect(chat.key.workspace);
      await controller.clarify(chat, 'Continue');
      host.waitingProfiles.clear();
      host.startTurn('a', chat.runtime.runtimeId);
      host.history = [
        {'id': 1, 'role': 'assistant', 'content': 'Reply ready'},
      ];
      host.completeTurn('a', chat.runtime.runtimeId, 'Reply ready');
      await Future<void>.delayed(Duration.zero);
      expect(chat.composer.observation.queue, isEmpty);
      expect(alerts, [
        (profile: 'a', session: 'loaded', input: true),
        (profile: 'a', session: 'loaded', input: false),
      ]);
    },
  );

  test(
    'resume durable identity requires the canonical stored identity without mutation',
    () {
      final gateway = controller.current!.gateway;
      final base = <String, dynamic>{
        ...canonicalSnapshotFields,
        'session_id': 'outside-runtime',
        'info': {'profile_name': 'a'},
      };
      for (final lazy in [false, true]) {
        final snapshot = Map<String, dynamic>.unmodifiable({
          ...base,
          'stored_session_id': 'outside',
          'info': {'profile_name': 'a', if (lazy) 'lazy': true},
        });
        expect(gateway.resumeDurableId(snapshot), 'outside');
        expect(snapshot['session_id'], 'outside-runtime');
        expect(snapshot.containsKey('session_key'), isFalse);
      }
      for (final invalid in <Map<String, dynamic>>[
        base,
        {...base, 'stored_session_id': ''},
        {...base, 'stored_session_id': 42},
        {...base, 'stored_session_id': null},
        {...base, 'session_key': 'outside'},
      ]) {
        expect(() => gateway.resumeDurableId(invalid), throwsFormatException);
      }
    },
  );

  test(
    'cold notification request adopts the canonical lazy snapshot',
    () async {
      host.lazyResume = true;
      host.pendingApprovals = [
        {
          'request_id': 'lazy-approval',
          'command': 'print(1)',
          'choices': ['once', 'deny'],
        },
      ];
      final key = ProfileSessionKey(controller.current!.scope, 'outside');
      final chat = await controller.loadNotificationApproval(key);
      expect(chat, isNotNull);
      expect(chat!.key, key);
      expect(chat.runtime.runtimeId, 'outside-runtime');
      expect(chat.runtime.approval!.requestId, 'lazy-approval');
      expect(host.approvalReads, isNotEmpty);
      expect(
        host.approvalReads.map((call) => call['session_id']),
        everyElement('outside-runtime'),
      );
      expect(controller.current!.chat, isNull);
      expect(host.resumeCalls.single['session_id'], 'outside');
    },
  );

  test('canonical lazy first-request read does not invent input', () async {
    host.lazyResume = true;
    host.active = [row('outside-runtime', 'outside', 'working')];
    host.changed();
    await waitForReads(host, 1);
    expect(alerts, isEmpty);
    host.waitingProfiles.add('a');
    host.active = [row('outside-runtime', 'outside', 'waiting', 2)];
    host.changed();
    await waitForReads(host, 2);
    expect(inputNotices, isEmpty);
    expect(alerts, isEmpty);
    expect(controller.notificationChats, isEmpty);
    expect(controller.current!.chat, isNull);
    expect(host.resumeCalls.single['display_projection'], isTrue);
  });

  test(
    'first unopened batch notification contains its current question and count',
    () async {
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await waitForReads(host, 1);
      expect(controller.notificationMonitoringChats.toList(), [
        (
          key: ProfileSessionKey(controller.current!.scope, 'outside'),
          payload: jsonEncode(
            ProfileSessionKey(controller.current!.scope, 'outside').toJson(),
          ),
          title: 'Outside task',
          state: 'working',
        ),
      ]);
      host.questions = [
        for (var i = 0; i < 3; i++)
          {
            'qid': 'q$i',
            'question': 'Which environment $i?',
            'choices': ['Preview', 'Production'],
          },
      ];
      host.waitingProfiles.add('a');
      host.active = [row('outside-runtime', 'outside', 'waiting', 2)];
      host.changed();
      await waitForReads(host, 2);
      expect(
        controller.current?.chat,
        isNull,
        reason: 'no chat opening may be required',
      );
      expect(inputNotices, hasLength(1));
      final notice = inputNotices.single;
      expect(notice.alert, isTrue);
      expect(notice.inputs.single.count, 3);
      expect(
        notice.inputs.single.content.preview,
        contains('Which environment 0?'),
      );
      expect(notice.inputs.single.focus.kind, 'question');
      expect(notice.inputs.single.focus.id, 'question-a');
      expect(notice.key.workspace.profileName, 'a');
    },
  );

  test(
    'unopened request is adopted without history and later live replies replace it',
    () async {
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await waitForReads(host, 1);
      expect(alerts, isEmpty, reason: 'the first snapshot is only a baseline');
      host.waitingProfiles.add('a');
      host.active = [row('outside-runtime', 'outside', 'waiting', 2)];
      host.changed();
      await waitForReads(host, 2);
      expect(alerts, [(profile: 'a', session: 'outside', input: true)]);
      expect(host.resumeCalls.single['display_projection'], isTrue);
      expect(controller.current?.chat, isNull);
      for (var turn = 0; turn < 2; turn++) {
        host.waitingProfiles.clear();
        host.gateways['a']!.onEvent!(
          StreamEvent(
            type: 'message.start',
            sessionId: 'outside-runtime',
            data: stockChatReply(host.gateways['a']!, 'message.start', {}),
          ),
        );
        host.gateways['a']!.onEvent!(
          StreamEvent(
            type: 'message.complete',
            sessionId: 'outside-runtime',
            data: {'text': 'Answer $turn'},
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }
      expect(alerts.where((alert) => !alert.input), hasLength(2));
      expect(controller.current?.chat, isNull);
    },
  );

  test(
    'private group workers never own monitoring or chat notifications',
    () async {
      host.saved['a']!.first.addAll({
        'source': 'bot_room',
        'title': 'Group: room-uuid',
      });
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await waitForReads(host, 1);
      expect(
        controller.hasActiveChats,
        isFalse,
        reason: 'Only shared room state owns group monitoring',
      );
      expect(controller.notificationMonitoringChats, isEmpty);
      host.history = [
        {'id': 1, 'role': 'assistant', 'content': 'Group reply'},
      ];
      host.active = [row('outside-runtime', 'outside', 'idle', 2)];
      host.changed();
      await waitForReads(host, 2);
      expect(controller.hasActiveChats, isFalse);
      expect(controller.notificationMonitoringChats, isEmpty);
      expect(alerts, isEmpty);
      expect(inputNotices, isEmpty);
      expect(host.resumeCalls, isEmpty);
    },
  );

  test(
    'multiple private worker states never replace shared group monitoring',
    () async {
      for (final saved in host.saved['a']!) {
        saved.addAll({'source': 'bot_room', 'title': 'Group: private-room'});
      }
      host.active = [
        row('outside-runtime', 'outside', 'working'),
        row('loaded-runtime', 'loaded', 'working'),
      ];
      host.changed();
      await waitForReads(host, 1);
      expect(controller.hasActiveChats, isFalse);
      expect(controller.notificationMonitoringChats, isEmpty);
      host.active = [
        row('outside-runtime', 'outside', 'idle'),
        row('loaded-runtime', 'loaded', 'working'),
      ];
      host.changed();
      await waitForReads(host, 2);
      expect(controller.hasActiveChats, isFalse);
      expect(controller.notificationMonitoringChats, isEmpty);
      host.active = [row('loaded-runtime', 'loaded', 'idle')];
      host.changed();
      await waitForReads(host, 3);
      expect(controller.hasActiveChats, isFalse);
      expect(controller.notificationMonitoringChats, isEmpty);
      expect(alerts, isEmpty);
      expect(inputNotices, isEmpty);
      expect(host.resumeCalls, isEmpty);
    },
  );

  for (final status in ['complete', 'error', 'interrupted']) {
    test('opened group worker stays silent on live $status', () async {
      host.saved['a']!.first.addAll({
        'source': 'bot_room',
        'title': 'Group: room-uuid',
        'hidden': true,
      });
      await controller.refresh();
      final chat = await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'outside'),
      );
      expect(chat!.source, 'bot_room');
      final gateway = controller.current!.gateway;
      host.history = [
        {'id': 1, 'role': 'assistant', 'content': 'Private group reply'},
      ];
      gateway.onEvent!(
        StreamEvent(
          type: 'message.start',
          sessionId: 'outside-runtime',
          data: stockChatReply(gateway, 'message.start', {}),
        ),
      );
      expect(controller.hasActiveChats, isFalse);
      expect(controller.notificationMonitoringChats, isEmpty);
      gateway.onEvent!(
        StreamEvent(
          type: 'message.complete',
          sessionId: 'outside-runtime',
          data: {'text': 'Private group reply', 'status': status},
        ),
      );
      for (var tick = 0; tick < 100 && controller.hasActiveChats; tick++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.hasActiveChats, isFalse);
      expect(chat.runtime.blocksTurnAdmission, isFalse);
      expect(alerts, isEmpty);
      expect(inputNotices, isEmpty);
      expect(controller.notificationMonitoringChats, isEmpty);
    });
  }

  test('opened group worker requests stay silent', () async {
    host.saved['a']!.first.addAll({
      'source': 'bot_room',
      'title': 'Group: room-uuid',
      'hidden': true,
    });
    await controller.refresh();
    final chat = await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'outside'),
    );
    final gateway = controller.current!.gateway;
    gateway.onEvent!(
      StreamEvent(
        type: 'clarify',
        sessionId: 'outside-runtime',
        data: {'request_id': 'worker-question', 'question': 'Continue?'},
      ),
    );
    gateway.onEvent!(
      StreamEvent(
        type: 'approval.request',
        sessionId: 'outside-runtime',
        data: {
          'kind': 'approval',
          'prompt_id': 'worker-approval',
          'execution_generation': gateway.canonical
              .session('outside-runtime')!
              .generation,
          'command': 'private command',
          'choices': ['once', 'deny'],
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(chat!.runtime.pendingQuestion, isNotNull);
    expect(chat.runtime.approval?.requestId, 'worker-approval');
    expect(chat.runtime.approval?.nativeGeneration, isNotNull);
    expect(alerts, isEmpty);
    expect(inputNotices, isEmpty);
    expect(controller.notificationMonitoringChats, isEmpty);
  });

  for (final botMessage in [true, false]) {
    for (final loaded in [true, false]) {
      test(
        '${loaded ? 'loaded' : 'unopened'} Bot Chat ${botMessage ? 'bot exchange stays silent' : 'human reply still alerts'}',
        () async {
          host.saved['a']!.first['title'] = 'Bot Chat';
          host.history = [
            {
              'id': 0,
              'role': 'user',
              'content': botMessage
                  ? 'Earlier human message'
                  : 'Message from 🤖 Default (@default): Earlier bot message',
            },
            {
              'id': 1,
              'role': 'user',
              'content': botMessage
                  ? 'Message from 🤖 Default (@default): Please review the group plan.'
                  : 'Please review the group plan.',
            },
            {
              'id': 2,
              'role': 'user',
              'content': 'Private reminder',
              'display_kind': 'hidden',
            },
            {
              'id': 3,
              'role': 'user',
              'content': 'Model changed',
              'display_kind': 'model_switch',
            },
            {'id': 4, 'role': 'assistant', 'content': 'Here is my review.'},
          ];
          if (loaded) {
            await controller.openSession(
              ProfileSessionKey(controller.current!.scope, 'outside'),
            );
            final gateway = controller.current!.gateway;
            gateway.onEvent!(
              StreamEvent(
                type: 'message.start',
                sessionId: 'outside-runtime',
                data: stockChatReply(gateway, 'message.start', {}),
              ),
            );
            gateway.onEvent!(
              StreamEvent(
                type: 'message.complete',
                sessionId: 'outside-runtime',
                data: {'text': 'Here is my review.'},
              ),
            );
            for (
              var tick = 0;
              tick < 100 && controller.hasActiveChats;
              tick++
            ) {
              await Future<void>.delayed(Duration.zero);
            }
            expect(controller.hasActiveChats, isFalse);
          } else {
            host.active = [row('outside-runtime', 'outside', 'working')];
            host.changed();
            await waitForReads(host, 1);
            host.active = [row('outside-runtime', 'outside', 'idle', 2)];
            host.changed();
            await waitForReads(host, 2);
          }
          expect(alerts, hasLength(botMessage ? 0 : 1));
          expect(previews, botMessage ? isEmpty : ['Here is my review.']);
        },
      );
    }
  }

  test(
    'bot exchange keeps attention and user side-task notifications',
    () async {
      host.history = [
        {
          'id': 1,
          'role': 'user',
          'content':
              'Message from 🤖 Default (@default): Review the group plan.',
        },
      ];
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'outside'),
      );
      final gateway = controller.current!.gateway;
      gateway.onEvent!(
        StreamEvent(
          type: 'clarify',
          sessionId: 'outside-runtime',
          data: {'request_id': 'question', 'question': 'Allow this action?'},
        ),
      );
      for (final kind in ['btw.complete', 'background.complete']) {
        gateway.onEvent!(
          StreamEvent(
            type: kind,
            sessionId: 'outside-runtime',
            data: {'task_id': kind, 'text': 'User task: $kind'},
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(alerts, hasLength(3));
      expect(alerts.first.input, isTrue);
      expect(previews.skip(1), [
        'User task: btw.complete',
        'User task: background.complete',
      ]);
      expect(inputNotices.single.inputs.single.focus.id, 'question');
    },
  );

  test('new live request wins over delayed first-request hydration', () async {
    host.active = [row('outside-runtime', 'outside', 'working')];
    host.changed();
    await waitForReads(host, 1);
    host.waitingProfiles.add('a');
    host.resumeDelay = Completer<void>();
    host.active = [row('outside-runtime', 'outside', 'waiting', 2)];
    host.changed();
    await waitForReads(host, 2);
    expect(
      controller.hasActiveChats,
      isTrue,
      reason: 'in-flight notification data must finish before monitoring stops',
    );
    host.gateways['a']!.onEvent!(
      StreamEvent(
        type: 'clarify',
        sessionId: 'outside-runtime',
        data: {'request_id': 'newer', 'question': 'New question?'},
      ),
    );
    host.resumeDelay!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(inputNotices.single.inputs.single.focus.id, 'newer');
    expect(
      controller.notificationChats.single.runtime.pendingQuestion!.requestId,
      'newer',
    );
    expect(controller.hasActiveChats, isFalse);
  });

  test(
    'failed first request read retries on the next invalidation without inventing actions',
    () async {
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await waitForReads(host, 1);
      host.resumeFails = true;
      host.waitingProfiles.add('a');
      host.active = [row('outside-runtime', 'outside', 'waiting', 2)];
      host.changed();
      await waitForReads(host, 2);
      expect(inputNotices, isEmpty);
      expect(controller.notificationChats, isEmpty);
      host.resumeFails = false;
      host.changed();
      await waitForReads(host, 3);
      expect(inputNotices.single.inputs.single.focus.id, 'question-a');
    },
  );

  test(
    'opening the chat wins over an older empty first-request resume',
    () async {
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await waitForReads(host, 1);
      host.waitingProfiles.add('a');
      host.resumeDelays[1] = Completer<void>();
      host.resumeDelays[2] = Completer<void>();
      host.resumeSnapshots[1] = {'open_requests': [], 'running': false};
      host.active = [row('outside-runtime', 'outside', 'waiting', 2)];
      host.changed();
      await waitForReads(host, 2);
      final candidate = controller.notificationChats.single;
      final opening = controller.openSession(candidate.key);
      await Future<void>.delayed(Duration.zero);
      expect(host.resumeCalls, hasLength(2));
      host.resumeDelays[1]!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.notificationChats, contains(same(candidate)));
      host.resumeDelays[2]!.complete();
      await opening;
      expect(controller.current!.chat, same(candidate));
      expect(candidate.runtime.pendingQuestion!.requestId, 'question-a');
    },
  );

  for (final mismatch in [
    {'session_id': 'other-runtime'},
    {'stored_session_id': 'other-chat'},
    {
      'info': {'profile_name': 'b'},
    },
  ]) {
    test(
      'first-request read rejects conflicting ownership: $mismatch',
      () async {
        host.active = [row('outside-runtime', 'outside', 'working')];
        host.changed();
        await waitForReads(host, 1);
        host.waitingProfiles.add('a');
        host.resumeOverrides = mismatch;
        host.active = [row('outside-runtime', 'outside', 'waiting', 2)];
        host.changed();
        await waitForReads(host, 2);
        expect(inputNotices, isEmpty);
        expect(controller.notificationChats, isEmpty);
        expect(controller.current?.chat, isNull);
      },
    );
  }

  test('deduplicates loaded event and reconciliation paths', () async {
    final loaded = await controller.createChat(canDispatch: () => true);
    host.active = [
      row(loaded.runtime.runtimeId, loaded.key.sessionId, 'working'),
    ];
    host.changed();
    await waitForReads(host, 1);

    host.gateways['a']!.onEvent!(
      StreamEvent(
        type: 'clarify',
        sessionId: loaded.runtime.runtimeId,
        data: const {'request_id': 'q1', 'question': 'Continue?'},
      ),
    );
    host.active = [
      row(loaded.runtime.runtimeId, loaded.key.sessionId, 'waiting', 2),
    ];
    host.changed();
    await waitForReads(host, 2);

    expect(alerts, [(profile: 'a', session: 'loaded', input: true)]);
  });

  // Stock session.active_list/session.resume checked at upstream Hermes
  // 9fc7f17906eab1dd81ddfdf8a1edeecac1e79940 (2026-09-26).
  test(
    'idle snapshot recovers a loaded chat after a missed completion',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Next question');
      host.gateways['a']!.onEvent!(
        StreamEvent(
          type: 'message.start',
          sessionId: chat.runtime.runtimeId,
          data: stockChatReply(host.gateways['a']!, 'message.start', {}),
        ),
      );
      expect(chat.runtime.blocksTurnAdmission, isTrue);
      host.history = [
        {'id': 1, 'role': 'assistant', 'content': 'Recovered answer'},
      ];
      host.active = [row(chat.runtime.runtimeId, chat.key.sessionId, 'idle')];
      host.changed();
      await waitForReads(host, 1);
      expect(chat.runtime.blocksTurnAdmission, isFalse);
      expect(chat.composer.observation.text, 'Next question');
      expect(host.resumeCalls, hasLength(1));
      expect(chat.reading.messages.single['content'], 'Recovered answer');
    },
  );

  test(
    'desktop resolution clears loaded question state from the chat list',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.gateways['a']!.onEvent!(
        StreamEvent(
          type: 'clarify',
          sessionId: chat.runtime.runtimeId,
          data: const {
            'request_id': 'desktop-question',
            'question': 'Continue?',
          },
        ),
      );
      host.active = [
        row(chat.runtime.runtimeId, chat.key.sessionId, 'waiting'),
      ];
      host.changed();
      await waitForReads(host, 1);
      expect(chat.runtime.pendingQuestion, isNotNull);
      expect(
        chatListStatus(const {}, runtime: chat.listObservation),
        ChatListStatus.needsInput,
      );

      // Desktop answered and finished while this chat was not selected. The
      // global snapshot arrives without request.cancel or message.complete.
      host.active = [
        row(chat.runtime.runtimeId, chat.key.sessionId, 'idle', 2),
      ];
      host.changed();
      await waitForReads(host, 2);
      for (var i = 0; i < 20 && chat.runtime.pendingQuestion != null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(chat.runtime.pendingQuestion, isNull);
      expect(
        chatListStatus(const {}, runtime: chat.listObservation),
        ChatListStatus.idle,
      );
      expect(controller.hasActiveChats, isFalse);
    },
  );

  test(
    'desktop completion clears an earlier waiting activity snapshot',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      host.active = [
        row(chat.runtime.runtimeId, chat.key.sessionId, 'waiting'),
      ];
      await controller.refreshActivity();
      expect(
        controller.liveActivity.single.state,
        ProfileLiveActivityState.needsInput,
      );
      final reads = host.activeReads;
      host.gateways['a']!.onEvent!(
        StreamEvent(
          type: 'message.complete',
          sessionId: chat.runtime.runtimeId,
          data: const {'text': 'Desktop question resolved'},
        ),
      );
      host.active = [
        row(chat.runtime.runtimeId, chat.key.sessionId, 'idle', 2),
      ];
      host.changed();
      await waitForReads(host, reads + 1);
      expect(chat.runtime.pendingQuestion, isNull);
      expect(chat.runtime.blocksTurnAdmission, isFalse);
      expect(controller.liveActivity, isEmpty);
    },
  );

  test('a newer question survives a delayed desktop-resolution read', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    void question(String id) => host.gateways['a']!.onEvent!(
      StreamEvent(
        type: 'clarify',
        sessionId: chat.runtime.runtimeId,
        data: {'request_id': id, 'question': 'Continue?'},
      ),
    );
    question('old');
    host.resumeDelay = Completer<void>();
    host.active = [row(chat.runtime.runtimeId, chat.key.sessionId, 'idle')];
    host.changed();
    await waitForReads(host, 1);
    expect(host.resumeCalls, hasLength(1));
    question('new');
    host.resumeDelay!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(chat.runtime.pendingQuestion?.requestId, 'new');
    expect(chat.runtime.needsInput, isTrue);
  });

  test('failed request refresh preserves the pending question', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.gateways['a']!.onEvent!(
      StreamEvent(
        type: 'clarify',
        sessionId: chat.runtime.runtimeId,
        data: const {'request_id': 'pending', 'question': 'Continue?'},
      ),
    );
    host.resumeFails = true;
    host.active = [row(chat.runtime.runtimeId, chat.key.sessionId, 'idle')];
    host.changed();
    await waitForReads(host, 1);
    expect(chat.runtime.pendingQuestion?.requestId, 'pending');
    expect(chat.runtime.needsInput, isTrue);
  });

  test('desktop resolution resumes monitoring while work continues', () async {
    final chat = await controller.createChat(canDispatch: () => true);
    host.gateways['a']!.onEvent!(
      StreamEvent(
        type: 'clarify',
        sessionId: chat.runtime.runtimeId,
        data: const {'request_id': 'pending', 'question': 'Continue?'},
      ),
    );
    host.workingProfiles.add('a');
    host.active = [row(chat.runtime.runtimeId, chat.key.sessionId, 'working')];
    host.changed();
    await waitForReads(host, 1);
    expect(chat.runtime.pendingQuestion, isNull);
    expect(chat.runtime.execution, ChatExecution.running);
    expect(controller.hasActiveChats, isTrue);
  });

  for (final status in ['idle', 'unknown', 'missing', 'failed']) {
    test(
      'activity reconciliation preserves side work or uncertainty: $status',
      () async {
        final chat = await controller.createChat(canDispatch: () => true);
        host.active = [
          row(chat.runtime.runtimeId, chat.key.sessionId, 'waiting'),
        ];
        await controller.refreshActivity();
        final reads = host.activeReads;
        host.activeFails = status == 'failed';
        host.active = [
          if (status != 'missing')
            {
              ...row(chat.runtime.runtimeId, chat.key.sessionId, status),
              'side_tasks_running': 1,
            },
        ];
        host.changed();
        await waitForReads(host, reads + 1);
        expect(
          controller.liveActivity.single.state,
          status == 'idle'
              ? ProfileLiveActivityState.running
              : ProfileLiveActivityState.needsInput,
        );
        if (status == 'idle') {
          expect(controller.liveActivity.single.sideTasksRunning, 1);
        }
      },
    );
  }

  test('failed and reconnected snapshots never imply completion', () async {
    host.active = [row('outside-runtime', 'outside', 'working')];
    host.changed();
    await waitForReads(host, 1);

    host.activeFails = true;
    host.changed();
    await waitForReads(host, 2);
    host.connection(false);
    host.connection(true);
    host.activeFails = false;
    host.active = [];
    host.changed();
    await waitForReads(host, 3);

    expect(alerts, isEmpty);
  });

  for (final status in [null, 'unknown']) {
    test('a $status runtime does not prove completion', () async {
      host.active = [row('outside-runtime', 'outside', 'working')];
      host.changed();
      await waitForReads(host, 1);
      host.active = [
        if (status != null) row('outside-runtime', 'outside', status, 2),
      ];
      host.changed();
      await waitForReads(host, 2);
      expect(alerts, isEmpty);
    });
  }

  test('unopened completion reads the latest official answer text', () async {
    host.active = [row('outside-runtime', 'outside', 'working')];
    host.changed();
    await waitForReads(host, 1);
    host.history = [
      {'id': 42, 'role': 'assistant', 'content': 'The export is ready.'},
    ];
    host.active = [row('outside-runtime', 'outside', 'idle', 2)];
    host.changed();
    await waitForReads(host, 2);
    expect(previews, ['The export is ready.']);
  });

  test('does not alert without one verified profile owner', () async {
    host.saved['b'] = [
      {'id': 'outside', 'title': 'Collision', 'profile': 'b'},
    ];
    host.active = [row('outside-runtime', 'outside', 'working')];
    host.changed();
    await waitForReads(host, 1);
    host.active = [row('outside-runtime', 'outside', 'idle', 2)];
    host.changed();
    await waitForReads(host, 2);
    expect(alerts, isEmpty);

    host.saved['b'] = [];
    host.failedMetadataProfiles.add('b');
    host.active = [row('outside-runtime-2', 'outside', 'working', 3)];
    host.changed();
    await waitForReads(host, 3);
    host.failedMetadataProfiles.clear();
    host.active = [row('outside-runtime-2', 'outside', 'idle', 4)];
    host.changed();
    await waitForReads(host, 4);
    expect(
      alerts,
      isEmpty,
      reason:
          'a chat without verified ownership never establishes tracked work',
    );
  });

  test('disposed controller ignores later invalidations', () async {
    controller.dispose();
    disposed = true;
    host.active = [row('outside-runtime', 'outside', 'working')];
    host.changed();
    await Future<void>.delayed(Duration.zero);
    expect(host.activeReads, 0);
    expect(alerts, isEmpty);
  });
}
