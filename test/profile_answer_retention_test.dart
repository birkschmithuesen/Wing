import 'package:wing/core/models/transcript_presentation.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:wing/core/widgets/source_code_block.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/profile_message.dart';

import '../tools/performance/streaming_replay_fixture.dart';
import 'helpers/pump_markdown_widget.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_history_fixture.dart';

class _HistoryHost extends ProfileHistoryFixture {
  List<Map<String, dynamic>> rows = [
    {'id': 1, 'role': 'user', 'content': 'Request a mixed answer'},
  ];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => rows;
}

class _Rendering {
  _Rendering(WidgetTester tester, String source) {
    final answer = find.byWidgetPredicate(
      (widget) => widget is MarkdownMessageContent && widget.data == source,
    );
    expect(answer, findsOneWidget);
    message = tester.state(answer);
    List<State> descendants(Type type) => tester
        .elementList(find.descendant(of: answer, matching: find.byType(type)))
        .whereType<StatefulElement>()
        .map((element) => element.state)
        .toList();
    background = descendants(BackgroundMarkdownContent);
    code = descendants(SourceCodeBlock);
    selectable = descendants(SelectableText);
    expect(background, isNotEmpty);
    expect(code, isNotEmpty);
    expect(selectable, isNotEmpty);
    for (final state in background.cast<BackgroundMarkdownContentState>()) {
      expect(state.pending, isFalse);
      expect(state.renderedSource, state.widget.data);
    }
  }

  late final State message;
  late final List<State> background;
  late final List<State> code;
  late final List<State> selectable;

  void expectRetainedBy(_Rendering next) {
    expect(next.message, same(message));
    for (final state in [...background, ...code, ...selectable]) {
      expect(state.mounted, isTrue);
    }
    expect(next.background, orderedEquals(background));
    expect(next.code, orderedEquals(code));
    // Completion can add a new paragraph; existing closed blocks stay mounted.
    for (final state in selectable) {
      expect(
        next.selectable.any((candidate) => identical(candidate, state)),
        isTrue,
      );
    }
  }
}

Future<
  ({ProfileWorkspaceController controller, ProfileChat chat, _HistoryHost host})
