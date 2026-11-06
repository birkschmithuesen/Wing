import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/voice_processing_settings.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/screens/bots/bot_group_history_screen.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/services/bot_group_history_session.dart';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bots_preferences.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/profile_live_execution.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/widgets/chat_inline_image.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';

import 'support/bots_fixture.dart';
import 'support/composer_fixture.dart';
import 'support/profile_browser_fixture.dart';

const _capture = bool.fromEnvironment('CAPTURE_CONVERSATION_ROUTES');
String _receiptImage() {
  final pixels = img.Image(width: 160, height: 96);
  for (var y = 0; y < pixels.height; y++) {
    for (var x = 0; x < pixels.width; x++) {
      pixels.setPixelRgb(x, y, 35 + x, 85 + y, 110);
    }
  }
  return 'data:image/png;base64,${base64Encode(img.encodePng(pixels))}';
}

final _imageReceipt = {
  'tool_id': 'received-image',
  'name': 'vision_analyze',
  'result': {
    '_multimodal': true,
    'content': [
      {
        'type': 'image_url',
        'image_url': {'url': _receiptImage()},
      },
    ],
    'meta': {'native_vision': true},
  },
};

void _expectCollapsedActivity() {
  final live = find.byType(ProfileLiveExecution);
  expect(live, findsOneWidget);
  expect(
    find.descendant(
      of: live,
      matching: find.byType(ProfileToolCall, skipOffstage: false),
      skipOffstage: false,
    ),
    findsNothing,
  );
  expect(
    find.descendant(
      of: live,
      matching: find.byType(MarkdownMessageContent, skipOffstage: false),
      skipOffstage: false,
    ),
    findsOneWidget,
  );
}

Future<void> _inspectLiveImage(
  WidgetTester tester,
  GlobalKey frame,
  String name,
) async {
  final live = find.byType(ProfileLiveExecution);
  final section = tester.widget<ProfileActivitySection>(
    find.descendant(of: live, matching: find.byType(ProfileActivitySection)),
  );
  final header = find.descendant(of: live, matching: find.text(section.label));
  await Scrollable.ensureVisible(tester.element(header), alignment: 0.5);
  await _frames(tester);
  await tester.tap(header);
  await _frames(tester);
  final call = find.descendant(
    of: live,
    matching: find.byType(ProfileToolCall),
  );
  final title = find.descendant(
    of: call,
    matching: find.text(tester.widget<ProfileToolCall>(call).call.title),
  );
  await Scrollable.ensureVisible(tester.element(title), alignment: 0.5);
  await _frames(tester);
  await tester.tap(title);
  await _frames(tester);
  final image = find.descendant(of: call, matching: find.byType(Image));
  expect(image, findsOneWidget);
  final element = image.evaluate().single;
  await tester.runAsync(
    () => precacheImage((element.widget as Image).image, element),
  );
  await _frames(tester);
  final preview = find.descendant(
    of: call,
    matching: find.byTooltip('Preview image'),
  );
  await Scrollable.ensureVisible(tester.element(preview), alignment: 0.5);
  await _frames(tester);
  await _render(tester, frame, '$name-image');
  await tester.tap(preview);
  await _frames(tester);
  await tester.pump(const Duration(milliseconds: 600));
  expect(find.byType(InteractiveViewer), findsOneWidget);
  await tester.tap(find.byTooltip('Back').hitTestable());
  await _frames(tester);
  await tester.pump(const Duration(milliseconds: 600));
  await Scrollable.ensureVisible(tester.element(header), alignment: 0.5);
  await _frames(tester);
  await tester.tap(header);
  await _frames(tester);
  expect(find.byType(ChatInlineImage), findsNothing);
  final latest = find.byKey(const ValueKey('jump-to-latest'));
  if (latest.evaluate().isNotEmpty) {
    await tester.tap(latest);
    await _frames(tester);
  }
}

class _CanonicalFixture extends ProfileBrowserFixture {
  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    {
      'id': 'canonical',
      'title': 'Bot Chat',
      'profile': profile,
      'last_active': now,
      'unread': false,
    },
  ];

  final messages = <Map<String, dynamic>>[
    {'id': 1, 'role': 'user', 'content': 'Review the shared renderer.'},
  ];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => messages;
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (tester
        .stateList<BackgroundMarkdownContentState>(
          find.byType(BackgroundMarkdownContent, skipOffstage: false),
        )
        .any((state) => state.pending)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
  }
}

