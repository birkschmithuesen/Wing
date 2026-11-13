import 'package:wing/core/widgets/studio_error.dart';
import 'support/host_resources_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/administration/administration_content.dart';
import 'package:wing/core/screens/administration/admin_health_section.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/administration_fixture.dart';
import 'support/profile_browser_fixture.dart';

const _profiles = [
  HermesProfile(name: 'default', isDefault: true),
  HermesProfile(name: 'client-work'),
  HermesProfile(name: 'reminder-inbox'),
  HermesProfile(name: 'shared'),
  HermesProfile(name: 'research-and-writing'),
];

class _Fixture {
  _Fixture(this.status);
  final String status;
  final requests = <String>[];
  final scopedRequests = <(String, String, Map<String, String>)>[];
  final explicitCalls = <String>[];
  final models = <String, String>{};
  Future<Map<String, dynamic>> Function(String profile)? checkAccess;
  Future<Map<String, dynamic>> Function(String profile)? checkConnector;
  Map<String, dynamic> modelInfo(String profile) => {
    'model': models[profile] ?? 'gpt-5.6-sol',
    'provider': 'openai-codex',
  };
  final base = AdministrationFixture('Claw');
  late ProfileWorkspaceController workspace;
  late AppPreferences appPreferences;
  late AdministrationRepository repository;
  Future<void> initialize() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    final discovery = ProfileDiscovery(
      profiles: _profiles,
      currentName: 'reminder-inbox',
      activeName: 'default',
    );
    final browser = ProfileBrowserFixture();
    workspace = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'Claw',
          label: 'Claw',
          host: 'localhost',
          port: 1,
          apiKey: '',
          icon: ConnectionIcon.home,
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'Claw-endpoint',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: (scope) {
        final source = browser.gateway(scope);
        return ProfileGateway(
          scope: scope,
          get: (path, query) async {
            if (path == 'model/info') return modelInfo(scope.profileName);
            return source.read(path, query);
          },
          rpc: (method, params) {
            explicitCalls.add('$method ${scope.profileName}');
            if (method == 'setup.runtime_check') {
              if (checkAccess != null) return checkAccess!(scope.profileName);
              if (status == 'missing' || status == 'problems') {
                return Future.value({
                  'ok': false,
                  'profile': scope.profileName,
                  'error': 'No usable credentials found for openai-codex.',
                });
              }
              return Future.value({
                // The native authority validates profile before this result.
                'ok': true,
                ...modelInfo(scope.profileName),
              });
            }
            return source.call(method, params);
          },
          discover: () async => discovery,
        );
      },
    );
    await workspace.initialize();
    await workspace.switchProfile('default');
    workspace.connectionStatus.accessAvailable();
    workspace.connectionStatus.liveChanged('default', true);
    Future<Map<String, dynamic>> read(
      String method,
      String path,
      Map<String, String> query,
      Map<String, dynamic>? body,
    ) async {
      requests.add('$method $path');
      scopedRequests.add((method, path, Map.of(query)));
      if (method == 'POST' &&
          {'ops/doctor', 'ops/security-audit'}.contains(path)) {
        return {'ok': true, 'name': path.substring(4), 'pid': 7};
      }
      if (method == 'GET' && path.startsWith('actions/')) {
        return {
          'name': path.split('/')[1],
          'pid': 7,
          'running': false,
          'exit_code': 0,
          'lines': ['All checks passed!'],
        };
      }
      if (method == 'POST' && path == 'mcp/servers/example/test') {
        if (checkConnector != null) return checkConnector!(query['profile']!);
        return {'ok': status != 'problems'};
      }
      if (method != 'GET') throw StateError('Unexpected write: $path');
      if (status == 'unknown' &&
          {'tools/toolsets', 'cron/jobs'}.contains(path)) {
        throw StateError('Unavailable');
      }
      return switch (path) {
        'system/stats' => hostStatsPayload(),
        'status' => hostPressurePayload(),
        'profiles' => {
          'profiles': [
            for (final p in _profiles)
              {'name': p.name, 'is_default': p.isDefault},
          ],
        },
        'profiles/active' => {'current': 'reminder-inbox', 'active': 'default'},
        'config' => {
          'memory': {'memory_enabled': true, 'memory_char_limit': 2200},
          'agent': {'reasoning_effort': 'high'},
          'approvals': {'mode': 'smart'},
          'compression': {'enabled': true},
        },
        'model/info' => modelInfo(query['profile']!),
        'skills' => {
          'data': List.generate(
            126,
            (i) => {'name': 'skill-$i', 'enabled': true},
          ),
        },
        'tools/toolsets' => {
          'data': List.generate(
            21,
            (i) => {
              'name': 'tool-$i',
              'enabled': true,
              'configured': !{'amber', 'problems'}.contains(status) || i != 0,
            },
          ),
        },
        'providers/oauth' => {
          'providers': [
            {
              'id': 'openai-codex',
              'name': 'OpenAI Codex',
              'flow': 'device_code',
              'status': {
                'logged_in': true,
                'source_label': 'OpenAI Codex',
                if (status == 'red') 'expires_at': '2020-01-01T00:00:00Z',
              },
            },
          ],
        },
        'mcp/servers' => {
          'servers': [
            {
              'name': 'example',
              'enabled': true,
              'transport': 'http',
              'auth': null,
              'source': 'config',
              'plugin': null,
            },
          ],
        },
        'cron/jobs' => {
          'data': [
            if (status == 'problems')
              {
                'id': 'failed-task',
                'profile': query['profile']!,
                'profile_name': query['profile']!,
                'enabled': true,
                'schedule': {'kind': 'interval', 'minutes': 60},
                'state': 'error',
                'last_error': 'Delivery failed',
              },
          ],
        },
        _ => await base.send(method, path, query, body),
      };
    }

    repository = AdministrationRepository(
      ownedMutation:
          (method, path, query, body, canDispatch, onDispatched) async {
            if (method != 'POST' ||
                !{'ops/doctor', 'ops/security-audit'}.contains(path)) {
              throw StateError('Unexpected owned mutation: $method $path');
            }
            if (!canDispatch()) throw StateError('Diagnostic retired');
            onDispatched();
            return read(method, path, query, body);
          },
      settingsWrite: (_, _, _, _) async =>
          throw StateError('Unexpected settings write'),
      connectionId: 'Claw',
      connectionIdentity: 'Claw-endpoint',
      connectionLabel: 'Claw',
      request: read,
      gateway: (name) => ProfileGateway(
        scope: WorkspaceScope(
          connectionId: 'Claw',
          connectionIdentity: 'Claw-endpoint',
          profileName: name,
        ),
        get: (p, q) => read('GET', p, {...q, 'profile': name}, null),
        discover: () async => discovery,
        rpc: (method, params) async {
          requests.add('RPC $method $name');
          if (method == 'mcp.servers.status') {
            return {
              'checked_at': DateTime.now().millisecondsSinceEpoch,
              'servers': [
                {
                  'name': 'example',
                  'transport': 'http',
                  'source': 'config',
                  'plugin': null,
                  'tools': 0,
                  'connected': false,
                  'disabled': false,
                  'status': 'configured',
                  'needs_auth': false,
                },
              ],
            };
          }
          if (method != 'setup.status') {
            throw StateError('Unexpected RPC: $method');
          }
          return {'profile': name, 'provider_configured': true};
        },
      ),
    );
  }

  void dispose() {
    workspace.dispose();
    repository.close();
    appPreferences.dispose();
  }
}

