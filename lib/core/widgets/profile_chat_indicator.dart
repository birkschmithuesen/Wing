import 'studio_loading.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:flutter/material.dart';
import '../models/gateway_insight.dart';
import '../theme/wing_theme.dart';

/// Precise state comes from the owned runtime and its active children.
class ProfileChatIndicator extends StatelessWidget {
  final ChatRuntimeObservation runtime;
  final List<GatewaySubagentActivity> subagents;
  final Set<String> unconfirmedSubagentIds;
  const ProfileChatIndicator({
    super.key,
    required this.runtime,
    required this.subagents,
    required this.unconfirmedSubagentIds,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final confirmedChildWork = subagents.any(
      (item) => !item.isTerminal && !unconfirmedSubagentIds.contains(item.id),
    );
    final status =
        runtime.execution == ChatExecution.running || confirmedChildWork
        ? ChatExecution.running
        : runtime.execution;
    final (label, color, icon, spinning) = runtime.reconnecting
        ? ('Reconnecting', tokens.warning, Icons.wifi_off_rounded, false)
        : runtime.needsInput
        ? ('Input needed', tokens.blocked, Icons.help_rounded, false)
        : switch (status) {
            ChatExecution.submitting => (
              'Sending',
              tokens.muted,
              Icons.arrow_upward,
              false,
            ),
            ChatExecution.running => ('Working', tokens.running, null, true),
            ChatExecution.failed => (
              'Failed',
              tokens.danger,
              Icons.error_outline,
              false,
            ),
            ChatExecution.completed => (
              'Completed',
              tokens.success,
              Icons.flag_outlined,
              false,
            ),
            ChatExecution.cancelled => (
              'Stopped',
              tokens.muted,
              Icons.stop_circle_outlined,
              false,
            ),
            _ => ('', tokens.muted, Icons.circle_outlined, false),
          };
    if (label.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: spinning
            ? runtime.opening || runtime.offline
                  ? const SizedBox.square(dimension: 18)
                  : StudioWorkingIndicator(
                      conversation: true,
                      label: 'Working',
                      color: color,
                    )
            : Icon(icon, size: 18, color: color),
      ),
    );
  }
}
