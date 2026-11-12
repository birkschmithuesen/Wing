import 'package:wing/core/widgets/studio_error.dart';
import 'package:wing/core/widgets/bot_group_conversation.dart';
import 'package:wing/core/widgets/conversation_page.dart';
import 'package:wing/core/widgets/gateway_approval_panel.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/services/bots_preferences.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/profile_colors.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/workspace_picker.dart';
import 'package:wing/core/services/recent_conversation_snapshots.dart';
import 'package:wing/core/models/voice_processing_settings.dart';
import 'dart:async';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/oklch_color.dart';
import 'package:wing/core/widgets/bot_avatar.dart';
import 'package:wing/core/widgets/bot_group_picture.dart';
import 'package:wing/core/widgets/bot_group_identity.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/mention_suggestions.dart';
import 'support/bots_fixture.dart';
import 'package:wing/core/widgets/conversation_activity_status.dart';
import 'package:wing/core/widgets/composer_icon_button.dart';
import 'helpers/pump_markdown_widget.dart';
import 'package:wing/core/widgets/voice_input_activity.dart';
import 'package:wing/core/widgets/recent_conversations/conversation_route_scope.dart';
import 'support/voice_fixture.dart';
import 'support/administration_fixture.dart';

const _capture = bool.fromEnvironment('CAPTURE_BOT_GROUPS');

Map<String, dynamic> _event(int seq, String kind, String actor, String text) =>
    {
      'room_id': 'room-1',
      'seq': seq,
      'kind': kind,
      'actor': {
        'kind': kind == 'message.user' ? 'user' : 'member',
        'id': actor,
        'profile': actor,
      },
      'payload': {'text': text},
      'created_at': 1791756000.0 + seq * 60,
    };

Future<void> _settleGroupMarkdown(WidgetTester tester) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 300));
    final pending = tester
        .stateList<BackgroundMarkdownContentState>(
          find.byType(BackgroundMarkdownContent, skipOffstage: false),
        )
        .any((state) => state.pending);
    if (!pending) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('Group Markdown did not settle, including lazy-list cache children.');
}

