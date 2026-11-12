import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/screens/bots/bot_screen_view.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/bots_fixture.dart';
import 'dart:convert';
import 'helpers/pump_markdown_widget.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';
import 'support/browser_mutations_fixture.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/widgets/server_connection_label.dart';

const _captureMenu = bool.fromEnvironment('STUDIO_REVIEW');

class _WorkspaceRefreshFixture extends BrowserMutationsFixture {
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {'id': 1, 'role': 'user', 'content': 'Keep this conversation visible'},
  ];
}

Future<void> _capture(WidgetTester tester, GlobalKey frame, String name) async {
  if (!_captureMenu) return;
  await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final rendered = await boundary.toImage();
    final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
    final folder = Directory('build/design-previews/chat-menu')
      ..createSync(recursive: true);
    await File(
      '${folder.path}/$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    rendered.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (!_captureMenu) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Refresh workspace acknowledges held reads ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final host = _WorkspaceRefreshFixture();
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: SavedConnection(
                id: 'host',
                label: 'Home server',
                host: 'localhost',
                port: 1,
                apiKey: '',
              ),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'refresh-feedback',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: host.gateway,
          );
          addTearDown(controller.dispose);
          addTearDown(appPreferences.dispose);
          await controller.initialize();
          final chat = (await controller.openSession(
            ProfileSessionKey(controller.current!.scope, 'newest'),
          ))!;
          await controller.updateDraft(chat, 'Keep my draft');
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () =>
                    BotsSession((_) async => [BotsFixture().repository]),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final slot = find.byKey(const ValueKey('studio-loading-slot'));
          final slotRect = tester.getRect(slot);
          final composer = find.byKey(const Key('profile-message-composer'));
          final composerRect = tester.getRect(composer);
          final actionRect = tester.getRect(find.byTooltip('Chat actions'));
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.text('Keep this conversation visible'), findsOneWidget);
          final automaticGate = Completer<void>();
          host.pageDelays[(chat.key.workspace.profileName, 0)] = automaticGate;
          addTearDown(() {
            if (!automaticGate.isCompleted) automaticGate.complete();
          });
          final automaticRead = controller.switchProfile(
            chat.key.workspace.profileName,
          );
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(tester.getRect(composer), composerRect);
          automaticGate.complete();
          await automaticRead;
          await tester.pumpAndSettle();
          final listGate = Completer<void>();
          final resumeGate = Completer<void>();
          host.pageDelays[(chat.key.workspace.profileName, 0)] = listGate;
          host.rpcDelays['session.resume'] = resumeGate;
          addTearDown(() {
            if (!listGate.isCompleted) listGate.complete();
            if (!resumeGate.isCompleted) resumeGate.complete();
          });
          await tester.tap(find.byTooltip('Chat actions'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Refresh workspace'));
          await tester.pumpAndSettle();
          final pulse = find.byType(StudioLoading);
          expect(pulse, findsOneWidget);
          expect(find.text('Keep this conversation visible'), findsOneWidget);
          final sharedRefresh = controller.refresh();
          expect(controller.refresh(), same(sharedRefresh));
          expect(
            tester.widget<StudioLoading>(pulse).label,
            'Refreshing workspace',
          );
          expect(
            find.ancestor(of: pulse, matching: find.byType(WingAppBar)),
            findsOneWidget,
          );
          expect(slotRect.contains(tester.getCenter(pulse)), isTrue);
          expect(tester.getRect(slot), slotRect);
          expect(tester.getRect(composer), composerRect);
          expect(tester.getRect(find.byTooltip('Chat actions')), actionRect);
          expect(tester.widget<TextField>(composer).enabled, isNot(false));
          final navigator = tester.state<NavigatorState>(
            find.byType(Navigator).first,
          );
          unawaited(
            navigator.push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    const Scaffold(body: Text('Covered conversation')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(pulse, findsNothing);
          navigator.pop();
          await tester.pumpAndSettle();
          expect(pulse, findsOneWidget);
          await _capture(
            tester,
            frame,
            'refresh-${brightness.name}-$scale-held',
          );
          await tester.tap(find.byTooltip('Chat actions'));
          await tester.pumpAndSettle();
          final refreshItem = tester.widget<PopupMenuItem<String>>(
            find.ancestor(
              of: find.text('Refresh workspace'),
              matching: find.byWidgetPredicate(
                (w) => w is PopupMenuItem<String>,
              ),
            ),
          );
          expect(refreshItem.enabled, isFalse);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          listGate.complete();
          await tester.pumpAndSettle();
          expect(resumeGate.isCompleted, isFalse);
          expect(
            pulse,
            findsOneWidget,
            reason: 'feedback lasts through runtime recovery',
          );
          resumeGate.complete();
          await sharedRefresh;
          await tester.pumpAndSettle();
          expect(pulse, findsNothing);
          expect(controller.current!.chat, same(chat));
          expect(find.text('Keep this conversation visible'), findsOneWidget);
          expect(chat.composer.observation.displayedText, 'Keep my draft');
          expect(tester.getRect(slot), slotRect);
          expect(tester.getRect(composer), composerRect);
          expect(tester.getRect(find.byTooltip('Chat actions')), actionRect);
          await _capture(
            tester,
            frame,
            'refresh-${brightness.name}-$scale-ready',
          );
          final failureGate = Completer<void>();
          host.pageDelays[(chat.key.workspace.profileName, 0)] = failureGate;
          host.pageFailures.add((chat.key.workspace.profileName, 0));
          addTearDown(() {
            if (!failureGate.isCompleted) failureGate.complete();
          });
          await tester.tap(find.byTooltip('Chat actions'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Refresh workspace'));
          await tester.pumpAndSettle();
          expect(pulse, findsOneWidget);
          failureGate.complete();
          await tester.pumpAndSettle();
          expect(pulse, findsNothing);
          expect(controller.refreshingWorkspace, isFalse);
          expect(find.text('Page offline'), findsOneWidget);
          expect(find.text('Keep this conversation visible'), findsOneWidget);
          expect(chat.composer.observation.displayedText, 'Keep my draft');
          await tester.tap(find.byTooltip('Chat actions'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<PopupMenuItem<String>>(
                  find.ancestor(
                    of: find.text('Refresh workspace'),
                    matching: find.byWidgetPredicate(
                      (w) => w is PopupMenuItem<String>,
                    ),
                  ),
                )
                .enabled,
            isTrue,
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          host.pageFailures.clear();
          final retirementGate = Completer<void>();
          host.pageDelays[(chat.key.workspace.profileName, 0)] = retirementGate;
          addTearDown(() {
            if (!retirementGate.isCompleted) retirementGate.complete();
          });
          final retiredRefresh = controller.refresh();
          await tester.pumpAndSettle();
          expect(pulse, findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          retirementGate.complete();
          await retiredRefresh;
          await tester.pumpAndSettle();
          expect(pulse, findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final category in ['tasks', 'agents']) {
    testWidgets('saved history restores the $category activity tab', (
      tester,
    ) async {
      final name = category == 'tasks' ? 'todo_list' : 'delegate_task';
      final arguments = category == 'tasks'
          ? <String, dynamic>{}
          : {
              'tasks': [
                {'goal': 'Inspect the saved delegation'},
              ],
            };
      final result = category == 'tasks'
          ? {
              'revision': 2,
              'todos': [
                {
                  'id': 'one',
                  'content': 'Inspect the saved task',
                  'status': 'completed',
                },
              ],
            }
          : {
              'results': [
                {
                  'task_index': 0,
                  'status': 'completed',
                  'summary': 'Inspection complete',
                  'duration_seconds': 42.5,
                  'model': 'test-model',
                  'api_calls': 3,
                },
              ],
              'total_duration_seconds': 43,
            };
      final rows = <Map<String, dynamic>>[
        {
          'id': 1,
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call',
              'type': 'function',
              'function': {'name': name, 'arguments': jsonEncode(arguments)},
            },
          ],
        },
        {
          'id': 2,
          'role': 'tool',
          'tool_call_id': 'call',
          'content': jsonEncode(result),
        },
      ];
      final timeline = TranscriptTimeline.project(
        rows,
        presentationId: (row) => row['id']!,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProfileToolActivitySection(section: timeline.sections.single),
              ],
            ),
          ),
        ),
      );
      await tester.tap(
        find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
      );
      await tester.pumpAndSettle();
      final tab = find.byKey(ValueKey(('activity-tab', category)));
      expect(tab, findsOneWidget);
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(
        find.text(
          category == 'tasks'
              ? 'Inspect the saved task'
              : 'Inspect the saved delegation',
        ),
        findsOneWidget,
      );
      if (category == 'agents') {
        expect(find.text('43 s'), findsOneWidget);
        await tester.tap(find.text('Inspect the saved delegation'));
        await tester.pumpAndSettle();
        await tester.settleMarkdown();
        expect(
          find.text('Inspection complete', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('Steer'), findsNothing);
        expect(find.text('Interrupt'), findsNothing);
      }
    });
  }

  testWidgets('saved and live tool calls share their Activity', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final host = ProfileActionsFixture();
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'combined-activity',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    chat.reading.installSavedHistory([
      ...chat.reading.messages,
      ...[
        {'id': 1, 'role': 'user', 'content': 'Continue searching'},
        for (var id = 2; id <= 68; id++)
          {
            'id': id,
            'role': 'tool',
            'tool_name': 'Search',
            'content': 'Result $id',
          },
      ],
    ]);
    emitChatEvent(controller, chat, 'message.start', {});
    emitChatEvent(controller, chat, 'tool.start', {
      'name': 'terminal',
      'tool_id': 'live',
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('live-activity-toggle')),
      findsOneWidget,
    );
    expect(find.text('Tool activity'), findsNothing);
    expect(find.text('68 tools'), findsOneWidget);
    expect(find.text('Activity · 1 tool'), findsNothing);
    expect(find.text('Timeline'), findsNothing);
    expect(find.text('Running command'), findsNothing);
    expect(find.text('Search'), findsNothing);
    await tester.openLiveActivity();
    await tester.pumpAndSettle();
    expect(find.text('Search'), findsNWidgets(67));
    expect(find.text('Timeline'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Keep Activity open while typing',
    );
    await tester.pump();
    expect(find.text('Search'), findsNWidgets(67));
    await Scrollable.ensureVisible(
      tester.element(find.text('Search').first),
      alignment: 0.3,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search').first);
    await tester.pumpAndSettle();
    expect(find.text('Result 68'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final canonical in [false, true]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'shared chat menu and screen for ${canonical ? 'canonical' : 'ordinary'} in ${brightness.name} at $scale',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final appPreferences = AppPreferences(preferences);
            final host = ProfileActionsFixture();
            final controller = ProfileWorkspaceController(
              access: ConnectionAccess(
                connection: SavedConnection(
                  id: 'host',
                  label: 'Home server',
                  host: 'localhost',
                  port: 1,
                  apiKey: '',
                ),
                dashboardOAuth: null,
              ),
              connectionIdentity: 'instance-1',
              preferences: preferences,
              appPreferences: appPreferences,
              gatewayFactory: host.gateway,
            );
            addTearDown(controller.dispose);
            addTearDown(appPreferences.dispose);
            await controller.initialize();
            final chat = await controller.createChat(canDispatch: () => true);
            final fixture = BotsFixture(server: controller.administration());
            fixture.profiles
              ..clear()
              ..add(
                BotsFixture.profile(chat.key.workspace.profileName, 'Pace'),
              );
            fixture.profiles.single['canonical_session'] = {
              'id': canonical ? chat.key.sessionId : 'another-chat',
            };
            final screenReads = <String>[];
            fixture.readHook = (profile, method, _) async {
              if (method.startsWith('display.')) screenReads.add(profile);
              return null;
            };
            emitChatEvent(controller, chat, 'tool.start', {
              'name': 'terminal',
              'tool_id': 'live',
            });
            emitChatEvent(controller, chat, 'subagent.start', {
              'subagent_id': 'child',
              'goal': 'Inspect the release',
            });
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final frame = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(key: frame, child: child!),
                ),
                home: ProfileWorkspaceScreen(
                  controller: controller,
                  createBotsSession: () =>
                      BotsSession((_) async => [fixture.repository]),
                ),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump(const Duration(milliseconds: 300));
            final name =
                '${canonical ? 'canonical' : 'ordinary'}-${brightness.name}-$scale';
            expect(find.text('Activity · 1 tool'), findsOneWidget);
            await _capture(tester, frame, '$name-chat');
            await tester.tap(find.byTooltip('Chat actions'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump(const Duration(milliseconds: 300));
            final items = tester
                .widgetList<PopupMenuItem<String>>(
                  find.byWidgetPredicate(
                    (widget) => widget is PopupMenuItem<String>,
                  ),
                )
                .map((item) => item.value)
                .toList();
            expect(items, ['screen', 'outputs', 'find', 'git', 'car', 'refresh']);
            expect(find.byType(PopupMenuDivider), findsOneWidget);
            for (final label in [
              'View screen',
              'Outputs',
              'Git review',
              'Find in chat',
              'Refresh workspace',
            ]) {
              final target = tester.getRect(
                find.ancestor(
                  of: find.text(label),
                  matching: find.byWidgetPredicate(
                    (widget) => widget is PopupMenuItem<String>,
                  ),
                ),
              );
              expect(target.height, greaterThanOrEqualTo(48));
              expect(target.left, greaterThanOrEqualTo(0));
              expect(
                target.right,
                lessThanOrEqualTo(tester.view.physicalSize.width),
              );
            }
            expect(find.text('Subagents'), findsNothing);
            expect(find.text('Goal'), findsNothing);
            expect(find.text('Background work'), findsNothing);
            await _capture(tester, frame, '$name-menu');
            await tester.tap(find.text('View screen'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.byType(BotScreenView), findsOneWidget);
            expect(find.text('Pace screen'), findsOneWidget);
            controller.connectionStatus
              ..accessAvailable()
              ..liveChanged(chat.key.workspace.profileName, true);
            await tester.pump();
            await _capture(tester, frame, '$name-screen-connected');
            final connectionLabel = find.descendant(
              of: find.byType(BotScreenView),
              matching: find.byType(ServerConnectionLabel),
            );
            expect(
              tester.widget<ServerConnectionLabel>(connectionLabel).status,
              same(controller.connectionStatus),
              reason:
                  'The pushed desktop route must retain live connection status',
            );
            final led = find.descendant(
              of: find.byType(BotScreenView),
              matching: find.byKey(const ValueKey('server-connection-led')),
            );
            final tokens = Theme.of(
              tester.element(led),
            ).extension<WingTokens>()!;
            Color? ledColor() =>
                (tester.widget<Container>(led).decoration! as BoxDecoration)
                    .color;
            expect(ledColor(), tokens.success);
            controller.connectionStatus.beginRecovery('screen-test');
            await tester.pump();
            expect(ledColor(), tokens.warning);
            await _capture(tester, frame, '$name-screen-reconnecting');
            controller.connectionStatus.failRecovery(
              'screen-test',
              'Connection interrupted',
            );
            await tester.pump();
            expect(ledColor(), tokens.danger);
            await _capture(tester, frame, '$name-screen-disconnected');
            await tester.tap(find.byTooltip('Connection details'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.text('Connection interrupted'), findsOneWidget);
            Navigator.of(tester.element(find.text('Connection details'))).pop();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            controller.connectionStatus.endRecovery('screen-test');
            await tester.pump();
            expect(ledColor(), tokens.success);
            expect(screenReads, isNotEmpty);
            expect(screenReads, everyElement(chat.key.workspace.profileName));
            expect(fixture.commands, isEmpty);
            Navigator.of(tester.element(find.byType(BotScreenView))).pop();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.byType(BotScreenView), findsNothing);
            expect(controller.current!.chat, same(chat));
            expect(find.text('Activity · 1 tool'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  test('screen opening retires an overtaken profile read', () async {
    final fixture = BotsFixture();
    final gate = Completer<Map<String, dynamic>?>();
    final started = Completer<void>();
    fixture.readHook = (_, method, _) {
      if (method != 'profiles.list') return Future.value(null);
      started.complete();
      return gate.future;
    };
    final session = BotsSession((_) async => [fixture.repository]);
    addTearDown(session.dispose);
    var current = true;
    final opening = session.openScreen(
      WorkspaceScope(
        connectionId: 'host',
        connectionIdentity: 'instance-1',
        profileName: 'atlas',
      ),
      canUse: () => current,
    );
    await started.future;
    current = false;
    gate.complete(null);
    expect(await opening, isNull);
    expect(fixture.commands, isEmpty);
  });
}