void main({
  Future<void> Function(WidgetTester tester, String name)? nativeCapture,
  bool useNativeViewport = false,
}) {
  const capture = bool.fromEnvironment('CAPTURE_ADMIN_HEALTH');
  if (capture) {
    setUpAll(() async {
      for (final e in {
        'Roboto': 'roboto-regular.ttf',
        'MaterialIcons': 'materialicons-regular.otf',
      }.entries) {
        await (FontLoader(e.key)..addFont(
              File(
                '/tmp/wing-header-fonts/${e.value}',
              ).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
    });
  }
  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!capture) {
      await nativeCapture?.call(tester, name);
      return;
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('health-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/administration-health/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('Fix access opens the owning editor and checks again on return', (
    tester,
  ) async {
    final fixture = _Fixture('missing');
    await fixture.initialize();
    addTearDown(fixture.dispose);
    await fixture.workspace.switchProfile('client-work');
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: HermesHealthContent(
            controller: fixture.workspace,
            repository: fixture.repository,
            onOpenMenu: () {},
            onOpenSession: (_) async {},
            onConnections: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Credentials missing'), findsOneWidget);
    await tester.ensureVisible(find.text('Fix access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fix access'));
    await tester.pumpAndSettle();
    expect(find.text('Profile access'), findsOneWidget);
    expect(find.text('Claw / client-work'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(HermesHealthContent), findsOneWidget);
    expect(find.text('Credentials missing'), findsOneWidget);
    expect(find.text('Fix access'), findsOneWidget);
    expect(
      fixture.explicitCalls.where((v) => v.startsWith('setup.runtime_check')),
      hasLength(2),
    );
  });

  testWidgets(
    'Fix access rechecks the captured profile after selection changes',
    (tester) async {
      final fixture = _Fixture('missing');
      await fixture.initialize();
      addTearDown(fixture.dispose);
      await fixture.workspace.switchProfile('client-work');
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: HermesHealthContent(
              controller: fixture.workspace,
              repository: fixture.repository,
              onOpenMenu: () {},
              onOpenSession: (_) async {},
              onConnections: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Fix access'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix access'));
      await tester.pumpAndSettle();
      expect(find.text('Claw / client-work'), findsOneWidget);
      await fixture.workspace.switchProfile('shared');
      await tester.pumpAndSettle();
      expect(fixture.workspace.current?.scope.profileName, 'shared');
      fixture.explicitCalls.clear();

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(
        fixture.explicitCalls.where(
          (call) => call.startsWith('setup.runtime_check'),
        ),
        ['setup.runtime_check client-work'],
      );
      expect(fixture.workspace.current?.scope.profileName, 'shared');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Fix access drains an older check before checking again', (
    tester,
  ) async {
    final fixture = _Fixture('missing');
    await fixture.initialize();
    addTearDown(fixture.dispose);
    await fixture.workspace.switchProfile('client-work');
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: HermesHealthContent(
            controller: fixture.workspace,
            repository: fixture.repository,
            onOpenMenu: () {},
            onOpenSession: (_) async {},
            onConnections: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Fix access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fix access'));
    await tester.pumpAndSettle();
    final oldCheck = Completer<Map<String, dynamic>>();
    addTearDown(() {
      if (!oldCheck.isCompleted) {
        oldCheck.complete({'ok': false, 'profile': 'client-work'});
      }
    });
    var calls = 0;
    fixture.checkAccess = (profile) {
      calls++;
      return calls == 1
          ? oldCheck.future
          : Future.value({
              'ok': true,
              'profile': profile,
              ...fixture.modelInfo(profile),
            });
    };
    final session = fixture.workspace.healthSession(
      repository: fixture.repository,
    );
    unawaited(session.refresh(fixture.workspace.current!.gateway));
    for (var step = 0; step < 20 && calls == 0; step++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(calls, 1);

    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, 1);
    oldCheck.complete({'ok': false, 'profile': 'client-work'});
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Access is set up'), findsOneWidget);
    expect(fixture.workspace.current?.scope.profileName, 'client-work');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Health checks access and connectors on entry and profile selection',
    (tester) async {
      final fixture = _Fixture('green');
      await fixture.initialize();
      addTearDown(fixture.dispose);
      fixture.explicitCalls.clear();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: HermesHealthContent(
              controller: fixture.workspace,
              repository: fixture.repository,
              onOpenMenu: () {},
              onOpenSession: (_) async {},
              onConnections: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        fixture.requests,
        containsAll([
          'GET model/info',
          'GET providers/oauth',
          'GET tools/toolsets',
          'GET mcp/servers',
          'GET cron/jobs',
        ]),
      );
      expect(
        fixture.explicitCalls.where((v) => v.startsWith('setup.runtime_check')),
        ['setup.runtime_check default'],
      );
      expect(
        fixture.scopedRequests
            .where((r) => r.$1 == 'POST' && r.$2.startsWith('ops/'))
            .map((r) => (r.$2, r.$3.isEmpty)),
        [('ops/doctor', true), ('ops/security-audit', true)],
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Not fully checked'), findsNothing);
      expect(find.text('Access is set up'), findsOneWidget);
      expect(
        fixture.scopedRequests
            .where((r) => r.$1 == 'POST' && r.$2 == 'mcp/servers/example/test')
            .map((r) => r.$3['profile']),
        ['default'],
      );
      expect(find.textContaining('Connections not tested'), findsNothing);
      final before = fixture.scopedRequests.length;
      await fixture.workspace.switchProfile('client-work');
      await tester.pumpAndSettle();
      final switched = fixture.scopedRequests
          .skip(before)
          .where(
            (r) => const [
              'model/info',
              'providers/oauth',
              'tools/toolsets',
              'mcp/servers',
              'cron/jobs',
            ].contains(r.$2),
          );
      expect(switched, hasLength(5));
      expect(switched.every((r) => r.$3['profile'] == 'client-work'), isTrue);
      expect(
        fixture.explicitCalls,
        contains('setup.runtime_check client-work'),
      );
      expect(
        fixture.scopedRequests
            .where((r) => r.$1 == 'POST' && r.$2 == 'mcp/servers/example/test')
            .map((r) => r.$3['profile']),
        ['default', 'client-work'],
      );
      await tester.ensureVisible(find.byTooltip('Refresh profile status'));
      await tester.tap(find.byTooltip('Refresh profile status'));
      await tester.pumpAndSettle();
      expect(
        fixture.explicitCalls.where(
          (v) => v == 'setup.runtime_check client-work',
        ),
        hasLength(2),
      );
      expect(find.textContaining('Access is set up'), findsOneWidget);
      await tester.ensureVisible(find.text('Model access'));
      await tester.tap(find.text('Model access'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Access is set up'), findsOneWidget);
      expect(find.text('Provider configuration detected'), findsNothing);
      expect(
        find.text('Provider readiness is not fully observed'),
        findsNothing,
      );
      expect(find.text('Access checks'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.text('Change model'), findsNothing);
      expect(find.text('Manage provider access'), findsNothing);
      expect(find.text('Fix access'), findsNothing);
      expect(find.byType(HermesHealthContent), findsOneWidget);
      expect(find.text('gpt-5.6-sol · openai-codex'), findsOneWidget);
      // Refresh checks the newly selected model after reading its configuration.
      fixture.models['client-work'] = 'gpt-6-astra';
      await tester.ensureVisible(find.byTooltip('Refresh profile status'));
      await tester.tap(find.byTooltip('Refresh profile status'));
      await tester.pumpAndSettle();
      expect(find.text('Access is set up'), findsOneWidget);
      expect(find.text('gpt-6-astra · openai-codex'), findsOneWidget);
      expect(
        fixture.explicitCalls.where((v) => v.startsWith('setup.runtime_check')),
        hasLength(4),
      );
      expect(
        fixture.requests.where(
          (v) =>
              v.startsWith('POST') &&
              !v.endsWith('/test') &&
              !{'POST ops/doctor', 'POST ops/security-audit'}.contains(v),
        ),
        isEmpty,
      );
      expect(
        fixture.requests.where((r) => r.startsWith('POST ops/')),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('all four rows surface problems automatically', (tester) async {
    final fixture = _Fixture('problems');
    await fixture.initialize();
    addTearDown(fixture.dispose);
    tester.view.physicalSize = const Size(412, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HermesHealthContent(
            controller: fixture.workspace,
            repository: fixture.repository,
            onOpenMenu: () {},
            onOpenSession: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Credentials missing'), findsOneWidget);
    expect(find.text('21 enabled · 1 needs setup'), findsOneWidget);
    expect(find.text('0 passed · 1 failed'), findsOneWidget);
    expect(find.text('1 task · 1 has a reported error'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching profiles during checks keeps results isolated', (
    tester,
  ) async {
    final fixture = _Fixture('green');
    await fixture.initialize();
    addTearDown(fixture.dispose);
    final access = Completer<Map<String, dynamic>>();
    final connector = Completer<Map<String, dynamic>>();
    fixture.checkAccess = (profile) async => profile == 'default'
        ? access.future
        : {'ok': true, 'profile': profile, ...fixture.modelInfo(profile)};
    fixture.checkConnector = (profile) async =>
        profile == 'default' ? connector.future : {'ok': true};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HermesHealthContent(
            controller: fixture.workspace,
            repository: fixture.repository,
            onOpenMenu: () {},
            onOpenSession: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();
    final checking = find.text('Checking access…');
    await tester.scrollUntilVisible(
      checking,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(checking, findsOneWidget);
    final viewport = tester.getRect(
      find.byKey(const PageStorageKey('administration-health-findings')),
    );
    expect(viewport.contains(tester.getCenter(checking)), isTrue);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Refresh profile status',
            ),
          )
          .onPressed,
      isNull,
    );
    await fixture.workspace.switchProfile('client-work');
    await tester.pumpAndSettle();
    expect(find.text('Access is set up'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Refresh profile status',
            ),
          )
          .onPressed,
      isNotNull,
    );
    access.complete({
      'ok': false,
      'profile': 'default',
      'error': 'No usable credentials found for openai-codex.',
    });
    connector.complete({'ok': false});
    await tester.pumpAndSettle();
    expect(find.text('Access is set up'), findsOneWidget);
    expect(find.text('Credentials missing'), findsNothing);
    expect(find.text('0 passed · 1 failed'), findsNothing);
    fixture.checkAccess = (profile) async => {
      'ok': true,
      'profile': profile,
      ...fixture.modelInfo(profile),
    };
    fixture.checkConnector = (_) async => {'ok': true};
    await fixture.workspace.switchProfile('default');
    await tester.pumpAndSettle();
    expect(
      fixture.explicitCalls.where((v) => v == 'setup.runtime_check default'),
      hasLength(1),
    );
    expect(find.text('Credentials missing'), findsOneWidget);
    expect(find.text('0 passed · 1 failed'), findsOneWidget);
    expect(
      fixture.requests.where((r) => r.startsWith('POST ops/')),
      hasLength(2),
    );
    // Returning to Health reuses each profile and the server results.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HermesHealthContent(
            controller: fixture.workspace,
            repository: fixture.repository,
            onOpenMenu: () {},
            onOpenSession: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      fixture.explicitCalls.where((v) => v == 'setup.runtime_check default'),
      hasLength(1),
    );
    expect(
      fixture.requests.where((r) => r.startsWith('POST ops/')),
      hasLength(2),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    for (final status in [
      'green',
      'amber',
      'red',
      'unknown',
      'missing',
      'problems',
    ]) {
      for (final large in [false, if (status != 'red') true]) {
        testWidgets(
          'health entry $status ${brightness.name} ${large ? 'large' : 'phone'}',
          (tester) async {
            final fixture = _Fixture(status);
            await fixture.initialize();
            addTearDown(fixture.dispose);
            if (!useNativeViewport) {
              tester.view.physicalSize = large
                  ? const Size(320, 640)
                  : const Size(412, 832);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
            }
            final scaffold = GlobalKey<ScaffoldState>();
            await tester.pumpWidget(
              RepaintBoundary(
                key: const ValueKey('health-capture'),
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: wingTheme(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(large ? 2 : 1)),
                    child: child!,
                  ),
                  home: Scaffold(
                    key: scaffold,
                    appBar: AppBar(title: const Text('Hermes health')),
                    drawer: const Drawer(child: Text('Navigation')),
                    body: HermesHealthContent(
                      controller: fixture.workspace,
                      repository: fixture.repository,
                      onOpenMenu: () => scaffold.currentState!.openDrawer(),
                      onOpenSession: (_) async {},
                      onConnections: () {},
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.byType(HermesHealthContent), findsOneWidget);
            expect(find.text('Host'), findsOneWidget);
            expect(
              fixture.requests,
              containsAll([
                'GET model/info',
                'GET providers/oauth',
                'GET tools/toolsets',
                'GET mcp/servers',
              ]),
            );
            expect(find.byType(TabBar), findsNothing);
            final pageScroll = find
                .byWidgetPredicate(
                  (w) =>
                      w is Scrollable && w.axisDirection == AxisDirection.down,
                )
                .first;
            for (final section in ['Server', 'Profile']) {
              final heading = find.byWidgetPredicate(
                (w) => w is AdminHealthSectionHeading && w.title == section,
              );
              await tester.scrollUntilVisible(
                heading,
                180,
                scrollable: pageScroll,
              );
              await tester.pumpAndSettle();
              expect(
                find.descendant(
                  of: heading,
                  matching: find.textContaining(
                    section == 'Profile' && status == 'unknown'
                        ? 'Check incomplete'
                        : 'Last checked ',
                  ),
                ),
                findsOneWidget,
              );
            }
            await tester.drag(pageScroll, const Offset(0, 3000));
            await tester.pumpAndSettle();
            if (status == 'missing' || status == 'green') {
              await tester.scrollUntilVisible(
                find.byTooltip('Refresh profile status'),
                250,
                scrollable: find
                    .byWidgetPredicate(
                      (w) =>
                          w is Scrollable &&
                          w.axisDirection == AxisDirection.down,
                    )
                    .first,
              );
              await tester.ensureVisible(
                find.byTooltip('Refresh profile status'),
              );
              await tester.pumpAndSettle();
              await tester.tap(find.byTooltip('Refresh profile status'));
              await tester.pumpAndSettle();
            }
            final name =
                '$status-${brightness.name}-${large ? 'large' : 'phone'}';
            await snapshot(tester, '$name-overview');
            await snapshot(tester, '$name-health');
            final vertical = find
                .byWidgetPredicate(
                  (w) =>
                      w is Scrollable && w.axisDirection == AxisDirection.down,
                )
                .first;
            await tester.drag(vertical, const Offset(0, -700));
            await tester.pumpAndSettle();
            await snapshot(tester, '$name-health-lower');
            await tester.drag(vertical, const Offset(0, 5000));
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(
              find.text('Model access'),
              200,
              scrollable: vertical,
            );
            await tester.pumpAndSettle();
            await snapshot(tester, '$name-model-access');
            if (status == 'missing' || status == 'problems') {
              await tester.ensureVisible(find.text('Fix access'));
              await tester.pumpAndSettle();
              await snapshot(tester, '$name-model-access-action');
            }
            expect(find.text('Not fully checked'), findsNothing);
            expect(
              find.textContaining(RegExp(r'^Checked [0-9]')),
              findsNothing,
            );
            for (final title in [
              'Tool setup',
              'Connectors',
              'Scheduled tasks',
            ]) {
              await tester.drag(vertical, const Offset(0, 3000));
              await tester.pumpAndSettle();
              await tester.scrollUntilVisible(
                find.text(title),
                200,
                scrollable: vertical,
              );
              await tester.pumpAndSettle();
              final row = find.ancestor(
                of: find.text(title),
                matching: find.byType(ListTile),
              );
              final tile = tester.widget<ListTile>(row);
              final needsDetails = switch (title) {
                'Tool setup' => [
                  'amber',
                  'problems',
                  'unknown',
                ].contains(status),
                'Scheduled tasks' =>
                  status == 'problems' || status == 'unknown',
                _ => status == 'problems',
              };
              if (!needsDetails) {
                expect(tile.onTap, isNull);
                expect(tile.trailing, isNull);
                expect(
                  (tile.leading! as Icon).color,
                  WingTokens.of(tester.element(row)).success,
                );
                await tester.tap(find.text(title));
                await tester.pumpAndSettle();
                expect(find.byType(HermesHealthContent), findsOneWidget);
                continue;
              }
              expect(tile.onTap, isNotNull);
              expect((tile.trailing! as Icon).icon, Icons.chevron_right);
              final summary = find.descendant(
                of: row,
                matching: find.byType(StudioError),
              );
              expect(summary, findsOneWidget);
              expect(
                tester.widget<StudioError>(summary).severity,
                status == 'unknown'
                    ? StudioErrorSeverity.error
                    : StudioErrorSeverity.noResult,
              );
              await tester.ensureVisible(summary);
              await tester.pumpAndSettle();
              await snapshot(tester, '$name-summary-$title');
              await tester.tap(find.text(title));
              await tester.pumpAndSettle();
              if (status == 'unknown') {
                expect(
                  tester.widget<StudioError>(find.byType(StudioError)).severity,
                  StudioErrorSeverity.error,
                );
              }
              final recovery = find.text(switch (title) {
                'Tool setup' => 'Skills and tools',
                'Connectors' => 'Manage connectors',
                _ => 'Manage scheduled tasks',
              });
              await tester.scrollUntilVisible(
                recovery,
                150,
                scrollable: find.byType(Scrollable).first,
              );
              await tester.pumpAndSettle();
              expect(recovery, findsOneWidget);
              expect(
                tester
                    .widget<ListTile>(
                      find.ancestor(
                        of: recovery,
                        matching: find.byType(ListTile),
                      ),
                    )
                    .onTap,
                isNotNull,
              );
              await snapshot(tester, '$name-detail-$title');
              await tester.drag(
                find.byType(Scrollable).first,
                const Offset(0, -450),
              );
              await tester.pumpAndSettle();
              await snapshot(tester, '$name-detail-$title-lower');
              expect(tester.takeException(), isNull);
              await tester.pageBack();
              await tester.pumpAndSettle();
            }
            if (status == 'green') {
              await tester.scrollUntilVisible(
                find.byTooltip('What’s checked?'),
                200,
                scrollable: vertical,
              );
              await tester.ensureVisible(find.byTooltip('What’s checked?'));
              await tester.tap(find.byTooltip('What’s checked?'));
              await tester.pumpAndSettle();
              expect(find.byType(AlertDialog), findsOneWidget);
              await snapshot(tester, '$name-explanation');
              final explanationScroll = find
                  .descendant(
                    of: find.byType(AlertDialog),
                    matching: find.byType(Scrollable),
                  )
                  .first;
              await tester.scrollUntilVisible(
                find.textContaining('No reported errors doesn’t mean'),
                180,
                scrollable: explanationScroll,
              );
              await tester.pumpAndSettle();
              await tester.drag(explanationScroll, const Offset(0, -3000));
              await tester.pumpAndSettle();
              await snapshot(tester, '$name-explanation-lower');
              await tester.tap(find.byTooltip('Close'));
              await tester.pumpAndSettle();
              expect(find.byType(AlertDialog), findsNothing);
            }
            expect(
              fixture.requests.where(
                (r) =>
                    r.startsWith('POST') &&
                    !r.endsWith('/test') &&
                    !{'POST ops/doctor', 'POST ops/security-audit'}.contains(r),
              ),
              isEmpty,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
