import 'studio_loading.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:flutter/material.dart';

import '../models/gateway_activity.dart';
import '../theme/wing_theme.dart';
import '../models/gateway_insight.dart';
import 'conversation_activity_status.dart';
import 'profile_chat_indicator.dart';

/// A current activity summary, independent of the scrollable transcript.
class ProfileActivityStatus extends StatelessWidget {
  final ChatRuntimeObservation runtime;
  final List<GatewaySubagentActivity> subagents;
  final Set<String> unconfirmedSubagentIds;

  const ProfileActivityStatus({
    super.key,
    required this.runtime,
    required this.subagents,
    required this.unconfirmedSubagentIds,
    required this.saving,
    this.executionInTranscript = false,
  });

  final bool saving;
  final bool executionInTranscript;

  String? get label {
    if (runtime.openingError != null) {
      return 'Sending unavailable · Your draft is kept';
    }
    if (runtime.opening || runtime.offline) {
      return null;
    }
    if (runtime.reconnecting) {
      return null;
    }
    if (runtime.needsInput) {
      return runtime.approval != null
          ? 'Waiting for your approval'
          : 'Waiting for your reply';
    }
    switch (runtime.execution) {
      case ChatExecution.submitting:
        return null;
      case ChatExecution.failed:
        return 'Something went wrong';
      default:
        break;
    }
    final children = subagents
        .where(
          (item) =>
              !item.isTerminal && !unconfirmedSubagentIds.contains(item.id),
        )
        .length;
    final childLabel = '$children subagent${children == 1 ? '' : 's'}';
    if (runtime.compacting) {
      const summary = 'Summarizing conversation…';
      return children > 0 ? '$summary · $childLabel active' : summary;
    }
    if (runtime.commandRunning) return 'Running command…';
    if (runtime.execution != ChatExecution.running) {
      if (children > 0) return 'Waiting for $childLabel…';
      if (runtime.error != null) return 'History needs attention';
      return null;
    }
    if (executionInTranscript) return null;
    final mainLabel = switch (runtime.mainActivity) {
      ChatMainActivity.writing => 'Writing response…',
      ChatMainActivity.thinking => 'Thinking…',
      ChatMainActivity.tool => _toolLabel,
      ChatMainActivity.working => 'Hermes is working…',
    };
    return children > 0 ? '$mainLabel · $childLabel active' : mainLabel;
  }

  String get _toolLabel {
    final active = runtime.mainToolActivity;
    if (active == null) {
      return runtime.tool == null
          ? 'Hermes is working…'
          : 'Using ${runtime.tool}';
    }
    final action = active.phase == GatewayToolActivityPhase.generating
        ? 'Preparing'
        : 'Using';
    final detail = active.detail;
    return '$action ${active.displayName}${detail == null ? '' : ' · $detail'}';
  }

  @override
  Widget build(BuildContext context) {
    final text = label;
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final Widget leading;
    if (runtime.compacting && !runtime.needsInput && !runtime.reconnecting) {
      leading =
          !runtime.opening &&
              !runtime.offline &&
              runtime.execution != ChatExecution.failed
          ? StudioWorkingIndicator(
              conversation: true,
              label: 'Summarizing conversation',
              color: WingTokens.of(context).running,
            )
          : Icon(
              Icons.compress_rounded,
              size: 18,
              color: WingTokens.of(context).running,
            );
    } else if (runtime.commandRunning &&
        !runtime.needsInput &&
        !runtime.reconnecting) {
      leading =
          !runtime.opening &&
              !runtime.offline &&
              runtime.execution != ChatExecution.failed
          ? StudioWorkingIndicator(
              conversation: true,
              label: 'Running command',
              color: color,
            )
          : Icon(Icons.error_outline, size: 18, color: color);
    } else if (runtime.execution == ChatExecution.idle &&
        runtime.activity(
              backgroundWorking: subagents.any(
                (item) =>
                    !item.isTerminal &&
                    !unconfirmedSubagentIds.contains(item.id),
              ),
            ) ==
            null) {
      leading = Icon(Icons.chat_bubble_outline, size: 18, color: color);
    } else {
      leading = ProfileChatIndicator(
        runtime: runtime,
        subagents: subagents,
        unconfirmedSubagentIds: unconfirmedSubagentIds,
      );
    }
    final waiting =
        runtime.openingError == null &&
        !runtime.opening &&
        !runtime.offline &&
        (runtime.reconnecting ||
            (runtime.execution == ChatExecution.submitting &&
                !runtime.needsInput));
    return StudioPageLoading(
      active: waiting || saving,
      label: runtime.reconnecting
          ? 'Reconnecting'
          : runtime.execution == ChatExecution.submitting
          ? 'Sending message'
          : 'Saving message',
      child: ConversationActivityStatus(
        label: text,
        leading: leading,
        wrap: runtime.compacting,
      ),
    );
  }
}
