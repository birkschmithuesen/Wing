import 'selection_viewport.dart';
import 'activity/activity_detail_actions.dart';
import 'subagent_timeline.dart';
import 'studio_loading.dart';
import 'studio_error.dart';

import 'package:flutter/material.dart';
import '../presentation/agent_task_presentation.dart';
import '../presentation/tool_call_presentation.dart';
import '../theme/wing_theme.dart';
import 'activity_time.dart';
import 'tool_activity_details.dart';
import '../presentation/tool_activity_details.dart';
import 'profile_transcript_disclosure.dart';

import '../models/gateway_insight.dart';
import '../models/profile_supervision.dart';
import '../models/profile_session_key.dart';
import '../services/transcript_resource_session.dart';

class ProfileSubagentPanel extends StatefulWidget {
  final SubagentInspectionSession session;
  final TranscriptResourceSession Function(ProfileSessionKey) createResources;
  final bool initiallyExpanded;
  final bool embedded;

  const ProfileSubagentPanel({
    super.key,
    required this.session,
    required this.createResources,
    this.initiallyExpanded = false,
    this.embedded = false,
  });

  @override
  State<ProfileSubagentPanel> createState() => _ProfileSubagentPanelState();
}

class _ProfileSubagentPanelState extends State<ProfileSubagentPanel> {
  @override
  void initState() {
    super.initState();
    if (!widget.embedded &&
        (widget.initiallyExpanded || widget.session.state.subagents.isEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  @override
  void didUpdateWidget(ProfileSubagentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.embedded &&
        !identical(oldWidget.session, widget.session) &&
        (widget.initiallyExpanded || widget.session.state.subagents.isEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (!mounted) {
      return;
    }
    try {
      await widget.session.refreshSubagents();
    } catch (_) {
      // The controller retains the profile-scoped error for the panel.
    }
  }

  Future<void> _openSubagent(String id) async {
    final detail = widget.session.openSubagent(id);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => StudioLoadingFrame(
          child: _SubagentDetailSheet(
            session: detail,
            createResources: widget.createResources,
          ),
        ),
      );
    } finally {
      detail.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final chat = widget.session.state;
      final children = <Widget>[
        if (chat.unconfirmedSubagentIds.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Refresh could not confirm every subagent. Showing their last known activity.',
            ),
          ),
        if (chat.subagentsError case final error?)
          Row(
            children: [
              Expanded(
                child: StudioError(
                  widget.embedded ? '$error Reopen to retry.' : error,
                ),
              ),
              if (!widget.embedded)
                ActivityDetailAction(
                  label: 'Retry',
                  icon: Icons.refresh,
                  onPressed: _refresh,
                ),
            ],
          ),
        if (!chat.subagentsLoading &&
            chat.subagentsError == null &&
            chat.subagents.isEmpty)
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('No live subagents for this chat.'),
          ),
        for (final activity in chat.subagents)
          _SubagentRow(
            key: ValueKey(('subagent', chat.key, activity.id)),
            activity: activity,
            unconfirmed: chat.unconfirmedSubagentIds.contains(activity.id),
            onTap: () => _openSubagent(activity.id),
          ),
        if (!widget.embedded)
          Align(
            alignment: Alignment.centerRight,
            child: ActivityDetailAction(
              onPressed: chat.subagentsLoading ? null : _refresh,
              icon: Icons.refresh,
              label: 'Refresh',
            ),
          ),
      ];
      if (widget.embedded) {
        return StudioLoadingRegion(
          available: chat.subagentsAvailable,
          busy: chat.subagentsLoading,
          label: 'Loading agents',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
      }
      return ProfileTranscriptDisclosure(
        key: ValueKey(('subagents', chat.key)),
        initiallyExpanded: widget.initiallyExpanded,
        maintainState: false,
        onExpansionChanged: (expanded) {
          if (expanded) _refresh();
        },
        icon: Icons.account_tree_outlined,
        label: 'Subagents',
        summary: Text(chat.subagentSummary),
        childrenPadding: EdgeInsets.zero,
        children: children,
      );
    },
  );
}

class _SubagentDetailSheet extends StatefulWidget {
  final SubagentInspectionDetail session;
  final TranscriptResourceSession Function(ProfileSessionKey) createResources;
  const _SubagentDetailSheet({
    required this.session,
    required this.createResources,
  });

