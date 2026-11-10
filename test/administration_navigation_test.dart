import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/services/versions_controller.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/models/profile_colors.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/screens/administration/administration_content.dart';
import 'package:wing/core/widgets/profile_selector.dart';
import 'support/administration_fixture.dart';
import 'support/administration_design_fixture.dart';
import 'support/backend_update_channel_fixture.dart';
import 'support/scheduled_tasks_fixture.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'support/profile_browser_fixture.dart';
import 'package:wing/core/services/profile_gateway.dart';

class _AdministrationProfilesFixture extends ProfileBrowserFixture {
  ProfileDiscovery discovery = const ProfileDiscovery(
    profiles: [
      HermesProfile(name: 'personal'),
      HermesProfile(name: 'work'),
    ],
    currentName: 'personal',
    activeName: 'personal',
  );
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final wire = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: () async => discovery,
      get: wire.read,
      rpc: wire.call,
    );
  }
}

class _UpdateAdministrationFixture extends AdministrationFixture {
  final channels = BackendUpdateChannelFixture();

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    if (method == 'GET' && path == 'health') {
      requests.add((method, path, {...query}, body));
      return {
        'ok': true,
        'version': updateCheck['current_version'],
        'commit': BackendUpdateChannelFixture.currentSha,
      };
    }
    if (method == 'GET' && path == 'hermes/update/check') {
      channels.fetchedAt++;
    }
    final channelRead = method != 'GET'
        ? null
        : path == 'profiles'
        ? {
            'profiles': [
              for (final name in configs.keys)
                {'name': name, 'path': BackendUpdateChannelFixture.home},
            ],
          }
        : channels.read(path, query);
    if (channelRead == null) return super.send(method, path, query, body);
    requests.add((method, path, {...query}, body == null ? null : {...body}));
    return channelRead;
  }
}

