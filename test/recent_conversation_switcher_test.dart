import 'package:wing/core/widgets/conversation_composer.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/services/group_observations.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:wing/core/services/recent_conversation_snapshots.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/notification_focus.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/models/transcript_reading.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/source_code_block.dart';
import 'package:wing/core/widgets/bot_avatar.dart';
import 'package:wing/core/widgets/bot_group_identity.dart';
import 'package:wing/core/widgets/bot_group_conversation.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/services/recent_conversation_session.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/markdown_parse_worker.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/chat_inline_image.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/widgets/chat_notice_activity_scope.dart';
import 'package:wing/core/widgets/recent_conversations/conversation_card_motion.dart';
import 'package:wing/core/widgets/recent_conversations/conversation_card_snapshots.dart';
import 'package:wing/core/widgets/recent_conversations/conversation_gestures.dart';
import 'package:wing/core/widgets/recent_conversations/conversation_preview.dart';
import 'package:wing/core/widgets/recent_conversations/recent_conversation_switcher.dart';

import 'support/profile_browser_fixture.dart';
import 'support/bots_fixture.dart';
import 'support/voice_fixture.dart';

const _export = bool.fromEnvironment('STUDIO_REVIEW');

class _ReviewBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

class _UiSource extends ChangeNotifier implements RecentConversationSource {
  @override
  final snapshots = RecentConversationSnapshots();
  @override
  void dispose() {
    snapshots.dispose();
    super.dispose();
  }

  @override
  void setVisible(bool visible) {}
  _UiSource({int count = 3}) {
    final scope = WorkspaceScope(
      connectionId: 'host',
      connectionIdentity: 'owner',
      profileName: 'personal',
    );
    entries = List.generate(
      count,
      (i) => RecentConversationEntry.chat(
        key: ProfileSessionKey(scope, '$i'),
        title: 'Chat $i',
        unread: false,
      ),
    );
    selected = entries.first.key;
  }
  late final List<RecentConversationEntry> entries;
  @override
  bool current = true;
  @override
  bool opensRoute(RecentConversationKey key) => key.group != null;
  @override
  late RecentConversationKey selected;
  final opens = <RecentConversationKey>[];
  final waitingPreviews =
      <RecentConversationKey, Completer<RecentConversationPreview>>{};
  bool rejectOpen = false;
  Completer<void>? waitingOpen;
  int previewReads = 0, historyReads = 0;
  final previewOrder = <RecentConversationKey>[];
  Completer<RecentConversationCatalog>? catalogRead;
  List<RecentConversationEntry>? catalogEntries;
  int catalogReads = 0;
  @override
  RecentConversationCatalog get catalog => RecentConversationCatalog(
    entries: catalogEntries ?? entries,
    error: null,
  );
  @override
  Future<RecentConversationCatalog> loadRecents({required bool refresh}) {
    catalogReads++;
    return catalogRead?.future ??
        Future.value(RecentConversationCatalog(entries: entries, error: null));
  }

  @override
  bool admits(RecentConversationKey key) => current;
  final appearances = <RecentConversationKey, BotRecord>{};
  final groupAppearances = <RecentConversationKey, BotGroupAppearance>{};
  int appearancePreparations = 0;
  @override
  RecentConversationAppearance appearanceFor(RecentConversationKey key) =>
      RecentConversationAppearance(
        bot: appearances[key],
        group: groupAppearances[key] ?? const BotGroupAppearance.empty(),
      );
  @override
  Future<void> prepareAppearances(
    Iterable<RecentConversationKey> keys,
    bool Function() canRead,
  ) async {
    if (canRead()) appearancePreparations++;
  }

  @override
  Object previewRevision(RecentConversationKey key) => revisions[key] ?? 0;
  final revisions = <RecentConversationKey, int>{};
  @override
  RecentConversationPreview? cachedPreview(RecentConversationEntry entry) {
    previewReads++;
    previewOrder.add(entry.key);
    return waitingPreviews.containsKey(entry.key) ? null : _readyPreview(entry);
  }

  RecentConversationPreview _readyPreview(RecentConversationEntry entry) =>
      RecentConversationPreview(
        entry: entry,
        reading: TranscriptReadingSnapshot(
          messages: const [],
          historySessionId: entry.key.chat?.sessionId,
        ),
        draft: '',
        scopeLabel: 'personal',
      );
  @override
  Future<RecentConversationPreview> loadPreview(
    RecentConversationEntry entry,
    bool Function() canRead,
  ) async {
    historyReads++;
    return waitingPreviews[entry.key]?.future ?? _readyPreview(entry);
  }

  @override
  Future<void> open(
    RecentConversationKey key,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent()) return;
    if (rejectOpen) throw StateError('Owned fixture resume rejection');
    opens.add(key);
    await waitingOpen?.future;
    if (!isCurrent()) return;
    if (key.group == null) {
      selected = key;
      notifyListeners();
    }
  }
}

class _MountedCard extends StatefulWidget {
  const _MountedCard({required this.owner, required this.child});
  final RecentConversationKey owner;
  final Widget child;
  @override
  State<_MountedCard> createState() => _MountedCardState();
}

class _MountedCardState extends State<_MountedCard> {
  late final RecentConversationKey initialOwner;
  @override
  void initState() {
    super.initState();
    initialOwner = widget.owner;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ScreenFixture extends ProfileBrowserFixture {
  ProfileSessionKey? failedResume;
  final unreadSessions = <String>{};
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      rpc: (method, params) {
        if (method == 'session.resume' &&
            scope == failedResume?.workspace &&
            params['session_id'] == failedResume?.sessionId) {
          throw StateError('Resume rejected');
        }
        return base.call(method, params);
      },
    );
  }

  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    for (var i = 0; i < 3; i++)
      {
        'id': 'chat-$i',
        'title': [
          'Review the Android gestures',
          'Plan a quieter workspace',
          'Finish the release notes',
        ][i],
        'profile': profile,
        'last_active': now - (i + 1) * 60,
        'unread': unreadSessions.contains('chat-$i'),
      },
  ];
  @override
  List<Map<String, dynamic>> projects(String profile) => [
    {
      'id': 'home',
      'label': 'Home',
      'isNoProject': true,
      'lastActive': now,
      'sessionIds': ['chat-0', 'chat-1', 'chat-2'],
    },
  ];
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {
      'id': 1,
      'role': 'user',
      'content': 'Keep the conversation familiar while I move between tasks.',
    },
    {
      'id': 2,
      'role': 'tool',
      'tool_name': 'Read project',
      'content': 'Inspect the existing conversation controls.',
    },
    {
      'id': 3,
      'timestamp': now - int.parse(id.split('-').last) * 60,
      'role': 'assistant',
      'content':
          '## A quieter workspace\n\nThe conversation stays in place. Switch when you need to check another task.\n\nYour draft stays with this conversation.',
    },
  ];
}

class _EmptyScreenFixture extends _ScreenFixture {
  @override
  List<Map<String, dynamic>> sessions(String profile) => const [];
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => const [];
}

