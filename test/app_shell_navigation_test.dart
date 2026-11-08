import 'package:wing/core/services/group_observations.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/recent_identity_card.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'support/bots_fixture.dart';
import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/widgets/chat_notice_activity_scope.dart';
import 'package:wing/core/services/shared_draft_session.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/backup_session.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/screens/workspace_overview_content.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/screens/analytics_content.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/main.dart';

import 'support/profile_browser_fixture.dart';
import 'support/administration_fixture.dart';
import 'support/loopback_http_fixtures.dart';
import 'support/gateway_application_requests.dart';
import 'home_config_restore_test.dart'
    show createHomeFixture, homeEntryFactory, profileController;

class _ShellFixture extends ProfileBrowserFixture {
  final createdSessions = <String, List<Map<String, dynamic>>>{};

  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    ...super.sessions(profile),
    ...?createdSessions[profile],
  ];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    for (final row in sessions(profile).where((row) => row['id'] == id))
      {
        'id': 1,
        'role': 'assistant',
        'content': 'Saved reply',
        'timestamp': row['last_active'],
      },
  ];
}

void main() {
  const capture = bool.fromEnvironment('CAPTURE_MENU');
  setUpAll(() async {
    if (!capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$root/${font.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  late _ShellFixture fixture;
  late AdministrationFixture administration;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ValueNotifier<ChatNoticeActivity?> activity;
  var controllerDisposed = false;

  setUp(() async {
    controllerDisposed = false;
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.tarkilhk.wing',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    fixture = _ShellFixture();
    administration = AdministrationFixture('host');
    activity = ValueNotifier(null);
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Prestige',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'host-endpoint',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    controller.healthSession(repository: administration.server);
    await controller.initialize();
  });
  tearDown(() {
    if (!controllerDisposed) controller.dispose();
    activity.dispose();
    appPreferences.dispose();
    administration.server.close();
  });

  Future<void> show(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.light,
    Widget? home,
    Size viewport = const Size(360, 800),
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(brightness),
        builder: (context, child) => RepaintBoundary(
          key: const ValueKey('menu-capture'),
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: ChatNoticeActivityScope(activity: activity, child: child!),
          ),
        ),
        home:
            home ??
            ProfileWorkspaceScreen(
              controller: controller,
              createBotsSession: () {
                final bots = BotsFixture();
                return BotsSession(
                  (_) async => [
                    BotsRepository(
                      groupObservations: GroupObservations(
                        controller.current!.scope,
                      ),
                      scope: controller.current!.scope,
                      instance: 'Host',
                      read: bots.read,

                      command: bots.command,
                      ownership: bots.ownership,
                    ),
                  ],
                );
              },
              onConnections: () {},
            ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) return;
    for (final widget in tester.widgetList<Image>(find.byType(Image))) {
      await tester.runAsync(
        () => precacheImage(
          widget.image,
          tester.element(find.byType(MaterialApp)),
        ),
      );
    }
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('menu-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/menu-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> navigate(WidgetTester tester, AppDestination destination) async {
    if (find.byType(AppDrawer).evaluate().isEmpty) {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
    }
    expect(find.byType(AppDrawer), findsOneWidget);
    final item = find.byKey(ValueKey('nav-${destination.name}'));
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    expect(item.hitTestable(), findsOneWidget);
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(find.byType(AppDrawer), findsNothing);
  }

  for (final exit in ['drawer', 'system Back', 'Chats menu']) {
    final systemBack = exit == 'system Back';
    final chatsMenu = exit == 'Chats menu';
    testWidgets(
      'chat opened from Recents returns to ${chatsMenu ? 'Chats' : 'Recents'} through $exit',
      (tester) async {
        final chat = await controller.createChat(canDispatch: () => true);
        emitChatEvent(controller, chat, 'session.title', {
          'session_id': chat.key.sessionId,
          'title': 'Recent conversation',
        });
        fixture.createdSessions[chat.key.workspace.profileName] = [
          {
            'id': chat.key.sessionId,
            'title': 'Recent conversation',
            'profile': chat.key.workspace.profileName,
            'last_active': fixture.now,
          },
        ];
        emitChatEvent(controller, chat, 'approval', {
          'request_id': 'fixture-approval',
          'command': 'Review fixture command',
        });
        await show(tester);
        await navigate(tester, AppDestination.activity);
        expect(find.byType(FilterChip), findsNothing);
        await tester.ensureVisible(find.text('Recent conversation'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Recent conversation'));
        await tester.pumpAndSettle();
        expect(find.byType(WorkspaceActivityContent), findsNothing);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          expect(find.byIcon(Icons.arrow_back), findsNothing);
          await tester.tap(find.byTooltip('Open navigation menu'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(ValueKey(chatsMenu ? 'nav-chats' : 'nav-activity')),
          );
        }
        await tester.pumpAndSettle();
        if (chatsMenu) {
          expect(find.byType(WorkspaceActivityContent), findsNothing);
          expect(find.byTooltip('New chat'), findsOneWidget);
          expect(controller.current!.chat, isNull);
          return;
        }
        expect(find.byType(WorkspaceActivityContent), findsOneWidget);
        if (systemBack) {
          expect(find.text('Recents'), findsOneWidget);
          expect(controller.current!.chat, isNull);
        }
        expect(find.byType(FilterChip), findsNothing);
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('recents ${brightness.name} at $scale', (tester) async {
        final chat = await controller.createChat(canDispatch: () => true);
        emitChatEvent(controller, chat, 'session.title', {
          'session_id': chat.key.sessionId,
          'title': 'Choose deployment region',
        });
        fixture.createdSessions[chat.key.workspace.profileName] = [
          {
            'id': chat.key.sessionId,
            'title': 'Choose deployment region',
            'profile': chat.key.workspace.profileName,
            'last_active': fixture.now,
          },
        ];
        emitChatEvent(controller, chat, 'approval', {
          'request_id': 'fixture-approval',
          'command': 'Review fixture command',
        });
        await show(tester, scale: scale, brightness: brightness);
        await navigate(tester, AppDestination.activity);
        expect(find.text('Recents'), findsOneWidget);
        expect(find.byType(ServerConnectionLabel), findsOneWidget);
        expect(
          tester
              .widget<ServerConnectionLabel>(find.byType(ServerConnectionLabel))
              .label,
          controller.connection.label,
        );
        expect(find.byType(FilterChip), findsNothing);
        await tester.scrollUntilVisible(
          find.text('Choose deployment region'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Choose deployment region'), findsOneWidget);
        await snapshot(tester, 'recents-${brightness.name}-$scale');
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pump();
        final pending = Completer<void>();
        final cardPosition = tester.getTopLeft(
          find.byType(RecentIdentityCard).first,
        );
        fixture.pageDelays[('personal', 0)] = pending;
        final refresh = controller.refreshRecents();
        await tester.pump();
        expect(find.byType(StudioLoading), findsNothing);
        expect(
          tester.getTopLeft(find.byType(RecentIdentityCard).first),
          cardPosition,
        );
        await snapshot(tester, 'recents-loading-${brightness.name}-$scale');
        pending.complete();
        await refresh;
        fixture.pageFailures.addAll([('personal', 0), ('work', 0)]);
        await controller.refreshRecents();
        await tester.pumpAndSettle();
        expect(find.text('Recents unavailable.'), findsNothing);
        expect(
          find.text('Recent chats unavailable for personal.'),
          findsOneWidget,
        );
        await snapshot(tester, 'recents-errors-${brightness.name}-$scale');
        expect(tester.takeException(), isNull);
      });

      testWidgets('instances ${brightness.name} at $scale', (tester) async {
        final homeFixture = await createHomeFixture();
        final manager = homeFixture.manager;
        final appPreferences = homeFixture.appPreferences;
        await manager.saveConnection('Homelab', 'hermes.local', 8642, '');
        await show(
          tester,
          scale: scale,
          brightness: brightness,
          home: HomeScreen(
            createSharedDraftSession: (entry) => SharedDraftSession(
              connectionManager: manager,
              entrySession: entry,
              shareIntents: null,
            ),
            createEntrySession: homeEntryFactory(
              tester,
              manager,
              appPreferences,
              create: (connection) =>
                  profileController(connection, manager.prefs, appPreferences),
              launchIntents: null,
            ),
            connManager: manager,
            appPreferences: appPreferences,
            createBackupSession: () => BackupSession(
              configuration: ConfigBackupService(
                connectionManager: manager,
                appPreferences: appPreferences,
              ),
              io: ConfigBackupIo(),
            ),
          ),
        );
        expect(find.text('Hermes instances'), findsOneWidget);
        expect(find.text('Homelab'), findsOneWidget);
        final addInstanceFinder = find.byType(FloatingActionButton);
        expect(find.byTooltip('Add instance'), findsOneWidget);
        expect(addInstanceFinder, findsOneWidget);
        expect(find.text('Add instance'), findsNothing);
        expect(
          tester.widget<FloatingActionButton>(addInstanceFinder).isExtended,
          isFalse,
        );
        expect(
          find.descendant(
            of: addInstanceFinder,
            matching: find.byIcon(Icons.add),
          ),
          findsOneWidget,
        );
        expect(find.byTooltip('Backup configuration'), findsNothing);
        expect(find.byTooltip('Restore configuration'), findsNothing);
        await snapshot(tester, 'instances-${brightness.name}-$scale');
        await navigate(tester, AppDestination.settings);
        expect(find.byTooltip('Backup configuration'), findsOneWidget);
        expect(find.byTooltip('Restore configuration'), findsOneWidget);
        await snapshot(tester, 'settings-${brightness.name}-$scale');
        expect(tester.takeException(), isNull);
      });

      testWidgets('menu and analytics ${brightness.name} at $scale', (
        tester,
      ) async {
        final chat = await controller.createChat(canDispatch: () => true);
        chat.composer.editText('Keep my analytics draft');
        await show(tester, scale: scale, brightness: brightness);
        final callsBefore = fixture.calls.length;
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        final menu = find.byType(AppDrawer);
        final tiles = tester
            .widgetList<ListTile>(
              find.descendant(of: menu, matching: find.byType(ListTile)),
            )
            .toList();
        expect(tiles.map((tile) => tile.key), [
          for (final name in [
            'chats',
            'activity',
            'bots',
            'connections',
            'settings',
            'administration',
            'health',
            'analytics',
          ])
            ValueKey('nav-$name'),
        ]);
        expect(find.text('Hermes instances'), findsOneWidget);
        await snapshot(tester, 'drawer-${brightness.name}-$scale');
        final analytics = find.byKey(const ValueKey('nav-analytics'));
        await tester.ensureVisible(analytics);
        await tester.pumpAndSettle();
        if (scale == 2) {
          await snapshot(tester, 'drawer-bottom-${brightness.name}');
        }
        await tester.tap(analytics);
        await tester.pumpAndSettle();
        expect(find.byType(HermesAnalyticsContent), findsOneWidget);
        expect(find.text('Hermes analytics'), findsOneWidget);
        expect(find.byTooltip('Choose profile'), findsOneWidget);
        expect(find.byTooltip('Refresh profile status'), findsNothing);
        expect(fixture.calls.length, callsBefore);
        await snapshot(tester, 'analytics-${brightness.name}-$scale');
        await navigate(tester, AppDestination.health);
        expect(find.text('Usage'), findsNothing);
        await navigate(tester, AppDestination.chats);
        expect(controller.current!.chat, isNull);
        expect(find.byTooltip('New chat'), findsOneWidget);
        expect(chat.composer.observation.text, 'Keep my analytics draft');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('administration header refresh reaches its current content', (
    tester,
  ) async {
    await show(tester);
    await navigate(tester, AppDestination.administration);
    final before =
        administration.requests.length + administration.rpcRequests.length;
    await tester.tap(find.byTooltip('Refresh administration'));
    for (
      var attempt = 0;
      attempt < 200 && controller.refreshingWorkspace;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.refreshingWorkspace, isFalse);
    await tester.pumpAndSettle();
    expect(
      administration.requests.length + administration.rpcRequests.length,
      greaterThan(before),
    );
    expect(find.byKey(const ValueKey('administration-health')), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Refresh overview', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  List<MethodCall> recordPlatformCalls(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    return calls;
  }

  Future<void> expectMenuThenExit(WidgetTester tester) async {
    final calls = recordPlatformCalls(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AppDrawer), findsOneWidget);
    expect(
      calls.where((call) => call.method == 'SystemNavigator.pop'),
      isEmpty,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == 'SystemNavigator.pop'),
      hasLength(1),
    );
  }

  for (final destination in [
    AppDestination.activity,
    AppDestination.settings,
    AppDestination.administration,
    AppDestination.health,
    AppDestination.analytics,
  ]) {
    testWidgets('${destination.label} Back opens the menu, then exits', (
      tester,
    ) async {
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('Keep my draft');
      await show(tester);
      await navigate(tester, destination);
      await expectMenuThenExit(tester);
      expect(controller.current!.chat, same(chat));
      expect(chat.composer.observation.text, 'Keep my draft');
      expect(controller.visible, isFalse);
      expect(
        tester.widget<AppDrawer>(find.byType(AppDrawer)).selected,
        destination,
      );
    });
  }

  for (final destination in [
    AppDestination.connections,
    AppDestination.settings,
  ]) {
    testWidgets('Home ${destination.label} Back opens the menu, then exits', (
      tester,
    ) async {
      final manager = await ConnectionManager.create(controller.preferences);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            createSharedDraftSession: (entry) => SharedDraftSession(
              connectionManager: manager,
              entrySession: entry,
              shareIntents: null,
            ),
            createEntrySession: homeEntryFactory(
              tester,
              manager,
              appPreferences,
              create: (connection) =>
                  profileController(connection, manager.prefs, appPreferences),
              launchIntents: null,
            ),
            connManager: manager,
            appPreferences: appPreferences,
            createBackupSession: () => BackupSession(
              configuration: ConfigBackupService(
                connectionManager: manager,
                appPreferences: appPreferences,
              ),
              io: ConfigBackupIo(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await navigate(tester, destination);
      await expectMenuThenExit(tester);
      expect(
        tester.widget<AppDrawer>(find.byType(AppDrawer)).selected,
        destination,
      );
    });
  }

  testWidgets('administration detail pages unwind before opening the menu', (
    tester,
  ) async {
    final calls = recordPlatformCalls(tester);
    await show(tester);
    await navigate(tester, AppDestination.administration);
    await tester.ensureVisible(find.text('Behavior'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Behavior'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Execution'));
    await tester.pumpAndSettle();
    expect(find.text('Approval policy'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Approval policy'), findsOneWidget);
    expect(find.byType(AppDrawer), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HermesAdministrationContent), findsOneWidget);
    expect(find.byType(HermesHealthContent), findsNothing);
    expect(find.byTooltip('Refresh administration'), findsOneWidget);
    expect(find.byType(AppDrawer), findsNothing);
    expect(
      calls.where((call) => call.method == 'SystemNavigator.pop'),
      isEmpty,
    );
    await expectMenuThenExit(tester);
  });

  testWidgets(
    'settings and administration preserve the open chat and unsent draft',
    (tester) async {
      final chat = await controller.createChat(canDispatch: () => true);
      chat.composer.editText('Keep this unsent');
      await show(tester);
      await navigate(tester, AppDestination.settings);
      expect(controller.visible, isFalse);
      expect(controller.current!.chat, same(chat));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AppDrawer), findsOneWidget);
      expect(controller.visible, isFalse);
      await tester.tap(find.byKey(const ValueKey('nav-chats')));
      await tester.pumpAndSettle();
      expect(controller.current!.chat, isNull);
      expect(find.byTooltip('New chat'), findsOneWidget);
      expect(chat.composer.observation.text, 'Keep this unsent');
      await controller.openSession(chat.key);
      await tester.pumpAndSettle();
      expect(find.text('Keep this unsent'), findsOneWidget);
      await navigate(tester, AppDestination.administration);
      expect(find.byType(HermesAdministrationContent), findsOneWidget);
      expect(find.text('Models and reasoning'), findsOneWidget);
      await navigate(tester, AppDestination.health);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byTooltip('Refresh profile status'),
        200,
        scrollable: find.descendant(
          of: find.byKey(
            const PageStorageKey('administration-health-findings'),
          ),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.byTooltip('Refresh profile status'), findsOneWidget);
      expect(controller.current!.chat, same(chat));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AppDrawer), findsOneWidget);
      await navigate(tester, AppDestination.chats);
      expect(controller.current!.chat, isNull);
      expect(find.byTooltip('New chat'), findsOneWidget);
      expect(chat.composer.observation.text, 'Keep this unsent');
      await navigate(tester, AppDestination.health);
      await tester.pumpAndSettle();
      await navigate(tester, AppDestination.chats);
      expect(find.byTooltip('New chat'), findsOneWidget);
      expect(chat.composer.observation.text, 'Keep this unsent');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('activity opens its original profile and preserves other drafts', (
    tester,
  ) async {
    final personal = await controller.createChat(canDispatch: () => true);
    personal.composer.editText('Personal draft');
    emitChatEvent(controller, personal, 'approval', {
      'request_id': 'fixture-approval',
      'command': 'Review fixture command',
    });
    await controller.navigateProfile('work');
    final work = await controller.createChat(canDispatch: () => true);
    work.composer.editText('Work draft');
    fixture.liveSessions['personal'] = [
      {
        'id': personal.runtime.runtimeId,
        'session_key': personal.key.sessionId,
        'status': 'waiting',
      },
    ];
    fixture.createdSessions[personal.key.workspace.profileName] = [
      {
        'id': personal.key.sessionId,
        'title': personal.title,
        'profile': personal.key.workspace.profileName,
        'last_active': fixture.now,
      },
    ];
    await show(tester);
    await navigate(tester, AppDestination.activity);
    final recent = find.byKey(
      ValueKey(
        'activity-${personal.key.workspace.profileName}-${personal.key.sessionId}',
      ),
    );
    await tester.ensureVisible(recent);
    await tester.pumpAndSettle();
    await tester.tap(recent);
    await tester.pumpAndSettle();
    expect(controller.current!.scope, personal.key.workspace);
    expect(controller.current!.chat, same(personal));
    expect(find.text('Personal draft'), findsOneWidget);
    expect(work.composer.observation.text, 'Work draft');
    expect(tester.takeException(), isNull);
  });

  group('current-stock identity navigation', () {
    useRealHttpClientsForLoopbackFixtures();

    testWidgets('administration opens the selected profile editor', (
      tester,
    ) async {
      const description = 'Work profile description';
      const soul = 'Work profile SOUL.\n';
      const directory = '/fixture/profiles/work';
      const metadataPath = '$directory/profile.yaml';
      final requests = <(String, Uri)>[];
      final sockets = <WebSocket>[];
      final rpcReads = <(String, Map<String, dynamic>)>[];
      final transport = (await tester.runAsync(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          requests.add((request.method, request.uri));
          if (request.uri.path == '/api/ws') {
            final socket = await WebSocketTransformer.upgrade(request);
            sockets.add(socket);
            gatewayApplicationRequests(socket).listen((raw) {
              final rpc = jsonDecode(raw as String) as Map<String, dynamic>;
              final params = rpc['params'] as Map<String, dynamic>;
              rpcReads.add((rpc['method'] as String, params));
              final result = switch (rpc['method']) {
                'session.list' => <String, dynamic>{'sessions': []},
                'mcp.servers.status' => <String, dynamic>{
                  'servers': [
                    {
                      'name': 'docs',
                      'transport': 'http',
                      'tools': 0,
                      'connected': false,
                      'disabled': false,
                      'status': 'configured',
                      'source': 'config',
                      'plugin': null,
                      'needs_auth': false,
                    },
                  ],
                  'checked_at': DateTime.now().millisecondsSinceEpoch,
                },
                _ => throw StateError('Unexpected RPC: ${rpc['method']}'),
              };
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': rpc['id'],
                  'result': result,
                }),
              );
            });
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': 'gateway.ready',
                  'payload': {'session_authority': true},
                },
              }),
            );
            return;
          }
          request.response.headers.contentType = ContentType.json;
          Map<String, dynamic>? response;
          if (request.method == 'GET') {
            response = switch (request.uri.path) {
              '/api/config' => {
                'memory': {'memory_enabled': true, 'memory_char_limit': 2000},
                'approvals': {'mode': 'normal'},
                'compression': {'enabled': true},
                'agent': {'reasoning_effort': 'medium'},
              },
              '/api/model/info' => {
                'provider': 'example',
                'model': 'Work model',
              },
              '/api/skills' ||
              '/api/tools/toolsets' ||
              '/api/cron/jobs' => {'data': []},
              '/api/providers/oauth' => {'providers': []},
              '/api/mcp/servers' => {
                'servers': [
                  {
                    'name': 'docs',
                    'enabled': true,
                    'transport': 'http',
                    'auth': 'none',
                    'source': 'config',
                    'plugin': null,
                  },
                ],
              },
              '/api/profiles' => {
                'profiles': [
                  {'name': 'personal', 'path': '/fixture/profiles/personal'},
                  {'name': 'work', 'path': directory},
                ],
              },
              '/api/profiles/active' => {'current': 'work', 'active': 'work'},
              '/api/files/read'
                  when request.uri.queryParameters['path'] == metadataPath =>
                () {
                  final bytes = utf8.encode(
                    'description: ${jsonEncode(description)}\n',
                  );
                  return <String, dynamic>{
                    'name': 'profile.yaml',
                    'path': metadataPath,
                    'size': bytes.length,
                    'mime_type': 'application/octet-stream',
                    'data_url':
                        'data:application/octet-stream;base64,${base64Encode(bytes)}',
                  };
                }(),
              '/api/profiles/work/soul' => {'content': soul, 'exists': true},
              _ => null,
            };
          }
          if (request.method == 'POST' &&
              request.uri.path == '/api/auth/ws-ticket') {
            await request.drain<void>();
            response = {'ticket': 'fixture-ticket'};
          }
          if (response == null) {
            request.response.statusCode = 404;
          }
          request.response.write(
            jsonEncode(response ?? {'detail': 'Not found'}),
          );
          await request.response.close();
        });
        return (server: server, subscription: subscription);
      }))!;
      final server = transport.server;
      final subscription = transport.subscription;
      var fixtureClosed = false;
      Future<void> closeFixture() async {
        if (fixtureClosed) {
          return;
        }
        await tester.pumpWidget(const SizedBox.shrink());
        // The workspace owns the shared HTTP pool. Finish that lifetime before
        // Flutter checks for idle connection timers at the end of the test.
        controllerDisposed = true;
        controller.dispose();
        await tester.runAsync(() async {
          for (final socket in sockets) {
            await socket.close();
          }
          await subscription.cancel();
          await server.close(force: true);
        });
        await tester.pump();
        fixtureClosed = true;
      }

      addTearDown(closeFixture);

      controller.dispose();
      controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Prestige',
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
            apiKey: '',
            dashboardPortOverride: server.port,
            dashboardProxied: true,
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'shell',
        preferences: await SharedPreferences.getInstance(),
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      await controller.initialize();
      await controller.switchProfile('work');
      expect(controller.current!.scope.profileName, 'work');
      await show(tester);
      await navigate(tester, AppDestination.administration);
      const parentPaths = {
        '/api/config',
        '/api/model/info',
        '/api/skills',
        '/api/tools/toolsets',
        '/api/cron/jobs',
        '/api/providers/oauth',
        '/api/mcp/servers',
      };
      // The real parent overview loads only its captured profile observations.
      // Finish those observations before marking the editor's separate reads.
      for (var attempt = 0; attempt < 500; attempt++) {
        await tester.pump();
        final seen = requests.map((request) => request.$2.path).toSet();
        if (seen.containsAll(parentPaths) &&
            rpcReads.any((read) => read.$1 == 'mcp.servers.status') &&
            find.text('Work model').evaluate().isNotEmpty &&
            find.textContaining('Loading').evaluate().isEmpty) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.text('Work model'), findsOneWidget);
      expect(find.textContaining('Loading'), findsNothing);
      final parentReads = requests
          .where((request) => parentPaths.contains(request.$2.path))
          .toList();
      expect(parentReads, hasLength(parentPaths.length));
      for (final read in parentReads) {
        expect(read.$1, 'GET');
        expect(read.$2.queryParameters, {'profile': 'work'});
      }
      await tester.pumpAndSettle();
      expect(rpcReads.map((read) => read.$1), [
        'session.list',
        'mcp.servers.status',
      ]);
      expect(rpcReads[0].$2, {'profile': 'work', 'limit': 1});
      expect(rpcReads[1].$2, {'profile': 'work'});
      expect(sockets, hasLength(1));
      expect(
        requests
            .where((request) => request.$1 != 'GET')
            .map((request) => (request.$1, request.$2.path)),
        [('POST', '/api/auth/ws-ticket')],
      );
      final identityRpcStart = rpcReads.length;
      final identityStart = requests.length;
      await tester.tap(find.text('Identity'));
      final descriptionField = find.byKey(
        const ValueKey('profile-description-field'),
      );
      final soulField = find.byKey(const ValueKey('profile-soul-field'));
      // Drain both the widget zone and the real loopback transport before
      // checking the observation, rather than settling an active spinner.
      for (var attempt = 0; attempt < 500; attempt++) {
        await tester.pump();
        if (descriptionField.evaluate().isNotEmpty &&
            soulField.evaluate().isNotEmpty &&
            tester.widget<TextField>(descriptionField).controller!.text ==
                description &&
            tester.widget<TextField>(soulField).controller!.text == soul) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(descriptionField, findsOneWidget);
      expect(soulField, findsOneWidget);
      expect(
        tester.widget<TextField>(descriptionField).controller!.text,
        description,
      );
      expect(tester.widget<TextField>(soulField).controller!.text, soul);
      await tester.pumpAndSettle();
      final identityReads = requests.skip(identityStart).toList();
      expect(identityReads.map((request) => (request.$1, request.$2.path)), [
        ('GET', '/api/profiles'),
        ('GET', '/api/profiles/active'),
        ('GET', '/api/files/read'),
        ('GET', '/api/profiles/work/soul'),
      ]);
      expect(identityReads[2].$2.queryParameters, {'path': metadataPath});
      expect(rpcReads, hasLength(identityRpcStart));
      expect(sockets, hasLength(1));
      expect(
        fixture.calls.where(
          (call) =>
              call.$2 == 'profiles.describe' || call.$2 == 'profiles.configure',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await closeFixture();
      expect(tester.takeException(), isNull);
    });
  });

  for (final openChat in [false, true]) {
    testWidgets(
      openChat
          ? 'Back returns from a conversation to Chats, then opens the menu and exits'
          : 'Back opens the menu from Chats, then exits',
      (tester) async {
        final chat = openChat
            ? await controller.createChat(canDispatch: () => true)
            : null;
        chat?.composer.editText('Still here');
        final platformCalls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => platformCalls.add(call),
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Text('Connections underneath')),
          ),
        );
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => ProfileWorkspaceScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        if (openChat) {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(AppDrawer), findsNothing);
          expect(find.byTooltip('Back to sessions'), findsNothing);
          expect(controller.current!.chat, isNull);
          expect(find.text('Connections underneath'), findsNothing);
          expect(chat!.composer.observation.text, 'Still here');
          expect(
            platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
            isEmpty,
          );
        }

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(AppDrawer), findsOneWidget);
        expect(find.text('Connections underneath'), findsNothing);
        expect(controller.current!.chat, isNull);
        expect(
          platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
          isEmpty,
        );

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
          hasLength(1),
        );
        expect(find.text('Connections underneath'), findsNothing);
        expect(controller.current!.chat, isNull);
        expect(chat?.composer.observation.text, openChat ? 'Still here' : null);
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('Settings title is readable in $brightness at ${scale}x', (
        tester,
      ) async {
        final homeFixture = await createHomeFixture();
        final manager = homeFixture.manager;
        final settings = homeFixture.appPreferences;
        await show(
          tester,
          scale: scale,
          brightness: brightness,
          viewport: const Size(320, 640),
          home: HomeScreen(
            createSharedDraftSession: (entry) => SharedDraftSession(
              connectionManager: manager,
              entrySession: entry,
              shareIntents: null,
            ),
            createEntrySession: homeEntryFactory(
              tester,
              manager,
              settings,
              create: (connection) =>
                  profileController(connection, manager.prefs, settings),
              launchIntents: null,
            ),
            connManager: manager,
            appPreferences: settings,
            createBackupSession: () => BackupSession(
              configuration: ConfigBackupService(
                connectionManager: manager,
                appPreferences: settings,
              ),
              io: ConfigBackupIo(),
            ),
          ),
        );
        await navigate(tester, AppDestination.settings);
        await snapshot(tester, 'settings-title-${brightness.name}-$scale');
        for (final action in [
          'Backup configuration',
          'Restore configuration',
        ]) {
          expect(find.byTooltip(action).hitTestable(), findsOneWidget);
        }
        final title = find.text('App settings');
        final header = tester.getRect(
          find.descendant(
            of: find.byType(WingAppBar),
            matching: find.byType(NavigationToolbar),
          ),
        );
        final paragraph = tester.renderObject<RenderParagraph>(title);
        final lines = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: 'App settings'.length),
        );
        expect(lines, isNotEmpty);
        for (final line in lines) {
          final bounds = line.toRect().shift(
            paragraph.localToGlobal(Offset.zero),
          );
          expect(
            header.contains(bounds.topLeft),
            isTrue,
            reason: 'The title must not paint above its header.',
          );
          expect(
            header.contains(bounds.bottomRight),
            isTrue,
            reason: 'The full Settings title must fit within its header.',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('drawer and settings fit a narrow device at large text size', (
    tester,
  ) async {
    await show(tester, scale: 2);
    await navigate(tester, AppDestination.settings);
    await tester.scrollUntilVisible(find.text('Theme'), 200);
    expect(find.text('Theme'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await navigate(tester, AppDestination.administration);
    expect(find.byType(HermesAdministrationContent), findsOneWidget);
    expect(find.text('Models and reasoning'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnected shell offers setup and device settings only', (
    tester,
  ) async {
    final manager = await ConnectionManager.create(controller.preferences);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          createSharedDraftSession: (entry) => SharedDraftSession(
            connectionManager: manager,
            entrySession: entry,
            shareIntents: null,
          ),
          createEntrySession: homeEntryFactory(
            tester,
            manager,
            appPreferences,
            create: (connection) =>
                profileController(connection, manager.prefs, appPreferences),
            launchIntents: null,
          ),
          connManager: manager,
          appPreferences: appPreferences,
          createBackupSession: () => BackupSession(
            configuration: ConfigBackupService(
              connectionManager: manager,
              appPreferences: appPreferences,
            ),
            io: ConfigBackupIo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Your agent, with you'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    for (final destination in [
      AppDestination.chats,
      AppDestination.activity,
      AppDestination.administration,
      AppDestination.health,
      AppDestination.analytics,
    ]) {
      expect(
        tester
            .widget<ListTile>(find.byKey(ValueKey('nav-${destination.name}')))
            .enabled,
        isFalse,
      );
    }
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Theme'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AppDrawer), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
