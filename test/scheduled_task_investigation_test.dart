import 'support/canonical_gateway_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/scheduled_task.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'package:wing/core/screens/administration/admin_widgets.dart';
import 'package:wing/core/screens/administration/admin_scheduled_task_detail_page.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/scheduled_tasks_controller.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';

import 'support/profile_browser_fixture.dart';
import 'support/administration_fixture.dart';
import 'support/scheduled_tasks_fixture.dart';

const _error =
    'Script exited with code 1\nstderr:\n'
    '{"status": "partial", "error": "ValueError", "records": 87}';
const _frame = ValueKey('investigation-capture');

class _Fixture {
  final tasks = ScheduledTasksFixture();
  final browser = ProfileBrowserFixture();
  late ProfileWorkspaceController workspace;
  late ScheduledTasksController controller;
  final creates = <(String, Map<String, dynamic>)>[];
  final sends = <(String, Map<String, dynamic>)>[];
  final screenKey = GlobalKey<ProfileWorkspaceScreenState>();
  Completer<void>? createGate, sendGate, historyGate;
  bool failCreate = false, failHistory = false;

  Future<void> initialize() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tasks.jobs['morning']!['last_error'] = _error;
    final stock = AdministrationFixture();
    addTearDown(stock.server.close);
    tasks.admin.override = (method, path, query, body) =>
        path.startsWith('cron/') || path == 'platforms'
        ? tasks.send(method, path, query, body)
        : stock.send(method, path, query, body);
    controller = ScheduledTasksController(
      ScheduledTasksRepository(tasks.profile),
      prefs,
    );
    await controller.refresh();
    workspace = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: tasks.admin.server.connectionId,
          label: 'Home',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: tasks.admin.server.connectionIdentity,
      preferences: prefs,
      appPreferences: AppPreferences(prefs),
      gatewayFactory: (scope) {
        final source = browser.gateway(scope);
        return ProfileGateway(
          scope: scope,
          discover: source.discover,
          get: (path, query) async {
            if (path == 'model/options') {
              return {'providers': <Object>[], 'models': <Object>[]};
            }
            if (path.startsWith('sessions/investigation-')) {
              final id = Uri.decodeComponent(path.split('/')[1]);
              if (path.endsWith('/messages')) {
                await historyGate?.future;
                if (failHistory) throw StateError('History unavailable');
                final sent = sends
                    .where(
                      (row) =>
                          row.$1 == scope.profileName &&
                          row.$2['session_id'] ==
                              'runtime-${id.split('-').last}',
                    )
                    .firstOrNull;
                final messages = <Map<String, dynamic>>[
                  if (sent != null)
                    {
                      'role': 'user',
                      'content': sent.$2['text'],
                      'timestamp': 1789606800,
                    },
                ];
                return {
                  'session_id': id,
                  'messages': messages,
                  'pagination': {
                    'offset': int.parse(query['offset'] ?? '0'),
                    'limit': int.parse(query['limit'] ?? '50'),
                    'returned': messages.length,
                    'order': 'latest',
                  },
                };
              }
              return {
                'id': id,
                'profile': scope.profileName,
                'source': 'desktop',
                'title': 'New chat',
                'is_hidden': false,
                'archived': false,
              };
            }
            return source.read(path, query);
          },
          rpc: (method, params) async {
            if (method == 'session.create') {
              creates.add((scope.profileName, Map.of(params)));
              final number = creates.length;
              await createGate?.future;
              if (failCreate) throw StateError('offline');
              return {
                ...canonicalSnapshotFields,
                'session_id': 'runtime-$number',
                'stored_session_id': 'investigation-$number',
                'messages': [],
                'info': {'profile_name': scope.profileName},
              };
            }
            if (method == 'session.resume' &&
                params['session_id'].toString().startsWith('runtime-')) {
              final number = params['session_id'].toString().split('-').last;
              return {
                ...canonicalSnapshotFields,
                'session_id': params['session_id'],
                'stored_session_id': 'investigation-$number',
                'messages': <Map<String, dynamic>>[],
                'info': {'profile_name': scope.profileName},
              };
            }
            if (method == 'prompt.submit') {
              sends.add((scope.profileName, Map.of(params)));
              await sendGate?.future;
              return canonicalReceipt(
                params,
                admissionId: 'investigation-${params['submission_id']}',
              );
            }
            return source.call(method, params);
          },
        );
      },
    );
    workspace.healthSession(repository: tasks.admin.server);
    await workspace.initialize();
  }

  Widget root({
    AppDestination destination = AppDestination.chats,
    ScheduledTaskInvestigationRequest? initial,
  }) => ProfileWorkspaceScreen(
    key: screenKey,
    controller: workspace,
    initialDestination: destination,
    initialInvestigation: initial,
    createBotsSession: () => BotsSession((_) async => []),
  );

  Widget page() => AdminScheduledTaskDetailPage(
    controller: controller,
    initial: controller.task('morning')!,
    onOpenSession: (_) async {},
    onInvestigate: (request) {
      Navigator.of(
        screenKey.currentContext!,
      ).popUntil((route) => route.isFirst);
      unawaited(screenKey.currentState!.openTaskInvestigation(request));
    },
  );

  void dispose() {
    workspace.dispose();
    workspace.appPreferences.dispose();
    controller.dispose();
    tasks.admin.server.close();
  }
}

