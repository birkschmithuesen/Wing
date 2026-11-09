import '../models/chat_output.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import '../presentation/tool_call_presentation.dart';
import 'profile_tool_call.dart';
import 'tool_activity_details.dart';
import 'package:markdown/markdown.dart' as markdown;
import '../presentation/tool_activity_details.dart';

import 'package:flutter/material.dart';

import '../models/gateway_activity.dart';
import '../models/chat_runtime.dart';
import '../models/gateway_todo.dart';
import '../theme/wing_theme.dart';
import 'profile_transcript_disclosure.dart';
import 'compact_activity_row.dart';
import 'activity_time.dart';
import 'activity/activity_detail_actions.dart';
import 'anchored_expansion_tile.dart';
import 'chat_model_controls.dart';

/// Native event order is supplied by the owners; rendering never sorts it.
class ProfileExecutionActivity extends StatelessWidget {
  const ProfileExecutionActivity({
    super.key,
    required this.entries,
    this.loadImage,
    this.onOpenResource,
    this.onShareResource,
  });
  final List<ChatActivityEntry> entries;
  final Future<Uint8List> Function(String)? loadImage;
  final Future<void> Function(ChatOutput)? onOpenResource;
  final Future<void> Function(ChatOutput)? onShareResource;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final entry in entries)
        switch (entry) {
          ChatToolEntry(:final activity) => ProfileLiveToolActivity(
            key: ValueKey(('activity-tool', entry.identity)),
            activities: [activity],
            loadImage: loadImage,
            onOpenResource: onOpenResource,
            onShareResource: onShareResource,
          ),
          ChatRequestEntry(:final question) => ProfileToolCall(
            key: ValueKey(('activity-request', entry.identity)),
            call: ToolCallPresentation.question(question),
          ),
          ChatReasoningEntry() => ProfileReasoningDisclosure(
            key: ValueKey(('activity-reasoning', entry.identity)),
            text: entry.text,
            running: entry.running,
            source: entry.source,
            availableText: entry.availableText,
          ),
        },
    ],
  );
}

class ProfileLiveToolActivity extends StatelessWidget {
  final Iterable<GatewayToolActivity> activities;
  final Future<Uint8List> Function(String)? loadImage;
  final Future<void> Function(ChatOutput)? onOpenResource;
  final Future<void> Function(ChatOutput)? onShareResource;

  const ProfileLiveToolActivity({
    super.key,
    required this.activities,
    this.loadImage,
    this.onOpenResource,
    this.onShareResource,
  });

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('live-tool-activity'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final activity in activities)
        ProfileToolCall(
          key: ValueKey(('live-tool', activity.toolId)),
          call: ToolCallPresentation.live(activity),
          loadImage: loadImage,
          onOpenResource: onOpenResource,
          onShareResource: onShareResource,
        ),
    ],
  );
}

class ProfileTodoPanel extends StatelessWidget {
  final List<GatewayTodo> todos;

  const ProfileTodoPanel({
    super.key,
    required this.todos,
    this.embedded = false,
    this.showSummary = true,
  });
  final bool embedded;
  final bool showSummary;

  @override
  Widget build(BuildContext context) {
    final completed = todos
        .where((todo) => todo.status == GatewayTodoStatus.completed)
        .length;
    final children = <Widget>[
      if (showSummary) ProfileTodoSummary(todos: todos),
      ActivityDetailsCard(
        children: [
          for (final todo in todos)
            Padding(
              key: ValueKey(('todo', todo.id)),
              padding: EdgeInsets.only(left: todo.parent == null ? 0 : 12),
              child: _TodoDisclosure(todo: todo),
            ),
        ],
      ),
    ];
    if (embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    return ProfileTranscriptDisclosure(
      key: const ValueKey('server-todos'),
      icon: Icons.format_list_bulleted,
      label: 'Tasks $completed/${todos.length}',
      children: children,
    );
  }
}

/// The same received task counts serve inline activity and the pinned dock.
class ProfileTodoSummary extends StatelessWidget {
  const ProfileTodoSummary({super.key, required this.todos});
  final List<GatewayTodo> todos;

  @override
  Widget build(BuildContext context) {
    int count(GatewayTodoStatus status) =>
        todos.where((todo) => todo.status == status).length;
    final working = count(GatewayTodoStatus.inProgress);
    final pending = count(GatewayTodoStatus.pending);
    final cancelled = count(GatewayTodoStatus.cancelled);
    return ActivityDetailFacts(
      facts: [
        [
          '${count(GatewayTodoStatus.completed)} of ${todos.length} completed',
          if (working > 0) '$working in progress',
          if (pending > 0) '$pending pending',
          if (cancelled > 0) '$cancelled cancelled',
        ].join(' · '),
      ],
    );
  }
}

/// Task identity owns disclosure state; status and list position may change.
/// Collapsed rows never build the selectable, scrollable task body.
class _TodoDisclosure extends StatefulWidget {
  const _TodoDisclosure({required this.todo});
  final GatewayTodo todo;

  @override
  State<_TodoDisclosure> createState() => _TodoDisclosureState();
}

class _TodoDisclosureState extends State<_TodoDisclosure> {
  bool _expanded = false;