  @override
  State<_SubagentDetailSheet> createState() => _SubagentDetailSheetState();
}

class _SubagentDetailSheetState extends State<_SubagentDetailSheet>
    with WidgetsBindingObserver {
  final _steer = TextEditingController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.session.setActive(
          WidgetsBinding.instance.lifecycleState == null ||
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed,
        );
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      widget.session.setActive(state == AppLifecycleState.resumed);
  Future<void> _submitSteer() async {
    final text = _steer.text;
    final accepted = await widget.session.steer(text);
    if (mounted && accepted && _steer.text == text) _steer.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _steer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final state = widget.session.state;
      final current = state.activity;
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
      return SafeArea(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: FractionallySizedBox(
            heightFactor: widget.session.timeline != null && keyboardInset > 0
                ? 1
                : 0.85,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _withTimeline(
                current,
                ListView(
                  children: [
                    ActivityDetailsCard(
                      children: [
                        ActivityDetailSection(
                          block: ToolDetailBlock(
                            label: 'Task',
                            role: ToolDetailRole.task,
                            text: _goal(current),
                            copyable: current.goal.trim().isNotEmpty,
                          ),
                          facts: [
                            ?current.model,
                            if (current.toolCount case final count?)
                              '$count ${count == 1 ? 'tool call' : 'tool calls'}',
                          ],
                        ),
                        if (_activityText(current) case final text?)
                          if (current.isTerminal &&
                              current.detail?.trim().isNotEmpty == true)
                            ActivityDetailSection(
                              block: ToolDetailBlock(
                                label: 'Reported result',
                                role: ToolDetailRole.output,
                                text: text,
                                markdown: true,
                                copyable: true,
                              ),
                            )
                          else
                            ActivityDetailFacts(
                              facts: [
                                '${current.isTerminal ? 'Last activity' : 'Current activity'}: $text',
                              ],
                            ),
                        if (widget.session.timeline == null)
                          _steeringControls(),
                        if (widget.session.timeline == null &&
                            widget.session.supportsTail)
                          _tailBody(current),
                        if (widget.session.timeline == null &&
                            !widget.session.supportsTail)
                          _recentActivity(current),
                        if (widget.session.timeline == null)
                          _statusFooter(current),
                        _SubagentMetadata(activity: current),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _withTimeline(GatewaySubagentActivity current, Widget details) {
    final timeline = widget.session.timeline;
    if (timeline == null) return details;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WingModalHeader(
            title: ListenableBuilder(
              listenable: timeline,
              builder: (context, _) => Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Subagent activity',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ActivityDetailAction(
                    label: 'Refresh subagent activity',
                    icon: Icons.refresh,
                    onPressed: timeline.historyLoading
                        ? null
                        : timeline.refresh,
                  ),
                ],
              ),
            ),
            closeLabel: 'Close subagent activity',
            onClose: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, readingConstraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: readingConstraints.maxHeight * 0.35,
                    ),
                    child: SingleChildScrollView(
                      child: ProfileTranscriptDisclosure(
                        label: 'Task',
                        icon: Icons.account_tree_outlined,
                        summary: Text(
                          _statusLabel(
                            current,
                            widget.session.state.unconfirmed,
                          ),
                        ),
                        anchorExpansion: false,
                        children: [
                          SizedBox(
                            height: readingConstraints.maxHeight * 0.3,
                            child: details,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: ClipRect(
                      child: SubagentTimeline(
                        session: timeline,
                        createResources: widget.createResources,
                        agentsBuilder: (inspection) => ProfileSubagentPanel(
                          session: inspection,
                          createResources: widget.createResources,
                          embedded: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.session.state.acceptsSteer)
            const SizedBox(height: WingSpacing.md),
          _steeringControls(feedbackHeight: constraints.maxHeight / 3),
          _statusFooter(current),
        ],
      ),
    );
  }

  Widget _steeringControls({double? feedbackHeight}) {
    final state = widget.session.state;
    final message = state.controlMessage;
    final feedback = message == null
        ? null
        : state.controlFailed
        ? Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WingSpacing.sm,
              vertical: WingSpacing.xs,
            ),
            child: StudioError(message),
          )
        : ActivityDetailStatus(label: message, icon: Icons.info_outline);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.acceptsSteer)
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: viewportSelection(
                  TextField(
                    controller: _steer,
                    minLines: 1,
                    maxLines: 1,
                    enabled: !state.steering,
                    decoration: const InputDecoration(
                      labelText: 'Steer subagent',
                      hintText: 'Add guidance for the current task',
                    ),
                  ),
                ),
              ),
              ActivityDetailAction(
                label: 'Steer',
                icon: Icons.send_outlined,
                busy: state.steering,
                onPressed: _submitSteer,
              ),
            ],
          ),
        if (feedback != null)
          if (feedbackHeight != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: feedbackHeight),
              child: SingleChildScrollView(child: feedback),
            )
          else
            feedback,
      ],
    );
  }

