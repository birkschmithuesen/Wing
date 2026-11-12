// Export real Wing widgets with authored, public-safe demo content.
// Run manually; this is asset tooling, not a production application change.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/models/app_preferences.dart' show AppThemePreference;
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/widgets/chat_notice_activity_scope.dart';
import 'package:wing/core/presentation/tool_call_presentation.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/screens/analytics_content.dart';
import 'package:wing/core/screens/administration/administration_content.dart';
import 'package:wing/core/screens/bots/bots_content.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/widgets/bot_group_conversation.dart';
import 'package:wing/core/screens/administration/admin_health_page.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/versions_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/health_alerts/health_alerts_scope.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';

import '../../test/helpers/pump_markdown_widget.dart';
import '../../test/source_highlighting_test.dart' show settleSource;
import '../../test/support/profile_browser_fixture.dart';
import '../../test/support/administration_design_fixture.dart';
import '../../test/support/host_resources_fixture.dart';
import '../../test/support/bots_fixture.dart';
import '../../test/support/health_alerts_fixture.dart';

class _CaptureBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

class _WebsiteFixture extends ProfileBrowserFixture {
  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    for (final row in super.sessions(profile))
      {
        ...row,
        'profile': profile,
        if (row['id'] == 'newest') 'title': 'The research, ready to use',
        if (row['id'] == 'pinned') 'title': 'Ideas for the next release',
        if (row['id'] == 'project-only')
          'title': 'Compare the deployment options',
        if (row['id'] == 'old') 'title': 'Turn meeting notes into a plan',
        if (row['id'] == 'test') 'title': 'Review the report sources',
        if (row['id'] == 'docs') 'title': 'Prepare the launch checklist',
        if (profile == 'work') 'title': 'Review the launch copy',
        if (profile == 'work') 'id': 'launch-copy',
      },
  ];

  @override
  List<Map<String, dynamic>> projects(String profile) => [
    for (final project in super.projects(profile))
      {
        ...project,
        if (project['id'] == 'p2') 'label': 'Research',
        if (profile == 'work') 'label': 'Launch',
        'sessionIds': profile == 'work'
            ? ['launch-copy']
            : project['id'] == 'p2'
            ? ['newest', 'project-only']
            : project['isNoProject'] == true
            ? ['old', 'pinned', 'pin-two', 'test', 'docs']
            : <String>[],
      },
  ];

  @override
  List<Map<String, dynamic>> searchRows(String profile, String query) => [
    for (final row in sessions(profile))
      if (row['id'] == query ||
          row['title'].toString().toLowerCase().contains(query))
        {...row, 'session_id': row['id']},
  ];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) =>
      id != 'newest'
      ? [
          {
            'id': 1,
            'role': 'assistant',
            'content': 'The next step is ready to review.',
            'timestamp': now - 600,
          },
        ]
      : [
          {
            'id': 1,
            'role': 'user',
            'timestamp': now - 684,
            'content':
                'Check the options and turn the research into a short recommendation.',
          },
          {
            'id': 2,
            'role': 'tool',
            'tool_name': 'execute_code',
            'content': 'Checked 7 records. Source dates preserved.',
          },
          {
            'id': 3,
            'role': 'assistant',
            'timestamp': now - 600,
            'content':
                '## The comparison is ready\n\n'
                'I checked all 7 records and kept the source dates with each finding.\n\n'
                '| Option | Best for |\n| --- | --- |\n'
                '| Smaller setup | A focused pilot |\n| Full setup | A larger rollout |\n'
                '| Hybrid setup | Gradual expansion |\n\n'
                '**Start with the smaller setup.** It covers the pilot without adding work you do not need yet.\n\n'
                'The full comparison is saved in `comparison.md`.',
          },
        ];

  @override
  ProfileGateway gateway(scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: (path, query) async => path == 'model/info'
          ? {'provider': 'research', 'model': 'Research model'}
          : base.read(path, query),
      ownedPatch: (path, body, canDispatch, onDispatched) async {
        if (!canDispatch()) throw StateError('Capture retired');
        onDispatched();
        return {'ok': true};
      },
      rpc: (method, params) async {
        if (method == 'setup.runtime_check') {
          return {
            'ok': true,
            'profile': scope.profileName,
            'provider': 'research',
            'model': 'Research model',
          };
        }
        final result = await base.call(method, params);
        if (method == 'session.resume') {
          return {
            ...result,
            'info': {
              ...result['info'] as Map,
              'model': 'provider/research-model',
            },
          };
        }
        return result;
      },
    );
  }
}

