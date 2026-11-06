import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/markdown_code_block.dart';
import 'package:wing/core/widgets/profile_live_work_dock.dart';
import 'package:wing/core/widgets/profile_subagent_panel.dart';
import 'package:wing/core/widgets/profile_live_execution.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/block_reusing_markdown_body.dart';

import '../tools/performance/streaming_replay_fixture.dart';
import '../tools/performance/workspace_streaming_replay.dart';
import 'helpers/pump_markdown_widget.dart';

Future<WorkspaceStreamingReplayState> _preparedWorkspace(
  WidgetTester tester, {
  int? historyCount,
  bool work = false,
  Brightness brightness = Brightness.light,
  double scale = 1,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<WorkspaceStreamingReplayState>();
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('workspace-replay-capture'),
      child: MaterialApp(
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: WorkspaceStreamingReplay(key: key),
      ),
    ),
  );
  Map<String, Object?>? result;
  Object? failure;
  final preparation = historyCount == null
      ? key.currentState!.prepare(requireKeyboard: false, work: work)
      : key.currentState!.prepareIdle(historyCount, requireKeyboard: false);
  final pending = preparation.then<void>(
    (value) => result = value,
    onError: (Object error) {
      failure = error;
    },
  );
  for (
    var attempt = 0;
    attempt < 200 && result == null && failure == null;
    attempt++
  ) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.settleMarkdown();
  }
  expect(failure, isNull);
  expect(result, isNotNull);
  await pending;
  return key.currentState!;
}

bool _canAddListener(ChangeNotifier notifier) {
  void listener() {}
  try {
    notifier.addListener(listener);
    notifier.removeListener(listener);
    return true;
  } on FlutterError {
    return false;
  }
}