  Widget _statusFooter(GatewaySubagentActivity current) {
    final state = widget.session.state;
    return ActivityDetailStatus(
      working:
          !state.unconfirmed && current.status == GatewaySubagentStatus.running,
      label: _statusLabel(current, state.unconfirmed),
      icon: state.unconfirmed
          ? Icons.help_outline
          : _statusIcon(current.status),
      error:
          !state.unconfirmed && current.status == GatewaySubagentStatus.failed,
      warning:
          !state.unconfirmed &&
          current.status == GatewaySubagentStatus.interrupted,
      actions: [
        Padding(
          padding: const EdgeInsets.all(WingSpacing.sm),
          child: ActivityTime(
            subject: 'Agent',
            durationSeconds: current.isTerminal
                ? current.durationSeconds
                : null,
            backendStartedAt:
                !state.unconfirmed &&
                    current.status == GatewaySubagentStatus.running
                ? current.startedAt
                : null,
          ),
        ),
        if (state.canControl)
          ActivityDetailAction(
            label: 'Interrupt',
            icon: Icons.stop_circle_outlined,
            busy: state.interrupting,
            onPressed: widget.session.interrupt,
          ),
      ],
    );
  }

  Widget _recentActivity(GatewaySubagentActivity activity) =>
      activity.recentActivity.isEmpty
      ? const SizedBox.shrink()
      : ActivityDetailSection(
          copyable: false,
          viewable: false,
          block: ToolDetailBlock(
            label: 'Recent activity',
            text: activity.recentActivity.map(_recentActivityText).join('\n'),
          ),
        );

  Widget _tailBody(GatewaySubagentActivity activity) {
    final tail = widget.session.state.tail;
    final readableTail = tail != null && tail.available && tail.text.isNotEmpty
        ? tail
        : widget.session.state.lastAvailableTail;
    final messages = <String>[
      if (widget.session.state.tailError == null) ...[
        if (tail == null)
          'Loading live output...'
        else if (!tail.available)
          activity.isTerminal
              ? 'Live output is unavailable after completion.'
              : 'Hermes has not provided a live transcript for this subagent.'
        else if (tail.text.isEmpty)
          'Waiting for transcript text...',
      ],
      if (readableTail != null &&
          (widget.session.state.tailError != null ||
              tail?.available != true ||
              tail!.text.isEmpty))
        'Showing the last received output.',
      if (readableTail?.truncated == true)
        'Showing the latest 16 KiB of live output.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (readableTail != null)
          ActivityDetailSection(
            block: ToolDetailBlock(
              label: 'Live output',
              role: ToolDetailRole.output,
              text: readableTail.text,
              copyable: true,
              format: ToolDetailFormat.source,
            ),
            facts: messages,
            actions: _tailActions(),
          )
        else
          ActivityDetailStatus(
            label: 'Live output',
            icon: Icons.notes_outlined,
            contextFacts: messages,
            actions: _tailActions(),
          ),
        if (widget.session.state.inlineTailError case final error?)
          Padding(
            padding: const EdgeInsets.all(WingSpacing.sm),
            // The existing Alert owns announcement of the same read failure.
            child: StudioError(error, announce: false),
          ),
        _recentActivity(activity),
      ],
    );
  }

  List<Widget> _tailActions() => [
    ActivityDetailAction(
      label: 'Refresh live output',
      icon: Icons.refresh,
      busy: widget.session.state.loadingTail,
      onPressed: widget.session.refreshTail,
    ),
    if (widget.session.state.tailError != null &&
        widget.session.state.tailFailures >= 3)
      ActivityDetailAction(
        label: 'Retry',
        icon: Icons.refresh,
        onPressed: widget.session.retryTail,
      ),
  ];
}

String _statusLabel(GatewaySubagentActivity activity, bool unconfirmed) {
  final status = switch (activity.status) {
    GatewaySubagentStatus.queued => 'Queued',
    GatewaySubagentStatus.running => 'Running',
    GatewaySubagentStatus.completed => 'Completed',
    GatewaySubagentStatus.failed => 'Failed',
    GatewaySubagentStatus.interrupted => 'Interrupted',
  };
  return unconfirmed ? 'Last seen ${status.toLowerCase()}' : status;
}

String? _activityText(GatewaySubagentActivity activity) {
  if (activity.isTerminal && activity.detail != null) return activity.detail;
  if (activity.phase == GatewaySubagentPhase.thinking) return 'Thinking';
  if (activity.lastTool case final tool?) {
    final label = ToolCallPresentation.titleFor(
      tool,
      completed: activity.isTerminal,
    );
    final detail = activity.detail;
    return detail == null || detail == tool ? label : '$label · $detail';
  }
  return activity.detail;
}