Future<void> _render(WidgetTester tester, GlobalKey frame, String name) async {
  if (!_capture) return;
  await _frames(tester);
  await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(
      'build/design-previews/conversation-presentation/site/renders/$name.png',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _open(
  WidgetTester tester, {
  required Widget screen,
  required Brightness brightness,
  required double scale,
  required GlobalKey frame,
}) async {
  tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: wingTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: scale == 2,
        ),
        child: RepaintBoundary(key: frame, child: child!),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => screen)),
            child: const Text('Open conversation'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open conversation'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  expect(find.byType(screen.runtimeType), findsOneWidget);
  await _frames(tester);
}

void _expectHeaderWait(WidgetTester tester) {
  final indicator = find.byType(StudioLoading);
  expect(indicator, findsOneWidget);
  expect(
    find.ancestor(of: indicator, matching: find.byType(WingAppBar)),
    findsOneWidget,
  );
  expect(tester.getSize(indicator).shortestSide, greaterThan(0));
}

Finder _answer(String text) => find.ancestor(
  of: find.byWidgetPredicate(
    (widget) => widget is MarkdownMessageContent && widget.data == text,
  ),
  matching: find.byType(ProfileMessage),
);

IconButton _copy(WidgetTester tester, Finder message) =>
    tester.widget<IconButton>(
      find.descendant(
        of: message,
        matching: find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Copy message',
        ),
      ),
    );

