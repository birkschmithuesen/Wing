import 'recent_conversations/conversation_gestures.dart';
import '../models/chat_output.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../presentation/tool_call_presentation.dart';
import '../presentation/saved_activity.dart';
import 'profile_execution_activity.dart';
import 'profile_saved_agents.dart';
import 'profile_tool_call.dart';
import 'profile_activity_tabs.dart';
import '../models/transcript_message.dart';
import '../models/transcript_timeline.dart';
import 'profile_review_notice_card.dart';
import 'profile_transcript_disclosure.dart';
import 'compact_activity_row.dart';
import 'activity_time.dart';
import 'tool_activity_details.dart';
import '../presentation/tool_activity_details.dart'
    show ToolDetailBlock, ToolDetailFormat, ToolDetailRole;
import '../theme/wing_theme.dart';

/// Shared disclosure for saved tool calls and current execution details.
class ProfileActivitySection extends StatefulWidget {
  const ProfileActivitySection({
    super.key,
    required this.detailsBuilder,
    required this.label,
    this.subtitle,
    this.trailing,
    this.initiallyExpanded = false,
    this.anchorExpansion = true,
  });

  final WidgetBuilder detailsBuilder;
  final String label;
  final Widget? trailing;
  final Widget? subtitle;
  final bool initiallyExpanded;
  final bool anchorExpansion;

  @override
  State<ProfileActivitySection> createState() => _ProfileActivitySectionState();
}

class _ProfileActivitySectionState extends State<ProfileActivitySection> {
  late bool _visited = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) => ConversationGestureBoundary(
    blocked: true,
    child: ProfileTranscriptDisclosure(
      label: widget.label,
      icon: null,
      trailing: widget.trailing,
      summary: widget.subtitle,
      initiallyExpanded: widget.initiallyExpanded,
      anchorExpansion: widget.anchorExpansion,
      // Both live and saved bodies are lazy until first expansion. Later
      // collapse retains tabs and nested disclosure state.
      maintainState: _visited,
      onExpansionChanged: (expanded) {
        if (expanded && !_visited) setState(() => _visited = true);
      },
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Builder(builder: widget.detailsBuilder),
        ),
      ],
    ),
  );
}

/// One collapsed section containing the existing tool result cards.
class ProfileToolActivitySection extends StatelessWidget {
  const ProfileToolActivitySection({
    super.key,
    required this.section,
    this.expandedMessageId,
    this.focusedMessageKey,
    this.trailing,
    this.currentActivity = const [],
    this.tabs = const [],
    this.liveToolCount = 0,
    this.loadImage,
    this.onOpenResource,
    this.onShareResource,
    this.noticeBuilder,
  });
  final TranscriptTimelineSection section;
  final int? expandedMessageId;
  final GlobalKey? focusedMessageKey;
  final Widget? trailing;
  final List<Widget> currentActivity;
  final List<ProfileActivityTab> tabs;
  final int liveToolCount;
  final Future<Uint8List> Function(String)? loadImage;
  final Future<void> Function(ChatOutput)? onOpenResource;
  final Future<void> Function(ChatOutput)? onShareResource;
  final Widget Function(TranscriptTimelineEntry)? noticeBuilder;

  @override
  Widget build(BuildContext context) {
    final count = section.toolCount;
    final total = count + liveToolCount;
    final reviews = section.reviewCount;
    final duration = section.replyDuration;
    final metadata = [
      if (duration != null)
        '· ${formatToolDuration(duration.inMicroseconds / 1000000)}',
      if (reviews > 0) '$reviews ${reviews == 1 ? 'review' : 'reviews'}',
    ].join(' · ');
    final expanded =
        expandedMessageId != null &&
        section.containsMessage(expandedMessageId!);
    return ProfileActivitySection(
      label: total > 0
          ? 'Activity · $total ${total == 1 ? 'tool' : 'tools'}'
          : 'Activity',
      trailing: trailing,
      initiallyExpanded: expanded,
      subtitle: metadata.isEmpty
          ? null
          : duration == null
          ? Text(metadata)
          : Tooltip(
              message:
                  'Approximate reply time: final reply timestamp minus the '
                  'triggering message timestamp, both from Hermes',
              child: Text(
                metadata,
                semanticsLabel:
                    'Approximate reply time '
                    '${formatToolDuration(duration.inMicroseconds / 1000000)}'
                    '${reviews > 0 ? ', $reviews reviews' : ''}',
              ),
            ),
      detailsBuilder: (_) => ProfileActivityContents(
        groups: section.groups,
        expandedMessageId: expandedMessageId,
        focusedMessageKey: focusedMessageKey,
        currentActivity: currentActivity,
        tabs: tabs,
        loadImage: loadImage,
        onOpenResource: onOpenResource,
        onShareResource: onShareResource,
        noticeBuilder: noticeBuilder,
      ),
    );
  }
}