class _SwitchingFixture extends _WebsiteFixture {
  @override
  List<Map<String, dynamic>> projects(String profile) => [
    for (final project in super.projects(profile))
      if (project['isNoProject'] == true ||
          project['id'] == 'p2' ||
          project['id'] == 'work-project')
        project,
  ];
}

class _ActivityFixture extends _WebsiteFixture {
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {
      'id': 21,
      'role': 'user',
      'timestamp': now - 684,
      'content': 'Check the source dates and save the comparison.',
    },
    {
      'id': 22,
      'role': 'tool',
      'tool_name': 'todo',
      'content': jsonEncode({
        'revision': 1,
        'todos': [
          {
            'id': 'read',
            'content': 'Read the seven source records',
            'status': 'completed',
          },
          {
            'id': 'dates',
            'content': 'Check publication dates',
            'status': 'completed',
          },
          {
            'id': 'report',
            'content': 'Save the comparison report',
            'status': 'completed',
          },
        ],
      }),
    },
    {
      'id': 23,
      'role': 'tool',
      'tool_name': 'delegate_task',
      'args': {
        'tasks': [
          {'goal': 'Check the publication dates in all seven source records.'},
        ],
      },
      'content': jsonEncode({
        'results': [
          {
            'task_index': 0,
            'status': 'completed',
            'summary': 'All seven records include a publication date.',
            'duration_seconds': 12,
          },
        ],
      }),
    },
    {
      'id': 24,
      'role': 'tool',
      'tool_name': 'execute_code',
      'args': {
        'code':
            'from pathlib import Path\n\nrows = Path("research.csv").read_text().splitlines()\nprint(f"Checked {len(rows) - 1} records")',
      },
      'content': jsonEncode({
        'output': 'Checked 7 records\nSource dates preserved',
        'success': true,
      }),
    },
    {
      'id': 25,
      'role': 'assistant',
      'timestamp': now - 600,
      'content':
          'The seven records are checked. The comparison is saved in `comparison.md`.',
    },
  ];
}

class _WebsiteAdministration extends AdministrationDesignFixture {
  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    if (path == 'system/stats') {
      return {...hostStatsPayload(), 'hostname': 'My Hermes'};
    }
    if (path == 'status') return hostPressurePayload();
    if (path == 'ops/doctor' || path == 'ops/security-audit') {
      return {'ok': true, 'name': path.substring(4), 'pid': 7};
    }
    if (path.startsWith('actions/')) {
      return {
        'name': path.split('/')[1],
        'pid': 7,
        'running': false,
        'exit_code': 0,
        'lines': ['All checks passed.'],
      };
    }
    if (path == 'tools/toolsets') {
      return {
        'data': [
          {'name': 'web', 'enabled': true, 'configured': true},
          {'name': 'terminal', 'enabled': true, 'configured': true},
        ],
      };
    }
    if (path == 'mcp/servers') {
      return {
        'servers': [
          {'name': 'Research library', 'enabled': true},
        ],
      };
    }
    if (path.endsWith('/test')) return {'ok': true};
    if (path == 'providers/oauth') {
      return {
        'providers': [
          {
            'id': 'research',
            'name': 'Research provider',
            'flow': 'device_code',
            'status': {'logged_in': true, 'source_label': 'Profile sign-in'},
          },
        ],
      };
    }
    return super.send(method, path, query, body);
  }
}

/// One consistent demo history supplies the year, period and model totals.
class _WebsiteAnalytics extends AdministrationDesignFixture {
  late final _year = _dailyRows();