Future<void> captureCompletion(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_COMPLETION_LAYOUT')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('workspace-replay-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final target = File('build/design-previews/completion-layout/$name.png');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_COMPLETION_LAYOUT')) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    const monoFont = String.fromEnvironment('CAPTURE_MONO_FONT');
    for (final entry in {
      'Roboto': '$directory/Roboto-Regular.ttf',
      'MaterialIcons': '$directory/MaterialIcons-Regular.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
      'monospace': monoFont,
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(await File(entry.value).readAsBytes()),
            ),
          ))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('completion retains the already rendered work-run answer '
          '${brightness.name} $scale', (tester) async {
        final state = await _preparedWorkspace(
          tester,
          work: true,
          brightness: brightness,
          scale: scale,
        );
        final body = find.byWidgetPredicate(
          (widget) =>
              widget is MarkdownMessageContent &&
              widget.data == streamingReplayInitial(),
        );
        final original = tester.element(body);
        await captureCompletion(tester, 'streaming-${brightness.name}-$scale');
        state.complete();
        await tester.pump();
        await tester.settleMarkdown();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          state.controller!.current!.chat!.runtime.executionActive,
          isFalse,
        );
        expect(body, findsOneWidget);
        expect(
          tester.element(body),
          same(original),
          reason:
              'The live-to-saved handoff retains the Markdown parser/cache '
              'owner instead of disposing and recreating the rendered answer.',
        );
        expect(tester.widget<MarkdownMessageContent>(body).streaming, isFalse);
        await captureCompletion(tester, 'complete-${brightness.name}-$scale');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('answer chunks leave an open work drawer unchanged', (
    tester,
  ) async {
    final state = await _preparedWorkspace(tester, work: true);
    final chat = state.controller!.current!.chat!;
    await tester.tap(find.byKey(const ValueKey(('live-work-tab', 0, false))));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.settleMarkdown();
    // Finish the drawer's post-layout content measurement before observing
    // rebuilds caused by answer chunks.
    await tester.pump();
    final panel = tester.widget<ProfileSubagentPanel>(
      find.byType(ProfileSubagentPanel),
    );
    var notifications = 0, dockBuilds = 0, panelBuilds = 0, activityBuilds = 0;
    panel.session.addListener(() => notifications++);
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is ProfileLiveWorkDock) dockBuilds++;
      if (element.widget is ProfileSubagentPanel) panelBuilds++;
      if (element.widget is ProfileLiveExecution) activityBuilds++;
      previous?.call(element, builtOnce);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    for (var index = 0; index < 30; index++) {
      state.appendReply('.');
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(chat.reading.streaming, '${streamingReplayInitial()}${'.' * 30}');
    expect(notifications, 0, reason: 'Unchanged supervision stays quiet.');
    expect(
      dockBuilds,
      0,
      reason: 'Answer text does not rebuild work controls.',
    );
    expect(panelBuilds, 0, reason: 'Unchanged agent cards remain mounted.');
    expect(
      activityBuilds,
      0,
      reason: 'Answer text does not rebuild tool runs.',
    );
    state.controller!.current!.gateway.onEvent!(
      StreamEvent(
        type: 'subagent.progress',
        sessionId: chat.runtime.runtimeId,
        data: {'subagent_id': 'offline-agent-0', 'text': 'New progress'},
      ),
    );
    await tester.pump();
    expect(notifications, greaterThan(0));
    expect(
      panel.session.state.subagents.first.recentActivity,
      contains('New progress'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('work replay retains synthetic tasks, agents and live source', (
    tester,
  ) async {
    final state = await _preparedWorkspace(tester, work: true);
    final chat = state.controller!.current!.chat!;
    expect(chat.todos, hasLength(7));
    expect(chat.subagents, hasLength(2));
    expect(chat.runtime.toolActivities, hasLength(1));
    await state.controller!.reconnect(chat.key.workspace);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.settleMarkdown();
    expect(chat.runtime.executionActive, isTrue);
    expect(chat.reading.streaming, streamingReplayInitial());
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'replay coordinates open agents and switch to tasks through the visible dock',
    (tester) async {
      final state = await _preparedWorkspace(tester, work: true);
      Future<void> tapControl(String name) async {
        final coordinates = state.controls()[name] as List<int>?;
        expect(
          coordinates,
          isNotNull,
          reason: '$name must be a visible tap target',
        );
        final ratio = tester.view.devicePixelRatio;
        await tester.tapAt(
          Offset(coordinates![0] / ratio, coordinates[1] / ratio),
        );
        // Opening installs and measures the overlay before its reveal starts.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.settleMarkdown();
        await tester.pump();
      }

      // The long answer leaves Activity retained outside the viewport. It must
      // not contribute an invalid coordinate or prevent the visible dock taps.
      expect(state.controls(), isNot(contains('activity')));
      await tapControl('subagents');
      expect(find.byType(ProfileSubagentPanel).hitTestable(), findsOneWidget);
      await tapControl('tasks');
      final expandTask = find
          .descendant(
            of: find.byType(ProfileTodoPanel),
            matching: find.byTooltip('Expand task'),
          )
          .first;
      expect(expandTask.hitTestable(), findsOneWidget);
      await tester.tap(expandTask);
      await tester.pump();
      expect(find.byTooltip('Collapse task').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('render verification rejects missing and stale mounted segments', () {
    const source = 'Visible prose.\n\n```dart\nfinal value = 1;\n```\n';
    final split = splitMarkdownCodeBlocks(source, streaming: true);
    final widgets = split
        .map<Widget>(
          (part) => part is MarkdownCodeBlock
              ? part
              : BlockReusingMarkdownBody(data: part as String),
        )
        .toList();
    expect(
      workspaceReplayMatchesSegments(source, widgets, streaming: true),
      isTrue,
    );
    expect(
      workspaceReplayMatchesSegments(source, widgets.skip(1), streaming: true),
      isFalse,
    );
    expect(
      workspaceReplayMatchesSegments(source, [
        const BlockReusingMarkdownBody(data: 'Old prose.'),
        ...widgets.skip(1),
      ], streaming: true),
      isFalse,
    );
  });

  testWidgets('changed prepared source is rejected before measurement', (
    tester,
  ) async {
    final state = await _preparedWorkspace(tester);
    state.controller!.current!.chat!.reading.appendStreaming(
      'Unexpected input',
    );
    await expectLater(
      state.replay(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Prepared source'),
        ),
      ),
    );
    expect(state.ready()['running'], isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pause then resume invalidates preparation', (tester) async {
    final state = await _preparedWorkspace(tester);
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(state.ready()['prepared'], isFalse);
    await expectLater(state.replay(), throwsStateError);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'pause cancels pending frame preparation without waiting for resume',
    (tester) async {
      final key = GlobalKey<WorkspaceStreamingReplayState>();
      await tester.pumpWidget(
        MaterialApp(home: WorkspaceStreamingReplay(key: key)),
      );
      final state = key.currentState!;
      final preparing = state.prepare(requireKeyboard: false);
      final expectation = expectLater(
        preparing,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('canceled'),
          ),
        ),
      );
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await expectation;
      expect(state.ready()['prepared'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'aborted replacement disposes the old controller after its view detaches',
    (tester) async {
      final state = await _preparedWorkspace(tester, historyCount: 2);
      final oldController = state.controller!;
      addTearDown(() {
        if (_canAddListener(oldController)) oldController.dispose();
      });

      final preparing = state.prepareIdle(50, requireKeyboard: false);
      expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await expectLater(
        preparing,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('canceled'),
          ),
        ),
      );
      expect(_canAddListener(oldController), isTrue);

      await tester.pump();
      expect(find.byType(ProfileWorkspaceScreen), findsNothing);
      expect(_canAddListener(oldController), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('offline replay prepares the real workspace and composer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<WorkspaceStreamingReplayState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
        home: WorkspaceStreamingReplay(key: key),
      ),
    );
    Map<String, Object?>? result;
    Object? failure;
    final preparing = key.currentState!
        .prepare(requireKeyboard: false)
        .then((value) {
          result = value;
        })
        .catchError((Object error) {
          failure = error;
        });
    for (
      var attempt = 0;
      attempt < 200 && result == null && failure == null;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.settleMarkdown();
    }
    expect(failure, isNull);
    expect(result, isNotNull);
    await preparing;
    expect(result!['prepared'], isTrue);
    expect(result!['nativeDraftStorage'], isFalse);
    expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
    final chat = key.currentState!.controller!.current!.chat!;
    expect(chat.runtime.blocksTurnAdmission, isTrue);
    expect(chat.reading.streaming, streamingReplayInitial());
    final rendered = key.currentState!.renderedReadiness(
      streamingReplayInitial(),
    );
    expect(rendered['rendered'], isTrue, reason: rendered.toString());
    expect(rendered['segmentsMatch'], isTrue);
    expect(rendered['editableMarkers'], greaterThan(0));
    final textField = tester.widget<TextField>(
      find.byKey(const Key('profile-message-composer')),
    );
    expect(textField.focusNode!.hasFocus, isTrue);
    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Physical typing equivalent',
    );
    await tester.pump();
    expect(
      chat.composer.observation.displayedText,
      'Physical typing equivalent',
    );
    key.currentState!.appendReply('A deterministic appended paragraph.');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.settleMarkdown();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownMessageContent &&
            widget.data ==
                '${streamingReplayInitial()}A deterministic appended paragraph.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(workspaceReplayDeltaCount * workspaceReplayIntervalUs, 20000000);
  });

  testWidgets('idle probe accepts only short or long saved-history fixtures', (
    tester,
  ) async {
    final state = await _preparedWorkspace(tester, historyCount: 2);
    expect(state.controller!.current!.chat!.reading.messages, hasLength(2));
    expect(state.controller!.current!.chat!.reading.streaming, isEmpty);
    expect(
      state.controller!.current!.chat!.runtime.blocksTurnAdmission,
      isFalse,
    );
    await expectLater(
      state.prepareIdle(3, requireKeyboard: false),
      throwsStateError,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle probe exports counts and expected draft check only', (
    tester,
  ) async {
    final state = await _preparedWorkspace(tester, historyCount: 50);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    final started = state.startProbe();
    expect(started['started'], isTrue);
    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Test ${'test ' * 39}',
    );
    await tester.pump();
    Map<String, Object?>? report;
    Object? failure;
    final stopping = state.stopProbe().then<void>(
      (value) => report = value,
      onError: (Object error) {
        failure = error;
      },
    );
    for (
      var attempt = 0;
      attempt < 20 && report == null && failure == null;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.settleMarkdown();
    }
    expect(failure, isNull);
    await stopping;
    expect(report, isNotNull);
    expect(report!['draftCharacters'], 200);
    expect(report!['expectedDraftVerified'], isTrue);
    expect(report, isNot(contains('draft')));
    expect(report, isNot(contains('source')));
    expect(report, contains('transcript.build_setup_sync'));
    expect(report, contains('transcript.group_sync'));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
