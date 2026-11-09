import 'studio_form_actions.dart';
import 'activity/activity_detail_actions.dart';
import '../theme/wing_theme.dart';
import 'studio_error.dart';
import 'package:flutter/material.dart';
import 'compact_activity_row.dart';
import 'activity_time.dart';
import 'tool_activity_details.dart';
import '../presentation/tool_activity_details.dart';
import 'profile_transcript_disclosure.dart';

import '../models/gateway_process.dart';
import '../models/session_control.dart';
import '../services/profile_supervision_session.dart';

/// Server-owned recurring work and background processes for one captured chat.
class ProfileBackgroundWorkPanel extends StatefulWidget {
  final ProfileSupervisionSession session;
  final bool initiallyExpanded;

  const ProfileBackgroundWorkPanel({
    super.key,
    required this.session,
    this.initiallyExpanded = false,
  });

  @override
  State<ProfileBackgroundWorkPanel> createState() =>
      _ProfileBackgroundWorkPanelState();
}

class _ProfileBackgroundWorkPanelState
    extends State<ProfileBackgroundWorkPanel> {
  bool _requested = false;
  @override
  void initState() {
    super.initState();
    _requestRefresh();
  }

  @override
  void didUpdateWidget(ProfileBackgroundWorkPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _requested = false;
      _requestRefresh();
    }
  }

  void _requestRefresh() {
    if (_requested) return;
    _requested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() => widget.session.refreshControl();
  Future<void> _refreshSessionControl() => widget.session.refreshControl();
  Future<void> _control(SessionControlAction action) async {
    await widget.session.control(action);
  }

  Future<void> _confirmClearHeartbeat() async {
    final session = widget.session;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        title: const Text('Clear heartbeat?'),
        content: const Text(
          'This removes the heartbeat schedule from the Hermes server.',
        ),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: 'Clear heartbeat',
            confirmIcon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
    );
    if (confirmed == true && mounted && identical(widget.session, session)) {
      await session.control(SessionControlAction.heartbeatClear);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final chat = widget.session.state;
      final snapshot = chat.sessionControl;
      final working =
          chat.actionBusy ||
          chat.sessionControlLoading ||
          chat.sessionControlWorking;
      final refreshing = chat.sessionControlLoading;
      return ProfileTranscriptDisclosure(
        key: ValueKey(('background-work', chat.key)),
        initiallyExpanded: widget.initiallyExpanded,
        maintainState: false,
        icon: Icons.work_history_outlined,
        label: 'Background work',
        summary: Text(chat.backgroundSummary),
        childrenPadding: EdgeInsets.zero,
        children: [
          if (snapshot?.loop case final loop?)
            _LoopSection(
              loop: loop,
              actions: chat.loopActions,
              disabled: working,
              onAction: _control,
            ),
          if (snapshot?.heartbeat case final heartbeat?)
            _HeartbeatSection(
              heartbeat: heartbeat,
              actions: chat.heartbeatActions,
              disabled: working,
              onAction: _control,
              onClear: _confirmClearHeartbeat,
            ),
          if (snapshot?.loop == null && snapshot?.heartbeat == null)
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('No recurring work is configured for this chat.'),
            ),
          if (chat.sessionControlError case final error?)
            _ErrorRow(
              message: error,
              onRetry: working ? null : _refreshSessionControl,
            ),
          if (chat.actionError case final error?)
            Align(alignment: Alignment.centerLeft, child: StudioError(error)),
          if (chat.sessionControlNotice case final notice?)
            Align(alignment: Alignment.centerLeft, child: Text(notice)),
          Align(
            alignment: Alignment.centerRight,
            child: ActivityDetailAction(
              onPressed: refreshing || chat.actionBusy ? null : _refresh,
              busy: refreshing,
              icon: Icons.refresh,
              label: 'Refresh',
            ),
          ),
        ],
      );
    },
  );
}

/// Borrowed process rows in the live-work dock. The workspace owns discovery
/// and refresh lifetime; mounting a kept-alive page performs no I/O.
class ProfileProcessPanel extends StatelessWidget {
  const ProfileProcessPanel({super.key, required this.session});
  final ProfileSupervisionSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final state = session.state;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.processesError case final error?) StudioError(error),
          for (final process in state.processes)
            _ProcessTile(
              key: ValueKey(process.id),
              process: process,
              confirmed: session.active && state.processesError == null,
              stopping: state.stopping.contains(process.id),
              error: state.processErrors[process.id],
              onStop: () => session.stopProcess(process.id),
              onDismiss: () => session.dismissProcess(process.id),
            ),
        ],
      );
    },
  );
}

class _LoopSection extends StatelessWidget {
  final SessionLoop loop;
  final List<SessionControlAction> actions;
  final bool disabled;
  final Future<void> Function(SessionControlAction) onAction;

