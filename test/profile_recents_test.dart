import 'package:wing/core/services/completion_diagnostics.dart';
import 'support/composer_fixture.dart' show stockChatReply;
import 'package:wing/core/services/group_observations.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'dart:async';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/models/session_visibility.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/workspace_recents_session.dart';
import 'package:wing/core/services/recent_conversation_session.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/ws_client.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_browser_fixture.dart';
import 'support/bots_fixture.dart';

class _RecentsFixture extends ProfileBrowserFixture {
  final messageRows = <(String, String), List<Map<String, dynamic>>>{};
  String? recentProject;
  Completer<void>? heldProjects;
  Completer<void>? projectsStarted;
  @override
  List<Map<String, dynamic>> projectSessions(String profile, String id) =>
      profile == 'personal' && id == recentProject
      ? sessions(
          profile,
        ).where((row) => ['shared-id', 'recent-0'].contains(row['id'])).toList()
      : super.projectSessions(profile, id);
  Completer<void>? heldResume;
  Completer<void>? resumeStarted;
  bool unread = false;
  double? lastRead;
  bool hiddenChat = false;
  int readWrites = 0;
  bool failHiddenMetadata = false;
  bool failDiscovery = false;
  Completer<void>? heldRead;
  bool failRead = false;
  final readWatermarks = <String, double>{};
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final delegate = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: () async {
        if (failDiscovery) throw http.ClientException('Discovery interrupted');
        return delegate.discover();
      },
      get: (path, query) async {
        if (failHiddenMetadata && path == 'sessions/shared-id') {
          throw StateError('Metadata interrupted');
        }
        return delegate.read(path, query);
      },
      rpc: (method, params) async {
        if (method == 'projects.tree' && heldProjects != null) {
          if (projectsStarted?.isCompleted == false) {
            projectsStarted!.complete();
          }
          await heldProjects!.future;
        }
        if (method == 'session.resume' && heldResume != null) {
          if (resumeStarted?.isCompleted == false) resumeStarted!.complete();
          await heldResume!.future;
        }
        return delegate.call(method, params);
      },
      ownedPatch: (path, body, canDispatch, onDispatched) async {
        if (!canDispatch()) throw StateError('Read superseded');
        expect(path, 'sessions/shared-id');
        expect(body['profile'], scope.profileName);
        expect(body['unread'], false);
        onDispatched();
        final readAt = DateTime.now().millisecondsSinceEpoch / 1000;
        await heldRead?.future;
        if (failRead) throw StateError('Read acknowledgement interrupted');
        unread = false;
        readWrites++;
        readWatermarks[scope.profileName] = readAt;
        for (final row
            in hiddenSessions[scope.profileName] ?? <Map<String, dynamic>>[]) {
          if (row['id'] == 'shared-id') row['last_read_at'] = now;
        }
        return {'ok': true};
      },
    );
  }

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) =>
      messageRows[(profile, id)] ??
      [
        if (id != 'empty' && id != 'active-empty')
          {
            'id': 1,
            'role': 'assistant',
            'content': 'Saved reply',
            'timestamp': id == 'heartbeat'
                ? now - 90000
                : [...sessions(profile), ...?hiddenSessions[profile]]
                          .where((row) => row['id'] == id)
                          .firstOrNull?['last_active'] ??
                      now - 90000,
          },
      ];
  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    if (profile == 'personal')
      {
        'id': 'room-worker',
        'title': 'Group: room-uuid',
        'profile': profile,
        'source': 'bot_room',
        'last_active': now,
      },
    for (final id in ['empty', 'heartbeat'])
      {'id': id, 'title': id, 'profile': profile, 'last_active': now},
    if (profile == 'personal')
      for (var i = 0; i < 105; i++)
        {
          'id': 'recent-$i',
          'title': 'Finished conversation $i',
          'profile': profile,
          'last_active': now - i * 60,
          'pinned': i == 0,
        },
    if (!hiddenChat)
      {
        'id': 'shared-id',
        'title': '$profile conversation',
        'profile': profile,
        'last_active': now - 600,
        'archived': profile == 'work',
        'unread': unread,
        'last_read_at': readWatermarks[profile] ?? lastRead,
      },
    {
      'id': 'old',
      'title': 'Old pinned chat',
      'profile': profile,
      'last_active': now - 90000,
      'pinned': true,
    },
  ];
}

class _MeasuredWorkspace extends ProfileWorkspaceController {
  _MeasuredWorkspace({
    required super.access,
    required super.connectionIdentity,
    required super.preferences,
    required super.appPreferences,
    required super.gatewayFactory,
    super.onAttention,
  });

  int recentProjections = 0;

  @override
  List<ProfileRecentChat> recentChats({DateTime? now}) {
    recentProjections++;
    return super.recentChats(now: now);
  }
}