Future<void> _render(WidgetTester tester, GlobalKey key, String name) async {
  if (!_capture) return;
  for (var pass = 0; pass < 4; pass++) {
    await _settleGroupMarkdown(tester);
  }
  final shadows = debugDisableShadows;
  debugDisableShadows = false;
  try {
    void repaint(RenderObject object) {
      object.markNeedsPaint();
      object.visitChildren(repaint);
    }

    repaint(key.currentContext!.findRenderObject()!);
    await tester.pump();
    await tester.runAsync(() async {
      final frame =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await frame.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/design-previews/bot-groups')
        ..createSync(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = shadows;
  }
}

Finder _decisionButton(String label) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == label,
);

void main() {
  setUpAll(() async {
    if (!_capture) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      WingTypography.sans: 'Roboto-Regular.ttf',
      'monospace': 'RobotoMono-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$directory/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  late BotsPreferences groupPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    groupPreferences = await BotsPreferences.load();
  });
  testWidgets('group refresh preserves semantics through popup retirement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    try {
      final fixture = BotsFixture();
      fixture.events.add(_event(1, 'message.user', 'you', 'Review the plan'));
      final group = (await fixture.repository.groupCatalog()).single;
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: BotGroupScreen(
            createSession: () => BotGroupSession(
              fixture.repository,
              group,
              reads: BotGroupReadState(),
              preferences: groupPreferences,
              groupMessages: null,
              appearances: FixedGroupAppearances(const []),
            ),
            stopVoicePlayback: () async {},
            voiceInputSettings: () => null,
          ),
        ),
      );
      await _settleGroupMarkdown(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Group options'));
      await tester.pumpAndSettle();
      final refresh = find.text('Refresh group');
      final popup = ModalRoute.of(tester.element(refresh))!;
      var retired = false;
      unawaited(popup.completed.then((_) => retired = true));
      final readGate = Completer<void>();
      var reads = 0;
      var readBeforeRetirement = false;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.state') {
          reads++;
          readBeforeRetirement |= !retired;
          await readGate.future;
        }
        return null;
      };
      fixture.pending.add({
        'kind': 'discard',
        'task_id': 'unknown',
        'member_id': 'atlas',
        'execution_generation': 9,
      });
      await tester.tap(refresh);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(retired, isFalse);
      expect(
        reads,
        0,
        reason: 'The closing popup still owns its semantics scope.',
      );
      expect(find.byTooltip('Refreshing group'), findsOneWidget);
      expect(find.byType(StudioLoading), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(retired, isTrue);
      expect(
        reads,
        1,
        reason: 'Explicit refresh joins the resumed visible read.',
      );
      expect(readBeforeRetirement, isFalse);
      expect(find.byTooltip('Refreshing group'), findsOneWidget);
      readGate.complete();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Discard unknown group attempt'), findsOneWidget);
      expect(find.byTooltip('Refreshing group'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Group options'));
      await tester.pumpAndSettle();
      final cancelledPopup = ModalRoute.of(tester.element(refresh))!;
      reads = 0;
      retired = false;
      unawaited(cancelledPopup.completed.then((_) => retired = true));
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(retired, isFalse);
      expect(reads, 0);
      await tester.pumpAndSettle();
      expect(retired, isTrue);
      expect(reads, 1, reason: 'Cancelling restores normal visible polling.');
      expect(readBeforeRetirement, isFalse);
      await tester.tap(find.byTooltip('Group options'));
      await tester.pumpAndSettle();
      reads = 0;
      await tester.tap(refresh);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(
        reads,
        0,
        reason: 'A departed screen must not start a delayed read.',
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group question history stays chronological and collapsed ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          fixture.events.addAll([
            _event(1, 'message.user', 'you', 'Review the changes.'),
            _event(2, 'message.member', 'atlas', 'I will inspect the source.'),
          ]);
          final command = "python -c '${'print("café 🦋"); ' * 80}'";
          fixture.pending.add({
            'kind': 'approval',
            'task_id': 'task-1',
            'member_id': 'atlas',
            'request_id': 'approval-1',
            'execution_generation': 1,
            'approval': {
              'command': command,
              'description': 'Inspect the source.',
              'choices': ['once', 'deny'],
            },
          });
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).first;
          late BotGroupSession session;
          final frame = GlobalKey();
          Widget route() => RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: BotGroupScreen(
                stopVoicePlayback: () async {},
                voiceInputSettings: () => null,
                createSession: () => session = BotGroupSession(
                  fixture.repository,
                  group,
                  reads: BotGroupReadState(),
                  preferences: groupPreferences,
                  groupMessages: null,
                  appearances: FixedGroupAppearances(const []),
                ),
              ),
            ),
          );
          await tester.pumpWidget(route());
          await _settleGroupMarkdown(tester);
          expect(find.text('Review command'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(ProfileTranscript),
              matching: find.byType(GatewayApprovalPanel),
            ),
            findsOneWidget,
          );
          expect(find.text('Asking a question'), findsNothing);
          expect(find.text('Waiting for your approval'), findsOneWidget);
          expect(_decisionButton('Approve for session'), findsNothing);
          expect(_decisionButton('Always approve'), findsNothing);
          expect(find.text(command), findsOneWidget);
          await _render(
            tester,
            frame,
            'question-pending-${brightness.name}-$scale',
          );
          await _settleGroupMarkdown(tester);
          expect(
            tester
                .widget<SelectableText>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is SelectableText && widget.data == command,
                  ),
                )
                .data,
            command,
          );
          await _render(
            tester,
            frame,
            'question-expanded-${brightness.name}-$scale',
          );
          await _settleGroupMarkdown(tester);
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          await tester.pump();
          await _settleGroupMarkdown(tester);
          final approve = _decisionButton('Approve once');
          final keyboardTop =
              (tester.view.physicalSize.height -
                  tester.view.viewInsets.bottom) /
              tester.view.devicePixelRatio;
          expect(
            tester.getRect(approve).bottom,
            lessThanOrEqualTo(keyboardTop),
          );
          expect(approve.hitTestable(), findsOneWidget);
          expect(
            tester.getSize(approve).shortestSide,
            greaterThanOrEqualTo(48),
          );
          await _render(
            tester,
            frame,
            'question-keyboard-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
          await _settleGroupMarkdown(tester);
          tester.view.viewInsets = FakeViewPadding.zero;
          final held = Completer<void>();
          addTearDown(() {
            if (!held.isCompleted) held.complete();
          });
          fixture.beforeCommand = () => held.future;
          fixture.commandHook = (_, method, params) async {
            if (method == 'groups.approve') throw StateError('Offline');
            return null;
          };
          await tester.tap(approve);
          await tester.pump();
          await tester.pump();
          expect(tester.widget<IconButton>(approve).onPressed, isNull);
          final header = find.byKey(const ValueKey('studio-loading-slot'));
          final progress = find.descendant(
            of: header,
            matching: find.byType(StudioLoading),
          );
          expect(progress, findsOneWidget);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(tester.getRect(progress).isEmpty, isFalse);
          expect(
            tester.getRect(header).contains(tester.getCenter(progress)),
            isTrue,
          );
          expect(find.bySemanticsLabel('Updating group work'), findsOneWidget);
          expect(find.text('Submitting decision'), findsNothing);
          await _render(
            tester,
            frame,
            'question-held-${brightness.name}-$scale',
          );
          held.complete();
          await _settleGroupMarkdown(tester);
          expect(
            session.approvalError(session.pendingApprovals.single),
            isNotNull,
          );
          expect(tester.widget<IconButton>(approve).onPressed, isNotNull);
          await _render(
            tester,
            frame,
            'question-failed-${brightness.name}-$scale',
          );
          final originalRequest = fixture.pending.single;
          fixture.pending.clear();
          fixture.events.addAll([
            _event(3, 'message.user', 'you', 'Continue with other work.'),
            _event(4, 'message.member', 'atlas', 'A later reply.'),
          ]);
          await session.refresh();
          await _settleGroupMarkdown(tester);
          fixture.pending.add(originalRequest);
          await session.refresh();
          await _settleGroupMarkdown(tester);
          expect(_decisionButton('Approve once'), findsNothing);
          expect(_decisionButton('Reject'), findsNothing);
          expect(session.pendingApprovals, isEmpty);
          await _render(
            tester,
            frame,
            'question-replayed-closed-${brightness.name}-$scale',
          );
          fixture.pending.clear();
          await session.refresh();
          await _settleGroupMarkdown(tester);
          final timeline = TranscriptTimeline.project(
            session.reading.messages,
            presentationId: session.reading.messagePresentationId,
            requestActivities: session.reading.requestActivities,
          );
          final position = timeline.sections.indexWhere((s) => s.isActivity);
          expect(timeline.sections[position - 1].messages.last.id, 2);
          expect(timeline.sections[position + 1].messages.first.id, 3);
          expect(timeline.sections[position].toolCount, 0);
          final outerActivity = find.text('Activity');
          await tester.scrollUntilVisible(
            outerActivity,
            160,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('profile-transcript')),
                  matching: find.byType(Scrollable),
                )
                .first,
            maxScrolls: 20,
          );
          await tester.ensureVisible(outerActivity);
          await _settleGroupMarkdown(tester);
          expect(find.text('Asked a question'), findsNothing);
          await _render(
            tester,
            frame,
            'question-history-collapsed-${brightness.name}-$scale',
          );
          await tester.tap(outerActivity);
          await _settleGroupMarkdown(tester);
          expect(
            find.descendant(
              of: find.byType(ProfileActivityTimeline),
              matching: find.byType(ProfileToolCall),
            ),
            findsOneWidget,
          );
          expect(_decisionButton('Approve once'), findsNothing);
          expect(_decisionButton('Reject'), findsNothing);
          final closed = find.text('Asked a question');
          await tester.scrollUntilVisible(
            closed,
            160,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('profile-transcript')),
                  matching: find.byType(Scrollable),
                )
                .first,
            maxScrolls: 20,
          );
          await _settleGroupMarkdown(tester);
          await tester.ensureVisible(closed);
          await _settleGroupMarkdown(tester);
          if (closed.hitTestable().evaluate().isEmpty) {
            await tester.drag(
              find.byKey(const ValueKey('profile-transcript')),
              const Offset(0, -320),
            );
            await _settleGroupMarkdown(tester);
          }
          expect(closed.hitTestable(), findsOneWidget);
          expect(find.byType(SourceCodeText), findsNothing);
          await _render(
            tester,
            frame,
            'question-closed-${brightness.name}-$scale',
          );
          await tester.tap(closed);
          await _settleGroupMarkdown(tester);
          expect(
            tester.widget<SourceCodeText>(find.byType(SourceCodeText)).text,
            command,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          groupPreferences = await BotsPreferences.load();
          await tester.pumpWidget(route());
          await _settleGroupMarkdown(tester);
          await tester.scrollUntilVisible(
            find.text('Activity'),
            160,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('profile-transcript')),
                  matching: find.byType(Scrollable),
                )
                .first,
            maxScrolls: 20,
          );
          await _settleGroupMarkdown(tester);
          expect(find.byType(SourceCodeText), findsNothing);
          expect(find.text('Asked a question'), findsNothing);
          expect(session.reading.messages.map((row) => row['id']), [
            1,
            2,
            3,
            4,
          ]);
          final restored = TranscriptTimeline.project(
            session.reading.messages,
            presentationId: session.reading.messagePresentationId,
            requestActivities: session.reading.requestActivities,
          );
          expect(restored.sections.where((s) => s.isActivity), hasLength(1));
          expect(_decisionButton('Approve once'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group mention picker preserves multiline composer ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).single;
          final appearances = await fixture.repository.bots();
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
                child: BotGroupScreen(
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () => null,
                  createSession: () => BotGroupSession(
                    fixture.repository,
                    group,
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                    groupMessages: null,
                    appearances: FixedGroupAppearances(appearances),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final input = find.byKey(const ValueKey('group-message-composer'));
          final composer = find.byKey(const ValueKey('conversation-composer'));
          const draft =
              'Keep working until done.\nAfter these steps we work on:\n'
              '1. Daily ingestion\n@Atlas + ';
          await tester.enterText(input, draft);
          await tester.pumpAndSettle();
          final before = tester.getRect(composer);
          final inputBefore = tester.getRect(input);
          final controller = tester.widget<TextField>(input).controller!;
          final focus = tester.widget<TextField>(input).focusNode!;
          expect(controller.text, draft);
          await _render(
            tester,
            frame,
            'mention-draft-${brightness.name}-$scale',
          );

          void expectStableComposer() {
            expect(tester.getRect(composer), before);
            expect(tester.getRect(input), inputBefore);
            expect(focus.hasFocus, isTrue);
            expect(tester.takeException(), isNull);
          }

          final value = TextEditingValue(
            text: '$draft@',
            selection: TextSelection.collapsed(offset: draft.length + 1),
            composing: TextRange(start: draft.length, end: draft.length + 1),
          );
          tester.testTextInput.updateEditingValue(value);
          await tester.pump();
          expect(find.byType(MentionSuggestions), findsOneWidget);
          expect(controller.value, value);
          expectStableComposer();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expectStableComposer();
          await _render(
            tester,
            frame,
            'mention-open-${brightness.name}-$scale',
          );
          await tester.tap(find.byTooltip('Close references'));
          await tester.pumpAndSettle();
          expectStableComposer();
          expect(controller.value, value);

          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: '$draft@Mi',
              selection: TextSelection.collapsed(offset: draft.length + 3),
              composing: TextRange(start: draft.length, end: draft.length + 3),
            ),
          );
          await tester.pump();
          expectStableComposer();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expectStableComposer();
          await tester.tap(
            find
                .descendant(
                  of: find.byType(MentionSuggestions),
                  matching: find.text('Mira'),
                )
                .hitTestable(),
          );
          await tester.pumpAndSettle();
          expect(controller.text, '$draft@Mira ');
          expect(controller.value.composing, TextRange.empty);
          expectStableComposer();
          await _render(
            tester,
            frame,
            'mention-selected-${brightness.name}-$scale',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group pass bubbles identify the member and retain chronology ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          Map<String, dynamic> settled(int seq, String member, bool passed) => {
            ..._event(seq, 'turn.settled', 'gateway-1', ''),
            'actor': {'kind': 'gateway', 'id': 'gateway-1'},
            'payload': {
              'member_id': member,
              'passed': passed,
              'message_event_id': passed ? null : 'fixture-3',
            },
          };
          fixture.events.addAll([
            _event(1, 'message.user', 'you', 'Review the plan.'),
            settled(2, 'atlas', true),
            _event(3, 'message.member', 'mira', 'The plan is ready.'),
            settled(4, 'mira', false),
          ]);
          final cache = RecentGroupMessages();
          addTearDown(cache.dispose);
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: cache,
          )).single;
          final appearances = await fixture.repository.bots();
          final frame = GlobalKey();
          late BotGroupSession session;
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: frame,
                child: BotGroupScreen(
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () => null,
                  createSession: () => session = BotGroupSession(
                    fixture.repository,
                    group,
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                    groupMessages: cache,
                    appearances: FixedGroupAppearances(appearances),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(ProfileTranscript), findsOneWidget);
          await _settleGroupMarkdown(tester);
          final pass = find.byKey(const ValueKey(('group-message', 2)));
          expect(pass, findsOneWidget);
          expect(
            find.descendant(of: pass, matching: find.text('Atlas')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: pass, matching: find.text('Passed')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: pass, matching: find.byType(BotAvatar)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: pass, matching: find.byType(Tooltip)),
            findsWidgets,
          );
          expect(
            find.descendant(of: pass, matching: find.byTooltip('Copy message')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey(('group-message', 4))),
            findsNothing,
          );
          final messages = tester
              .widgetList<ProfileMessage>(find.byType(ProfileMessage))
              .map((widget) => widget.message)
              .toList();
          expect(messages.map((message) => message.id), [
            'room-1:3',
            'room-1:2',
            'room-1:1',
          ]);
          expect(messages[1].timestamp, session.events[1].timestamp);
          expect(messages[1].copyText, isEmpty);
          expect(
            tester.getTopLeft(pass).dy,
            lessThan(
              tester
                  .getTopLeft(find.byKey(const ValueKey(('group-message', 3))))
                  .dy,
            ),
          );
          expect(tester.takeException(), isNull);
          await _render(tester, frame, 'pass-${brightness.name}-$scale');

          fixture.events.add(settled(5, 'mira', true));
          await session.refresh();
          await tester.pumpAndSettle();
          final latestPass = find.byKey(const ValueKey(('group-message', 5)));
          expect(
            find.descendant(of: latestPass, matching: find.text('Mira')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: latestPass, matching: find.text('Passed')),
            findsOneWidget,
          );
          await session.refresh();
          await tester.pumpAndSettle();
          expect(latestPass, findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets(
        'consecutive bot avatars clear the previous footer ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          fixture.events.addAll([
            _event(1, 'message.user', 'you', 'Check the sources.'),
            _event(2, 'message.member', 'atlas', 'Sources checked.'),
            _event(3, 'message.member', 'mira', 'Review complete.'),
          ]);
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).first;
          final appearances = await fixture.repository.bots();
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
                child: BotGroupScreen(
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () =>
                      const LocalVoiceInputSettings(language: ''),
                  createSession: () => BotGroupSession(
                    fixture.repository,
                    group,
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                    groupMessages: null,
                    appearances: FixedGroupAppearances(appearances),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _settleGroupMarkdown(tester);
          for (final (previousId, nextId, kind) in [
            ('room-1:1', 'room-1:2', 'user-message-bubble'),
            ('room-1:2', 'room-1:3', 'bot-message-bubble'),
          ]) {
            final previous = tester.getRect(
              find.byKey(
                ValueKey<(String, Object?)>((kind, previousId)),
                skipOffstage: false,
              ),
            );
            final next = tester.getRect(
              find.byKey(
                ValueKey<(String, Object?)>(('bot-message-bubble', nextId)),
                skipOffstage: false,
              ),
            );
            final avatar = tester.getRect(
              find.byKey(
                ValueKey<(String, Object?)>((
                  'bot-message-avatar-frame',
                  nextId,
                )),
                skipOffstage: false,
              ),
            );
            expect(next.top, greaterThanOrEqualTo(previous.bottom));
            expect(
              avatar.top,
              greaterThanOrEqualTo(previous.bottom),
              reason:
                  'The avatar surround must clear the preceding timestamp/copy row.',
            );
          }
          expect(tester.takeException(), isNull);
          await _render(
            tester,
            frame,
            'consecutive-bots-${brightness.name}-$scale',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('group message draft survives leaving and reopening', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final fixture = BotsFixture();
    var roster = BotsSession((_) async => [fixture.repository]);
    await roster.refresh();
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: BotGroupScreen(
            createSession: () => roster.openGroup(roster.state.groups.single),
            voiceInputSettings: () =>
                const LocalVoiceInputSettings(language: ''),
            stopVoicePlayback: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open();
    const draft = '  Please compare these approaches.\nKeep the detail.  ';
    final input = find.byKey(const ValueKey('group-message-composer'));
    await tester.enterText(input, draft);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    roster.dispose();
    SharedPreferences.resetStatic();
    roster = BotsSession((_) async => [fixture.repository]);
    await roster.refresh();
    await open();
    expect(tester.widget<TextField>(input).controller!.text, draft);
    expect(fixture.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
    roster.dispose();
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group microphone shares the normal composer field ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).single;
          final frame = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: BotGroupScreen(
                  voiceInputSettings: () =>
                      const LocalVoiceInputSettings(language: ''),
                  stopVoicePlayback: () async {},
                  createSession: () => BotGroupSession(
                    fixture.repository,
                    group,
                    groupMessages: null,
                    appearances: FixedGroupAppearances(const []),
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final input = find.byKey(const ValueKey('group-message-composer'));
          final microphone = find.byTooltip('Dictate message');
          void expectComposerActions(String label) {
            final mic = tester.getRect(microphone);
            final action = tester.getRect(find.byTooltip(label));
            final field = tester.getRect(input);
            expect(field.contains(mic.center), isTrue);
            expect(mic.bottom, lessThanOrEqualTo(action.top));
            expect(microphone.hitTestable(), findsOneWidget);
            expect(find.byTooltip(label).hitTestable(), findsOneWidget);
            expect(mic.width, greaterThanOrEqualTo(48));
            expect(mic.height, greaterThanOrEqualTo(48));
            expect(tester.takeException(), isNull);
          }

          expectComposerActions('Send group message');
          await tester.enterText(input, 'One line');
          await tester.pumpAndSettle();
          expectComposerActions('Send group message');
          await tester.enterText(
            input,
            'Anything else is wrong and you must stop it immediately.\n\n'
            'I need you guys to refocus your plans on achieving this!!!!!',
          );
          await tester.pumpAndSettle();
          expectComposerActions('Send group message');
          await _render(tester, frame, 'microphone-${brightness.name}-$scale');
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          await tester.pumpAndSettle();
          expectComposerActions('Send group message');
          await _render(
            tester,
            frame,
            'microphone-keyboard-${brightness.name}-$scale',
          );
          fixture.sendLost = true;
          await tester.tap(find.byTooltip('Send group message'));
          await tester.pumpAndSettle();
          expectComposerActions('Retry same message');
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final continuing in [false, true]) {
        testWidgets(
          'group ${continuing ? 'continues' : 'menu stops'} deferred work without active flags ${brightness.name} $scale',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final fixture = BotsFixture();
            fixture.events.add(
              _event(1, 'message.member', 'atlas', 'Saved group reply'),
            );
            fixture.readHook = (profile, method, params) async {
              if (method != 'groups.state') return null;
              return {
                'room': fixture.room,
                'driver_status': {
                  'working': false,
                  'blocked': false,
                  'pending_actions': fixture.pending,
                },
              };
            };
            final group = (await readFixtureGroups(
              fixture.repository,
              groupMessages: null,
            )).first;
            final stopGate = Completer<void>();
            fixture.commandHook = (profile, method, params) async {
              if (method != 'groups.${continuing ? 'retry' : 'stop'}') {
                return null;
              }
              await stopGate.future;
              fixture.pending.clear();
              if (!continuing) {
                fixture.events.add({
                  ..._event(2, 'room.stop_requested', 'gateway-1', ''),
                  'payload': {'cancel_id': params['cancel_id']},
                });
              }
              return continuing
                  ? {
                      'retried': true,
                      'task': {'room_id': group.id, 'task_id': 'stranded-task'},
                    }
                  : {'cancelled': 1};
            };
            final frame = GlobalKey();
            late BotGroupSession session;
            await tester.pumpWidget(
              RepaintBoundary(
                key: frame,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: wingTheme(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: BotGroupScreen(
                    onEdit: (_) async => null,
                    stopVoicePlayback: () async {},
                    voiceInputSettings: () =>
                        const LocalVoiceInputSettings(language: ''),
                    createSession: () => session = BotGroupSession(
                      fixture.repository,
                      group,
                      reads: BotGroupReadState(),
                      preferences: groupPreferences,
                      groupMessages: null,
                      appearances: FixedGroupAppearances(const []),
                    ),
                  ),
                ),
              ),
            );
            await _settleGroupMarkdown(tester);
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Group options'));
            await tester.pumpAndSettle();
            expect(find.text('Stop group work'), findsNothing);
            await tester.tapAt(const Offset(20, 500));
            await tester.pumpAndSettle();
            fixture.pending.add({
              'kind': 'retry',
              'task_id': 'stranded-task',
              'member_id': 'atlas',
              'execution_generation': 4,
            });
            await session.refresh();
            await tester.pumpAndSettle();
            expect(
              find.widgetWithText(StudioError, 'Atlas could not finish.'),
              findsOneWidget,
            );
            expect(find.byTooltip('Stop group work'), findsNothing);
            final input = find.byType(TextField);
            await tester.enterText(input, 'Keep this draft');
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Group options'));
            await tester.pumpAndSettle();
            final stop = find.text('Stop group work');
            expect(stop, findsOneWidget);
            final stopRect = tester.getRect(stop);
            expect(stopRect.left, greaterThanOrEqualTo(0));
            expect(
              stopRect.right,
              lessThanOrEqualTo(tester.view.physicalSize.width),
            );
            expect(
              stopRect.bottom,
              lessThanOrEqualTo(tester.view.physicalSize.height),
            );
            if (continuing) {
              await tester.tapAt(const Offset(20, 500));
              await tester.pumpAndSettle();
              final resume = find.byTooltip('Retry group attempt');
              expect(resume, findsOneWidget);
              final resumeRect = tester.getRect(resume);
              expect(
                resumeRect.bottom,
                lessThanOrEqualTo(tester.view.physicalSize.height),
              );
              await _render(
                tester,
                frame,
                'deferred-continue-${brightness.name}-$scale',
              );
              await tester.tap(resume);
              expect(find.byType(AlertDialog), findsNothing);
            } else {
              await _render(
                tester,
                frame,
                'deferred-stop-menu-${brightness.name}-$scale',
              );
              await tester.tap(stop);
            }
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(session.acting, isTrue);
            expect(find.text('Updating group work…'), findsNothing);
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(session.canStopGroupWork, isFalse);
            final calls = fixture.commands
                .where(
                  (call) =>
                      call.$2 == 'groups.${continuing ? 'retry' : 'stop'}',
                )
                .toList();
            expect(calls, hasLength(1));
            expect(calls.single.$1, 'default');
            expect(calls.single.$3['room_id'], group.id);
            if (continuing) {
              expect(calls.single.$3, {
                'room_id': group.id,
                'task_id': 'stranded-task',
                'member_id': 'atlas',
                'execution_generation': 4,
              });
            } else {
              expect(calls.single.$3['cancel_id'], isNotEmpty);
            }
            expect(
              tester.widget<TextField>(input).controller!.text,
              'Keep this draft',
            );
            stopGate.complete();
            await tester.pumpAndSettle();
            expect(fixture.commands.map((call) => call.$2), [
              continuing ? 'groups.retry' : 'groups.stop',
            ]);
            expect(fixture.events, hasLength(continuing ? 1 : 2));
            expect(session.acting, isFalse);
            expect(session.runtime!.actions, isEmpty);
            expect(session.canStopGroupWork, isFalse);
            expect(
              find.widgetWithText(StudioError, 'Atlas could not finish.'),
              findsNothing,
            );
            expect(
              session.events.map((event) => event.text),
              contains('Saved group reply'),
            );
            if (!continuing) {
              expect(find.text('Saved group reply'), findsOneWidget);
            }
            expect(
              tester.widget<TextField>(input).controller!.text,
              'Keep this draft',
            );
            await tester.tap(find.byTooltip('Group options'));
            await tester.pumpAndSettle();
            expect(find.text('Stop group work'), findsNothing);
            await tester.tapAt(const Offset(20, 500));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
          },
        );
      }
      testWidgets(
        'manual group refresh is visible and automatic reads stay quiet ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          fixture.readHook = (_, method, _) async => method == 'groups.state'
              ? {
                  'room': {
                    ...fixture.room,
                    'latest_seq': fixture.events.length,
                  },
                  'driver_status': {
                    'working': true,
                    'blocked': false,
                    'pending_actions': <Object>[],
                  },
                }
              : null;
          fixture.events.add(
            _event(1, 'message.member', 'atlas', 'Saved group reply'),
          );
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).first;
          final appearances = FixedGroupAppearances(
            await fixture.repository.bots(),
          );
          addTearDown(appearances.dispose);
          final frame = GlobalKey();
          final reduced = ValueNotifier(true);
          addTearDown(reduced.dispose);
          late BotGroupSession session;
          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => ValueListenableBuilder<bool>(
                  valueListenable: reduced,
                  builder: (_, value, _) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(scale),
                      disableAnimations: value,
                    ),
                    child: child!,
                  ),
                ),
                home: BotGroupScreen(
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () =>
                      const LocalVoiceInputSettings(language: ''),
                  createSession: () => session = BotGroupSession(
                    fixture.repository,
                    group,
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                    groupMessages: null,
                    appearances: appearances,
                  ),
                ),
              ),
            ),
          );
          await _settleGroupMarkdown(tester);
          await tester.pumpAndSettle();
          final input = find.byType(TextField);
          await tester.enterText(input, 'Keep this draft');
          await tester.pumpAndSettle();
          final transcript = find.byKey(const ValueKey('profile-transcript'));
          final transcriptRect = tester.getRect(transcript);
          final composerRect = tester.getRect(input);
          final menuRect = tester.getRect(find.byTooltip('Group options'));
          final stateGate = Completer<void>();
          final logGate = Completer<void>();
          final stateStarted = Completer<void>();
          final logStarted = Completer<void>();
          var stateReads = 0;
          fixture.readHook = (_, method, _) async {
            if (method == 'groups.state') {
              stateReads++;
              if (!stateStarted.isCompleted) stateStarted.complete();
              await stateGate.future;
              return {
                'room': {...fixture.room, 'latest_seq': fixture.events.length},
                'driver_status': {
                  'working': true,
                  'blocked': false,
                  'pending_actions': <Object>[],
                },
              };
            }
            if (method == 'groups.log') {
              if (!logStarted.isCompleted) logStarted.complete();
              await logGate.future;
            }
            return null;
          };
          reduced.value = false;
          await tester.pump();
          final automatic = session.refresh();
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.text('Bots are working…'), findsOneWidget);
          await tester.tap(find.byTooltip('Group options'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text('Refresh group'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(stateStarted.isCompleted, isTrue);
          expect(stateReads, 1);
          // Wait for the dismissed popup to release its semantics scope.
          for (
            var frame = 0;
            frame < 10 && find.byTooltip('Refreshing group').evaluate().isEmpty;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(find.byTooltip('Refreshing group'), findsOneWidget);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.text('Refreshing group'), findsNothing);
          expect(find.text('Bots are working…'), findsOneWidget);
          expect(find.byIcon(Icons.pending_outlined), findsNothing);
          final pulse = find.byTooltip('Refreshing group');
          expect(
            find.ancestor(of: pulse, matching: find.byType(WingAppBar)),
            findsOneWidget,
          );
          final pulseRect = tester.getRect(pulse);
          final identityRect = tester.getRect(
            find.byType(ServerConnectionLabel),
          );
          expect(pulseRect.center.dy, closeTo(identityRect.center.dy, 1));
          expect(pulseRect.overlaps(transcriptRect), isFalse);
          expect(find.byIcon(Icons.more_horiz), findsOneWidget);
          expect(tester.getRect(transcript), transcriptRect);
          expect(tester.getRect(input), composerRect);
          expect(tester.getRect(find.byTooltip('Group options')), menuRect);
          expect(tester.widget<TextField>(input).readOnly, isFalse);
          await _render(tester, frame, 'refreshing-${brightness.name}-$scale');
          reduced.value = true;
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(tester.binding.transientCallbackCount, 0);
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          final item = tester.widget<StudioPopupMenuItem<String>>(
            find.widgetWithText(StudioPopupMenuItem<String>, 'Refresh group'),
          );
          expect(item.enabled, isFalse);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          fixture.events.add(
            _event(2, 'message.member', 'mira', 'Fresh group reply'),
          );
          stateGate.complete();
          await tester.pump();
          expect(logStarted.isCompleted, isTrue);
          expect(find.byTooltip('Refreshing group'), findsOneWidget);
          logGate.complete();
          await automatic;
          await tester.pump();
          await _settleGroupMarkdown(tester);
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.text('Bots are working…'), findsOneWidget);
          expect(find.text('Fresh group reply'), findsOneWidget);
          expect(
            tester.widget<TextField>(input).controller!.text,
            'Keep this draft',
          );
          expect(tester.getRect(transcript), transcriptRect);
          expect(tester.getRect(input), composerRect);
          expect(tester.getRect(find.byTooltip('Group options')), menuRect);
          expect(fixture.commands, isEmpty);
          fixture.readHook = (_, method, _) async {
            if (method == 'groups.state') throw StateError('Offline');
            return null;
          };
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Refresh group'));
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(find.textContaining('could not refresh'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('Fresh group reply'),
            150,
            scrollable: find
                .descendant(of: transcript, matching: find.byType(Scrollable))
                .last,
          );
          await _settleGroupMarkdown(tester);
          expect(find.text('Fresh group reply'), findsOneWidget);
          fixture.readHook = null;
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Refresh group'));
          await tester.pumpAndSettle();
          expect(find.textContaining('could not refresh'), findsNothing);
          expect(
            tester.widget<TextField>(input).controller!.text,
            'Keep this draft',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets(
        'discussion instance position matches standard header ${brightness.name} $scale',
        (tester) async {
          final size = Size(scale == 1 ? 390 : 320, 844);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).first;
          final status = ServerConnectionStatus('Claw')
            ..accessAvailable()
            ..liveChanged('discussion', true);
          addTearDown(status.dispose);
          final frame = GlobalKey();
          Widget identity() => ServerConnectionLabel(
            label: 'Claw',
            icon: ConnectionIcon.cloud,
            status: status,
          );
          Future<void> show({
            required bool discussion,
            required bool keyboard,
          }) async {
            await tester.pumpWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    padding: const EdgeInsets.only(top: 24),
                    viewInsets: EdgeInsets.only(bottom: keyboard ? 280 : 0),
                  ),
                  child: child!,
                ),
                home: RepaintBoundary(
                  key: frame,
                  child: Builder(
                    builder: (context) {
                      final actions = [
                        IconButton(
                          tooltip: 'Group options',
                          onPressed: () {},
                          icon: const Icon(Icons.more_horiz),
                        ),
                      ];
                      return discussion
                          ? BotGroupConversation(
                              group: group,
                              appearances: const [],
                              instanceHeader: identity(),
                              transcript: const Center(
                                child: Text('Discussion'),
                              ),
                              composer: const SizedBox(height: 64),
                              actions: actions,
                              onBack: () {},
                              onMembers: () {},
                              showMembers: !keyboard,
                            )
                          : Scaffold(
                              appBar: WingAppBar(
                                context: context,
                                leading: const BackButton(),
                                title: WingConversationTitle(
                                  title: group.name,
                                  avatar: BotGroupIdentity(
                                    group: group,
                                    bots: const [],
                                    size: 32,
                                  ),
                                ),
                                actions: actions,
                                contextRow: Align(
                                  alignment: Alignment.centerLeft,
                                  child: identity(),
                                ),
                              ),
                              body: const Center(
                                child: Text('Standard screen'),
                              ),
                            );
                    },
                  ),
                ),
              ),
            );
            await tester.pump();
          }

          Map<String, Rect> geometry() => {
            'icon': tester.getRect(find.byIcon(Icons.cloud_outlined)),
            'led': tester.getRect(
              find.byKey(const ValueKey('server-connection-led')),
            ),
            'name': tester.getRect(find.text('Claw')),
            'details': tester.getRect(
              find.byKey(const ValueKey('connection-status-target')),
            ),
          };
          await show(discussion: false, keyboard: false);
          final standard = geometry();
          await _render(
            tester,
            frame,
            'instance-standard-${brightness.name}-$scale',
          );
          for (final keyboard in [false, true]) {
            await show(discussion: true, keyboard: keyboard);
            expect(find.byType(ServerConnectionLabel), findsOneWidget);
            expect(
              geometry(),
              standard,
              reason:
                  'The shared instance identity must occupy the standard screen position, including with the keyboard open.',
            );
            expect(tester.takeException(), isNull);
            await _render(
              tester,
              frame,
              'instance-position-${brightness.name}-$scale-keyboard-$keyboard',
            );
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final reduced in [false, true]) {
    testWidgets(
      'group cached landing keeps viewport geometry across first runtime refresh reduced=$reduced',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = BotsFixture();
        fixture.events.add(
          _event(
            1,
            'message.member',
            'atlas',
            'Cached reply with **bold** text.',
          ),
        );
        final cache = RecentGroupMessages();
        addTearDown(cache.dispose);
        final group = (await readFixtureGroups(
          fixture.repository,
          groupMessages: cache,
        )).single;
        final waiting = Completer<void>();
        fixture.readHook = (_, method, _) async {
          if (method == 'groups.state') await waiting.future;
          return null;
        };
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!,
            ),
            home: BotGroupScreen(
              stopVoicePlayback: () async {},
              voiceInputSettings: () => null,
              createSession: () => BotGroupSession(
                fixture.repository,
                group,
                reads: BotGroupReadState(),
                preferences: groupPreferences,
                groupMessages: cache,
                appearances: FixedGroupAppearances(const []),
              ),
            ),
          ),
        );
        final viewport = find.byKey(const ValueKey('profile-transcript'));
        final reply = find.byKey(const ValueKey(('group-message', 1)));
        final before = tester.getRect(viewport);
        final bottom = tester.getRect(reply).bottom;
        await _settleGroupMarkdown(tester);
        expect(tester.getRect(viewport), before);
        expect(tester.getRect(reply).bottom, closeTo(bottom, .01));
        await tester.pump();
        expect(find.text('Loading history…'), findsNothing);
        expect(find.byType(StudioLoading), findsNothing);
        expect(find.bySemanticsLabel('Loading history'), findsNothing);
        waiting.complete();
        await _settleGroupMarkdown(tester);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(StudioLoading), findsNothing);
        expect(tester.getRect(viewport), before);
        expect(tester.getRect(reply).bottom, closeTo(bottom, .01));
      },
    );
  }

  testWidgets('live group prepares only the bottom on its first loaded frame', (
    tester,
  ) async {
    final fixture = BotsFixture();
    fixture.events.addAll([
      for (var i = 1; i <= 100; i++)
        _event(i, 'message.member', 'atlas', 'Message $i\n' * 20),
    ]);
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).single;
    await tester.pumpWidget(
      MaterialApp(
        home: BotGroupScreen(
          stopVoicePlayback: () async {},
          voiceInputSettings: () => null,
          createSession: () => BotGroupSession(
            fixture.repository,
            group,
            reads: BotGroupReadState(),
            preferences: groupPreferences,
            groupMessages: null,
            appearances: FixedGroupAppearances(const []),
          ),
        ),
      ),
    );
    await tester.pump();
    final messages = tester
        .widgetList<BotGroupMessage>(find.byType(BotGroupMessage))
        .toList();
    expect(
      messages.any((message) => message.message.id == 'room-1:100'),
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

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group dictation shares chat controls ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).single;
          final device = VoiceDeviceFixture();
          addTearDown(device.stream.close);
          final frame = GlobalKey();
          var playbackStops = 0;
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
                child: BotGroupScreen(
                  voiceInputSettings: () =>
                      const LocalVoiceInputSettings(language: 'fr-FR'),
                  stopVoicePlayback: () async {
                    playbackStops++;
                  },
                  voiceDevice: device,
                  createSession: () => BotGroupSession(
                    fixture.repository,
                    group,
                    groupMessages: null,
                    appearances: FixedGroupAppearances(const []),
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                  ),
                ),
              ),
            ),
          );
          await _settleGroupMarkdown(tester);
          final titleBounds = tester.getRect(find.text(group.name));
          final artworkBounds = tester.getRect(find.byType(BotGroupIdentity));
          expect(artworkBounds.isEmpty, isFalse);
          expect(titleBounds.left, greaterThanOrEqualTo(artworkBounds.right));
          expect(titleBounds.center.dy, closeTo(artworkBounds.center.dy, .01));
          final input = find.byKey(const ValueKey('group-message-composer'));
          await tester.enterText(input, 'Plan: replace later');
          final editing = tester.widget<TextField>(input).controller!;
          editing.selection = const TextSelection(
            baseOffset: 6,
            extentOffset: 13,
          );
          await tester.pump();
          await _render(tester, frame, 'voice-idle-${brightness.name}-$scale');
          expect(find.byType(VoiceInputButton), findsOneWidget);
          await tester.tap(find.byTooltip('Dictate message'));
          await tester.pump();
          expect(device.language, 'fr-FR');
          expect(device.local, isTrue);
          expect(playbackStops, 1);
          expect(tester.widget<TextField>(input).readOnly, isTrue);
          expect(find.byType(VoiceInputActivity), findsOneWidget);
          expect(find.byTooltip('Stop recording'), findsOneWidget);
          expect(find.byTooltip('Cancel recording'), findsOneWidget);
          expect(find.text('Cancel recording'), findsNothing);
          final send = tester.widget<ComposerIconButton>(
            find.byType(ComposerIconButton),
          );
          expect(send.onPressed, isNull);
          device.stream.add({
            'id': device.recording,
            'text': 'spoken',
            'final': false,
          });
          await tester.pump();
          await _render(
            tester,
            frame,
            'voice-recording-${brightness.name}-$scale',
          );
          final oldText = editing.text;
          await tester.tap(find.byTooltip('Cancel recording'));
          await tester.pump();
          expect(editing.text, oldText);
          expect(
            editing.selection,
            const TextSelection(baseOffset: 6, extentOffset: 13),
          );
          await tester.tap(find.byTooltip('Dictate message'));
          await tester.pump();
          device.stream.add({
            'id': device.recording,
            'text': 'spoken',
            'final': true,
          });
          await tester.pump();
          expect(editing.text, 'Plan: spoken later');
          expect(editing.selection.extentOffset, 12);
          expect(fixture.commands, isEmpty);
          final speechError = List.filled(
            3,
            'Speech processing failed. Check your connection and profile speech settings, then retry.',
          ).join(' ');
          device.startError = StateError(speechError);
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          await tester.pump();
          await tester.tap(find.byTooltip('Dictate message'));
          await tester.pump();
          expect(find.text(speechError), findsOneWidget);
          expect(editing.text, 'Plan: spoken later');
          expect(
            tester.getRect(find.byTooltip('Dictate message')).bottom,
            lessThanOrEqualTo(844 - 280),
          );
          await _render(tester, frame, 'voice-error-${brightness.name}-$scale');
          final errorScroll = find.descendant(
            of: find.byType(VoiceInputActivity),
            matching: find.byType(Scrollable),
          );
          final errorPosition = tester
              .state<ScrollableState>(errorScroll)
              .position;
          expect(
            tester.getTopLeft(find.byType(VoiceInputActivity)).dy,
            greaterThanOrEqualTo(
              tester.getTopLeft(find.byType(ConversationFooter)).dy,
            ),
          );
          expect(errorPosition.maxScrollExtent, greaterThan(0));
          await tester.drag(
            find.descendant(
              of: find.byType(VoiceInputActivity),
              matching: find.byType(SingleChildScrollView),
            ),
            const Offset(0, -60),
          );
          await tester.pump();
          expect(errorPosition.pixels, greaterThan(0));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('group dictation cancels when Recents obscures the discussion', (
    tester,
  ) async {
    final fixture = BotsFixture();
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).single;
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final screen = BotGroupScreen(
      voiceInputSettings: () => const LocalVoiceInputSettings(language: ''),
      stopVoicePlayback: () async {},
      voiceDevice: device,
      createSession: () => BotGroupSession(
        fixture.repository,
        group,
        groupMessages: null,
        appearances: FixedGroupAppearances(const []),
        reads: BotGroupReadState(),
        preferences: groupPreferences,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: visible,
          builder: (_, value, child) => ConversationPresentationScope(
            visible: value,
            onRecordingChanged: (_) {},
            child: child!,
          ),
          child: screen,
        ),
      ),
    );
    await _settleGroupMarkdown(tester);
    final input = find.byKey(const ValueKey('group-message-composer'));
    await tester.enterText(input, 'Keep this draft');
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    final id = device.recording;
    visible.value = false;
    await tester.pump();
    expect(device.cancelled, contains(id));
    device.stream.add({'id': id, 'text': 'late speech', 'final': true});
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'Keep this draft');
    visible.value = true;
    await tester.pump();
    expect(find.byTooltip('Cancel recording'), findsNothing);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    final backgroundId = device.recording;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(device.cancelled, contains(backgroundId));
    device.stream.add({
      'id': backgroundId,
      'text': 'background speech',
      'final': true,
    });
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'Keep this draft');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'group dictation uses Hermes and preserves drafts after microphone failure',
    (tester) async {
      final server = AdministrationFixture();
      final fixture = BotsFixture(server: server.server);
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      final device = VoiceDeviceFixture()
        ..startError = StateError('Microphone unavailable');
      addTearDown(device.stream.close);
      final transcript = Completer<Map<String, dynamic>>();
      server.mutationOverride =
          (method, path, query, body, canDispatch, onDispatched) async {
            expect(canDispatch(), isTrue);
            onDispatched();
            server.requests.add((method, path, query, body));
            return transcript.future;
          };
      await tester.pumpWidget(
        MaterialApp(
          home: BotGroupScreen(
            voiceInputSettings: () => const HermesVoiceInputSettings(),
            stopVoicePlayback: () async {},
            voiceDevice: device,
            createSession: () => BotGroupSession(
              fixture.repository,
              group,
              groupMessages: null,
              appearances: FixedGroupAppearances(const []),
              reads: BotGroupReadState(),
              preferences: groupPreferences,
            ),
          ),
        ),
      );
      await _settleGroupMarkdown(tester);
      final input = find.byKey(const ValueKey('group-message-composer'));
      await tester.enterText(input, 'Draft');
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      expect(find.text('Microphone unavailable'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, 'Draft');
      device.startError = null;
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      expect(device.local, isFalse);
      await tester.tap(find.byTooltip('Stop recording'));
      await tester.pump();
      expect(find.text('Transcribing…'), findsOneWidget);
      expect(server.requests.single.$3, {'profile': 'default'});
      expect(server.requests.single.$4, {
        'data_url': 'data:audio/mp4;base64,AQID',
        'mime_type': 'audio/mp4',
      });
      transcript.complete({'ok': true, 'transcript': 'spoken'});
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, 'Draft spoken');
      expect(fixture.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group header opens editor from name and icon ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          fixture.events.add(
            _event(1, 'message.member', 'atlas', 'Keep this reply'),
          );
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).first;
          final appearances = await fixture.repository.bots();
          final navigator = GlobalKey<NavigatorState>();
          final frame = GlobalKey();
          var edits = 0;
          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                navigatorKey: navigator,
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: BotGroupScreen(
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () =>
                      const LocalVoiceInputSettings(language: ''),
                  createSession: () => BotGroupSession(
                    fixture.repository,
                    group,
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                    groupMessages: null,
                    appearances: FixedGroupAppearances(appearances),
                  ),
                  onEdit: (selected) async {
                    expect(selected.id, group.id);
                    edits++;
                    await navigator.currentState!.push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            const Scaffold(body: Text('Group editor')),
                      ),
                    );
                    return selected.withDetails(
                      name: 'Renamed group',
                      color: ProfileColorChoice.blue,
                      picture: selected.picture,
                      revision: 1,
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _settleGroupMarkdown(tester);
          final input = find.byKey(const ValueKey('group-message-composer'));
          await tester.enterText(input, 'Keep this draft');
          await tester.pumpAndSettle();
          final title = find.byTooltip('Edit group');
          expect(title, findsOneWidget);
          expect(tester.getSize(title).height, greaterThanOrEqualTo(48));
          await _render(
            tester,
            frame,
            'editable-header-${brightness.name}-$scale',
          );
          await tester.tap(find.text(group.name));
          await tester.pumpAndSettle();
          expect(find.text('Group editor'), findsOneWidget);
          expect(edits, 1);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(find.text('Renamed group'), findsOneWidget);
          expect(
            tester.widget<TextField>(input).controller!.text,
            'Keep this draft',
          );
          expect(find.text('Keep this reply'), findsOneWidget);
          await tester.tap(
            find.descendant(of: title, matching: find.byType(BotGroupIdentity)),
          );
          await tester.pumpAndSettle();
          expect(find.text('Group editor'), findsOneWidget);
          expect(edits, 2);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          expect(find.text('Edit group'), findsNothing);
          expect(find.text('Bot working histories'), findsNothing);
          expect(find.text('Refresh group'), findsOneWidget);
          await _render(
            tester,
            frame,
            'group-options-${brightness.name}-$scale',
          );
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(fixture.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'bot avatar popup has only two scoped actions ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final semantics = tester.ensureSemantics();
          final fixture = BotsFixture();
          fixture.events.addAll([
            _event(1, 'message.member', 'atlas', 'Atlas room reply'),
            _event(2, 'message.member', 'mira', 'Mira room reply'),
          ]);
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).first;
          final appearances = await fixture.repository.bots();
          var reads = 0;
          fixture.readHook = (_, method, _) async {
            if (method == 'groups.state') reads++;
            return null;
          };
          final navigator = GlobalKey<NavigatorState>();
          final frame = GlobalKey();
          final actions = <(String, String, String)>[];
          Future<void> open(BotRecord bot, String action) async {
            actions.add((
              action,
              bot.scope.connectionIdentity,
              bot.profile.name,
            ));
            await navigator.currentState!.push<void>(
              MaterialPageRoute(
                builder: (_) => Scaffold(body: Text('${bot.title} $action')),
              ),
            );
          }

          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                navigatorKey: navigator,
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: scale == 2,
                  ),
                  child: child!,
                ),
                home: BotGroupScreen(
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () =>
                      const LocalVoiceInputSettings(language: ''),
                  createSession: () => BotGroupSession(
                    fixture.repository,
                    group,
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                    groupMessages: null,
                    appearances: FixedGroupAppearances(appearances),
                  ),
                  onOpenBotChat: (bot) => open(bot, 'private chat'),
                  onOpenBotSettings: (bot) => open(bot, 'settings'),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _settleGroupMarkdown(tester);
          final input = find.byKey(const ValueKey('group-message-composer'));
          await tester.enterText(input, 'Keep my room draft');
          await tester.pumpAndSettle();
          final avatar = find.byTooltip('Options for Mira');
          final sourceMessage = find.ancestor(
            of: avatar,
            matching: find.byType(ProfileMessage),
          );
          bool sourceAvatarVisible() =>
              tester.widget<ProfileMessage>(sourceMessage).senderAvatarVisible;
          expect(tester.getSize(avatar).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(avatar).height, greaterThanOrEqualTo(48));
          final anchor = tester.getRect(avatar);
          final avatarBounds = tester.getRect(
            find.descendant(of: avatar, matching: find.byType(BotAvatar)),
          );
          await tester.tap(avatar);
          await tester.pumpAndSettle();
          expect(sourceAvatarVisible(), isFalse);
          expect(tester.getRect(avatar), anchor);
          final otherMessage = find.ancestor(
            of: find.byTooltip('Options for Atlas'),
            matching: find.byType(ProfileMessage),
          );
          expect(
            tester.widget<ProfileMessage>(otherMessage).senderAvatarVisible,
            isTrue,
          );
          final buttons = [
            for (final action in ['chat', 'settings'])
              find.byKey(ValueKey(('group-bot-action', action))),
          ];
          for (final button in buttons) {
            expect(button, findsOneWidget);
            expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
            expect(tester.widget<PopupMenuItem>(button).enabled, isTrue);
            expect(
              tester
                  .getSemantics(
                    find
                        .descendant(of: button, matching: find.byType(Text))
                        .first,
                  )
                  .getSemanticsData()
                  .hasAction(ui.SemanticsAction.tap),
              isTrue,
            );
          }
          expect(find.text('View working history'), findsNothing);
          expect(find.text('Chat directly'), findsOneWidget);
          expect(find.text('Bot settings'), findsOneWidget);
          final panel = find
              .ancestor(
                of: buttons.first,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Material &&
                      widget.elevation == 4 &&
                      widget.shape is RoundedRectangleBorder,
                ),
              )
              .first;
          final panelRect = tester.getRect(panel);
          expect(panelRect.left, greaterThanOrEqualTo(8));
          expect(
            panelRect.right,
            lessThanOrEqualTo(tester.view.physicalSize.width - 8),
          );
          expect(panelRect.bottom, lessThanOrEqualTo(844 - 8));
          expect(panelRect.contains(anchor.center), isTrue);
          expect(panelRect.top, lessThanOrEqualTo(avatarBounds.top));
          expect(panelRect.bottom, greaterThanOrEqualTo(anchor.top));
          final identity = find.byKey(
            const ValueKey('group-bot-card-identity'),
          );
          final face = tester.widget<BotAvatar>(
            find.descendant(of: identity, matching: find.byType(BotAvatar)),
          );
          expect(face.name, 'Mira');
          expect(
            find
                .descendant(of: identity, matching: find.byType(BotAvatar))
                .hitTestable(),
            findsOneWidget,
          );
          final menuAvatar = find.descendant(
            of: identity,
            matching: find.byType(BotAvatar),
          );
          expect(
            tester.getCenter(menuAvatar).dx,
            closeTo(anchor.center.dx, .1),
          );
          if (scale == 1) {
            expect(
              tester.getCenter(menuAvatar).dy,
              closeTo(anchor.center.dy, .1),
            );
          }
          expect(
            find.descendant(of: identity, matching: find.text('Mira')),
            findsOneWidget,
          );
          await _render(tester, frame, 'bot-popup-${brightness.name}-$scale');
          final pausedReads = reads;
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump(const Duration(seconds: 5));
          expect(reads, pausedReads);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          if (scale == 1) expect(sourceAvatarVisible(), isFalse);
          await tester.pumpAndSettle();
          expect(find.text('Chat directly'), findsNothing);
          expect(sourceAvatarVisible(), isTrue);
          expect(reads, greaterThan(pausedReads));
          expect(actions, isEmpty);
          for (final (label, page, action) in [
            ('Chat directly', 'Mira private chat', 'private chat'),
            ('Bot settings', 'Mira settings', 'settings'),
          ]) {
            await tester.tap(avatar);
            await tester.pumpAndSettle();
            await tester.tap(find.text(label));
            await tester.pumpAndSettle();
            expect(find.text(page), findsOneWidget);
            expect(actions.last, (
              action,
              group.scope.connectionIdentity,
              'mira',
            ));
            final coveredReads = reads;
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pump(const Duration(seconds: 5));
            expect(reads, coveredReads);
            navigator.currentState!.pop();
            await tester.pumpAndSettle();
            expect(sourceAvatarVisible(), isTrue);
            expect(
              tester.widget<TextField>(input).controller!.text,
              'Keep my room draft',
            );
            expect(find.text('Mira room reply'), findsOneWidget);
          }
          await tester.tap(avatar);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          await _settleGroupMarkdown(tester);
          expect(find.text('Mira private chat'), findsOneWidget);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          await tester.tap(avatar);
          await tester.pumpAndSettle();
          await tester.tapAt(const Offset(280, 100));
          await tester.pumpAndSettle();
          expect(find.text('Chat directly'), findsNothing);
          expect(
            tester.widget<TextField>(input).controller!.text,
            'Keep my room draft',
          );
          expect(fixture.commands, isEmpty);
          expect(tester.takeException(), isNull);
          expect(sourceAvatarVisible(), isTrue);
          await tester.tap(avatar);
          await tester.pumpAndSettle();
          expect(sourceAvatarVisible(), isFalse);
          semantics.dispose();
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'missing bot disables profile shortcuts without offering private history',
    (tester) async {
      final fixture = BotsFixture();
      fixture.events.add(
        _event(1, 'message.member', 'mira', 'Saved Mira reply'),
      );
      final group = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).first;
      await tester.pumpWidget(
        MaterialApp(
          home: BotGroupScreen(
            stopVoicePlayback: () async {},
            voiceInputSettings: () =>
                const LocalVoiceInputSettings(language: ''),
            createSession: () => BotGroupSession(
              fixture.repository,
              group,
              reads: BotGroupReadState(),
              preferences: groupPreferences,
              groupMessages: null,
              appearances: FixedGroupAppearances([]),
            ),
            onOpenBotChat: (_) async => fail('Unavailable bot must not open'),
            onOpenBotSettings: (_) async =>
                fail('Unavailable bot must not open'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Options for Mira'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey(('group-bot-action', 'history'))),
        findsNothing,
      );
      expect(
        tester
            .widget<PopupMenuItem>(
              find.byKey(const ValueKey(('group-bot-action', 'chat'))),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<PopupMenuItem>(
              find.byKey(const ValueKey(('group-bot-action', 'settings'))),
            )
            .enabled,
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('covered group editor stays paused across app resume', (
    tester,
  ) async {
    final fixture = BotsFixture();
    final group = (await readFixtureGroups(
      fixture.repository,
      groupMessages: null,
    )).first;
    final appearances = await fixture.repository.bots();
    var reads = 0;
    fixture.readHook = (_, method, _) async {
      if (method == 'groups.state') reads++;
      return null;
    };
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: BotGroupScreen(
          stopVoicePlayback: () async {},
          voiceInputSettings: () => const LocalVoiceInputSettings(language: ''),
          createSession: () => BotGroupSession(
            fixture.repository,
            group,
            reads: BotGroupReadState(),
            preferences: groupPreferences,
            groupMessages: null,
            appearances: FixedGroupAppearances(appearances),
          ),
          onEdit: (_) async {
            await navigator.currentState!.push<void>(
              MaterialPageRoute(
                builder: (_) => const Scaffold(body: Text('Group editor')),
              ),
            );
            return null;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit group'));
    await tester.pumpAndSettle();
    expect(find.text('Group editor'), findsOneWidget);
    final coveredReads = reads;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 5));
    expect(reads, coveredReads);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(reads, greaterThan(coveredReads));
    expect(tester.takeException(), isNull);
  });

  setUpAll(() async {
    if (!_capture) return;
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
      testWidgets(
        'group replies use normal chat copy controls ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          fixture.events.add({
            'room_id': 'room-1',
            'seq': 1,
            'kind': 'message.member',
            'actor': {'kind': 'member', 'id': 'atlas', 'profile': 'atlas'},
            'payload': {
              'text':
                  '**Read-only sources.**\n\n- [Mission](https://example.com/mission)\n- `verified`',
            },
            'created_at': 1791756000.0,
          });
          fixture.events.add(
            _event(
              2,
              'message.user',
              'you',
              '**Literal user text** @bot_atlas',
            ),
          );
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).first;
          final appearances = await fixture.repository.bots();
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
                child: BotGroupScreen(
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () =>
                      const LocalVoiceInputSettings(language: ''),
                  createSession: () => BotGroupSession(
                    fixture.repository,
                    group,
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                    groupMessages: null,
                    appearances: FixedGroupAppearances(appearances),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(find.byType(ProfileMessage), findsNWidgets(2));
          expect(find.text('User'), findsNothing);
          final botMessage = tester
              .widgetList<ProfileMessage>(find.byType(ProfileMessage))
              .firstWhere((widget) => widget.message.sender != null);
          final bubbleColors = botMessage.botBubbleColors!;
          final theme = wingTheme(brightness);
          expect(
            bubbleColors.fill,
            isNot(theme.colorScheme.surfaceContainerHigh),
          );
          final botBubble = find.byKey(
            const ValueKey<(String, Object?)>((
              'bot-message-bubble',
              'room-1:1',
            )),
          );
          expect(
            (tester.widget<Container>(botBubble).decoration as BoxDecoration)
                .color,
            bubbleColors.fill,
          );
          final botFooter = tester.widget<Material>(
            find.byKey(
              const ValueKey<(String, Object?)>((
                'bot-message-footer',
                'room-1:1',
              )),
            ),
          );
          expect(
            botFooter.color,
            Color.lerp(theme.colorScheme.surface, bubbleColors.fill, .5),
          );
          final userBubble = find.byKey(
            const ValueKey<(String, Object?)>((
              'user-message-bubble',
              'room-1:2',
            )),
          );
          expect(
            tester
                .widget<ColoredBox>(
                  find
                      .descendant(
                        of: userBubble,
                        matching: find.byType(ColoredBox),
                      )
                      .first,
                )
                .color,
            theme.colorScheme.primaryContainer,
          );
          expect(
            colorContrast(bubbleColors.text, bubbleColors.fill),
            greaterThanOrEqualTo(7),
          );
          expect(
            colorContrast(bubbleColors.link, bubbleColors.fill),
            greaterThanOrEqualTo(4.5),
          );
          final userText = tester
              .widgetList<SelectableText>(find.byType(SelectableText))
              .firstWhere(
                (text) =>
                    text.textSpan?.toPlainText().contains('Literal user') ??
                    false,
              );
          expect(
            userText.textSpan!.toPlainText(),
            '**Literal user text** @Atlas',
          );
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          for (final (kind, id, expectedText) in [
            (
              'user-message-bubble',
              'room-1:2',
              '**Literal user text** @bot_atlas',
            ),
            (
              'bot-message-bubble',
              'room-1:1',
              '**Read-only sources.**\n\n- [Mission](https://example.com/mission)\n- `verified`',
            ),
          ]) {
            final message = find.byWidgetPredicate(
              (widget) => widget is ProfileMessage && widget.message.id == id,
            );
            final bubble = find.byKey(ValueKey<(String, Object?)>((kind, id)));
            final copy = find.descendant(
              of: message,
              matching: find.byTooltip('Copy message'),
            );
            expect(copy, findsOneWidget);
            expect(find.descendant(of: bubble, matching: copy), findsOneWidget);
            await tester.ensureVisible(copy);
            await tester.pumpAndSettle();
            final bubbleRect = tester.getRect(bubble);
            final copyRect = tester.getRect(copy);
            expect(copyRect.width, greaterThanOrEqualTo(48));
            expect(copyRect.height, greaterThanOrEqualTo(32));
            expect(bubbleRect.contains(copyRect.center), isTrue);
            expect(copy.hitTestable(), findsOneWidget);
            await tester.tapAt(Offset(copyRect.right - 2, copyRect.bottom - 2));
            expect(copied, expectedText);
            await tester.pumpAndSettle();
            expect(find.byType(SnackBar), findsNothing);
            await _render(
              tester,
              frame,
              'copy-$kind-${brightness.name}-$scale',
            );
          }
          expect(tester.takeException(), isNull);
          expect(find.text('Atlas'), findsWidgets);
          expect(find.textContaining('**Read-only'), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group composer, sender identity and recovery ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          fixture.events.addAll([
            _event(
              1,
              'message.user',
              'you',
              'Let’s build Pace Health Analysis. @bot_atlas will build it; @bot_mira will review the evidence.',
            ),
            _event(
              2,
              'message.member',
              'atlas',
              'Saved our shared mission in [docs/mission.md](https://example.com/mission).\n\n**Acceptance gates**\n- Read-only sources\n- Reproducible calculations\n- Every conclusion links to evidence',
            ),
            _event(
              3,
              'message.member',
              'mira',
              'I’ll review the scientific assumptions before implementation. The comparison windows and missing-data rules need your approval.',
            ),
          ]);
          final group =
              (await readFixtureGroups(
                fixture.repository,
                groupMessages: null,
              )).first.withIcon(
                picture: File('assets/icon/icon.png').readAsBytesSync(),
              );
          final appearances = await fixture.repository.bots();
          final frame = GlobalKey();
          final keyboard = ValueNotifier<bool>(false);
          addTearDown(keyboard.dispose);
          late BotGroupSession session;
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => ValueListenableBuilder<bool>(
                valueListenable: keyboard,
                builder: (context, shown, _) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    viewInsets: EdgeInsets.only(bottom: shown ? 280 : 0),
                  ),
                  child: child!,
                ),
              ),
              home: RepaintBoundary(
                key: frame,
                child: BotGroupScreen(
                  stopVoicePlayback: () async {},
                  voiceInputSettings: () =>
                      const LocalVoiceInputSettings(language: ''),
                  createSession: () => session = BotGroupSession(
                    fixture.repository,
                    group,
                    reads: BotGroupReadState(),
                    preferences: groupPreferences,
                    groupMessages: null,
                    appearances: FixedGroupAppearances(appearances),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _settleGroupMarkdown(tester);
          final botMessages = tester
              .widgetList<ProfileMessage>(find.byType(ProfileMessage))
              .where((widget) => widget.message.sender != null)
              .toList();
          // Enlarged text lazily mounts only the latest bot at this scroll position.
          if (scale == 1) {
            expect(
              botMessages.map((widget) => widget.botBubbleColors!.fill).toSet(),
              hasLength(2),
            );
          }
          expect(
            tester.widget<BotGroupPicture>(find.byType(BotGroupPicture)).image,
            group.picture,
          );
          expect(tester.takeException(), isNull);
          if (scale == 1) expect(find.byType(BotAvatar), findsWidgets);
          final input = find.byKey(const ValueKey('group-message-composer'));
          final send = find.byWidgetPredicate(
            (widget) =>
                widget is IconButton && widget.tooltip == 'Send group message',
          );
          expect(tester.widget<IconButton>(send).onPressed, isNull);
          await _render(
            tester,
            frame,
            'conversation-${brightness.name}-$scale',
          );
          expect(find.byType(ActionChip), findsNothing);
          await tester.enterText(input, 'Review @at this evidence');
          final controller = tester.widget<TextField>(input).controller!;
          controller.selection = const TextSelection.collapsed(offset: 10);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(MentionSuggestions),
              matching: find.text('Atlas'),
            ),
          );
          await tester.pump();
          expect(controller.text, 'Review @Atlas this evidence');
          expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
          final transcript = tester
              .widget<ListView>(
                find.byKey(const ValueKey('profile-transcript')),
              )
              .controller!;
          fixture.events.add(
            _event(
              4,
              'message.member',
              'atlas',
              'Evidence review\n\n${List.filled(8, 'The approved source list and calculation definitions are recorded in our shared mission.').join('\n\n')}',
            ),
          );
          await session.refresh();
          await tester.pumpAndSettle();
          await _settleGroupMarkdown(tester);
          transcript.jumpTo(transcript.position.maxScrollExtent);
          await tester.pumpAndSettle();
          await _settleGroupMarkdown(tester);
          for (
            var frame = 0;
            frame < 30 && transcript.position.isScrollingNotifier.value;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          final viewport = tester.getRect(
            find.byKey(const ValueKey('profile-transcript')),
          );
          final visibleMessages =
              find
                  .byType(BotGroupMessage)
                  .evaluate()
                  .where(
                    (element) => tester
                        .getRect(find.byWidget(element.widget))
                        .overlaps(viewport),
                  )
                  .toList()
                ..sort(
                  (a, b) => tester
                      .getRect(find.byWidget(a.widget))
                      .top
                      .compareTo(tester.getRect(find.byWidget(b.widget)).top),
                );
          final visibleMessage = visibleMessages.first;
          final anchor = find.byKey(visibleMessage.widget.key!);
          final before = tester.getRect(anchor);
          fixture.events.add(
            _event(
              5,
              'message.member',
              'atlas',
              'Another reply while you read earlier messages.',
            ),
          );
          await session.refresh();
          await tester.pumpAndSettle();
          await _settleGroupMarkdown(tester);
          expect(tester.getRect(anchor).top, closeTo(before.top, 1));
          expect(find.byTooltip('New activity'), findsOneWidget);
          await _render(tester, frame, 'reading-${brightness.name}-$scale');
          await tester.tap(find.byTooltip('New activity'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 70));
          expect(transcript.offset, greaterThan(0));
          expect(
            transcript.offset,
            lessThan(transcript.position.maxScrollExtent),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey(('group-message', 5))),
            findsOneWidget,
          );
          expect(transcript.offset, closeTo(0, .01));
          await _render(tester, frame, 'draft-${brightness.name}-$scale');
          fixture.sendLost = true;
          fixture.readHook = (_, method, _) async {
            if (method == 'groups.log') throw StateError('History unavailable');
            return null;
          };
          await tester.tap(send);
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(input).readOnly, isTrue);
          expect(controller.text, 'Review @Atlas this evidence');
          expect(find.byTooltip('Retry same message'), findsOneWidget);
          expect(find.byType(ActionChip), findsNothing);
          final recovery = find.widgetWithText(
            StudioError,
            'Message not confirmed. Retry sends the same message once.',
          );
          expect(recovery, findsOneWidget);
          await _render(tester, frame, 'uncertain-${brightness.name}-$scale');
          keyboard.value = true;
          await tester.pumpAndSettle();
          expect(recovery.hitTestable(), findsOneWidget);
          expect(
            find.byTooltip('Retry same message').hitTestable(),
            findsOneWidget,
          );
          await _render(
            tester,
            frame,
            'uncertain-keyboard-${brightness.name}-$scale',
          );
          keyboard.value = false;
          await tester.pumpAndSettle();
          fixture.readHook = null;
          await tester.tap(find.byTooltip('Retry same message'));
          await tester.pumpAndSettle();
          expect(controller.text, isEmpty);
          expect(
            fixture.commands.where((command) => command.$2 == 'groups.send'),
            hasLength(2),
          );
          expect(
            fixture.events.where((event) => event['kind'] == 'message.user'),
            hasLength(2),
          );
          final details = find.byKey(
            const ValueKey('connection-status-target'),
          );
          final standardDetails = tester.getRect(details);
          keyboard.value = true;
          await tester.enterText(
            input,
            List.filled(8, 'Please review the evidence.').join('\n'),
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(send).bottom, lessThanOrEqualTo(844 - 280));
          expect(details, findsOneWidget);
          expect(tester.getRect(details), standardDetails);
          expect(tester.takeException(), isNull);
          await _render(tester, frame, 'keyboard-${brightness.name}-$scale');
          await tester.pumpWidget(const SizedBox());
        },
      );
      testWidgets('group status and members ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = BotsFixture();
        fixture.events.addAll([
          _event(
            1,
            'message.member',
            'atlas',
            '@bot_mira, I’m checking the evidence before the build. ${List.filled(20, 'The approved sources and calculation definitions are in our shared mission.').join(' ')}',
          ),
          _event(
            2,
            'message.user',
            'you',
            '@bot_atlas, please review this evidence and explain what I need to do next.',
          ),
        ]);
        final group = (await readFixtureGroups(
          fixture.repository,
          groupMessages: null,
        )).first;
        final appearances = await fixture.repository.bots();
        var working = true, approval = false;
        final initialRead = Completer<void>();
        fixture.readHook = (profile, method, params) async {
          if (method != 'groups.state') return null;
          await initialRead.future;
          return {
            'room': fixture.room,
            'driver_status': {
              'working': working,
              'blocked': approval,
              'pending_actions': approval
                  ? [
                      {
                        'kind': 'approval',
                        'task_id': 'task-1',
                        'member_id': 'atlas',
                        'request_id': 'approval-1',
                        'execution_generation': 1,
                        'approval': {
                          'command': 'build',
                          'choices': ['once', 'deny'],
                        },
                      },
                    ]
                  : [],
            },
          };
        };
        final connectionStatus = ServerConnectionStatus(group.instance)
          ..accessAvailable()
          ..liveChanged('discussion', true);
        addTearDown(connectionStatus.dispose);
        WorkspacePickerMode? pickedMode;
        final frame = GlobalKey();
        final reduced = ValueNotifier<bool>(false);
        addTearDown(reduced.dispose);
        late BotGroupSession session;
        await tester.pumpWidget(
          RepaintBoundary(
            key: frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => ValueListenableBuilder<bool>(
                valueListenable: reduced,
                builder: (context, value, _) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: value,
                  ),
                  child: ServerConnectionScope(
                    status: connectionStatus,
                    icon: ConnectionIcon.cloud,
                    onPickWorkspace: (_, {required mode}) => pickedMode = mode,
                    child: child!,
                  ),
                ),
              ),
              home: BotGroupScreen(
                stopVoicePlayback: () async {},
                voiceInputSettings: () =>
                    const LocalVoiceInputSettings(language: ''),
                createSession: () => session = BotGroupSession(
                  fixture.repository,
                  group,
                  reads: BotGroupReadState(),
                  preferences: groupPreferences,
                  groupMessages: null,
                  appearances: FixedGroupAppearances(appearances),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.text('Loading history…'), findsNothing);
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(find.bySemanticsLabel('Loading history'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await _render(tester, frame, 'loading-${brightness.name}-$scale');
        initialRead.complete();
        await _settleGroupMarkdown(tester);
        await _settleGroupMarkdown(tester);
        expect(find.text('Bots are working…'), findsOneWidget);
        expect(find.byType(ConversationActivityStatus), findsOneWidget);
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(find.byTooltip('Refresh group'), findsNothing);
        expect(find.byTooltip('Stop group work'), findsOneWidget);
        expect(find.byType(ComposerIconButton), findsOneWidget);
        expect(find.text('R'), findsNothing);
        final identity = find.byType(ServerConnectionLabel);
        expect(identity, findsOneWidget);
        expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
        expect(find.text(group.instance), findsOneWidget);
        expect(find.text('${group.instance} · 2 bots'), findsNothing);
        final led = find.byKey(const ValueKey('server-connection-led'));
        expect(led, findsOneWidget);
        Color ledColor() =>
            (tester.widget<Container>(led).decoration! as BoxDecoration).color!;
        final context = tester.element(identity);
        expect(ledColor(), WingTokens.of(context).success);
        connectionStatus.accessFailed(const SocketException('Offline'));
        connectionStatus.liveChanged('discussion', false);
        await tester.pump();
        expect(ledColor(), WingTokens.of(context).danger);
        await tester.tap(
          find.byKey(const ValueKey('connection-status-target')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Disconnected'), findsOneWidget);
        expect(
          find.byKey(const ValueKey(('group-member', 'atlas'))),
          findsNothing,
        );
        await tester.tap(find.byTooltip('Close connection details'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        connectionStatus.accessAvailable();
        connectionStatus.liveChanged('discussion', true);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('workspace-picker-target')));
        await tester.pump();
        expect(pickedMode, WorkspacePickerMode.connections);
        final memberButton = find.byKey(const ValueKey('group-members-entry'));
        expect(tester.getSize(memberButton).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(memberButton).height, greaterThanOrEqualTo(48));
        expect(
          tester.widget<IconButton>(memberButton).tooltip,
          'Show group members · 2 bots',
        );
        await _render(tester, frame, 'working-${brightness.name}-$scale');
        await tester.tap(find.byTooltip('Group options'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(find.text('Bot working histories'), findsNothing);
        expect(find.byIcon(Icons.pending_outlined), findsNothing);
        expect(
          find.descendant(
            of: find.byType(ConversationActivityStatus),
            matching: find.byType(CustomPaint),
          ),
          findsOneWidget,
        );
        await _render(tester, frame, 'working-menu-${brightness.name}-$scale');
        await tester.tapAt(const Offset(4, 220));
        await tester.pump();
        expect(find.byIcon(Icons.pending_outlined), findsNothing);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(find.byType(StudioLoading), findsOneWidget);

        final transcript = tester
            .widget<ListView>(find.byKey(const ValueKey('profile-transcript')))
            .controller!;
        transcript.jumpTo(transcript.position.maxScrollExtent);
        await tester.pump();
        await _settleGroupMarkdown(tester);
        for (
          var frame = 0;
          frame < 30 && transcript.position.isScrollingNotifier.value;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(transcript.position.isScrollingNotifier.value, isFalse);
        final readingAnchor = find.byKey(const ValueKey(('group-message', 1)));
        final readingTop = tester.getRect(readingAnchor).top;
        final readingOffset = transcript.offset;
        expect(
          readingOffset,
          greaterThanOrEqualTo(80),
          reason:
              'The fixture must be reading older history, outside the latest-follow threshold.',
        );
        approval = true;
        await session.refresh();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.getRect(readingAnchor).top, closeTo(readingTop, 1));
        expect(find.text('Waiting for your approval'), findsOneWidget);
        expect(find.byType(ShaderMask), findsNothing);
        expect(find.byType(StudioLoading), findsNothing);
        await tester.tap(find.byKey(const ValueKey('jump-to-latest')));
        await tester.pump();
        await _settleGroupMarkdown(tester);
        expect(find.text('Review command'), findsOneWidget);
        await _render(tester, frame, 'approval-${brightness.name}-$scale');
        approval = false;
        await session.refresh();
        await tester.pump(const Duration(milliseconds: 300));
        reduced.value = true;
        await tester.pump();
        await tester.pump();
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(find.text('Bots are working…'), findsOneWidget);
        reduced.value = false;
        await tester.pump();
        final input = find.byKey(const ValueKey('group-message-composer'));
        await tester.enterText(input, 'Keep this draft');
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byTooltip('Send group message'), findsOneWidget);
        final entry = find.byKey(const ValueKey('group-members-entry'));
        final anchorRect = tester.getRect(entry);
        await tester.tap(entry);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(Dialog), findsNothing);
        final atlas = find.byKey(const ValueKey(('group-member', 'atlas')));
        final mira = find.byKey(const ValueKey(('group-member', 'mira')));
        expect(
          find.descendant(of: atlas, matching: find.text('Atlas')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: mira, matching: find.text('Mira')),
          findsOneWidget,
        );
        final firstRect = tester.getRect(atlas);
        expect(firstRect.top, greaterThanOrEqualTo(anchorRect.bottom));
        expect(firstRect.left, greaterThanOrEqualTo(0));
        expect(
          firstRect.right,
          lessThanOrEqualTo(tester.view.physicalSize.width),
        );
        expect(atlas.hitTestable(), findsOneWidget);
        expect(mira.hitTestable(), findsOneWidget);
        expect(find.text('Group members'), findsNothing);
        await _render(tester, frame, 'members-${brightness.name}-$scale');
        await tester.tapAt(const Offset(10, 500));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(atlas, findsNothing);
        await tester.tap(entry);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(atlas, findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(atlas, findsNothing);
        await tester.tap(find.byTooltip('Group options'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Group members'), findsNothing);
        expect(find.text('Refresh group'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widget<TextField>(input).controller!.text,
          'Keep this draft',
        );
        expect(fixture.commands, isEmpty);
        final sending = Completer<void>();
        fixture.commandHook = (profile, method, params) async {
          if (method == 'groups.send') await sending.future;
          return null;
        };
        await tester.tap(find.byTooltip('Send group message'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Sending message…'), findsNothing);
        expect(find.text('Bots are working…'), findsOneWidget);
        expect(tester.widget<TextField>(input).readOnly, isTrue);
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(ComposerIconButton),
            matching: find.byType(StudioLoading),
          ),
          findsNothing,
        );
        await _render(tester, frame, 'sending-${brightness.name}-$scale');
        sending.complete();
        await _settleGroupMarkdown(tester);
        working = false;
        await session.refresh();
        await tester.pumpAndSettle();
        expect(find.text('Bots are working…'), findsNothing);
        expect(find.byType(StudioLoading), findsNothing);
        expect(session.sending, isFalse);
        expect(session.pendingText, isNull);
        final idleSending = Completer<void>();
        fixture.commandHook = (profile, method, params) async {
          if (method == 'groups.send') {
            await idleSending.future;
            throw StateError('Synthetic send failure');
          }
          return null;
        };
        await tester.enterText(input, 'Message from idle group');
        await tester.pump(const Duration(milliseconds: 300));
        final idleComposer = tester.getRect(input);
        await tester.tap(find.byTooltip('Send group message'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.text('Sending message…'), findsNothing);
        expect(session.sending, isTrue);
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(tester.getRect(input), idleComposer);
        await _render(tester, frame, 'idle-sending-${brightness.name}-$scale');
        idleSending.complete();
        await _settleGroupMarkdown(tester);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(StudioLoading), findsNothing);
        expect(
          find.widgetWithText(
            StudioError,
            'Message not confirmed. Retry sends the same message once.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