  const _LoopSection({
    required this.loop,
    required this.disabled,
    required this.actions,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) => _WorkSection(
    icon: Icons.repeat,
    title: 'Loop · ${_loopStatus(loop.status)}',
    prompt: loop.prompt,
    details: [
      _loopCadence(loop),
      _loopRunCount(loop),
      if (loop.awaitingResponse) 'Waiting for the current response',
      if (loop.deferredByGoal) 'Deferred while the goal is active',
      if (loop.pausedReason case final reason? when reason.trim().isNotEmpty)
        'Paused: $reason',
      if (loop.lastStopReason case final reason? when reason.trim().isNotEmpty)
        'Stopped: $reason',
    ],
    timing:
        loop.status == SessionLoopStatus.active &&
            loop.nextDueAt > 0 &&
            !loop.awaitingResponse &&
            !loop.deferredByGoal
        ? ActivityTime.countdown(
            due: DateTime.fromMillisecondsSinceEpoch(
              (loop.nextDueAt * 1000).round(),
            ),
          )
        : null,
    actions: [
      if (actions.contains(SessionControlAction.loopPause))
        ActivityDetailAction(
          onPressed: disabled
              ? null
              : () => onAction(SessionControlAction.loopPause),
          icon: Icons.pause,
          label: 'Pause loop',
        ),
      if (actions.contains(SessionControlAction.loopResume))
        ActivityDetailAction(
          onPressed: disabled
              ? null
              : () => onAction(SessionControlAction.loopResume),
          icon: Icons.play_arrow,
          label: 'Resume loop',
        ),
      if (actions.contains(SessionControlAction.loopStop))
        ActivityDetailAction(
          onPressed: disabled
              ? null
              : () => onAction(SessionControlAction.loopStop),
          icon: Icons.stop,
          label: 'Stop loop',
        ),
    ],
  );
}

class _HeartbeatSection extends StatelessWidget {
  final SessionHeartbeat heartbeat;
  final List<SessionControlAction> actions;
  final bool disabled;
  final Future<void> Function(SessionControlAction) onAction;
  final Future<void> Function() onClear;

  const _HeartbeatSection({
    required this.heartbeat,
    required this.disabled,
    required this.actions,
    required this.onAction,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => _WorkSection(
    icon: Icons.monitor_heart_outlined,
    title: 'Heartbeat · ${_heartbeatStatus(heartbeat.status)}',
    prompt: heartbeat.prompt,
    details: [
      'Every ${_duration(heartbeat.intervalSeconds)}',
      '${heartbeat.fireCount} runs',
    ],
    actions: [
      if (actions.contains(SessionControlAction.heartbeatPause))
        ActivityDetailAction(
          onPressed: disabled
              ? null
              : () => onAction(SessionControlAction.heartbeatPause),
          icon: Icons.pause,
          label: 'Pause heartbeat',
        ),
      if (actions.contains(SessionControlAction.heartbeatResume))
        ActivityDetailAction(
          onPressed: disabled
              ? null
              : () => onAction(SessionControlAction.heartbeatResume),
          icon: Icons.play_arrow,
          label: 'Resume heartbeat',
        ),
      ActivityDetailAction(
        onPressed: disabled ? null : onClear,
        icon: Icons.clear,
        label: 'Clear heartbeat',
      ),
    ],
  );
}

class _WorkSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String prompt;
  final List<String> details;
  final List<Widget> actions;
  final Widget? timing;

  const _WorkSection({
    required this.icon,
    required this.title,
    required this.prompt,
    required this.details,
    required this.actions,
    this.timing,
  });

  @override
  Widget build(BuildContext context) => ActivityDetailsCard(
    children: [
      ActivityDetailSection(
        leading: Icon(icon, size: 16),
        block: ToolDetailBlock(label: 'Prompt', text: prompt, copyable: true),
        facts: details,
      ),
      ActivityDetailStatus(label: title, icon: icon, actions: actions),
      ?timing,
    ],
  );
}

class _ProcessTile extends StatelessWidget {
  final GatewayProcessActivity process;
  final bool stopping;
  final bool confirmed;
  final String? error;
  final Future<void> Function() onStop;
  final VoidCallback onDismiss;