/// Historical Activity categories, independent of their disclosure lifetime.
class ProfileActivityContents extends StatelessWidget {
  const ProfileActivityContents({
    super.key,
    required this.groups,
    this.expandedMessageId,
    this.focusedMessageKey,
    this.currentActivity = const [],
    this.tabs = const [],
    this.loadImage,
    this.onOpenResource,
    this.onShareResource,
    this.noticeBuilder,
  });

  final List<TranscriptTimelineGroup> groups;
  final int? expandedMessageId;
  final GlobalKey? focusedMessageKey;
  final List<Widget> currentActivity;
  final List<ProfileActivityTab> tabs;
  final Future<Uint8List> Function(String)? loadImage;
  final Future<void> Function(ChatOutput)? onOpenResource;
  final Future<void> Function(ChatOutput)? onShareResource;
  final Widget Function(TranscriptTimelineEntry)? noticeBuilder;

  @override
  Widget build(BuildContext context) {
    final saved = SavedActivity(groups.expand((group) => group.toolResults));
    final supplied = tabs.map((tab) => tab.id).toSet();
    final noticeEntries = [
      for (final group in groups)
        if (group.isAgentNotice) ...group.messages,
    ];
    assert(noticeEntries.isEmpty || noticeBuilder != null);
    final notices = [
      if (noticeBuilder case final builder?)
        for (final entry in noticeEntries)
          Container(
            key: entry.id == expandedMessageId
                ? focusedMessageKey
                : ValueKey(('saved-agent-notice', entry.presentationId)),
            child: Builder(builder: (_) => builder(entry)),
          ),
    ];
    return ProfileActivityTabs(
      initialTabId: noticeEntries.any((entry) => entry.id == expandedMessageId)
          ? 'agents'
          : null,
      tabs: [
        if (groups.any((group) => !group.isAgentNotice) ||
            currentActivity.isNotEmpty)
          ProfileActivityTab(
            id: 'timeline',
            label: 'Timeline',
            child: ProfileActivityTimeline(
              groups: groups,
              expandedMessageId: expandedMessageId,
              focusedMessageKey: focusedMessageKey,
              currentActivity: currentActivity,
              loadImage: loadImage,
              onOpenResource: onOpenResource,
              onShareResource: onShareResource,
            ),
          ),
        for (final tab in tabs)
          if (tab.id == 'agents' && notices.isNotEmpty)
            ProfileActivityTab(
              id: tab.id,
              label: tab.label,
              onSelected: tab.onSelected,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [tab.child, ...notices],
              ),
            )
          else
            tab,
        if (saved.todos.isNotEmpty && !supplied.contains('tasks'))
          ProfileActivityTab(
            id: 'tasks',
            label: 'Tasks ${saved.todos.length}',
            child: ProfileTodoPanel(todos: saved.todos, embedded: true),
          ),
        if ((saved.agents.isNotEmpty || notices.isNotEmpty) &&
            !supplied.contains('agents'))
          ProfileActivityTab(
            id: 'agents',
            label: saved.agents.isEmpty
                ? 'Agents'
                : 'Agents ${saved.agents.length}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (saved.agents.isNotEmpty)
                  ProfileSavedAgents(agents: saved.agents),
                ...notices,
              ],
            ),
          ),
      ],
    );
  }
}

/// Shared timeline rows without reconstructing historical Tasks or Agents.
/// Current work owns those categories in the dock, even after receipts save.
class ProfileActivityTimeline extends StatelessWidget {
  const ProfileActivityTimeline({
    super.key,
    required this.groups,
    this.expandedMessageId,
    this.focusedMessageKey,
    this.currentActivity = const [],
    this.newestFirst = false,
    this.loadImage,
    this.onOpenResource,
    this.onShareResource,
  });

