import 'package:wing/core/widgets/source_code_text.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/gateway_todo.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/presentation/saved_activity.dart';
import 'package:wing/core/presentation/tool_call_presentation.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_supervision_session.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_background_work_panel.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_goal_panel.dart';
import 'package:wing/core/widgets/profile_saved_agents.dart';
import 'package:wing/core/widgets/profile_subagent_panel.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';

import 'helpers/pump_markdown_widget.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';

const _capture = bool.fromEnvironment('CAPTURE_ACTIVITY_FAMILY');
const _agentHeading =
    'Review the report and compare every supplied record against the original source';
const _agentTask =
    '$_agentHeading. Check source dates and preserve every instruction in the task. Report uncertainty separately from confirmed results.';

class _FamilyFixture extends ProfileActionsFixture {
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      rpc: (method, params) async => switch (method) {
        'subagent.list' => {
          'subagents': [
            {
              'subagent_id': 'agent',
              'goal': _agentTask,
              'status': 'running',
              'model': 'review-model',
              'accepting_steer': true,
              'tool_count': 3,
            },
          ],
          'delegations': [],
        },
        'subagent.tail' => {
          'subagent_id': 'agent',
          'available': true,
          'text': 'Read report.py\nFound two records to review.\n',
          'truncated': false,
        },
        'process.list' => {
          'processes': [
            {
              'session_id': 'process',
              'command': 'python  report.py',
              'cwd': '/workspace',
              'status': 'running',
              'output_tail': 'Checked 7 records\nReport saved\n',
              'uptime_seconds': 4,
            },
          ],
        },
        'session.control.read' => {
          'control': {
            'revision': 'family',
            'updated_at': 1,
            'goal': {
              'title': 'Verify the report',
              'status': 'active',
              'turns_used': 2,
              'max_turns': 8,
              'contract': {
                'outcome': 'An accurate report',
                'verification': 'Run the checks',
                'constraints': '',
                'boundaries': '',
                'stop_when': '',
              },
              'subgoals': ['Check source records'],
              'gates': [],
            },
            'loop': {
              'prompt': 'Check the report queue',
              'status': 'active',
              'mode': 'interval',
              'interval_seconds': 300,
              'current_delay': 300,
              'times': 6,
              'until': '',
              'max_ticks': 0,
              'ticks_fired': 3,
              'created_at': 1,
              'last_fired_at': 2,
              'next_due_at': 0,
              'awaiting_response': false,
              'deferred_by_goal': false,
            },
            'heartbeat': {
              'prompt': 'Report service health',
              'status': 'paused',
              'interval_seconds': 900,
              'created_at': 1,
              'last_fired_at': 2,
              'fire_count': 4,
            },
          },
        },
        _ => base.call(method, params),
      },
    );
  }
}

ToolCallPresentation _call(
  String name,
  Map<String, dynamic> args,
  Object result,
) => ToolCallPresentation.live(
  GatewayToolActivity.fromGatewayEvent('tool.complete', {
    'tool_id': name,
    'name': name,
    'args': args,
    'result': result,
  })!,
);

