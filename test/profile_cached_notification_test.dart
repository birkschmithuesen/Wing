import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/workspace_snapshot_store.dart';
import 'package:wing/core/services/ws_client.dart';

import 'profile_notification_coverage_test.dart'
    show NotificationCoverageHost, row, waitForReads;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NotificationCoverageHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat cached;
  late List<ProfileInputNotification> notices;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    const identity = 'cached-notification-owner';
    await WorkspaceSnapshotStore(preferences, identity).write({
      'selected': 'a',
      'profiles': [
        {
          'name': 'a',
          'sessions': [
            {
              'id': 'outside',
              'title': 'Previously opened chat',
              'profile': 'a',
            },
          ],
          'chats': [
            {
              'id': 'outside',
              'title': 'Previously opened chat',
              'messages': [
                {
                  'id': 1,
                  'role': 'assistant',
                  'content': 'Earlier completed reply',
                },
              ],
              'history_session': 'outside',
            },
          ],
        },
      ],
    });
    host = NotificationCoverageHost();
    notices = <ProfileInputNotification>[];
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
      connectionIdentity: identity,
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      onAttention: (_) async {},
      onNotificationInputs: (notice) async => notices.add(notice),
    );
    cached = controller.notificationChats.single;
    expect(
      cached.runtime.runtimeId,
      'outside',
      reason: 'reading cache contains a durable ID, not a live runtime',
    );
    expect(cached.runtime.offline, isTrue);
    await controller.initialize();
    expect(controller.current!.chat, isNull);
    expect(host.resumeCalls, isEmpty);
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> snapshot(String status) async {
    final reads = host.activeReads;
    host.active = [row('outside-runtime', 'outside', status, reads + 1)];
    host.changed();
    await waitForReads(host, reads + 1);
  }

  Future<void> question() async {
    host.questions = [
      for (var index = 0; index < 3; index++)
        {
          'qid': 'q$index',
          'question': 'Choose environment $index',
          'choices': ['Preview', 'Production'],
        },
    ];
    host.waitingProfiles.add('a');
    await snapshot('waiting');
  }

  void expectCached() {
    expect(controller.notificationChats.single, same(cached));
    expect(
      cached.reading.messages.single['content'],
      'Earlier completed reply',
    );
    expect(controller.current!.chat, isNull);
  }

  test(
    'a cached unopened chat receives its first live question after restart',
    () async {
      await snapshot('working');
      expect(controller.hasActiveChats, isTrue);
      await question();
      expectCached();
      expect(
        notices,
        hasLength(1),
        reason:
            'new waiting runtime must hydrate the existing cached slot; resume calls: ${host.resumeCalls.length}, cached runtime: ${cached.runtime.runtimeId}, status: ${cached.runtime.execution}, watcher: ${controller.hasActiveChats}',
      );
      expect(notices.single.alert, isTrue);
      expect(notices.single.inputs.single.count, 3);
      expect(notices.single.inputs.single.focus.kind, 'question');
      expect(
        notices.single.inputs.single.content.preview,
        contains('Choose environment 0'),
      );
      expect(host.resumeCalls.single['display_projection'], isTrue);
      expect(cached.runtime.runtimeId, 'outside-runtime');
      expect(cached.runtime.offline, isFalse);
    },
  );

  test(
    'failed adoption retains the offline transcript and retries later',
    () async {
      await snapshot('working');
      host.resumeFails = true;
      await question();
      expect(host.resumeCalls, hasLength(1));
      expectCached();
      expect(cached.runtime.runtimeId, 'outside');
      expect(cached.runtime.offline, isTrue);
      expect(notices, isEmpty);
      host.resumeFails = false;
      await snapshot('waiting');
      expectCached();
      expect(notices.single.inputs.single.count, 3);
      expect(cached.runtime.runtimeId, 'outside-runtime');
      expect(cached.runtime.offline, isFalse);
    },
  );

  for (final mismatch in [
    {'session_id': 'wrong-runtime'},
    {'stored_session_id': 'wrong-session'},
    {
      'info': {'profile_name': 'b'},
    },
  ]) {
    test(
      'cached adoption rejects mismatched ownership and can retry: $mismatch',
      () async {
        await snapshot('working');
        host.resumeOverrides = mismatch;
        await question();
        expect(host.resumeCalls, hasLength(1));
        expectCached();
        expect(cached.runtime.runtimeId, 'outside');
        expect(cached.runtime.offline, isTrue);
        expect(notices, isEmpty);
        host.resumeOverrides = {};
        await snapshot('waiting');
        expectCached();
        expect(notices.single.inputs.single.count, 3);
      },
    );
  }

  for (final resumeFails in [false, true]) {
    test(
      'newer live question owns cached state when adoption fails: $resumeFails',
      () async {
        await snapshot('working');
        host.resumeDelays[1] = Completer<void>();
        await question();
        expect(host.resumeCalls, hasLength(1));
        host.gateways['a']!.onEvent!(
          StreamEvent(
            type: 'clarify',
            sessionId: 'outside-runtime',
            data: {
              'request_id': 'newer-live-question',
              'question': 'Newer decision?',
              'choices': ['Yes', 'No'],
            },
          ),
        );
        host.resumeFails = resumeFails;
        host.resumeDelays[1]!.complete();
        await Future<void>.delayed(Duration.zero);
        expectCached();
        expect(
          cached.runtime.pendingQuestion!.requestId,
          'newer-live-question',
        );
        expect(notices.single.inputs.single.focus.id, 'newer-live-question');
        expect(notices.single.alert, isTrue);
        expect(cached.runtime.runtimeId, 'outside-runtime');
        expect(cached.runtime.offline, isFalse);
      },
    );
  }

  test(
    'resolved adoption retains the cached transcript without a notice',
    () async {
      await snapshot('working');
      host.resumeSnapshots[1] = {'open_requests': [], 'running': false};
      await question();
      expect(host.resumeCalls, hasLength(1));
      expectCached();
      expect(cached.runtime.runtimeId, 'outside-runtime');
      expect(cached.runtime.offline, isFalse);
      expect(cached.runtime.pendingQuestion, isNull);
      expect(notices, isEmpty);
    },
  );

  test(
    'opening the cached chat wins over an older empty adoption response',
    () async {
      await snapshot('working');
      host.resumeDelays[1] = Completer<void>();
      host.resumeDelays[2] = Completer<void>();
      host.resumeSnapshots[1] = {'open_requests': [], 'running': false};
      await question();
      expect(host.resumeCalls, hasLength(1));
      final opening = controller.openSession(cached.key);
      await Future<void>.delayed(Duration.zero);
      expect(host.resumeCalls, hasLength(2));
      host.resumeDelays[1]!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.notificationChats.single, same(cached));
      expect(
        cached.reading.messages.single['content'],
        'Earlier completed reply',
      );
      host.resumeDelays[2]!.complete();
      await opening;
      expect(controller.current!.chat, same(cached));
      expect(cached.runtime.pendingQuestion!.requestId, 'question-a');
      expect(cached.runtime.runtimeId, 'outside-runtime');
      expect(cached.runtime.offline, isFalse);
    },
  );

  test(
    'ambiguous profile ownership never adopts or drops a cached chat',
    () async {
      await snapshot('working');
      host.saved['b'] = [
        {'id': 'outside', 'title': 'Another profile chat', 'profile': 'b'},
      ];
      await question();
      expect(host.resumeCalls, isEmpty);
      expectCached();
      expect(cached.runtime.runtimeId, 'outside');
      expect(cached.runtime.offline, isTrue);
      expect(notices, isEmpty);
    },
  );
}