void main() {
  const capture = bool.fromEnvironment('CAPTURE_ADMINISTRATION');
  if (capture) {
    setUpAll(() async {
      const root = String.fromEnvironment('CAPTURE_FONT_DIR');
      for (final font in {
        'Roboto': 'roboto-regular.ttf',
        'MaterialIcons': 'materialicons-regular.otf',
        'monospace': 'monospace.ttf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(
                '$root/${font.value}',
              ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
            ))
            .load();
      }
    });
  }
  late ProfileWorkspaceController controller;
  late _AdministrationProfilesFixture profiles;
  late AppPreferences appPreferences;
  late AdministrationFixture admin;
  late GlobalKey<ScaffoldState> shellKey;
  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.tarkilhk.wing',
      version: '1.0.1',
      buildNumber: '2260',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({});
    profiles = _AdministrationProfilesFixture();
    admin = AdministrationFixture();
    shellKey = GlobalKey<ScaffoldState>();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: admin.server.connectionId,
          label: 'Home server',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: admin.server.connectionIdentity,
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: profiles.gateway,
    );
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });
  Future<void> show(
    WidgetTester tester,
    Brightness brightness, {
    double scale = 1,
    double width = 390,
    WorkspaceAccent accent = WorkspaceAccent.teal,
    bool healthOnly = false,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('admin-preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: profileWorkspaceTheme(wingTheme(brightness), accent: accent),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            key: shellKey,
            drawer: AppDrawer(
              selected: healthOnly
                  ? AppDestination.health
                  : AppDestination.administration,
              onSelected: (_) {},
              access: controller.access,
              connectionStatus: controller.connectionStatus,
              versionsControllerFactory: (_) =>
                  VersionsController(gateway: admin.server.gateway('default')),
            ),
            body: healthOnly
                ? HermesHealthContent(
                    onOpenMenu: () => shellKey.currentState!.openDrawer(),
                    onOpenSession: (_) async {},
                    controller: controller,
                    repository: admin.server,
                    onConnections: () {},
                  )
                : HermesAdministrationContent(
                    onOpenMenu: () => shellKey.currentState!.openDrawer(),
                    onOpenSession: (_) async {},
                    controller: controller,
                    repository: admin.server,
                    onConnections: () {},
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<Finder> showProfileRefresh(WidgetTester tester) async {
    final refresh = find.byTooltip('Refresh profile status');
    await tester.scrollUntilVisible(
      refresh,
      200,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(refresh.hitTestable(), findsOneWidget);
    return refresh;
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    // Asset decoding runs outside the widget test's fake clock.
    for (final element in find.byType(Image).evaluate()) {
      final widget = element.widget as Image;
      await tester.runAsync(() => precacheImage(widget.image, element));
    }
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('admin-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/administration-preview/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('ordinary Administration does not start retained Health checks', (
    tester,
  ) async {
    await show(tester, Brightness.dark);
    expect(find.byType(HermesAdministrationContent), findsOneWidget);
    expect(
      controller.healthSession(repository: admin.server).overviews,
      isEmpty,
    );
    expect(
      admin.requests.where((request) => request.$2.startsWith('ops/')),
      isEmpty,
    );
    expect(
      admin.rpcRequests.where((request) => request.$2 == 'setup.runtime_check'),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'header refresh reloads overview reads without duplicate action',
    (tester) async {
      await show(tester, Brightness.dark);
      admin.requests.clear();
      final refresh = find.byWidgetPredicate(
        (widget) =>
            widget is IconButton && widget.tooltip == 'Refresh administration',
      );
      await tester.tap(find.byTooltip('Refresh administration'));
      await tester.pump();
      // Reconnect joins journal work created by the async fixture setup. Let
      // its real event queue advance while observing the actual control state.
      for (
        var attempt = 0;
        attempt < 40 && tester.widget<IconButton>(refresh).onPressed == null;
        attempt++
      ) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      for (final endpoint in [
        'config',
        'model/info',
        'skills',
        'tools/toolsets',
        'providers/oauth',
        'mcp/servers',
        'cron/jobs',
      ]) {
        expect(
          admin.requests.where((r) => r.$1 == 'GET' && r.$2 == endpoint),
          hasLength(1),
          reason: endpoint,
        );
      }
      expect(find.text('Refresh overview', skipOffstage: false), findsNothing);
      expect(admin.requests.where((r) => r.$1 != 'GET'), isEmpty);
    },
  );

  testWidgets(
    'Health entry performs diagnostics without switching server profile',
    (tester) async {
      await show(tester, Brightness.dark, healthOnly: true);
      await showProfileRefresh(tester);
      expect(admin.requests.where((r) => r.$2 == 'profiles/active'), isEmpty);
      expect(
        admin.requests.where((r) => r.$1 != 'GET').map((r) => (r.$1, r.$2)),
        [('POST', 'ops/doctor'), ('POST', 'ops/security-audit')],
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning from an editor does not refresh a newly selected profile',
    (tester) async {
      await show(tester, Brightness.dark);
      try {
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) => widget is TextField && !widget.readOnly,
          ),
          'Memory budget',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Memory budget').last);
        await tester.pumpAndSettle();
        expect(find.text('Memory settings'), findsOneWidget);
        expect(find.text('Server A / personal'), findsOneWidget);
        expect(
          admin.requests.where(
            (request) =>
                request.$1 == 'GET' &&
                request.$2 == 'config' &&
                request.$3['profile'] == 'personal',
          ),
          isNotEmpty,
        );

        expect(await controller.switchProfile('work'), isTrue);
        await tester.pumpAndSettle();
        expect(controller.current?.scope.profileName, 'work');
        // The open editor keeps its original scope while the underlying
        // Administration route has finished loading the newly selected owner.
        expect(find.text('Server A / personal'), findsOneWidget);
        expect(
          admin.requests.where(
            (request) =>
                request.$1 == 'GET' &&
                request.$2 == 'config' &&
                request.$3['profile'] == 'work',
          ),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        final readsBeforeReturn = admin.requests.length;
        final rpcBeforeReturn = admin.rpcRequests.length;

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(HermesAdministrationContent), findsOneWidget);
        expect(controller.current?.scope.profileName, 'work');
        expect(
          tester
              .widget<ProfileSelector>(find.byType(ProfileSelector))
              .selectedProfile,
          'work',
        );
        expect(tester.takeException(), isNull);
        expect(
          admin.requests
              .skip(readsBeforeReturn)
              .where((request) => request.$3['profile'] == 'work'),
          isEmpty,
          reason: 'Returning from the personal editor cannot refresh work.',
        );
        expect(
          admin.rpcRequests
              .skip(rpcBeforeReturn)
              .where((request) => request.$1 == 'work'),
          isEmpty,
        );
        expect(admin.requests.where((request) => request.$1 != 'GET'), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'direct profile choices retain canonical administration ownership',
    (tester) async {
      await show(tester, Brightness.dark);
      expect(find.byType(ProfileSelector), findsOneWidget);
      expect(find.text('Change'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('profile-work')));
      await tester.pumpAndSettle();
      expect(controller.current?.scope.profileName, 'work');
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester
            .widget<ProfileSelector>(find.byType(ProfileSelector))
            .selectedProfile,
        'work',
      );
      await tester.tap(find.text('Memory'));
      await tester.pumpAndSettle();
      expect(
        admin.requests
            .where((r) => r.$2 == 'learning/graph')
            .last
            .$3['profile'],
        'work',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (brightness, scale, width) in [
    (Brightness.light, 1.0, 390.0),
    (Brightness.dark, 1.0, 390.0),
    (Brightness.light, 2.0, 320.0),
    (Brightness.dark, 2.0, 320.0),
  ]) {
    testWidgets('profile color picker ${brightness.name} $scale', (
      tester,
    ) async {
      await show(tester, brightness, scale: scale, width: width);
      await tester.ensureVisible(find.byKey(const ValueKey('profile-work')));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('profile-work')));
      await tester.pumpAndSettle();
      expect(find.text('Color for work'), findsOneWidget);
      await screenshot(tester, '${brightness.name}-$scale-profile-colors');
      await tester.tap(find.byKey(const ValueKey('profile-color-8')));
      await tester.pumpAndSettle();
      expect(
        appPreferences
            .profileColorsFor(controller.connectionIdentity)
            .value
            .profiles['work']!
            .selected,
        ProfileColorChoice.blue,
      );
      await screenshot(tester, '${brightness.name}-$scale-profile-blue');
      expect(tester.takeException(), isNull);
    });
  }

  for (final mode in ['light', 'dark', 'narrow']) {
    testWidgets('profile brief and attention hierarchy $mode', (tester) async {
      final fixture = AdministrationDesignFixture();
      admin = fixture;
      fixture.jobs.add(
        taskJson(
          id: 'next',
          name: 'Morning research and a deliberately long project name',
        )..['next_run_at'] = '2026-09-18T01:00:00Z',
      );
      profiles.discovery = ProfileDiscovery(
        profiles: [
          HermesProfile(
            name: 'personal',
            displayName: 'Personal',
            description: fixture.description,
          ),
          const HermesProfile(
            name: 'work',
            displayName: 'Client research and planning',
          ),
        ],
        currentName: 'personal',
        activeName: 'personal',
      );
      await controller.switchProfile('personal');
      await show(
        tester,
        mode == 'light' ? Brightness.light : Brightness.dark,
        width: mode == 'narrow' ? 320 : 390,
        scale: mode == 'narrow' ? 2 : 1,
      );
      expect(find.text(fixture.description), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-brief')), findsNothing);
      expect(find.text('Describe this agent'), findsNothing);
      await screenshot(tester, '$mode-profile-brief');
      await tester.scrollUntilVisible(
        find.text('Access and connectors'),
        200,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Setup needed'), findsOneWidget);
      expect(find.text('Sign-in expired'), findsOneWidget);
      await screenshot(tester, '$mode-profile-attention');
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('versions and updates ${brightness.name} at $scale text', (
        tester,
      ) async {
        admin = _UpdateAdministrationFixture();
        await show(
          tester,
          brightness,
          scale: scale,
          width: scale == 2 ? 320 : 390,
        );
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('menu-server-version')),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.sync), findsOneWidget);
        await screenshot(tester, '${brightness.name}-$scale-versions-entry');
        final checksBefore = admin.requests
            .where((r) => r.$2 == 'hermes/update/check')
            .length;
        await tester.tap(find.byKey(const ValueKey('menu-server-version')));
        await tester.pumpAndSettle();
        expect(find.text('1.2.3'), findsOneWidget);
        expect(
          find.text('Update available · 3 commits behind main'),
          findsOneWidget,
        );
        expect(find.byTooltip('Reconnect MCP tools'), findsNothing);
        expect(find.byTooltip('Check update progress'), findsNothing);
        expect(
          admin.requests.where((r) => r.$2 == 'hermes/update/check').length,
          checksBefore + 1,
        );
        await screenshot(tester, '${brightness.name}-$scale-versions');
        await tester.ensureVisible(find.byTooltip('Changes in this update'));
        await tester.pumpAndSettle();
        final requestCount = admin.requests.length;
        await tester.tap(find.byTooltip('Changes in this update'));
        await tester.pumpAndSettle();
        expect(find.text('Showing 2 of 3 commits'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Keep scheduled tasks running after reconnecting'),
          160,
          scrollable: find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Keep scheduled tasks running after reconnecting'),
          findsOneWidget,
        );
        expect(find.text('Commit: abc1234'), findsNothing);
        expect(admin.requests, hasLength(requestCount));
        await screenshot(tester, '${brightness.name}-$scale-changes');
        await tester.scrollUntilVisible(
          find.text('Commit details'),
          -160,
          scrollable: find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Commit details'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Commit: abc1234'),
          160,
          scrollable: find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Commit: abc1234'), findsOneWidget);
        await screenshot(tester, '${brightness.name}-$scale-changes-details');
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshot(tester, '${brightness.name}-$scale-changes-bottom');
        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('Update backend'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'administration and Health entry fit ${brightness.name} and preserve ownership',
      (tester) async {
        await show(tester, brightness);
        expect(find.text('Models and reasoning'), findsOneWidget);
        expect(find.text('Identity'), findsOneWidget);
        await screenshot(tester, '${brightness.name}-profile');
        expect(find.byType(TabBar), findsNothing);
        expect(find.text('Profiles'), findsNothing);
        expect(find.text('Versions & updates'), findsNothing);
        await show(tester, brightness, scale: 2, width: 320);
        expect(tester.takeException(), isNull);
        await screenshot(tester, '${brightness.name}-profile-large-text');
        await show(tester, brightness, healthOnly: true);
        await showProfileRefresh(tester);
        await screenshot(tester, '${brightness.name}-health-profile');
        await tester.scrollUntilVisible(
          find.text('Server'),
          -250,
          scrollable: find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Runtime profile:'), findsNothing);
        expect(find.byTooltip('Run all diagnostics'), findsOneWidget);
        expect(admin.requests.where((r) => r.$2 == 'profiles/active'), isEmpty);
        await screenshot(tester, '${brightness.name}-health');
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('all root owners remain reachable at 320dp and 200 percent', (
    tester,
  ) async {
    await show(tester, Brightness.dark, scale: 2, width: 320);
    await screenshot(tester, 'narrow-profile');
    await tester.scrollUntilVisible(
      find.text('Scheduled tasks'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    await screenshot(tester, 'narrow-profile-bottom');
    await show(tester, Brightness.dark, scale: 2, width: 320, healthOnly: true);
    await screenshot(tester, 'narrow-health');
    await tester.scrollUntilVisible(
      find.text('Doctor'),
      100,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    await screenshot(tester, 'narrow-health-runtime');
    expect(tester.takeException(), isNull);
  });

  testWidgets('runtime health remains available without a selected profile', (
    tester,
  ) async {
    final previous = controller;
    controller = ProfileWorkspaceController(
      access: previous.access,
      connectionIdentity: 'unselected-administration',
      preferences: previous.preferences,
      appPreferences: appPreferences,
      gatewayFactory: profiles.gateway,
    );
    previous.dispose();
    expect(controller.current, isNull);
    await show(tester, Brightness.dark, scale: 1.3, healthOnly: true);
    expect(find.byType(TabBar), findsNothing);
    expect(find.textContaining('Runtime profile:'), findsNothing);
    expect(find.byTooltip('Run all diagnostics'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'large-text-missing-profile');
  });

  testWidgets('search shows owner and opens the one scoped editor', (
    tester,
  ) async {
    await show(tester, Brightness.light);
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && !widget.readOnly,
      ),
      'providers',
    );
    await tester.pumpAndSettle();
    expect(find.text('Providers'), findsNothing);
    expect(
      find.text('Profile › Access and connectors\nServer A / personal'),
      findsOneWidget,
    );
    await tester.tap(find.text('Access and connectors'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Provider access'));
    await tester.pumpAndSettle();
    expect(find.text('Profile access'), findsOneWidget);
    expect(find.text('Server A / personal'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && !widget.readOnly,
      ),
      'Memory budget',
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Profile › Memory › Memory settings\nServer A / personal'),
      findsOneWidget,
    );
    await tester.tap(find.text('Memory budget').last);
    await tester.pumpAndSettle();
    expect(find.text('Server A / personal'), findsOneWidget);
    expect(find.text('Memory settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.tap(find.byType(TextFormField).last);
    await tester.pumpAndSettle();
    await screenshot(tester, 'light-editor-keyboard');
    expect(find.byTooltip('Save changes').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'profile management scrolls after the last profile ${brightness.name} $scale',
        (tester) async {
          profiles.discovery = const ProfileDiscovery(
            profiles: [
              HermesProfile(name: 'personal'),
              HermesProfile(name: 'client-work'),
              HermesProfile(name: 'reminder-inbox'),
              HermesProfile(name: 'last-profile'),
            ],
            currentName: 'personal',
            activeName: 'personal',
          );
          await controller.switchProfile('personal');
          await show(
            tester,
            brightness,
            scale: scale,
            width: scale == 2 ? 320 : 390,
          );
          final manage = find.byTooltip('Manage profiles');
          final selector = find.byKey(const ValueKey('profile-selector'));
          final last = find.byKey(const ValueKey('profile-last-profile'));
          expect(manage.hitTestable(), findsNothing);
          await screenshot(
            tester,
            '${brightness.name}-$scale-profile-row-start',
          );
          await tester.drag(selector, const Offset(-1600, 0));
          await tester.pumpAndSettle();
          expect(manage.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(manage).left,
            greaterThan(tester.getRect(last).right),
          );
          expect(tester.getSize(manage).height, greaterThanOrEqualTo(48));
          expect(tester.takeException(), isNull);
          await screenshot(tester, '${brightness.name}-$scale-profile-row-end');
          await tester.tap(manage);
          await tester.pumpAndSettle();
          expect(find.byTooltip('Create profile'), findsOneWidget);
          await tester.tap(find.text('personal').first);
          await tester.pumpAndSettle();
          expect(find.text('Models and reasoning'), findsOneWidget);
          expect(find.byTooltip('Create profile'), findsNothing);
        },
      );
    }
  }

  testWidgets(
    'unknown credential results offer retry without administrative navigation',
    (tester) async {
      await show(tester, Brightness.dark, healthOnly: true);
      final refresh = await showProfileRefresh(tester);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.text('Check incomplete'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Fix access'), findsNothing);
      expect(find.text('Manage provider access'), findsNothing);
      expect(find.text('Change model'), findsNothing);
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Model access'), findsOneWidget);
      expect(find.text('Profile access'), findsNothing);
    },
  );

  for (final brightness in Brightness.values) {
    for (final accent in WorkspaceAccent.values) {
      testWidgets(
        'administration preserves the ${accent.name} accent in ${brightness.name}',
        (tester) async {
          await show(tester, brightness, accent: accent);
          final theme = Theme.of(
            tester.element(find.byType(HermesAdministrationContent)),
          );
          expect(
            theme.colorScheme.primary,
            brightness == Brightness.dark ? accent.dark : accent.light,
          );

          await screenshot(tester, '${brightness.name}-${accent.name}-profile');
        },
      );
    }
  }

  testWidgets('Health runtime findings survive returning from an action', (
    tester,
  ) async {
    admin.override = AdministrationDesignFixture().send;
    await show(tester, Brightness.dark, healthOnly: true);
    await tester.scrollUntilVisible(
      find.text('Doctor'),
      100,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Doctor'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Failed'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Doctor'),
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(HermesHealthContent), findsOneWidget);
    expect(find.textContaining('Failed'), findsOneWidget);
    expect(find.text('Doctor'), findsOneWidget);
    expect(
      admin.requests.where((r) => r.$1 == 'POST' && r.$2 == 'ops/doctor'),
      hasLength(1),
    );
    expect(
      admin.requests.where((r) => r.$2 == 'actions/doctor/status'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'runtime metadata failure does not hide supported server health actions',
    (tester) async {
      admin.override = (method, path, query, body) async =>
          throw StateError('offline');
      await show(tester, Brightness.dark, healthOnly: true);
      await tester.scrollUntilVisible(
        find.text('Doctor'),
        100,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Profile scope unavailable'), findsNothing);
      expect(find.text('Doctor'), findsOneWidget);
      expect(find.text('Logs'), findsOneWidget);
      expect(find.byTooltip('Run all diagnostics'), findsOneWidget);
    },
  );

  testWidgets('scheduled tasks opens from Profile with captured ownership', (
    tester,
  ) async {
    await show(tester, Brightness.light);
    final selected = controller.current!.scope.profileName;
    admin.override = (method, path, query, body) async => {'data': []};
    await tester.scrollUntilVisible(
      find.text('Scheduled tasks'),
      250,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scheduled tasks'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'No scheduled tasks for this profile. Start with a morning briefing or a weekly review.',
      ),
      findsOneWidget,
    );
    expect(
      admin.requests.where((r) => r.$2 == 'cron/jobs').last.$3['profile'],
      selected,
    );
    expect(find.text('Server A / $selected'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Models and reasoning'), findsOneWidget);
  });
}