void main() {
  setUpAll(() async {
    if (!_capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
      'monospace': 'DejaVuSansMono.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$root/${entry.value}',
            ).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final (format, markdown) in [
        (ToolDetailFormat.prose, false),
        (ToolDetailFormat.prose, true),
        (ToolDetailFormat.source, false),
        (ToolDetailFormat.diff, false),
      ]) {
        testWidgets(
          '${format.name} markdown=$markdown activity text scrolls ${brightness.name} $scale',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
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
            copied = null;
            final text =
                '# Supplied details\n\n${List.generate(50, (i) => '- Record $i: ${List.filled(8, 'long supplied text ').join()}').join('\n')}\n\nLast received line';
            final block = ToolDetailBlock(
              label: 'Content',
              text: text,
              format: format,
              markdown: markdown,
              copyable: true,
            );
            final outer = ScrollController();
            addTearDown(outer.dispose);
            final boundary = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: wingTheme(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: SingleChildScrollView(
                      controller: outer,
                      child: ActivityDetailsCard(
                        children: [
                          ActivityDetailSection(block: block),
                          const ActivityDetailStatus(label: 'Completed'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.settleMarkdown();
            await tester.pumpAndSettle();
            await tester.pumpAndSettle();
            if (_capture) {
              await tester.runAsync(() async {
                final rendered =
                    await (boundary.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                final data = await rendered.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/activity-family/scroll-${format.name}-$markdown-${brightness.name}-${scale.toInt()}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(data!.buffer.asUint8List());
                rendered.dispose();
              });
            }
            expect(find.text('Preview'), findsNothing);
            expect(find.text('Full text'), findsNothing);
            expect(find.byTooltip('Expand Content'), findsNothing);
            final sourceRegion = find.byType(SourceCodeText);
            final region = sourceRegion.evaluate().isNotEmpty
                ? sourceRegion
                : find.byKey(const ValueKey('activity-content-scroll'));
            expect(tester.getSize(region).height, 160);
            final inline = tester
                .state<ScrollableState>(
                  find
                      .descendant(
                        of: region,
                        matching: find.byWidgetPredicate(
                          (widget) =>
                              widget is Scrollable &&
                              widget.axisDirection == AxisDirection.down,
                        ),
                      )
                      .first,
                )
                .position;
            final source = markdown
                ? tester
                      .widget<MarkdownMessageContent>(
                        find.byType(MarkdownMessageContent),
                      )
                      .data
                : sourceRegion.evaluate().isNotEmpty
                ? tester.widget<SourceCodeText>(sourceRegion).text
                : tester
                      .widget<SelectableText>(find.byType(SelectableText))
                      .textSpan!
                      .toPlainText();
            expect(source, text);
            await tester.drag(region, const Offset(0, -100));
            await tester.pumpAndSettle();
            expect(inline.pixels, greaterThan(0));
            expect(outer.offset, 0);
            inline.jumpTo(inline.maxScrollExtent);
            await tester.pump();
            expect(inline.pixels, inline.maxScrollExtent);
            await tester.tap(find.byTooltip('Copy Content'));
            await tester.pump();
            expect(copied, text);
            await tester.pump(const Duration(seconds: 2));
            await tester.tap(find.byTooltip('Open Content'));
            await tester.pumpAndSettle();
            await tester.settleMarkdown();
            await tester.pumpAndSettle();
            final full = find.byWidgetPredicate(
              (widget) => widget is ActivityDetailSection && widget.full,
            );
            expect(full, findsOneWidget);
            expect(tester.widget<ActivityDetailSection>(full).block.text, text);
            expect(
              find.descendant(
                of: full,
                matching: find.byKey(const ValueKey('activity-content-scroll')),
              ),
              findsNothing,
            );
            expect(find.byTooltip('Open Content'), findsNothing);
            await tester.pumpWidget(const SizedBox.shrink());

            expect(tester.takeException(), isNull);
          },
        );
      }
      for (final specimenName in [
        'tasks',
        'saved-agents',
        'skill',
        'dispatched-agents',
        'agents',
        'work',
        'processes',
        'goals',
        'reasoning',
        'search',
        'write',
        'web',
      ]) {
        testWidgets('$specimenName activity family ${brightness.name} $scale', (
          tester,
        ) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final fixture = _FamilyFixture();
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'family',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: fixture.gateway,
          );
          await controller.initialize();
          final chat = await controller.createChat(canDispatch: () => true);
          final session = ProfileSupervisionSession(
            controller: controller,
            chat: chat,
          );
          if (specimenName == 'processes') await session.refreshProcesses();
          addTearDown(() {
            session.dispose();
            controller.dispose();
            appPreferences.dispose();
          });
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final saved = SavedActivity(
            TranscriptTimeline.project(
              [
                {
                  'id': 1,
                  'role': 'tool',
                  'tool_name': 'delegate_task',
                  'args': {
                    'tasks': [
                      {'goal': _agentTask},
                    ],
                  },
                  'content': jsonEncode({
                    'results': [
                      {
                        'task_index': 0,
                        'status': 'completed',
                        'summary':
                            '## Review\nTwo records checked.\n\n- Dates are clear\n- No clipping found',
                        'duration_seconds': 4,
                      },
                    ],
                  }),
                },
              ],
              presentationId: (row) => row['id']!,
            ).sections.expand((s) => s.groups).expand((g) => g.toolResults),
          ).agents;
          final specimens = <String, Widget>{
            'tasks': const ProfileTodoPanel(
              embedded: true,
              todos: [
                GatewayTodo(
                  id: 'task-1',
                  content: 'Read the report and check the dates',
                  status: GatewayTodoStatus.completed,
                ),
                GatewayTodo(
                  id: 'task-2',
                  content: 'Review the remaining record',
                  status: GatewayTodoStatus.pending,
                  parent: 'review',
                ),
              ],
            ),
            'saved-agents': ProfileSavedAgents(agents: saved),
            'skill': ToolActivityDetailsView(
              call: ToolCallPresentation.live(
                GatewayToolActivity.fromGatewayEvent('tool.complete', {
                  'tool_id': 'skill',
                  'name': 'skill_view',
                  'args': {'name': 'inspect-build'},
                  'result': {
                    'success': true,
                    'name': 'inspect-build',
                    'description':
                        'Inspect build output and find the first actionable error.',
                    'tags': ['build', 'review'],
                    '_source_path': '/workspace/skills/inspect-build/SKILL.md',
                    'content':
                        '---\nname: inspect-build\nversion: 1.0\nauthor: Example\nlicense: MIT\n---\n# Inspect build\n\n## When to use\nRead the actual build error before changing code.\n\n## Workflow\n1. Find the first failure.\n2. Check its source.\n3. Verify the fix.\n',
                  },
                })!,
              ),
              onShareResource: (_) async {},
            ),
            'dispatched-agents': ProfileSavedAgents(
              agents: SavedActivity(
                TranscriptTimeline.project(
                  [
                    {
                      'id': 2,
                      'role': 'tool',
                      'tool_name': 'delegate_task',
                      'content': jsonEncode({
                        'status': 'dispatched',
                        'goals': [_agentTask],
                      }),
                    },
                  ],
                  presentationId: (row) => row['id']!,
                ).sections.expand((s) => s.groups).expand((g) => g.toolResults),
              ).agents,
            ),
            'agents': ProfileSubagentPanel(
              session: session,
              createResources: controller.traceResources,
              initiallyExpanded: true,
            ),
            'work': ProfileBackgroundWorkPanel(
              session: session,
              initiallyExpanded: true,
            ),
            'processes': ProfileProcessPanel(session: session),
            'goals': ProfileGoalPanel(
              session: session,
              initiallyExpanded: true,
            ),
            'reasoning': const ProfileReasoningDisclosure(
              text:
                  'Compare the returned records before checking the summary.\n\nThe date fields require a separate review.',
            ),
            'search': ProfileToolCall(
              initiallyExpanded: true,
              call: _call(
                'search_files',
                {'pattern': 'report', 'path': '/workspace'},
                {
                  'matches': [
                    {
                      'path': '/workspace/report.py',
                      'line': 9,
                      'content': 'print("report ready")',
                    },
                    {
                      'path': '/workspace/report.py',
                      'line': 15,
                      'content': 'report.save()',
                    },
                  ],
                  'total_count': 2,
                },
              ),
            ),
            'write': ProfileToolCall(
              initiallyExpanded: true,
              call: _call(
                'write_file',
                {
                  'path': '/workspace/report.py',
                  'content': 'print("report ready")\n',
                },
                {
                  'bytes_written': 22,
                  'verified': true,
                  'lint': {'status': 'ok', 'output': 'Syntax checked'},
                  'lsp_diagnostics':
                      'LSP diagnostics introduced by this edit:\n<diagnostics file="/workspace/report.py">Unknown report type.</diagnostics>',
                },
              ),
            ),
            'web': ProfileToolCall(
              initiallyExpanded: true,
              call: _call(
                'web_search',
                {'query': 'report documentation'},
                {
                  'results': [
                    {
                      'title': 'Report guide',
                      'url': 'https://example.org/guide',
                      'snippet':
                          '## Format\nKeep source dates beside each record.',
                    },
                  ],
                },
              ),
            ),
          };
          for (final entry in specimens.entries.where(
            (entry) => entry.key == specimenName,
          )) {
            final boundary = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: wingTheme(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(scale),
                      disableAnimations: true,
                    ),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: entry.value,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            if (entry.key == 'saved-agents' ||
                entry.key == 'dispatched-agents') {
              await tester.tap(find.text(_agentHeading));
              await tester.pumpAndSettle();
              expect(
                find.text(
                  entry.key == 'saved-agents'
                      ? 'Completed'
                      : 'Dispatched in background',
                ),
                findsOneWidget,
              );
            } else if (entry.key == 'agents') {
              await tester.tap(find.text(_agentHeading));
              await tester.pumpAndSettle();
            } else if (entry.key == 'processes') {
              await tester.ensureVisible(find.text('python report.py'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('python report.py'));
              await tester.pumpAndSettle();
            } else if (entry.key == 'reasoning') {
              await tester.tap(find.text('Reasoning'));
              await tester.pumpAndSettle();
            }
            await tester.settleMarkdown();
            await tester.pumpAndSettle();
            expect(find.text('Preview'), findsNothing, reason: entry.key);
            expect(find.text('Full text'), findsNothing, reason: entry.key);
            expect(
              find.byType(ActivityDetailsCard),
              findsWidgets,
              reason: entry.key,
            );
            for (final card in tester.widgetList<ActivityDetailsCard>(
              find.byType(ActivityDetailsCard),
            )) {
              final frame = tester.widget<Container>(
                find
                    .descendant(
                      of: find.byWidget(card),
                      matching: find.byType(Container),
                    )
                    .first,
              );
              final decoration = frame.decoration! as BoxDecoration;
              expect(frame.margin, const EdgeInsets.symmetric(vertical: 4));
              expect(
                decoration.color,
                WingTokens.forBrightness(brightness).raised,
              );
              expect(decoration.borderRadius, WingRadius.card);
            }
            for (final section
                in find.byType(ActivityDetailSection).evaluate()) {
              final sectionWidget = section.widget as ActivityDetailSection;
              if (sectionWidget.showHeader &&
                  sectionWidget.headerBuilder == null) {
                final frame = find
                    .descendant(
                      of: find.byWidget(section.widget),
                      matching: find.byType(Container),
                    )
                    .first;
                final header = tester.getRect(frame);
                final heading = find
                    .descendant(
                      of: frame,
                      matching: find.text(sectionWidget.block.label),
                    )
                    .first;
                final headingBounds = tester.getRect(heading);
                expect(
                  header.intersect(headingBounds),
                  headingBounds,
                  reason: '${entry.key} heading stays within its header',
                );
              } else {
                // The resource header owns all actions for this payload. The body
                // must not repeat a section heading or a second copy/viewer row.
                expect(
                  find.descendant(
                    of: find.descendant(
                      of: find.byWidget(section.widget),
                      matching: find.byType(ActivityDetailContent),
                    ),
                    matching: find.text(sectionWidget.block.label),
                  ),
                  findsNothing,
                  reason: entry.key,
                );
                expect(
                  find.descendant(
                    of: find.descendant(
                      of: find.byWidget(section.widget),
                      matching: find.byType(ActivityDetailContent),
                    ),
                    matching: find.byType(IconButton),
                  ),
                  findsNothing,
                  reason: entry.key,
                );
              }
              final contents = find.descendant(
                of: find.byWidget(section.widget),
                matching: find.byType(ActivityDetailContent),
              );
              for (final content in contents.evaluate()) {
                final sourcePane = find.descendant(
                  of: find.byWidget(content.widget),
                  matching: find.byType(SourceCodeText),
                );
                final pane = sourcePane.evaluate().isNotEmpty
                    ? sourcePane
                    : find.descendant(
                        of: find.byWidget(content.widget),
                        matching: find.byKey(
                          const ValueKey('activity-content-scroll'),
                        ),
                      );
                expect(pane, findsOneWidget, reason: entry.key);
                expect(
                  tester.getSize(pane).height,
                  lessThanOrEqualTo(160),
                  reason: entry.key,
                );
                final colored = find
                    .descendant(
                      of: find.byWidget(content.widget),
                      matching: find.byType(ColoredBox),
                    )
                    .first;
                final box = tester.widget<ColoredBox>(colored);
                final padding = box.child! as Padding;
                final outside = tester.getRect(colored);
                final inside = tester.getRect(find.byWidget(padding.child!));
                expect(
                  inside.left - outside.left,
                  closeTo(8, 0.1),
                  reason: entry.key,
                );
                expect(
                  inside.top - outside.top,
                  closeTo(8, 0.1),
                  reason: entry.key,
                );
                expect(
                  outside.right - inside.right,
                  closeTo(8, 0.1),
                  reason: entry.key,
                );
                expect(
                  outside.bottom - inside.bottom,
                  closeTo(8, 0.1),
                  reason: entry.key,
                );
              }
            }
            for (final footer in tester.widgetList<ActivityDetailStatus>(
              find.byType(ActivityDetailStatus),
            )) {
              if (footer.label == 'Completed') {
                final status = find.descendant(
                  of: find.byWidget(footer),
                  matching: find.text('Completed'),
                );
                expect(
                  tester.widget<Text>(status).style!.color,
                  WingTokens.forBrightness(brightness).muted,
                );
                expect(footer.icon, Icons.check_circle_outline);
              }
            }

            for (final button in find.byType(IconButton).evaluate()) {
              var detailAction = false;
              button.visitAncestorElements((parent) {
                if (parent.widget is ActivityDetailsCard) detailAction = true;
                return !detailAction;
              });
              if (detailAction) {
                expect(
                  tester.getSize(find.byWidget(button.widget)),
                  const Size.square(32),
                  reason: entry.key,
                );
              }
            }
            expect(find.text('Copy code'), findsNothing);
            expect(find.text('Copy output'), findsNothing);
            expect(find.text('Copy details'), findsNothing);
            expect(find.text('Stop process'), findsNothing);
            expect(find.text('Succeeded'), findsNothing);
            expect(tester.takeException(), isNull, reason: entry.key);
            if (_capture) {
              await tester.runAsync(() async {
                final render =
                    boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final picture = await render.toImage();
                final bytes = await picture.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/activity-family/${entry.key}-${brightness.name}-${scale.toInt()}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                picture.dispose();
              });
            }
            if (_capture &&
                scale == 2 &&
                (entry.key == 'agents' || entry.key == 'work')) {
              final status = find.byWidgetPredicate(
                (widget) => widget is ActivityDetailStatus && widget.working,
              );
              expect(status, findsOneWidget);
              await tester.ensureVisible(status);
              await tester.pumpAndSettle();
              await tester.runAsync(() async {
                final render =
                    boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final picture = await render.toImage();
                final bytes = await picture.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  'build/activity-family/${entry.key}-status-${brightness.name}-2.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                picture.dispose();
              });
            }
            if (entry.key == 'agents') {
              Navigator.of(tester.element(find.text('Live output'))).pop();
              await tester.pumpAndSettle();
            }
            if (entry.key == 'skill') {
              await tester.tap(find.byTooltip('Open skill instructions'));
              await tester.pumpAndSettle();
              await tester.settleMarkdown();
              expect(find.text('Inspect build'), findsOneWidget);
              expect(find.text('Version'), findsOneWidget);
              expect(find.text('1.0'), findsOneWidget);
              expect(find.text('Author'), findsOneWidget);
              expect(find.text('Example'), findsOneWidget);
              expect(tester.takeException(), isNull);
              if (_capture) {
                await tester.runAsync(() async {
                  final render =
                      boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary;
                  final picture = await render.toImage();
                  final bytes = await picture.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await File(
                    'build/activity-family/skill-viewer-${brightness.name}-${scale.toInt()}.png',
                  ).writeAsBytes(bytes!.buffer.asUint8List());
                  picture.dispose();
                });
              }
              Navigator.of(tester.element(find.text('Inspect build'))).pop();
              await tester.pumpAndSettle();
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
        });
      }
    }
  }
}
