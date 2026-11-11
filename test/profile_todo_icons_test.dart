import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_todo.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_activity_tabs.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_live_work_dock.dart';

const _capture = bool.fromEnvironment('CAPTURE_TASK_ICONS');
const _todos = [
  GatewayTodo(
    id: 'task-1',
    content: 'Audit original sources and create blind calibration cases',
    status: GatewayTodoStatus.completed,
  ),
  GatewayTodo(
    id: 'task-2',
    content:
        'Independently grade real answers and controlled variants. '
        'Keep all original evidence available while reviewing source quality. '
        'Dispatch and building labels are not completion. '
        'Resolve each remaining source decision before starting the next review. '
        'Record the findings and preserve the complete review notes.',
    status: GatewayTodoStatus.inProgress,
  ),
  GatewayTodo(
    id: 'task-3',
    parent: 'task-2',
    content: 'Resolve the remaining source-scope decision',
    status: GatewayTodoStatus.pending,
  ),
  GatewayTodo(
    id: 'task-4',
    content: 'Repeat the superseded comparison',
    status: GatewayTodoStatus.cancelled,
  ),
];

void main() {
  setUpAll(() async {
    if (!_capture) return;
    const dir = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$dir/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'task selection does not paint handles outside the reading viewport: $brightness/$scale',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final frame = GlobalKey();
          final content = List.generate(
            30,
            (i) => 'Task line $i to inspect',
          ).join('\n');
          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 350,
                      height: 400,
                      child: ProfileTodoPanel(
                        embedded: true,
                        todos: [
                          GatewayTodo(
                            id: 'selection',
                            content: content,
                            status: GatewayTodoStatus.inProgress,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byTooltip('Expand task'));
          await tester.pumpAndSettle();
          final preview = find.byKey(const ValueKey('activity-content-scroll'));
          final scroll = tester
              .widget<SingleChildScrollView>(preview)
              .controller!;
          scroll.jumpTo(100);
          await tester.pumpAndSettle();
          Future<({ByteData data, int width, int height})> pixels() async =>
              (await tester.runAsync(() async {
                final image =
                    await (frame.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                try {
                  final data = await image.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  );
                  return (
                    data: data!,
                    width: image.width,
                    height: image.height,
                  );
                } finally {
                  image.dispose();
                }
              }))!;
          final before = await pixels();
          await tester.longPressAt(tester.getRect(preview).center);
          await tester.pumpAndSettle();
          final editable = tester.state<EditableTextState>(
            find.byType(EditableText),
          );
          // Use the same native controls at both scales, including overflow
          // when the selection toolbar cannot fit every action.
          final selectAll = find.text('Select all');
          if (selectAll.hitTestable().evaluate().isEmpty) {
            final more = find.descendant(
              of: find.byType(TextSelectionToolbar),
              matching: find.byTooltip(
                MaterialLocalizations.of(editable.context).moreButtonTooltip,
              ),
            );
            expect(more.hitTestable(), findsOneWidget);
            await tester.tap(more);
            await tester.pumpAndSettle();
          }
          expect(selectAll.hitTestable(), findsOneWidget);
          await tester.tap(selectAll);
          await tester.pumpAndSettle();
          expect(
            editable.widget.controller.selection.textInside(
              editable.widget.controller.text,
            ),
            content,
          );
          // Isolate selection painting from the separate context-menu overlay.
          editable.hideToolbar(false);
          scroll.jumpTo(100);
          await tester.pumpAndSettle();
          if (_capture) {
            await tester.runAsync(() async {
              final image =
                  await (frame.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/design-previews/task-selection/${brightness.name}-$scale.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }
          final after = await pixels();
          expect((after.width, after.height), (before.width, before.height));
          final visible = tester.getRect(preview);
          var outsideChanges = 0;
          var insideChanges = 0;
          for (var y = 0; y < after.height; y++) {
            for (var x = 0; x < after.width; x++) {
              final i = (y * after.width + x) * 4;
              if (before.data.getUint32(i) == after.data.getUint32(i)) continue;
              if (visible.contains(Offset(x.toDouble(), y.toDouble()))) {
                insideChanges++;
              } else {
                outsideChanges++;
              }
            }
          }
          expect(
            insideChanges,
            greaterThan(0),
            reason: 'Selection must be painted',
          );
          expect(
            outsideChanges,
            0,
            reason:
                'Selecting hidden task text must not paint selection handles over the surrounding screen',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('in-progress tasks retain their static semantic glyph', (
    tester,
  ) async {
    {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileTodoPanel(
              embedded: true,
              todos: const [
                GatewayTodo(
                  id: 'task-5',
                  content: 'Inspect the current result',
                  status: GatewayTodoStatus.inProgress,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Inspect the current result'), findsOneWidget);
      expect(find.byType(StudioLoading), findsNothing);
      expect(find.byIcon(Icons.timelapse), findsOneWidget);
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('task states fit and remain accessible: $brightness/$scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        final boundary = GlobalKey();
        try {
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      ProfileActivitySection(
                        label: 'Activity',
                        initiallyExpanded: true,
                        detailsBuilder: (_) => const ProfileActivityTabs(
                          tabs: [
                            ProfileActivityTab(
                              id: 'tasks',
                              label: 'Tasks 1/4',
                              child: ProfileTodoPanel(
                                todos: _todos,
                                embedded: true,
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
          for (final label in [
            'Completed task',
            'Task in progress',
            'Pending task',
            'Cancelled task',
          ]) {
            expect(find.bySemanticsLabel(label), findsOneWidget);
          }
          expect(find.byIcon(Icons.flag_outlined), findsNothing);
          expect(
            tester.widget<Icon>(find.byIcon(Icons.check_circle)).color,
            WingTokens.forBrightness(brightness).success,
          );
          expect(find.byIcon(Icons.block), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
        Future<void> capture(String state) async {
          if (!_capture) return;
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/design-previews/task-disclosure/site/${brightness.name}-$scale-$state.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('collapsed');
        final running = find.byKey(const ValueKey(('todo', 'task-2')));
        final expand = find.descendant(
          of: running,
          matching: find.byTooltip('Expand task'),
        );
        await tester.ensureVisible(expand);
        // The task text is a disclosure target, not only the chevron.
        await tester.tap(find.text(_todos[1].content));
        await tester.pump();
        expect(find.byType(SelectableText), findsOneWidget);
        // Status and blank padding must toggle the same row, too.
        final status = find.descendant(
          of: running,
          matching: find.text('In progress'),
        );
        await tester.tap(status);
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsNothing);
        await tester.tapAt(tester.getTopLeft(expand) + const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsOneWidget);
        await tester.tap(status);
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsNothing);
        // Vertical scrolling on the header must not open the task.
        await tester.drag(find.text(_todos[1].content), const Offset(0, -30));
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsNothing);
        await tester.ensureVisible(expand);
        Focus.of(tester.element(find.text(_todos[1].content))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsNothing);
        await tester.tap(
          find.descendant(
            of: running,
            matching: find.byIcon(Icons.chevron_right),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture('expanded');
        final contentScroll = find.descendant(
          of: running,
          matching: find.byKey(const ValueKey('activity-content-scroll')),
        );
        await tester.ensureVisible(contentScroll);
        await tester.tap(contentScroll);
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsOneWidget);
        await tester.drag(contentScroll, const Offset(0, -140));
        await tester.pumpAndSettle();
        expect(
          tester
              .state<ScrollableState>(
                find
                    .descendant(
                      of: contentScroll,
                      matching: find.byType(Scrollable),
                    )
                    .first,
              )
              .position
              .pixels,
          greaterThan(0),
        );
        final collapse = find.descendant(
          of: running,
          matching: find.byTooltip('Collapse task'),
        );
        await tester.ensureVisible(collapse);
        await tester.tap(collapse);
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'task disclosures follow IDs through updates and backend reordering',
    (tester) async {
      var todos = _todos;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return ProfileTodoPanel(embedded: true, todos: todos);
                },
              ),
            ),
          ),
        ),
      );
      Finder row(String id) => find.byKey(ValueKey(('todo', id)));
      Finder control(String id, String label) =>
          find.descendant(of: row(id), matching: find.byTooltip(label));
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(control('task-2', 'Expand task'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(control('task-1', 'Expand task'), findsOneWidget);
      expect(control('task-2', 'Collapse task'), findsOneWidget);

      update(
        () => todos = [
          _todos[3],
          const GatewayTodo(
            id: 'task-2',
            content: 'Updated review notes',
            status: GatewayTodoStatus.completed,
          ),
          _todos[0],
          _todos[2],
          const GatewayTodo(
            id: 'new',
            content: 'Newly received task',
            status: GatewayTodoStatus.pending,
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Updated review notes'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(control('task-2', 'Collapse task'), findsOneWidget);
      expect(control('new', 'Expand task'), findsOneWidget);
      final positions = todos
          .map((todo) => tester.getTopLeft(row(todo.id)).dy)
          .toList();
      expect(positions, orderedEquals([...positions]..sort()));
      await tester.tap(control('task-2', 'Collapse task'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(control('task-2', 'Expand task'));
      await tester.pumpAndSettle();
      update(() => todos = [_todos[0]]);
      await tester.pumpAndSettle();
      update(() => todos = [_todos[0], _todos[1]]);
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      expect(control('task-2', 'Expand task'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task expansion works inside the dock without moving the composer',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: Text('Conversation')),
                ProfileLiveWorkDock(
                  taskSummary: const ProfileTodoSummary(todos: _todos),
                  subagentSummary: const Text('Agent summary'),
                  taskCount: 4,
                  completedTasks: 1,
                  subagentCount: 1,
                  tasks: const ProfileTodoPanel(
                    embedded: true,
                    showSummary: false,
                    todos: _todos,
                  ),
                  subagents: const Text('Subagent review'),
                  onAgentsSelected: () async {},
                ),
                const SizedBox(
                  height: 60,
                  child: TextField(key: ValueKey('composer')),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final composerTop = tester.getTopLeft(
        find.byKey(const ValueKey('composer')),
      );
      await tester.tap(find.byKey(const ValueKey(('live-work-tab', 1, false))));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      final running = find.byKey(const ValueKey(('todo', 'task-2')));
      final expand = find.descendant(
        of: running,
        matching: find.byTooltip('Expand task'),
      );
      await tester.ensureVisible(expand);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      final contentScroll = find.descendant(
        of: running,
        matching: find.byKey(const ValueKey('activity-content-scroll')),
      );
      await tester.drag(contentScroll, const Offset(25, -140));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('live-work-panel'))).top,
        closeTo(8, 1),
      );
      await tester.drag(contentScroll, const Offset(25, -140));
      await tester.pumpAndSettle();
      final reader = tester.state<ScrollableState>(
        find
            .descendant(of: contentScroll, matching: find.byType(Scrollable))
            .first,
      );
      expect(reader.position.pixels, greaterThan(0));
      await tester.longPressAt(tester.getRect(contentScroll).center);
      await tester.pumpAndSettle();
      final selected = tester.widget<EditableText>(
        find.descendant(of: running, matching: find.byType(EditableText)),
      );
      expect(selected.controller.selection.isCollapsed, isFalse);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('composer'))),
        composerTop,
      );
      await tester.tap(find.byKey(const ValueKey(('live-work-tab', 0, true))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey(('live-work-tab', 1, true))));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: running, matching: find.byTooltip('Collapse task')),
        findsOneWidget,
      );
      // A downward swipe inside the nested reader returns to its start, then
      // closes the same drawer rather than trapping movement in the text.
      await tester.drag(contentScroll, const Offset(50, 1800));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('live-work-panel')), findsNothing);
      await tester.tap(find.byKey(const ValueKey(('live-work-tab', 1, false))));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: running, matching: find.byTooltip('Expand task')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completion updates the task state glyph and count', (
    tester,
  ) async {
    var status = GatewayTodoStatus.inProgress;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ProfileTodoPanel(
                todos: [
                  GatewayTodo(id: 'task-6', content: 'Review', status: status),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Tasks 0/1'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.timelapse), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    update(() => status = GatewayTodoStatus.completed);
    await tester.pumpAndSettle();
    expect(find.text('Tasks 1/1'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
