import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/health_alert.dart';
import '../../presentation/health_alert_presentation.dart';
import '../../theme/wing_theme.dart';
import '../studio_error.dart';
import '../studio_loading.dart';
import 'health_alert_notice.dart';
import 'health_alerts_scope.dart';

Future<void> showHealthAlertDetails(
  BuildContext context,
  HealthAlertsScope scope,
  HealthAlert issue,
) {
  HealthAlertNotice.dismiss(context);
  return showDialog<void>(
    context: context,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: Duration(milliseconds: 210),
            reverseDuration: Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
          ),
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: StudioLoadingFrame(
          child: _HealthAlertCard(scope: scope, issue: issue),
        ),
      ),
    ),
  );
}

Future<void> showHealthAlertQuickView(
  BuildContext context,
  HealthAlertsScope scope,
) {
  final box = context.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(
            context,
            rootNavigator: true,
          ).overlay!.context.findRenderObject()!
          as RenderBox;
  Rect position() =>
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  var lastPosition = position();
  Rect anchor() {
    if (box.attached && box.hasSize && overlay.attached) {
      lastPosition = position();
    }
    return lastPosition;
  }

  HealthAlertNotice.dismiss(context);
  final tokens = WingTokens.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss alert quick view',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => _AnchoredQuickView(
      initialAnchor: lastPosition,
      readAnchor: anchor,
      child: Material(
        color: tokens.raised,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: WingRadius.card,
          side: BorderSide(color: tokens.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: StudioLoadingFrame(child: _HealthAlertCard(scope: scope)),
      ),
    ),
  );
}

class _AnchoredQuickView extends StatefulWidget {
  const _AnchoredQuickView({
    required this.initialAnchor,
    required this.readAnchor,
    required this.child,
  });

  final Rect initialAnchor;
  final Rect Function() readAnchor;
  final Widget child;

  @override
  State<_AnchoredQuickView> createState() => _AnchoredQuickViewState();
}

class _AnchoredQuickViewState extends State<_AnchoredQuickView> {
  late Rect _anchor = widget.initialAnchor;

  @override
  Widget build(BuildContext context) {
    // The anchor lives on a different route. Sample it after layout so a
    // viewport change never reads that route's render boxes during layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final next = widget.readAnchor();
      if (next != _anchor) setState(() => _anchor = next);
    });
    return CustomSingleChildLayout(
      delegate: _QuickViewLayout(
        anchor: _anchor,
        padding: MediaQuery.paddingOf(context),
        keyboard: MediaQuery.viewInsetsOf(context).bottom,
        direction: Directionality.of(context),
      ),
      child: widget.child,
    );
  }
}

class _QuickViewLayout extends SingleChildLayoutDelegate {
  const _QuickViewLayout({
    required this.anchor,
    required this.padding,
    required this.keyboard,
    required this.direction,
  });

  final Rect anchor;
  final EdgeInsets padding;
  final double keyboard;
  final TextDirection direction;

  Rect _viewport(Size size) => Rect.fromLTRB(
    padding.left + 8,
    padding.top + 4,
    size.width - padding.right - 8,
    size.height - math.max(padding.bottom, keyboard) - 8,
  );

