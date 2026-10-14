import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/session_visibility.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_workspace_controller_test.dart' show Host;

class FilterHost extends Host {
  final rows = <Map<String, dynamic>>[
    for (var i = 0; i < 150; i++)
      {'id': 'cron-$i', 'title': 'Scheduled $i', 'source': 'cron'},
    {'id': 'tool', 'title': 'Integration run', 'source': 'tool'},
    {'id': 'subagent', 'title': 'Delegate run', 'source': 'subagent'},
    {'id': 'kanban', 'title': 'Worker run', 'source': 'kanban'},
    {'id': 'oneshot', 'title': 'Technical run', 'source': 'oneshot'},
    {'id': 'chat', 'title': 'My conversation', 'source': 'desktop'},
    {'id': 'wing', 'title': 'Phone conversation', 'source': 'wing'},
    {'id': 'unknown', 'title': 'Old conversation', 'source': 'unknown'},
    {'id': 'missing', 'title': 'Unlabelled conversation'},
    {
      'id': 'branch',
      'title': 'Branched conversation',
      'source': 'cli',
      'parent_session_id': 'chat',
    },
    {'id': 'custom', 'title': 'Custom source conversation', 'source': 'custom'},
  ];
  final listRequests = <(String, Map<String, String>)>[];
  Future<void> Function(String, Map<String, String>)? wait;
  bool fail = false;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    final gateway = ProfileGateway(
      scope: scope,
      discover: discover,
      connect: base.connect,
      close: base.close,
      rpc: (method, params) async {
        final result = await base.call(method, params);
        if (method == 'session.resume') {
          result['stored_session_id'] = params['session_id'];
          result['info'] = {
            'source': 'tool',
            'profile_name': scope.profileName,
          };
        }
        return result;
      },
      get: (path, params) async {
        if (path != 'sessions' && path != 'sessions/search') {
          return base.read(path, params);
        }
        listRequests.add((path, params));
        await wait?.call(path, params);
        if (fail) throw StateError('offline');
        final exclude = params['exclude_sources']?.split(',') ?? [];
        final include = params['sources']?.split(',');
        final matches = rows.where(
          (row) =>
              !exclude.contains(row['source']) &&
              (include == null || include.contains(row['source'])) &&
              (params['q'] == null ||
                  row['title'].toString().toLowerCase().contains(
                    params['q']!.toLowerCase(),
                  )),
        );
        final page = matches
            .skip(int.parse(params['offset'] ?? '0'))
            .take(int.parse(params['limit']!));
        return {
          'offset': int.parse(params['offset'] ?? '0'),
          'limit': int.parse(params['limit']!),
          'total': matches.length,
          path == 'sessions/search' ? 'results' : 'sessions': [
            for (final row in page)
              if (path == 'sessions/search')
                {
                  ...row,
                  'id': null,
                  'session_id': row['id'],
                  'snippet': 'Matching content',
                }
              else
                {...row, 'profile': scope.profileName},
          ],
        };
      },
    );
    gateways[scope.profileName] = gateway;
    return gateway;
  }
}