  const _ProcessTile({
    super.key,
    required this.process,
    required this.stopping,
    required this.confirmed,
    required this.error,
    required this.onStop,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) => CompactActivityRow(
    key: ValueKey(('process', process.id)),
    icon: Icon(
      Icons.terminal_rounded,
      color: WingTokens.of(context).muted,
      size: 16,
    ),
    title: Text(
      process.command,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: WingTokens.of(context).typography.mono,
    ),
    lines: [
      Text(
        process.isRunning && !confirmed
            ? 'Last seen running'
            : _processStatus(process),
        style: WingTokens.of(context).typography.label,
      ),
    ],
    time: const ActivityTime(subject: 'Process'),
    details: [
      ActivityDetailsCard(
        children: [
          if (process.commandSource case final command?)
            ActivityDetailSection(
              block: ToolDetailBlock(
                label: 'Command',
                role: ToolDetailRole.command,
                language: 'bash',
                text: command,
                copyable: true,
                format: ToolDetailFormat.source,
              ),
              facts: [
                if (process.cwd case final cwd?) 'Folder: $cwd',
                if (process.pid case final pid?) 'PID $pid',
                if (process.detached) 'Detached',
                if (process.notifyOnComplete) 'Completion notice enabled',
              ],
            ),
          if (process.outputTail case final output? when output.isNotEmpty)
            ActivityDetailSection(
              block: ToolDetailBlock(
                label: 'Recent output',
                role: ToolDetailRole.output,
                text: output,
                copyable: true,
                format: ToolDetailFormat.source,
              ),
              facts: const [
                'Latest received output; not a complete transcript',
              ],
            ),
          if (process.outputTail?.isEmpty == true)
            const ActivityDetailFacts(
              facts: ['Latest received output is empty'],
            ),
          if (process.commandSource == null &&
              (process.cwd != null ||
                  process.pid != null ||
                  process.detached ||
                  process.notifyOnComplete))
            ActivityDetailFacts(
              facts: [
                if (process.cwd case final cwd?) 'Folder: $cwd',
                if (process.pid case final pid?) 'PID $pid',
                if (process.detached) 'Detached',
                if (process.notifyOnComplete) 'Completion notice enabled',
              ],
            ),
          if (error case final message?)
            ActivityDetailStatus(
              label: message,
              error: true,
              icon: Icons.error_outline,
            ),
          ActivityDetailStatus(
            working: confirmed && process.isRunning,
            label: process.isRunning
                ? (confirmed ? 'Running' : 'Last seen running')
                : process.exitCode != null && process.exitCode != 0
                ? 'Failed'
                : process.exitCode == null
                ? 'Exited'
                : 'Completed',
            error:
                !process.isRunning &&
                process.exitCode != null &&
                process.exitCode != 0,
            icon: process.isRunning
                ? Icons.terminal_rounded
                : process.exitCode != null && process.exitCode != 0
                ? Icons.error_outline
                : Icons.check_circle_outline,
            contextFacts: [
              if (!process.isRunning)
                process.exitCode == null
                    ? 'Process exited; exit code not supplied'
                    : 'Exit ${process.exitCode}',
            ],
            actions: [
              ActivityDetailAction(
                label: process.isRunning ? 'Stop process' : 'Dismiss',
                icon: process.isRunning ? Icons.stop : Icons.close,
                busy: stopping,
                onPressed: process.isRunning
                    ? (confirmed ? onStop : null)
                    : onDismiss,
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

class _ErrorRow extends StatelessWidget {
  final String message;
  final Future<void> Function()? onRetry;

  const _ErrorRow({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: StudioError(message)),
      ActivityDetailAction(
        label: 'Retry',
        icon: Icons.refresh,
        onPressed: onRetry,
      ),
    ],
  );
}

String _loopStatus(SessionLoopStatus status) => switch (status) {
  SessionLoopStatus.active => 'Active',
  SessionLoopStatus.paused => 'Paused',
  SessionLoopStatus.done => 'Stopped',
};

String _heartbeatStatus(SessionHeartbeatStatus status) => switch (status) {
  SessionHeartbeatStatus.active => 'Active',
  SessionHeartbeatStatus.paused => 'Paused',
};

String _loopCadence(SessionLoop loop) => switch (loop.mode) {
  SessionLoopMode.interval => 'Every ${_duration(loop.intervalSeconds)}',
  SessionLoopMode.selfPaced =>
    'Self-paced · ${_duration(loop.currentDelay)} delay',
};

String _loopRunCount(SessionLoop loop) {
  if (loop.times > 0) return '${loop.ticksFired}/${loop.times} runs';
  if (loop.maxTicks > 0) {
    return '${loop.ticksFired}/${loop.maxTicks} tick budget';
  }
  return '${loop.ticksFired} runs';
}

String _duration(num seconds) {
  final whole = seconds.round();
  if (whole >= 3600 && whole % 3600 == 0) return '${whole ~/ 3600}h';
  if (whole >= 60 && whole % 60 == 0) return '${whole ~/ 60}m';
  return '${seconds.toStringAsFixed(seconds == whole ? 0 : 1)}s';
}

String _processStatus(GatewayProcessActivity process) {
  if (process.isRunning) {
    return process.uptimeSeconds == null
        ? 'Running'
        : 'Running · ${_duration(process.uptimeSeconds!)} uptime';
  }
  return process.exitCode == null
      ? 'Exited'
      : 'Exited · code ${process.exitCode}';
}