  final List<TranscriptTimelineGroup> groups;
  final int? expandedMessageId;
  final GlobalKey? focusedMessageKey;
  final List<Widget> currentActivity;
  final bool newestFirst;
  final Future<Uint8List> Function(String)? loadImage;
  final Future<void> Function(ChatOutput)? onOpenResource;
  final Future<void> Function(ChatOutput)? onShareResource;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (newestFirst) ...currentActivity,
      for (final group in newestFirst ? groups.reversed : groups)
        if (group.isReasoning)
          ProfileReasoningDisclosure(
            key:
                group.messages.first.emptyAssistant &&
                    expandedMessageId != null &&
                    group.containsMessage(expandedMessageId!)
                ? focusedMessageKey
                : ValueKey((
                    'saved-reasoning',
                    group.messages.first.presentationId,
                  )),
            text: group.messages.first.reasoning,
            initiallyExpanded:
                group.messages.first.emptyAssistant &&
                expandedMessageId != null &&
                group.containsMessage(expandedMessageId!),
          )
        else if (group.question case final question?)
          ProfileToolCall(
            key: ValueKey(('activity-request', question.id)),
            call: ToolCallPresentation.question(question),
          )
        else if (group.reviewText case final review?)
          ProfileReviewNoticeRow(
            key: group.messages.last.id == expandedMessageId
                ? focusedMessageKey
                : null,
            text: review,
            initiallyExpanded:
                expandedMessageId != null &&
                group.containsMessage(expandedMessageId!),
          )
        else if (group.isProcessNotice)
          for (final entry in group.messages)
            ProfileProcessActivityRow(
              key: entry.id == expandedMessageId
                  ? focusedMessageKey
                  : ValueKey(('saved-process-notice', entry.presentationId)),
              message: entry.message,
              initiallyExpanded: entry.id == expandedMessageId,
            )
        else if (!group.isAgentNotice)
          ProfileToolActivity(
            results: newestFirst
                ? group.toolResults.toList().reversed
                : group.toolResults,
            loadImage: loadImage,
            onOpenResource: onOpenResource,
            onShareResource: onShareResource,
            initiallyExpanded:
                expandedMessageId != null &&
                group.containsMessage(expandedMessageId!),
            focusedMessageId: expandedMessageId,
            focusedMessageKey: focusedMessageKey,
          ),
      if (!newestFirst) ...currentActivity,
    ],
  );
}

/// Process notices share row geometry and detail actions with tool receipts.
class ProfileProcessActivityRow extends StatelessWidget {
  const ProfileProcessActivityRow({
    super.key,
    required this.message,
    this.initiallyExpanded = false,
  });

  final TranscriptMessage message;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => CompactActivityRow(
    icon: Icon(
      ProfileToolCall.iconFor('terminal'),
      color: WingTokens.of(context).muted,
      size: 16,
    ),
    title: const Text(
      'Process update',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3),
    ),
    lines: [
      Text(
        message.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          color: WingTokens.of(context).muted,
        ),
      ),
    ],
    time: const ActivityTime(),
    initiallyExpanded: initiallyExpanded,
    details: [
      ActivityDetailsCard(
        children: [
          ActivityDetailSection(
            block: ToolDetailBlock(
              label: 'Update',
              text: message.text,
              copyable: true,
            ),
          ),
          if (message.noticeResult case final output?)
            ActivityDetailSection(
              block: ToolDetailBlock(
                label: 'Output',
                text: output,
                copyable: true,
                format: ToolDetailFormat.source,
                role: ToolDetailRole.output,
              ),
            ),
        ],
      ),
    ],
  );
}

/// Contiguous outputs retain their transcript grouping and focus identities;
/// every call has its own readable disclosure inside the Timeline tab.
class ProfileToolActivity extends StatelessWidget {
  ProfileToolActivity({
    super.key,
    required Iterable<TranscriptToolResult> results,
    this.initiallyExpanded = false,
    this.focusedMessageId,
    this.focusedMessageKey,
    this.loadImage,
    this.onOpenResource,
    this.onShareResource,
  }) : results = List.unmodifiable(results);
  final List<TranscriptToolResult> results;
  final bool initiallyExpanded;
  final int? focusedMessageId;
  final GlobalKey? focusedMessageKey;
  final Future<Uint8List> Function(String)? loadImage;
  final Future<void> Function(ChatOutput)? onOpenResource;
  final Future<void> Function(ChatOutput)? onShareResource;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final result in results)
          Container(
            key: focusedMessageId != null && result.id == focusedMessageId
                ? focusedMessageKey
                : result.id == null
                ? null
                : ValueKey(('saved-tool', result.id)),
            decoration:
                focusedMessageId != null && result.id == focusedMessageId
                ? BoxDecoration(
                    color: colors.primaryContainer.withValues(alpha: .45),
                    border: Border.all(color: colors.primary, width: 2),
                    borderRadius: BorderRadius.circular(6),
                  )
                : null,
            child: ProfileToolCall(
              call: ToolCallPresentation.saved(result),
              initiallyExpanded:
                  initiallyExpanded &&
                  (focusedMessageId == null || result.id == focusedMessageId),
              loadImage: loadImage,
              onOpenResource: onOpenResource,
              onShareResource: onShareResource,
            ),
          ),
      ],
    );
  }
}