  List<Map<String, dynamic>> _dailyRows() {
    final random = math.Random(20261009);
    final end = DateTime.utc(2026, 10, 9);
    return [
      for (var i = 0; i < 365; i++)
        (() {
          final date = end.subtract(Duration(days: 364 - i));
          final idle = random.nextInt(100) < (date.weekday >= 6 ? 42 : 12);
          return <String, dynamic>{
            'day': date.toIso8601String().substring(0, 10),
            'input_tokens': idle ? 0 : 9000 + random.nextInt(70000),
            'cache_read_tokens': idle ? 0 : 26000 + random.nextInt(180000),
            'output_tokens': idle ? 0 : 1800 + random.nextInt(24000),
          };
        })(),
    ];
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    if (path != 'analytics/usage' && path != 'analytics/models') {
      return super.send(method, path, query, body);
    }
    final days = int.parse(query['days']!);
    final rows = _year.skip(_year.length - days).toList();
    if (path == 'analytics/usage') return {'daily': rows};
    final totals = {
      for (final key in ['input_tokens', 'cache_read_tokens', 'output_tokens'])
        key: rows.fold<int>(0, (sum, row) => sum + (row[key] as int)),
    };
    return {
      'period_days': days,
      'models': [
        for (final model in ['gpt-6-astra', 'gpt-5.6-sol'])
          {
            'model': model,
            'provider': 'openai-codex',
            'estimated_cost': 0,
            for (final entry in totals.entries)
              entry.key: model == 'gpt-6-astra'
                  ? entry.value * 7 ~/ 10
                  : entry.value - entry.value * 7 ~/ 10,
          },
      ],
    };
  }
}