void main() {
  late FilterHost host;
  late SharedPreferences prefs;
  late ProfileWorkspaceController controller;
  ProfileWorkspaceController makeController([
    String identity = 'host-identity',
  ]) => ProfileWorkspaceController(
    connection: SavedConnection(
      id: 'host',
      label: 'Host',
      host: 'localhost',
      port: 1,
      apiKey: '',
    ),
    connectionIdentity: identity,
    preferences: prefs,
    gatewayFactory: host.gateway,
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    host = FilterHost();
    controller = makeController();
    await controller.initialize();
  });
  tearDown(() => controller.dispose());

  test('missing and retired automated-only preferences default to chats', () {
    expect(SessionVisibility.fromStored(null), SessionVisibility.chats);
    expect(SessionVisibility.fromStored('automated'), SessionVisibility.chats);
    expect(SessionVisibility.fromStored('all'), SessionVisibility.all);
  });

  test(
    'Chats excludes automation before pagination and retains unknowns and branches',
    () {
      expect(controller.current!.sessions.map((r) => r['id']), [
        'chat',
        'wing',
        'unknown',
        'missing',
        'branch',
        'custom',
      ]);
      expect(
        host.listRequests.single.$2['exclude_sources'],
        'cron,tool,subagent,kanban,oneshot',
      );
      expect(controller.current!.nextSessionOffset, isNull);
    },
  );

  test('including automation paginates all sources', () async {
    await controller.setSessionVisibility(SessionVisibility.all);
    expect(controller.current!.sessions, hasLength(50));
    while (controller.current!.nextSessionOffset != null) {
      await controller.loadMoreSessions();
    }
    expect(controller.current!.sessions, hasLength(160));
    expect(host.listRequests.last.$2.containsKey('exclude_sources'), isFalse);
    expect(host.listRequests.last.$2['offset'], '150');
    await controller.setSessionVisibility(SessionVisibility.all);
    expect(host.listRequests.last.$2.containsKey('sources'), isFalse);
    expect(host.listRequests.last.$2.containsKey('exclude_sources'), isFalse);
  });

  test(
    'search uses the same exclusion and inclusion filters with profile ownership',
    () async {
      await controller.searchChats('run');
      expect(controller.current!.searchResults, isEmpty);
      expect(
        host.listRequests.last.$2['exclude_sources'],
        'cron,tool,subagent,kanban,oneshot',
      );
      await controller.setSessionVisibility(SessionVisibility.all);
      expect(controller.current!.searchResults.map((r) => r['id']), [
        'tool',
        'subagent',
        'kanban',
        'oneshot',
      ]);
      expect(host.listRequests.last.$2.containsKey('exclude_sources'), isFalse);
      expect(host.listRequests.last.$2['profile'], 'a');
    },
  );

  test(
    'selection persists per verified connection and across profiles and archives',
    () async {
      await controller.setSessionVisibility(SessionVisibility.all);
      await controller.navigateProfile('b');
      expect(host.listRequests.last.$2['profile'], 'b');
      expect(host.listRequests.last.$2.containsKey('exclude_sources'), isFalse);
      await controller.showArchived(true);
      expect(host.listRequests.last.$2['archived'], 'only');
      expect(host.listRequests.last.$2.containsKey('exclude_sources'), isFalse);
      final restored = makeController();
      final other = makeController('another-server');
      addTearDown(restored.dispose);
      addTearDown(other.dispose);
      expect(restored.sessionVisibility, SessionVisibility.all);
      expect(other.sessionVisibility, SessionVisibility.chats);
    },
  );

  test(
    'late automated page cannot publish after switching back to Chats',
    () async {
      await controller.setSessionVisibility(SessionVisibility.all);
      final gate = Completer<void>();
      host.wait = (_, params) async {
        if (params['offset'] == '50') await gate.future;
      };
      final page = controller.loadMoreSessions();
      await controller.setSessionVisibility(SessionVisibility.chats);
      gate.complete();
      await page;
      expect(controller.current!.sessions, hasLength(6));
      expect(
        controller.current!.sessions.every((r) => r['source'] != 'cron'),
        isTrue,
      );
    },
  );

  test(
    'late search cannot restore automated results after a filter change',
    () async {
      await controller.setSessionVisibility(SessionVisibility.all);
      final gate = Completer<void>();
      host.wait = (_, params) async {
        if (params['q'] == 'run' && !params.containsKey('exclude_sources')) {
          await gate.future;
        }
      };
      final search = controller.searchChats('run');
      await controller.setSessionVisibility(SessionVisibility.chats);
      gate.complete();
      await search;
      expect(controller.current!.searchResults, isEmpty);
      expect(controller.current!.searchLoading, isFalse);
    },
  );

  test(
    'failed filter load is retriable without displaying the old page',
    () async {
      host.fail = true;
      await controller.setSessionVisibility(SessionVisibility.all);
      expect(controller.current!.sessions, isEmpty);
      expect(controller.current!.sessionsPageError, isNotNull);
      host.fail = false;
      await controller.loadMoreSessions();
      expect(controller.current!.sessionsPageError, isNull);
      expect(controller.current!.sessions, hasLength(50));
    },
  );

  testWidgets(
    'automated visibility applies before cross-profile search and grouping',
    (tester) async {
      await controller.setSessionVisibility(SessionVisibility.all);
      while (controller.current!.nextSessionOffset != null) {
        await controller.loadMoreSessions();
      }
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'tool'),
      );
      expect(controller.current!.chat!.source, 'tool');
      controller.showList();
      await controller.setSessionVisibility(SessionVisibility.chats);
      await tester.pumpWidget(
        MaterialApp(
          // This test waits for menus to settle while a working chat is visible.
          // Exercise filtering with reduced motion; the border's motion has its
          // own lifecycle and interaction tests.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: ProfileWorkspaceScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SegmentedButton<SessionVisibility>), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('workspace-search')),
        'Integration run',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == 'Integration run'),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Chat list options'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(
        find.byKey(const ValueKey('chat-menu-include-automated')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == 'Integration run'),
        findsWidgets,
      );
      await tester.tap(find.byTooltip('Chat list options'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await tester.tap(
        find.byKey(const ValueKey('chat-menu-include-automated')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == 'Integration run'),
        findsNothing,
      );
      expect(controller.sessionVisibility, SessionVisibility.chats);
      expect(host.calls.where((c) => c.$2 == 'session.interrupt'), isEmpty);
    },
  );
}