  ({double top, double bottom, bool above}) _verticalBounds(Size size) {
    final rect = anchor;
    final viewport = _viewport(size);
    final below = math.max(0.0, viewport.bottom - rect.bottom - 4);
    final above = math.max(0.0, rect.top - 4 - viewport.top);
    return (top: above, bottom: below, above: below < 180 && above > below);
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final vertical = _verticalBounds(size);
    final viewport = _viewport(size);
    final attachedWidth = direction == TextDirection.ltr
        ? anchor.right - viewport.left
        : viewport.right - anchor.left;
    final width = math.min(360.0, attachedWidth.clamp(0.0, viewport.width));
    return BoxConstraints.tightFor(width: width).copyWith(
      maxHeight: math.min(
        size.height * .72,
        vertical.above ? vertical.top : vertical.bottom,
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rect = anchor;
    final viewport = _viewport(size);
    final start = direction == TextDirection.ltr
        ? rect.right - childSize.width
        : rect.left;
    return Offset(
      start.clamp(
        viewport.left,
        math.max(viewport.left, viewport.right - childSize.width),
      ),
      _verticalBounds(size).above
          ? rect.top - 4 - childSize.height
          : rect.bottom + 4,
    );
  }

  @override
  bool shouldRelayout(_QuickViewLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.padding != padding ||
      oldDelegate.keyboard != keyboard ||
      oldDelegate.direction != direction;
}

class _HealthAlertCard extends StatefulWidget {
  const _HealthAlertCard({required this.scope, this.issue});

  final HealthAlertsScope scope;
  final HealthAlert? issue;

  @override
  State<_HealthAlertCard> createState() => _HealthAlertCardState();
}

class _HealthAlertCardState extends State<_HealthAlertCard> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.scope.alerts.attentionAlerts.firstOrNull?.id;
  }

  void _close() => Navigator.of(context).pop();

  void _open(HealthAlert alert) {
    _close();
    widget.scope.openAlert(alert);
  }

  Future<void> _restore(
    HealthAlert alert,
    Future<void> Function(HealthAlert) restore,
  ) async {
    final release = HealthAlertNotice.quietRestoration(context, alert);
    try {
      await restore(alert);
    } finally {
      release();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.scope.alerts,
    builder: (context, _) {
      final owner = widget.scope.alerts;
      final issue = widget.issue;
      final now = owner.now;
      final alerts = [
        for (final alert in owner.alerts)
          if (issue == null
              ? alert.id == _selected || alert.remindsAt(now)
              : alert.id == issue.id && alert.occurrence == issue.occurrence)
            alert,
      ];
      final index = math.max(0, alerts.indexWhere((a) => a.id == _selected));
      final alert = alerts.isEmpty ? null : alerts[index];
      final error = alert == null ? null : owner.error(alert);
      return StudioPageLoading(
        active: owner.saving,
        label: 'Saving alert choice',
        child: Column(
          key: const ValueKey('health-alert-card'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: WingModalHeader(
                title: const Text('Alerts'),
                closeLabel: 'Close alerts',
                onClose: _close,
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: alert == null
                    ? Text(
                        issue == null
                            ? 'No current alerts.'
                            : 'This issue is no longer current.',
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (error != null) ...[
                            StudioError(error),
                            const SizedBox(height: 8),
                          ],
                          if (alerts.length > 1)
                            Row(
                              children: [
                                _action(
                                  'Previous issue',
                                  Icons.chevron_left,
                                  () => setState(
                                    () => _selected =
                                        alerts[(index - 1) % alerts.length].id,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    '${index + 1} of ${alerts.length}',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                _action(
                                  'Next issue',
                                  Icons.chevron_right,
                                  () => setState(
                                    () => _selected =
                                        alerts[(index + 1) % alerts.length].id,
                                  ),
                                ),
                              ],
                            ),
                          _AlertObservation(
                            alert: alert,
                            now: now,
                            onOpen: alert.canOpen ? () => _open(alert) : null,
                          ),
                        ],
                      ),
              ),
            ),
            if (alert != null) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _action(
                      alert.acknowledged
                          ? 'Unacknowledge issue'
                          : 'Acknowledge issue',
                      alert.acknowledged ? Icons.undo : Icons.done,
                      owner.saving
                          ? null
                          : () => alert.acknowledged
                                ? _restore(alert, owner.unacknowledge)
                                : owner.acknowledge(alert),
                    ),
                    _action(
                      !alert.acknowledged && !alert.remindsAt(now)
                          ? 'Unsnooze issue'
                          : 'Snooze for 30 minutes',
                      !alert.acknowledged && !alert.remindsAt(now)
                          ? Icons.history
                          : Icons.snooze_outlined,
                      owner.saving || alert.acknowledged
                          ? null
                          : () => alert.remindsAt(now)
                                ? owner.snooze(alert)
                                : _restore(alert, owner.unsnooze),
                    ),
                    if (alert.canOpen)
                      _action(
                        healthAlertActionLabel(alert),
                        switch (alert.scope) {
                          HealthAlertScope.host =>
                            Icons.health_and_safety_outlined,
                          HealthAlertScope.profile => Icons.tune,
                          HealthAlertScope.connection => Icons.dns_outlined,
                          HealthAlertScope.operational => Icons.open_in_new,
                        },
                        () => _open(alert),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _action(String label, IconData icon, VoidCallback? onPressed) =>
      StudioButtonPress(
        child: IconButton(
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      );
}

class _AlertObservation extends StatelessWidget {
  const _AlertObservation({
    required this.alert,
    required this.now,
    this.onOpen,
  });

  final HealthAlert alert;
  final DateTime now;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final observed = TimeOfDay.fromDateTime(alert.observedAt.toLocal());
    return Semantics(
      button: onOpen != null,
      label: onOpen == null ? null : healthAlertActionLabel(alert),
      child: StudioButtonPress(
        child: InkWell(
          key: const ValueKey('health-alert-open-issue'),
          onTap: onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final scale = MediaQuery.textScalerOf(context);
                  final title = Text(
                    alert.title,
                    style: theme.textTheme.titleMedium,
                  );
                  final compact =
                      constraints.maxWidth < 260 || scale.scale(14) > 20;
                  final status = _AlertStatus(
                    alert: alert,
                    now: now,
                    alignment: compact
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.end,
                  );
                  return compact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [title, status],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: title),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 24 + scale.scale(48),
                              child: status,
                            ),
                          ],
                        );
                },
              ),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: alert.severity == HealthAlertSeverity.critical
                          ? 'Critical'
                          : 'Warning',
                      style: TextStyle(
                        color: healthAlertErrorSeverity(
                          alert,
                        ).color(WingTokens.of(context)),
                      ),
                    ),
                    TextSpan(text: ' · ${healthAlertScopeLabel(alert)}'),
                  ],
                ),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(alert.detail),
              if (healthAlertTriggerSummary(alert) case final summary?) ...[
                const SizedBox(height: 8),
                Text('At alert: $summary'),
              ],
              const SizedBox(height: 8),
              Text(
                '${alert.lastKnown ? 'Last known' : 'Observed'} ${observed.format(context)}',
                style: theme.textTheme.bodySmall,
              ),
              if (alert.lastKnown)
                const Text('A fresh reading is needed to confirm recovery.'),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertStatus extends StatelessWidget {
  const _AlertStatus({
    required this.alert,
    required this.now,
    required this.alignment,
  });

  final HealthAlert alert;
  final DateTime now;
  final MainAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final label = healthAlertSilencedLabel(context, alert, now);
    final time = alert.snoozedUntil?.toLocal();
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return SizedBox(
      height: math.max(20.0, MediaQuery.textScalerOf(context).scale(14) * 1.35),
      child: label == null
          ? null
          : Semantics(
              label: label,
              liveRegion: true,
              child: ExcludeSemantics(
                child: Tooltip(
                  message: label,
                  child: Row(
                    mainAxisAlignment: alignment,
                    children: [
                      Icon(
                        alert.acknowledged ? Icons.done : Icons.snooze_outlined,
                        size: 16,
                        color: color,
                      ),
                      if (!alert.acknowledged && time != null) ...[
                        const SizedBox(width: 4),
                        Text(
                          MaterialLocalizations.of(context).formatTimeOfDay(
                            TimeOfDay.fromDateTime(time),
                            alwaysUse24HourFormat: true,
                          ),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