Future<void> _finishFrames(WidgetTester tester) async {
  // A pending-image spinner intentionally keeps scheduling frames. Advance a
  // bounded interval instead of settling it through the read/batch deadlines.
  for (var pass = 0; pass < 16; pass++) {
    await tester.pump(const Duration(milliseconds: 80));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

Future<void> _twoContacts(
  WidgetTester tester,
  Offset a,
  Offset b,
  Offset endA,
  Offset endB, {
  bool returnToStart = false,
}) async {
  final first = await tester.startGesture(a, pointer: 1);
  final second = await tester.startGesture(b, pointer: 2);
  await tester.pump();
  for (var i = 1; i <= 8; i++) {
    await first.moveTo(Offset.lerp(a, endA, i / 8)!);
    await second.moveTo(Offset.lerp(b, endB, i / 8)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (returnToStart) {
    for (var i = 1; i <= 8; i++) {
      await first.moveTo(Offset.lerp(endA, a, i / 8)!);
      await second.moveTo(Offset.lerp(endB, b, i / 8)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
  }
  await first.up();
  await second.up();
  await _finishFrames(tester);
}

Future<void> _chatGesture(
  WidgetTester tester, {
  bool pinch = true,
  bool returnToStart = false,
}) async {
  final rect = tester.getRect(find.byType(ProfileTranscript));
  final fractions = pinch ? [.24, .76] : [.16, .38];
  for (var y = rect.top + 24; y < rect.bottom - 24; y += 12) {
    if (!fractions.every(
      (fraction) => admitsConversationGesture(
        PointerDownEvent(
          position: Offset(rect.left + rect.width * fraction, y),
          viewId: tester.view.viewId,
        ),
      ),
    )) {
      continue;
    }
    await _twoContacts(
      tester,
      Offset(rect.left + rect.width * fractions[0], y),
      Offset(rect.left + rect.width * fractions[1], y),
      Offset(rect.left + rect.width * (pinch ? .41 : .66), y),
      Offset(rect.left + rect.width * (pinch ? .59 : .88), y),
      returnToStart: returnToStart,
    );
    return;
  }
  throw StateError('No admitted transcript row');
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!_export) return;
  await _finishFrames(tester);
  await _captureCurrent(tester, key, name);
}

Future<void> _expectArrivalWhileTyping(
  WidgetTester tester, {
  required Finder composer,
  required ValueNotifier<ChatNoticeActivity?> activity,
  required RecentConversationKey target,
  required int sequence,
  required GlobalKey frame,
  required String captureName,
}) async {
  await tester.showKeyboard(composer);
  tester.view.viewInsets = const FakeViewPadding(bottom: 260);
  await tester.pump();
  final field = tester.widget<TextField>(composer);
  final value = field.controller!.value;
  final bounds = tester.getRect(composer);
  expect(field.focusNode!.hasFocus, isTrue);
  final visit = tester
      .widget<RecentConversationSwitcher>(
        find.byType(RecentConversationSwitcher),
      )
      .session;
  final selected = visit.selected;
  for (final kind in ConversationActivityKind.values) {
    activity.value = ChatNoticeActivity(
      key: target,
      kind: kind,
      identity: 'typing-${kind.name}',
      sequence: sequence++,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 900));
    expect(
      find.byKey(const ValueKey('recent-conversation-nudge')),
      findsOneWidget,
      reason: 'A fresh ${kind.name} must remain visible while typing.',
    );
    expect(field.focusNode!.hasFocus, isTrue);
    expect(field.controller!.value, value);
    expect(tester.getRect(composer), bounds);
    expect(visit.selected, selected);
    await _captureCurrent(tester, frame, '$captureName-${kind.name}');
  }
  await tester.pump(const Duration(seconds: 4));
  expect(find.byKey(const ValueKey('recent-conversation-nudge')), findsNothing);
}

Future<void> _captureCurrent(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (!_export) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/recents-review')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  if (_export) _ReviewBinding();
  setUpAll(() async {
    if (!_export) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
      'monospace': 'build/studio-mono.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final outcome in [
        'success',
        'failure',
        'coordination',
        'back',
        'back-history',
      ]) {
        testWidgets(
          'Recents tap enters chat before held resume and history ${brightness.name} $scale $outcome',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final appPreferences = AppPreferences(preferences);
            addTearDown(appPreferences.dispose);
            final fixture = _ScreenFixture();
            var resume = Completer<void>();
            var refuseAttachment = outcome == 'coordination';
            final history = Completer<void>();
            var opening = false;
            var resumeStarted = false;
            var historyStarted = false;
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
              connectionIdentity: 'recents-entry',
              preferences: preferences,
              appPreferences: appPreferences,
              gatewayFactory: (scope) {
                final base = fixture.gateway(scope);
                return ProfileGateway(
                  scope: scope,
                  discover: base.discover,
                  get: (path, query) async {
                    if (opening && path.endsWith('/messages')) {
                      historyStarted = true;
                      await history.future;
                    }
                    return base.read(path, query);
                  },
                  rpc: (method, params) async {
                    if (opening && method == 'session.resume') {
                      resumeStarted = true;
                      await resume.future;
                      if (refuseAttachment) {
                        throw JsonRpcError(
                          'session.resume',
                          'runtime_coordination_required',
                          code: 4001,
                          reason: 'runtime_coordination_required',
                        );
                      }
                    }
                    return base.call(method, params);
                  },
                );
              },
            );
            addTearDown(controller.dispose);
            await controller.initialize();
            await controller.refreshRecents();
            await controller.openSession(
              ProfileSessionKey(controller.current!.scope, 'chat-2'),
            );
            final activity = ValueNotifier<ChatNoticeActivity?>(null);
            addTearDown(activity.dispose);
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final frame = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: scale == 2,
                  ),
                  child: ChatNoticeActivityScope(
                    activity: activity,
                    child: RepaintBoundary(key: frame, child: child!),
                  ),
                ),
                home: ProfileWorkspaceScreen(
                  controller: controller,
                  initialDestination: AppDestination.activity,
                  createBotsSession: () {
                    final bots = BotsFixture();
                    return BotsSession((_) async => [bots.repository]);
                  },
                ),
              ),
            );
            await tester.pumpAndSettle();
            final title = find.text('Review the Android gestures').first;
            await tester.ensureVisible(title);
            await tester.pumpAndSettle();
            opening = true;
            await tester.tap(title);
            await tester.pump();
            await tester.pump();
            expect(find.text('Recents'), findsNothing);
            expect(find.byTooltip('Back'), findsOneWidget);
            expect(find.text('Review the Android gestures'), findsOneWidget);
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(find.byType(ProfileTranscript), findsNothing);
            final backRect = tester.getRect(find.byTooltip('Back'));
            for (var i = 0; i < 30; i++) {
              await tester.pump();
            }
            expect(historyStarted, isTrue);
            expect(resumeStarted, isFalse);
            await _captureCurrent(
              tester,
              frame,
              'recents-entry-history-${brightness.name}-$scale-$outcome',
            );
            if (outcome == 'back-history') {
              await tester.tap(find.byTooltip('Back'));
              await tester.pump();
              history.complete();
              resume.complete();
              await tester.pumpAndSettle();
              expect(find.text('Recents'), findsOneWidget);
              expect(controller.current!.chat, isNull);
            } else if (outcome == 'failure') {
              history.completeError(StateError('History unavailable'));
              await tester.pumpAndSettle();
              expect(find.byTooltip('Retry'), findsOneWidget);
              expect(find.byType(StudioLoading), findsNothing);
              expect(find.byType(ProfileTranscript), findsNothing);
              expect(resumeStarted, isFalse);
              opening = false;
              resume.complete();
              await tester.tap(find.byTooltip('Retry'));
              await _finishFrames(tester);
              expect(controller.current!.chat!.key.sessionId, 'chat-0');
              expect(find.byType(ProfileTranscript), findsOneWidget);
            } else {
              history.complete();
              await _finishFrames(tester);
              expect(resumeStarted, isTrue);
              expect(find.byType(ProfileTranscript), findsOneWidget);
              expect(controller.current!.chat!.reading.messages, isNotEmpty);
              expect(controller.current!.chat!.runtime.offline, isTrue);
              expect(find.byType(StudioLoading), findsOneWidget);
              expect(
                tester.getRect(find.byTooltip('Open navigation menu')),
                backRect,
              );
              await _captureCurrent(
                tester,
                frame,
                'recents-entry-resume-${brightness.name}-$scale-$outcome',
              );
              if (outcome == 'back') {
                await tester.binding.handlePopRoute();
                await tester.pump();
                resume.complete();
                await _finishFrames(tester);
                expect(find.text('Recents'), findsOneWidget);
                expect(controller.current!.chat, isNull);
              } else {
                resume.complete();
                await _finishFrames(tester);
                if (outcome == 'coordination') {
                  expect(
                    find.text(
                      'Sending is unavailable. Hermes could not confirm chat ownership. If this chat is open in another app, close it there, then retry.',
                    ),
                    findsOneWidget,
                  );
                  expect(find.byType(ProfileTranscript), findsOneWidget);
                  expect(find.byTooltip('Retry'), findsOneWidget);
                  expect(find.byType(StudioLoading), findsNothing);
                  final chat = controller.current!.chat!;
                  expect(chat.runtime.offline, isTrue);
                  await controller.updateDraft(chat, 'Keep my draft');
                  await _finishFrames(tester);
                  expect(
                    tester
                        .widget<ComposerActionButton>(
                          find.byType(ComposerActionButton),
                        )
                        .unavailable[ComposerAction.send],
                    isNotNull,
                  );
                  await tester.tap(find.byType(ComposerActionButton));
                  await _finishFrames(tester);
                  expect(
                    fixture.calls.where((call) => call.$2 == 'prompt.submit'),
                    isEmpty,
                  );
                  expect(chat.composer.observation.text, 'Keep my draft');
                  await _captureCurrent(
                    tester,
                    frame,
                    'coordination-${brightness.name}-$scale',
                  );
                  refuseAttachment = false;
                  resume = Completer<void>();
                  await tester.tap(find.byTooltip('Retry'));
                  await tester.pump();
                  await tester.pump();
                  expect(find.byType(ProfileTranscript), findsOneWidget);
                  expect(find.byType(StudioLoading), findsOneWidget);
                  await _captureCurrent(
                    tester,
                    frame,
                    'coordination-retry-${brightness.name}-$scale',
                  );
                  resume.complete();
                  await _finishFrames(tester);
                  expect(controller.current!.chat, same(chat));
                  expect(chat.runtime.offline, isFalse);
                  expect(chat.runtime.openingError, isNull);
                  expect(chat.composer.observation.text, 'Keep my draft');
                  expect(
                    tester
                        .widget<ComposerActionButton>(
                          find.byType(ComposerActionButton),
                        )
                        .unavailable[ComposerAction.send],
                    isNull,
                  );
                }
                expect(controller.current!.chat!.key.sessionId, 'chat-0');
                expect(find.byType(ProfileTranscript), findsOneWidget);
                expect(find.byType(StudioLoading), findsNothing);
                expect(find.byType(RecentConversationSwitcher), findsOneWidget);
                await tester.binding.handlePopRoute();
                await _finishFrames(tester);
                expect(find.text('Recents'), findsOneWidget);
              }
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets('passive group prepares only the bottom on its first frame', (
    tester,
  ) async {
    final fixture = BotsFixture();
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).single;
    final entry = RecentConversationEntry.group(group, unread: false);
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPreview(
          connectionLabel: 'Host',
          card: RecentConversationCard(
            entry: entry,
            preview: RecentConversationPreview(
              entry: entry,
              reading: TranscriptReadingSnapshot(
                messages: const [],
                historySessionId: null,
              ),
              draft: '',
              scopeLabel: 'Group',
              group: GroupConversationPreview(
                messages: [
                  for (var i = 0; i < 100; i++)
                    TranscriptMessage.discussion(
                      group: group,
                      event: BotGroupEvent(
                        sequence: i,
                        eventId: 'event-$i',
                        kind: 'message.member',
                        actor: 'atlas',
                        actorId: 'atlas',
                        actorName: 'Atlas',
                        timestamp: DateTime(2026, 10, 12),
                        text: 'Message $i\n' * 20,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final messages = tester
        .widgetList<BotGroupMessage>(find.byType(BotGroupMessage))
        .toList();
    expect(
      messages.any((message) => message.message.id == 'room-1:99'),
      isTrue,
    );
    expect(
      messages.every(
        (message) =>
            int.parse(message.message.id.toString().split(':').last) > 90,
      ),
      isTrue,
    );
    expect(messages.length, lessThan(10));
  });

  testWidgets('shared group identity never invents unresolved member avatars', (
    tester,
  ) async {
    final fixture = BotsFixture();
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).single;
    final roster = await fixture.repository.bots();
    Widget render(Iterable<BotRecord> bots) => MaterialApp(
      theme: wingTheme(Brightness.dark),
      home: Scaffold(
        body: BotGroupIdentity(group: group, bots: bots, size: 32),
      ),
    );
    await tester.pumpWidget(render(const []));
    expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    expect(find.byType(BotAvatar), findsNothing);
    await tester.pumpWidget(render([roster.first]));
    expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    expect(find.byType(BotAvatar), findsOneWidget);
    await tester.pumpWidget(render(roster));
    expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    expect(find.byType(BotAvatar), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  for (final fromGroup in [false, true]) {
    for (final target in ['chat', 'bot', 'group']) {
      for (final pinch in [false, true]) {
        testWidgets(
          'Recents Back returns to Recents from $target entered through ${fromGroup ? 'group' : 'Recents'} after ${pinch ? 'pinch' : 'swipe'}',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            final preferences = await SharedPreferences.getInstance();
            final appPreferences = AppPreferences(preferences);
            final fixture = _ScreenFixture();
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
              gatewayFactory: fixture.gateway,
            );
            addTearDown(controller.dispose);
            addTearDown(appPreferences.dispose);
            await controller.initialize();
            final botFixture = BotsFixture();
            botFixture.profiles
              ..clear()
              ..add(BotsFixture.profile('personal', 'Atlas'));
            botFixture.profiles.single['canonical_session']['id'] = 'chat-1';
            botFixture.events.add({
              'room_id': 'room-1',
              'seq': 1,
              'kind': 'message.member',
              'created_at': fixture.now - 30,
              'actor': {'kind': 'member', 'id': 'atlas'},
              'payload': {'text': 'Recent group reply'},
            });
            final activity = ValueNotifier<ChatNoticeActivity?>(null);
            addTearDown(activity.dispose);
            tester.view.physicalSize = const Size(390, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(Brightness.dark),
                builder: (_, child) =>
                    ChatNoticeActivityScope(activity: activity, child: child!),
                home: ProfileWorkspaceScreen(
                  controller: controller,
                  initialDestination: fromGroup
                      ? AppDestination.bots
                      : AppDestination.activity,
                  createBotsSession: () =>
                      BotsSession((_) async => [botFixture.repository]),
                ),
              ),
            );
            await _finishFrames(tester);
            if (fromGroup) {
              await tester.tap(find.text('Groups').first);
              await _finishFrames(tester);
              await tester.tap(find.text('Research team').first);
            } else {
              final row = find.byKey(
                const ValueKey('activity-personal-chat-0'),
              );
              await tester.ensureVisible(row);
              await tester.tap(row);
            }
            await _finishFrames(tester);
            await _chatGesture(tester, pinch: pinch);
            final switcher = tester.widget<RecentConversationSwitcher>(
              find.byType(RecentConversationSwitcher),
            );
            final key = target == 'group'
                ? switcher.session.entries
                      .firstWhere((e) => e.group != null)
                      .key
                : RecentConversationKey.chat(
                    ProfileSessionKey(
                      WorkspaceScope(
                        connectionId: 'host',
                        connectionIdentity: 'instance-1',
                        profileName: 'personal',
                      ),
                      target == 'bot' ? 'chat-1' : 'chat-2',
                    ),
                  );
            final index = switcher.session.entries.indexWhere(
              (e) => e.key == key,
            );
            expect(index, greaterThanOrEqualTo(0));
            unawaited(
              tester
                  .state<RecentConversationSwitcherState>(
                    find.byType(RecentConversationSwitcher),
                  )
                  .selectAdjacent(index - switcher.session.selectedIndex),
            );
            await _finishFrames(tester);
            expect(find.text('Swipe to browse · tap to open'), findsNothing);
            if (pinch) {
              await _chatGesture(tester, returnToStart: true);
              expect(find.text('Swipe to browse · tap to open'), findsNothing);
            }
            await tester.binding.handlePopRoute();
            await _finishFrames(tester);
            expect(
              find.byType(ProfileTranscript),
              findsNothing,
              reason: 'Back must not reveal a previous chat.',
            );
            expect(
              find.byType(BotGroupScreen, skipOffstage: false),
              findsNothing,
              reason: 'Back must unwind all borrowed conversation routes.',
            );
            expect(controller.current?.chat, isNull);
            expect(find.text('Recents'), findsOneWidget);
            expect(find.byKey(const ValueKey('bots-search')), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('group passive card ${brightness.name} $scale', (
        tester,
      ) async {
        final fixture = BotsFixture();
        final roster = await fixture.repository.bots();
        fixture.room['name'] = 'Build Pace Health Analysis Research team';
        final group = (await readFixtureGroups(
          fixture.repository,
          groupMessages: null,
        )).single;
        final status = ServerConnectionStatus(group.instance)
          ..accessAvailable()
          ..liveChanged('discussion', true);
        addTearDown(status.dispose);
        final entry = RecentConversationEntry.group(group, unread: false);
        final frame = GlobalKey();
        tester.view.physicalSize = Size(scale == 1 ? 360 : 320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: frame,
              child: ConversationPreview(
                connectionLabel: 'Home server',
                connectionIcon: ConnectionIcon.cloud,
                connectionStatus: status,
                card: RecentConversationCard(
                  entry: entry,
                  groupAppearance: BotGroupAppearance.forGroup(group, roster),
                  preview: RecentConversationPreview(
                    entry: entry,
                    reading: TranscriptReadingSnapshot(
                      messages: const [],
                      historySessionId: null,
                    ),
                    draft: '',
                    scopeLabel: 'Bot group',
                    group: GroupConversationPreview(
                      messages: [
                        TranscriptMessage.discussion(
                          group: group,
                          event: BotGroupEvent(
                            sequence: 1,
                            eventId: 'event-1',
                            kind: 'message.member',
                            actor: 'atlas',
                            actorId: 'atlas',
                            actorName: 'Atlas',
                            timestamp: DateTime(2026, 10, 12),
                            text:
                                '@bot_atlas The research is ready. We can continue here.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await _finishFrames(tester);
        final title = find.text('Build Pace Health Analysis Research team');
        expect(title, findsOneWidget);
        final artwork = find.byType(BotGroupIdentity);
        expect(artwork, findsOneWidget);
        final artworkBounds = tester.getRect(artwork);
        final titleBounds = tester.getRect(title);
        expect(artworkBounds.isEmpty, isFalse);
        expect(titleBounds.left, greaterThanOrEqualTo(artworkBounds.right));
        expect(titleBounds.center.dy, closeTo(artworkBounds.center.dy, .01));
        expect(
          titleBounds.right,
          lessThanOrEqualTo(
            tester.view.physicalSize.width / tester.view.devicePixelRatio,
          ),
        );
        expect(find.text('Message the group'), findsOneWidget);
        expect(find.byType(BotGroupConversation), findsOneWidget);
        final identity = tester.widget<ServerConnectionLabel>(
          find.byType(ServerConnectionLabel),
        );
        expect(identity.label, group.instance);
        expect(identity.status, same(status));
        expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
        expect(
          find.byKey(const ValueKey('server-connection-led')),
          findsOneWidget,
        );
        expect(find.byType(ConversationComposer), findsOneWidget);
        expect(find.byType(BotGroupMessage), findsOneWidget);
        final attachment = find.byTooltip('Attach file');
        expect(attachment, findsOneWidget);
        final surface = tester.getRect(
          find.byKey(const ValueKey('conversation-composer')),
        );
        expect(
          tester
              .getCenter(
                find.descendant(
                  of: attachment,
                  matching: find.byIcon(Icons.add),
                ),
              )
              .dx,
          closeTo(surface.left + 8 + 24, .01),
        );
        expect(tester.getSize(attachment).width, 48);
        expect(attachment.hitTestable(), findsNothing);
        final prose = [
          ...tester
              .widgetList<RichText>(find.byType(RichText))
              .map((text) => text.text.toPlainText()),
          ...tester
              .widgetList<SelectableText>(find.byType(SelectableText))
              .map((text) => text.data ?? text.textSpan?.toPlainText() ?? ''),
        ].join(' ');
        expect(
          prose,
          contains('@Atlas The research is ready. We can continue here.'),
        );
        expect(prose, isNot(contains('@bot_atlas')));
        expect(fixture.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          frame,
          'group-passive-${brightness.name}-$scale',
        );
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('canonical bot passive header ${brightness.name} $scale', (
        tester,
      ) async {
        final fixture = BotsFixture();
        fixture.profiles.first['has_avatar'] = true;
        fixture.readHook = (_, method, _) async =>
            method == 'profiles.get_asset'
            ? {
                'found': true,
                'data':
                    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGO4Odf1PwAGyQK7B3JGZQAAAABJRU5ErkJggg==',
              }
            : null;
        final owner = BotsSession((_) async => [fixture.repository]);
        addTearDown(owner.dispose);
        final key = ProfileSessionKey(
          WorkspaceScope(
            connectionId: 'host',
            connectionIdentity: 'instance-1',
            profileName: 'atlas',
          ),
          'atlas-chat',
        );
        final bot = await owner.botForConversation(key);
        expect(fixture.commands, isEmpty);
        final entry = RecentConversationEntry.chat(
          key: key,
          title: 'Bot Chat',
          unread: false,
        );
        final frame = GlobalKey();
        tester.view.physicalSize = Size(scale == 1 ? 360 : 320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: frame,
              child: BotAvatarScope(
                session: owner,
                prepared: true,
                child: ConversationPreview(
                  card: RecentConversationCard(
                    entry: entry,
                    bot: bot,
                    preview: RecentConversationPreview(
                      entry: entry,
                      reading: TranscriptReadingSnapshot(
                        messages: const [],
                        historySessionId: key.sessionId,
                      ),
                      draft: '',
                      scopeLabel: 'Unassigned',
                    ),
                  ),
                  connectionLabel: 'Host',
                ),
              ),
            ),
          ),
        );
        await _finishFrames(tester);
        expect(find.text('Atlas'), findsOneWidget);
        expect(find.text('Bot Chat'), findsNothing);
        final avatar = tester.widget<BotAvatar>(find.byType(BotAvatar));
        expect(
          avatar.image,
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGO4Odf1PwAGyQK7B3JGZQAAAABJRU5ErkJggg==',
          ),
        );
        expect(tester.getSize(find.byType(BotAvatar)).isEmpty, isFalse);
        final savedImage = tester.renderObject<RenderImage>(
          find.descendant(
            of: find.byType(BotAvatar),
            matching: find.byType(RawImage),
          ),
        );
        expect(savedImage.image, isNotNull);
        final bounds = tester.getRect(find.byType(BotConversationTitle));
        expect(
          bounds.right,
          lessThanOrEqualTo(
            tester.view.physicalSize.width / tester.view.devicePixelRatio,
          ),
        );
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          frame,
          'canonical-bot-header-${brightness.name}-$scale',
        );
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  group('gesture and motion contract', () {
    late _UiSource source;
    late ValueNotifier<ChatNoticeActivity?> activity;
    late RecentConversationSession session;
    final switcher = GlobalKey<RecentConversationSwitcherState>();
    setUp(() {
      source = _UiSource();
      activity = ValueNotifier(null);
      session = RecentConversationSession.fromRecents(
        entries: source.entries,
        source: source,
        activity: activity,
      );
    });
    tearDown(() {
      session.dispose();
      activity.dispose();
      source.dispose();
    });
    void enterDormant() {
      session.dispose();
      session = RecentConversationSession.fromChat(
        chat: source.entries.first,
        source: source,
        activity: () => activity,
      );
    }

    testWidgets('capture waits for a scheduled chat repaint', (tester) async {
      final color = ValueNotifier(Colors.red);
      addTearDown(color.dispose);
      await session.select(source.selected);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<Color>(
            valueListenable: color,
            builder: (context, value, _) => RecentConversationSwitcher(
              key: switcher,
              session: session,
              chatKey: source.selected,
              gesturesEnabled: true,
              nudgesEnabled: true,
              onPresentationChanged: (_, _) {},
              previewBuilder: (_) => const SizedBox.expand(),
              child: SizedBox.expand(child: ColoredBox(color: value)),
            ),
          ),
        ),
      );

      // Idle preparation must observe the completed repaint, never a stale frame.
      color.value = Colors.green;
      await _finishFrames(tester);
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      final image = tester
          .widgetList<RawImage>(
            find.byKey(ValueKey((source.selected, 'snapshot'))),
          )
          .map((widget) => widget.image)
          .whereType<ui.Image>()
          .first;
      final pixels = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      expect(pixels, isNotNull);
      expect(pixels!.getUint8(0), 76);
      expect(pixels.getUint8(1), 175);
      expect(pixels.getUint8(2), 80);
      expect(pixels.getUint8(3), 255);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    Future<void> mount(
      WidgetTester tester, {
      Brightness brightness = Brightness.dark,
      bool accessible = false,
      bool reduced = false,
      double textScale = 1,
      GlobalKey? frame,
      Widget Function(RecentConversationCard)? buildPreview,
      Widget? liveChild,
      bool dormant = false,
    }) async {
      if (!dormant) await session.select(source.selected);
      source.opens.clear();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              accessibleNavigation: accessible,
              disableAnimations: reduced,
              textScaler: TextScaler.linear(textScale),
            ),
            child: frame == null
                ? child!
                : RepaintBoundary(key: frame, child: child!),
          ),
          home: ListenableBuilder(
            listenable: source,
            builder: (context, _) => Theme(
              data: wingTheme(brightness),
              child: RecentConversationSwitcher(
                key: switcher,
                session: session,
                chatKey: source.selected,
                gesturesEnabled: true,
                nudgesEnabled: true,
                onPresentationChanged: (_, _) {},
                previewBuilder:
                    buildPreview ??
                    (card) => Scaffold(
                      body: Center(
                        child: Text(
                          card.preview?.scopeLabel ?? 'Preview pending',
                        ),
                      ),
                    ),
                child:
                    liveChild ??
                    Scaffold(
                      body: ConversationGestureBoundary(
                        child: ColoredBox(
                          color: Theme.of(context).colorScheme.surface,
                          child: Column(
                            children: [
                              Text(
                                'Mounted conversation ${source.selected.chat!.sessionId}',
                              ),
                              const ConversationGestureBoundary(
                                blocked: true,
                                child: SizedBox(
                                  height: 150,
                                  child: Center(
                                    child: Text('Selectable message'),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: ListView(
                                  children: const [SizedBox(height: 1800)],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
              ),
            ),
          ),
        ),
      );
      await _finishFrames(tester);
    }

    Future<({int alpha, Color strongest})> nudgePixels(
      WidgetTester tester,
    ) async {
      final paint = tester.renderObject<RenderCustomPaint>(
        find.byKey(const ValueKey('recent-conversation-nudge')),
      );
      final boundary = paint.parent! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          var alpha = 0, strongestAlpha = 0;
          var strongest = const Color(0xff000000);
          for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
            final value = bytes.getUint8(i);
            alpha += value;
            if (value > strongestAlpha) {
              strongestAlpha = value;
              strongest = Color.fromARGB(
                255,
                bytes.getUint8(i - 3),
                bytes.getUint8(i - 2),
                bytes.getUint8(i - 1),
              );
            }
          }
          return (alpha: alpha, strongest: strongest);
        } finally {
          image.dispose();
        }
      }))!;
    }

    Future<int> nudgeAlpha(WidgetTester tester) async =>
        (await nudgePixels(tester)).alpha;

    Future<void> signal(
      WidgetTester tester, {
      int index = 1,
      int sequence = 1,
      ConversationActivityKind kind = ConversationActivityKind.reply,
    }) async {
      activity.value = ChatNoticeActivity(
        key: source.entries[index].key,
        kind: kind,
        identity: 'pond-$sequence',
        sequence: sequence,
      );
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pump();
    }

    testWidgets('pond ripples keep arriving then expire after 3.8 seconds', (
      tester,
    ) async {
      await mount(tester);
      await signal(tester);
      final cue = find.byKey(const ValueKey('recent-conversation-nudge'));
      await tester.pump(const Duration(milliseconds: 900));
      expect(await nudgeAlpha(tester), greaterThan(0));
      expect(
        tester.getRect(cue).right,
        tester.view.physicalSize.width / tester.view.devicePixelRatio,
      );
      await tester.pump(const Duration(milliseconds: 2300));
      final ongoing = await nudgeAlpha(tester);
      expect(ongoing, greaterThan(0), reason: 'Later waves must still arrive');
      await tester.pump(const Duration(milliseconds: 500));
      final fading = await nudgeAlpha(tester);
      expect(fading, greaterThan(0));
      expect(fading, lessThan(ongoing));
      await tester.pump(const Duration(milliseconds: 150));
      expect(cue, findsNothing);
      expect(source.opens, isEmpty, reason: 'Cues cannot open or read a chat');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pond ripples replace direction and clear for card gestures', (
      tester,
    ) async {
      await mount(tester);
      await signal(tester);
      await tester.pump(const Duration(milliseconds: 900));
      await signal(
        tester,
        index: 2,
        sequence: 2,
        kind: ConversationActivityKind.inputNeeded,
      );
      await tester.pump(const Duration(milliseconds: 900));
      final cue = find.byKey(const ValueKey('recent-conversation-nudge'));
      expect(cue, findsOneWidget);
      expect(tester.getRect(cue).left, 0);
      expect(await nudgeAlpha(tester), greaterThan(0));
      switcher.currentState!.openStack();
      await tester.pump();
      expect(cue, findsNothing);
      expect(source.opens, isEmpty);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('pond cue retires when the mounted conversation changes', (
      tester,
    ) async {
      await mount(tester);
      await signal(tester);
      await tester.pump(const Duration(milliseconds: 900));
      expect(await nudgeAlpha(tester), greaterThan(0));
      source.selected = source.entries[1].key;
      source.notifyListeners();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('recent-conversation-nudge')),
        findsNothing,
      );
      expect(source.opens, isEmpty);
      expect(session.active, isFalse);
      await signal(tester, index: 2, sequence: 2);
      await tester.pump(const Duration(milliseconds: 900));
      expect(
        find.byKey(const ValueKey('recent-conversation-nudge')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion clears an ongoing pond cue', (tester) async {
      await mount(tester);
      await signal(tester);
      await tester.pump(const Duration(milliseconds: 900));
      expect(await nudgeAlpha(tester), greaterThan(0));
      await mount(tester, reduced: true);
      await signal(tester, index: 2, sequence: 2);
      await tester.pump(const Duration(milliseconds: 900));
      expect(
        find.byKey(const ValueKey('recent-conversation-nudge')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'mixed circle has fresher left, older right and endpoint wrap',
      (tester) async {
        final room = RecentConversationEntry.group(
          BotGroup(
            observationComplete: true,
            scope: source.entries[0].key.chat!.workspace,
            instance: 'Host',
            id: 'room-1',
            name: 'Research team',
            members: const [],
          ),
          unread: false,
        );
        source.entries[1] = room;
        source.selected = source.entries[0].key;
        session.dispose();
        session = RecentConversationSession.fromRecents(
          entries: source.entries,
          source: source,
          activity: activity,
        );
        source.selected = source.entries[0].key;
        await mount(tester, accessible: true);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        await tester.tap(find.byTooltip('Next conversation'));
        await _finishFrames(tester);
        double x(RecentConversationKey key) =>
            tester.getCenter(find.byKey(ValueKey((key, 'snapshot')))).dx;
        expect(x(source.entries[0].key), lessThan(x(room.key)));
        expect(x(source.entries[2].key), greaterThan(x(room.key)));
        expect(source.opens, isEmpty);
        await tester.tap(find.byTooltip('Next conversation'));
        await _finishFrames(tester);
        expect(x(room.key), lessThan(x(source.entries[2].key)));
        expect(x(source.entries[0].key), greaterThan(x(source.entries[2].key)));
        await tester.tap(find.byTooltip('Next conversation'));
        await _finishFrames(tester);
        expect(x(source.entries[2].key), lessThan(x(source.entries[0].key)));
        expect(x(room.key), greaterThan(x(source.entries[0].key)));
        await tester.tap(find.byTooltip('Next conversation'));
        await _finishFrames(tester);
        source.waitingOpen = Completer<void>();
        await tester.tap(find.byTooltip('Open conversation'));
        await tester.pump();
        expect(source.opens, [room.key]);
        expect(source.selected, source.entries[0].key);
        source.waitingOpen!.complete();
        await _finishFrames(tester);
        expect(find.text('Choose a conversation'), findsOneWidget);
        expect(session.selected, source.entries[0].key);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'opening reads neighbors before the first motion or capture frame',
      (tester) async {
        enterDormant();
        final pending = <Completer<RecentConversationPreview>>[];
        for (final entry in source.entries.skip(1)) {
          final read = Completer<RecentConversationPreview>();
          pending.add(read);
          source.waitingPreviews[entry.key] = read;
        }
        source.catalogRead = Completer<RecentConversationCatalog>();
        await mount(tester, dormant: true);
        switcher.currentState!.openStack();
        expect(
          source.previewOrder,
          containsAll([source.entries[1].key, source.entries[2].key]),
          reason: 'Opening data reads must overlap motion and live readback',
        );
        expect(session.entries, hasLength(1));
        expect(source.historyReads, 2);
        expect(
          find.byKey(ValueKey((source.entries[1].key, 'snapshot'))),
          findsNothing,
          reason:
              'Early reads must not start offscreen rendering during motion',
        );
        source.catalogRead!.complete(source.catalog);
        for (var i = 0; i < pending.length; i++) {
          pending[i].complete(source._readyPreview(source.entries[i + 1]));
        }
        await _finishFrames(tester);
        expect(
          find.byKey(ValueKey((source.entries[1].key, 'snapshot'))),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'ready neighbors publish screenshots while catalog refresh is pending',
      (tester) async {
        enterDormant();
        source.catalogRead = Completer<RecentConversationCatalog>();
        await mount(tester, dormant: true);
        switcher.currentState!.openStack();
        await tester.pump();
        source.notifyListeners();
        await _finishFrames(tester);
        expect(session.catalogLoading, isTrue);
        for (final entry in source.entries.skip(1)) {
          expect(
            find.byKey(ValueKey((entry.key, 'snapshot'))),
            findsOneWidget,
            reason: 'A ready neighbor must not wait for the whole catalog',
          );
        }
        expect(source.opens, isEmpty);
        source.catalogRead!.complete(source.catalog);
        await _finishFrames(tester);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'ready neighbor screenshot appears before a held neighboring history',
      (tester) async {
        enterDormant();
        source.catalogRead = Completer<RecentConversationCatalog>();
        final pending = Completer<RecentConversationPreview>();
        source.waitingPreviews[source.entries[2].key] = pending;
        await mount(tester, dormant: true);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        expect(session.catalogLoading, isTrue);
        expect(
          find.byKey(ValueKey((source.entries[1].key, 'snapshot'))),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey((source.entries[2].key, 'snapshot'))),
          findsNothing,
        );
        pending.complete(source._readyPreview(source.entries[2]));
        await _finishFrames(tester);
        expect(
          find.byKey(ValueKey((source.entries[2].key, 'snapshot'))),
          findsOneWidget,
        );
        expect(source.opens, isEmpty);
        source.catalogRead!.complete(source.catalog);
        await _finishFrames(tester);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'ten-card batch publishes outward and reuses captures on reopening',
      (tester) async {
        session.dispose();
        source.dispose();
        source = _UiSource(count: 100);
        session = RecentConversationSession.fromRecents(
          entries: source.entries,
          source: source,
          activity: activity,
        );
        final built = <RecentConversationKey>[];
        await mount(
          tester,
          buildPreview: (card) {
            built.add(card.entry.key);
            return const ColoredBox(color: Colors.green);
          },
        );
        // mount supplies normal phone geometry; override it after mounting to
        // exercise rounding and the readback slot in a high-density square.
        tester.view.physicalSize = const Size(2100, 2100);
        tester.view.devicePixelRatio = 3;
        await tester.pump();
        expect(
          source.previewReads,
          0,
          reason: 'Normal chat does not prewarm on a timer.',
        );
        switcher.currentState!.openStack();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('recent-snapshot-progress')),
          findsNothing,
        );
        expect(built, isEmpty);
        await _finishFrames(tester);
        await _finishFrames(tester);
        final expected = [
          99,
          1,
          98,
          2,
          97,
          3,
          96,
          4,
          95,
        ].map((i) => source.entries[i].key).toList();
        expect(built, expected);
        expect(source.previewOrder, expected);
        expect(
          find.byKey(const ValueKey('recent-snapshot-progress')),
          findsNothing,
        );
        expect(source.opens, isEmpty);
        switcher.currentState!.dismissStack();
        await _finishFrames(tester);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        expect(
          built,
          expected,
          reason: 'Valid pixels survive successive stack openings.',
        );
        expect(source.previewOrder, expected);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'programmatic switching retains the departing genuine viewport',
      (tester) async {
        final built = <RecentConversationKey>[];
        await mount(
          tester,
          buildPreview: (card) {
            built.add(card.entry.key);
            return const ColoredBox(color: Colors.green);
          },
        );
        final origin = source.selected;
        final selection = switcher.currentState!.selectAdjacent(1);
        await tester.pump();
        await _finishFrames(tester);
        await selection;
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        expect(find.byKey(ValueKey((origin, 'snapshot'))), findsOneWidget);
        expect(
          built,
          isNot(contains(origin)),
          reason: 'Changing selection must not discard the departing readback.',
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        for (final group in [false, true]) {
          testWidgets(
            'unread tint preserves cached ${group ? 'group' : 'chat'} pixels in ${brightness.name} at $scale',
            (tester) async {
              if (group) {
                source.entries[1] = RecentConversationEntry.group(
                  BotGroup(
                    observationComplete: true,
                    scope: source.entries.first.key.chat!.workspace,
                    instance: 'Host',
                    id: 'room-unread',
                    name: 'Research team',
                    members: const [],
                  ),
                  unread: false,
                );
              }
              var builds = 0;
              await mount(
                tester,
                brightness: brightness,
                textScale: scale,
                buildPreview: (_) {
                  builds++;
                  return const Scaffold(body: Text('Saved answer'));
                },
              );
              switcher.currentState!.openStack();
              await _finishFrames(tester);
              final entry = source.entries[1];
              final pixels = find.byKey(ValueKey((entry.key, 'snapshot')));
              final image = tester.widget<RawImage>(pixels).image!;
              final bytes = source.snapshots.retainedBytes;
              final revision = session.cardRevision(entry.key);
              final before = (builds, source.previewReads, source.historyReads);
              final order = session.entries.map((e) => e.key).toList();
              final rect = tester.getRect(pixels);
              final tint = find.byKey(ValueKey((entry.key, 'unread-tint')));
              expect(tint, findsNothing);
              for (final unread in [true, false, true]) {
                source.entries[1] = group
                    ? RecentConversationEntry.group(
                        entry.group!,
                        unread: unread,
                      )
                    : RecentConversationEntry.chat(
                        key: entry.key.chat!,
                        title: entry.title,
                        unread: unread,
                      );
                source.notifyListeners();
                await tester.pump();
                await _finishFrames(tester);
                expect(tint, unread ? findsOneWidget : findsNothing);
                expect(tester.widget<RawImage>(pixels).image, same(image));
                expect(image.debugDisposed, isFalse);
                expect(source.snapshots.retainedBytes, bytes);
                expect(session.cardRevision(entry.key), revision);
                expect((
                  builds,
                  source.previewReads,
                  source.historyReads,
                ), before);
                expect(session.entries.map((e) => e.key), order);
                expect(tester.getRect(pixels), rect);
                if (unread) {
                  final context = tester.element(tint);
                  final tokens = WingTokens.of(context);
                  final decoration =
                      tester.widget<DecoratedBox>(tint).decoration
                          as BoxDecoration;
                  expect(
                    decoration.color,
                    tokens.recentUnreadTint(
                      Theme.of(context).colorScheme.primaryContainer,
                    ),
                  );
                  expect(
                    decoration.border!.top.color,
                    tokens.recentUnreadBorder,
                  );
                }
              }
              expect(source.opens, isEmpty);
              switcher.currentState!.dismissStack();
              await _finishFrames(tester);
              expect(tint, findsNothing);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    testWidgets('closed composer keyboard changes preserve neighbor pixels', (
      tester,
    ) async {
      await mount(tester);
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      final key = source.entries[1].key;
      final pixels = find.byKey(ValueKey((key, 'snapshot')));
      final old = tester.widget<RawImage>(pixels).image!;
      switcher.currentState!.dismissStack();
      await _finishFrames(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pump();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      expect(
        old.debugDisposed,
        isFalse,
        reason: 'Unchanged card pixels must survive the normal composer IME',
      );
      expect(
        tester.widget<RawImage>(pixels).image,
        same(old),
        reason: 'Unchanged card pixels must survive the normal composer IME',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a new visit borrows retained workspace screenshot images', (
      tester,
    ) async {
      await mount(tester);
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      final neighbor = source.entries[1].key;
      final finder = find.byKey(ValueKey((neighbor, 'snapshot')));
      final image = tester.widget<RawImage>(finder).image!;
      final bytes = source.snapshots.retainedBytes;
      await tester.pumpWidget(const SizedBox());
      expect(image.debugDisposed, isFalse);
      expect(source.snapshots.retainedBytes, bytes);
      session.dispose();
      session = RecentConversationSession.fromRecents(
        entries: source.entries,
        source: source,
        activity: activity,
      );
      source.previewReads = source.historyReads = 0;
      await mount(tester);
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      expect(tester.widget<RawImage>(finder).image, same(image));
      expect(source.previewReads, 0);
      expect(source.historyReads, 0);
      expect(image.debugDisposed, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('equivalent workspace themes preserve prepared images', (
      tester,
    ) async {
      final built = <RecentConversationKey>[];
      await mount(
        tester,
        buildPreview: (card) {
          built.add(card.entry.key);
          return const ColoredBox(color: Colors.green);
        },
      );
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      final key = source.selected;
      final image = tester
          .widget<RawImage>(find.byKey(ValueKey((key, 'snapshot'))))
          .image;
      final before = List.of(built);
      for (var rebuild = 0; rebuild < 3; rebuild++) {
        source.notifyListeners();
        await tester.pump();
      }
      await _finishFrames(tester);
      expect(
        tester.widget<RawImage>(find.byKey(ValueKey((key, 'snapshot')))).image,
        same(image),
      );
      expect(built, before);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'reopening retains pixels while an updated preview is pending',
      (tester) async {
        await mount(tester);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        final entry = source.entries[1];
        final pixels = find.byKey(ValueKey((entry.key, 'snapshot')));
        final old = tester.widget<RawImage>(pixels).image!;
        switcher.currentState!.dismissStack();
        await _finishFrames(tester);
        final pending = Completer<RecentConversationPreview>();
        source.waitingPreviews[entry.key] = pending;
        source.revisions[entry.key] = 1;
        source.notifyListeners();
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        expect(
          pixels,
          findsOneWidget,
          reason: 'A refresh must not replace usable pixels with a blank card',
        );
        expect(tester.widget<RawImage>(pixels).image, same(old));
        expect(old.debugDisposed, isFalse);
        pending.complete(source._readyPreview(entry));
        await _finishFrames(tester);
        expect(tester.widget<RawImage>(pixels).image, isNot(same(old)));
        expect(old.debugDisposed, isTrue);
        expect(source.opens, isEmpty);
      },
    );

    testWidgets('pending bot placeholder updates to its resolved identity', (
      tester,
    ) async {
      final entry = source.entries[1];
      source.entries[1] = RecentConversationEntry.chat(
        key: entry.key.chat!,
        title: 'Bot Chat',
        unread: false,
      );
      final pending = Completer<RecentConversationPreview>();
      source.waitingPreviews[entry.key] = pending;
      await mount(tester);
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      final fixture = BotsFixture();
      source.appearances[entry.key] = (await fixture.repository.bots()).first;
      source.notifyListeners();
      await tester.pump();
      expect(find.text('Atlas'), findsOneWidget);
      expect(find.text('Bot Chat'), findsNothing);
      expect(find.byType(BotAvatar), findsOneWidget);
      pending.complete(source._readyPreview(entry));
      await _finishFrames(tester);
    });

    testWidgets(
      'group appearance replaces shared pixels without another preview read',
      (tester) async {
        final fixture = BotsFixture();
        final group = (await readFixtureGroups(
          fixture.repository,
          groupMessages: null,
        )).single;
        final entry = RecentConversationEntry.group(group, unread: false);
        source.entries[1] = entry;
        final builds = <BotGroupAppearance>[];
        await mount(
          tester,
          buildPreview: (card) {
            if (card.entry.key == entry.key) builds.add(card.groupAppearance);
            return ConversationPreview(card: card, connectionLabel: 'Host');
          },
        );
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        final pixels = find.byKey(ValueKey((entry.key, 'snapshot')));
        expect(pixels, findsOneWidget);
        final old = tester.widget<RawImage>(pixels).image!;
        final reads = source.previewReads;
        expect(builds.last.byHandle, isEmpty);
        final roster = await fixture.repository.bots();
        source.groupAppearances[entry.key] = BotGroupAppearance.forGroup(
          group,
          roster,
        );
        source.notifyListeners();
        await tester.pump();
        expect(tester.widget<RawImage>(pixels).image, same(old));
        await _finishFrames(tester);
        expect(
          builds.last.byHandle.keys,
          containsAll(['bot_atlas', 'bot_mira']),
        );
        expect(tester.widget<RawImage>(pixels).image, isNot(same(old)));
        expect(old.debugDisposed, isTrue);
        expect(source.previewReads, reads);
        final ready = tester.widget<RawImage>(pixels).image!;
        switcher.currentState!.dismissStack();
        await _finishFrames(tester);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        expect(tester.widget<RawImage>(pixels).image, same(ready));
        expect(source.previewReads, reads);
      },
    );

    testWidgets(
      'genuine viewport refreshes identity after returning without replacing it while parked',
      (tester) async {
        final key = source.selected;
        final fixture = BotsFixture();
        source.appearances[key] = (await fixture.repository.bots()).first;
        final child = ListenableBuilder(
          listenable: source,
          builder: (context, _) => Scaffold(
            body: Center(child: Text(source.appearances[key]!.title)),
          ),
        );
        await mount(tester, liveChild: child);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        final pixels = find.byKey(ValueKey((key, 'snapshot')));
        final old = tester.widget<RawImage>(pixels).image!;
        final oldBytes = await tester.runAsync(
          () => old.toByteData(format: ui.ImageByteFormat.png),
        );
        fixture.profiles.first['ui_meta']['hermes-bots']['title'] =
            'Resolved Atlas with current identity';
        source.appearances[key] = (await fixture.repository.bots()).first;
        source.notifyListeners();
        await _finishFrames(tester);
        expect(
          tester.widget<RawImage>(pixels).image,
          same(old),
          reason:
              'Parked actual viewport must not be replaced by a reconstruction',
        );
        switcher.currentState!.dismissStack();
        await _finishFrames(tester);
        expect(
          find.text('Resolved Atlas with current identity'),
          findsOneWidget,
        );
        final reads = source.historyReads;
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        final next = tester.widget<RawImage>(pixels).image!;
        expect(next, isNot(same(old)));
        final nextBytes = await tester.runAsync(
          () => next.toByteData(format: ui.ImageByteFormat.png),
        );
        expect(
          listEquals(
            oldBytes!.buffer.asUint8List(),
            nextBytes!.buffer.asUint8List(),
          ),
          isFalse,
          reason:
              'New actual viewport pixels must contain the resolved identity',
        );
        expect(source.historyReads, reads);
      },
    );

    testWidgets('resizing the stack restarts its image batch', (tester) async {
      await mount(tester);
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      expect(
        find.byKey(const ValueKey('recent-snapshot-progress')),
        findsNothing,
      );
      final pixels = find.byKey(ValueKey((source.entries[1].key, 'snapshot')));
      final previous = tester.widget<RawImage>(pixels).image!;
      tester.view.physicalSize = const Size(700, 700);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('recent-snapshot-progress')),
        findsNothing,
      );
      await _finishFrames(tester);
      expect(
        find.byKey(const ValueKey('recent-snapshot-progress')),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey((source.entries[1].key, 'snapshot'))),
        findsOneWidget,
      );
      final resized = tester.widget<RawImage>(pixels).image!;
      expect(resized, isNot(same(previous)));
      expect(previous.debugDisposed, isTrue);
      expect(resized.width, resized.height);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a changed conversation revision replaces only its image', (
      tester,
    ) async {
      final built = <RecentConversationKey>[];
      await mount(
        tester,
        buildPreview: (card) {
          built.add(card.entry.key);
          return ColoredBox(
            color: source.revisions[card.entry.key] == 1
                ? Colors.blue
                : Colors.green,
          );
        },
      );
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      final key = source.entries[1].key;
      final old = tester
          .widget<RawImage>(find.byKey(ValueKey((key, 'snapshot'))))
          .image!;
      built.clear();
      source.revisions[key] = 1;
      source.notifyListeners();
      await _finishFrames(tester);
      final image = tester
          .widget<RawImage>(find.byKey(ValueKey((key, 'snapshot'))))
          .image!;
      expect(image, isNot(same(old)));
      expect(old.debugDisposed, isTrue);
      expect(built, [key]);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'pending Markdown never publishes a blank snapshot and exit fences it',
      (tester) async {
        final parsed = Completer<MarkdownParseResult>();
        await mount(
          tester,
          buildPreview: (_) => BackgroundMarkdownContent(
            data: '**Prepared message**',
            deliverables: false,
            parse: (_) => parsed.future,
            builder: (_, _) => const ColoredBox(color: Colors.green),
          ),
        );
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        expect(
          find.byKey(ValueKey((source.entries[1].key, 'snapshot'))),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('recent-snapshot-progress')),
          findsNothing,
        );
        switcher.currentState!.dismissStack();
        await _finishFrames(tester);
        parsed.complete(const MarkdownParseResult([], 0, 0, 0));
        await _finishFrames(tester);
        expect(find.byType(RawImage), findsNothing);
        expect(find.byType(BackgroundMarkdownContent), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'failed and timed-out reads settle the spinner without opening chats',
      (tester) async {
        final failed = Completer<RecentConversationPreview>();
        final held = Completer<RecentConversationPreview>();
        source.waitingPreviews[source.entries[1].key] = failed;
        source.waitingPreviews[source.entries[2].key] = held;
        await mount(tester);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        failed.completeError(StateError('Fixture history unavailable'));
        await tester.pump(const Duration(seconds: 6));
        await _finishFrames(tester);
        expect(
          find.byKey(const ValueKey('recent-snapshot-progress')),
          findsNothing,
        );
        expect(source.opens, isEmpty);
        held.complete(source._readyPreview(source.entries[2]));
        await _finishFrames(tester);
        expect(
          find.byKey(ValueKey((source.entries[2].key, 'snapshot'))),
          findsNothing,
          reason: 'Timed-out history cannot publish a late image.',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'batch deadline stops loading even when physical reads remain held',
      (tester) async {
        session.dispose();
        source.dispose();
        source = _UiSource(count: 100);
        session = RecentConversationSession.fromRecents(
          entries: source.entries,
          source: source,
          activity: activity,
        );
        for (final entry in source.entries.skip(1)) {
          source.waitingPreviews[entry.key] =
              Completer<RecentConversationPreview>();
        }
        await mount(tester);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        expect(
          find.byKey(const ValueKey('recent-snapshot-progress')),
          findsNothing,
        );
        await tester.pump(const Duration(seconds: 16));
        await _finishFrames(tester);
        expect(
          find.byKey(const ValueKey('recent-snapshot-progress')),
          findsNothing,
        );
        expect(source.opens, isEmpty);
        expect(
          source.previewOrder.toSet(),
          hasLength(9),
          reason:
              'Initial admission stops at ten cards, including the real capture.',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('accessibility service leaves expert gestures available', (
      tester,
    ) async {
      await mount(tester, accessible: true);
      await _twoContacts(
        tester,
        const Offset(220, 400),
        const Offset(300, 400),
        const Offset(50, 400),
        const Offset(130, 400),
      );
      expect(source.opens, [source.entries[1].key]);
      expect(find.byType(StudioLoading), findsNothing);
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      expect(find.byTooltip('Open conversation'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cached card presentation publishes a completed preview read', (
      tester,
    ) async {
      final entry = source.entries[1];
      final pending = Completer<RecentConversationPreview>();
      source.waitingPreviews[entry.key] = pending;
      await mount(
        tester,
        buildPreview: (card) =>
            ColoredBox(color: card.preview == null ? Colors.red : Colors.green),
      );
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      expect(find.byKey(ValueKey((entry.key, 'snapshot'))), findsNothing);
      pending.complete(
        RecentConversationPreview(
          entry: entry,
          reading: TranscriptReadingSnapshot(
            messages: const [],
            historySessionId: entry.key.chat?.sessionId,
          ),
          draft: '',
          scopeLabel: 'Loaded saved conversation',
        ),
      );
      await _finishFrames(tester);
      final image = tester
          .widget<RawImage>(find.byKey(ValueKey((entry.key, 'snapshot'))))
          .image!;
      final pixels = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      expect(pixels!.getUint8(0), 76);
      expect(pixels.getUint8(1), 175);
      expect(pixels.getUint8(2), 80);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dragging keeps snapshots and starts no preview work', (
      tester,
    ) async {
      final delayedKey = source.entries[1].key;
      final delayedPreview = Completer<RecentConversationPreview>();
      source.waitingPreviews[delayedKey] = delayedPreview;
      await session.select(source.selected);
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var previewsBuilt = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: RecentConversationSwitcher(
            key: switcher,
            session: session,
            chatKey: source.selected,
            gesturesEnabled: true,
            nudgesEnabled: true,
            onPresentationChanged: (_, _) {},
            previewBuilder: (card) {
              previewsBuilt++;
              final preview = RecentConversationPreview(
                entry: card.entry,
                reading: TranscriptReadingSnapshot(
                  messages: [
                    for (var row = 0; row < 20; row++)
                      {
                        'id': row,
                        'role': row.isEven ? 'user' : 'assistant',
                        'content':
                            '${card.entry.title} message $row\n\n'
                            '**Saved discussion** with distinct reading state.\n\n'
                            '- First task\n- Second task',
                      },
                  ],
                  historySessionId: card.entry.key.chat!.sessionId,
                ),
                draft: '',
                scopeLabel: 'personal',
              );
              return _MountedCard(
                owner: card.entry.key,
                child: ConversationPreview(
                  card: RecentConversationCard(
                    entry: card.entry,
                    preview: preview,
                  ),
                  connectionLabel: 'Owned fixture',
                ),
              );
            },
            child: const ColoredBox(
              color: Colors.teal,
              child: SizedBox.expand(),
            ),
          ),
        ),
      );
      await _finishFrames(tester);
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      expect(find.byKey(ValueKey((delayedKey, 'snapshot'))), findsNothing);
      delayedPreview.complete(source._readyPreview(source.entries[1]));
      final snapshots = find.byWidgetPredicate(
        (widget) =>
            widget is RawImage &&
            source.entries.any(
              (entry) => widget.key == ValueKey((entry.key, 'snapshot')),
            ),
      );
      // Raster capture and Markdown preparation complete outside fake time.
      // Wait for the actual owned pixels before starting the drag contract.
      final preparationWait = Stopwatch()..start();
      while (snapshots.evaluate().length != source.entries.length &&
          preparationWait.elapsed < const Duration(seconds: 5)) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pump();
      expect(snapshots, findsNWidgets(source.entries.length));
      expect(find.byType(_MountedCard), findsNothing);
      final before = previewsBuilt;
      final readsBefore = source.previewReads;
      final drag = await tester.startGesture(const Offset(180, 400));
      for (var step = 1; step <= 10; step++) {
        await drag.moveTo(Offset(180 + step * 8, 400));
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(_MountedCard), findsNothing);
        expect(snapshots, findsNWidgets(source.entries.length));
      }
      expect(
        previewsBuilt,
        before,
        reason:
            'Dragging transforms already loaded rich previews; it must '
            'not reconstruct their message trees every animation frame.',
      );
      expect(
        source.previewReads,
        readsBefore,
        reason: 'History admission cannot start on a drag frame.',
      );
      await drag.up();
      await _finishFrames(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'catalog retry preserves the focused identity after circular browsing',
      (tester) async {
        final recovered = source.entries.removeLast();
        enterDormant();
        source.catalogRead = Completer();
        await mount(tester, dormant: true, accessible: true);
        switcher.currentState!.openStack();
        source.catalogRead!.complete(
          RecentConversationCatalog(
            entries: source.entries.take(2),
            error: 'One profile is offline.',
          ),
        );
        await _finishFrames(tester);
        await tester.tap(find.byTooltip('Previous conversation'));
        await _finishFrames(tester);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label == 'Chat 1, conversation 2 of 2',
          ),
          findsOneWidget,
        );
        source.catalogRead = Completer();
        await tester.tap(find.byTooltip('Retry recent chats'));
        await tester.pump();
        source.entries.add(recovered);
        source.catalogRead!.complete(
          RecentConversationCatalog(entries: source.entries, error: null),
        );
        await _finishFrames(tester);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label == 'Chat 1, conversation 2 of 3',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Open conversation'));
        await _finishFrames(tester);
        expect(source.selected, source.entries[1].key);
        expect(tester.takeException(), isNull);
      },
    );

    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'opening cover uses progress without a repeated caption in ${brightness.name} at $scale',
          (tester) async {
            final frame = GlobalKey();
            await mount(
              tester,
              brightness: brightness,
              textScale: scale,
              frame: frame,
            );
            source.waitingOpen = Completer<void>();
            switcher.currentState!.openStack();
            await _finishFrames(tester);
            final selection = switcher.currentState!.selectAdjacent(1);
            await _finishFrames(tester);
            final title = tester.getRect(find.text(source.entries[1].title));
            expect(find.text('Opening conversation…'), findsNothing);
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(
              find.bySemanticsLabel('Opening conversation'),
              findsOneWidget,
            );
            expect(title.top, greaterThanOrEqualTo(0));
            expect(title.left, greaterThanOrEqualTo(0));
            expect(
              title.bottom,
              lessThanOrEqualTo(tester.getRect(find.byType(StudioLoading)).top),
            );
            expect(
              find.text(source.entries[1].key.chat!.workspace.profileName),
              findsNothing,
            );
            await _captureCurrent(
              tester,
              frame,
              'opening-${brightness.name}-$scale',
            );
            source.waitingOpen!.complete();
            await _finishFrames(tester);
            await selection;
            expect(find.text('Opening conversation…'), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('swipe supersedes a held conversation opening', (tester) async {
      await mount(tester);
      final held = source.waitingOpen = Completer<void>();
      final first = switcher.currentState!.selectAdjacent(1);
      await _finishFrames(tester);
      source.waitingOpen = null;
      await _twoContacts(
        tester,
        const Offset(220, 400),
        const Offset(300, 400),
        const Offset(50, 400),
        const Offset(130, 400),
      );
      expect(source.opens, [source.entries[1].key, source.entries[2].key]);
      expect(source.selected, source.entries[2].key);
      held.complete();
      await _finishFrames(tester);
      await first;
      expect(source.selected, source.entries[2].key);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'swipe returns from a held opening and ignores its late failure',
      (tester) async {
        await mount(tester);
        final held = source.waitingOpen = Completer<void>();
        final opening = switcher.currentState!.selectAdjacent(1);
        await _finishFrames(tester);
        await _twoContacts(
          tester,
          const Offset(100, 400),
          const Offset(180, 400),
          const Offset(270, 400),
          const Offset(350, 400),
        );
        await opening;
        expect(source.selected, source.entries[0].key);
        expect(find.byType(StudioLoading), findsNothing);
        held.completeError(StateError('Retired opening failed'));
        await _finishFrames(tester);
        expect(source.opens, [source.entries[1].key]);
        expect(source.selected, source.entries[0].key);
        expect(session.error, isNull);
        expect(session.active, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('card opens during expansion and waits for a painted chat', (
      tester,
    ) async {
      await mount(tester);
      source.waitingOpen = Completer<void>();
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      final selection = switcher.currentState!.selectAdjacent(1);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        source.opens,
        [source.entries[1].key],
        reason:
            'Opening overlaps expansion rather than waiting for its spring.',
      );
      for (var frame = 0; frame < 50; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(source.opens, [source.entries[1].key]);
      final bounds = tester.getRect(
        find.byKey(ValueKey((source.entries[1].key, 'snapshot'))),
      );
      expect(bounds.left.abs(), lessThan(1));
      expect(bounds.top.abs(), lessThan(1));
      expect(
        bounds.width,
        closeTo(
          tester.view.physicalSize.width / tester.view.devicePixelRatio,
          1,
        ),
      );
      expect(
        bounds.height,
        closeTo(
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
          1,
        ),
      );
      expect(find.text('Swipe to browse · tap to open'), findsNothing);
      source.waitingOpen!.complete();
      await _finishFrames(tester);
      await selection;
      expect(find.byType(StudioLoading), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'quick stack flick coasts across several cards and can be caught',
      (tester) async {
        await mount(tester);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        await tester.flingFrom(
          const Offset(250, 400),
          const Offset(-110, 0),
          2800,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        final catchGesture = await tester.startGesture(const Offset(180, 400));
        await tester.pump();
        final visible = tester
            .widgetList<Positioned>(find.byType(Positioned))
            .where((widget) => widget.key is ValueKey<int>)
            .map((widget) => (widget.key! as ValueKey<int>).value)
            .toList();
        expect(visible.reduce((a, b) => a > b ? a : b), greaterThan(2));
        final caught = tester.getRect(find.byKey(ValueKey(visible.first)));
        await tester.pump(const Duration(milliseconds: 160));
        expect(tester.getRect(find.byKey(ValueKey(visible.first))), caught);
        expect(source.opens, isEmpty);
        final center = visible.reduce((a, b) => a < b ? a : b) + 1;
        await catchGesture.up();
        await _finishFrames(tester);
        expect(
          source.selected,
          source.entries[center % source.entries.length].key,
          reason:
              'A tap catches and opens the card actually visible beneath it.',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'conversation construction waits for expansion before first paint',
      (tester) async {
        await mount(tester);
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        var finished = false;
        final selection = switcher.currentState!
            .selectAdjacent(1)
            .then((_) => finished = true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(source.selected, source.entries[1].key);
        expect(finished, isFalse);
        final live = tester.widget<Offstage>(
          find
              .ancestor(
                of: find.text('Selectable message', skipOffstage: false),
                matching: find.byType(Offstage),
              )
              .first,
        );
        expect(
          live.offstage,
          isTrue,
          reason: 'Moving cards must not mount or lay out the selected chat.',
        );
        expect(
          find.text('Mounted conversation 0', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('Mounted conversation 1', skipOffstage: false),
          findsNothing,
        );
        final cover = tester.widget<FadeTransition>(
          find
              .descendant(
                of: find.byType(RecentConversationSwitcher),
                matching: find.byType(FadeTransition),
              )
              .first,
        );
        expect(cover.opacity.value, 1);
        await tester.pump(const Duration(milliseconds: 170));
        await tester.pump();
        expect(
          find.text('Mounted conversation 0', skipOffstage: false),
          findsNothing,
        );
        expect(find.text('Mounted conversation 1'), findsOneWidget);
        expect(
          cover.opacity.value,
          1,
          reason: 'Reveal must wait for the selected chat paint.',
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(finished, isFalse);
        expect(
          cover.opacity.value,
          1,
          reason:
              'Deferred reading layout needs an opaque paint frame before reveal.',
        );
        await tester.pump(const Duration(milliseconds: 120));
        await selection;
        expect(find.byType(RawImage), findsNothing);
        expect(find.text('Opening conversation…'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('disposing during expansion releases the pending paint wait', (
      tester,
    ) async {
      await mount(tester);
      var completed = false;
      final selection = switcher.currentState!
          .selectAdjacent(1)
          .then((_) => completed = true);
      await tester.pump(const Duration(milliseconds: 16));
      expect(source.selected, source.entries[1].key);
      expect(completed, isFalse);
      await tester.pumpWidget(const SizedBox());
      await selection;
      expect(completed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'snapshot memory is bounded and discarded pixels are released',
      (tester) async {
        Future<ui.Image> pixels(int size) async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
            Paint()..color = Colors.teal,
          );
          final picture = recorder.endRecording();
          final image = await tester.runAsync(
            () => picture.toImage(size, size),
          );
          picture.dispose();
          return image!;
        }

        final store = RecentConversationSnapshots(byteLimit: 3200);
        final cache = ConversationCardSnapshots(
          store,
          environment: () => 'test',
          liveEnvironment: () => 'test',
        );
        addTearDown(store.dispose);
        final images = [for (var i = 0; i < 3; i++) await pixels(20)];
        for (var i = 0; i < 3; i++) {
          cache.record(
            source.entries[i].key,
            images[i],
            live: i == 0,
            revision: 0,
          );
        }
        expect(cache.imageFor(source.entries[0].key), isNull);
        expect(images[0].debugDisposed, isTrue);
        expect(cache.imageFor(source.entries[1].key), isNotNull);
        final oversized = await pixels(40);
        cache.record(source.entries[0].key, oversized, live: true, revision: 0);
        expect(oversized.debugDisposed, isTrue);
        expect(cache.imageFor(source.entries[1].key), isNotNull);
        cache.retain({source.entries[1].key});
        expect(
          images[2].debugDisposed,
          isFalse,
          reason: 'Prepared images survive neighborhood changes.',
        );
        cache.reserve(1600);
        expect(
          images[2].debugDisposed,
          isTrue,
          reason: 'Readback in flight counts against the pixel budget.',
        );
        expect(images[1].debugDisposed, isFalse);
        cache.release(1600);
        cache.record(
          source.entries[0].key,
          await pixels(20),
          live: true,
          revision: 0,
        );
        final visited = cache.imageFor(source.entries[0].key)!;
        cache.retain({source.entries[1].key});
        expect(cache.isLive(source.entries[0].key), isTrue);
        expect(
          visited.debugDisposed,
          isFalse,
          reason: 'Visited real viewports survive ring neighborhood changes.',
        );
        store.clear();
        expect(images[1].debugDisposed, isTrue);
        expect(visited.debugDisposed, isTrue);
      },
    );

    testWidgets(
      'two-finger swipe opens an adjacent chat before the first pinch',
      (tester) async {
        enterDormant();
        await mount(tester, dormant: true);
        await _twoContacts(
          tester,
          const Offset(220, 400),
          const Offset(300, 400),
          const Offset(50, 400),
          const Offset(130, 400),
        );
        expect(source.opens, [source.entries[1].key]);
        expect(find.text('Swipe to browse · tap to open'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'first swipe uses ready neighbors while the catalog refresh is held',
      (tester) async {
        enterDormant();
        source.catalogRead = Completer<RecentConversationCatalog>();
        await mount(tester, dormant: true);
        await _twoContacts(
          tester,
          const Offset(220, 400),
          const Offset(300, 400),
          const Offset(50, 400),
          const Offset(130, 400),
        );
        expect(source.opens, [source.entries[1].key]);
        source.catalogRead!.complete(source.catalog);
        await _finishFrames(tester);
        expect(source.opens, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'first swipe ignores a catalog completed after route disposal',
      (tester) async {
        enterDormant();
        source.catalogEntries = [source.entries.first];
        source.catalogRead = Completer<RecentConversationCatalog>();
        await mount(tester, dormant: true);
        await _twoContacts(
          tester,
          const Offset(220, 400),
          const Offset(300, 400),
          const Offset(50, 400),
          const Offset(130, 400),
        );
        expect(source.catalogReads, 1);
        expect(source.opens, isEmpty);
        await tester.pumpWidget(const SizedBox());
        source.catalogRead!.complete(source.catalog);
        await _finishFrames(tester);
        expect(source.opens, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('entry pinch activates once; canceled pinch stays dormant', (
      tester,
    ) async {
      enterDormant();
      await mount(tester, dormant: true);
      expect(session.modeEnabled, isFalse);
      expect(source.catalogReads, 0);
      final first = await tester.startGesture(
        const Offset(75, 400),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(285, 400),
        pointer: 2,
      );
      await first.moveTo(const Offset(145, 400));
      await second.moveTo(const Offset(215, 400));
      await tester.pump(const Duration(milliseconds: 16));
      await first.cancel();
      await second.cancel();
      await _finishFrames(tester);
      expect(session.modeEnabled, isFalse);
      expect(source.catalogReads, 0);
      await _twoContacts(
        tester,
        const Offset(75, 400),
        const Offset(285, 400),
        const Offset(145, 400),
        const Offset(215, 400),
      );
      expect(session.modeEnabled, isTrue);
      expect(source.catalogReads, 1);
      expect(session.entries, hasLength(3));
      expect(find.text('Swipe to browse · tap to open'), findsOneWidget);
      switcher.currentState!.dismissStack();
      await _finishFrames(tester);
      expect(session.modeEnabled, isTrue);
      await _twoContacts(
        tester,
        const Offset(220, 400),
        const Offset(300, 400),
        const Offset(50, 400),
        const Offset(130, 400),
      );
      expect(source.opens, [source.entries[1].key]);
      expect(tester.takeException(), isNull);
    });

    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'single-card entry, loading and retry ${brightness.name} $scale',
          (tester) async {
            source.entries.removeRange(1, source.entries.length);
            enterDormant();
            source.catalogRead = Completer();
            final frame = GlobalKey();
            await mount(
              tester,
              dormant: true,
              brightness: brightness,
              textScale: scale,
              accessible: true,
              frame: frame,
            );
            tester.view.physicalSize = Size(scale == 1 ? 360 : 320, 800);
            await tester.pump();
            await _twoContacts(
              tester,
              const Offset(75, 400),
              const Offset(285, 400),
              const Offset(145, 400),
              const Offset(215, 400),
            );
            expect(find.text('Loading recent chats…'), findsNothing);
            expect(find.text('No other recent chats.'), findsNothing);
            expect(
              tester
                  .widget<IconButton>(
                    find.widgetWithIcon(IconButton, Icons.chevron_right),
                  )
                  .onPressed,
              isNull,
            );
            await _capture(
              tester,
              frame,
              'entry-loading-${brightness.name}-$scale',
            );
            source.catalogRead!.complete(
              RecentConversationCatalog(
                entries: const [],
                error: 'Recent chats could not be loaded.',
              ),
            );
            await _finishFrames(tester);
            expect(find.byTooltip('Retry recent chats'), findsOneWidget);
            expect(find.text('No other recent chats.'), findsNothing);
            final card = find.descendant(
              of: find.byType(Transform),
              matching: find.byType(RawImage),
            );
            expect(card, findsOneWidget);
            expect(
              tester.getRect(card).bottom,
              lessThanOrEqualTo(
                tester
                        .getTopLeft(
                          find.text('Recent chats could not be loaded.'),
                        )
                        .dy -
                    8,
              ),
              reason: 'Large error text must stay below the scaled card.',
            );
            await _capture(
              tester,
              frame,
              'entry-failed-${brightness.name}-$scale',
            );
            source.catalogRead = Completer();
            await tester.tap(find.byTooltip('Retry recent chats'));
            await tester.pump();
            expect(source.catalogReads, 2);
            source.catalogRead!.complete(
              RecentConversationCatalog(entries: const [], error: null),
            );
            await _finishFrames(tester);
            expect(find.text('No other recent chats.'), findsOneWidget);
            final movingCards = find.descendant(
              of: find.byType(Transform),
              matching: find.byType(RawImage),
            );
            expect(movingCards, findsOneWidget);
            await _capture(
              tester,
              frame,
              'entry-empty-${brightness.name}-$scale',
            );
            await tester.tap(find.byTooltip('Open conversation'));
            await _finishFrames(tester);
            expect(session.modeEnabled, isTrue);
            expect(source.opens, isEmpty);
            expect(find.text('No other recent chats.'), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('two-finger horizontal movement switches once and wraps', (
      tester,
    ) async {
      await mount(tester);
      await _twoContacts(
        tester,
        const Offset(220, 400),
        const Offset(300, 400),
        const Offset(50, 400),
        const Offset(130, 400),
      );
      expect(source.opens, [source.entries[1].key]);
      expect(find.text('Swipe to browse · tap to open'), findsNothing);
      await _twoContacts(
        tester,
        const Offset(80, 400),
        const Offset(160, 400),
        const Offset(250, 400),
        const Offset(330, 400),
      );
      expect(source.selected, source.entries[0].key);
      await _twoContacts(
        tester,
        const Offset(80, 400),
        const Offset(160, 400),
        const Offset(250, 400),
        const Offset(330, 400),
      );
      expect(source.selected, source.entries[2].key);
      expect(tester.takeException(), isNull);
    });

    for (final dx in [-170.0, 170.0]) {
      for (final dy in [-240.0, -120.0, 120.0, 240.0]) {
        testWidgets(
          'two-finger diagonal swipe switches with dx $dx and dy $dy',
          (tester) async {
            await mount(tester);
            final a = Offset(dx < 0 ? 220 : 80, 400);
            final b = a + const Offset(80, 0);
            final delta = Offset(dx, dy);
            await _twoContacts(tester, a, b, a + delta, b + delta);
            expect(source.opens, [source.entries[dx < 0 ? 1 : 2].key]);
            expect(find.text('Swipe to browse · tap to open'), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('two-finger swipe accepts vertical movement before direction', (
      tester,
    ) async {
      await mount(tester);
      final first = await tester.startGesture(
        const Offset(220, 400),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(300, 400),
        pointer: 2,
      );
      await first.moveBy(const Offset(0, 100));
      await second.moveBy(const Offset(0, 100));
      await tester.pump(const Duration(milliseconds: 16));
      expect(source.opens, isEmpty);
      await first.moveBy(const Offset(-170, 40));
      await second.moveBy(const Offset(-170, 40));
      await tester.pump(const Duration(milliseconds: 16));
      await first.up();
      await second.up();
      await _finishFrames(tester);
      expect(source.opens, [source.entries[1].key]);
      expect(find.text('Swipe to browse · tap to open'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('two-finger vertical movement alone does not switch', (
      tester,
    ) async {
      await mount(tester);
      await _twoContacts(
        tester,
        const Offset(180, 400),
        const Offset(260, 400),
        const Offset(180, 640),
        const Offset(260, 640),
      );
      expect(source.opens, isEmpty);
      expect(find.text('Swipe to browse · tap to open'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final earlyNarrowing in [false, true]) {
      testWidgets(
        'two-finger swipe with ${earlyNarrowing ? 'early' : 'late'} narrowing stays a swipe',
        (tester) async {
          await mount(tester);
          final first = await tester.startGesture(
            const Offset(220, 400),
            pointer: 1,
          );
          final second = await tester.startGesture(
            const Offset(300, 400),
            pointer: 2,
          );
          await first.moveBy(Offset(earlyNarrowing ? -12 : -24, 0));
          await second.moveBy(const Offset(-24, 0));
          await tester.pump(const Duration(milliseconds: 16));
          await first.moveTo(const Offset(50, 400));
          await second.moveTo(const Offset(100, 400));
          await tester.pump(const Duration(milliseconds: 16));
          await first.up();
          await second.up();
          await _finishFrames(tester);
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          expect(source.opens, [source.entries[1].key]);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final (span, contraction) in [(60.0, 20.0), (200.0, 40.0)]) {
      testWidgets(
        'small inward finger drift does not open the stack at span $span',
        (tester) async {
          await mount(tester);
          await _twoContacts(
            tester,
            Offset(180 - span / 2, 400),
            Offset(180 + span / 2, 400),
            Offset(180 - (span - contraction) / 2, 400),
            Offset(180 + (span - contraction) / 2, 400),
          );
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          expect(source.opens, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('two-finger swipe tolerates separately delivered moves', (
      tester,
    ) async {
      await mount(tester);
      final first = await tester.startGesture(
        const Offset(220, 400),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(300, 400),
        pointer: 2,
      );
      // The trailing finger arrives first, temporarily narrowing the span.
      await second.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await first.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await second.moveTo(const Offset(130, 400));
      await tester.pump(const Duration(milliseconds: 16));
      await first.moveTo(const Offset(50, 400));
      await tester.pump(const Duration(milliseconds: 16));
      await first.up();
      await second.up();
      await _finishFrames(tester);
      expect(find.text('Swipe to browse · tap to open'), findsNothing);
      expect(source.opens, [source.entries[1].key]);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'pinch stays open after lift; browsing does not select; tap commits',
      (tester) async {
        await mount(tester);
        await _twoContacts(
          tester,
          const Offset(80, 400),
          const Offset(280, 400),
          const Offset(145, 400),
          const Offset(215, 400),
        );
        expect(find.text('Swipe to browse · tap to open'), findsOneWidget);
        expect(source.opens, isEmpty);
        await tester.dragFrom(const Offset(260, 400), const Offset(-210, 0));
        await _finishFrames(tester);
        expect(source.opens, isEmpty);
        await tester.tapAt(const Offset(180, 400));
        await _finishFrames(tester);
        expect(source.opens, [source.entries[1].key]);
        expect(find.text('Swipe to browse · tap to open'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'return expands the current card after multiple circular laps',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await mount(tester);
          switcher.currentState!.openStack();
          await _finishFrames(tester);
          for (var i = 0; i < 6; i++) {
            await tester.dragFrom(
              const Offset(260, 400),
              const Offset(-210, 0),
            );
            await _finishFrames(tester);
          }
          expect(source.opens, isEmpty);
          expect(
            find.bySemanticsLabel(RegExp('Chat 0, conversation 1 of 3')),
            findsOneWidget,
          );
          await tester.tapAt(const Offset(180, 400));
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find.bySemanticsLabel(RegExp('Chat 0, conversation 1 of 3')),
            findsOneWidget,
          );
          await _finishFrames(tester);
          expect(source.opens, isEmpty);
          await _twoContacts(
            tester,
            const Offset(80, 400),
            const Offset(160, 400),
            const Offset(250, 400),
            const Offset(330, 400),
          );
          expect(source.selected, source.entries[2].key);
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets('a new gesture can interrupt a card returning to the chat', (
      tester,
    ) async {
      await mount(tester);
      final first = await tester.startGesture(
        const Offset(220, 400),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(300, 400),
        pointer: 2,
      );
      await first.moveBy(
        const Offset(-24, 0),
        timeStamp: const Duration(milliseconds: 16),
      );
      await second.moveBy(
        const Offset(-24, 0),
        timeStamp: const Duration(milliseconds: 16),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 80));
      expect(source.opens, isEmpty);
      await _twoContacts(
        tester,
        const Offset(220, 400),
        const Offset(300, 400),
        const Offset(50, 400),
        const Offset(130, 400),
      );
      expect(source.opens, [source.entries[1].key]);
      expect(find.text('Swipe to browse · tap to open'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pointer timing distinguishes a short fling from a slow drag', (
      tester,
    ) async {
      await mount(tester);
      Future<void> drag(Duration lastMove) async {
        final first = await tester.startGesture(
          const Offset(220, 400),
          pointer: 1,
        );
        final second = await tester.startGesture(
          const Offset(300, 400),
          pointer: 2,
        );
        await first.moveBy(
          const Offset(-19, 0),
          timeStamp: const Duration(milliseconds: 16),
        );
        await second.moveBy(
          const Offset(-19, 0),
          timeStamp: const Duration(milliseconds: 16),
        );
        await tester.pump(const Duration(milliseconds: 16));
        await first.moveBy(const Offset(-31, 0), timeStamp: lastMove);
        await second.moveBy(const Offset(-31, 0), timeStamp: lastMove);
        await tester.pump(lastMove - const Duration(milliseconds: 16));
        await first.up();
        await second.up();
        await _finishFrames(tester);
      }

      await drag(const Duration(milliseconds: 300));
      expect(source.opens, isEmpty);
      await drag(const Duration(milliseconds: 48));
      expect(source.opens, [source.entries[1].key]);
      expect(tester.takeException(), isNull);
    });

    for (final dormant in [false, true]) {
      testWidgets(
        'normal scrolling and subsequent pinch work with Recents dormant $dormant',
        (tester) async {
          if (dormant) enterDormant();
          await mount(tester, dormant: dormant);
          final scrollable = tester.state<ScrollableState>(
            find.descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            ),
          );
          final initial = scrollable.position.pixels;
          await tester.dragFrom(
            const Offset(220, 500),
            const Offset(-50, -180),
          );
          await _finishFrames(tester);
          expect(scrollable.position.pixels, greaterThan(initial));
          final afterUpwardScroll = scrollable.position.pixels;
          expect(source.opens, isEmpty);
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          await tester.dragFrom(const Offset(170, 350), const Offset(40, 100));
          await _finishFrames(tester);
          expect(scrollable.position.pixels, lessThan(afterUpwardScroll));
          expect(source.opens, isEmpty);
          await _twoContacts(
            tester,
            const Offset(80, 400),
            const Offset(280, 400),
            const Offset(145, 400),
            const Offset(215, 400),
          );
          expect(find.text('Swipe to browse · tap to open'), findsOneWidget);
          expect(source.opens, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('double tap and one-finger drag never switch chats', (
      tester,
    ) async {
      await mount(tester);
      await tester.tapAt(const Offset(220, 400));
      await tester.pump(const Duration(milliseconds: 80));
      final drag = await tester.startGesture(const Offset(220, 400));
      await drag.moveBy(const Offset(-130, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await drag.up();
      await _finishFrames(tester);
      expect(source.opens, isEmpty);
      expect(find.text('Swipe to browse · tap to open'), findsNothing);
    });

    testWidgets(
      'blocked messages keep their gestures and accessibility exposes navigation',
      (tester) async {
        await mount(tester);
        expect(find.text('Swipe to browse · tap to open'), findsNothing);
        expect(
          admitsConversationGesture(
            const PointerDownEvent(position: Offset(180, 70)),
          ),
          isFalse,
        );
        expect(
          admitsConversationGesture(
            const PointerDownEvent(position: Offset(40, 30)),
          ),
          isFalse,
          reason: 'Exclusion covers empty padding as well as painted text.',
        );
        await _twoContacts(
          tester,
          const Offset(80, 70),
          const Offset(260, 70),
          const Offset(145, 70),
          const Offset(195, 70),
        );
        expect(source.opens, isEmpty);
        expect(find.text('Swipe to browse · tap to open'), findsNothing);
        expect(
          admitsConversationGesture(
            const PointerDownEvent(position: Offset(180, 70)),
          ),
          isFalse,
        );
        final semantics = tester.ensureSemantics();
        try {
          await mount(tester, accessible: true);
          await _twoContacts(
            tester,
            const Offset(80, 400),
            const Offset(280, 400),
            const Offset(145, 400),
            const Offset(215, 400),
          );
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          switcher.currentState!.openStack();
          await tester.pumpAndSettle();
          expect(find.byTooltip('Next conversation'), findsOneWidget);
          expect(
            find.bySemanticsLabel(RegExp('Chat 0, conversation 1 of 3')),
            findsOneWidget,
          );
          final tree = tester
              .binding
              .renderViews
              .single
              .owner!
              .semanticsOwner!
              .rootSemanticsNode!
              .toStringDeep();
          expect(tree, isNot(contains('Selectable message')));
          await tester.tap(find.byTooltip('Next conversation'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Open conversation'));
          await _finishFrames(tester);
          expect(source.opens, [source.entries[1].key]);
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'unselected prose admits two fingers while code and buttons keep their gestures',
      (tester) async {
        await mount(tester);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConversationGestureBoundary(
                child: Column(
                  children: [
                    const SizedBox(
                      height: 100,
                      child: Center(child: Text('Prose message')),
                    ),
                    SizedBox(
                      key: key,
                      height: 100,
                      child: const SelectableText('Selectable prose'),
                    ),
                    const SourceCodeBlock(
                      code: 'horizontal source code',
                      language: 'dart',
                      headerAction: null,
                    ),
                    IconButton(
                      tooltip: 'Copy answer',
                      onPressed: () {},
                      icon: const Icon(Icons.copy),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          admitsConversationGesture(
            PointerDownEvent(
              position: tester.getCenter(find.text('Prose message')),
            ),
          ),
          isTrue,
        );
        expect(
          admitsConversationGesture(
            PointerDownEvent(
              position: tester.getCenter(find.text('Selectable prose')),
            ),
          ),
          isTrue,
        );
        expect(
          admitsConversationGesture(
            PointerDownEvent(
              position: tester.getCenter(find.byType(SourceCodeBlock)),
            ),
          ),
          isFalse,
        );
        expect(
          admitsConversationGesture(
            PointerDownEvent(
              position: tester.getCenter(find.byTooltip('Copy answer')),
            ),
          ),
          isFalse,
        );
      },
    );

    testWidgets(
      'appearance updates recapture only passive pixels without history reads',
      (tester) async {
        final key = source.entries[1].key;
        BotRecord appearance(String title) => BotRecord(
          scope: key.chat!.workspace,
          instance: 'Host',
          profile: HermesProfile.fromJson({
            'name': key.chat!.workspace.profileName,
          }),
          title: title,
          shape: 'squircle',
          color: '#65c7bc',
          pinned: false,
          hidden: false,
          hasAvatar: false,
          revision: 1,
          metadata: const {},
          chat: key.chat!,
        );
        source.appearances[key] = appearance('Atlas');
        final frame = GlobalKey();
        await mount(
          tester,
          frame: frame,
          buildPreview: (card) =>
              ConversationPreview(card: card, connectionLabel: 'Host'),
        );
        switcher.currentState!.openStack();
        await _finishFrames(tester);
        ui.Image pixels(RecentConversationKey key) => tester
            .widget<RawImage>(find.byKey(ValueKey((key, 'snapshot'))))
            .image!;
        final genuine = pixels(source.selected),
            previous = pixels(key),
            other = pixels(source.entries[2].key);
        final historyReads = source.historyReads,
            preparations = source.appearancePreparations;
        await _finishFrames(tester);
        expect(pixels(key), same(previous));
        expect(source.appearancePreparations, preparations);
        source.appearances[key] = appearance('Atlas renamed');
        source.notifyListeners();
        await _finishFrames(tester);
        expect(pixels(key), isNot(same(previous)));
        expect(previous.debugDisposed, isTrue);
        expect(pixels(source.selected), same(genuine));
        expect(pixels(source.entries[2].key), same(other));
        expect(source.historyReads, historyReads);
        expect(source.opens, isEmpty);
        await _capture(tester, frame, 'canonical-bot-stack');
        final reads = source.appearancePreparations;
        final first = await tester.startGesture(const Offset(130, 400));
        await first.moveBy(const Offset(-35, 0));
        await tester.pump(const Duration(milliseconds: 100));
        expect(source.appearancePreparations, reads);
        await first.cancel();
        await _finishFrames(tester);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('reduced motion publishes cached cards and returns directly', (
      tester,
    ) async {
      await mount(tester, reduced: true);
      switcher.currentState!.openStack();
      await _finishFrames(tester);
      expect(find.byType(RawImage), findsNWidgets(3));
      expect(source.opens, isEmpty);
      expect(switcher.currentState!.dismissStack(), isTrue);
      await _finishFrames(tester);
      expect(find.text('Swipe to browse · tap to open'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'spring interruption retains position and velocity; reduced motion settles immediately',
      (tester) async {
        final motion = ConversationCardMotion(tester);
        addTearDown(motion.dispose);
        motion.spring(position: 1, lift: 1, zoom: 1);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        final position = motion.position, velocity = motion.positionVelocity;
        expect(position, greaterThan(0));
        expect(velocity, greaterThan(0));
        motion.spring(position: 0, lift: 0, zoom: 0);
        expect(motion.position, position);
        expect(motion.positionVelocity, velocity);
        await tester.pumpAndSettle();
        expect(motion.position.abs(), lessThan(.001));
        var done = false;
        motion.spring(
          position: 1,
          lift: 1,
          zoom: 1,
          reducedMotion: true,
          settled: () => done = true,
        );
        expect(done, isTrue);
        expect(motion.animating, isFalse);
        expect(motion.position, 1);
      },
    );

    for (final brightness in Brightness.values) {
      testWidgets(
        'stack selection recovery reports once in ${brightness.name}',
        (tester) async {
          await mount(tester, brightness: brightness, accessible: true);
          switcher.currentState!.openStack();
          await _finishFrames(tester);
          await tester.tap(find.byTooltip('Next conversation'));
          await _finishFrames(tester);
          source.rejectOpen = true;
          await tester.tap(find.byTooltip('Open conversation'));
          await _finishFrames(tester);
          expect(source.selected, source.entries.first.key);
          expect(
            find.text('Couldn’t reopen this chat. Retry to continue.'),
            findsOneWidget,
          );
          expect(find.byType(SnackBar), findsNothing);
          source.rejectOpen = false;
          await tester.tap(find.byTooltip('Open conversation'));
          await _finishFrames(tester);
          expect(source.selected, source.entries[1].key);
          expect(
            find.text('Couldn’t reopen this chat. Retry to continue.'),
            findsNothing,
          );
        },
      );

      testWidgets('group reply cue paints in ${brightness.name}', (
        tester,
      ) async {
        final room = RecentConversationEntry.group(
          BotGroup(
            scope: source.entries[0].key.chat!.workspace,
            instance: 'Host',
            id: 'room-1',
            name: 'Discussion',
            members: const [],
            observationComplete: true,
          ),
          unread: true,
        );
        source.entries[1] = room;
        session.dispose();
        session = RecentConversationSession.fromRecents(
          entries: source.entries,
          source: source,
          activity: activity,
        );
        final frame = GlobalKey();
        await mount(tester, brightness: brightness, frame: frame);
        activity.value = ChatNoticeActivity(
          key: room.key,
          kind: ConversationActivityKind.reply,
          identity: 'answer:2',
          sequence: 1,
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 900));
        expect((await nudgePixels(tester)).alpha, greaterThan(0));
        await _captureCurrent(
          tester,
          frame,
          'group-arrival-cue-${brightness.name}',
        );
        expect(source.opens, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('neutral and amber cue paint in ${brightness.name}', (
        tester,
      ) async {
        await mount(tester, brightness: brightness);
        for (final kind in ConversationActivityKind.values) {
          activity.value = ChatNoticeActivity(
            key: source.entries[1].key,
            kind: kind,
            identity: kind.name,
            sequence: kind.index + 1,
          );
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 800));
          final pixels = await nudgePixels(tester);
          expect(pixels.alpha, greaterThan(0));
          final expected = kind == ConversationActivityKind.inputNeeded
              ? brightness == Brightness.light
                    ? const Color(0xffaa5e1e)
                    : const Color(0xfff4b160)
              : brightness == Brightness.light
              ? const Color(0xff2a393f)
              : const Color(0xffe8f7f7);
          expect(pixels.strongest.r, closeTo(expected.r, .025));
          expect(pixels.strongest.g, closeTo(expected.g, .025));
          expect(pixels.strongest.b, closeTo(expected.b, .025));
          await tester.pump(const Duration(milliseconds: 3100));
          expect(
            find.byKey(const ValueKey('recent-conversation-nudge')),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'passive rich card in ${brightness.name} at $scale avoids resource loads',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final source = _UiSource();
          addTearDown(source.dispose);
          final entry = source.entries[1];
          final card = RecentConversationCard(
            entry: entry,
            preview: RecentConversationPreview(
              entry: entry,
              reading: TranscriptReadingSnapshot(
                messages: const [
                  {
                    'id': 1,
                    'role': 'user',
                    'timestamp': 1791586680,
                    'content': 'Is this an upstream issue?',
                  },
                  {
                    'id': 2,
                    'role': 'assistant',
                    'timestamp': 1791586740,
                    'content':
                        'Yes—and **it is already reported upstream with the same symptoms**.\n\n'
                        '- [Issue #134240](https://github.com/NousResearch/hermes-agent/issues/134240): plugin skills load in chat but are missing from the list.\n'
                        '- [Fix PR #117836](https://github.com/NousResearch/hermes-agent/pull/117836): exposes skills across the listing surfaces.\n\n'
                        '| State | Result |\n| --- | --- |\n| Report | Open |\n| Fix | Pending |\n\n'
                        '```dart\nfinal snapshot = await boundary.toImage();\n```\n\n'
                        '![Reference image](https://example.invalid/image.png)',
                  },
                ],
                historySessionId: entry.key.chat?.sessionId,
              ),
              draft: '',
              scopeLabel: 'Unassigned',
              modelLabel: '6.1 Sol',
            ),
          );
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: frame,
                child: ConversationPreview(card: card, connectionLabel: 'Claw'),
              ),
            ),
          );
          await _finishFrames(tester);
          final prose = [
            ...tester
                .widgetList<RichText>(find.byType(RichText))
                .map((widget) => widget.text.toPlainText()),
            ...tester
                .widgetList<SelectableText>(find.byType(SelectableText))
                .map(
                  (widget) =>
                      widget.data ?? widget.textSpan?.toPlainText() ?? '',
                ),
          ].join('\n');
          expect(prose, contains('Issue #134240'));
          expect(prose, isNot(contains('https://github.com/NousResearch')));
          expect(prose, isNot(contains('**it is already')));
          expect(find.byType(MarkdownMessageContent), findsWidgets);
          expect(
            find.byType(ChatInlineImage),
            findsNothing,
            reason:
                'Offscreen Markdown images must not initiate network/decode work.',
          );
          expect(tester.takeException(), isNull);
          await _capture(
            tester,
            frame,
            'passive-card-${brightness.name}-$scale',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group pinch shares Recents and preserves native Back ${brightness.name} $scale',
        (tester) async {
          final voiceDevice = VoiceDeviceFixture();
          addTearDown(voiceDevice.stream.close);
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final fixture = _ScreenFixture();
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
            connectionIdentity: 'group-entry-ui',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: fixture.gateway,
          );
          addTearDown(controller.dispose);
          addTearDown(appPreferences.dispose);
          await controller.initialize();
          final roomStatus = ServerConnectionStatus('Home server')
            ..accessAvailable()
            ..liveChanged('discussion', true);
          addTearDown(roomStatus.dispose);
          final roomConnection = controller.connection.copyWith(
            icon: ConnectionIcon.cloud,
          );
          final roomServer = AdministrationRepository.forConnection(
            ConnectionAccess(connection: roomConnection, dashboardOAuth: null),
            'instance-1',
            connectionStatus: roomStatus,
          );
          addTearDown(roomServer.close);
          final botFixture = BotsFixture(server: roomServer);
          for (var seq = 1; seq <= 8; seq++) {
            botFixture.events.add({
              'room_id': 'room-1',
              'seq': seq,
              'kind': 'message.member',
              'created_at': fixture.now - 60 + seq,
              'actor': {'kind': 'member', 'id': 'atlas'},
              'payload': {
                'text':
                    'Group reply $seq. Keep the discussion and its reading position when switching conversations.',
              },
            });
          }
          late BotsSession bots;
          final activity = ValueNotifier<ChatNoticeActivity?>(null);
          addTearDown(activity.dispose);
          final frame = GlobalKey();
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: ChatNoticeActivityScope(
                  activity: activity,
                  child: RepaintBoundary(key: frame, child: child!),
                ),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                initialDestination: AppDestination.bots,
                savedConnections: () => [roomConnection],
                voiceDevice: voiceDevice,
                createBotsSession: () =>
                    bots = BotsSession((_) async => [botFixture.repository]),
              ),
            ),
          );
          await _finishFrames(tester);
          await tester.tap(find.text('Groups').first);
          await _finishFrames(tester);
          final landingRead = Completer<void>();
          botFixture.readHook = (_, method, _) async {
            if (method == 'groups.state') await landingRead.future;
            return null;
          };
          await tester.tap(find.text('Research team').first);
          await _finishFrames(tester);
          expect(find.byType(BotGroupScreen), findsOneWidget);
          final groupIdentity = find.descendant(
            of: find.byType(BotGroupScreen),
            matching: find.byType(ServerConnectionLabel),
          );
          expect(
            tester.widget<ServerConnectionLabel>(groupIdentity).status,
            same(roomStatus),
          );
          expect(
            ServerConnectionScope.scopeOf(tester.element(groupIdentity))!.icon,
            ConnectionIcon.cloud,
          );
          expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
          final landingViewport = find.byKey(
            const ValueKey('profile-transcript'),
          );
          final landingBounds = tester.getRect(landingViewport);
          expect(find.bySemanticsLabel('Loading history'), findsOneWidget);
          landingRead.complete();
          for (var frame = 0; frame < 24; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              tester.getRect(landingViewport),
              landingBounds,
              reason:
                  'A group landing must not resize while initial loading feedback clears.',
            );
          }
          expect(find.byType(StudioLoading), findsNothing);
          final switcherState = tester.state<RecentConversationSwitcherState>(
            find.byType(RecentConversationSwitcher),
          );
          final visit = tester
              .widget<RecentConversationSwitcher>(
                find.byType(RecentConversationSwitcher),
              )
              .session;
          final groupKey = visit.selected;
          final groupBots = bots;
          expect(groupKey?.group, bots.observedGroups.single.key);
          expect(groupKey?.chat, isNull);
          expect(visit.modeEnabled, isFalse);
          await tester.tap(find.byTooltip('Dictate message'));
          await _finishFrames(tester);
          expect(voiceDevice.local, isTrue);
          final recordingSwitcher = tester.widget<RecentConversationSwitcher>(
            find.byType(RecentConversationSwitcher),
          );
          expect(recordingSwitcher.gesturesEnabled, isFalse);
          expect(recordingSwitcher.nudgesEnabled, isFalse);
          await _chatGesture(tester);
          expect(visit.modeEnabled, isFalse);
          await tester.tap(find.byTooltip('Cancel recording'));
          await _finishFrames(tester);
          final field = find.byKey(
            const ValueKey('group-message-composer'),
            skipOffstage: false,
          );
          await tester.enterText(field, 'Keep this group draft');
          await tester.pump();
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          final list = tester.widget<ListView>(
            find.byKey(const ValueKey('profile-transcript')),
          );
          list.controller!.jumpTo(0);
          await tester.pump();
          final commands = List.of(botFixture.commands);
          final resumes = fixture.calls
              .where((call) => call.$2 == 'session.resume')
              .length;
          await _chatGesture(tester);
          expect(visit.modeEnabled, isTrue);
          await _capture(
            tester,
            frame,
            'group-recents-${brightness.name}-$scale',
          );
          await tester.binding.handlePopRoute();
          await _finishFrames(tester);
          await tester.showKeyboard(field);
          tester.view.viewInsets = const FakeViewPadding(bottom: 200);
          await tester.pump();
          final composerFocus = tester.widget<TextField>(field).focusNode!;
          expect(composerFocus.hasFocus, isTrue);
          await _expectArrivalWhileTyping(
            tester,
            composer: field,
            activity: activity,
            target: visit.entries.firstWhere((e) => e.key != groupKey).key,
            sequence: 1,
            frame: frame,
            captureName: 'group-typing-arrival-${brightness.name}-$scale',
          );
          final viewport = tester.getRect(
            find.byKey(const ValueKey('profile-transcript')),
          );
          final visibleMessages =
              [
                  for (final element in find.byType(ProfileMessage).evaluate())
                    (
                      message:
                          (element.widget as ProfileMessage).message.copyText,
                      rect: tester.getRect(
                        find.byElementPredicate(
                          (candidate) => candidate == element,
                        ),
                      ),
                    ),
                ].where((row) => row.rect.overlaps(viewport)).toList()
                ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
          final readingMessage = visibleMessages.first.message;
          final readingRect = visibleMessages.first.rect;
          final readingFraction =
              ((viewport.top - readingRect.top) / readingRect.height).clamp(
                0.0,
                1.0,
              );
          final readingAlignment =
              ((readingRect.top - viewport.top) / viewport.height).clamp(
                0.0,
                1.0,
              );
          await _chatGesture(tester);
          expect(composerFocus.hasFocus, isFalse);
          tester.view.viewInsets = FakeViewPadding.zero;
          await _finishFrames(tester);
          expect(visit.modeEnabled, isTrue);
          expect(visit.selected, groupKey);
          expect(botFixture.commands, commands);
          expect(
            fixture.calls.where((call) => call.$2 == 'session.resume'),
            hasLength(resumes),
          );
          await _capture(
            tester,
            frame,
            'group-recents-keyboard-${brightness.name}-$scale',
          );
          // A hidden discussion cannot clear a fresh reply's device read receipt.
          final room = groupBots.observedGroups.single;
          final receipt = groupBots.groupReads.sequence(room);
          botFixture.events.add({
            'room_id': 'room-1',
            'seq': 9,
            'kind': 'message.member',
            'created_at': fixture.now,
            'actor': {'kind': 'member', 'id': 'atlas'},
            'payload': {'text': 'A reply received while viewing cards'},
          });
          await groupBots.refresh();
          await _finishFrames(tester);
          expect(groupBots.groupReads.sequence(room), receipt);
          // Simulate the retained keyboard returning with the conversation so
          // the reading geometry is compared at equal viewport dimensions.
          tester.view.viewInsets = const FakeViewPadding(bottom: 200);
          await switcherState.selectAdjacent(0);
          await _finishFrames(tester);
          expect(composerFocus.hasFocus, isTrue);
          expect(find.byType(BotGroupScreen), findsOneWidget);
          // Restoring around a saved row changes the scroll origin. The same
          // message must remain visible after a new reply arrives while away.
          final restoredMessage = find.byWidgetPredicate(
            (widget) =>
                widget is ProfileMessage &&
                widget.message.copyText == readingMessage,
          );
          expect(restoredMessage, findsOneWidget);
          final restoredRect = tester.getRect(restoredMessage);
          final restoredViewport = tester.getRect(
            find.byKey(const ValueKey('profile-transcript')),
          );
          expect(
            restoredRect.top,
            closeTo(
              restoredViewport.top +
                  readingAlignment * restoredViewport.height -
                  readingFraction * restoredRect.height,
              3,
            ),
          );
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Keep this group draft',
          );
          FocusManager.instance.primaryFocus?.unfocus();
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pump();
          await _chatGesture(tester, pinch: false);
          expect(visit.modeEnabled, isTrue);
          expect(find.byType(ProfileTranscript), findsOneWidget);
          expect(find.byType(BotGroupScreen), findsNothing);
          final chatSwitcher = tester.state<RecentConversationSwitcherState>(
            find.byType(RecentConversationSwitcher),
          );
          final chatVisit = tester
              .widget<RecentConversationSwitcher>(
                find.byType(RecentConversationSwitcher),
              )
              .session;
          final groupIndex = chatVisit.entries.indexWhere(
            (entry) => entry.key == groupKey,
          );
          final groupLandingRead = Completer<void>();
          botFixture.readHook = (_, method, _) async {
            if (method == 'groups.state') await groupLandingRead.future;
            return null;
          };
          unawaited(
            chatSwitcher.selectAdjacent(groupIndex - chatVisit.selectedIndex),
          );
          await _finishFrames(tester);
          expect(find.byType(BotGroupScreen), findsOneWidget);
          final switchedViewport = find.byKey(
            const ValueKey('profile-transcript'),
          );
          final switchedBounds = tester.getRect(switchedViewport);
          expect(find.bySemanticsLabel('Loading history'), findsNothing);
          await _capture(
            tester,
            frame,
            'group-switched-loading-${brightness.name}-$scale',
          );
          groupLandingRead.complete();
          for (var frame = 0; frame < 24; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              tester.getRect(switchedViewport),
              switchedBounds,
              reason:
                  'Switching from an ordinary chat to a group keeps its viewport fixed.',
            );
          }
          expect(find.byType(StudioLoading), findsNothing);
          await _capture(
            tester,
            frame,
            'group-switched-ready-${brightness.name}-$scale',
          );
          await tester.binding.handlePopRoute();
          await _finishFrames(tester);
          expect(find.byType(ProfileTranscript), findsNothing);
          expect(
            find.byType(BotGroupScreen, skipOffstage: false),
            findsNothing,
          );
          expect(controller.current?.chat, isNull);
          expect(find.text('Recents'), findsOneWidget);
          expect(find.byKey(const ValueKey('bots-search')), findsNothing);
          expect(visit.active, isFalse);
          expect(botFixture.commands, commands);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final entry in ['Chats', 'Bots', 'Groups', 'Recents group']) {
    for (final cancelPinch in [false, true]) {
      testWidgets(
        'direct $entry entry preserves Back destination${cancelPinch ? ' after a canceled pinch' : ''}',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final fixture = _ScreenFixture();
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
            gatewayFactory: fixture.gateway,
          );
          addTearDown(controller.dispose);
          addTearDown(appPreferences.dispose);
          await controller.initialize();
          if (entry == 'Chats') {
            await controller.openSession(
              ProfileSessionKey(controller.current!.scope, 'chat-0'),
            );
          }
          final bots = BotsFixture();
          bots.profiles
            ..clear()
            ..add(BotsFixture.profile('personal', 'Atlas'));
          bots.profiles.single['canonical_session']['id'] = 'chat-0';
          bots.events.add({
            'room_id': 'room-1',
            'seq': 1,
            'kind': 'message.member',
            'created_at': fixture.now + 1,
            'actor': {'kind': 'member', 'id': 'atlas'},
            'payload': {'text': 'Recent group reply'},
          });
          final activity = ValueNotifier<ChatNoticeActivity?>(null);
          addTearDown(activity.dispose);
          tester.view.physicalSize = const Size(390, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(Brightness.dark),
              builder: (_, child) =>
                  ChatNoticeActivityScope(activity: activity, child: child!),
              home: ProfileWorkspaceScreen(
                controller: controller,
                initialDestination: entry == 'Chats'
                    ? AppDestination.chats
                    : entry == 'Recents group'
                    ? AppDestination.activity
                    : AppDestination.bots,
                createBotsSession: () =>
                    BotsSession((_) async => [bots.repository]),
              ),
            ),
          );
          await _finishFrames(tester);
          if (entry == 'Bots') {
            await tester.tap(find.text('Atlas').first);
          } else if (entry == 'Groups') {
            await tester.tap(find.text('Groups').first);
            await _finishFrames(tester);
            await tester.enterText(
              find.byKey(const ValueKey('bots-search')),
              'Research',
            );
            await _finishFrames(tester);
            await tester.tap(find.text('Research team').first);
          } else if (entry == 'Recents group') {
            await tester.tap(find.text('Research team').first);
          }
          await _finishFrames(tester);
          final visit = tester
              .widget<RecentConversationSwitcher>(
                find.byType(RecentConversationSwitcher),
              )
              .session;
          expect(visit.modeEnabled, entry == 'Recents group');
          if (cancelPinch) {
            await _chatGesture(tester, returnToStart: true);
            expect(visit.modeEnabled, entry == 'Recents group');
          }
          await tester.binding.handlePopRoute();
          await _finishFrames(tester);
          expect(find.byType(ProfileTranscript), findsNothing);
          expect(
            find.byType(BotGroupScreen, skipOffstage: false),
            findsNothing,
          );
          expect(controller.current?.chat, isNull);
          if (entry == 'Bots' || entry == 'Groups') {
            final search = tester.widget<TextField>(
              find.byKey(const ValueKey('bots-search')),
            );
            expect(
              search.decoration!.hintText,
              entry == 'Groups' ? 'Search groups' : 'Search bots',
            );
            expect(
              search.controller!.text,
              entry == 'Groups' ? 'Research' : '',
            );
          } else {
            expect(
              find.text(entry == 'Chats' ? 'Chats' : 'Recents'),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final botEntry in [false, true]) {
    testWidgets(
      'pinch entry from ${botEntry ? 'Bots' : 'an empty new chat'} changes Back destination to Recents',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        final fixture = botEntry ? _ScreenFixture() : _EmptyScreenFixture();
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
          gatewayFactory: fixture.gateway,
        );
        addTearDown(controller.dispose);
        addTearDown(appPreferences.dispose);
        await controller.initialize();
        final bots = BotsFixture();
        bots.profiles
          ..clear()
          ..add(BotsFixture.profile('personal', 'Atlas'));
        bots.profiles.single['canonical_session']['id'] = 'chat-0';
        final activity = ValueNotifier<ChatNoticeActivity?>(null);
        addTearDown(activity.dispose);
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            builder: (_, child) =>
                ChatNoticeActivityScope(activity: activity, child: child!),
            home: ProfileWorkspaceScreen(
              controller: controller,
              initialQuickChat: !botEntry,
              initialDestination: botEntry
                  ? AppDestination.bots
                  : AppDestination.chats,
              initialBotSession: botEntry
                  ? ProfileSessionKey(controller.current!.scope, 'chat-0')
                  : null,
              createBotsSession: () =>
                  BotsSession((_) async => [bots.repository]),
            ),
          ),
        );
        await _finishFrames(tester);
        final chat = controller.current!.chat!;
        final visit = tester
            .widget<RecentConversationSwitcher>(
              find.byType(RecentConversationSwitcher),
            )
            .session;
        expect(visit.modeEnabled, isFalse);
        if (botEntry) {
          await _chatGesture(tester);
        } else {
          final area = tester.getRect(find.byType(ProfileTranscript));
          await _twoContacts(
            tester,
            Offset(75, area.center.dy),
            Offset(285, area.center.dy),
            Offset(145, area.center.dy),
            Offset(215, area.center.dy),
          );
        }
        expect(visit.modeEnabled, isTrue);
        expect(visit.selected?.chat, chat.key);
        if (!botEntry) {
          expect(find.text('No other recent chats.'), findsOneWidget);
          expect(controller.recentChats(), isEmpty);
        }
        await tester.binding.handlePopRoute();
        await _finishFrames(tester);
        expect(controller.current!.chat, same(chat));
        await tester.binding.handlePopRoute();
        await _finishFrames(tester);
        expect(visit.active, isFalse);
        expect(controller.current!.chat, isNull);
        expect(find.text('Recents'), findsOneWidget);
        expect(find.byKey(const ValueKey('bots-search')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'ordinary chat pinch activates Recents and preserves draft ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final fixture = _ScreenFixture();
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
            connectionIdentity: 'entry-ui',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: fixture.gateway,
          );
          addTearDown(controller.dispose);
          addTearDown(appPreferences.dispose);
          await controller.initialize();
          await controller.openSession(
            ProfileSessionKey(controller.current!.scope, 'chat-0'),
          );
          final botFixture = BotsFixture();
          botFixture.events.add({
            'room_id': 'room-1',
            'seq': 1,
            'kind': 'message.member',
            'created_at': fixture.now - 30,
            'actor': {'kind': 'member', 'id': 'atlas'},
            'payload': {'text': 'Fresh group answer'},
          });
          final original = controller.current!.chat!;
          await controller.updateDraft(original, 'Keep this draft');
          final activity = ValueNotifier<ChatNoticeActivity?>(null);
          addTearDown(activity.dispose);
          final frame = GlobalKey();
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: ChatNoticeActivityScope(
                  activity: activity,
                  child: RepaintBoundary(key: frame, child: child!),
                ),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () =>
                    BotsSession((_) async => [botFixture.repository]),
              ),
            ),
          );
          await _finishFrames(tester);
          final visit = tester
              .widget<RecentConversationSwitcher>(
                find.byType(RecentConversationSwitcher),
              )
              .session;
          expect(visit.modeEnabled, isFalse);
          expect(controller.recentsLoaded, isFalse);
          final resumes = fixture.calls
              .where((call) => call.$2 == 'session.resume')
              .length;
          final hold = Completer<void>();
          fixture.pageDelays[('work', 0)] = hold;
          addTearDown(() {
            if (!hold.isCompleted) hold.complete();
          });
          final field = tester.widget<TextField>(
            find.widgetWithText(TextField, 'Keep this draft'),
          );
          field.controller!.selection = const TextSelection.collapsed(
            offset: 5,
          );
          await _chatGesture(tester);
          expect(visit.modeEnabled, isTrue);
          expect(find.text('Loading recent chats…'), findsNothing);
          expect(controller.current!.chat, same(original));
          expect(
            fixture.calls.where((call) => call.$2 == 'session.resume'),
            hasLength(resumes),
          );
          hold.complete();
          await _finishFrames(tester);
          expect(visit.selected?.chat, original.key);
          expect(
            visit.entries.any(
              (entry) => entry.key.chat?.workspace.profileName == 'work',
            ),
            isTrue,
          );
          expect(find.text('Swipe to browse · tap to open'), findsOneWidget);
          await _capture(
            tester,
            frame,
            'entry-workspace-${brightness.name}-$scale',
          );
          await tester.binding.handlePopRoute();
          await _finishFrames(tester);
          expect(visit.modeEnabled, isTrue);
          expect(controller.current!.chat, same(original));
          expect(
            tester
                .widget<TextField>(
                  find.widgetWithText(TextField, 'Keep this draft'),
                )
                .controller!
                .selection
                .baseOffset,
            5,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.pump();
          final other = visit.entries.last.key;
          activity.value = ChatNoticeActivity(
            key: other,
            kind: ConversationActivityKind.reply,
            identity: 'background',
            sequence: 1,
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            find.byKey(const ValueKey('recent-conversation-nudge')),
            findsNothing,
          );
          expect(visit.modeEnabled, isTrue);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            find.byKey(const ValueKey('recent-conversation-nudge')),
            findsNothing,
          );
          activity.value = ChatNoticeActivity(
            key: other,
            kind: ConversationActivityKind.reply,
            identity: 'fresh',
            sequence: 2,
          );
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find.byKey(const ValueKey('recent-conversation-nudge')),
            findsOneWidget,
          );
          if (_export) {
            await tester.pump(const Duration(milliseconds: 1400));
            await _captureCurrent(
              tester,
              frame,
              'pond-ripples-${brightness.name}-$scale',
            );
          }
          await _expectArrivalWhileTyping(
            tester,
            composer: find.widgetWithText(TextField, 'Keep this draft'),
            activity: activity,
            target: other,
            sequence: 3,
            frame: frame,
            captureName: 'chat-typing-arrival-${brightness.name}-$scale',
          );
          FocusManager.instance.primaryFocus?.unfocus();
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pump();
          await _chatGesture(tester, pinch: false);
          expect(
            find.byKey(const ValueKey('recent-conversation-nudge')),
            findsNothing,
          );
          expect(controller.current!.chat!.key, other.chat);
          await tester.binding.handlePopRoute();
          await _finishFrames(tester);
          expect(visit.active, isFalse);
          expect(controller.current!.chat, isNull);
          expect(find.text('Last 24 hours + ongoing work'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        'real Recents chat stack, drafts and Back in ${brightness.name} at $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          addTearDown(appPreferences.dispose);
          final fixture = _ScreenFixture()
            ..unreadSessions.addAll(['chat-1', 'chat-2']);
          Completer<void>? heldResume, resumeStarted;
          final reads = <String>[];
          final acknowledgedSessions = <ProfileSessionKey>[];
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
            connectionIdentity: 'recents-ui',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: (scope) {
              final base = fixture.gateway(scope);
              return ProfileGateway(
                scope: scope,
                discover: base.discover,
                get: base.read,
                ownedPatch: (path, body, canDispatch, onDispatched) async {
                  if (path != 'sessions/chat-0' ||
                      body.length != 5 ||
                      body['profile'] != scope.profileName ||
                      body['unread'] != false ||
                      body['request_id'] is! String ||
                      (body['request_id'] as String).isEmpty ||
                      body['expected_revision'] != 0 ||
                      body['expected_generation'] != 0 ||
                      !canDispatch()) {
                    throw StateError('Unexpected read acknowledgement');
                  }
                  onDispatched();
                  acknowledgedSessions.add(ProfileSessionKey(scope, 'chat-0'));
                  return {'ok': true};
                },
                rpc: (method, params) async {
                  if (method == 'session.resume' && heldResume != null) {
                    final delay = heldResume!;
                    heldResume = null;
                    resumeStarted!.complete();
                    await delay.future;
                  }
                  return base.call(method, params);
                },
              );
            },
            onNotificationRead: (_, identity) async {
              reads.add(identity);
            },
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          await controller.refreshRecents();
          final activity = ValueNotifier<ChatNoticeActivity?>(null);
          addTearDown(activity.dispose);
          final frame = GlobalKey();
          tester.view.physicalSize = Size(scale == 1 ? 360 : 320, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: ChatNoticeActivityScope(
                  activity: activity,
                  child: RepaintBoundary(key: frame, child: child!),
                ),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                initialDestination: AppDestination.activity,
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
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.text('Review the Android gestures').first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Review the Android gestures').first);
          await _finishFrames(tester);
          final first = controller.current!.chat!;
          await controller.updateDraft(first, 'Return to this draft');
          await tester.pumpAndSettle();
          final field = find.widgetWithText(TextField, 'Return to this draft');
          final editing = tester.widget<TextField>(field).controller!;
          editing.selection = const TextSelection.collapsed(offset: 6);
          if (brightness == Brightness.dark && scale == 1) {
            final visit = tester
                .widget<RecentConversationSwitcher>(
                  find.byType(RecentConversationSwitcher),
                )
                .session;
            final other = visit.entries.firstWhere(
              (entry) => entry.key.chat!.workspace != first.key.workspace,
            );
            fixture.failedResume = other.key.chat!;
            expect(await visit.select(other.key), isTrue);
            await _finishFrames(tester);
            expect(controller.current!.chat!.key, other.key.chat);
            expect(controller.current!.chat!.reading.messages, isNotEmpty);
            expect(controller.current!.chat!.runtime.openingError, isNotNull);
            expect(
              first.composer.observation.displayedText,
              'Return to this draft',
            );
            fixture.failedResume = null;
            expect(
              await visit.select(RecentConversationKey.chat(first.key)),
              isTrue,
            );
            await _finishFrames(tester);
            expect(controller.current!.chat!.key, first.key);
          }
          final resumes = fixture.calls
              .where((call) => call.$2 == 'session.resume')
              .length;
          await _capture(tester, frame, 'normal-${brightness.name}-$scale');
          await tester.tap(find.byTooltip('Chat actions'));
          await tester.pumpAndSettle();
          for (final label in [
            'Previous recent conversation',
            'Next recent conversation',
            'Choose recent conversation',
          ]) {
            expect(find.text(label), findsNothing);
          }
          expect(find.text('Outputs'), findsOneWidget);
          expect(find.text('Refresh workspace'), findsOneWidget);
          await _captureCurrent(
            tester,
            frame,
            'menu-${brightness.name}-$scale',
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await _chatGesture(tester);
          expect(find.text('Swipe to browse · tap to open'), findsOneWidget);
          final composerFocus = tester
              .widget<TextField>(
                find.widgetWithText(
                  TextField,
                  'Return to this draft',
                  skipOffstage: false,
                ),
              )
              .focusNode!;
          composerFocus.requestFocus();
          await tester.pump();
          expect(
            composerFocus.hasFocus,
            isFalse,
            reason: 'The hidden chat cannot regain composer focus',
          );
          expect(
            fixture.calls.where((call) => call.$2 == 'session.resume'),
            hasLength(resumes),
          );
          await _capture(tester, frame, 'stack-${brightness.name}-$scale');
          if (_export) {
            await tester.dragFrom(
              Offset(tester.view.physicalSize.width * .25, 400),
              Offset(tester.view.physicalSize.width * .6, 0),
            );
            await _finishFrames(tester);
            expect(
              find.byWidgetPredicate(
                (widget) =>
                    widget is DecoratedBox &&
                    widget.position == DecorationPosition.foreground &&
                    widget.key.toString().contains('unread-tint'),
              ),
              findsWidgets,
            );
            await _capture(
              tester,
              frame,
              'unread-stack-${brightness.name}-$scale',
            );
            await tester.dragFrom(
              Offset(tester.view.physicalSize.width * .75, 400),
              Offset(-tester.view.physicalSize.width * .6, 0),
            );
            await _finishFrames(tester);
          }
          expect(controller.visible, isFalse);
          if (brightness == Brightness.dark && scale == 1) {
            first.reading.recordNotificationResult(
              const NotificationFocus('answer', '3'),
            );
            await controller.refreshHistory(first);
            await _finishFrames(tester);
            expect(
              reads,
              isEmpty,
              reason:
                  'A card or hidden normal transcript cannot acknowledge a read',
            );
          }
          await tester.dragFrom(
            Offset(tester.view.physicalSize.width * .75, 400),
            Offset(-tester.view.physicalSize.width * .6, 0),
          );
          await _finishFrames(tester);
          expect(controller.current!.chat!.key, first.key);
          expect(
            fixture.calls.where((call) => call.$2 == 'session.resume'),
            hasLength(resumes),
          );
          await tester.tapAt(Offset(tester.view.physicalSize.width / 2, 400));
          await _finishFrames(tester);
          expect(controller.current!.chat!.key, isNot(first.key));
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          final refreshDelay = Completer<void>();
          heldResume = refreshDelay;
          resumeStarted = Completer<void>();
          addTearDown(() {
            if (!refreshDelay.isCompleted) refreshDelay.complete();
          });
          await _chatGesture(tester, pinch: false);
          for (var frame = 0; frame < 12; frame++) {
            await tester.pump(const Duration(milliseconds: 120));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(resumeStarted.isCompleted, isTrue);
          expect(first.refreshingConversation, isTrue);
          final refreshWing = find.descendant(
            of: find.byKey(const ValueKey('studio-loading-slot')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is StudioLoading &&
                  widget.label == 'Refreshing conversation',
            ),
          );
          expect(refreshWing, findsOneWidget);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(
            tester
                .getRect(refreshWing)
                .overlaps(
                  Offset.zero &
                      (tester.view.physicalSize / tester.view.devicePixelRatio),
                ),
            isTrue,
            reason:
                'The pending user action keeps visible header feedback over cached reading',
          );
          expect(
            find.widgetWithText(TextField, 'Return to this draft'),
            findsOneWidget,
          );
          expect(
            controller.visible,
            isTrue,
            reason: 'Cached reading must be revealed while resume is held',
          );
          await _captureCurrent(
            tester,
            frame,
            'refreshing-${brightness.name}-$scale',
          );
          refreshDelay.complete();
          await _finishFrames(tester);
          expect(first.refreshingConversation, isFalse);
          expect(find.byType(StudioLoading), findsNothing);
          expect(controller.current!.chat!.key, first.key);
          final restored = tester
              .widget<TextField>(
                find.widgetWithText(TextField, 'Return to this draft'),
              )
              .controller!;
          expect(restored.selection.baseOffset, 6);
          expect(controller.visible, isTrue);
          if (brightness == Brightness.dark && scale == 1) {
            expect(
              reads,
              isEmpty,
              reason: 'Revealing cached reading does not read the answer',
            );
            expect(acknowledgedSessions, isEmpty);
            // Return restores the reading point, not the newest edge. Read
            // through the reply before expecting its acknowledgement.
            for (var pass = 0; pass < 10 && reads.isEmpty; pass++) {
              await tester.drag(
                find.byKey(const ValueKey('profile-transcript')),
                const Offset(0, -300),
              );
              await _finishFrames(tester);
            }
            expect(reads, ['answer:3']);
            expect(acknowledgedSessions, [first.key]);
            expect(first.markReadFailed, isFalse);
          }
          await _chatGesture(tester);
          await tester.binding.handlePopRoute();
          await _finishFrames(tester);
          expect(find.text('Swipe to browse · tap to open'), findsNothing);
          expect(controller.current!.chat!.key, first.key);
          if (brightness == Brightness.dark && scale == 1) {
            await _chatGesture(tester);
            expect(controller.visible, isFalse);
            tester
                .state<ProfileWorkspaceScreenState>(
                  find.byType(ProfileWorkspaceScreen),
                )
                .showNotificationChat();
            await _finishFrames(tester);
            expect(find.text('Swipe to browse · tap to open'), findsNothing);
            expect(controller.visible, isTrue);
          }
          expect(find.byTooltip('Back to Recents'), findsNothing);
          expect(find.byTooltip('Open navigation menu'), findsOneWidget);
          await tester.binding.handlePopRoute();
          await _finishFrames(tester);
          expect(
            find.text(
              brightness == Brightness.dark && scale == 1 ? 'Chats' : 'Recents',
            ),
            findsOneWidget,
          );
          expect(controller.current!.chat, isNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
  }
}