void main() {
  setUpAll(() async {
    final config = File('.dart_tool/package_config.json').absolute;
    final packages =
        (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
    final flutter = packages.cast<Map>().singleWhere(
      (package) => package['name'] == 'flutter',
    );
    final sdk = Directory.fromUri(
      config.uri.resolve(flutter['rootUri'] as String),
    ).parent.parent;
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '${sdk.path}/bin/cache/artifacts/material_fonts/${font.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
    await (FontLoader('WingIcons')..addFont(
          File(
            'assets/fonts/wing-icons.ttf',
          ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
        ))
        .load();
  });
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture();
    await fixture.initialize();
  });
  tearDown(() => fixture.dispose());

  Future<void> pump(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
    double scale = 1,
    bool administration = false,
  }) async {
    tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: RepaintBoundary(key: _frame, child: child!),
        ),
        home: fixture.root(
          destination: administration
              ? AppDestination.administration
              : AppDestination.chats,
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (administration) {
      await tester.scrollUntilVisible(
        find.text('Scheduled tasks'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Scheduled tasks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Morning briefing'));
    } else {
      unawaited(
        Navigator.of(
          fixture.screenKey.currentContext!,
        ).push<void>(MaterialPageRoute(builder: (_) => fixture.page())),
      );
    }
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Ask personal'),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('task-detail-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('Last run needs attention')),
      alignment: 0.05,
    );
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(WidgetTester tester, bool Function() settled) async {
    for (var attempt = 0; attempt < 100 && !settled(); attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    if (!settled()) {
      debugPrint(
        'Destination state: sends=${fixture.sends.length}, creates=${fixture.creates.length}, messages=${fixture.workspace.current?.chat?.reading.messages.length}, errors=${tester.widgetList<StudioError>(find.byType(StudioError)).map((w) => w.message).toList()}, waits=${tester.widgetList<StudioLoading>(find.byType(StudioLoading)).map((w) => w.label).toList()}',
      );
    }
    expect(settled(), isTrue, reason: 'The expected action did not settle');
    await tester.pump();
  }

  bool preparing(WidgetTester tester) => find
      .byWidgetPredicate(
        (widget) =>
            widget is StudioLoading &&
            widget.label == 'Opening investigation chat',
      )
      .evaluate()
      .isNotEmpty;
  bool destinationReady(WidgetTester tester) =>
      find
          .textContaining('The last run of scheduled task', findRichText: true)
          .evaluate()
          .isNotEmpty &&
      !preparing(tester);

  testWidgets(
    'Ask enters the destination while creation is held, targets its profile and clears project',
    (tester) async {
      await fixture.workspace.switchProfile('work');
      await fixture.workspace.selectProject(
        fixture.workspace.current!.projects.first,
      );
      fixture.createGate = Completer<void>();
      await pump(tester);
      expect(find.byType(AdminAskHermesButton), findsOneWidget);
      await tester.tap(find.text('Ask personal'));
      // Let the departing MaterialPageRoute finish its reverse transition.
      // Backend creation remains held; it cannot make navigation pass.
      await tester.pumpAndSettle();
      expect(find.byType(AdminScheduledTaskDetailPage), findsNothing);
      expect(find.text('New chat'), findsOneWidget);
      expect(find.byType(ProfileMessage), findsNothing);
      expect(preparing(tester), isTrue);
      expect(fixture.sends, isEmpty);
      fixture.createGate!.complete();
      await waitFor(tester, () => destinationReady(tester));
      expect(fixture.creates.single.$1, 'personal');
      expect(fixture.creates.single.$2['cwd'], isNull);
      expect(fixture.sends.single.$1, 'personal');
      final prompt = fixture.sends.single.$2['text'] as String;
      expect(prompt, contains('Morning briefing'));
      expect(prompt, contains('task ID: morning'));
      expect(prompt, contains('2026-09-17T01:00:00.000Z'));
      expect(prompt, contains(_error));
      expect(prompt, contains('Please investigate'));
      final chat = fixture.workspace.current!.chat!;
      expect(chat.key.workspace, fixture.tasks.profile.scope);
      expect(chat.key.sessionId, 'investigation-1');
      expect(chat.projectId, isNull);
      expect(
        fixture.browser.calls.where((call) => call.$2 == 'session.resume'),
        isEmpty,
      );
      expect(fixture.workspace.current!.selectedProject, isNull);
      expect(chat.composer.observation.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'production Administration retires task routes before creation completes',
    (tester) async {
      fixture.createGate = Completer<void>();
      await pump(tester, administration: true);
      await tester.tap(find.text('Ask personal'));
      await tester.pumpAndSettle();
      expect(find.byType(AdminScheduledTaskDetailPage), findsNothing);
      expect(find.text('New chat'), findsOneWidget);
      expect(preparing(tester), isTrue);
      expect(fixture.creates, hasLength(1));
      fixture.createGate!.complete();
      await waitFor(tester, () => destinationReady(tester));
      expect(fixture.sends, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'health-alert initial entry shows the destination on its first frame',
    (tester) async {
      fixture.createGate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: fixture.root(
            initial: ScheduledTaskInvestigationRequest(
              owner: fixture.tasks.profile.scope,
              task: fixture.controller.task('morning')!,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('New chat'), findsOneWidget);
      expect(find.byType(AdminScheduledTaskDetailPage), findsNothing);
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(fixture.creates, hasLength(1));
      fixture.createGate!.complete();
      await waitFor(tester, () => destinationReady(tester));
      expect(fixture.sends, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'destination owns one pulse through held creation, history and send',
    (tester) async {
      fixture.createGate = Completer<void>();
      fixture.historyGate = Completer<void>();
      fixture.sendGate = Completer<void>();
      await pump(tester);
      await tester.tap(find.text('Ask personal'));
      await tester.pumpAndSettle();
      final back = tester.getRect(find.byTooltip('Back'));
      expect(fixture.creates, hasLength(1));
      expect(find.byType(AdminScheduledTaskDetailPage), findsNothing);
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(preparing(tester), isTrue);
      fixture.createGate!.complete();
      await tester.pumpAndSettle();
      expect(fixture.sends, isEmpty);
      expect(preparing(tester), isTrue);
      expect(tester.getRect(find.byTooltip('Back')), back);
      fixture.historyGate!.complete();
      await waitFor(tester, () => fixture.sends.isNotEmpty);
      expect(preparing(tester), isTrue);
      expect(find.byType(ProfileMessage), findsNothing);
      expect(tester.getRect(find.byTooltip('Back')), back);
      fixture.sendGate!.complete();
      await waitFor(tester, () => destinationReady(tester));
      expect(fixture.creates, hasLength(1));
      expect(fixture.sends, hasLength(1));
      expect(preparing(tester), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('creation failure and Retry stay at the new chat destination', (
    tester,
  ) async {
    fixture.failCreate = true;
    await pump(tester);
    await tester.tap(find.text('Ask personal'));
    await tester.pumpAndSettle();
    expect(find.byType(AdminScheduledTaskDetailPage), findsNothing);
    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);
    expect(preparing(tester), isFalse);
    expect(fixture.sends, isEmpty);
    fixture.failCreate = false;
    await tester.tap(find.byTooltip('Retry'));
    await waitFor(tester, () => destinationReady(tester));
    expect(fixture.sends, hasLength(1));
    expect(fixture.creates, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'history retry reuses the created chat without submitting duplicates',
    (tester) async {
      fixture.failHistory = true;
      await pump(tester);
      await tester.tap(find.text('Ask personal'));
      await waitFor(
        tester,
        () => find.byTooltip('Retry').evaluate().isNotEmpty,
      );
      expect(fixture.creates, hasLength(1));
      fixture.failHistory = false;
      await tester.tap(find.byTooltip('Retry'));
      await waitFor(tester, () => destinationReady(tester));
      expect(fixture.creates, hasLength(1));
      expect(fixture.sends, hasLength(1));
      expect(fixture.workspace.current!.chat!.key.sessionId, 'investigation-1');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Back during creation retires navigation and keeps a created draft unsent',
    (tester) async {
      fixture.createGate = Completer<void>();
      await pump(tester);
      await tester.tap(find.text('Ask personal'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      fixture.createGate!.complete();
      await tester.pumpAndSettle();
      expect(fixture.sends, isEmpty);
      expect(preparing(tester), isFalse);
      final chat = fixture.workspace
          .browserResource('personal')
          .chats['investigation-1']!;
      expect(chat.composer.observation.text, contains(_error));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'copy preserves exact error and shows pending, copied and failure feedback',
    (tester) async {
      final clipboard = <String>[];
      var gate = Completer<void>();
      var fail = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
            await gate.future;
            if (fail) throw PlatformException(code: 'unavailable');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(tester);
      await tester.tap(find.byTooltip('Copy task error'));
      await tester.pump();
      expect(find.byTooltip('Copy task error: copying'), findsOneWidget);
      expect(clipboard.single, _error);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Copy task error: copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      gate = Completer<void>();
      fail = true;
      await tester.tap(find.byTooltip('Copy task error'));
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Could not copy this text. Try again.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('unknown run time is qualified in the investigation prompt', () async {
    fixture.tasks.jobs['morning']!.remove('last_run_at');
    await fixture.controller.refresh();
    final task = fixture.controller.task('morning')!;
    expect(task.failureInvestigationPrompt, contains(_error));
    expect(
      task.failureInvestigationPrompt,
      contains('run time was not recorded'),
    );
  });

  testWidgets('healthy run omits failure actions', (tester) async {
    fixture.tasks.jobs['morning']!.remove('last_error');
    await fixture.controller.refresh();
    await tester.pumpWidget(
      MaterialApp(theme: wingTheme(Brightness.dark), home: fixture.page()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Morning briefing'), findsOneWidget);
    expect(find.text('Ask personal'), findsNothing);
    expect(find.byTooltip('Copy task error'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('profile change during submission suppresses late navigation', (
    tester,
  ) async {
    fixture.sendGate = Completer<void>();
    await pump(tester);
    await tester.tap(find.text('Ask personal'));
    await waitFor(tester, () => fixture.sends.isNotEmpty);
    await fixture.workspace.switchProfile('work');
    fixture.sendGate!.complete();
    await waitFor(
      tester,
      () => find
          .text('Chat saved in personal. Open it from Chats.')
          .evaluate()
          .isNotEmpty,
    );
    expect(fixture.workspace.current!.scope.profileName, 'work');
    expect(fixture.sends, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_TASK_INVESTIGATION')) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_frame),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/design-previews/task-investigation/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final long in [false, true]) {
        testWidgets(
          'failure controls render ${brightness.name} $scale long=$long',
          (tester) async {
            if (long) {
              fixture.tasks.jobs['morning']!['last_error'] = '$_error\n' * 12;
              await fixture.controller.refresh();
            }
            await pump(tester, brightness: brightness, scale: scale);
            expect(find.byTooltip('Copy task error'), findsOneWidget);
            expect(tester.takeException(), isNull);
            final name = '${brightness.name}-$scale-${long ? 'long' : 'short'}';
            await capture(tester, '$name-ready');
            fixture.createGate = Completer<void>();
            fixture.failCreate = true;
            await tester.tap(find.text('Ask personal'));
            await tester.pumpAndSettle();
            expect(find.byType(StudioLoading), findsOneWidget);
            await capture(tester, '$name-opening');
            fixture.createGate!.complete();
            await tester.pumpAndSettle();
            expect(find.byType(StudioLoading), findsNothing);
            expect(find.text('offline'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await capture(tester, '$name-failed');
            fixture.failCreate = false;
            await tester.tap(find.byTooltip('Retry'));
            await waitFor(tester, () => destinationReady(tester));
            expect(fixture.sends, hasLength(1));
            expect(tester.takeException(), isNull);
            await capture(tester, '$name-complete');
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
