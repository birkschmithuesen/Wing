import 'dart:async';

import 'package:flutter/material.dart';

import '../presentation/tool_call_presentation.dart';
import '../theme/wing_theme.dart';
import '../utils/tool_activity_clock.dart';

/// Only this small label ticks. Execution facts and the transcript never tick.
class ActivityTime extends StatefulWidget {
  const ActivityTime({
    super.key,
    this.durationSeconds,
    this.startedAt,
    this.backendStartedAt,
    this.subject = 'Tool',
    this.showUnavailable = false,
    this.clock = toolActivityNow,
    this.wallClock = DateTime.now,
  }) : _intervalStart = null,
       _deadline = null;

  /// A received schedule deadline, not evidence that work has started.
  const ActivityTime.countdown({
    super.key,
    required DateTime due,
    this.wallClock = DateTime.now,
  }) : _deadline = due,
       _intervalStart = null,
       durationSeconds = null,
       backendStartedAt = null,
       startedAt = null,
       subject = 'Next run',
       showUnavailable = false,
       clock = toolActivityNow;

  /// Conversation interval, using saved message times and first live receipt.
  ActivityTime.interval({
    super.key,
    required DateTime start,
    DateTime? end,
    this.wallClock = DateTime.now,
  }) : durationSeconds = end == null
           ? null
           : end.difference(start).inMicroseconds / 1000000,
       backendStartedAt = null,
       startedAt = null,
       subject = 'Activity',
       showUnavailable = false,
       clock = toolActivityNow,
       _intervalStart = start,
       _deadline = null;

  final DateTime? _intervalStart;
  final DateTime? _deadline;
  bool get _interval => _intervalStart != null;
  final double? durationSeconds;
  final Duration? startedAt;

  /// Backend Unix timestamp in seconds, never a locally invented start.
  final double? backendStartedAt;
  final String subject;
  final bool showUnavailable;
  final Duration Function() clock;
  final DateTime Function() wallClock;

  @override
  State<ActivityTime> createState() => _ActivityTimeState();
}

class _ActivityTimeState extends State<ActivityTime>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(ActivityTime oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _schedule();
    if (mounted) setState(() {});
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (widget.durationSeconds != null ||
        (widget.startedAt == null &&
            widget.backendStartedAt == null &&
            widget._intervalStart == null &&
            widget._deadline == null) ||
        (widget._deadline != null &&
            !widget._deadline!.isAfter(widget.wallClock())) ||
        !TickerMode.valuesOf(context).enabled ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        if (widget._deadline != null &&
            !widget._deadline!.isAfter(widget.wallClock())) {
          _timer?.cancel();
          _timer = null;
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget._deadline case final deadline?) {
      final seconds =
          deadline.difference(widget.wallClock()).inMilliseconds / 1000;
      final local = deadline.toLocal();
      final material = MaterialLocalizations.of(context);
      final remaining = Duration(seconds: seconds.ceil());
      final text = seconds <= 0
          ? 'Due now'
          : 'Next in ${remaining.inDays > 0
                ? '${remaining.inDays}d ${remaining.inHours % 24}h'
                : remaining.inHours > 0
                ? '${remaining.inHours}h ${remaining.inMinutes % 60}m'
                : remaining.inMinutes > 0
                ? '${remaining.inMinutes}m ${remaining.inSeconds % 60}s'
                : '${remaining.inSeconds}s'}';
      return Tooltip(
        message:
            'Scheduled ${material.formatShortDate(local)} · ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}. Phone and server clocks may differ.',
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: WingTokens.of(context).muted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
    }
    final finalTime = widget.durationSeconds;
    final start = widget.startedAt;
    final backendStart = widget._intervalStart == null
        ? widget.backendStartedAt
        : widget._intervalStart!.microsecondsSinceEpoch / 1000000;
    final unavailable =
        finalTime == null && start == null && backendStart == null;
    if (unavailable && !widget.showUnavailable) {
      return const SizedBox.shrink();
    }
    final elapsed = unavailable
        ? 0.0
        : finalTime ??
              (backendStart != null
                      ? widget.wallClock().microsecondsSinceEpoch / 1000000 -
                            backendStart
                      : (widget.clock() - start!).inMilliseconds / 1000)
                  .clamp(0.0, double.infinity);
    final text = unavailable
        ? '—'
        : '${widget._interval
                  ? '· '
                  : finalTime == null
                  ? '≈ '
                  : ''}'
              '${formatToolDuration(elapsed)}';
    return Tooltip(
      message: widget._interval
          ? 'Time from the preceding user message or reasoning block. '
                'Live reasoning is timed when first received on this device.'
          : unavailable
          ? 'No backend timing available for this call'
          : finalTime == null
          ? backendStart != null
                ? 'Approximate elapsed time from backend start; phone and server clocks may differ'
                : 'Approximate time since backend tool start was received'
          : 'Backend duration',
      child: Semantics(
        label: widget._interval
            ? 'Activity ${finalTime == null ? 'elapsed time' : 'duration'} '
                  '${formatToolDuration(elapsed)}'
            : unavailable
            ? '${widget.subject} duration unavailable'
            : finalTime == null
            ? '${widget.subject} running; approximate elapsed time'
            : 'Backend duration $text',
        child: ExcludeSemantics(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget._interval
                ? const TextStyle(fontFeatures: [FontFeature.tabularFigures()])
                : TextStyle(
                    fontSize: 12,
                    color: WingTokens.of(context).muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
          ),
        ),
      ),
    );
  }
}
