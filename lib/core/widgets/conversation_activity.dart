import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/chat_runtime.dart';
import '../models/transcript_timeline.dart';
import '../models/chat_output.dart';
import '../models/gateway_todo.dart';
import '../models/profile_supervision.dart';
import 'profile_activity_status.dart';
import 'profile_chat_indicator.dart';
import 'profile_execution_activity.dart';
import 'profile_live_execution.dart';
import 'profile_live_work_dock.dart';
import 'profile_transcript_disclosure.dart';
import 'tool_activity_details.dart';

/// Shared conversation presentation. Transport owners supply facts and commands;
/// this module owns activity placement, counts, viewers and working feedback.
final class ConversationActivity {
  const ConversationActivity({
    required this.runtime,
    required this.entries,
    required this.todos,
    required this.inspection,
    required this.agentsBuilder,
    required this.live,
    required this.taskCount,
    required this.agentCount,
    this.beforeMessagePresentationId,
    this.processCount,
    this.processes,
    this.processSummary,
    this.onProcessesSelected,
  });
  final ChatRuntimeObservation runtime;
  final List<ChatActivityEntry> entries;
  final List<GatewayTodo> todos;
  final SubagentInspectionSession inspection;
  final Widget Function() agentsBuilder;
  final bool live;
  final int? processCount;
  final Widget? processes, processSummary;
  final Future<void> Function()? onProcessesSelected;
  // A received native suffix receipt establishes this conversation boundary
  // while the earlier tool history is still being backfilled.
  final Object? beforeMessagePresentationId;
  bool get hasPositionedExecution =>
      live || beforeMessagePresentationId != null;
  // Null means the source has not observed this category yet.
  final int? taskCount;
  final int? agentCount;

  bool get _hasVisibleLiveExecution =>
      live &&
      entries.any(
        (entry) => switch (entry) {
          ChatReasoningEntry() => entry.text.trim().isNotEmpty,
          ChatToolEntry() || ChatRequestEntry() => true,
        },
      );

  // Only facts that change the shared work indicator invalidate its retained
  // transcript presentation; growing answer text does not.
  Object get indicatorRevision => (
    runtime.execution,
    runtime.reconnecting,
    runtime.needsInput,
    runtime.opening,
    runtime.offline,
    inspection.state.subagents.any(
      (item) =>
          !item.isTerminal &&
          !inspection.state.unconfirmedSubagentIds.contains(item.id),
    ),
  );

  bool get hasDock =>
      todos.isNotEmpty ||
      inspection.state.subagents.isNotEmpty ||
      processCount != null;
  int get completedTasks =>
      todos.where((todo) => todo.status == GatewayTodoStatus.completed).length;
  int get toolCount => live ? 0 : entries.whereType<ChatToolEntry>().length;
  bool get preparingTool =>
      runtime.tool != null &&
      !runtime.toolActivities.any((tool) => !tool.isTerminal);
  Widget get preparing => ProfileTranscriptDisclosure(
    icon: Icons.terminal_rounded,
    label: 'Preparing ${runtime.tool!}',
    children: const [Text('Hermes is preparing the tool call')],
  );

  Widget? liveExecution({
    DateTime? startedAt,
    DateTime? endedAt,
    TranscriptTimelineSection? savedActivity,
    Future<Uint8List> Function(String)? loadImage,
    Future<void> Function(ChatOutput)? onOpenResource,
    Future<void> Function(ChatOutput)? onShareResource,
  }) => !hasPositionedExecution || (entries.isEmpty && savedActivity == null)
      ? null
      : ProfileLiveExecution(
          entries: entries,
          savedActivity: savedActivity,
          startedAt: startedAt,
          endedAt: endedAt,
          running: live,
          indicator: _hasVisibleLiveExecution
              ? ProfileChatIndicator(
                  runtime: runtime,
                  subagents: inspection.state.subagents,
                  unconfirmedSubagentIds:
                      inspection.state.unconfirmedSubagentIds,
                )
              : null,
          loadImage: loadImage,
          onOpenResource: onOpenResource,
          onShareResource: onShareResource,
        );

  List<Widget> currentActivity({
    Future<Uint8List> Function(String)? loadImage,
    Future<void> Function(ChatOutput)? onOpenResource,
    Future<void> Function(ChatOutput)? onShareResource,
  }) => hasPositionedExecution
      ? const []
      : [
          if (preparingTool) preparing,
          if (entries.isNotEmpty)
            ProfileExecutionActivity(
              entries: entries,
              loadImage: loadImage,
              onOpenResource: onOpenResource,
              onShareResource: onShareResource,
            ),
        ];

  Widget get tasks =>
      ProfileTodoPanel(todos: todos, embedded: true, showSummary: false);
  Widget get agents => agentsBuilder();

  Widget status({Key? key, required bool saving}) => ProfileActivityStatus(
    key: key,
    runtime: runtime,
    subagents: inspection.state.subagents,
    unconfirmedSubagentIds: inspection.state.unconfirmedSubagentIds,
    saving: saving,
    executionInTranscript: _hasVisibleLiveExecution,
  );

  Widget dock({
    GlobalKey<ProfileLiveWorkDockState>? key,
    VoidCallback? onOpenChanged,
  }) => hasDock
      ? ProfileLiveWorkDock(
          key: key,
          onOpenChanged: onOpenChanged,
          taskCount: taskCount,
          completedTasks: completedTasks,
          subagentCount: agentCount,
          processCount: processCount,
          processes: processes,
          processSummary: processSummary,
          onProcessesSelected: onProcessesSelected,
          taskSummary: ProfileTodoSummary(todos: todos),
          subagentSummary: ListenableBuilder(
            listenable: inspection,
            builder: (context, _) =>
                ActivityDetailFacts(facts: [inspection.state.subagentSummary]),
          ),
          tasks: tasks,
          subagents: agents,
          onAgentsSelected: inspection.refreshSubagents,
        )
      : const SizedBox.shrink();
}
