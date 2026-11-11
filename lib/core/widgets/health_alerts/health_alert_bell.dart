import 'package:flutter/scheduler.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/health_alert.dart';
import '../../theme/wing_theme.dart';
import 'health_alerts_scope.dart';
import 'health_alert_dialog.dart';

/// Animation and accessibility only. Incidents/settings belong to app owners.
class HealthAlertBell extends StatefulWidget {
  const HealthAlertBell({super.key});
  @override
  State<HealthAlertBell> createState() => _HealthAlertBellState();
}

class _HealthAlertBellState extends State<HealthAlertBell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion;
  @override
  void initState() {
    super.initState();
    _motion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 680),
    );
  }

  HealthAlertsScope? _scope;
  final _seen = <String, int>{};
  bool _updateScheduled = false;
  bool _quickViewOpen = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = HealthAlertsScope.maybeOf(context);
    if (next?.alerts != _scope?.alerts) {
      _scope?.alerts.removeListener(_changed);
      _scope = next;
      _scope?.alerts.addListener(_changed);
      _seen.clear();
      for (final a in _scope?.alerts.alerts ?? <HealthAlert>[]) {
        if (a.remindsAt(_scope!.alerts.now)) _seen[a.id] = a.occurrence;
      }
    }
    if (MediaQuery.disableAnimationsOf(context)) _motion.stop();
  }

  void _changed() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_updateScheduled) return;
      _updateScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateScheduled = false;
        if (mounted) _changed();
      });
      return;
    }
    final scope = _scope;
    if (!mounted || scope == null) return;
    final current = <String, int>{};
    var arrived = false;
    for (final a in scope.alerts.attentionAlerts) {
      current[a.id] = a.occurrence;
      if (_seen[a.id] != a.occurrence) arrived = true;
    }
    _seen
      ..clear()
      ..addAll(current);
    if (current.isEmpty) _motion.stop();
    if (arrived &&
        scope.alerts.settings.settings.animateBell &&
        !MediaQuery.disableAnimationsOf(context)) {
      _motion.forward(from: 0);
    }
    setState(() {});
  }

  Future<void> _openQuickView(HealthAlertsScope scope) async {
    setState(() => _quickViewOpen = true);
    try {
      await showHealthAlertQuickView(context, scope);
    } finally {
      if (mounted) setState(() => _quickViewOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 48, height: 48, child: _button(context));

  Widget? _button(BuildContext context) {
    final scope = _scope;
    final alerts = scope?.alerts.attentionAlerts ?? <HealthAlert>[];
    if (scope == null || (alerts.isEmpty && !_quickViewOpen)) return null;
    final tokens = WingTokens.of(context);
    final color = alerts.isEmpty
        ? tokens.muted
        : alerts.first.severity == HealthAlertSeverity.critical
        ? tokens.danger
        : tokens.warning;
    return StudioButtonPress(
      child: IconButton(
        key: ValueKey(
          alerts.isEmpty ? 'health-alert-anchor' : 'health-alert-bell',
        ),
        tooltip: alerts.isEmpty
            ? 'Alert quick view open'
            : 'Health alerts: ${alerts.length} ${alerts.length == 1 ? 'issue needs' : 'issues need'} attention',
        onPressed: _quickViewOpen ? null : () => _openQuickView(scope),
        icon: AnimatedBuilder(
          animation: _motion,
          builder: (context, _) => Badge(
            label: ExcludeSemantics(
              child: Text(
                alerts.length > 99 ? '99+' : '${alerts.length}',
                textScaler: TextScaler.noScaling,
                style: const TextStyle(fontSize: 10),
              ),
            ),
            offset: const Offset(2, -4),
            backgroundColor: color,
            textColor: tokens.surface,
            isLabelVisible: alerts.isNotEmpty,
            child: Transform.rotate(
              angle: _motion.isAnimating
                  ? math.sin(_motion.value * math.pi * 8) *
                        .22 *
                        (1 - _motion.value)
                  : 0,
              alignment: Alignment.topCenter,
              child: Icon(Icons.warning_amber_rounded, color: color),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scope?.alerts.removeListener(_changed);
    _motion.dispose();
    super.dispose();
  }
}
