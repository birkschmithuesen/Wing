import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_live_work_dock.dart';

void main() {
  final capture = const bool.fromEnvironment('CAPTURE_LIVE_WORK_DOCK');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  final frame = GlobalKey();
  final dock = GlobalKey<ProfileLiveWorkDockState>();
  Future<void> show(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
    double scale = 1,
    bool reduced = false,
    double keyboard = 0,
    Future<void> Function()? refresh,
  }) async {
    tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduced,
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: RepaintBoundary(key: frame, child: child!),
        ),
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) dock.currentState?.dismiss();
          },
          child: Scaffold(
            body: Column(
              children: [
                const Expanded(
                  child: Center(child: Text('Conversation remains here')),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ProfileLiveWorkDock(
                        taskSummary: const Text('Task summary'),
                        subagentSummary: const Text('Agent summary'),
                        key: dock,
                        taskCount: 7,
                        completedTasks: 3,
                        subagentCount: 2,
                        onAgentsSelected: refresh ?? () async {},
                        subagents: Column(
                          children: [
                            for (var i = 0; i < 8; i++)
                              SizedBox(
                                height: 64,
                                child: Text(
                                  'Subagent $i: inspect source mappings',
                                ),
                              ),
                          ],
                        ),
                        tasks: Column(
                          children: [
                            for (var i = 0; i < 12; i++)
                              SizedBox(
                                height: 64,
                                child: Text(
                                  'Task $i: research metric definitions',
                                ),
                              ),
                          ],
                        ),
                      ),
                      const TextField(
                        key: ValueKey('draft'),
                        decoration: InputDecoration(
                          hintText: 'Draft your next message',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder tab(int index, {bool overlay = true}) =>
      find.byKey(ValueKey(('live-work-tab', index, overlay)));
  Future<void> picture(WidgetTester tester, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final image =
          await (frame.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('build/design-previews/live-work-native')
        ..createSync(recursive: true);
      await File(
        '${dir.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('fixed dock and drawer ${brightness.name} $scale', (
        tester,
      ) async {
        await show(tester, brightness: brightness, scale: scale);
        await tester.enterText(
          find.byKey(const ValueKey('draft')),
          'Keep my draft',
        );
        final composer = tester.getRect(find.byKey(const ValueKey('draft')));
        final closed = tester.getRect(tab(1, overlay: false));
        // Only real-font captures establish text fit. The default test Ahem
        // glyphs are uniform squares rather than the production Roboto metrics.
        if (capture) {
          for (final label in ['2 subagents', 'Tasks 3/7']) {
            expect(
              tester
                  .renderObject<RenderParagraph>(find.text(label))
                  .didExceedMaxLines,
              isFalse,
            );
          }
        }
        expect(find.byKey(const ValueKey('live-work-divider')), findsOneWidget);
        await picture(tester, '${brightness.name}-$scale-folded');
        await tester.tap(tab(1, overlay: false));
        await tester.pumpAndSettle();
        expect(tester.getRect(tab(1)).bottom, closed.bottom);
        expect(tester.getRect(find.byKey(const ValueKey('draft'))), composer);
        expect(
          find.byKey(const ValueKey('live-work-selection')),
          findsOneWidget,
        );
        final pages = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        expect(pages.page, 1);
        await picture(tester, '${brightness.name}-$scale-tasks');
        await tester.tap(tab(0));
        await tester.pumpAndSettle();
        expect(pages.page, 0);
        await picture(tester, '${brightness.name}-$scale-subagents');
        await tester.tapAt(const Offset(10, 30));
        await tester.pumpAndSettle();
        expect(find.byType(PageView), findsNothing);
        expect(find.text('Keep my draft'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('pinned summaries and resizing ${brightness.name} $scale', (
        tester,
      ) async {
        await show(
          tester,
          brightness: brightness,
          scale: scale,
          reduced: scale == 2,
        );
        final panel = find.byKey(const ValueKey('live-work-panel'));
        final handle = find.byKey(const ValueKey('live-work-handle'));
        final composer = tester.getRect(find.byKey(const ValueKey('draft')));
        await tester.tap(tab(1, overlay: false));
        await tester.pumpAndSettle();
        final compact = tester.getRect(panel);
        final gesture = await tester.startGesture(tester.getCenter(handle));
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -140));
        await tester.pump();
        expect(tester.getSize(panel).height, greaterThan(compact.height));
        expect(tester.getSize(panel).height, lessThan(700));
        expect(tester.getRect(panel).bottom, compact.bottom);
        await gesture.moveBy(const Offset(0, -350));
        await gesture.up();
        await tester.pumpAndSettle();
        final expanded = tester.getRect(panel);
        expect(expanded.top, closeTo(8, 1));
        expect(expanded.bottom, compact.bottom);
        expect(find.byTooltip('Collapse drawer'), findsOneWidget);
        expect(tester.getRect(find.byKey(const ValueKey('draft'))), composer);
        final summary = tester.getRect(find.text('Task summary'));
        final first = tester.getTopLeft(
          find.text('Task 0: research metric definitions'),
        );
        await tester.drag(find.byType(PageView), const Offset(0, -140));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text('Task summary')), summary);
        expect(tester.getRect(panel), expanded);
        expect(
          tester
              .getTopLeft(find.text('Task 0: research metric definitions'))
              .dy,
          lessThan(first.dy),
        );
        await picture(tester, '${brightness.name}-$scale-tasks-expanded');
        await tester.tap(tab(0));
        await tester.pumpAndSettle();
        expect(tester.getRect(panel), expanded);
        final agentSummary = tester.getRect(find.text('Agent summary'));
        await tester.drag(find.byType(PageView), const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text('Agent summary')), agentSummary);
        await picture(tester, '${brightness.name}-$scale-agents-expanded');
        // The same handle is an accessible tap/keyboard alternative to dragging.
        await tester.tap(handle);
        await tester.pumpAndSettle();
        expect(tester.getSize(panel).height, compact.height);
        await tester.tap(handle);
        await tester.pumpAndSettle();
        expect(tester.getRect(panel), expanded);
        await tester.fling(handle, const Offset(0, 500), 1000);
        await tester.pumpAndSettle();
        expect(find.byType(PageView), findsNothing);
        expect(tester.getRect(find.byKey(const ValueKey('draft'))), composer);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('vertical grip gestures ${brightness.name} $scale', (
        tester,
      ) async {
        await show(
          tester,
          brightness: brightness,
          scale: scale,
          reduced: scale == 2,
        );
        await tester.enterText(
          find.byKey(const ValueKey('draft')),
          'Keep draft',
        );
        final composer = tester.getRect(find.byKey(const ValueKey('draft')));
        final panel = find.byKey(const ValueKey('live-work-panel'));
        final handle = find.byKey(const ValueKey('live-work-handle'));
        for (final category in [0, 1]) {
          await tester.tap(tab(category, overlay: false));
          await tester.pumpAndSettle();
          final compact = tester.getRect(panel);

          // Slow downward movement follows the finger below compact height.
          final drag = await tester.startGesture(tester.getCenter(handle));
          await drag.moveBy(const Offset(0, 20));
          await tester.pump(const Duration(milliseconds: 100));
          await drag.moveBy(const Offset(0, 80));
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.getSize(panel).height, lessThan(compact.height));
          expect(tester.getRect(panel).bottom, compact.bottom);
          await drag.up();
          await tester.pumpAndSettle();
          expect(dock.currentState!.isOpen, isFalse);
          expect(find.byType(PageView), findsNothing);
          await picture(
            tester,
            '${brightness.name}-$scale-$category-swipe-closed',
          );

          await tester.tap(tab(category, overlay: false));
          await tester.pumpAndSettle();
          expect(tester.getRect(panel), compact);
          // A short flick expands even without crossing half the screen.
          await tester.fling(handle, const Offset(0, -70), 1000);
          await tester.pumpAndSettle();
          expect(tester.getRect(panel).top, closeTo(8, 1));
          await picture(
            tester,
            '${brightness.name}-$scale-$category-swipe-expanded',
          );
          await tester.fling(handle, const Offset(0, 70), 1000);
          await tester.pumpAndSettle();
          expect(find.byType(PageView), findsNothing);

          await tester.tap(tab(category, overlay: false));
          await tester.pumpAndSettle();
          expect(tester.getRect(panel), compact);
          // A cancelled drag restores the previous size instead of dismissing.
          final cancelled = await tester.startGesture(tester.getCenter(handle));
          await cancelled.moveBy(const Offset(0, 20));
          await tester.pump();
          await cancelled.moveBy(const Offset(0, 80));
          await tester.pump();
          await cancelled.cancel();
          await tester.pumpAndSettle();
          expect(tester.getRect(panel), compact);
          expect(dock.currentState!.isOpen, isTrue);
          final short = await tester.startGesture(tester.getCenter(handle));
          await short.moveBy(const Offset(0, 20));
          await tester.pump(const Duration(milliseconds: 150));
          await short.moveBy(const Offset(0, 12));
          await tester.pump(const Duration(milliseconds: 300));
          await short.up();
          await tester.pumpAndSettle();
          expect(tester.getRect(panel), compact);
          expect(dock.currentState!.isOpen, isTrue);
          await tester.tap(tab(category));
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byKey(const ValueKey('draft'))), composer);
          expect(find.text('Keep draft'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('swipe up either dock zone ${brightness.name} $scale', (
        tester,
      ) async {
        await show(
          tester,
          brightness: brightness,
          scale: scale,
          reduced: scale == 2,
        );
        await tester.enterText(
          find.byKey(const ValueKey('draft')),
          'Keep draft',
        );
        final composer = tester.getRect(find.byKey(const ValueKey('draft')));
        final panel = find.byKey(const ValueKey('live-work-panel'));
        final handle = find.byKey(const ValueKey('live-work-handle'));
        for (final category in [0, 1]) {
          await tester.fling(
            tab(category, overlay: false),
            const Offset(35, -70),
            1000,
          );
          await tester.pumpAndSettle();
          expect(dock.currentState!.isOpen, isTrue);
          expect(
            tester.widget<PageView>(find.byType(PageView)).controller!.page,
            category,
          );
          expect(tester.getSize(panel).height, lessThanOrEqualTo(320));
          expect(tester.getRect(panel).top, greaterThan(8));
          await picture(
            tester,
            '${brightness.name}-$scale-$category-zone-compact',
          );
          await tester.fling(tab(category), const Offset(35, -70), 1000);
          await tester.pumpAndSettle();
          expect(tester.getRect(panel).top, closeTo(8, 1));
          expect(tester.getRect(find.byKey(const ValueKey('draft'))), composer);
          await picture(
            tester,
            '${brightness.name}-$scale-$category-zone-expanded',
          );

          await tester.tap(handle);
          await tester.pumpAndSettle();
          expect(tester.getSize(panel).height, lessThanOrEqualTo(320));
          await tester.drag(tab(category), const Offset(0, -100));
          await tester.pumpAndSettle();
          expect(tester.getRect(panel).top, closeTo(8, 1));
          // Swiping the other zone selects its content as well as maximizing.
          await tester.fling(tab(1 - category), const Offset(0, -70), 1000);
          await tester.pumpAndSettle();
          expect(
            tester.widget<PageView>(find.byType(PageView)).controller!.page,
            1 - category,
          );
          expect(tester.getRect(panel).top, closeTo(8, 1));
          await tester.tap(tab(1 - category));
          await tester.pumpAndSettle();
          expect(find.byType(PageView), findsNothing);
          expect(find.text('Keep draft'), findsOneWidget);
        }
        // An interrupted or downward swipe cannot open a folded drawer.
        final cancelled = await tester.startGesture(
          tester.getCenter(tab(0, overlay: false)),
        );
        await cancelled.moveBy(const Offset(0, -20));
        await cancelled.moveBy(const Offset(0, -100));
        await cancelled.cancel();
        await tester.pumpAndSettle();
        expect(find.byType(PageView), findsNothing);
        await tester.fling(tab(1, overlay: false), const Offset(0, 70), 1000);
        await tester.pumpAndSettle();
        expect(find.byType(PageView), findsNothing);
        await tester.fling(
          tab(0, overlay: false),
          const Offset(100, -70),
          1000,
        );
        await tester.pumpAndSettle();
        expect(find.byType(PageView), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('panel uses dominant swipe axis ${brightness.name} $scale', (
        tester,
      ) async {
        await show(
          tester,
          brightness: brightness,
          scale: scale,
          reduced: scale == 2,
        );
        final panel = find.byKey(const ValueKey('live-work-panel'));
        final handle = find.byKey(const ValueKey('live-work-handle'));
        final composer = tester.getRect(find.byKey(const ValueKey('draft')));
        for (final category in [0, 1]) {
          await tester.tap(tab(category, overlay: false));
          await tester.pumpAndSettle();
          expect(tester.getSize(handle).height, 24);
          // A diagonal starting in the rows primarily moves vertically.
          await tester.fling(
            find.byType(PageView),
            const Offset(60, -100),
            1000,
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(panel).top, closeTo(8, 1));
          expect(
            tester.widget<PageView>(find.byType(PageView)).controller!.page,
            category,
          );
          // The larger horizontal component switches categories, without resize.
          await tester.fling(
            find.byType(PageView),
            Offset(category == 0 ? -180 : 180, 100),
            1000,
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<PageView>(find.byType(PageView)).controller!.page,
            1 - category,
          );
          expect(tester.getRect(panel).top, closeTo(8, 1));
          final summary = find.text(
            category == 0 ? 'Task summary' : 'Agent summary',
          );
          await tester.fling(summary, const Offset(60, 100), 1000);
          await tester.pumpAndSettle();
          expect(find.byType(PageView), findsNothing);
          expect(tester.getRect(find.byKey(const ValueKey('draft'))), composer);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('expanded rows scroll then hand downward motion to the panel', (
    tester,
  ) async {
    await show(tester);
    await tester.fling(tab(1, overlay: false), const Offset(30, -100), 1000);
    await tester.pumpAndSettle();
    await tester.fling(tab(1), const Offset(30, -100), 1000);
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('live-work-panel'));
    final expanded = tester.getRect(panel);
    final scroll = find
        .descendant(
          of: find.byType(PageView),
          matching: find.byType(SingleChildScrollView),
        )
        .last;
    final position = tester
        .widget<SingleChildScrollView>(scroll)
        .controller!
        .position;
    await tester.drag(scroll, const Offset(30, -180));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(30));
    final before = position.pixels;
    await tester.drag(scroll, const Offset(10, 30));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(before));
    expect(position.pixels, greaterThan(0));
    expect(tester.getRect(panel), expanded);
    await tester.drag(scroll, const Offset(60, 400));
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swiped subagents show held read feedback on the first frame', (
    tester,
  ) async {
    final gate = Completer<void>();
    await show(tester, refresh: () => gate.future);
    await tester.fling(tab(0, overlay: false), const Offset(35, -100), 1000);
    await tester.pump();
    expect(dock.currentState!.isOpen, isTrue);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('keyboard grip resizes immediately and reopening resets height', (
    tester,
  ) async {
    await show(tester, keyboard: 260);
    await tester.tap(tab(1, overlay: false));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('live-work-panel'));
    final handle = find.byKey(const ValueKey('live-work-handle'));
    final compact = tester.getRect(panel);
    final grip = find.descendant(of: handle, matching: find.byType(Container));
    Focus.of(tester.element(grip)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.getRect(panel).top, closeTo(8, 1));
    expect(tester.getRect(panel).bottom, compact.bottom);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(tester.getRect(panel), compact);
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(tester.getRect(panel).top, closeTo(8, 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
    await tester.tap(tab(1, overlay: false));
    await tester.pumpAndSettle();
    expect(tester.getRect(panel), compact);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap and swift thumb release both settle at 220 ms', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(tab(0, overlay: false));
    await tester.pumpAndSettle();
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    await tester.tap(tab(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(pages.page, greaterThan(0));
    expect(pages.page, lessThan(1));
    await tester.pump(const Duration(milliseconds: 110));
    expect(pages.page, closeTo(1, .001));
    await tester.fling(find.byType(PageView), const Offset(80, 0), 1500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(pages.page, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 110));
    expect(pages.page, closeTo(0, .001));
    await tester.fling(find.byType(PageView), const Offset(-80, 0), 1500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(pages.page, greaterThan(0));
    expect(pages.page, lessThan(1));
    await tester.pump(const Duration(milliseconds: 110));
    expect(pages.page, closeTo(1, .001));
    expect(tester.takeException(), isNull);
  });
  testWidgets('vertical scroll, reduced motion, Back and retirement', (
    tester,
  ) async {
    await show(tester, reduced: true, keyboard: 260);
    await tester.tap(tab(1, overlay: false));
    await tester.pumpAndSettle();
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    await tester.drag(find.byType(PageView), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    await tester.tap(tab(0));
    await tester.pump();
    expect(pages.page, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
    await tester.tap(tab(1, overlay: false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'background joins a populated dock and retires without moving the composer',
    (tester) async {
      int? processes;
      var agents = 2, tasks = 1;
      var processReads = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 360,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ProfileLiveWorkDock(
                          key: dock,
                          taskCount: tasks,
                          completedTasks: 0,
                          subagentCount: agents,
                          processCount: processes,
                          taskSummary: const Text('Tasks summary'),
                          subagentSummary: const Text('Agents summary'),
                          processSummary: const Text('Process summary'),
                          tasks: const SizedBox(height: 80),
                          subagents: const SizedBox(height: 80),
                          processes: const SizedBox(
                            height: 80,
                            child: Text('Command'),
                          ),
                          onAgentsSelected: () async {},
                          onProcessesSelected: () async {
                            processReads++;
                          },
                        ),
                        const TextField(key: ValueKey('draft')),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final composer = tester.getRect(find.byKey(const ValueKey('draft')));
      await tester.tap(tab(1, overlay: false));
      await tester.pumpAndSettle();
      update(() => processes = 1);
      await tester.pumpAndSettle();
      final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
      expect(pages.page, 1);
      expect(processReads, 0, reason: 'Kept-alive pages do not initiate reads');
      for (final id in [0, 1, 2]) {
        expect(tester.getSize(tab(id)).width, 120);
      }
      await tester.tap(tab(2));
      await tester.pumpAndSettle();
      expect(pages.page, 2);
      expect(processReads, 1);
      await tester.fling(find.byType(PageView), const Offset(220, 0), 1000);
      await tester.pumpAndSettle();
      expect(pages.page, 1);
      await tester.tap(tab(2));
      await tester.pumpAndSettle();
      update(() {
        agents = 0;
        tasks = 0;
      });
      await tester.pumpAndSettle();
      expect(pages.page, 0);
      expect(tester.getSize(tab(2)).width, 360);
      expect(tester.getRect(find.byKey(const ValueKey('draft'))), composer);
      update(() => processes = null);
      await tester.pumpAndSettle();
      expect(find.byType(PageView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selected subagent read has immediate retained feedback', (
    tester,
  ) async {
    final gate = Completer<void>();
    await show(tester, refresh: () => gate.future);
    await tester.tap(tab(0, overlay: false));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
  for (final (first, reduced) in [
    (0, false),
    (1, false),
    (0, true),
    (1, true),
  ]) {
    testWidgets(
      'nonempty tabs appear and retain selected page from $first reduced=$reduced',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var agents = first == 0 ? 1 : 0;
        var tasks = first == 1 ? 1 : 0;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: 360,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      update = setState;
                      return ProfileLiveWorkDock(
                        taskSummary: const Text('Task summary'),
                        subagentSummary: const Text('Agent summary'),
                        key: dock,
                        taskCount: tasks,
                        completedTasks: 0,
                        subagentCount: agents,
                        onAgentsSelected: () async {},
                        tasks: const SizedBox(
                          height: 160,
                          child: Text('Task content'),
                        ),
                        subagents: const SizedBox(
                          height: 80,
                          child: Text('Agent content'),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tab(1 - first, overlay: false), findsNothing);
        expect(tester.getSize(tab(first, overlay: false)).width, 360);
        expect(find.byKey(const ValueKey('live-work-divider')), findsNothing);
        await tester.tap(tab(first, overlay: false));
        await tester.pumpAndSettle();
        final panel = find.byKey(const ValueKey('live-work-panel'));
        final originalHeight = tester.getSize(panel).height;
        await tester.tap(tab(first));
        await tester.pumpAndSettle();
        await tester.fling(
          tab(first, overlay: false),
          const Offset(30, -100),
          1000,
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(panel).height, originalHeight);
        final bottom = tester.getRect(tab(first)).bottom;
        update(() {
          agents = 1;
          tasks = 1;
        });
        await tester.pump();
        if (reduced) {
          expect(
            tester
                .getSize(
                  find.byKey(ValueKey(('live-work-tab-slot', 1 - first, true))),
                )
                .width,
            180,
          );
        }
        await tester.pump(const Duration(milliseconds: 70));
        // Reveal a second control while the existing tab gives it space.
        final growing = tester
            .getSize(
              find.byKey(ValueKey(('live-work-tab-slot', 1 - first, true))),
            )
            .width;
        expect(growing, greaterThan(0));
        if (reduced) {
          expect(growing, 180);
        } else {
          expect(growing, lessThan(180));
        }
        await tester.pumpAndSettle();
        expect(tester.getSize(tab(first)).width, 180);
        expect(tester.getRect(tab(first)).bottom, bottom);
        final pages = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        expect(pages.page, first);
        expect(tester.getSize(panel).height, originalHeight);
        // Removing the selected category selects the remaining populated page.
        update(() {
          if (first == 0) {
            agents = 0;
          } else {
            tasks = 0;
          }
        });
        await tester.pumpAndSettle();
        expect(tab(first), findsNothing);
        expect(pages.page, 0);
        expect(tester.getSize(tab(1 - first)).width, 360);
        expect(
          tester.getSize(panel).height,
          first == 0 ? greaterThan(originalHeight) : lessThan(originalHeight),
        );
        update(() {
          agents = 0;
          tasks = 0;
        });
        await tester.pumpAndSettle();
        expect(find.byType(PageView), findsNothing);
        expect(find.byType(TextButton), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('drawer fits, interpolates on tap and drag, and caps scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var taskHeight = 180.0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 360,
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return ProfileLiveWorkDock(
                    taskSummary: const Text('Task summary'),
                    subagentSummary: const Text('Agent summary'),
                    key: dock,
                    taskCount: 1,
                    completedTasks: 0,
                    subagentCount: 1,
                    onAgentsSelected: () async {},
                    tasks: SizedBox(
                      height: taskHeight,
                      child: const Text('Task content'),
                    ),
                    subagents: const SizedBox(
                      height: 80,
                      child: Text('Agent content'),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(tab(0, overlay: false));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('live-work-panel'));
    final bottom = tester.getBottomLeft(panel).dy;
    final agentHeight = tester.getSize(panel).height;
    await tester.tap(tab(1));
    await tester.pumpAndSettle();
    final naturalTaskHeight = tester.getSize(panel).height;
    expect(naturalTaskHeight, greaterThan(agentHeight));
    await tester.tap(tab(0));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, agentHeight);
    await tester.tap(tab(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(tester.getSize(panel).height, greaterThan(agentHeight));
    expect(tester.getSize(panel).height, lessThan(naturalTaskHeight));
    expect(tester.getBottomLeft(panel).dy, bottom);
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, naturalTaskHeight);
    final gesture = await tester.startGesture(tester.getCenter(panel));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(tester.getSize(panel).height, greaterThan(agentHeight));
    expect(tester.getSize(panel).height, lessThan(naturalTaskHeight));
    expect(tester.getBottomLeft(panel).dy, bottom);
    await gesture.up();
    await tester.pumpAndSettle();
    // Return to Tasks if the partial drag settled on Subagents.
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    if (pages.page == 0) {
      await tester.tap(tab(1));
      await tester.pumpAndSettle();
    }
    update(() => taskHeight = 1000);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(tester.getSize(panel).height, greaterThan(naturalTaskHeight));
    expect(tester.getSize(panel).height, lessThan(320));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, 320);
    final scroll = find
        .descendant(
          of: find.byType(PageView),
          matching: find.byType(SingleChildScrollView),
        )
        .last;
    await tester.tap(find.byKey(const ValueKey('live-work-handle')));
    await tester.pumpAndSettle();
    final expandedContent = tester.getTopLeft(find.text('Task content')).dy;
    await tester.drag(scroll, const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Task content')).dy,
      lessThan(expandedContent),
    );
    expect(pages.page, 1);
    await tester.tap(find.byKey(const ValueKey('live-work-handle')));
    await tester.pumpAndSettle();
    update(() => taskHeight = 120);
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, greaterThan(agentHeight));
    expect(tester.getSize(panel).height, lessThan(naturalTaskHeight));
    expect(tester.getBottomLeft(panel).dy, bottom);
    Focus.of(tester.element(tab(1))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(pages.page, 0);
    expect(tester.getSize(panel).height, agentHeight);
    expect(tester.getBottomLeft(panel).dy, bottom);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a folded dock retires without creating a late ticker', (
    tester,
  ) async {
    await show(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