  void _toggle() {
    ExpansionAnchorNotification(
      context,
      allowBottomGap: !_expanded,
    ).dispatch(context);
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final todo = widget.todo;
    final colors = WingTokens.of(context);
    final status =
        '${todo.parent == null ? '' : 'Subtask · '}${switch (todo.status) {
          GatewayTodoStatus.pending => 'Pending',
          GatewayTodoStatus.inProgress => 'In progress',
          GatewayTodoStatus.completed => 'Completed',
          GatewayTodoStatus.cancelled => 'Cancelled',
        }}';
    return ExpansionSizeObserver(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.border)),
            ),
            padding: const EdgeInsets.only(left: WingSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: WingSpacing.sm,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _TodoStatusIcon(status: todo.status),
                            const SizedBox(width: WingSpacing.sm),
                            Expanded(
                              child: Text(
                                status,
                                style: colors.typography.label,
                              ),
                            ),
                          ],
                        ),
                        if (!_expanded) ...[
                          const SizedBox(height: WingSpacing.xs),
                          Text(
                            todo.content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: colors.typography.body,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Semantics(
                  expanded: _expanded,
                  child: ActivityDetailAction(
                    label: _expanded ? 'Collapse task' : 'Expand task',
                    onPressed: _toggle,
                    icon: _expanded ? Icons.expand_more : Icons.chevron_right,
                  ),
                ),
              ],
            ),
          ),
          if (_expanded)
            ActivityDetailSection(
              showHeader: false,
              copyable: false,
              viewable: false,
              block: ToolDetailBlock(label: status, text: todo.content),
            ),
        ],
      ),
    );
  }
}

class _TodoStatusIcon extends StatelessWidget {
  const _TodoStatusIcon({required this.status});

  final GatewayTodoStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final label = switch (status) {
      GatewayTodoStatus.pending => 'Pending task',
      GatewayTodoStatus.inProgress => 'Task in progress',
      GatewayTodoStatus.completed => 'Completed task',
      GatewayTodoStatus.cancelled => 'Cancelled task',
    };
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 16,
          child: switch (status) {
            GatewayTodoStatus.pending => CustomPaint(
              painter: _PendingTaskPainter(tokens.muted),
            ),
            GatewayTodoStatus.inProgress => Icon(
              Icons.timelapse,
              size: 16,
              color: tokens.accent,
            ),
            GatewayTodoStatus.completed => Icon(
              Icons.check_circle,
              size: 16,
              color: tokens.success,
            ),
            GatewayTodoStatus.cancelled => Icon(
              Icons.block,
              size: 16,
              color: tokens.muted,
            ),
          },
        ),
      ),
    );
  }
}

class _PendingTaskPainter extends CustomPainter {
  const _PendingTaskPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;
    const step = math.pi / 4;
    for (var i = 0; i < 8; i++) {
      canvas.drawArc(rect, -math.pi / 2 + i * step, step * 0.6, false, paint);
    }
  }

  @override
  bool shouldRepaint(_PendingTaskPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// A bounded preview of received text; the detail payload remains exact.
String reasoningHeading(String text) {
  final line = text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .firstOrNull;
  if (line == null) return 'Thinking';
  final nodes = markdown.Document(encodeHtml: false).parseLines([line]);
  return nodes.map((node) => node.textContent).join().trim();
}

class ProfileReasoningDisclosure extends StatelessWidget {
  final String text;
  final bool running;
  final bool initiallyExpanded;
  final String? source;
  final String? availableText;
  final String? heading;

  const ProfileReasoningDisclosure({
    super.key,
    required this.text,
    this.running = false,
    this.initiallyExpanded = false,
    this.source,
    this.availableText,
    this.heading,
  });

  @override
  Widget build(BuildContext context) => CompactActivityRow(
    key: const ValueKey('reasoning-disclosure'),
    icon: CircuitBrainIcon(color: WingTokens.of(context).muted),
    initiallyExpanded: initiallyExpanded,
    time: const ActivityTime(),
    title: Text(
      heading ?? (running ? 'Thinking' : 'Reasoning'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.3,
      ),
    ),
    lines: [
      if (heading == null)
        Text(
          text.trimLeft().split('\n').first,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: WingTokens.of(context).muted,
          ),
        ),
    ],
    details: [
      ActivityDetailsCard(
        children: [
          ActivityDetailSection(
            block: ToolDetailBlock(
              label: 'Reasoning',
              text: text,
              markdown: true,
              copyable: true,
            ),
          ),
        ],
      ),
      if (source != null || availableText != null)
        ProfileTranscriptDisclosure(
          label: 'Raw details',
          icon: Icons.data_object,
          maintainState: false,
          children: [
            ActivityDetailsCard(
              children: [
                if (source != null)
                  ActivityDetailSection(
                    copyable: false,
                    viewable: false,
                    block: ToolDetailBlock(label: 'Source', text: source!),
                  ),
                if (availableText != null)
                  ActivityDetailSection(
                    block: ToolDetailBlock(
                      label: 'Available reasoning',
                      text: availableText!,
                      markdown: true,
                      copyable: true,
                    ),
                  ),
              ],
            ),
          ],
        ),
    ],
  );
}