>
_open(WidgetTester tester, String source) async {
  SharedPreferences.setMockInitialValues({});
  final host = _HistoryHost();
  final preferences = await SharedPreferences.getInstance();
  final appPreferences = AppPreferences(preferences);
  addTearDown(appPreferences.dispose);
  final controller = ProfileWorkspaceController(
    access: ConnectionAccess(
      connection: identityTestConnection(),
      dashboardOAuth: null,
    ),
    connectionIdentity: 'answer-retention',
    preferences: preferences,
    appPreferences: appPreferences,
    gatewayFactory: host.gateway,
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  final chat = await openFixtureChat(
    controller: controller,
    key: ProfileSessionKey(controller.current!.scope, 'chat-0'),
    title: 'Mixed response',
  );

  await controller.refreshHistory(chat);
  emitChatEvent(controller, chat, 'message.start');
  chat.reading.updateStreaming(source);
  tester.view.physicalSize = const Size(360, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  return (controller: controller, chat: chat, host: host);
}

Widget _screen(
  ProfileWorkspaceController controller,
  ProfileChat chat, {
  ThemeData? theme,
  FocusNode? draftFocus,
  TextEditingController? draft,
}) => MaterialApp(
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: Scaffold(
    body: Column(
      children: [
        Expanded(
          child: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => ProfileTranscript(
              key: ValueKey(chat.key),
              presentation: TranscriptPresentation.capture(
                identity: chat.key,
                reader: chat.reading,
                timeline: TranscriptTimeline.project(
                  [...chat.reading.messages, ?chat.reading.streamingMessage],
                  presentationId: chat.reading.messagePresentationId,
                  liveMessageIndex: chat.reading.streamingMessage == null
                      ? null
                      : chat.reading.messages.length,
                ),
                needsInput: chat.runtime.needsInput,
                turnAdmissionBlocked: chat.runtime.blocksTurnAdmission,
              ),
              openingContent: chat.runtime.opening
                  ? ProfileTranscriptOpening(
                      status: controller.connectionStatus,
                      error: chat.runtime.openingError,
                      onRetry: controller.resumeConnection,
                    )
                  : null,
              notificationReading: chat.reading,
              onAnswerRead: (target) =>
                  controller.notificationAnswerRead(chat, target),
              onRefreshHistory: () => controller.refreshHistory(chat),
              onLoadOlder: () => controller.loadOlderMessages(chat),
              messageBuilder: (row) => ProfileMessage(message: row.message),
              tail: const [],
            ),
          ),
        ),
        if (draft != null)
          TextField(
            key: const ValueKey('answer-retention-draft'),
            controller: draft,
            focusNode: draftFocus,
          ),
      ],
    ),
  ),
);

String _mixedSource() =>
    '${List.generate(8, streamingReplaySection).join()}'
    'A closed paragraph remains selectable.\n\n';

void main() {
  testWidgets(
    'completion and confirmed history retain the same answer rendering',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final host = _HistoryHost();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'answer-retention',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final chat = await openFixtureChat(
        controller: controller,
        key: ProfileSessionKey(controller.current!.scope, 'chat-0'),
        title: 'Mixed response',
      );

      await controller.refreshHistory(chat);
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = _mixedSource();
      const finalParagraph =
          'Final extra tokens are available after completion.';
      final finalSource = '$source$finalParagraph';
      emitChatEvent(controller, chat, 'message.start');
      chat.reading.updateStreaming(source);
      final draft = TextEditingController(text: 'Fresh composer text');
      final draftFocus = FocusNode();
      addTearDown(draft.dispose);
      addTearDown(draftFocus.dispose);
      Widget screen() =>
          _screen(controller, chat, draft: draft, draftFocus: draftFocus);
      await tester.pumpWidget(screen());
      await tester.settleMarkdown();
      draftFocus.requestFocus();
      await tester.pump();
      final draftState = tester.state(
        find.byKey(const ValueKey('answer-retention-draft')),
      );
      final lastCode = find.byType(SourceCodeBlock).last;
      final wrap = find.descendant(
        of: lastCode,
        matching: find.byTooltip('Scroll horizontally'),
      );
      await tester.ensureVisible(wrap);
      await tester.pump();
      await tester.tap(wrap);
      await tester.pump();
      draftFocus.requestFocus();
      await tester.pump();
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('profile-transcript')))
          .controller!;
      scroll.jumpTo(64);
      await tester.pump();
      final readingPosition = tester.getTopLeft(lastCode).dy;
      final initial = _Rendering(tester, source);

      final historyGate = Completer<void>();
      host.rows = [
        host.rows.first,
        {'id': 2, 'role': 'assistant', 'content': finalSource},
      ];
      host.historyDelays[('chat-0', 0)] = historyGate;
      addTearDown(() {
        if (!historyGate.isCompleted) historyGate.complete();
      });
      controller.current!.gateway.onEvent!(
        StreamEvent(
          type: 'message.complete',
          sessionId: chat.runtime.runtimeId,
          data: {'status': 'completed', 'text': finalSource},
        ),
      );
      await tester.pump();
      await tester.settleMarkdown();
      expect(chat.reading.streaming, isEmpty);
      expect(chat.reading.messages.last['id'], isNull);
      expect(chat.reading.messages.last['content'], finalSource);
      expect(find.text(finalParagraph, findRichText: true), findsOneWidget);
      initial.expectRetainedBy(_Rendering(tester, finalSource));
      for (final state
          in initial.background.cast<BackgroundMarkdownContentState>()) {
        expect(state.widget.streaming, isFalse);
      }
      expect(tester.getTopLeft(lastCode).dy, closeTo(readingPosition, 1));
      expect(
        find.descendant(
          of: find.byType(SourceCodeBlock).last,
          matching: find.byTooltip('Wrap lines'),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(screen());
      await tester.pump();
      await tester.settleMarkdown();
      initial.expectRetainedBy(_Rendering(tester, finalSource));
      expect(tester.getTopLeft(lastCode).dy, closeTo(readingPosition, 1));

      historyGate.complete();
      for (
        var attempt = 0;
        attempt < 200 && chat.reading.historyLoading;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(chat.reading.historyLoading, isFalse);
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages.last['id'], 2);
      await tester.settleMarkdown();
      initial.expectRetainedBy(_Rendering(tester, finalSource));
      expect(tester.getTopLeft(lastCode).dy, closeTo(readingPosition, 1));

      await tester.pumpWidget(screen());
      await tester.pump();
      await tester.settleMarkdown();
      initial.expectRetainedBy(_Rendering(tester, finalSource));
      expect(find.text(finalParagraph, findRichText: true), findsOneWidget);
      expect(draft.text, 'Fresh composer text');
      expect(draftFocus.hasFocus, isTrue);
      expect(
        tester.state(find.byKey(const ValueKey('answer-retention-draft'))),
        same(draftState),
      );
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
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
      final copy = find.descendant(
        of: find.byType(SourceCodeBlock).last,
        matching: find.byTooltip('Copy code'),
      );
      await tester.ensureVisible(copy);
      await tester.pump();
      await tester.tap(copy);
      await tester.pump();
      expect(clipboard.single, contains('final synthetic7 = 7;'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('width and theme changes refresh the retained answer correctly', (
    tester,
  ) async {
    final source = _mixedSource();
    final fixture = await _open(tester, source);
    await tester.pumpWidget(_screen(fixture.controller, fixture.chat));
    await tester.settleMarkdown();
    final initial = _Rendering(tester, source);

    tester.view.physicalSize = const Size(480, 760);
    await tester.pumpWidget(
      _screen(fixture.controller, fixture.chat, theme: ThemeData.dark()),
    );
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    final refreshed = _Rendering(tester, source);
    expect(refreshed.message, same(initial.message));
    expect(refreshed.background, orderedEquals(initial.background));
    expect(refreshed.code, orderedEquals(initial.code));
    final closing = find.text(
      'A closed paragraph remains selectable.',
      findRichText: true,
    );
    expect(closing, findsOneWidget);
    expect(Theme.of(tester.element(closing)).brightness, Brightness.dark);
    expect(MediaQuery.sizeOf(tester.element(closing)).width, 480);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a later assistant message and different chat keep distinct rendering',
    (tester) async {
      final source = _mixedSource();
      final fixture = await _open(tester, source);
      await tester.pumpWidget(_screen(fixture.controller, fixture.chat));
      await tester.settleMarkdown();
      final original = _Rendering(tester, source);
      // An interim answer is durable while the same turn starts fresh prose.
      fixture.controller.current!.gateway.onEvent!(
        StreamEvent(
          type: 'message.interim',
          sessionId: fixture.chat.runtime.runtimeId,
          data: stockChatReply(
            fixture.controller.current!.gateway,
            'message.interim',
            {'text': source},
          ),
        ),
      );
      await tester.pump();
      await tester.settleMarkdown();
      original.expectRetainedBy(_Rendering(tester, source));
      final nextSource =
          '${streamingReplaySection(21)}A distinct later answer.';
      fixture.controller.current!.gateway.onEvent!(
        StreamEvent(
          type: 'message.delta',
          sessionId: fixture.chat.runtime.runtimeId,
          data: stockChatReply(
            fixture.controller.current!.gateway,
            'message.delta',
            {'text': nextSource},
          ),
        ),
      );
      await tester.pump();
      await tester.settleMarkdown();
      final next = _Rendering(tester, nextSource);
      expect(next.message, isNot(same(original.message)));
      expect(
        find.text('A distinct later answer.', findRichText: true),
        findsOneWidget,
      );

      final other = await openFixtureChat(
        controller: fixture.controller,
        key: ProfileSessionKey(fixture.controller.current!.scope, 'other-chat'),
        title: 'Different conversation',
      );
      // Deliberately equal source text must not transfer renderer ownership.
      emitChatEvent(fixture.controller, other, 'message.start');
      other.reading.updateStreaming(nextSource);

      await tester.pumpWidget(_screen(fixture.controller, other));
      await tester.settleMarkdown();
      final switched = _Rendering(tester, nextSource);
      expect(switched.message, isNot(same(next.message)));
      expect(next.message.mounted, isFalse);
      expect(
        find.text('A distinct later answer.', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'previewed final retains the interim renderer without duplication',
    (tester) async {
      final source = _mixedSource();
      final fixture = await _open(tester, source);
      await tester.pumpWidget(_screen(fixture.controller, fixture.chat));
      await tester.settleMarkdown();
      final initial = _Rendering(tester, source);
      fixture.controller.current!.gateway.onEvent!(
        StreamEvent(
          type: 'message.interim',
          sessionId: fixture.chat.runtime.runtimeId,
          data: stockChatReply(
            fixture.controller.current!.gateway,
            'message.interim',
            {'text': source},
          ),
        ),
      );
      await tester.pump();
      await tester.settleMarkdown();
      initial.expectRetainedBy(_Rendering(tester, source));
      final interim = fixture.chat.reading.messages.last;
      final interimToken = fixture.chat.reading.messagePresentationId(interim);
      final retainedInterim = Map<String, dynamic>.from(interim);
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      fixture.host.rows = [
        fixture.host.rows.first,
        {'id': 2, 'role': 'assistant', 'content': source},
      ];
      fixture.host.historyDelays[('chat-0', 0)] = gate;
      fixture.controller.current!.gateway.onEvent!(
        StreamEvent(
          type: 'message.complete',
          sessionId: fixture.chat.runtime.runtimeId,
          data: {
            'text': source,
            'response_previewed': true,
            // Current-stock receipts can prove the final row independently of
            // whether persistence of the entire turn was complete.
            'persisted_turn': {
              'complete': false,
              'final_assistant_row_id': 2,
              'row_ids': [2],
            },
          },
        ),
      );
      await tester.pump();
      await tester.settleMarkdown();
      expect(fixture.chat.runtime.blocksTurnAdmission, isFalse);
      expect(
        fixture.chat.reading.messagePresentationId(
          fixture.chat.reading.messages.last,
        ),
        same(interimToken),
      );
      expect(interim, retainedInterim);
      expect(interim['content'], source);
      expect(
        fixture.chat.reading.messages.where(
          (row) => row['role'] == 'assistant',
        ),
        hasLength(1),
      );
      initial.expectRetainedBy(_Rendering(tester, source));
      gate.complete();
      for (
        var attempt = 0;
        attempt < 200 && fixture.chat.reading.historyLoading;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(fixture.chat.reading.historyLoading, isFalse);
      expect(fixture.chat.reading.historyError, isNull);
      expect(fixture.chat.reading.messages.last['id'], 2);
      expect(
        fixture.chat.reading.messages.where(
          (row) => row['role'] == 'assistant',
        ),
        hasLength(1),
      );
      await tester.settleMarkdown();
      initial.expectRetainedBy(_Rendering(tester, source));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