void main() {
  _CaptureBinding();
  const frame = ValueKey('website-capture');

  setUpAll(() async {
    const root = String.fromEnvironment('WING_CAPTURE_FONTS');
    for (final entry in {
      'Roboto': '$root/studio-roboto.ttf',
      'Ahem': '$root/studio-roboto.ttf',
      'MaterialIcons': '$root/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
      'monospace': '$root/studio-mono.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(File(entry.value).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });

  Future<void> capture(
    WidgetTester tester,
    String name, {
    String directory = 'website/assets/screenshots',
  }) async {
    await tester.settleMarkdown();
    await settleSource(tester);
    await tester.runAsync(() async {
      final context = tester.element(find.byKey(frame));
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await precacheImage(image.image, context);
      }
    });
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(frame),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$directory/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('export bots and a group discussion', (tester) async {
    // Working bots animate continuously; let route/content reads finish without
    // waiting for the app to stop scheduling frames.
    Future<void> settleView() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.settleMarkdown();
    }

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // Opt-in screenshot tooling runs outside test/ discovery.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final fixture = BotsFixture();
    fixture.profiles.addAll([
      BotsFixture.profile(
        'sage',
        'Sage',
        preview: 'The source notes are saved with the report.',
      ),
      BotsFixture.profile(
        'orbit',
        'Orbit',
        preview: 'Your weekly review is scheduled for Friday.',
      ),
    ]);
    const colors = ['#65c7bc', '#ebaa65', '#bca6e8', '#86afda', '#db94af'];
    const shapes = ['squircle', 'hexagon', 'circle', 'cloud', 'pill'];
    for (var i = 0; i < fixture.profiles.length; i++) {
      final meta = fixture.profiles[i]['ui_meta']['hermes-bots'] as Map;
      meta['color'] = colors[i];
      meta['shape'] = shapes[i];
    }
    final messages = [
      (
        'user',
        'you',
        'Compare the rollout options. @bot_atlas check the evidence; @bot_mira review the risks.',
      ),
      (
        'member',
        'atlas',
        '**Start with a small pilot.** It covers the required integrations and keeps the first rollout manageable.',
      ),
      (
        'member',
        'mira',
        'Test the **rollback steps** first. Then invite one team and review their feedback before expanding.',
      ),
    ];
    fixture.events.addAll([
      for (var i = 0; i < messages.length; i++)
        {
          'room_id': 'room-1',
          'seq': i + 1,
          'event_id': 'message-$i',
          'kind': 'message.${messages[i].$1}',
          'actor': {
            'kind': messages[i].$1,
            'id': messages[i].$2,
            'profile': messages[i].$2,
          },
          'created_at': 1792724400.0 + i * 60,
          'payload': {'text': messages[i].$3},
        },
    ]);
    final session = BotsSession((_) async => [fixture.repository]);
    addTearDown(session.dispose);
    await session.refresh();
    var view = const BotsViewState();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(Brightness.dark),
        builder: (_, child) => RepaintBoundary(key: frame, child: child!),
        home: StatefulBuilder(
          builder: (context, setState) => BotsContent(
            session: session,
            instanceHeader: const Align(
              alignment: Alignment.centerLeft,
              child: ServerConnectionLabel(label: 'Home server'),
            ),
            viewState: view,
            onViewChanged: (next) => setState(() => view = next),
            onOpenMenu: () {},
            onOpenChat: (_) async {},
            onOpenGroupMemberChat: (_, _) async {},
            onOpenGroup: (group) => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => BotGroupScreen(
                  createSession: () => session.openGroup(group),
                  voiceInputSettings: () => null,
                  stopVoicePlayback: () async {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settleView();
    await capture(
      tester,
      'bots-dark',
      directory: 'build/website-release-media',
    );
    await tester.tap(find.byTooltip('Edit name & appearance for Atlas'));
    await settleView();
    await capture(
      tester,
      'bot-appearance-dark',
      directory: 'build/website-release-media',
    );
    await tester.pageBack();
    await settleView();
    await tester.tap(find.widgetWithText(Tab, 'Groups'));
    await settleView();
    await tester.tap(find.text('Research team'));
    await settleView();
    expect(find.byType(BotGroupScreen), findsOneWidget);
    expect(find.byType(BotGroupConversation), findsOneWidget);
    await capture(
      tester,
      'bot-discussion-dark',
      directory: 'build/website-release-media',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('export Recents conversation switching', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // Opt-in screenshot tooling runs outside test/ discovery.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final fixture = _WebsiteFixture();
    final controller = ProfileWorkspaceController(
      connectionIdentity: 'website-recents',
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'Home server',
          label: 'My Hermes',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    fixture.liveSessions['personal'] = [
      {
        'id': 'research-runtime',
        'session_key': 'project-only',
        'status': 'working',
        'last_active': fixture.now,
      },
    ];
    fixture.liveSessions['work'] = [
      {
        'id': 'launch-runtime',
        'session_key': 'launch-copy',
        'status': 'waiting',
        'last_active': fixture.now,
      },
    ];
    await controller.refreshRecents();
    final activity = ValueNotifier<ChatNoticeActivity?>(null);
    addTearDown(activity.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(Brightness.dark),
        builder: (_, child) => ChatNoticeActivityScope(
          activity: activity,
          child: RepaintBoundary(key: frame, child: child!),
        ),
        home: ProfileWorkspaceScreen(
          controller: controller,
          initialDestination: AppDestination.activity,
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await capture(tester, 'recents-dark');
    await tester.tap(find.text('The research, ready to use').first);
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    final first = await tester.startGesture(const Offset(90, 400), pointer: 1);
    final second = await tester.startGesture(
      const Offset(300, 400),
      pointer: 2,
    );
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      await first.moveTo(
        Offset.lerp(const Offset(90, 400), const Offset(155, 400), i / 8)!,
      );
      await second.moveTo(
        Offset.lerp(const Offset(300, 400), const Offset(235, 400), i / 8)!,
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await first.up();
    await second.up();
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(find.text('Swipe to browse · tap to open'), findsOneWidget);
    await capture(tester, 'recents-stack-dark');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'export ${brightness.name} health overview with alert settings',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        // Opt-in screenshot tooling runs outside test/ discovery.
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final alerts = HealthAlertsFixture(preferences);
        final workspace = _WebsiteFixture();
        final administration = _WebsiteAdministration();
        administration.jobs.add({
          'id': 'morning-brief',
          'name': 'Morning research brief',
          'enabled': true,
          'state': 'scheduled',
          'schedule': {'kind': 'cron', 'expr': '0 8 * * 1-5'},
          'next_run_at': DateTime.now()
              .add(const Duration(hours: 12))
              .toIso8601String(),
        });
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: SavedConnection(
              id: 'Home server',
              label: 'My Hermes',
              host: 'unused',
              port: 1,
              apiKey: '',
            ),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'Home server-endpoint',
          preferences: preferences,
          appPreferences: alerts.appPreferences,
          gatewayFactory: workspace.gateway,
        );
        await controller.initialize();
        controller.connectionStatus.accessAvailable();
        controller.connectionStatus.liveChanged('personal', true);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            builder: (_, child) => HealthAlertsScope(
              alerts: alerts.coordinator,
              openAlert: (_) async {},
              child: RepaintBoundary(key: frame, child: child!),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                appBar: WingAppBar(
                  context: context,
                  title: const Text('Hermes health'),
                  leading: const BackButton(),
                ),
                body: HermesAdministrationContent(
                  controller: controller,
                  repository: administration.server,
                  onOpenMenu: () {},
                  onOpenSession: (_) async {},
                  healthOnly: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Alert settings'), findsOneWidget);
        expect(find.text('Host'), findsOneWidget);
        expect(find.text('Profile'), findsOneWidget);
        await capture(tester, 'health-${brightness.name}');
        tester.view.physicalSize = const Size(390, 560);
        await tester.pump();
        await tester.drag(find.byType(ListView).last, const Offset(0, -420));
        await tester.pumpAndSettle();
        await capture(tester, 'health-profile-${brightness.name}');
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        administration.server.close();
        alerts.dispose();
      },
    );
  }

  testWidgets('export health alerts and resource thresholds', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // Opt-in screenshot tooling runs outside test/ discovery.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final fixture = HealthAlertsFixture(await SharedPreferences.getInstance());
    fixture.host.stats['memory'] = {
      'total': 34359738368,
      'used': 33432025432,
      'available': 927712936,
      'percent': 97.3,
    };
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(Brightness.light),
        builder: (_, child) => HealthAlertsScope(
          alerts: fixture.coordinator,
          openAlert: (_) async {},
          child: RepaintBoundary(key: frame, child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: WingAppBar(
              context: context,
              title: const Text('Hermes health'),
              leading: const BackButton(),
            ),
            body: AdminHealthContent(
              health: fixture.owner.healthSession().health,
              hostResources: fixture.owner.hostResources(),
              profile: null,
              onRefresh: fixture.owner.hostResources().refresh,
              onOpenDestination: (_) async {},
              accessChecks: () => null,
              onReviewAccess: null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await fixture.critical();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('health-alert-bell')));
    await tester.pumpAndSettle();
    await capture(tester, 'health-alerts-light');
    await tester.tap(find.byTooltip('Close alerts'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('health-alert-settings-entry')));
    await tester.pumpAndSettle();
    expect(find.text('Server problems'), findsNothing);
    expect(find.text('Profile problems'), findsOneWidget);
    await capture(tester, 'alert-settings-light');
    await tester.tap(find.text('Memory usage'));
    await tester.pumpAndSettle();
    await capture(tester, 'alert-thresholds-light');
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('export analytics with 30 days selected', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1040);
    addTearDown(tester.view.reset);
    final fixture = _WebsiteAnalytics();
    addTearDown(fixture.server.close);
    await tester.pumpWidget(
      RepaintBoundary(
        key: frame,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: wingTheme(Brightness.dark),
          home: AnalyticsPage(profile: fixture.server.profile('personal')),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
    await tester.tap(find.text('30D'));
    await tester.pumpAndSettle(const Duration(milliseconds: 250));
    expect(find.text('30D selected'), findsOneWidget);
    expect(find.text('Last 30 days · all models'), findsOneWidget);
    await capture(tester, 'analytics-dark');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final brightness in Brightness.values) {
    testWidgets('export ${brightness.name} website demo screens', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      // This opt-in fixture tool runs under flutter test, outside test/ discovery.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final fixture = _WebsiteFixture();
      final administration = _WebsiteAdministration();
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'Home server',
            label: 'My Hermes',
            host: 'unused',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'Home server-endpoint',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      controller.healthSession(repository: administration.server);
      await controller.initialize();
      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            home: ProfileWorkspaceScreen(controller: controller),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await capture(tester, 'chats-${brightness.name}');

      final switchingController = ProfileWorkspaceController(
        access: controller.access,
        connectionIdentity: 'website-switching',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: _SwitchingFixture().gateway,
      );
      addTearDown(switchingController.dispose);
      await switchingController.initialize();
      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            home: ProfileWorkspaceScreen(
              key: const ValueKey('switching-capture'),
              controller: switchingController,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('chat-profile-personal')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Profile 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-filter-profile')));
      await tester.pump(const Duration(milliseconds: 250));
      await capture(tester, 'profiles-${brightness.name}');
      await tester.tapAt(const Offset(380, 800));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('chat-profile-personal')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('chat-filter-project')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Launch'), findsWidgets);
      expect(find.text('Research'), findsWidgets);
      await capture(tester, 'projects-${brightness.name}');
      await tester.tapAt(const Offset(380, 800));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byTooltip('Chat list options'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Group by…'), findsOneWidget);
      expect(find.text('Sort by…'), findsOneWidget);
      expect(find.text('Show details…'), findsOneWidget);
      await capture(tester, 'workspace-view-${brightness.name}');
      await tester.tapAt(const Offset(380, 800));
      await tester.pump(const Duration(milliseconds: 250));

      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            home: Scaffold(
              appBar: AppBar(title: const Text('Chats')),
              drawer: AppDrawer(
                selected: AppDestination.chats,
                access: controller.access,
                connectionStatus: controller.connectionStatus,
                versionsControllerFactory: (_) => VersionsController(),
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('nav-chats')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-activity')), findsOneWidget);
      await capture(tester, 'navigator-${brightness.name}');
      fixture.liveSessions['personal'] = [
        {
          'id': 'research-runtime',
          'session_key': 'project-only',
          'status': 'working',
          'last_active': fixture.now,
        },
      ];
      fixture.liveSessions['work'] = [
        {
          'id': 'launch-runtime',
          'session_key': 'launch-copy',
          'status': 'waiting',
          'last_active': fixture.now,
        },
      ];
      await controller.refreshRecents();
      expect(controller.recentsProfileErrors, isEmpty);
      expect(
        controller.recentChats().where((chat) => chat.state != null),
        hasLength(2),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            home: ProfileWorkspaceScreen(
              key: const ValueKey('recents'),
              controller: controller,
              initialDestination: AppDestination.activity,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await capture(tester, 'recents-${brightness.name}');
      fixture.liveSessions.clear();
      await controller.refreshActivity();
      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            home: ProfileWorkspaceScreen(
              key: const ValueKey('conversation'),
              controller: controller,
            ),
          ),
        ),
      );
      await tester.tap(find.text('The research, ready to use').first);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.settleMarkdown();
      final chat = controller.current!.chat!;
      controller.current!.gateway.onEvent!(
        StreamEvent(
          type: 'session.usage',
          sessionId: chat.runtime.runtimeId,
          data: const {
            'usage': {
              'context_used': 42000,
              'context_max': 128000,
              'context_percent': 32.8,
              'context_estimated': true,
            },
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await capture(tester, 'conversation-${brightness.name}');

      controller.current!.gateway.onEvent!(
        StreamEvent(
          type: 'message.start',
          sessionId: chat.runtime.runtimeId,
          data: const {},
        ),
      );
      await tester.enterText(
        find.byKey(const Key('profile-message-composer')),
        'Keep the source links in the final report.',
      );
      await tester.pump(const Duration(milliseconds: 250));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ComposerActionButton)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('composer-choice-steer'))),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await capture(tester, 'steer-${brightness.name}');
      await gesture.cancel();

      administration.jobs.add({
        'id': 'morning-brief',
        'name': 'Morning research brief',
        'enabled': true,
        'state': 'scheduled',
        'schedule': {'kind': 'cron', 'expr': '0 8 * * 1-5'},
        'next_run_at': DateTime.now()
            .add(const Duration(hours: 12))
            .toIso8601String(),
      });
      controller.connectionStatus.accessAvailable();
      controller.connectionStatus.liveChanged('personal', true);
      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            home: Scaffold(
              body: HermesAdministrationContent(
                controller: controller,
                repository: administration.server,
                onOpenMenu: () {},
                onOpenSession: (_) async {},
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await capture(tester, 'administration-${brightness.name}');
      expect(find.text('Research model'), findsWidgets);
      expect(find.text('Information unavailable'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());

      tester.view.physicalSize = const Size(390, 800);
      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ProfileMessage(
                  message: TranscriptMessage.fromRow({
                    'role': 'assistant',
                    'content':
                        '## Workshop checklist\n\n**Book a room for 12 people** and plan a 90-minute session.\n\n| Task | Due |\n| --- | --- |\n| Book the room | Monday |\n| Send invitations | Tuesday |\n| Print handouts | Friday |\n\n> Ask about accessibility needs in the invitation.\n\n```python\nfrom pathlib import Path\nreport = Path("workshop-plan.md")\nprint(report.read_text())\n```\n\nThe complete plan: [workshop-plan.md](/workspace/workshop-plan.md)',
                  }),
                  onOpenRemoteFile: (_) async {},
                  onDownloadRemoteFile: (_) async => true,
                  onReadAloud: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await capture(tester, 'results-${brightness.name}');

      tester.view.physicalSize = const Size(390, 400);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: wingTheme(brightness),
          home: RepaintBoundary(
            key: frame,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: ProfileToolCall(
                  initiallyExpanded: true,
                  call: ToolCallPresentation.live(
                    GatewayToolActivity(
                      toolId: 'website-code',
                      name: 'execute_code',
                      phase: GatewayToolActivityPhase.completed,
                      arguments: jsonEncode({
                        'code':
                            'from pathlib import Path\n\nrecords = Path("research.csv")\nrows = records.read_text().splitlines()\nprint(f"Checked {len(rows) - 1} records")',
                      }),
                      result: jsonEncode({
                        'output': 'Checked 7 records\nSource dates preserved',
                        'success': true,
                      }),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await capture(tester, 'tool-${brightness.name}');

      tester.view.physicalSize = const Size(390, 844);
      final activityController = ProfileWorkspaceController(
        access: controller.access,
        connectionIdentity: 'website-activity',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: _ActivityFixture().gateway,
      );
      addTearDown(activityController.dispose);
      await activityController.initialize();
      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            home: ProfileWorkspaceScreen(
              key: const ValueKey('activity-capture'),
              controller: activityController,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('The research, ready to use').first);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.textContaining('Used 3 tools'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Timeline'), findsOneWidget);
      expect(find.text('Tasks 3'), findsOneWidget);
      expect(find.text('Agents 1'), findsOneWidget);
      await tester.settleMarkdown();
      final transcript = tester.widget<ListView>(
        find.byKey(const ValueKey('profile-transcript')),
      );
      transcript.controller!.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Ran code').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Ran code'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.settleMarkdown();
      transcript.controller!.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Timeline').hitTestable(), findsOneWidget);
      expect(find.text('Tasks 3').hitTestable(), findsOneWidget);
      expect(find.text('Agents 1').hitTestable(), findsOneWidget);
      await capture(tester, 'activity-${brightness.name}');

      for (final detail in [
        (
          name: 'code',
          height: 290.0,
          content:
              '```python\nfrom pathlib import Path\nreport = Path("workshop-plan.md")\nprint(report.read_text())\n```',
        ),
        (
          name: 'message-actions',
          height: 190.0,
          content:
              'Book a room for 12 people and plan a 90-minute session. Ask about accessibility needs in the invitation.',
        ),
        (
          name: 'files',
          height: 260.0,
          content:
              'The workshop plan is ready.\n\n[workshop-plan.md](/workspace/workshop-plan.md)',
        ),
      ]) {
        tester.view.physicalSize = Size(390, detail.height);
        await tester.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ProfileMessage(
                    message: TranscriptMessage.fromRow({
                      'role': 'assistant',
                      'content': detail.content,
                    }),
                    onOpenRemoteFile: (_) async {},
                    onDownloadRemoteFile: (_) async => true,
                    onReadAloud: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await capture(tester, '${detail.name}-${brightness.name}');
      }
      if (brightness == Brightness.dark) {
        tester.view.physicalSize = const Size(390, 844);
        await appPreferences.setTheme(AppThemePreference.dark);
        await tester.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              home: ProfileWorkspaceScreen(
                key: const ValueKey('appearance-capture'),
                controller: controller,
                initialDestination: AppDestination.settings,
              ),
            ),
          ),
        );
        await capture(tester, 'appearance-dark', directory: 'docs/screenshots');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