void main() {
  late _RecentsFixture fixture;
  late _MeasuredWorkspace controller;
  late AppPreferences appPreferences;
  late SharedPreferences preferences;

  _MeasuredWorkspace makeController({
    String identity = 'recents',
    Future<void> Function(ProfileNotification)? onAttention,
  }) => _MeasuredWorkspace(
    access: ConnectionAccess(
      connection: identityTestConnection(),
      dashboardOAuth: null,
    ),
    connectionIdentity: identity,
    preferences: preferences,
    appPreferences: appPreferences,
    gatewayFactory: fixture.gateway,
    onAttention: onAttention,
  );

  WorkspaceRecentsSession recentsFor(BotsSession bots) {
    final recents = WorkspaceRecentsSession(controller, bots, foreground: true);
    addTearDown(recents.dispose);
    return recents;
  }

  WorkspaceRecentsSession emptyRecents() {
    final bots = BotsSession((_) async => const []);
    addTearDown(bots.dispose);
    return recentsFor(bots);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    fixture = _RecentsFixture();
    controller = makeController();
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test('Recents retains project identity across session invalidation', () async {
    fixture.recentProject = 'p2';
    await controller.refreshRecents();
    final scope = controller.current!.scope;
    await controller.openSession(ProfileSessionKey(scope, 'shared-id'));
    final recents = emptyRecents();
    await recents.refresh();
    String? projectFor(String id) => recents
        .items()
        .singleWhere((item) => item.chat?.key == ProfileSessionKey(scope, id))
        .chat!
        .project
        ?.name;
    expect(projectFor('shared-id'), 'Mobile app');
    expect(projectFor('recent-0'), 'Mobile app');
    final projectReads = fixture.calls
        .where((call) => call.$2 == 'projects.tree')
        .length;

    controller.current!.gateway.onEvent!(
      StreamEvent(type: 'sessions.changed', sessionId: '', data: const {}),
    );
    // An unrelated publication must not turn invalidated metadata into absence.
    controller.showList();
    await Future<void>.delayed(Duration.zero);
    expect(projectFor('shared-id'), 'Mobile app');
    expect(projectFor('recent-0'), 'Mobile app');
    expect(
      fixture.calls.where((call) => call.$2 == 'projects.tree').length,
      projectReads,
      reason: 'Publishing stale project identity must not start a server read',
    );

    fixture.heldProjects = Completer<void>();
    fixture.projectsStarted = Completer<void>();
    final refresh = recents.refresh(force: true);
    await fixture.projectsStarted!.future;
    expect(projectFor('shared-id'), 'Mobile app');
    expect(projectFor('recent-0'), 'Mobile app');
    fixture.failProjects = true;
    fixture.heldProjects!.complete();
    await refresh;
    fixture.heldProjects = null;
    expect(projectFor('shared-id'), 'Mobile app');
    expect(projectFor('recent-0'), 'Mobile app');

    fixture.failProjects = false;
    fixture.recentProject = 'p3';
    await recents.refresh(force: true);
    expect(projectFor('shared-id'), 'Home lab');
    expect(projectFor('recent-0'), 'Home lab');

    fixture.recentProject = null;
    await recents.refresh(force: true);
    expect(projectFor('shared-id'), isNull);
    expect(projectFor('recent-0'), isNull);
  });

  test('opening a chat rereads invalidated project membership', () async {
    fixture.recentProject = 'p2';
    await controller.refreshRecents();
    final scope = controller.current!.scope;
    int projectReads() =>
        fixture.calls.where((call) => call.$2 == 'projects.tree').length;
    final cachedReads = projectReads();
    final key = ProfileSessionKey(scope, 'shared-id');
    await controller.openSession(key);
    await controller.openSession(key);
    expect(
      projectReads(),
      cachedReads,
      reason: 'Reopening with valid membership reuses the profile cache',
    );
    controller.current!.gateway.onEvent!(
      StreamEvent(type: 'sessions.changed', sessionId: '', data: const {}),
    );
    fixture.recentProject = 'p3';
    final chat = (await controller.openSession(
      ProfileSessionKey(scope, 'shared-id'),
    ))!;
    await Future<void>.delayed(Duration.zero);
    expect(chat.projectId, 'p3');
    expect(controller.chatProjectLabel(chat), 'Home lab');
    expect(
      projectReads(),
      cachedReads + 1,
      reason:
          'An invalidated profile needs one fresh project tree, not per-card reads',
    );
  });

  test(
    'incomplete project membership keeps the known conversation project',
    () async {
      fixture.recentProject = 'p2';
      await controller.refreshRecents();
      final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
      final chat = (await controller.openSession(key))!;
      expect(controller.chatProjectLabel(chat), 'Mobile app');
      // The stock project tree omits some sessions; absence is not unassignment.
      fixture.hiddenChat = true;
      controller.current!.gateway.onEvent!(
        StreamEvent(type: 'sessions.changed', sessionId: '', data: const {}),
      );
      await controller.openSession(key);
      await Future<void>.delayed(Duration.zero);
      expect(chat.projectLookupFailed, isTrue);
      expect(controller.chatProjectLabel(chat), 'Mobile app');
      expect(controller.chatProject(chat)?.id, 'p2');
      fixture.hiddenChat = false;
      fixture.recentProject = null;
      await controller.refreshRecents();
      expect(controller.chatProjectLabel(chat), 'Unassigned');
      expect(chat.projectLookupFailed, isFalse);
    },
  );

  for (final hidden in [false, true]) {
    test(
      'live answer updates ${hidden ? 'hidden Bot Chat' : 'ordinary chat'} unread before Recents polling',
      () async {
        fixture.hiddenChat = hidden;
        if (hidden) {
          fixture.hiddenSessions['personal'] = [
            {
              'id': 'shared-id',
              'title': 'Bot Chat',
              'profile': 'personal',
              'source': 'desktop',
              'hidden': true,
              'last_active': fixture.now - 600,
              'unread': false,
              'last_read_at': fixture.now - 300,
            },
          ];
        }
        fixture.lastRead = fixture.now - 300;
        final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
        final chat = (await controller.openSession(key))!;
        final gateway = controller.current!.gateway;
        final recents = emptyRecents();
        await recents.refresh();
        expect(
          recents.items().singleWhere((item) => item.chat?.key == key).unread,
          isFalse,
        );
        controller.setRouteVisibility(controller, false);
        fixture.messageRows[('personal', 'shared-id')] = [
          {
            'id': 2,
            'role': 'assistant',
            'content': 'New live answer',
            'timestamp': fixture.now,
          },
        ];
        gateway.onEvent!(
          StreamEvent(
            type: 'message.start',
            sessionId: chat.runtime.runtimeId,
            data: stockChatReply(gateway, 'message.start', {}),
          ),
        );
        gateway.onEvent!(
          StreamEvent(
            type: 'message.complete',
            sessionId: chat.runtime.runtimeId,
            data: {'text': 'New live answer'},
          ),
        );
        for (var tick = 0; tick < 30; tick++) {
          await Future<void>.delayed(Duration.zero);
        }
        final item = recents.items().singleWhere(
          (item) => item.chat?.key == key,
        );
        expect(item.messagePreview, 'New live answer');
        expect(
          item.unread,
          isTrue,
          reason:
              'A delivered answer must update cached Recents without waiting for its periodic list read',
        );
        expect(
          recents.catalog.entries
              .singleWhere((entry) => entry.key.chat == key)
              .unread,
          isTrue,
        );
        expect(fixture.readWrites, 0);
        await controller.openSession(key);
        expect(fixture.readWrites, 0);
        controller.setRouteVisibility(controller, true);
        chat.reading.recordReading(null, readThrough: 2);
        await controller.acknowledgeVisibleReading(chat, 2);
        await Future<void>.delayed(Duration.zero);
        expect(fixture.readWrites, 1);
        expect(
          recents.items().singleWhere((item) => item.chat?.key == key).unread,
          isFalse,
          reason:
              'An explicit successful open must acknowledge the event-driven answer',
        );
      },
    );
  }

  for (final failure in [false, true]) {
    test(
      'newer answer survives a held read acknowledgement failure=$failure',
      () async {
        fixture.lastRead = fixture.now - 300;
        final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
        final chat = (await controller.openSession(key))!;
        final recents = emptyRecents();
        await recents.refresh();
        fixture.messageRows[('personal', 'shared-id')] = [
          {
            'id': 2,
            'role': 'assistant',
            'content': 'First incoming answer',
            'timestamp': fixture.now,
          },
        ];
        await controller.refreshHistory(chat);
        await Future<void>.delayed(Duration.zero);
        expect(
          recents.items().singleWhere((item) => item.chat?.key == key).unread,
          isTrue,
        );
        fixture.heldRead = Completer<void>();
        fixture.failRead = failure;
        final reading = controller.mutateSession(
          key,
          changes: const {'unread': false},
          canDispatch: () => true,
        );
        final result = expectLater(
          reading,
          failure ? throwsStateError : completes,
        );
        await Future<void>.delayed(Duration.zero);
        fixture.messageRows[('personal', 'shared-id')] = [
          ...fixture.messageRows[('personal', 'shared-id')]!,
          {
            'id': 3,
            'role': 'assistant',
            'content': 'Newer incoming answer',
            'timestamp': fixture.now + 1,
          },
        ];
        await controller.refreshHistory(chat);
        fixture.heldRead!.complete();
        await result;
        await Future<void>.delayed(Duration.zero);
        expect(
          recents.items().singleWhere((item) => item.chat?.key == key).unread,
          isTrue,
          reason: 'A receipt only covers the history captured before dispatch',
        );
        expect(
          recents
              .items()
              .singleWhere((item) => item.chat?.key == key)
              .messagePreview,
          'Newer incoming answer',
        );
        expect(fixture.readWrites, failure ? 0 : 1);
      },
    );
  }

  test(
    'valid read watermark overrides stale read list flag during reconciliation',
    () async {
      fixture.lastRead = fixture.now - 300;
      final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
      final chat = (await controller.openSession(key))!;
      final recents = emptyRecents();
      await recents.refresh();
      fixture.messageRows[('personal', 'shared-id')] = [
        {
          'id': 2,
          'role': 'assistant',
          'content': 'Answer after the metadata snapshot',
          'timestamp': fixture.now,
        },
      ];
      await controller.refreshHistory(chat);
      await Future<void>.delayed(Duration.zero);
      expect(
        recents.items().singleWhere((item) => item.chat?.key == key).unread,
        isTrue,
      );
      await recents.refresh(force: true);
      expect(
        recents.items().singleWhere((item) => item.chat?.key == key).unread,
        isTrue,
        reason:
            'Metadata and history reads are not an atomic snapshot; compare the answer to last_read_at',
      );
      expect(fixture.readWrites, 0);
    },
  );

  test(
    'first live answer enters Recents unread without a previous message observation',
    () async {
      final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
      fixture.messageRows[('personal', 'shared-id')] = [];
      final chat = (await controller.openSession(key))!;
      final recents = emptyRecents();
      await recents.refresh();
      expect(recents.items().any((item) => item.chat?.key == key), isFalse);
      controller.setRouteVisibility(controller, false);
      final release = fixture.historyDelays[('shared-id', 0)] =
          Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final gateway = controller.current!.gateway;
      gateway.onEvent!(
        StreamEvent(
          type: 'message.start',
          sessionId: chat.runtime.runtimeId,
          data: stockChatReply(gateway, 'message.start', {}),
        ),
      );
      gateway.onEvent!(
        StreamEvent(
          type: 'message.complete',
          sessionId: chat.runtime.runtimeId,
          data: {
            'text': 'First incoming answer',
            'mobile_push_event_id': 'first-answer',
          },
        ),
      );
      for (var tick = 0; tick < 20; tick++) {
        await Future<void>.delayed(Duration.zero);
      }
      final item = recents.items().singleWhere((item) => item.chat?.key == key);
      expect(item.messagePreview, 'First incoming answer');
      expect(
        item.unread,
        isTrue,
        reason:
            'The first answer has no older saved-message baseline to compare',
      );
      expect(fixture.readWrites, 0);
      fixture.unread = true;
      fixture.messageRows[('personal', 'shared-id')] = [
        {
          'id': 1,
          'role': 'assistant',
          'content': 'First incoming answer',
          'timestamp': fixture.now,
        },
      ];
      release.complete();
    },
  );

  test(
    'live answer cue publishes before held completion history enrichment',
    () async {
      final notices = <ProfileNotification>[];
      controller.dispose();
      controller = makeController(
        onAttention: (notice) async => notices.add(notice),
      );
      await controller.initialize();
      fixture.lastRead = fixture.now - 300;
      final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
      final chat = (await controller.openSession(key))!;
      final recents = emptyRecents();
      await recents.refresh();
      controller.setRouteVisibility(controller, false);
      final history = fixture.historyDelays[('shared-id', 0)] =
          Completer<void>();
      addTearDown(() {
        if (!history.isCompleted) history.complete();
      });
      final gateway = controller.current!.gateway;
      gateway.onEvent!(
        StreamEvent(
          type: 'message.start',
          sessionId: chat.runtime.runtimeId,
          data: stockChatReply(gateway, 'message.start', {}),
        ),
      );
      gateway.onEvent!(
        StreamEvent(
          type: 'message.complete',
          sessionId: chat.runtime.runtimeId,
          data: {
            'text': 'Delivered reply before history',
            'mobile_push_event_id': 'held-history-answer',
          },
        ),
      );
      for (var tick = 0; tick < 20; tick++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(chat.reading.historyLoading, isTrue);
      expect(
        recents.items().singleWhere((item) => item.chat?.key == key).unread,
        isTrue,
      );
      expect(
        notices,
        hasLength(1),
        reason: 'The fresh answer cue must not wait for passive enrichment',
      );
      expect(notices.single.focus!.identity, 'answer:held-history-answer');
      history.complete();
    },
  );

  for (final failed in [false, true]) {
    test(
      'viewed current live answer clears Recents through confirmed read acknowledgement failure=$failed',
      () async {
        fixture.lastRead = fixture.now - 300;
        final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
        final chat = (await controller.openSession(key))!;
        final recents = emptyRecents();
        await recents.refresh();
        fixture.messageRows[('personal', 'shared-id')] = [
          {
            'id': 2,
            'role': 'assistant',
            'content': 'Reply viewed in the current chat',
            'timestamp': fixture.now,
          },
        ];
        final gateway = controller.current!.gateway;
        gateway.onEvent!(
          StreamEvent(
            type: 'message.start',
            sessionId: chat.runtime.runtimeId,
            data: stockChatReply(gateway, 'message.start', {}),
          ),
        );
        gateway.onEvent!(
          StreamEvent(
            type: 'message.complete',
            sessionId: chat.runtime.runtimeId,
            data: {
              'text': 'Reply viewed in the current chat',
              'mobile_push_event_id': 'current-answer',
            },
          ),
        );
        for (var tick = 0; tick < 30; tick++) {
          await Future<void>.delayed(Duration.zero);
        }
        controller.setRouteVisibility(controller, true);
        fixture.failRead = failed;
        final target = chat.reading.notificationReadTarget!;
        controller.notificationAnswerRead(chat, target);
        chat.reading.recordReading(null, readThrough: 2);
        await controller.acknowledgeVisibleReading(chat, 2);
        for (var tick = 0; tick < 20; tick++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(fixture.readWrites, failed ? 0 : 1);
        expect(chat.markReadFailed, failed);
        if (failed) {
          expect(
            recents.items().singleWhere((item) => item.chat?.key == key).unread,
            isTrue,
          );
          fixture.failRead = false;
          await controller.openSession(key);
          await controller.acknowledgeVisibleReading(chat, 2);
          await Future<void>.delayed(Duration.zero);
          expect(fixture.readWrites, 1);
          expect(chat.markReadFailed, isFalse);
        }
        expect(
          recents.items().singleWhere((item) => item.chat?.key == key).unread,
          isFalse,
          reason:
              'Returning to Recents must not claim an already viewed live answer is new',
        );
        await recents.refresh(force: true);
        expect(
          recents.items().singleWhere((item) => item.chat?.key == key).unread,
          isFalse,
          reason: 'Confirmed reading stays read through reconciliation',
        );
      },
    );
  }

  for (final text in ['', '   ']) {
    test(
      'empty completion cannot manufacture an answer cue (length=${text.length})',
      () async {
        final notices = <ProfileNotification>[];
        controller.dispose();
        controller = makeController(
          onAttention: (notice) async => notices.add(notice),
        );
        await controller.initialize();
        fixture.lastRead = fixture.now - 300;
        final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
        final chat = (await controller.openSession(key))!;
        final recents = emptyRecents();
        await recents.refresh();
        controller.setRouteVisibility(controller, false);
        final gateway = controller.current!.gateway;
        gateway.onEvent!(
          StreamEvent(
            type: 'message.start',
            sessionId: chat.runtime.runtimeId,
            data: stockChatReply(gateway, 'message.start', {}),
          ),
        );
        gateway.onEvent!(
          StreamEvent(
            type: 'message.complete',
            sessionId: chat.runtime.runtimeId,
            data: {'text': text},
          ),
        );
        for (var tick = 0; tick < 30; tick++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(notices, hasLength(1));
        expect(notices.single.focus!.kind, 'status');
        expect(
          recents.items().singleWhere((item) => item.chat?.key == key).unread,
          isFalse,
        );
        expect(fixture.readWrites, 0);
      },
    );
  }

  test('message excerpts keep the start of the latest visible message', () {
    expect(
      recentChatMessagePreview([
        {'role': 'user', 'content': 'First prompt.'},
        {
          'role': 'assistant',
          'content': '**First sentence.** Second sentence.',
        },
        {'role': 'tool', 'content': 'Private tool output'},
        {
          'role': 'user',
          'display_kind': 'hidden',
          'content': 'Model-only context',
        },
      ]),
      'First sentence. Second sentence.',
    );
    expect(
      recentChatMessagePreview([
        {'role': 'assistant', 'content': 'Old reply'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Latest question?'},
          ],
        },
      ]),
      'Latest question?',
    );
    expect(
      recentMessageExcerpt('```python\nprint("hello")\n```'),
      'print("hello")',
    );
    expect(
      recentChatMessagePreview([
        {'role': 'tool', 'content': 'Output'},
      ]),
      isNull,
    );
  });

  for (final fromRecents in [false, true]) {
    testWidgets(
      'group origin admits cues only after Recents activation (fromRecents=$fromRecents)',
      (tester) async {
        final host = BotsFixture();
        host.events.add({
          'room_id': 'room-1',
          'seq': 1,
          'kind': 'message.member',
          'created_at': fixture.now,
          'actor': {'kind': 'member', 'id': 'atlas'},
          'payload': {'text': 'A recent group answer'},
        });
        final bots = BotsSession((_) async => [host.repository]);
        addTearDown(bots.dispose);
        final recents = recentsFor(bots);
        await recents.refresh();
        final group = bots.observedGroups.single;
        final origin = RecentConversationKey.group(group.key);
        final target = recents.catalog.entries
            .firstWhere((entry) => entry.key.chat != null)
            .key;
        final activity = ValueNotifier<ChatNoticeActivity?>(null);
        addTearDown(activity.dispose);
        var subscriptions = 0;
        final visit = controller.groupRecentConversationSession(
          group: group,
          fromRecents: fromRecents,
          recents: recents,
          onOpenGroup: (_) async {},
          onOpenChat: (_) async {},
          activity: () {
            subscriptions++;
            return activity;
          },
        );
        addTearDown(visit.dispose);
        expect(visit.modeEnabled, fromRecents);
        expect(subscriptions, fromRecents ? 1 : 0);
        visit.setInteractive(true, origin: origin);
        activity.value = ChatNoticeActivity(
          key: target,
          kind: ConversationActivityKind.reply,
          identity: 'group-origin-answer-1',
          sequence: 1,
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(visit.nudges.value?.key, fromRecents ? target : null);
        if (!fromRecents) {
          await visit.activate();
          visit.setInteractive(true, origin: origin);
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            visit.nudges.value,
            isNull,
            reason: 'Activation cannot replay the earlier arrival',
          );
          activity.value = ChatNoticeActivity(
            key: target,
            kind: ConversationActivityKind.reply,
            identity: 'group-origin-answer-2',
            sequence: 2,
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(visit.nudges.value?.key, target);
          expect(subscriptions, 1);
        }
        visit.setVisible(false);
        expect(fixture.readWrites, 0);
      },
    );
  }

  test(
    'Recents message previews share freshness reads and cached reopening',
    () async {
      fixture.messageRows[('personal', 'shared-id')] = [
        {
          'id': 1,
          'role': 'assistant',
          'content': 'First sentence. Latest answer.',
          'timestamp': fixture.now - 600,
        },
      ];
      fixture.messageRows[('work', 'shared-id')] = [
        {
          'id': 2,
          'role': 'user',
          'content': 'Work question?',
          'timestamp': fixture.now - 600,
        },
      ];
      final recents = emptyRecents();
      await recents.refresh();
      final items = recents.items();
      expect(
        items
            .singleWhere((i) => i.chat?.key.workspace.profileName == 'work')
            .messagePreview,
        'Work question?',
      );
      final personal = items.singleWhere(
        (i) =>
            i.chat?.key.workspace.profileName == 'personal' &&
            i.chat?.key.sessionId == 'shared-id',
      );
      expect(personal.messagePreview, 'First sentence. Latest answer.');
      final reads = fixture.reads
          .where((r) => r.$1.endsWith('/messages'))
          .length;
      await recents.refresh();
      expect(recents.items(), same(items));
      expect(
        fixture.reads.where((r) => r.$1.endsWith('/messages')).length,
        reads,
      );
      expect(
        fixture.reads
            .where((r) => r.$1 == 'sessions/shared-id/messages')
            .length,
        2,
      );
      expect(
        fixture.reads
            .where((r) => r.$1.endsWith('/messages'))
            .every((r) => r.$2['inline_images'] == 'false'),
        isTrue,
      );
      expect(fixture.readWrites, 0);
      // A retained transcript with this timestamp must not overwrite a newer
      // REST message body when an edit keeps the original timestamp.
      await controller.openSession(personal.chat!.key);
      fixture.failHistory = true;
      await recents.refresh(force: true);
      expect(
        recents
            .items()
            .singleWhere((i) => i.identity == personal.identity)
            .messagePreview,
        'First sentence. Latest answer.',
      );
      expect(recents.catalog.error, isNotNull);
      fixture.failHistory = false;
      fixture.messageRows[('personal', 'shared-id')] = [
        {
          'id': 3,
          'role': 'assistant',
          'content': 'A revised answer with the same timestamp.',
          'timestamp': fixture.now - 600,
        },
      ];
      await recents.refresh(force: true);
      expect(
        recents
            .items()
            .singleWhere((i) => i.identity == personal.identity)
            .messagePreview,
        'A revised answer with the same timestamp.',
      );
    },
  );

  test(
    'tool-tail paging finds the last chat message without changing freshness',
    () async {
      fixture.messageRows[('personal', 'shared-id')] = [
        {
          'id': 1,
          'role': 'assistant',
          'content': 'Latest visible answer.',
          'timestamp': fixture.now - 900,
        },
        for (var id = 2; id <= 25; id++)
          {
            'id': id,
            'role': 'tool',
            'content': 'Tool output',
            'timestamp': fixture.now - 600,
          },
      ];
      await controller.refreshRecents();
      final item = controller.recentChats().singleWhere(
        (i) =>
            i.key.workspace.profileName == 'personal' &&
            i.key.sessionId == 'shared-id',
      );
      expect(item.messagePreview, 'Latest visible answer.');
      expect(item.lastActive, fixture.now - 600);
      final offsets = fixture.reads
          .where(
            (r) =>
                r.$1 == 'sessions/shared-id/messages' &&
                r.$2['profile'] == 'personal',
          )
          .map((r) => int.parse(r.$2['offset']!))
          .toList();
      expect(offsets.first, 0);
      expect(offsets.any((offset) => offset > 0), isTrue);
      expect(offsets.toSet(), hasLength(offsets.length));
      expect(offsets, orderedEquals([...offsets]..sort()));
    },
  );

  test(
    'runtime heartbeats do not outrank newer messages or invent an age',
    () async {
      fixture.hiddenSessions['personal'] = [
        {
          'id': 'active-empty',
          'title': 'Empty active chat',
          'profile': 'personal',
        },
      ];
      fixture.liveSessions['personal'] = [
        {
          'id': 'busy-runtime',
          'session_key': 'recent-100',
          'status': 'working',
          'last_active': fixture.now + 1000,
        },
        {
          'id': 'empty-runtime',
          'session_key': 'active-empty',
          'status': 'working',
          'last_active': fixture.now + 2000,
        },
      ];
      await controller.refreshRecents();
      final chats = controller.recentChats();
      expect(chats.first.key.sessionId, 'recent-0');
      expect(chats.first.state, isNull);
      final busy = chats.singleWhere(
        (c) =>
            c.key.workspace.profileName == 'personal' &&
            c.key.sessionId == 'recent-100',
      );
      expect(busy.activity, isNotNull);
      expect(busy.lastActive, fixture.now - 6000);
      final empty = chats.singleWhere((c) => c.key.sessionId == 'active-empty');
      expect(empty.lastActive, 0);
      expect(chats.last.key, empty.key);
    },
  );

  for (final hidden in [false, true]) {
    test('tool activity has no new answer, hidden=$hidden', () async {
      final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
      fixture.messageRows[('personal', 'shared-id')] = [
        {
          'id': 1,
          'role': 'assistant',
          'content': 'Read answer',
          'timestamp': fixture.now - 200,
        },
        {
          'id': 2,
          'role': 'user',
          'content': 'Next prompt',
          'timestamp': fixture.now - 80,
        },
        {
          'id': 3,
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call',
              'type': 'function',
              'function': {'name': 'read_file', 'arguments': '{}'},
            },
          ],
          'timestamp': fixture.now - 40,
        },
        {
          'id': 4,
          'role': 'tool',
          'content': 'File contents',
          'timestamp': fixture.now - 30,
        },
      ];
      if (hidden) {
        await controller.refreshRecents();
        await controller.openSession(key);
      }
      fixture.unread = true;
      fixture.lastRead = fixture.now - 100;
      if (hidden) {
        fixture.hiddenChat = true;
        fixture.hiddenSessions['personal'] = [
          {
            'id': 'shared-id',
            'title': 'Bot Chat',
            'profile': 'personal',
            'source': 'desktop',
            'hidden': 1,
            'last_read_at': fixture.lastRead,
            'last_active': fixture.now - 30,
          },
        ];
      }
      final writes = fixture.readWrites;
      await controller.refreshRecents();
      expect(controller.recentsProfileErrors, isEmpty);
      final recent = controller.recentChats().singleWhere(
        (chat) => chat.key == key,
      );
      expect(recent.messagePreview, 'Next prompt');
      expect(
        recent.unread,
        isFalse,
        reason: 'Tools and outgoing prompts are not new answers',
      );
      expect(fixture.readWrites, writes);

      // A newer prompt/tool tail must not hide a real answer still to read.
      final messages = fixture.messageRows[('personal', 'shared-id')]!;
      messages.insert(1, {
        'id': 5,
        'role': 'assistant',
        'content': 'Unread answer',
        'timestamp': fixture.now - 90,
      });
      messages.addAll([
        for (var i = 0; i < 25; i++)
          {
            'id': 6 + i,
            'role': 'tool',
            'content': 'More activity',
            'timestamp': fixture.now - 20 + i / 100,
          },
      ]);
      await controller.refreshRecents();
      expect(controller.recentsProfileErrors, isEmpty);
      final withAnswer = controller.recentChats().singleWhere(
        (chat) => chat.key == key,
      );
      expect(withAnswer.unread, isTrue);
      expect(withAnswer.messagePreview, 'Next prompt');
      expect(fixture.readWrites, writes);

      fixture.lastRead = fixture.now - 85;
      if (hidden) {
        fixture.hiddenSessions['personal']!.single['last_read_at'] =
            fixture.lastRead;
      }
      await controller.refreshRecents();
      expect(
        controller.recentChats().singleWhere((chat) => chat.key == key).unread,
        isFalse,
        reason: 'Later tools must not make a read answer unread again',
      );
      expect(fixture.readWrites, writes);
    });
  }

  test('technical assistant rows do not count as new answers', () async {
    fixture.unread = true;
    fixture.lastRead = fixture.now - 100;
    fixture.messageRows[('personal', 'shared-id')] = [
      {
        'id': 1,
        'role': 'user',
        'content': 'First prompt',
        'timestamp': fixture.now - 80,
      },
      {
        'id': 2,
        'role': 'assistant',
        'content': 'Checking a file',
        'tool_calls': [
          {
            'id': 'call',
            'type': 'function',
            'function': {'name': 'read_file', 'arguments': '{}'},
          },
        ],
        'timestamp': fixture.now - 50,
      },
      {
        'id': 3,
        'role': 'assistant',
        'content': 'Private model context',
        'display_kind': 'hidden',
        'timestamp': fixture.now - 40,
      },
      {
        'id': 4,
        'role': 'assistant',
        'content': '',
        'reasoning': 'Internal reasoning',
        'timestamp': fixture.now - 30,
      },
    ];
    await controller.refreshRecents();
    expect(controller.recentsProfileErrors, isEmpty);
    expect(
      controller
          .recentChats()
          .singleWhere(
            (chat) =>
                chat.key.sessionId == 'shared-id' &&
                chat.key.workspace.profileName == 'personal',
          )
          .unread,
      isFalse,
    );
    expect(fixture.readWrites, 0);
  });

  test(
    'confirmed reading clears unread without advancing message freshness',
    () async {
      fixture.unread = true;
      await controller.refreshRecents();
      final before = controller.recentChats().singleWhere(
        (c) =>
            c.key.workspace.profileName == 'personal' &&
            c.key.sessionId == 'shared-id',
      );
      expect(before.unread, isTrue);
      final chat = (await controller.openSession(before.key))!;
      expect(fixture.readWrites, 0);
      controller.setRouteVisibility(controller, true);
      chat.reading.recordReading(null, readThrough: 1);
      await controller.acknowledgeVisibleReading(chat, 1);
      final after = controller.recentChats().singleWhere(
        (c) => c.key == before.key,
      );
      expect(after.unread, isFalse);
      expect(after.lastActive, before.lastActive);
      final position = chat.reading.readingPosition;
      // Stock Mark as unread resets its timestamp, not Wing's message marker.
      fixture.unread = true;
      fixture.lastRead = 0;
      fixture.readWatermarks.clear();
      await controller.refreshRecents();
      expect(
        controller.recentChats().singleWhere((c) => c.key == before.key).unread,
        isTrue,
      );
      expect(identical(chat.reading.readingPosition, position), isTrue);
    },
  );

  for (final tracked in [true, false]) {
    test(
      'hidden bot reply stays unread before opening, tracked=$tracked',
      () async {
        await controller.refreshRecents();
        final key = controller
            .recentChats()
            .singleWhere(
              (c) =>
                  c.key.workspace.profileName == 'personal' &&
                  c.key.sessionId == 'shared-id',
            )
            .key;
        await controller.openSession(key);
        fixture.hiddenChat = true;
        fixture.hiddenSessions['personal'] = [
          {
            'id': 'shared-id',
            'title': 'Bot Chat',
            'profile': 'personal',
            'source': 'desktop',
            'hidden': 1,
            'last_read_at': tracked ? fixture.now - 300 : null,
            'last_activity_at': fixture.now - 30,
            'last_active': fixture.now - 30,
          },
        ];

        final writes = fixture.readWrites;
        await controller.refreshRecents();
        final before = controller.recentChats().singleWhere(
          (c) => c.key == key,
        );
        expect(
          before.unread,
          isTrue,
          reason: 'A hidden chat omitted from the list is not proof of reading',
        );
        expect(
          fixture.readWrites,
          writes,
          reason: 'Passive refresh must not change server read state',
        );
        fixture.failHiddenMetadata = true;
        await controller.refreshRecents();
        expect(controller.recentsProfileErrors, contains('personal'));
        expect(
          controller.recentChats().singleWhere((c) => c.key == key).unread,
          isTrue,
        );
        fixture.failHiddenMetadata = false;
        await controller.refreshRecents();
        expect(controller.recentsProfileErrors, isNot(contains('personal')));
        expect(fixture.readWrites, writes);
        final chat = (await controller.openSession(key))!;
        expect(fixture.readWrites, writes);
        controller.setRouteVisibility(controller, true);
        chat.reading.recordReading(null, readThrough: 1);
        await controller.acknowledgeVisibleReading(chat, 1);
        expect(fixture.readWrites, writes + 1);
        expect(
          controller.recentChats().singleWhere((c) => c.key == key).unread,
          isFalse,
        );
        await controller.refreshRecents();
        expect(
          controller.recentChats().singleWhere((c) => c.key == key).unread,
          isFalse,
        );
      },
    );
  }

  test('group workers stay out of saved, opened and active Recents', () async {
    await controller.setSessionVisibility(SessionVisibility.all);
    await controller.refreshRecents();
    expect(
      controller.recentChats().any(
        (item) => item.key.sessionId == 'room-worker',
      ),
      isFalse,
    );
    expect(
      fixture.reads.any((read) => read.$1 == 'sessions/room-worker/messages'),
      isFalse,
    );
    final key = ProfileSessionKey(controller.current!.scope, 'room-worker');
    final chat = await controller.openSession(key);
    expect(chat?.source, 'bot_room');
    fixture.liveSessions[key.workspace.profileName] = [
      {
        'id': 'worker-runtime',
        'session_key': 'room-worker',
        'status': 'working',
      },
    ];
    await controller.refreshActivity();
    expect(
      controller.liveActivity.any((item) => item.sessionId == 'room-worker'),
      isTrue,
    );
    expect(
      controller.recentChats().any(
        (item) => item.key.sessionId == 'room-worker',
      ),
      isFalse,
    );
  });

  test(
    'cold passive canonical appearance loads before opening its chat',
    () async {
      await controller.refreshRecents();
      final keys = controller.recentChats().map((chat) => chat.key).toList();
      final target = keys.first;
      var now = DateTime.now();
      final botFixture = BotsFixture();
      final row = BotsFixture.profile(
        target.workspace.profileName,
        'Canonical assistant',
      );
      row['canonical_session'] = {
        'id': target.sessionId,
        'resolved_id': '${target.sessionId}-tip',
      };
      botFixture.profiles
        ..clear()
        ..add(row);
      final bots = BotsSession(
        (_) async => [
          BotsRepository(
            groupObservations: GroupObservations(controller.current!.scope),
            scope: controller.current!.scope,
            instance: 'Host',
            read: botFixture.read,

            command: (_, _, _, _, _) async => throw StateError('Passive only'),
            ownership: (_, _) async => throw StateError('No runtime reads'),
          ),
        ],
        now: () => now,
      );
      addTearDown(bots.dispose);
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      addTearDown(activity.dispose);
      final visit = controller.recentConversationSession(
        onOpenGroup: (_) async {},
        entries: [
          for (final key in keys)
            RecentConversationEntry.chat(
              key: key,
              title: 'Saved title',
              unread: false,
            ),
        ],
        recents: recentsFor(bots),
        activity: activity,
      );
      addTearDown(visit.dispose);
      final calls = fixture.calls.length;
      visit.prepare(keys.take(3).map(RecentConversationKey.chat));
      await Future<void>.delayed(Duration.zero);
      expect(visit.cardAt(0).bot!.title, 'Canonical assistant');
      expect(visit.cardAt(0).bot!.describesConversation(target), isTrue);
      expect(fixture.calls.length, calls);
      expect(botFixture.commands, isEmpty);
      final reading = visit.cardAt(0).preview;
      final revision = visit.previewRevision(
            RecentConversationKey.chat(target),
          ),
          pixels = visit.cardRevision(RecentConversationKey.chat(target));
      row['ui_meta'] = {
        'hermes-bots': {'title': 'Renamed assistant'},
      };
      row['ui_meta_revisions'] = {'hermes-bots': 3};
      now = now.add(const Duration(seconds: 30));
      await bots.refresh();
      expect(
        visit.previewRevision(RecentConversationKey.chat(target)),
        revision,
      );
      expect(
        visit.cardRevision(RecentConversationKey.chat(target)),
        isNot(pixels),
      );
      expect(visit.cardAt(0).preview, same(reading));
      expect(visit.cardAt(0).bot!.title, 'Renamed assistant');
    },
  );

  test(
    'entry catalog anchors an old draft without changing recency or reopening',
    () async {
      await controller.refreshRecents();
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'old'),
      );
      final chat = controller.current!.chat!;
      await controller.updateDraft(chat, 'Unsent work');
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      final visit = controller.chatRecentConversationSession(
        onOpenGroup: (_) async {},
        recents: emptyRecents(),
        chat: chat,
        activity: () => activity,
      );
      addTearDown(visit.dispose);
      addTearDown(activity.dispose);
      final resumes = fixture.calls
          .where((call) => call.$2 == 'session.resume')
          .length;
      expect(visit.modeEnabled, isFalse);
      expect(visit.selected, RecentConversationKey.chat(chat.key));
      visit.activate();
      await Future<void>.delayed(Duration.zero);
      expect(visit.entries.last.key, RecentConversationKey.chat(chat.key));
      expect(
        visit.entries.where((entry) => entry.key.chat == chat.key),
        hasLength(1),
      );
      expect(
        visit.entries.any(
          (entry) => entry.key.chat!.workspace.profileName == 'work',
        ),
        isTrue,
      );
      expect(
        controller.recentChats().any((item) => item.key == chat.key),
        isFalse,
      );
      expect(chat.composer.observation.displayedText, 'Unsent work');
      expect(
        fixture.calls.where((call) => call.$2 == 'session.resume'),
        hasLength(resumes),
      );
    },
  );

  test(
    'Recents reveals cached reading without a loaded profile browser',
    () async {
      final scope = WorkspaceScope(
        connectionId: controller.connection.id,
        connectionIdentity: controller.connectionIdentity,
        profileName: 'work',
      );
      final key = ProfileSessionKey(scope, 'shared-id');
      await controller.openSession(key);
      final cached = controller.current!.chat!;
      expect(controller.current!.loaded, isFalse);
      await controller.openSession(
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: controller.connection.id,
            connectionIdentity: controller.connectionIdentity,
            profileName: 'personal',
          ),
          'shared-id',
        ),
      );
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      addTearDown(activity.dispose);
      final visit = controller.recentConversationSession(
        recents: emptyRecents(),
        entries: [
          RecentConversationEntry.chat(key: key, title: 'Work', unread: false),
        ],
        onOpenGroup: (_) async {},
        activity: activity,
      );
      addTearDown(visit.dispose);
      final held = fixture.heldResume = Completer<void>();
      fixture.resumeStarted = Completer<void>();
      var revealed = false;
      final open = visit
          .select(RecentConversationKey.chat(key))
          .then((value) => revealed = value);
      await fixture.resumeStarted!.future;
      await Future<void>.delayed(Duration.zero);
      try {
        expect(revealed, isTrue);
        expect(controller.current!.chat, same(cached));
        expect(cached.reading.messages.single['content'], 'Saved reply');
      } finally {
        held.complete();
        await open;
      }
    },
  );

  test('Recents reuses its cached list between observations', () async {
    await controller.refreshRecents();
    final bots = BotsSession((_) async => [BotsFixture().repository]);
    final recents = WorkspaceRecentsSession(controller, bots, foreground: true);
    addTearDown(recents.dispose);
    addTearDown(bots.dispose);
    final items = recents.items();
    expect(items, isNotEmpty);
    expect(identical(recents.items(), items), isTrue);
  });

  test(
    'cached Recents openings share one background refresh and visibility lease',
    () async {
      final fixture = BotsFixture();
      var groupReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.list') groupReads++;
        return null;
      };
      final bots = BotsSession((_) async => [fixture.repository]);
      final recents = recentsFor(bots);
      addTearDown(bots.dispose);
      final held = Completer<void>(), started = Completer<void>();
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.list') {
          groupReads++;
          if (!started.isCompleted) started.complete();
          await held.future;
        }
        return null;
      };
      final first = recents.refresh();
      await started.future;
      final second = recents.refresh(force: true);
      expect(identical(first, second), isTrue);
      expect(groupReads, 1);
      held.complete();
      await first;
      final catalog = recents.catalog;
      final items = recents.items();
      final reader = Object(), other = Object();
      recents.setVisible(reader, true);
      recents.setVisible(other, true);
      await recents.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(groupReads, 1);
      expect(identical(recents.catalog, catalog), isTrue);
      expect(identical(recents.items(), items), isTrue);
      recents.setVisible(reader, false);
      recents.setVisible(other, false);
      await recents.refresh(force: true);
      expect(groupReads, 1, reason: 'Fresh group catalog is reused');
    },
  );

  testWidgets(
    'visible borrowing defers refresh and cancels admission if hidden immediately',
    (tester) async {
      final fixture = BotsFixture();
      var groupReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.list') groupReads++;
        return null;
      };
      final bots = BotsSession((_) async => [fixture.repository]);
      final recents = recentsFor(bots);
      addTearDown(bots.dispose);
      final reader = Object();
      recents.setVisible(reader, true);
      expect(controller.recentsLoading, isFalse);
      recents.setVisible(reader, false);
      await tester.pump();
      expect(groupReads, 0);
      recents.setVisible(reader, true);
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
        await recents.refresh();
      });
      expect(groupReads, 1);
      recents.setVisible(reader, false);
    },
  );

  testWidgets(
    'Recents polls while any reader is visible and stops when hidden',
    (tester) async {
      final fixture = BotsFixture();
      var now = DateTime.now();
      var groupReads = 0, statusReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.list') groupReads++;
        if (method == 'profiles.list') statusReads++;
        return null;
      };
      final bots = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      final recents = recentsFor(bots);
      addTearDown(bots.dispose);
      await recents.refresh();
      final reader = Object(), other = Object();
      recents.setVisible(reader, true);
      recents.setVisible(other, true);
      await tester.pump();
      expect(groupReads, 1);
      recents.setVisible(reader, false);
      now = now.add(WorkspaceRecentsSession.refreshInterval);
      await tester.pump(WorkspaceRecentsSession.refreshInterval);
      await tester.pump();
      expect(groupReads, 1);
      expect(statusReads, 2);
      recents.setVisible(other, false);
      now = now.add(WorkspaceRecentsSession.refreshInterval);
      await tester.pump(WorkspaceRecentsSession.refreshInterval);
      expect(groupReads, 1);
      expect(statusReads, 2);
    },
  );

  test('unchanged retained history is summarized once for Recents', () async {
    final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
    final chat = (await controller.openSession(key))!;
    void history(String content) => chat.reading.installSavedHistory([
      {
        'id': 1,
        'role': 'assistant',
        'content': content,
        'timestamp': fixture.now,
      },
    ]);
    history('Original **answer**');
    CompletionDiagnostics.reset();
    int summaries() {
      final totals = CompletionDiagnostics.snapshot()['totals'];
      if (totals is! Map) return 0;
      final summary = totals['recents.reading_summary'];
      return summary is Map ? summary['count'] as int : 0;
    }

    for (var i = 0; i < 100; i++) {
      final item = controller.recentChats().singleWhere(
        (row) => row.key == key,
      );
      expect(item.messagePreview, 'Original answer');
    }
    expect(summaries(), CompletionDiagnostics.enabled ? 1 : 0);
    // Editing the same message ID and timestamp must replace its cached text.
    history('Revised **answer**');
    expect(
      controller
          .recentChats()
          .singleWhere((row) => row.key == key)
          .messagePreview,
      'Revised answer',
    );
    expect(summaries(), CompletionDiagnostics.enabled ? 2 : 0);
    history('');
    expect(
      controller
          .recentChats()
          .singleWhere((row) => row.key == key)
          .messagePreview,
      '',
    );
    expect(summaries(), CompletionDiagnostics.enabled ? 3 : 0);
  });

  test(
    'paused Recents skips retained-history projections and catches up on resume',
    () async {
      fixture.messageRows[('personal', 'shared-id')] = [
        {
          'id': 1,
          'role': 'assistant',
          'content': 'Saved **answer**. ' * 1000,
          'timestamp': fixture.now,
        },
      ];
      final key = ProfileSessionKey(controller.current!.scope, 'shared-id');
      final chat = (await controller.openSession(key))!;
      final gateway = controller.current!.gateway;
      final recents = emptyRecents();
      await recents.refresh();
      await Future<void>.delayed(Duration.zero);
      final cached = recents.items();
      recents.setForeground(false);
      final projections = controller.recentProjections;
      for (var i = 0; i < 100; i++) {
        // Actual HTTP observations notify this shared connection owner, even
        // when access remains healthy. Each previously reparsed saved replies.
        controller.connectionStatus.accessAvailable();
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.recentProjections, projections);
      expect(recents.items(), same(cached));

      fixture.messageRows[('personal', 'shared-id')] = [
        {
          'id': 2,
          'role': 'assistant',
          'content': 'Answer delivered in the background',
          'timestamp': fixture.now + 1,
        },
      ];
      gateway.onEvent!(
        StreamEvent(
          type: 'message.start',
          sessionId: chat.runtime.runtimeId,
          data: stockChatReply(gateway, 'message.start', {}),
        ),
      );
      gateway.onEvent!(
        StreamEvent(
          type: 'message.complete',
          sessionId: chat.runtime.runtimeId,
          data: {'text': 'Answer delivered in the background'},
        ),
      );
      for (var tick = 0; tick < 30; tick++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.recentProjections, projections);
      expect(recents.items(), same(cached));
      recents.setForeground(true);
      await Future<void>.delayed(Duration.zero);
      final item = recents.items().singleWhere((item) => item.chat?.key == key);
      expect(item.messagePreview, 'Answer delivered in the background');
      expect(item.unread, isTrue);
    },
  );

  testWidgets(
    'Recents suspends retained and late readers until the app resumes',
    (tester) async {
      final recents = emptyRecents();
      final reader = Object(), lateReader = Object();
      recents.setVisible(reader, true);
      await tester.pump();
      await recents.refresh();
      final reads = fixture.reads.length;
      expect(reads, greaterThan(0));

      recents.setForeground(false);
      // A delayed route callback must not restart background work.
      recents.setVisible(lateReader, true);
      await tester.pump(const Duration(minutes: 5));
      expect(fixture.reads.length, reads);
      await recents.prepareAppearances();
      expect(fixture.reads.length, reads);

      recents.setForeground(true);
      await tester.pump();
      await tester.pump(WorkspaceRecentsSession.refreshInterval);
      expect(fixture.reads.length, greaterThan(reads));
      recents.setVisible(reader, false);
      recents.setVisible(lateReader, false);
    },
  );

  test(
    'new conversation sources share cached reading revision and screenshot ownership',
    () async {
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'recent-5'),
      );
      final bots = BotsSession((_) async => const []);
      addTearDown(bots.dispose);
      final recents = recentsFor(bots);
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      addTearDown(activity.dispose);
      final chat = controller.current!.chat!;
      RecentConversationSession open() =>
          controller.chatRecentConversationSession(
            chat: chat,
            recents: recents,
            onOpenGroup: (_) async {},
            activity: () => activity,
          );
      final first = open();
      final key = RecentConversationKey.chat(chat.key);
      final revision = first.previewRevision(key);
      expect(first.snapshots, same(recents.snapshots));
      first.dispose();
      final second = open();
      addTearDown(second.dispose);
      expect(second.snapshots, same(recents.snapshots));
      expect(second.previewRevision(key), revision);
    },
  );

  for (final method in ['groups.state', 'groups.log']) {
    test(
      'failed $method observation retains the cached group slot until recovery',
      () async {
        var now = DateTime.now();
        final fixture = BotsFixture();
        fixture.room['name'] = 'Build Pace Health Analysis';
        fixture.events.add({
          'room_id': 'room-1',
          'seq': 1,
          'kind': 'message.member',
          'created_at': DateTime.now().millisecondsSinceEpoch / 1000 - 120,
          'actor': {'kind': 'member', 'id': 'atlas'},
          'payload': {'text': 'Recent group answer'},
        });
        final bots = BotsSession(
          (_) async => [fixture.repository],
          now: () => now,
        );
        final recents = WorkspaceRecentsSession(
          controller,
          bots,
          foreground: true,
        );
        addTearDown(recents.dispose);
        addTearDown(bots.dispose);
        now = now.add(const Duration(minutes: 5));
        await bots.refresh();
        await Future<void>.delayed(Duration.zero);
        final group = recents.items().single.group!;
        final activity = ValueNotifier<ChatNoticeActivity?>(null);
        addTearDown(activity.dispose);
        final visit = controller.recentConversationSession(
          recents: recents,
          entries: recents.catalog.entries,
          onOpenGroup: (_) async {},
          activity: activity,
        );
        addTearDown(visit.dispose);
        if (method == 'groups.log') {
          fixture.events.add({
            'room_id': 'room-1',
            'seq': 2,
            'kind': 'message.member',
            'created_at': DateTime.now().millisecondsSinceEpoch / 1000,
            'actor': {'kind': 'member', 'id': 'atlas'},
            'payload': {'text': 'Newer group answer'},
          });
        }
        fixture.readHook = (_, requested, _) async {
          if (requested == method) {
            throw StateError('Group read unavailable');
          }
          return null;
        };
        now = now.add(const Duration(minutes: 5));
        await bots.refresh();
        await Future<void>.delayed(Duration.zero);
        expect(recents.items().single.group!.key, group.key);
        expect(
          recents.items().single.lastMessage,
          group.lastMessageAt!.millisecondsSinceEpoch / 1000,
        );
        expect(bots.state.errors, isNotEmpty);
        expect(visit.catalogError, isNotNull);
        fixture.readHook = null;
        fixture.room['name'] = 'Recovered Build Pace Health Analysis';
        now = now.add(const Duration(minutes: 5));
        await bots.refresh();
        await Future<void>.delayed(Duration.zero);
        expect(recents.items().single.group!.key, group.key);
        expect(bots.state.errors, isEmpty);
        expect(visit.catalogError, isNull);
        expect(
          visit.entries.single.title,
          'Recovered Build Pace Health Analysis',
        );
        fixture.readHook = (_, method, _) async {
          if (method == 'groups.list') {
            return {'rooms': [], 'next_offset': null};
          }
          return null;
        };
        now = now.add(const Duration(minutes: 5));
        await bots.refresh();
        await Future<void>.delayed(Duration.zero);
        expect(recents.items(), isEmpty);
        expect(visit.entries, isEmpty);
      },
    );
  }

  test(
    'cold group cards prepare canonical member identity while presence waits',
    () async {
      final roomFixture = BotsFixture();
      roomFixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': DateTime.now().millisecondsSinceEpoch / 1000,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Saved group reply'},
      });
      final started = Completer<void>(), release = Completer<void>();
      roomFixture.readHook = (_, method, _) async {
        if (method == 'session.active_list') {
          if (!started.isCompleted) started.complete();
          await release.future;
        }
        return null;
      };
      final bots = BotsSession((_) async => [roomFixture.repository]);
      final recents = WorkspaceRecentsSession(
        controller,
        bots,
        foreground: true,
      );
      final refresh = bots.refresh();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await refresh;
        recents.dispose();
        bots.dispose();
      });
      await started.future;
      await Future<void>.delayed(Duration.zero);
      final room = recents.catalog.entries.singleWhere(
        (entry) => entry.group != null,
      );
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      addTearDown(activity.dispose);
      final visit = controller.recentConversationSession(
        recents: recents,
        entries: recents.catalog.entries,
        onOpenGroup: (_) async {},
        activity: activity,
      );
      addTearDown(visit.dispose);
      visit.activate();
      visit.prepare([room.key]);
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final card = visit.cardAt(
        visit.entries.indexWhere((entry) => entry.key == room.key),
      );
      expect(
        card.groupAppearance.byHandle.keys,
        containsAll(['bot_atlas', 'bot_mira']),
      );
      expect(card.groupAppearance.byHandle['bot_atlas']!.title, 'Atlas');
      expect(bots.state.loading, isTrue);
      expect(roomFixture.commands, isEmpty);
    },
  );

  test(
    'prepared group cards refresh when a bot passes without another reply',
    () async {
      var now = DateTime.now();
      final roomFixture = BotsFixture();
      roomFixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': now.millisecondsSinceEpoch / 1000,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Saved group reply'},
      });
      final bots = BotsSession(
        (_) async => [roomFixture.repository],
        now: () => now,
      );
      addTearDown(bots.dispose);
      await bots.refresh();
      final recents = recentsFor(bots);
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      addTearDown(activity.dispose);
      final visit = controller.recentConversationSession(
        recents: recents,
        entries: recents.catalog.entries,
        onOpenGroup: (_) async {},
        activity: activity,
      );
      addTearDown(visit.dispose);
      final room = visit.entries.singleWhere((entry) => entry.group != null);
      final index = visit.entries.indexOf(room);
      visit.prepare([room.key]);
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        visit
            .cardAt(index)
            .preview!
            .group!
            .messages
            .map((message) => message.text),
        ['Saved group reply'],
      );
      final revision = visit.previewRevision(room.key);
      roomFixture.events.add({
        'room_id': 'room-1',
        'seq': 2,
        'kind': 'turn.settled',
        'created_at': now.millisecondsSinceEpoch / 1000 + 60,
        'actor': {'kind': 'gateway', 'id': 'gateway-1'},
        'payload': {
          'member_id': 'mira',
          'passed': true,
          'message_event_id': null,
        },
      });
      now = now.add(const Duration(minutes: 5));
      await bots.refresh();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(visit.previewRevision(room.key), isNot(revision));
      visit.prepare([room.key]);
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final preview = visit
          .cardAt(visit.entries.indexWhere((entry) => entry.key == room.key))
          .preview!
          .group!
          .messages;
      expect(preview.map((message) => message.text), [
        'Saved group reply',
        'Passed',
      ]);
      expect(preview.last.sender, 'Mira');
      expect(preview.last.senderHandle, 'bot_mira');
      expect(roomFixture.commands, isEmpty);
    },
  );

  test(
    'group appearance changes refresh cards without rereading group messages',
    () async {
      final roomFixture = BotsFixture();
      roomFixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': DateTime.now().millisecondsSinceEpoch / 1000,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Saved group reply'},
      });
      var logs = 0;
      roomFixture.readHook = (_, method, _) async {
        if (method == 'groups.log') logs++;
        return null;
      };
      final bots = BotsSession((_) async => [roomFixture.repository]);
      final recents = WorkspaceRecentsSession(
        controller,
        bots,
        foreground: true,
      );
      addTearDown(bots.dispose);
      addTearDown(recents.dispose);
      await bots.refresh();
      await Future<void>.delayed(Duration.zero);
      final room = recents.catalog.entries.singleWhere(
        (entry) => entry.group != null,
      );
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      addTearDown(activity.dispose);
      final visit = controller.recentConversationSession(
        recents: recents,
        entries: recents.catalog.entries,
        onOpenGroup: (_) async {},
        activity: activity,
      );
      addTearDown(visit.dispose);
      visit.activate();
      visit.prepare([room.key]);
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final index = visit.entries.indexWhere((entry) => entry.key == room.key);
      final before = visit.cardRevision(room.key),
          data = visit.previewRevision(room.key);
      final reading = visit.cardAt(index).preview!;
      final reads = logs;
      final roster = await roomFixture.repository.bots();
      roomFixture.profiles.first['ui_meta']['hermes-bots']['title'] =
          'Resolved Atlas';
      bots.invalidateAppearances();
      await bots.appearancesForProfiles([
        roster.first.scope,
      ], canRead: () => true);
      await Future<void>.delayed(Duration.zero);
      expect(visit.cardRevision(room.key), isNot(before));
      expect(visit.previewRevision(room.key), data);
      expect(visit.cardAt(index).preview, same(reading));
      expect(
        visit.cardAt(index).groupAppearance.byHandle['bot_atlas']!.title,
        'Resolved Atlas',
      );
      expect(logs, reads);
      expect(roomFixture.commands, isEmpty);
    },
  );

  test(
    'group identity publishes all members before a held shared avatar',
    () async {
      final roomFixture = BotsFixture();
      roomFixture.profiles.first['has_avatar'] = true;
      roomFixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'created_at': DateTime.now().millisecondsSinceEpoch / 1000,
        'actor': {'kind': 'member', 'id': 'atlas'},
        'payload': {'text': 'Saved group reply'},
      });
      final started = Completer<void>(), release = Completer<void>();
      var assets = 0, logs = 0;
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=';
      roomFixture.readHook = (_, method, _) async {
        if (method == 'groups.log') logs++;
        if (method == 'profiles.get_asset') {
          assets++;
          if (!started.isCompleted) started.complete();
          await release.future;
          return {'found': true, 'data': png};
        }
        return null;
      };
      final bots = BotsSession((_) async => [roomFixture.repository]);
      final recents = WorkspaceRecentsSession(
        controller,
        bots,
        foreground: true,
      );
      final refresh = bots.refresh();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await refresh;
        recents.dispose();
        bots.dispose();
      });
      await refresh;
      await Future<void>.delayed(Duration.zero);
      final room = recents.catalog.entries.singleWhere((e) => e.group != null);
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      addTearDown(activity.dispose);
      final visit = controller.recentConversationSession(
        recents: recents,
        entries: recents.catalog.entries,
        onOpenGroup: (_) async {},
        activity: activity,
      );
      addTearDown(visit.dispose);
      var emissions = 0;
      visit.addListener(() => emissions++);
      visit.activate();
      visit.prepare([room.key]);
      await started.future;
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final index = visit.entries.indexWhere((e) => e.key == room.key);
      expect(
        visit.cardAt(index).groupAppearance.byHandle.keys,
        containsAll(['bot_atlas', 'bot_mira']),
      );
      expect(
        bots.avatarContentVersion(
          visit.cardAt(index).groupAppearance.byHandle['bot_atlas']!.scope,
        ),
        0,
      );
      final before = visit.cardRevision(room.key),
          reading = visit.cardAt(index).preview!;
      final reads = logs;
      expect(
        assets,
        1,
        reason:
            'Roster and card preparation must share one physical avatar request',
      );
      final beforeEmissions = emissions;
      release.complete();
      await refresh;
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        bots.avatarContentVersion(
          visit.cardAt(index).groupAppearance.byHandle['bot_atlas']!.scope,
        ),
        greaterThan(0),
      );
      expect(visit.cardRevision(room.key), isNot(before));
      expect(
        emissions,
        greaterThan(beforeEmissions),
        reason: 'Changed image pixels notify the prepared source immediately',
      );
      expect(visit.cardAt(index).preview, same(reading));
      expect(logs, reads);
      expect(assets, 1);
      expect(roomFixture.commands, isEmpty);
    },
  );

  test(
    'pinch catalog matches merged Recents freshness order including rooms',
    () async {
      var now = DateTime.now();
      final botFixture = BotsFixture();
      for (var seq = 1; seq <= 120; seq++) {
        botFixture.events.add({
          'room_id': 'room-1',
          'seq': seq,
          'kind': 'message.member',
          'created_at': fixture.now - 150 + seq,
          'actor': {'kind': 'member', 'id': 'atlas'},
          'payload': {'text': 'Group answer $seq'},
        });
      }
      final bots = BotsSession(
        (_) async => [botFixture.repository],
        now: () => now,
      );
      addTearDown(bots.dispose);
      await bots.refresh();
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'recent-5'),
      );
      await controller.refreshRecents();
      final merged = WorkspaceRecentsSession(
        controller,
        bots,
        foreground: true,
      );
      addTearDown(merged.dispose);
      final expected = merged
          .items()
          .map((item) => item.group?.name ?? item.chat!.title)
          .toList();
      expect(expected, contains('Research team'));
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      addTearDown(activity.dispose);
      BotGroup? openedGroup;
      final closeRoom = Completer<void>();
      final visit = controller.chatRecentConversationSession(
        onOpenGroup: (group) async {
          openedGroup = group;
          botFixture.room['name'] = 'Renamed research team';
          now = now.add(const Duration(minutes: 5));
          await bots.refresh();
          await closeRoom.future;
        },
        recents: merged,
        chat: controller.current!.chat!,
        activity: () => activity,
      );
      addTearDown(visit.dispose);
      visit.activate();
      await Future<void>.delayed(Duration.zero);
      expect(visit.catalogLoading, isFalse);
      expect(visit.entries.map((entry) => entry.title), expected);
      expect(
        visit.entries.map((entry) => entry.unread),
        merged.items().map((item) => item.unread),
      );
      final room = visit.entries.singleWhere((entry) => entry.group != null);
      final selected = visit.selected;
      final revision = visit.previewRevision(room.key);
      final commands = List.of(botFixture.commands);
      final chatCalls = List.of(fixture.calls);
      expect(bots.groupReads.unread(room.group!), isTrue);
      expect(room.unread, isTrue);
      visit.prepare([room.key]);
      await Future<void>.delayed(Duration.zero);
      final index = visit.entries.indexOf(room);
      expect(
        visit.cardAt(index).preview!.group!.messages.map((m) => m.text),
        List.generate(6, (i) => 'Group answer ${115 + i}'),
      );
      expect(
        visit.cardAt(index).groupAppearance.byHandle.keys,
        contains('bot_atlas'),
      );
      expect(visit.previewRevision(room.key), revision);
      expect(bots.groupReads.unread(room.group!), isTrue);
      expect(botFixture.commands, commands);
      expect(fixture.calls, chatCalls);
      final opening = visit.select(room.key);
      await Future<void>.delayed(Duration.zero);
      expect(openedGroup?.key, room.key.group);
      expect(visit.selecting, isTrue);
      expect(visit.selected, selected);
      closeRoom.complete();
      expect(await opening, isTrue);
      expect(
        visit.entries.singleWhere((entry) => entry.key == room.key).title,
        'Renamed research team',
      );
      expect(visit.selected, selected);
      expect(controller.current!.chat!.key, selected!.chat);
      expect(botFixture.commands, commands);
    },
  );

  for (final outcome in ['closed', 'failed', 'retired']) {
    final rejectRoute = outcome == 'failed';
    final retired = outcome == 'retired';
    test(
      'group-origin Recents fences selection after $outcome normal route',
      () async {
        var now = DateTime.now();
        final botFixture = BotsFixture();
        final bots = BotsSession(
          (_) async => [botFixture.repository],
          now: () => now,
        );
        addTearDown(bots.dispose);
        await bots.refresh();
        await controller.openSession(
          ProfileSessionKey(controller.current!.scope, 'shared-id'),
        );
        final original = controller.current!.chat!;
        final activity = ValueNotifier<ChatNoticeActivity?>(null);
        addTearDown(activity.dispose);
        final closed = Completer<void>();
        RecentConversationKey? opened;
        final group = bots.observedGroups.single;
        final visit = controller.groupRecentConversationSession(
          group: group,
          fromRecents: false,
          recents: recentsFor(bots),
          onOpenGroup: (_) async {},
          onOpenChat: (key) async {
            opened = key;
            await closed.future;
            if (rejectRoute) throw StateError('Route unavailable');
          },
          activity: () => activity,
        );
        addTearDown(visit.dispose);
        final origin = RecentConversationEntry.group(group, unread: false).key;
        expect(visit.selected, origin);
        expect(visit.modeEnabled, isFalse);
        final revision = visit.previewRevision(origin);
        await bots.refresh();
        expect(visit.previewRevision(origin), revision);
        botFixture.room['name'] = 'Renamed team';
        now = now.add(const Duration(minutes: 5));
        await bots.refresh();
        expect(visit.previewRevision(origin), isNot(revision));
        visit.activate();
        await Future<void>.delayed(Duration.zero);
        final target = visit.entries
            .firstWhere(
              (entry) =>
                  entry.key.chat?.sessionId == 'recent-5' &&
                  entry.key.chat?.workspace.profileName == 'personal',
            )
            .key;
        expect(visit.opensRoute(target), isTrue);
        final opening = visit.select(target);
        for (var i = 0; i < 20 && opened == null; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(opened, target);
        expect(controller.current!.chat!.key, target.chat);
        expect(visit.selected, origin);
        expect(visit.selecting, isTrue);
        if (retired) visit.dispose();
        closed.complete();
        expect(await opening, !rejectRoute && !retired);
        if (retired) {
          expect(controller.current!.chat!.key, target.chat);
          expect(visit.active, isFalse);
        } else if (rejectRoute) {
          expect(controller.current!.chat, same(original));
          expect(visit.selected, origin);
          expect(visit.modeEnabled, isTrue);
        } else {
          expect(controller.current!.chat!.key, target.chat);
          expect(visit.selected, origin);
          expect(visit.modeEnabled, isTrue);
        }
        expect(botFixture.commands, isEmpty);
      },
    );
  }

  for (final heldMethod in ['session.active_list', 'profiles.get_asset']) {
    test(
      'cold Recents publishes groups while $heldMethod is pending',
      () async {
        final botFixture = BotsFixture();
        if (heldMethod == 'profiles.get_asset') {
          botFixture.profiles.first['has_avatar'] = true;
        }
        botFixture.events.add({
          'room_id': 'room-1',
          'seq': 1,
          'kind': 'message.member',
          'created_at': DateTime.now().millisecondsSinceEpoch / 1000,
          'actor': {'kind': 'member', 'id': 'atlas'},
          'payload': {'text': 'Recent group answer'},
        });
        final started = Completer<void>(), release = Completer<void>();
        botFixture.readHook = (_, method, _) async {
          if (method == heldMethod) {
            if (!started.isCompleted) started.complete();
            await release.future;
            if (method == 'profiles.get_asset') return {'found': false};
          }
          return null;
        };
        final bots = BotsSession((_) async => [botFixture.repository]);
        final recents = WorkspaceRecentsSession(
          controller,
          bots,
          foreground: true,
        );
        var published = false;
        recents.addListener(() {
          if (recents.items().any((item) => item.group != null)) {
            published = true;
          }
        });
        addTearDown(() async {
          release.complete();
          await Future<void>.delayed(Duration.zero);
          recents.dispose();
          bots.dispose();
        });
        recents.setVisible(recents, true);
        await started.future;
        await Future<void>.delayed(Duration.zero);
        expect(recents.items().where((item) => item.chat != null), isNotEmpty);
        expect(
          recents.items().map((item) => item.group?.name),
          contains('Research team'),
          reason: 'Group discovery must not wait for unrelated bot reads',
        );
        expect(published, isTrue);
        expect(bots.state.loading, heldMethod == 'session.active_list');
        expect(botFixture.commands, isEmpty);
      },
    );
  }

  test(
    'pinch publishes ready neighbors while bot refresh is pending',
    () async {
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'recent-5'),
      );
      final botFixture = BotsFixture();
      final started = Completer<void>(), release = Completer<void>();
      botFixture.readHook = (_, method, _) async {
        if (method == 'session.active_list') {
          started.complete();
          await release.future;
        }
        return null;
      };
      final bots = BotsSession((_) async => [botFixture.repository]);
      final activity = ValueNotifier<ChatNoticeActivity?>(null);
      final visit = controller.chatRecentConversationSession(
        onOpenGroup: (_) async {},
        recents: recentsFor(bots),
        chat: controller.current!.chat!,
        activity: () => activity,
      );
      addTearDown(() async {
        release.complete();
        await Future<void>.delayed(Duration.zero);
        visit.dispose();
        activity.dispose();
        bots.dispose();
      });
      visit.activate();
      await started.future;
      await controller.refreshRecents();
      expect(visit.catalogLoading, isTrue);
      expect(
        visit.entries.length,
        greaterThan(1),
        reason:
            'Ready chats must reach screenshot preparation before bot status',
      );
      expect(botFixture.commands, isEmpty);
    },
  );

  test('simultaneous Recents consumers share the physical refresh', () async {
    final delay = Completer<void>();
    fixture.pageDelays[('personal', 0)] = delay;
    Future<void>? observed;
    controller.addListener(() {
      if (controller.recentsLoading && observed == null) {
        observed = controller.refreshRecents();
      }
    });
    final first = controller.refreshRecents();
    final second = controller.refreshRecents();
    expect(identical(first, second), isTrue);
    expect(identical(first, observed), isTrue);
    delay.complete();
    await first;
    expect(controller.recentsLoading, isFalse);
    expect(controller.recentChats(), isNotEmpty);
  });

  test(
    'loads every recent page across profiles, including archived chats',
    () async {
      final selectedScope = controller.current!.scope;
      await controller.refreshRecents();
      final items = controller.recentChats();
      expect(items, hasLength(107));
      expect(items.map((item) => item.key).toSet(), hasLength(107));
      expect(
        items.where((item) => item.key.sessionId == 'shared-id'),
        hasLength(2),
      );
      expect(items.any((item) => item.key.sessionId == 'old'), isFalse);
      expect(items.first.key.sessionId, 'recent-0');
      expect(
        fixture.reads.where(
          (read) =>
              read.$1 == 'sessions/recent-0/messages' &&
              read.$2['limit'] == '1',
        ),
        hasLength(1),
      );
      expect(items.every((item) => item.state == null), isTrue);
      expect(controller.current!.scope, selectedScope);
      expect(controller.current!.chat, isNull);
      expect(
        fixture.calls.where((call) => call.$2 == 'session.resume'),
        isEmpty,
      );
      expect(
        fixture.reads.any(
          (read) =>
              read.$1 == 'sessions' &&
              read.$2['offset'] == '100' &&
              read.$2['archived'] == 'include',
        ),
        isTrue,
      );
    },
  );

  test(
    'rolling window expires idle chats without another network refresh',
    () async {
      await controller.refreshRecents();
      final newest = fixture.now;
      final boundary = DateTime.fromMillisecondsSinceEpoch(
        ((newest + 86400) * 1000).round(),
      );
      expect(
        controller.recentChats(now: boundary).map((item) => item.key.sessionId),
        ['recent-0'],
      );
      expect(
        controller.recentChats(now: boundary.add(const Duration(seconds: 1))),
        isEmpty,
      );
    },
  );

  test(
    'partial profile failure keeps available recent chats and reports the gap',
    () async {
      fixture.failWork = true;
      await controller.refreshRecents();
      expect(controller.recentChats(), hasLength(106));
      expect(controller.recentsAvailableProfiles, 1);
      expect(controller.recentsProfileErrors['work'], isNotNull);
    },
  );

  test(
    'partial profile refresh retains known cached chats until recovery',
    () async {
      final recents = emptyRecents();
      await recents.refresh();
      final previous = recents.items().map((item) => item.chat!.key).toList();
      expect(
        previous.any((key) => key.workspace.profileName == 'work'),
        isTrue,
      );
      fixture.failWork = true;
      await recents.refresh(force: true);
      expect(recents.items().map((item) => item.chat!.key), previous);
      expect(recents.catalog.error, isNotNull);
      fixture.failWork = false;
      await recents.refresh(force: true);
      expect(recents.catalog.error, isNull);
      expect(recents.items().map((item) => item.chat!.key), previous);
    },
  );

  test(
    'discovery failure retains chats and the next refresh clears its error',
    () async {
      await controller.refreshRecents();
      final previous = controller
          .recentChats()
          .map((chat) => chat.key)
          .toList();
      expect(previous, isNotEmpty);
      fixture.failDiscovery = true;
      await controller.refreshRecents();
      expect(
        controller.recentsProfileErrors['recents'],
        'Recent chats could not be loaded.',
      );
      expect(controller.recentChats().map((chat) => chat.key), previous);
      expect(controller.recentsLoading, isFalse);
      fixture.failDiscovery = false;
      await controller.refreshRecents();
      expect(controller.recentsProfileErrors, isEmpty);
      expect(controller.recentChats().map((chat) => chat.key), previous);
    },
  );

  test('opening or drafting in an old chat does not make it recent', () async {
    final key = ProfileSessionKey(controller.current!.scope, 'old');
    final chat = await controller.openSession(key);
    await controller.updateDraft(chat!, 'Unsent draft');
    await controller.refreshRecents();
    expect(controller.recentChats().any((item) => item.key == key), isFalse);
    expect(
      preferences.getKeys().where((key) => key.startsWith('recent_visits_')),
      isEmpty,
    );
  });

  test(
    'empty chats and fresh heartbeats do not count as recent messages',
    () async {
      await controller.createChat(canDispatch: () => true);
      await controller.refreshRecents();
      expect(controller.recentChats(), hasLength(107));
      expect(
        controller.recentChats().any(
          (item) => ['empty', 'heartbeat'].contains(item.key.sessionId),
        ),
        isFalse,
      );
    },
  );

  test(
    'new local messages appear without opening or visit timestamps',
    () async {
      final chat = await controller.createChat(canDispatch: () => true);
      expect(controller.recentChats(), isEmpty);
      chat.reading.installSavedHistory([
        ...chat.reading.messages,
        {'role': 'user', 'content': 'Sent message', 'timestamp': fixture.now},
      ]);
      expect(controller.recentChats().single.key, chat.key);
      expect(controller.recentChats().single.messagePreview, 'Sent message');
      expect(
        controller.recentChats(
          now: DateTime.fromMillisecondsSinceEpoch(
            ((fixture.now + 86401) * 1000).round(),
          ),
        ),
        isEmpty,
      );
    },
  );

  test(
    'opens a recent archived chat in its owning profile with its saved title',
    () async {
      await controller.refreshRecents();
      final item = controller.recentChats().singleWhere(
        (item) => item.key.workspace.profileName == 'work',
      );
      final chat = await controller.openSession(item.key);
      expect(chat, isNotNull);
      expect(chat!.title, 'work conversation');
      expect(chat.archived, isTrue);
      expect(controller.current!.scope, item.key.workspace);
    },
  );
}