String _recentActivityText(String line) {
  if (!line.startsWith('Tool: ')) return line;
  final value = line.substring(6);
  final split = value.indexOf(' · ');
  final name = split < 0 ? value : value.substring(0, split);
  final caption = ToolCallPresentation.titleFor(name, completed: false);
  return split < 0 ? caption : '$caption${value.substring(split)}';
}

class _SubagentRow extends StatelessWidget {
  const _SubagentRow({
    super.key,
    required this.activity,
    required this.unconfirmed,
    required this.onTap,
  });
  final GatewaySubagentActivity activity;
  final bool unconfirmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = WingTokens.of(context);
    final metadata = [
      ?activity.model,
      if (activity.toolCount case final count?)
        '$count ${count == 1 ? 'tool call' : 'tool calls'}',
    ].join(' · ');
    return StudioButtonPress(
      child: ListTile(
        titleAlignment: ListTileTitleAlignment.top,
        contentPadding: const EdgeInsets.all(WingSpacing.sm),
        minVerticalPadding: 0,
        minTileHeight: 48,
        minLeadingWidth: 16,
        horizontalTitleGap: 8,
        leading: SizedBox(
          height: MediaQuery.textScalerOf(context).scale(14) * 1.3,
          child: Center(
            widthFactor: 1,
            child: Icon(
              unconfirmed ? Icons.help_outline : _statusIcon(activity.status),
              size: 16,
              color: unconfirmed
                  ? colors.muted
                  : activity.status == GatewaySubagentStatus.failed
                  ? colors.danger
                  : activity.status == GatewaySubagentStatus.running
                  ? colors.accent
                  : colors.muted,
            ),
          ),
        ),
        title: Text(
          agentTaskHeading(_goal(activity)),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            height: 1.3,
            color: colors.onSurface,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SubagentStatusLine(activity: activity, unconfirmed: unconfirmed),
            if (_activityText(activity) case final text?)
              Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: colors.muted,
                ),
              ),
            if (metadata.isNotEmpty)
              Text(
                metadata,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: colors.muted,
                ),
              ),
          ],
        ),
        trailing: SizedBox(
          height: MediaQuery.textScalerOf(context).scale(14) * 1.3,
          child: Center(
            widthFactor: 1,
            child: Icon(Icons.chevron_right, size: 16, color: colors.muted),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}

class _SubagentStatusLine extends StatelessWidget {
  const _SubagentStatusLine({
    required this.activity,
    required this.unconfirmed,
  });
  final GatewaySubagentActivity activity;
  final bool unconfirmed;
  @override
  Widget build(BuildContext context) {
    final colors = WingTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            _statusLabel(activity, unconfirmed),
            style: colors.typography.label.copyWith(
              color:
                  !unconfirmed &&
                      activity.status == GatewaySubagentStatus.failed
                  ? colors.danger
                  : colors.muted,
            ),
          ),
        ),
        const SizedBox(width: WingSpacing.sm),
        ActivityTime(
          subject: 'Agent',
          durationSeconds: activity.isTerminal
              ? activity.durationSeconds
              : null,
          backendStartedAt:
              !unconfirmed && activity.status == GatewaySubagentStatus.running
              ? activity.startedAt
              : null,
        ),
      ],
    );
  }
}

class _SubagentMetadata extends StatelessWidget {
  const _SubagentMetadata({required this.activity});
  final GatewaySubagentActivity activity;
  @override
  Widget build(BuildContext context) {
    final values = [
      'Agent ID: ${activity.id}',
      if (activity.childSessionId case final value?) 'Child session: $value',
      if (activity.parentId case final value?) 'Parent agent: $value',
      if (activity.delegationId case final value?) 'Delegation ID: $value',
      if (activity.model case final value?) 'Model: $value',
      if (activity.toolCount case final value?) 'Tool calls: $value',
      if (activity.startedAt case final value?)
        'Backend start (Unix seconds): $value',
      if (activity.durationSeconds case final value?)
        'Backend duration (seconds): $value',
    ].join('\n');
    return ActivityDetailSection(
      initiallyCollapsed: true,
      viewable: false,
      block: ToolDetailBlock(
        label: 'Raw details',
        text: values,
        format: ToolDetailFormat.source,
        copyable: false,
        secondary: true,
      ),
    );
  }
}

String _goal(GatewaySubagentActivity activity) =>
    activity.goal.trim().isEmpty ? 'Subagent' : activity.goal;

IconData _statusIcon(GatewaySubagentStatus status) => switch (status) {
  GatewaySubagentStatus.queued => Icons.schedule_outlined,
  GatewaySubagentStatus.running => Icons.account_tree_outlined,
  GatewaySubagentStatus.completed => Icons.check_circle_outline,
  GatewaySubagentStatus.failed => Icons.error_outline,
  GatewaySubagentStatus.interrupted => Icons.stop_circle_outlined,
};
