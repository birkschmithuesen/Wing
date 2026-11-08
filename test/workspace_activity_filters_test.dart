import 'package:wing/core/services/group_observations.dart';
import 'package:wing/core/services/workspace_recents_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/widgets/bot_avatar.dart';
import 'support/bots_fixture.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/workspace_overview_content.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/project_icon_glyphs.dart';

const _capture = bool.fromEnvironment('CAPTURE_RECENTS');

class _ActivityHost {
  final live = <String, List<Map<String, dynamic>>>{};
  final failed = <String>{};
  bool includeHistory = false;

  Future<ProfileDiscovery> discover() async => ProfileDiscovery(
    profiles: [const HermesProfile(name: 'main')],
    currentName: 'main',
    activeName: 'main',
  );

  ProfileGateway gateway(WorkspaceScope scope) => ProfileGateway(
    scope: scope,
    discover: discover,
    connect: () async {},
    get: (path, query) async => path == 'sessions/search'
        ? {
            'results': [
              for (final row in const [
                {'id': 'running', 'title': 'Running job', 'profile': 'main'},
                {'id': 'needs-input', 'title': 'Question', 'profile': 'main'},
                {
                  'id': 'side-work',
                  'title': 'Deploy checks',
                  'profile': 'main',
                },
                {
                  'id': 'idle-old',
                  'title': 'Idle old server',
                  'profile': 'main',
                },
              ])
                if (row['id'] == query['q'])
                  {
                    'session_id': row['id'],
                    'title': row['title'],
                    'profile': row['profile'],
                  },
            ],
          }
        : RegExp(r'^sessions/[^/]+$').hasMatch(path)
        ? const <Map<String, dynamic>>[
            {'id': 'running', 'title': 'Running job', 'profile': 'main'},
            {'id': 'needs-input', 'title': 'Question', 'profile': 'main'},
            {'id': 'side-work', 'title': 'Deploy checks', 'profile': 'main'},
            {'id': 'idle-old', 'title': 'Idle old server', 'profile': 'main'},
          ].singleWhere(
            (row) => row['id'] == Uri.decodeComponent(path.split('/')[1]),
          )
        : path == 'sessions'
        ? {
            'sessions': [
              if (includeHistory)
                {
                  'id': 'recent',
                  'title': 'Draft the setup guide',
                  'profile': 'main',
                  'last_active':
                      DateTime.now().millisecondsSinceEpoch / 1000 - 7200,
                  'unread': true,
                },
              {'id': 'running', 'title': 'Running job', 'profile': 'main'},
              {'id': 'needs-input', 'title': 'Question', 'profile': 'main'},
              {'id': 'side-work', 'title': 'Deploy checks', 'profile': 'main'},
              {'id': 'idle-old', 'title': 'Idle old server', 'profile': 'main'},
            ],
            'offset': int.parse(query['offset']!),
            'limit': int.parse(query['limit']!),
            'total': includeHistory ? 5 : 4,
          }
        : {
            'session_id': path.split('/')[1],
            'messages': <Map<String, dynamic>>[
              if (includeHistory)
                {
                  'id': 1,
                  'role': 'assistant',
                  'content': 'Guide ready',
                  'timestamp':
                      DateTime.now().millisecondsSinceEpoch / 1000 -
                      (path == 'sessions/needs-input/messages'
                          ? 360
                          : path == 'sessions/running/messages'
                          ? 600
                          : path == 'sessions/side-work/messages'
                          ? 1200
                          : 7200),
                },
            ],
            'pagination': {
              'offset': 0,
              'limit': int.parse(query['limit'] ?? '50'),
              'returned': includeHistory ? 1 : 0,
              'order': 'latest',
            },
          },
    rpc: (method, params) async {
      if (method == 'subagent.roster') return {'sessions': <Object>[]};
      if (method == 'session.active_list') {
        if (failed.contains(scope.profileName)) throw StateError('offline');
        return {'sessions': live[scope.profileName] ?? []};
      }
      if (method == 'projects.tree') {
        return {
          'projects': [
            {
              'id': 'sync',
              'label': 'Sync',
              'icon': 'repo',
              'color': '#A78BFA',
              'sessionIds': ['needs-input'],
            },
          ],
        };
      }
      return {};
    },
  );
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingProjectIcons': 'assets/fonts/codicons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  late _ActivityHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences preferences;
  late BotsSession bots;
  late WorkspaceRecentsSession recents;
  late BotsFixture fixture;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = _ActivityHost()..includeHistory = true;
    final saved = await SharedPreferences.getInstance();
    preferences = AppPreferences(saved);
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
      connectionIdentity: 'activity-filter-test',
      preferences: saved,
      appPreferences: preferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    host.live['main'] = [
      {
        'id': 'runtime-running',
        'session_key': 'running',
        'status': 'working',
        'last_active': DateTime.now().millisecondsSinceEpoch / 1000,
      },
      {
        'id': 'runtime-input',
        'session_key': 'needs-input',
        'status': 'waiting',
        'last_active': 1,
      },
      {
        'id': 'runtime-side',
        'session_key': 'side-work',
        'status': 'idle',
        'last_active': 2,
        'side_tasks_running': 2,
      },
    ];
    await controller.refreshRecents();
    fixture = BotsFixture();
    fixture.profiles.first['name'] = 'main';
    fixture.profiles.first['ui_meta']['hermes-bots']['title'] = 'Scout';
    fixture.profiles.first['canonical_session'] = {
      'id': 'running',
      'resolved_id': 'running',
      'preview': 'Body text must stay out of Recents',
    };
    fixture.events.add({
      'room_id': 'room-1',
      'seq': 1,
      'kind': 'message.member',
      'created_at': DateTime.now().millisecondsSinceEpoch / 1000 - 720,
      'actor': {'kind': 'member', 'id': 'atlas', 'display_name': 'Scout'},
      'payload': {'text': 'Room discussion excerpt'},
    });
    bots = BotsSession(
      (_) async => [
        BotsRepository(
          groupObservations: GroupObservations(controller.current!.scope),
          scope: controller.current!.scope,
          instance: 'Host',
          read: fixture.read,

          command: fixture.command,
          ownership: fixture.ownership,
        ),
      ],
    );
    await bots.refresh();
    recents = WorkspaceRecentsSession(controller, bots);
  });
  tearDown(() {
    recents.dispose();
    bots.dispose();
    controller.dispose();
    preferences.dispose();
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('approved identity cards in ${brightness.name} at $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final frame = GlobalKey();
        ProfileRecentChat? opened;
        List<WorkspaceRecentItem>? displayed;
        String? openedRoom;
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: RepaintBoundary(key: frame, child: child),
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('Recents')),
              body: WorkspaceActivityContent(
                recents: recents,
                visible: false,
                onOpen: (item, rows) {
                  opened = item;
                  displayed = rows;
                },
                onOpenGroup: (group) async {
                  openedRoom = group.id;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.activityProfileErrors, isEmpty);
        expect(find.byType(FilterChip), findsNothing);
        expect(find.text('Ongoing'), findsNothing);
        expect(find.text('Last 24 hours'), findsNothing);
        expect(find.textContaining('Body text'), findsNothing);
        expect(find.text('Room discussion excerpt'), findsOneWidget);
        expect(find.text('New answer'), findsWidgets);
        expect(find.text('Sync'), findsOneWidget);
        expect(find.byIcon(ProjectIconGlyphs.of('repo')), findsOneWidget);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        final botRow = find.byKey(const ValueKey('activity-main-running'));
        for (
          var wait = 0;
          wait < 20 &&
              find
                  .descendant(of: botRow, matching: find.byType(BotAvatar))
                  .evaluate()
                  .isEmpty;
          wait++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final avatar = find.descendant(
          of: botRow,
          matching: find.byType(BotAvatar),
        );
        expect(avatar, findsOneWidget);
        final unassignedRow = find.byKey(
          const ValueKey('activity-main-side-work'),
        );
        final groupRow = find.byKey(
          const ValueKey('recent-group-activity-filter-test/room-1'),
        );
        expect(
          find.descendant(of: botRow, matching: find.text('No project')),
          findsNothing,
        );
        expect(
          find.descendant(of: groupRow, matching: find.text('No project')),
          findsNothing,
        );
        final botName = find.descendant(
          of: botRow,
          matching: find.text('Scout'),
        );
        expect(botName, findsOneWidget);
        expect(
          tester.getRect(botName).right,
          lessThan(tester.getRect(avatar).left),
        );
        expect(
          find.descendant(of: botRow, matching: find.text('M')),
          findsNothing,
        );
        expect(
          find.descendant(of: botRow, matching: find.text('Running job')),
          findsNothing,
        );
        if (_capture) {
          final boundary =
              frame.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/recents-review/${brightness.name}-$scale-approved.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.scrollUntilVisible(
          unassignedRow,
          120,
          scrollable: find.byType(Scrollable),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: unassignedRow, matching: find.text('No project')),
          findsOneWidget,
        );
        final room = find.byKey(
          const ValueKey('recent-group-activity-filter-test/room-1'),
        );
        await tester.ensureVisible(room);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(of: room, matching: find.text('Research team')),
        );
        await tester.pumpAndSettle();
        expect(openedRoom, 'room-1');
        await tester.scrollUntilVisible(
          botRow,
          -120,
          scrollable: find.byType(Scrollable),
        );
        await tester.pumpAndSettle();
        await tester.tap(botName);
        await tester.pumpAndSettle();
        expect(opened?.key.sessionId, 'running');
        expect(
          displayed!.map((row) => row.chat?.key.sessionId ?? row.group!.id),
          ['needs-input', 'running', 'room-1', 'side-work', 'recent'],
        );
        expect(() => displayed!.clear(), throwsUnsupportedError);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets('retains partial status failures with usable chats', (
    tester,
  ) async {
    host.failed.add('main');
    await controller.refreshRecents();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceActivityContent(
            recents: recents,
            visible: false,
            onOpen: (_, _) {},
            onOpenGroup: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Live status could not be loaded.'), findsOneWidget);
    expect(find.text('No recent chats'), findsNothing);
    expect(find.text('Draft the setup guide'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
