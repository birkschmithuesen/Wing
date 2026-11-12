import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'support/profile_paging_fixture.dart';

void main() {
  late ProfilePagingFixture host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = ProfilePagingFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'QA',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'qa-settings',
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
    'pins outside the page never advance offsets or duplicate rows',
    () async {
      final data = controller.current!;
      expect(data.sessions.length, 51);
      expect(data.sessions.any((s) => s['id'] == 'chat-120'), isTrue);
      expect(data.nextSessionOffset, 50);
      await controller.loadMoreSessions();
      expect(data.sessions.length, 101);
      expect(data.nextSessionOffset, 100);
      await controller.loadMoreSessions();
      expect(data.sessions.length, 125);
      expect(data.nextSessionOffset, isNull);
      await controller.loadMoreSessions();
      expect(host.reads.map((r) => r.$2['offset']), ['0', '50', '100']);
      expect(data.sessions.map((s) => s['id']).toSet().length, 125);
      expect(data.sessions.where((s) => s['pinned'] == true).length, 2);
    },
  );

  test('concurrent scroll requests send one page', () async {
    final delay = host.pageDelays[('personal', 50)] = Completer<void>();
    final pending = controller.loadMoreSessions();
    await controller.loadMoreSessions();
    expect(controller.current!.sessionsLoadingMore, isTrue);
    expect(host.reads.where((r) => r.$2['offset'] == '50').length, 1);
    delay.complete();
    await pending;
    expect(controller.current!.sessionsLoadingMore, isFalse);
  });

  test('failed page preserves rows and retries the same offset', () async {
    host.pageFailures.add(('personal', 50));
    await controller.loadMoreSessions();
    expect(controller.current!.sessions.length, 51);
    expect(controller.current!.nextSessionOffset, 50);
    expect(controller.current!.sessionsPageError, isNotNull);
    host.pageFailures.clear();
    await controller.loadMoreSessions();
    expect(controller.current!.sessions.length, 101);
    expect(controller.current!.sessionsPageError, isNull);
    expect(host.reads.map((r) => r.$2['offset']), ['0', '50', '50']);
  });

  test(
    'A to B to A rejects the first A page even with identical IDs',
    () async {
      final a = controller.current!;
      final delay = host.pageDelays[('personal', 50)] = Completer<void>();
      final pending = controller.loadMoreSessions();
      await controller.navigateProfile('work');
      expect(
        controller.current!.sessions.every((r) => r['profile'] == 'work'),
        isTrue,
      );
      await controller.navigateProfile('personal');
      delay.complete();
      await pending;
      expect(controller.current, same(a));
      expect(a.sessions.length, 51);
      expect(a.nextSessionOffset, 50);
      expect(a.sessionsLoadingMore, isFalse);
      await controller.loadMoreSessions();
      expect(a.sessions.length, 101);
    },
  );

  test(
    'refresh invalidates pending pages and replaces the list atomically',
    () async {
      final delay = host.pageDelays[('personal', 50)] = Completer<void>();
      final pending = controller.loadMoreSessions();
      host.count = 10;
      await controller.refresh();
      delay.complete();
      await pending;
      expect(controller.current!.sessions.length, 10);
      expect(controller.current!.nextSessionOffset, isNull);
    },
  );

  test('project navigation rejects root pages and Back can retry', () async {
    final data = controller.current!;
    final delay = host.pageDelays[('personal', 50)] = Completer<void>();
    final pending = controller.loadMoreSessions();
    await controller.selectProject(data.projects.last);
    delay.complete();
    await pending;
    expect(data.visibleSessions.single['id'], 'other-only');
    expect(data.sessions.length, 51);
    await controller.selectProject(null);
    await controller.loadMoreSessions();
    expect(data.sessions.length, 101);
  });

  test(
    'a changing offset window deduplicates overlap without losing the tail',
    () async {
      host.prepend = true;
      await controller.loadMoreSessions();
      await controller.loadMoreSessions();
      final ids = controller.current!.sessions.map((s) => s['id']).toSet();
      expect(ids.length, 125);
      expect(ids.contains('chat-124'), isTrue);
      await controller.refresh();
      expect(
        controller.current!.sessions.any((s) => s['id'] == 'inserted'),
        isTrue,
      );
    },
  );

  test('empty and exact-boundary pages stop using metadata', () async {
    for (final count in [0, 50, 100]) {
      host.count = count;
      await controller.refresh();
      if (count == 100) await controller.loadMoreSessions();
      expect(controller.current!.nextSessionOffset, isNull);
      expect(controller.current!.sessions.length, count);
    }
  });

  test('malformed metadata and wrong-profile rows fail closed', () async {
    final scope = WorkspaceScope(connectionId: 'host', profileName: 'personal');
    for (final result in <Map<String, dynamic>>[
      {'sessions': [], 'offset': 0, 'limit': 50},
      {'sessions': [], 'offset': 1, 'limit': 50, 'total': 10},
      {'sessions': [], 'offset': 0, 'limit': 100, 'total': 10},
      {'sessions': [], 'offset': 0, 'limit': 50, 'total': -1},
      {
        'sessions': [
          {'id': 'same', 'profile': 'work'},
        ],
        'offset': 0,
        'limit': 50,
        'total': 1,
      },
      {
        'sessions': [
          {'id': '', 'profile': 'personal'},
        ],
        'offset': 0,
        'limit': 50,
        'total': 1,
      },
    ]) {
      final gateway = ProfileGateway(
        scope: scope,
        discover: host.gateway(scope).discover,
        get: (_, _) async => result,
        rpc: (_, _) async => {},
      );
      await expectLater(gateway.sessions(), throwsFormatException);
    }
  });
}