void main() {
  late BotsPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await BotsPreferences.load();
  });
  setUpAll(() async {
    if (!_capture) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': '$directory/Roboto-Regular.ttf',
      'MaterialIcons': '$directory/MaterialIcons-Regular.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            Future.value(
              ByteData.sublistView(await File(font.value).readAsBytes()),
            ),
          ))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      final variant =
          '${brightness.name}-${scale == 1 ? '390-100' : '320-200'}';
      testWidgets(
        'canonical bot route shares streaming and copy behavior $variant',
        (tester) async {
          final storedPreferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(storedPreferences);
          addTearDown(appPreferences.dispose);
          final browser = _CanonicalFixture();
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
            preferences: storedPreferences,
            appPreferences: appPreferences,
            gatewayFactory: (scope) {
              final base = browser.gateway(scope);
              return ProfileGateway(
                scope: scope,
                discover: base.discover,
                get: (path, query) async => path == 'model/options'
                    ? {'providers': <Object>[]}
                    : base.read(path, query),
                rpc: base.call,
                ownedPatch: (endpoint, body, canDispatch, onDispatched) async {
                  expect(canDispatch(), isTrue);
                  expect(body['unread'], isFalse);
                  onDispatched();
                  return {'ok': true, 'unread': false};
                },
              );
            },
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          final chat = await openFixtureChat(
            controller: controller,
            key: ProfileSessionKey(controller.current!.scope, 'canonical'),
          );
          final bots = BotsFixture();
          bots.profiles
            ..clear()
            ..add(BotsFixture.profile(chat.key.workspace.profileName, 'Atlas'));
          bots.profiles.single['canonical_session'] = {
            'id': 'canonical',
            'resolved_id': 'canonical',
          };
          final frame = GlobalKey();
          await _open(
            tester,
            brightness: brightness,
            scale: scale,
            frame: frame,
            screen: ProfileWorkspaceScreen(
              controller: controller,
              createBotsSession: () =>
                  BotsSession((_) async => [bots.repository]),
            ),
          );
          emitChatEvent(controller, chat, 'message.start');
          emitChatEvent(controller, chat, 'message.delta', {
            'text': 'The shared',
          });
          await _frames(tester);
          final initial = _answer('The shared');
          expect(initial, findsOneWidget);
          expect(_copy(tester, initial).onPressed, isNull);
          final message = tester.widget<ProfileMessage>(initial).message;
          final bubble = find.byKey(
            ValueKey(('bot-message-bubble', message.id)),
          );
          final width = tester.getSize(bubble).width;
          emitChatEvent(controller, chat, 'message.delta', {
            'text': ' renderer keeps',
          });
          await _frames(tester);
          final answer = _answer('The shared renderer keeps');
          expect(answer, findsOneWidget);
          expect(tester.getSize(bubble).width, width);
          expect(
            tester
                .widget<MarkdownMessageContent>(
                  find.descendant(
                    of: answer,
                    matching: find.byType(MarkdownMessageContent),
                  ),
                )
                .streaming,
            isTrue,
          );
          expect(_copy(tester, answer).onPressed, isNull);
          await _render(tester, frame, 'canonical-streaming-$variant');
          emitChatEvent(controller, chat, 'reasoning.delta', {
            'text': 'Inspect the received image.',
          });
          await _frames(tester);
          _expectCollapsedActivity();
          emitChatEvent(controller, chat, 'tool.complete', _imageReceipt);
          await _frames(tester);
          _expectCollapsedActivity();
          await _render(
            tester,
            frame,
            'canonical-streaming-collapsed-$variant',
          );
          await _inspectLiveImage(tester, frame, 'canonical-$variant');
          final liveRun = tester.element(find.byType(ProfileActivitySection));
          browser.messages.add({
            'id': 2,
            'role': 'assistant',
            'content': '',
            'reasoning':
                'Inspect the received image.\n\nI will review the evidence.',
            'display_reasoning': 'Inspect the received image.',
            'display_commentary': ['I will review the evidence.'],
            'tool_calls': [
              {
                'id': 'received-image',
                'function': {'name': 'vision_analyze', 'arguments': '{}'},
              },
            ],
          });
          await controller.refreshHistory(chat);
          await _frames(tester);
          expect(find.byType(ProfileReasoningContent), findsOneWidget);
          expect(
            tester.element(find.byType(ProfileActivitySection)),
            same(liveRun),
          );
          // A visited, collapsed run retains its offstage tool/viewer state.
          expect(find.byType(ProfileToolCall), findsNothing);
          await _render(tester, frame, 'canonical-history-reasoning-$variant');
          emitChatEvent(controller, chat, 'reasoning.delta', {
            'text': 'Continue the review.',
          });
          await _frames(tester);
          expect(find.byType(ProfileToolCall), findsNothing);

          browser.messages.add({
            'id': 3,
            'role': 'assistant',
            'content': 'The shared renderer keeps the conversation readable.',
          });
          emitChatEvent(controller, chat, 'message.complete', {
            'text': 'The shared renderer keeps the conversation readable.',
          });
          await _frames(tester);
          final complete = _answer(
            'The shared renderer keeps the conversation readable.',
          );
          await _render(tester, frame, 'canonical-success-$variant');
          expect(complete, findsOneWidget);
          expect(_copy(tester, complete).onPressed, isNotNull);
          expect(
            tester
                .widget<MarkdownMessageContent>(
                  find.descendant(
                    of: complete,
                    matching: find.byType(MarkdownMessageContent),
                  ),
                )
                .streaming,
            isFalse,
          );
          expect(bots.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        'history route streams and retains answers through failed refresh $variant',
        (tester) async {
          final fixture = BotsFixture();
          final group = (await fixture.repository.groupCatalog()).single;
          fixture.workerRows['atlas'] = [
            {
              'id': 'atlas-root',
              'resolved_id': 'atlas-tip',
              'title': 'Group: room-1',
              'source': 'bot_room',
            },
          ];
          fixture.workerMessages['atlas'] = [
            {'id': 1, 'role': 'user', 'content': 'Review the shared renderer.'},
          ];
          final replay = Completer<void>();
          addTearDown(() {
            if (!replay.isCompleted) replay.complete();
          });
          var working = true;
          fixture.readHook = (_, method, params) async {
            if (method == 'session.resume') {
              return BotsFixture.passiveSnapshot(
                params,
                epoch: 'route-test',
                sequence: 5,
                running: working,
              );
            }
            if (method == 'session.active_list') {
              return {
                'sessions': [
                  if (working)
                    {
                      'id': 'atlas-live',
                      'session_key': 'atlas-tip',
                      'title': 'Group: room-1',
                      'status': 'working',
                    },
                ],
              };
            }
            if (method == 'session.events.since') {
              await replay.future;
              return {
                'events': [
                  for (final event in [
                    {
                      'type': 'message.start',
                      'payload': <String, dynamic>{
                        'turn_id': 'route-worker-turn',
                      },
                      'seq': 1,
                    },
                    {
                      'type': 'message.delta',
                      'payload': {
                        'text': 'The shared renderer keeps',
                        'turn_id': 'route-worker-turn',
                        'segment': 0,
                        'offset': 0,
                      },
                      'seq': 2,
                    },
                    {
                      'type': 'todo.updated',
                      'payload': {
                        'revision': 1,
                        'todos': [
                          {
                            'id': 'review',
                            'content':
                                'Review source evidence and preserve the complete findings. '
                                'Check every unresolved source decision before continuing. '
                                'Dispatch and building labels are not completion. '
                                'Keep the original notes available for the final review.',
                            'status': 'in_progress',
                          },
                          {
                            'id': 'report',
                            'content': 'Write the final report',
                            'status': 'pending',
                          },
                        ],
                      },
                      'seq': 3,
                    },
                    {
                      'type': 'reasoning.delta',
                      'payload': {'text': 'Inspect the received image.'},
                      'seq': 4,
                    },
                    {
                      'type': 'tool.complete',
                      'payload': _imageReceipt,
                      'seq': 5,
                    },
                  ])
                    if ((event['seq'] as int) >
                        (params['last_sequence'] as int))
                      {
                        ...event,
                        'session_id': 'atlas-live',
                        'replay_epoch': 'route-test',
                      },
                ],
                'latest_seq': 5,
                'truncated': false,
                'replay_epoch': 'route-test',
                'snapshot_required': false,
                'open_requests': [],
              };
            }
            return null;
          };
          final frame = GlobalKey();
          late BotGroupHistorySession session;
          await _open(
            tester,
            brightness: brightness,
            scale: scale,
            frame: frame,
            screen: BotGroupHistoryScreen(
              appearanceForMember: (_) => null,
              createSession: () =>
                  session = BotGroupHistorySession(fixture.repository, group),
            ),
          );
          _expectHeaderWait(tester);
          await _render(tester, frame, 'history-held-$variant');
          replay.complete();
          await _frames(tester);
          const partial = 'The shared renderer keeps';
          final answer = _answer(partial);
          expect(answer, findsOneWidget);
          expect(
            tester
                .widget<MarkdownMessageContent>(
                  find.descendant(
                    of: answer,
                    matching: find.byType(MarkdownMessageContent),
                  ),
                )
                .streaming,
            isTrue,
          );
          expect(_copy(tester, answer).onPressed, isNull);
          await _render(tester, frame, 'history-streaming-$variant');
          // The lazy transcript may leave Activity above the viewport at 200%.
          for (
            var i = 0;
            i < 10 && find.byType(ProfileLiveExecution).evaluate().isEmpty;
            i++
          ) {
            await tester.drag(
              find.byKey(const ValueKey('profile-transcript')),
              const Offset(0, 200),
            );
            await _frames(tester);
          }
          _expectCollapsedActivity();
          await _render(tester, frame, 'history-streaming-collapsed-$variant');
          await _inspectLiveImage(tester, frame, 'history-$variant');

          await tester.tap(
            find.byKey(const ValueKey(('live-work-tab', 1, false))),
          );
          await _frames(tester);
          final task = find.byKey(const ValueKey(('todo', 'review')));
          final expandTask = find.descendant(
            of: task,
            matching: find.byTooltip('Expand task'),
          );
          expect(expandTask, findsOneWidget);
          expect(
            find.descendant(of: task, matching: find.byType(SelectableText)),
            findsNothing,
          );
          await _render(tester, frame, 'history-tasks-collapsed-$variant');
          final summary = tester.getRect(find.byType(ProfileTodoSummary));
          await tester.ensureVisible(expandTask);
          await _frames(tester);
          expect(tester.getRect(find.byType(ProfileTodoSummary)), summary);
          await tester.tap(expandTask);
          await _frames(tester);
          expect(
            find.descendant(of: task, matching: find.byType(SelectableText)),
            findsOneWidget,
          );
          await _render(tester, frame, 'history-tasks-expanded-$variant');
          await tester.fling(
            find.byKey(const ValueKey('live-work-handle')),
            const Offset(0, -500),
            1000,
          );
          await _frames(tester);
          expect(
            tester.getRect(find.byKey(const ValueKey('live-work-panel'))).top,
            closeTo(8, 1),
          );
          await _render(tester, frame, 'history-drawer-expanded-$variant');
          await tester.tap(
            find.byKey(const ValueKey(('live-work-tab', 1, true))),
          );
          await _frames(tester);

          working = false;
          fixture.workerMessages['atlas']!.add({
            'id': 2,
            'role': 'assistant',
            'content': 'The shared renderer keeps the conversation readable.',
          });
          await session.refreshLive();
          await _frames(tester);
          const complete =
              'The shared renderer keeps the conversation readable.';
          expect(_answer(complete), findsOneWidget);
          expect(_copy(tester, _answer(complete)).onPressed, isNotNull);
          await _render(tester, frame, 'history-success-$variant');

          final held = Completer<ProfileHistoryPage>();
          fixture.historyHook = (_, _, _) => held.future;
          await tester.tap(find.byTooltip('Refresh working history'));
          await _frames(tester);
          _expectHeaderWait(tester);
          expect(_answer(complete), findsOneWidget);
          held.completeError(StateError('Offline'));
          await _frames(tester);
          expect(find.byType(StudioLoading), findsNothing);
          expect(_answer(complete), findsOneWidget);
          expect(
            find.text('Working history could not load. Refresh to try again.'),
            findsWidgets,
          );
          await _render(tester, frame, 'history-failure-$variant');
          fixture.historyHook = null;
          await tester.tap(find.byTooltip('Refresh working history'));
          await _frames(tester);
          expect(find.byType(StudioLoading), findsNothing);
          expect(
            find.text('Working history could not load. Refresh to try again.'),
            findsNothing,
          );
          expect(_answer(complete), findsOneWidget);
          expect(fixture.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        'group route holds first log, retries and retires pending reads $variant',
        (tester) async {
          final fixture = BotsFixture();
          final group = (await fixture.repository.groupCatalog()).single;
          final appearances = FixedGroupAppearances(
            await fixture.repository.bots(),
          );
          addTearDown(appearances.dispose);
          var log = Completer<void>();
          fixture.readHook = (_, method, _) async {
            if (method == 'groups.log') await log.future;
            return null;
          };
          final frame = GlobalKey();
          await _open(
            tester,
            brightness: brightness,
            scale: scale,
            frame: frame,
            screen: BotGroupScreen(
              stopVoicePlayback: () async {},
              voiceInputSettings: () =>
                  const LocalVoiceInputSettings(language: ''),
              createSession: () => BotGroupSession(
                fixture.repository,
                group,
                reads: BotGroupReadState(),
                preferences: preferences,
                groupMessages: null,
                appearances: appearances,
              ),
            ),
          );
          _expectHeaderWait(tester);
          expect(find.textContaining('Start a discussion.'), findsNothing);
          await _render(tester, frame, 'group-held-$variant');
          log.completeError(StateError('Offline'));
          await _frames(tester);
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.textContaining('could not refresh'), findsWidgets);
          await _render(tester, frame, 'group-failure-$variant');

          log = Completer<void>();
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Refresh group'));
          await _frames(tester);
          _expectHeaderWait(tester);
          fixture.events.add({
            'room_id': 'room-1',
            'seq': 1,
            'kind': 'message.member',
            'actor': {'kind': 'member', 'id': 'atlas', 'profile': 'atlas'},
            'payload': {
              'text': 'The shared renderer keeps the conversation readable.',
            },
            'created_at': 1791756000.0,
          });
          log.complete();
          await _frames(tester);
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.textContaining('could not refresh'), findsNothing);
          final answer = _answer(
            'The shared renderer keeps the conversation readable.',
          );
          expect(answer, findsOneWidget);
          expect(_copy(tester, answer).onPressed, isNotNull);
          await _render(tester, frame, 'group-success-$variant');

          log = Completer<void>();
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Refresh group'));
          await _frames(tester);
          _expectHeaderWait(tester);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.text('Open conversation'), findsOneWidget);
          log.complete();
          await _frames(tester);
          expect(find.byType(BotGroupScreen), findsNothing);
          expect(find.byType(StudioLoading), findsNothing);
          expect(fixture.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
