import 'package:wing/core/models/transcript_position.dart';
import 'package:wing/core/models/transcript_presentation.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/services/chat_runtime.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:wing/core/models/chat_runtime.dart' as facts;
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/services/profile_supervision_session.dart';
import 'package:wing/core/widgets/conversation_activity.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'dart:ui' as ui;
import 'package:wing/core/models/transcript_reading.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/gateway_sensitive_prompt.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_activity_tabs.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/widgets/playful_portrait.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'helpers/pump_markdown_widget.dart';
import 'support/profile_history_fixture.dart';

void main({Future<void> Function(WidgetTester, String)? capture}) {
  const historyCapture = bool.fromEnvironment('CAPTURE_TRANSCRIPT_HISTORY');
  const captureKey = ValueKey('retained-history-capture');
  setUpAll(() async {
    if (!historyCapture) return;
    const fontDirectory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': '$fontDirectory/Roboto-Regular.ttf',
      'MaterialIcons': '$fontDirectory/MaterialIcons-Regular.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(await File(entry.value).readAsBytes()),
            ),
          ))
          .load();
    }
  });
  late ProfileWorkspaceController controller;
  late WorkspaceRuntimeFixture runtimes;
  late AppPreferences appPreferences;
  late ProfileHistoryFixture host;
  late ProfileChat chat;
  late ChatRuntime runtime;
  Future<void> Function()? loadOlder;
  var tailHeight = 0.0;
  var reducedMotion = false;
  var realisticMessages = false;
  List<Widget> currentActivity = [];
  List<Widget> extraTail = [];
  final list = find.byKey(const ValueKey('profile-transcript'));
  final jump = find.byKey(const ValueKey('jump-to-latest'));
  final thoughtHeader = find.descendant(
    of: find.byType(ListTile),
    matching: find.text('Reasoning'),
  );

  Map<String, dynamic> row(int id) => {
    'id': id,
    'role': 'assistant',
    'content': 'Message $id',
  };
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    runtimes = WorkspaceRuntimeFixture();
    host = ProfileHistoryFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'transcript-test',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      runtimeFactory: runtimes.create,
    );
    await controller.initialize();

    chat = await openFixtureChat(
      controller: controller,
      key: ProfileSessionKey(controller.current!.scope, 'chat-0'),
      title: 'Read-only test',
    );
    runtime = runtimes.forChat(chat);

    await controller.refreshHistory(chat);
    loadOlder = null;
    tailHeight = 0;
    reducedMotion = false;
    realisticMessages = false;
    currentActivity = [];
    extraTail = [];
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> show(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1,
    Size? surfaceSize,
  }) async {
    if (tester.binding is AutomatedTestWidgetsFlutterBinding) {
      tester.view.physicalSize = surfaceSize ?? const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: profileWorkspaceTheme(wingTheme(brightness)),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reducedMotion,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(actions: const [StudioLoadingSlot()]),
            body: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => ProfileTranscript(
                key: ValueKey(chat.key),
                presentation: TranscriptPresentation.capture(
                  identity: chat.key,
                  reader: chat.reading,
                  timeline: TranscriptTimeline.project(
                    [...chat.reading.messages, ?chat.reading.streamingMessage],
                    requestActivities: chat.reading.requestActivities,
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
                onLoadOlder:
                    loadOlder ?? () => controller.loadOlderMessages(chat),
                messageBuilder: (m) => realisticMessages
                    ? ProfileMessage(message: m.message)
                    : SizedBox(
                        key: ValueKey('body-${m.message.id}'),
                        height: 60 + ((m.message.id as int?) ?? 0) % 3 * 20,
                        child: Text(m.message.text),
                      ),
                tail: [
                  if (currentActivity.isNotEmpty)
                    ProfileActivitySection(
                      label: 'Activity',
                      detailsBuilder: (_) => Column(children: currentActivity),
                    ),
                  if (tailHeight > 0) SizedBox(height: tailHeight),
                  ...extraTail,
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> captureHistory(WidgetTester tester, String name) async {
    if (capture != null) await capture(tester, name);
    if (!historyCapture) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final target = File(
          'build/design-previews/retained-history/site/renders/$name.png',
        );
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('confirmed empty history refresh keeps its greeting '
          '${brightness.name} $scale', (tester) async {
        host.messageCount = 0;
        await controller.refreshHistory(chat);
        expect(chat.reading.historySessionId, isNotNull);
        await show(tester, brightness: brightness, scale: scale);
        final greeting = find.byType(PlayfulPortrait);
        final greetingRect = tester.getRect(greeting);
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        host.messageCount = 1;
        host.historyDelays[('chat-0', 0)] = gate;
        final refreshing = controller.refreshHistory(chat);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(chat.reading.historyLoading, isTrue);
        expect(chat.reading.messages, isEmpty);
        expect(greeting, findsOneWidget);
        expect(tester.getRect(greeting), greetingRect);
        expect(find.text('Start a conversation'), findsOneWidget);
        expect(find.byType(StudioLoading), findsNothing);
        await captureHistory(tester, 'empty-${brightness.name}-$scale');
        gate.complete();
        await refreshing;
        await tester.pumpAndSettle();
        expect(greeting, findsNothing);
        expect(find.text('personal message 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('retained history refresh stays quiet and interactive '
          '${brightness.name} $scale', (tester) async {
        host.messageCount = 2;
        await controller.refreshHistory(chat);
        var taps = 0;
        extraTail = [
          TextButton(
            onPressed: () => taps++,
            child: const Text('Transcript action'),
          ),
        ];
        await show(tester, brightness: brightness, scale: scale);
        final viewport = tester.getRect(list);
        final second = find.byKey(const ValueKey('body-2'));
        final messageRect = tester.getRect(second);
        final edgeRect = tester.getRect(find.text('Start of loaded history'));
        expect(viewport.contains(edgeRect.center), isTrue);
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        host.messageCount = 3;
        host.historyDelays[('chat-0', 0)] = gate;
        final refreshing = controller.refreshHistory(chat);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(chat.reading.historyLoading, isTrue);
        expect(chat.reading.historyPaging, isFalse);
        expect(chat.reading.messages, hasLength(2));
        expect(tester.getRect(second), messageRect);
        expect(tester.getRect(find.text('Start of loaded history')), edgeRect);
        expect(find.byType(StudioLoading), findsNothing);
        await tester.tap(find.text('Transcript action'));
        await tester.pump();
        expect(taps, 1);
        await captureHistory(tester, 'retained-${brightness.name}-$scale');
        gate.complete();
        await refreshing;
        await tester.pumpAndSettle();
        expect(chat.reading.historyLoading, isFalse);
        expect(find.text('personal message 3'), findsOneWidget);
        expect(find.byType(StudioLoading), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets(
    'older history keeps its blocked-action pulse and accessible name',
    (tester) async {
      await show(tester);
      final offset = chat.reading.nextHistoryOffset!;
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      host.historyDelays[('chat-0', offset)] = gate;
      final older = controller.loadOlderMessages(chat);
      final scroll = tester.widget<ListView>(list).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(chat.reading.historyPaging, isTrue);
      expect(find.bySemanticsLabel('Loading history'), findsOneWidget);
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(StudioLoading),
          matching: find.byType(AppBar),
        ),
        findsOneWidget,
      );
      expect(find.text('Load older messages'), findsOneWidget);
      gate.complete();
      await older;
      await tester.pumpAndSettle();
      expect(chat.reading.historyPaging, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a fresh retained-history refresh supersedes blocked paging feedback',
    (tester) async {
      host.messageCount = 2;
      await controller.refreshHistory(chat);
      await show(tester);
      host.messageCount = 620;
      await controller.refreshHistory(chat);
      final olderGate = Completer<void>();
      final refreshGate = Completer<void>();
      addTearDown(() {
        if (!olderGate.isCompleted) olderGate.complete();
        if (!refreshGate.isCompleted) refreshGate.complete();
      });
      host.historyDelays[('chat-0', chat.reading.nextHistoryOffset!)] =
          olderGate;
      final older = controller.loadOlderMessages(chat);
      expect(chat.reading.historyPaging, isTrue);
      host.historyDelays[('chat-0', 0)] = refreshGate;
      final refreshed = controller.refreshHistory(chat);
      await tester.pump();
      expect(chat.reading.historyLoading, isTrue);
      expect(chat.reading.historyPaging, isFalse);
      expect(find.byType(StudioLoading), findsNothing);
      olderGate.complete();
      await older;
      expect(chat.reading.historyLoading, isTrue);
      expect(chat.reading.historyPaging, isFalse);
      refreshGate.complete();
      await refreshed;
      await tester.pumpAndSettle();
      expect(chat.reading.historyLoading, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'older reads coalesce after layout without rebuilding during frame',
    (tester) async {
      final phases = <SchedulerPhase>[];
      loadOlder = () async {
        phases.add(SchedulerBinding.instance.schedulerPhase);
      };
      await show(tester);
      final scroll = tester.widget<ListView>(list).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent - 100);
      final context = tester.element(list);
      for (var request = 0; request < 2; request++) {
        ScrollEndNotification(
          metrics: scroll.position,
          context: context,
        ).dispatch(context);
      }
      expect(phases, isEmpty);
      await tester.pump();
      expect(phases, [SchedulerPhase.postFrameCallbacks]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('queued older read is revoked when the transcript is disposed', (
    tester,
  ) async {
    var reads = 0;
    loadOlder = () async {
      reads++;
    };
    await show(tester);
    final scroll = tester.widget<ListView>(list).controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent - 100);
    expect(reads, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(reads, 0);
    expect(tester.takeException(), isNull);
  });

  // This renderer fixture also varies local tail geometry and callback closures.
  // Rebuild its existing parent while retaining the transcript element/state.
  Future<void> rebuildPresentation(WidgetTester tester) async {
    tester
        .element(
          find
              .ancestor(
                of: find.byType(ProfileTranscript),
                matching: find.byType(ListenableBuilder),
              )
              .first,
        )
        .markNeedsBuild();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'completion and next stream retain activity selection, draft and callbacks',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      // This synthetic viewport also owns its keyboard geometry. Android's
      // physical keyboard inset can exceed the entire 760px test viewport.
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.reset);
      chat.reading.installSavedHistory([
        {'id': 1, 'role': 'user', 'content': 'Saved prompt'},
      ]);
      chat.reading.updateStreaming(
        List.generate(
          20,
          (index) =>
              'Readable paragraph $index: '
              'The answer stays in place while activity remains available.',
        ).join('\n\n'),
      );
      var callbackGeneration = 0;
      final callbacks = <String>[];
      final field = find.byKey(
        const ValueKey('retained-tail-draft'),
        skipOffstage: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (_, _) {
                final generation = callbackGeneration;
                return ProfileTranscript(
                  key: ValueKey(chat.key),
                  presentation: TranscriptPresentation.capture(
                    identity: chat.key,
                    reader: chat.reading,
                    timeline: TranscriptTimeline.project(
                      [
                        ...chat.reading.messages,
                        ?chat.reading.streamingMessage,
                      ],
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
                  onLoadOlder:
                      loadOlder ?? () => controller.loadOlderMessages(chat),
                  messageBuilder: (message) =>
                      ProfileMessage(message: message.message),

                  tail: [
                    ProfileActivityTabs(
                      key: const ValueKey('retained-activity-tabs'),
                      tabs: [
                        ProfileActivityTab(
                          id: 'tasks',
                          label: 'Tasks',
                          child: const Text('Task activity'),
                          onSelected: () => callbacks.add('g$generation:tasks'),
                        ),
                        ProfileActivityTab(
                          id: 'work',
                          label: 'Work',
                          child: const TextField(
                            key: ValueKey('retained-tail-draft'),
                          ),
                          onSelected: () => callbacks.add('g$generation:work'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.settleMarkdown();
      await tester.tap(find.byKey(const ValueKey(('activity-tab', 'work'))));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'Pending response');
      await tester.pump();
      final inputState = tester.state(field);
      expect(callbacks, ['g0:tasks', 'g0:work']);

      final marker = find.textContaining(
        'Readable paragraph 19:',
        findRichText: true,
      );
      // Opt out of bottom following while keeping the residual activity row
      // within the lazy list's mounted viewport/cache region.
      final scroll = tester.widget<ListView>(list).controller!;
      scroll.jumpTo(64);
      await tester.pumpAndSettle();
      expect(marker.hitTestable(), findsOneWidget);
      final before = tester.getTopLeft(marker).dy;
      callbackGeneration = 1;
      chat.reading.installSavedHistory([
        ...chat.reading.messages,
        {
          'id': 2,
          'role': 'assistant',
          'content':
              '${chat.reading.streaming}\n\nUnseen final paragraph one.'
              '\n\nUnseen final paragraph two.',
        },
      ]);
      chat.reading.updateStreaming('');
      tester
          .element(
            find
                .ancestor(
                  of: find.byType(ProfileTranscript),
                  matching: find.byType(ListenableBuilder),
                )
                .first,
          )
          .markNeedsBuild();
      await tester.pump();
      expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
      await tester.settleMarkdown();
      expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
      expect(
        find.text('Unseen final paragraph two.', findRichText: true),
        findsOneWidget,
      );
      expect(tester.state(field), same(inputState));
      expect(
        find.text('Pending response', skipOffstage: false),
        findsOneWidget,
      );
      expect(callbacks, ['g0:tasks', 'g0:work']);

      callbackGeneration = 2;
      chat.reading.updateStreaming(
        'A following answer begins.\n\nIts live tail grows.',
      );
      tester
          .element(
            find
                .ancestor(
                  of: find.byType(ProfileTranscript),
                  matching: find.byType(ListenableBuilder),
                )
                .first,
          )
          .markNeedsBuild();
      await tester.pump();
      await tester.settleMarkdown();
      expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
      expect(tester.state(field), same(inputState));
      expect(
        find.text('Pending response', skipOffstage: false),
        findsOneWidget,
      );
      expect(callbacks, ['g0:tasks', 'g0:work']);

      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      final beforeSelection = [...callbacks];
      final tasks = find.byKey(const ValueKey(('activity-tab', 'tasks')));
      await tester.tap(tasks);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey(('activity-tab', 'work'))));
      await tester.pumpAndSettle();
      expect(callbacks, [...beforeSelection, 'g2:tasks', 'g2:work']);
      expect(tester.state(field), same(inputState));
      expect(find.text('Pending response'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> showLiveActivity(
    WidgetTester tester, {
    required List<facts.ChatActivityEntry> entries,
    Future<void> Function(ChatOutput)? onShare,
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    final session = ProfileSupervisionSession(
      controller: controller,
      chat: chat,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: ProfileTranscript(
            presentation: TranscriptPresentation.capture(
              identity: chat.key,
              reader: chat.reading,
              timeline: TranscriptTimeline.project(
                const [],
                presentationId: chat.reading.messagePresentationId,
              ),
              needsInput: false,
              turnAdmissionBlocked: false,
            ),
            onRefreshHistory: () async {},
            messageBuilder: (entry) => ProfileMessage(message: entry.message),
            tail: const [],
            onShareResource: onShare,
            activity: ConversationActivity(
              runtime: chat.runtime,
              entries: entries,
              todos: const [],
              inspection: session,
              agentsBuilder: () => const SizedBox.shrink(),
              live: true,
              taskCount: 0,
              agentCount: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<facts.ChatActivityEntry> liveFile(String result) => [
    facts.ChatToolEntry(
      GatewayToolActivity(
        toolId: 'retained-file',
        name: 'read_file',
        phase: GatewayToolActivityPhase.completed,
        arguments: '{"path":"/tmp/retained.md"}',
        result: jsonEncode({'content': result}),
      ),
    ),
  ];

  Future<void> openLiveFile(WidgetTester tester) async {
    await tester.openLiveActivity();
    final tool = find.byWidgetPredicate(
      (widget) =>
          widget is ProfileToolCall && widget.call.callId == 'retained-file',
    );
    final header = find.descendant(of: tool, matching: find.byType(ListTile));
    expect(header, findsOneWidget);
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    expect(header.hitTestable(), findsOneWidget);
    await tester.tap(header);
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
  }

  testWidgets(
    'retained request Activity stays before the received saved answer',
    (tester) async {
      runtime.beginTurn(submitting: false);
      runtime.observeTool('tool.complete', {
        'tool_id': 'before',
        'name': 'terminal',
        'result': 'First result',
      });
      runtime.receiveApproval({
        'request_id': 'decision',
        'command': 'inspect source',
        'description': 'Allow inspection?',
      });
      final response = runtime.beginApprovalAnswer('decision', 'once');
      runtime.finishApprovalAnswer(response, 'decision', accepted: true);
      runtime.observeTool('tool.complete', {
        'tool_id': 'after',
        'name': 'terminal',
        'result': 'Second result',
      });
      runtime.completeTurn(failed: false, cancelled: false, error: null);
      final projection = ChatTranscriptProjection(
        savedRows: [
          {
            'id': 20,
            'role': 'tool',
            'tool_call_id': 'after',
            'tool_name': 'terminal',
            'content': 'Second result',
          },
          {
            'id': 21,
            'role': 'assistant',
            'content': 'The received final answer.',
          },
        ],
        streamingMessage: null,
        runtime: runtime.observation,
        presentationId: (row) => row['id']!,
        liveAnswering: false,
        requestActivities: chat.reading.requestActivities,
      );
      final inspection = ProfileSupervisionSession(
        controller: controller,
        chat: chat,
      );
      addTearDown(inspection.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: Scaffold(
            body: ProfileTranscript(
              presentation: TranscriptPresentation.capture(
                identity: chat.key,
                reader: chat.reading,
                timeline: projection.timeline,
                needsInput: false,
                turnAdmissionBlocked: false,
              ),
              onRefreshHistory: () async {},
              messageBuilder: (entry) => Text(entry.message.text),
              tail: const [],
              activity: ConversationActivity(
                runtime: runtime.observation,
                entries: projection.activity,
                beforeMessagePresentationId:
                    projection.retainedActivityBeforePresentationId,
                todos: const [],
                inspection: inspection,
                agentsBuilder: () => const SizedBox.shrink(),
                live: false,
                taskCount: 0,
                agentCount: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final activity = find.byKey(const ValueKey('live-activity-toggle'));
      expect(find.text('2 tools'), findsOneWidget);
      final answer = find.text('The received final answer.');
      expect(activity, findsOneWidget);
      expect(
        tester.getTopLeft(activity).dy,
        lessThan(tester.getTopLeft(answer).dy),
      );
      await tester.openLiveActivity();
      await tester.pumpAndSettle();
      final calls = tester
          .widgetList<ProfileToolCall>(find.byType(ProfileToolCall))
          .toList();
      expect(
        calls.map((widget) => widget.call.callId ?? widget.call.requestId),
        ['after', 'decision', 'before'],
      );
      expect(
        find.descendant(
          of: find.byType(ProfileActivityTimeline),
          matching: find.byType(ProfileToolCall),
        ),
        findsNWidgets(3),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retained live Activity shares through the current callback', (
    tester,
  ) async {
    final entries = liveFile('Received file content');
    final shared = <String>[];
    await showLiveActivity(
      tester,
      entries: entries,
      onShare: (output) async => shared.add('old:${output.path}'),
    );
    await openLiveFile(tester);
    await showLiveActivity(
      tester,
      entries: entries,
      onShare: (output) async => shared.add('current:${output.path}'),
    );
    final share = find.byTooltip('Share file');
    await tester.ensureVisible(share);
    await tester.pumpAndSettle();
    expect(share.hitTestable(), findsOneWidget);
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(shared, ['current:/tmp/retained.md']);
  });

  testWidgets(
    'live Activity removes sharing when the current route withdraws it',
    (tester) async {
      final entries = liveFile('Received file content');
      await showLiveActivity(tester, entries: entries, onShare: (_) async {});
      await openLiveFile(tester);
      await tester.ensureVisible(find.byTooltip('Share file'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Share file').hitTestable(), findsOneWidget);
      await showLiveActivity(tester, entries: entries);
      expect(find.byTooltip('Share file'), findsNothing);
    },
  );

  testWidgets(
    'live Activity replaces the received result for an existing tool',
    (tester) async {
      await showLiveActivity(tester, entries: liveFile('Earlier result'));
      await openLiveFile(tester);
      expect(find.text('Earlier result', findRichText: true), findsWidgets);
      await showLiveActivity(tester, entries: liveFile('Updated result'));
      expect(find.text('Earlier result', findRichText: true), findsNothing);
      await tester.settleMarkdown();
      expect(find.text('Updated result', findRichText: true), findsWidgets);
    },
  );

  testWidgets('live Activity replaces reasoning with the same identity', (
    tester,
  ) async {
    List<facts.ChatActivityEntry> reasoning(String text) => [
      facts.ChatReasoningEntry(
        identity: 'thought',
        text: text,
        source: 'event',
      ),
    ];
    await showLiveActivity(tester, entries: reasoning('Earlier reasoning'));
    await tester.settleMarkdown();
    expect(find.text('Earlier reasoning', findRichText: true), findsWidgets);
    await showLiveActivity(tester, entries: reasoning('Updated reasoning'));
    await tester.settleMarkdown();
    expect(find.text('Earlier reasoning', findRichText: true), findsNothing);
    expect(find.text('Updated reasoning', findRichText: true), findsWidgets);
  });

  testWidgets('empty greeting yields to messages and history states', (
    tester,
  ) async {
    chat.reading.installSavedHistory(const []);
    chat.reading.installSnapshot(
      TranscriptReadingSnapshot(
        messages: chat.reading.messages,
        historySessionId: null,
      ),
    );
    await show(tester);
    expect(find.byType(PlayfulPortrait), findsOneWidget);
    expect(find.text('Start a conversation'), findsOneWidget);

    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    host.historyDelays[('chat-0', 0)] = gate;
    host.failHistory = true;
    final loading = controller.refreshHistory(chat);
    expect(chat.reading.historyLoading, isTrue);
    await tester.pump();
    await tester.pump();
    expect(find.byType(PlayfulPortrait), findsNothing);
    expect(find.text('Loading history…'), findsNothing);
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.bySemanticsLabel('Loading history'), findsOneWidget);

    gate.complete();
    await loading;
    host.historyDelays.remove(('chat-0', 0));
    expect(chat.reading.historyLoading, isFalse);
    expect(chat.reading.historyError, isNotNull);
    await rebuildPresentation(tester);
    expect(find.byType(PlayfulPortrait), findsNothing);
    expect(find.text('Refresh history'), findsOneWidget);

    host.failHistory = false;
    host.messageCount = 0;
    await controller.refreshHistory(chat);
    expect(chat.reading.historyError, isNull);
    extraTail = [const Text('Live work')];
    await rebuildPresentation(tester);
    expect(find.byType(PlayfulPortrait), findsNothing);
    expect(find.text('Live work'), findsOneWidget);

    extraTail = [];
    chat.reading.installSavedHistory([row(500)]);
    await rebuildPresentation(tester);
    expect(find.byType(PlayfulPortrait), findsNothing);
    expect(find.text('Message 500'), findsOneWidget);
  });

  testWidgets('empty greeting scrolls within a short transcript viewport', (
    tester,
  ) async {
    chat.reading.installSavedHistory(const []);
    chat.reading.installSnapshot(
      TranscriptReadingSnapshot(
        messages: chat.reading.messages,
        historySessionId: chat.reading.historySessionId,
      ),
    );
    await show(tester);
    tester.view.physicalSize =
        const Size(320, 140) * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(PlayfulPortrait), findsOneWidget);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0));
  });

  Finder visibleRow(WidgetTester tester) {
    return find.byWidgetPredicate((w) {
      if (w.key is! ValueKey<String> ||
          !(w.key as ValueKey<String>).value.startsWith('body-')) {
        return false;
      }
      final y = tester.getTopLeft(find.byWidget(w)).dy;
      return y > 150 && y < 400;
    }).first;
  }

  Future<void> toggleInPlace(WidgetTester tester, Finder header) async {
    final before = tester.getTopLeft(header).dy;
    await tester.tapAt(
      Offset(tester.getRect(list).right - 32, tester.getCenter(header).dy),
    );
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(header).dy, closeTo(before, 1));
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, closeTo(before, 1));
  }

  testWidgets(
    '2500 variable-height rows stay lazy; older pages do not signal new activity',
    (tester) async {
      chat.reading.installSavedHistory(
        List.generate(2500, (i) => row(i + 100)),
      );
      chat.reading.installSnapshot(
        TranscriptReadingSnapshot(
          messages: chat.reading.messages,
          historySessionId: chat.reading.historySessionId,
        ),
      );
      await show(tester);
      expect(find.byKey(const ValueKey('body-100')), findsNothing);
      expect(find.byKey(const ValueKey('body-2599')), findsOneWidget);
      await tester.drag(list, const Offset(0, 440));
      await tester.pumpAndSettle();
      final anchor = tester.widget(visibleRow(tester)).key!;
      final before = tester.getTopLeft(find.byKey(anchor)).dy;
      chat.reading.installSavedHistory([
        ...List.generate(100, row),
        ...chat.reading.messages,
      ]);
      await rebuildPresentation(tester);
      expect(tester.getTopLeft(find.byKey(anchor)).dy, closeTo(before, 1));
      expect(find.byTooltip('Latest'), findsOneWidget);
      expect(find.byTooltip('New activity'), findsNothing);
      expect(find.byKey(const ValueKey('body-0')), findsNothing);
      expect(find.byKey(anchor).hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'a tall new streaming tail preserves the reader and marks new activity',
    (tester) async {
      await show(tester);
      await tester.drag(list, const Offset(0, 480));
      await tester.pumpAndSettle();
      final anchor = tester.widget(visibleRow(tester)).key!;
      final before = tester.getTopLeft(find.byKey(anchor)).dy;
      tailHeight = 1800;
      chat.reading.updateStreaming('New streaming output');
      await rebuildPresentation(tester);
      expect(find.byKey(anchor), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(anchor)).dy, closeTo(before, 2));
      expect(find.byTooltip('New activity'), findsOneWidget);
      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(chat.reading.readingPosition.resume, isNull);
      expect(jump, findsNothing);
      chat.reading.updateStreaming('More streaming output');
      tailHeight = 2000;
      await rebuildPresentation(tester);
      expect(chat.reading.readingPosition.resume, isNull);
      expect(jump, findsNothing);
    },
  );

  testWidgets('streaming updates do not cancel an active reader drag', (
    tester,
  ) async {
    tailHeight = 100;
    chat.reading.updateStreaming('Answer');
    await show(tester);
    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    final anchor = tester.widget(visibleRow(tester)).key!;
    final before = tester.getTopLeft(find.byKey(anchor)).dy;
    tailHeight += 40;
    chat.reading.appendStreaming(' more');
    tester
        .element(
          find
              .ancestor(
                of: find.byType(ProfileTranscript),
                matching: find.byType(ListenableBuilder),
              )
              .first,
        )
        .markNeedsBuild();
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(anchor)).dy, closeTo(before, 1));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(anchor)).dy, closeTo(before + 80, 1));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('streaming preserves fling momentum', (tester) async {
    tailHeight = 100;
    chat.reading.updateStreaming('Answer');
    await show(tester);
    await tester.fling(list, const Offset(0, 150), 800);
    await tester.pump(const Duration(milliseconds: 16));
    final scroll = tester.widget<ListView>(list).controller!;
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    tailHeight += 40;
    chat.reading.appendStreaming(' more');
    tester
        .element(
          find
              .ancestor(
                of: find.byType(ProfileTranscript),
                matching: find.byType(ListenableBuilder),
              )
              .first,
        )
        .markNeedsBuild();
    await tester.pump();
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    final before = scroll.offset;
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.offset, greaterThan(before));
    await tester.pumpAndSettle();
  });

  testWidgets('a small scroll away from latest opts out of streaming follow', (
    tester,
  ) async {
    tailHeight = 100;
    chat.reading.updateStreaming('Answer');
    await show(tester);
    final scroll = tester.widget<ListView>(list).controller!;
    scroll.jumpTo(10);
    await tester.pumpAndSettle();
    final anchor = tester.widget(visibleRow(tester)).key!;
    final before = tester.getTopLeft(find.byKey(anchor)).dy;
    tailHeight += 40;
    chat.reading.appendStreaming(' more');
    tester
        .element(
          find
              .ancestor(
                of: find.byType(ProfileTranscript),
                matching: find.byType(ListenableBuilder),
              )
              .first,
        )
        .markNeedsBuild();
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(anchor)).dy, closeTo(before, 1));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'reading inside a long streaming answer stays anchored on every frame',
    (tester) async {
      chat.reading.installSavedHistory([row(1)]);
      chat.reading.installSnapshot(
        TranscriptReadingSnapshot(
          messages: chat.reading.messages,
          historySessionId: chat.reading.historySessionId,
        ),
      );
      chat.reading.updateStreaming('Answer');
      extraTail = [
        Column(
          children: List.generate(
            100,
            (i) => SizedBox(height: 40, child: Text('Answer line $i')),
          ),
        ),
      ];
      await show(tester);
      await tester.drag(list, const Offset(0, 300));
      await tester.pumpAndSettle();
      final anchor = find.text('Answer line 80');
      final before = tester.getTopLeft(anchor).dy;
      extraTail = [
        Column(
          children: List.generate(
            105,
            (i) => SizedBox(height: 40, child: Text('Answer line $i')),
          ),
        ),
      ];
      chat.reading.appendStreaming(' more');
      tester
          .element(
            find
                .ancestor(
                  of: find.byType(ProfileTranscript),
                  matching: find.byType(ListenableBuilder),
                )
                .first,
          )
          .markNeedsBuild();
      await tester.pump();
      expect(tester.getTopLeft(anchor).dy, closeTo(before, 1));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(anchor).dy, closeTo(before, 1));
    },
  );

  testWidgets(
    'new durable messages keep reading position, and reduced-motion Latest clears the badge',
    (tester) async {
      reducedMotion = true;
      await show(tester);
      await tester.drag(list, const Offset(0, 450));
      await tester.pumpAndSettle();
      final anchor = tester.widget(visibleRow(tester)).key!;
      final before = tester.getTopLeft(find.byKey(anchor)).dy;
      chat.reading.installSavedHistory([...chat.reading.messages, row(621)]);
      await rebuildPresentation(tester);
      expect(tester.getTopLeft(find.byKey(anchor)).dy, closeTo(before, 2));
      expect(find.byTooltip('New activity'), findsOneWidget);
      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(chat.reading.readingPosition.resume, isNull);
      expect(jump, findsNothing);
      expect(chat.reading.messages.last['id'], 621);
    },
  );

  testWidgets('an expanded tool group survives older and newer additions', (
    tester,
  ) async {
    Map<String, dynamic> tool(int id) => {
      'id': id,
      'role': 'tool',
      'tool_name': 'Tool $id',
      'content': 'Output $id',
    };
    chat.reading.installSavedHistory([tool(1), tool(2), row(3)]);
    chat.reading.installSnapshot(
      TranscriptReadingSnapshot(
        messages: chat.reading.messages,
        historySessionId: chat.reading.historySessionId,
      ),
    );
    await show(tester);
    await tester.tap(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('Tool 1')),
      alignment: 0.3,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tool 1'));
    await tester.pumpAndSettle();
    expect(find.text('Output 1'), findsOneWidget);
    chat.reading.installSavedHistory([tool(0), ...chat.reading.messages]);
    await rebuildPresentation(tester);
    expect(find.text('Output 1'), findsOneWidget);
    final addedTool = List<Map<String, dynamic>>.of(chat.reading.messages)
      ..insert(3, tool(4));
    chat.reading.installSavedHistory(addedTool);
    await rebuildPresentation(tester);
    expect(find.text('Output 1'), findsOneWidget);
    expect(find.text('Output 4'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final laterContent in [0.0, 2200.0]) {
        testWidgets(
          'switching a long saved Tools section to Agents keeps content visible '
          '${brightness.name} $scale later=$laterContent',
          (tester) async {
            loadOlder = () async {};
            realisticMessages = true;
            tailHeight = laterContent;
            chat.reading.installSnapshot(
              TranscriptReadingSnapshot(
                historySessionId: chat.reading.historySessionId,
                messages: [
                  {
                    'id': 1,
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': [
                      {
                        'id': 'delegate',
                        'function': {
                          'name': 'delegate_task',
                          'arguments': jsonEncode({
                            'tasks': [
                              {'goal': 'Inspect transport'},
                            ],
                          }),
                        },
                      },
                    ],
                  },
                  for (var id = 2; id < 53; id++)
                    {
                      'id': id,
                      'role': 'tool',
                      'tool_name': 'read_file',
                      'content': 'File $id',
                    },
                  {
                    'id': 53,
                    'role': 'tool',
                    'tool_call_id': 'delegate',
                    'content': jsonEncode({
                      'results': [
                        {
                          'task_index': 0,
                          'status': 'completed',
                          'summary': 'Inspection complete',
                          'duration_seconds': 12,
                        },
                      ],
                    }),
                  },
                  {
                    'id': 54,
                    'role': 'assistant',
                    'content': List.generate(
                      5,
                      (i) =>
                          '## Recommendation $i\n\n**A useful comparison** with several choices. Read the supplier conditions.\n\n| Choice | Cost |\n| --- | --- |\n| First | 42 |\n| Second | 55 |',
                    ).join('\n\n'),
                  },
                ],
              ),
            );
            await show(tester, brightness: brightness, scale: scale);
            await tester.settleMarkdown();
            for (
              var attempt = 0;
              find
                      .textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$'))
                      .evaluate()
                      .isEmpty &&
                  attempt < 50;
              attempt++
            ) {
              await tester.drag(list, const Offset(0, 600));
              await tester.settleMarkdown();
              await tester.pumpAndSettle();
            }
            await Scrollable.ensureVisible(
              tester.element(
                find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
              ),
              alignment: 0.1,
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
            );
            await tester.pumpAndSettle();
            final agents = find.byKey(
              const ValueKey(('activity-tab', 'agents')),
            );
            final tools = find.byKey(
              const ValueKey(('activity-tab', 'timeline')),
            );
            await Scrollable.ensureVisible(
              tester.element(agents),
              alignment: 0.2,
            );
            await tester.pumpAndSettle();
            final scroll = tester.widget<ListView>(list).controller!;
            scroll.jumpTo(scroll.offset + 100 - tester.getTopLeft(agents).dy);
            await tester.pumpAndSettle();
            final before = tester.getTopLeft(agents).dy;
            for (var attempt = 0; attempt < 2; attempt++) {
              await tester.tap(agents);
              for (var frame = 0; frame < 20; frame++) {
                await tester.pump(const Duration(milliseconds: 16));
                expect(tester.getTopLeft(agents).dy, closeTo(before, 1));
                expect(
                  find.text('Inspect transport').hitTestable(),
                  findsOneWidget,
                );
                expect(tester.takeException(), isNull);
              }
              await tester.settleMarkdown();
              await tester.pumpAndSettle();
              expect(tester.getTopLeft(agents).dy, closeTo(before, 1));
              if (attempt == 0) {
                await tester.tap(tools);
                await tester.pumpAndSettle();
                expect(tester.getTopLeft(agents).dy, closeTo(before, 1));
              }
            }
            // Parent rebuilds must preserve the negative/bounded reading
            // position as well as the selected saved-agent page.
            await rebuildPresentation(tester);
            expect(tester.getTopLeft(agents).dy, closeTo(before, 1));
            expect(
              find.text('Inspect transport').hitTestable(),
              findsOneWidget,
            );
            await capture?.call(
              tester,
              'agents-${brightness.name}-$scale-later-$laterContent',
            );
            expect(jump.hitTestable(), findsOneWidget);
            await tester.tap(jump);
            await tester.pumpAndSettle();
            expect(scroll.position.minScrollExtent, 0);
            expect(scroll.offset, 0);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final liveTools in [false, true]) {
        testWidgets('collapsing latest tools removes the expansion gap '
            '${brightness.name} $scale live=$liveTools', (tester) async {
          realisticMessages = true;
          chat.reading.installSnapshot(
            TranscriptReadingSnapshot(
              historySessionId: chat.reading.historySessionId,
              messages: [
                {
                  'id': 1,
                  'role': 'user',
                  'content': 'Compare the available options.\n\n' * 12,
                },
                if (!liveTools)
                  for (var id = 2; id < 27; id++)
                    {
                      'id': id,
                      'role': 'tool',
                      'tool_name': 'read_file',
                      'content': 'Output $id',
                    },
              ],
            ),
          );
          if (liveTools) {
            currentActivity = [
              ProfileLiveToolActivity(
                activities: List.generate(
                  25,
                  (id) => GatewayToolActivity(
                    toolId: 'call-$id',
                    name: 'read_file',
                    phase: GatewayToolActivityPhase.completed,
                    arguments: jsonEncode({'path': 'file-$id'}),
                    result: 'Output $id',
                  ),
                ),
              ),
            ];
          }
          await show(
            tester,
            brightness: brightness,
            scale: scale,
            surfaceSize: Size(scale == 1 ? 390 : 320, 844),
          );
          await tester.settleMarkdown();
          final activity = find.textContaining(
            RegExp(r'^Activity(?: · \d+ tools?)?$'),
          );
          final before = tester.getBottomLeft(activity).dy;
          final scroll = tester.widget<ListView>(list).controller!;
          for (var attempt = 0; attempt < 2; attempt++) {
            await tester.tap(activity);
            await tester.pumpAndSettle();
            // Read into the expanded tools before returning to their disclosure.
            await tester.drag(list, const Offset(0, -400));
            await tester.pumpAndSettle();
            expect(activity.hitTestable(), findsOneWidget);
            await tester.tap(activity);
            for (var frame = 0; frame < 20; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              expect(scroll.position.minScrollExtent, 0);
            }
            await tester.pumpAndSettle();
            await tester.settleMarkdown();
            expect(scroll.offset, closeTo(0, 1));
            expect(tester.getBottomLeft(activity).dy, closeTo(before, 1));
            expect(jump, findsNothing);
          }
          await rebuildPresentation(tester);
          expect(scroll.position.minScrollExtent, 0);
          expect(scroll.offset, closeTo(0, 1));
          await capture?.call(
            tester,
            'tools-collapsed-${brightness.name}-$scale-live-$liveTools',
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('scrolling activity content preserves chat reading position', (
    tester,
  ) async {
    chat.reading.installSavedHistory([
      ...List.generate(20, row),
      {
        'id': 100,
        'role': 'tool',
        'tool_name': 'Scrollable output',
        'content': List.generate(100, (i) => 'Output line $i').join('\n'),
      },
    ]);
    chat.reading.installSnapshot(
      TranscriptReadingSnapshot(
        messages: chat.reading.messages,
        historySessionId: chat.reading.historySessionId,
      ),
    );
    await show(tester);
    await toggleInPlace(
      tester,
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
    );
    final header = find.text('Scrollable output');
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    await toggleInPlace(tester, header);
    final output = chat.reading.messages.last['content'] as String;
    final pane = find
        .ancestor(
          of: find.text(output, findRichText: true),
          matching: find.byKey(const ValueKey('activity-content-scroll')),
        )
        .first;
    await tester.ensureVisible(pane);
    await tester.pumpAndSettle();
    final chatOffset = chat.reading.readingPosition.resume;
    final headerTop = tester.getTopLeft(header).dy;
    await tester.drag(pane, const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SingleChildScrollView>(pane).controller!.offset,
      greaterThan(0),
    );
    expect(
      chat.reading.readingPosition.resume?.messageId,
      chatOffset?.messageId,
    );
    expect(tester.getTopLeft(header).dy, closeTo(headerTop, 1));
    expect(find.text('Preview'), findsNothing);
  });

  testWidgets('expanding long tool output keeps its header in place', (
    tester,
  ) async {
    chat.reading.installSavedHistory([
      ...List.generate(20, row),
      {
        'id': 100,
        'role': 'tool',
        'tool_name': 'Long output',
        'content': List.generate(100, (i) => 'Output line $i').join('\n'),
      },
    ]);
    chat.reading.installSnapshot(
      TranscriptReadingSnapshot(
        messages: chat.reading.messages,
        historySessionId: chat.reading.historySessionId,
      ),
    );
    await show(tester);
    final activity = find.textContaining(
      RegExp(r'^Activity(?: · \d+ tools?)?$'),
    );
    await toggleInPlace(tester, activity);
    final header = find.text('Long output');
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    await capture?.call(tester, 'tool-before-expansion');
    await toggleInPlace(tester, header);
    final output = chat.reading.messages.last['content'] as String;
    expect(find.text(output, findRichText: true), findsOneWidget);
    expect(find.text('Preview'), findsNothing);
    await capture?.call(tester, 'tool-after-expansion');
    await toggleInPlace(tester, header);
    await toggleInPlace(tester, header);
    final beforeDrag = tester.getTopLeft(header).dy;
    await tester.drag(list, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, lessThan(beforeDrag - 100));
    await tester.tap(jump);
    await tester.pumpAndSettle();
    expect(chat.reading.readingPosition.resume, isNull);
  });

  testWidgets(
    'nested live tool details and reasoning expand without movement',
    (tester) async {
      chat.reading.installSavedHistory(List.generate(20, row));
      chat.reading.installSnapshot(
        TranscriptReadingSnapshot(
          messages: chat.reading.messages,
          historySessionId: chat.reading.historySessionId,
        ),
      );
      currentActivity = [
        ProfileLiveToolActivity(
          activities: [
            GatewayToolActivity(
              name: 'delegate_task',
              phase: GatewayToolActivityPhase.completed,
              arguments: List.generate(100, (i) => 'Argument $i').join('\n'),
              result: 'Result starts here',
            ),
          ],
        ),
      ];
      extraTail = [ProfileReasoningDisclosure(text: 'Reasoning line\n' * 100)];
      await show(tester);
      await toggleInPlace(
        tester,
        find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
      );
      final tool = find.text('Delegated tasks');
      await tester.ensureVisible(tool);
      await tester.pumpAndSettle();
      await toggleInPlace(tester, tool);
      expect(find.text('Result starts here'), findsOneWidget);
      await capture?.call(tester, 'nested-tool-after-expansion');
      chat.reading.updateStreaming('Concurrent streaming update');
      final beforeRefresh = tester.getTopLeft(tool).dy;
      await rebuildPresentation(tester);
      expect(tester.getTopLeft(tool).dy, closeTo(beforeRefresh, 1));
      await toggleInPlace(tester, tool);
      expect(find.text('Result starts here'), findsNothing);
      await tester.tap(jump);
      await tester.pumpAndSettle();
      final thought = thoughtHeader;
      await tester.ensureVisible(thought);
      await tester.pumpAndSettle();
      await toggleInPlace(tester, thought);
    },
  );

  testWidgets('a short conversation keeps the expansion header in place', (
    tester,
  ) async {
    chat.reading.installSavedHistory([row(1)]);
    chat.reading.installSnapshot(
      TranscriptReadingSnapshot(
        messages: chat.reading.messages,
        historySessionId: chat.reading.historySessionId,
      ),
    );
    extraTail = [const ProfileReasoningDisclosure(text: 'A short thought')];
    await show(tester);
    final thought = thoughtHeader;
    await toggleInPlace(tester, thought);
    await tester.settleMarkdown();
    expect(find.text('A short thought'), findsNWidgets(2));
    await toggleInPlace(tester, thought);
    expect(chat.reading.readingPosition.resume, isNull);
  });

  testWidgets('restored history shows the saved prompt-to-reply interval', (
    tester,
  ) async {
    final snapshot = TranscriptReadingSnapshot(
      historySessionId: chat.key.sessionId,
      messages: [
        {
          'id': 1,
          'role': 'user',
          'content': 'Commit and push all please',
          'timestamp': 1791616320.25,
        },
        {
          'id': 2,
          'role': 'tool',
          'tool_name': 'terminal',
          'content': 'Changes pushed',
          'timestamp': 1791616380,
          'duration_s': 5,
        },
        {
          'id': 3,
          'role': 'assistant',
          'content': 'Committed and pushed all changes.',
          'timestamp': 1791616404.25,
        },
      ],
    );
    chat.reading.installSnapshot(snapshot);
    await show(tester);
    expect(find.text('· 1m 24s'), findsOneWidget);
    expect(find.text('Activity · 1 tool'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    try {
      if (tester.binding is AutomatedTestWidgetsFlutterBinding) {
        await tester.pump(const Duration(minutes: 10));
      } else {
        // Native frames are suspended while paused. Observe real elapsed time
        // without waiting for a paused frame or a ten-minute fake-clock jump.
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
    await tester.pumpAndSettle();
    expect(find.text('· 1m 24s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty assistant rows leave existing tool cards in one section', (
    tester,
  ) async {
    chat.reading.installSavedHistory([
      {
        'id': 1,
        'role': 'tool',
        'tool_name': 'read_file',
        'content': 'Read output',
      },
      {'id': 2, 'role': 'assistant', 'content': ''},
      {
        'id': 3,
        'role': 'tool',
        'tool_name': 'patch',
        'content': 'Patch output',
      },
      {
        'id': 4,
        'role': 'tool',
        'tool_name': 'terminal',
        'content': 'Test output',
      },
      row(5),
    ]);
    chat.reading.installSnapshot(
      TranscriptReadingSnapshot(
        messages: chat.reading.messages,
        historySessionId: chat.reading.historySessionId,
      ),
    );
    await show(tester);
    expect(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
      findsOneWidget,
    );
    expect(find.text('Activity · 3 tools'), findsOneWidget);
    expect(find.text('Read file'), findsNothing);
    expect(find.text('Tool 1'), findsNothing);
    expect(find.text('Message 5'), findsOneWidget);

    await tester.tap(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Read file'), findsOneWidget);
    expect(find.text('Patched file'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SourceCodeText && widget.text == 'Read output',
      ),
      findsNothing,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('Read file')),
      alignment: 0.3,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read file'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SourceCodeText && widget.text == 'Read output',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SourceCodeText && widget.text == 'Patch output',
      ),
      findsNothing,
    );
    await tester.tap(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SourceCodeText && widget.text == 'Read output',
      ),
      findsNothing,
    );
    expect(find.text('Message 5'), findsOneWidget);

    await tester.tap(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SourceCodeText && widget.text == 'Read output',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    chat.reading.recordReading(null);
    await show(tester);
    expect(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
      findsOneWidget,
    );
    expect(find.text('Read file'), findsNothing);
  });

  testWidgets('long tool history stays compact and prose separates sections', (
    tester,
  ) async {
    chat.reading.installSavedHistory([
      for (var i = 0; i < 30; i++) ...[
        {'id': i * 2, 'role': 'assistant', 'content': ''},
        {'id': i * 2 + 1, 'role': 'tool', 'content': 'Output $i'},
      ],
      row(60),
      {'id': 61, 'role': 'tool', 'content': 'Another output'},
      row(62),
    ]);
    chat.reading.installSnapshot(
      TranscriptReadingSnapshot(
        messages: chat.reading.messages,
        historySessionId: chat.reading.historySessionId,
      ),
    );
    await show(tester);
    expect(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
      findsNWidgets(2),
    );
    expect(find.text('Activity · 30 tools'), findsOneWidget);
    expect(find.text('Activity · 1 tool'), findsOneWidget);
    expect(find.text('Tool result'), findsNothing);
    expect(find.text('Message 60').hitTestable(), findsOneWidget);
    expect(find.text('Message 62').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool rows without saved IDs stay collapsed by default', (
    tester,
  ) async {
    chat.reading.installSavedHistory([
      {'role': 'tool', 'content': 'Unsaved tool output'},
    ]);
    chat.reading.installSnapshot(
      TranscriptReadingSnapshot(
        messages: chat.reading.messages,
        historySessionId: chat.reading.historySessionId,
      ),
    );

    await show(tester);

    expect(
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
      findsOneWidget,
    );
    expect(find.text('Unsaved tool output'), findsNothing);
  });

  testWidgets(
    'input requests are discoverable while reading without automatically approving',
    (tester) async {
      await show(tester);
      await tester.drag(list, const Offset(0, 450));
      await tester.pumpAndSettle();
      runtime.receiveApproval({
        'request_id': 'test',
        'command': 'test command',
      });
      await rebuildPresentation(tester);
      expect(find.byTooltip('Input needed'), findsOneWidget);
      final before = host.calls.length;
      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(chat.reading.readingPosition.resume, isNull);
      expect(chat.runtime.approval, isNotNull);
      expect(host.calls.length, before);
    },
  );

  testWidgets('pending secure input stays discoverable while reading', (
    tester,
  ) async {
    await show(tester);
    await tester.drag(list, const Offset(0, 450));
    await tester.pumpAndSettle();
    final request = GatewaySensitivePromptRequest.fromEventData(
      kind: GatewaySensitivePromptKind.vaultSaveLogin,
      data: {'request_id': 'reading-request', 'site': 'Fixture site'},
    )!;
    runtime.receiveSecure(request);
    await rebuildPresentation(tester);
    expect(find.byTooltip('Input needed'), findsOneWidget);
    final before = host.calls.length;
    await tester.tap(jump);
    await tester.pumpAndSettle();
    expect(chat.reading.readingPosition.resume, isNull);
    expect(chat.runtime.secureInput?.requestId, request.requestId);
    expect(chat.runtime.secureInput?.kind, request.kind);
    expect(host.calls.length, before);
  });

  testWidgets('closed secure input signals new activity while reading', (
    tester,
  ) async {
    realisticMessages = true;
    await show(tester);
    await tester.drag(list, const Offset(0, 450));
    await tester.pumpAndSettle();
    runtime.receiveSecure(
      GatewaySensitivePromptRequest.fromEventData(
        kind: GatewaySensitivePromptKind.vaultSaveLogin,
        data: {'request_id': 'reading-request', 'site': 'Fixture site'},
      )!,
    );
    await rebuildPresentation(tester);
    expect(find.byTooltip('Input needed'), findsOneWidget);
    final before = host.calls.length;

    runtime.reconcileOpenRequests(const []);
    await rebuildPresentation(tester);

    expect(find.byTooltip('Input needed'), findsNothing);
    expect(find.byTooltip('New activity').hitTestable(), findsOneWidget);
    expect(chat.reading.readingPosition.resume, isNotNull);
    await tester.tap(jump);
    await tester.pumpAndSettle();
    expect(chat.reading.readingPosition.resume, isNull);
    expect(chat.runtime.secureInput, isNull);
    expect(host.calls.length, before);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'search context keeps its header visible and expands the matched tool result ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final originalMessages = List<Map<String, dynamic>>.of(
            chat.reading.messages,
          );
          chat.reading.recordReading(const TranscriptBookmark(messageId: 84));
          var returned = false;
          final nearby = [
            for (var id = 1; id <= 9; id++)
              id == 5
                  ? {
                      'id': id,
                      'role': 'tool',
                      'tool_name': 'read_file',
                      'content': 'Matched tool output',
                    }
                  : {
                      'id': id,
                      'role': 'assistant',
                      'content': List.filled(
                        30,
                        'Nearby message $id',
                      ).join('\n'),
                    },
          ];

          await tester.pumpWidget(
            MaterialApp(
              theme: profileWorkspaceTheme(wingTheme(brightness)),
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: controller,
                  builder: (_, _) => ProfileTranscript(
                    presentation: TranscriptPresentation.capture(
                      identity: chat.key,
                      reader: chat.reading,
                      timeline: TranscriptTimeline.project(
                        nearby,
                        presentationId: chat.reading.messagePresentationId,
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
                    onLoadOlder:
                        loadOlder ?? () => controller.loadOlderMessages(chat),
                    messageBuilder: (message) => Text(message.message.text),
                    tail: const [],

                    focusedMessageId: 5,
                    onBackToLatest: () => returned = true,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          tester
              .element(
                find
                    .ancestor(
                      of: find.byType(ProfileTranscript),
                      matching: find.byType(ListenableBuilder),
                    )
                    .first,
              )
              .markNeedsBuild();
          await tester.pumpAndSettle();

          expect(find.text('Search result'), findsOneWidget);
          expect(
            find.byTooltip('Back to latest').hitTestable(),
            findsOneWidget,
          );
          expect(
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is SourceCodeText &&
                      widget.text == 'Matched tool output',
                )
                .hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          expect(chat.reading.messages, originalMessages);
          expect(chat.reading.readingPosition.resume?.messageId, 84);

          // A keyboard and composer can leave less than 84 logical pixels.
          tester.view.physicalSize = const Size(320, 84);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Search result').hitTestable(), findsOneWidget);
          expect(
            find.byTooltip('Back to latest').hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('Back to latest'));
          expect(returned, isTrue);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(chat.reading.readingPosition.resume?.messageId, 84);
        },
      );
    }
  }

  testWidgets(
    'an older-page failure retains messages and only retries on request',
    (tester) async {
      await show(tester);
      host.failHistory = true;
      final scroll = tester.widget<ListView>(list).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(chat.reading.historyError, isNotNull);
      expect(chat.reading.messages.length, 50);
      final reads = host.reads.length;
      await tester.pump(const Duration(seconds: 2));
      expect(host.reads.length, reads);
      host.failHistory = false;
      await tester.ensureVisible(find.text('Retry older messages'));
      await tester.tap(find.text('Retry older messages'));
      await tester.pumpAndSettle();
      expect(chat.reading.historyError, isNull);
      expect(chat.reading.messages.length, greaterThanOrEqualTo(100));
      expect(tester.takeException(), isNull);
    },
  );
}
