import '../widgets/selection_viewport.dart';
import 'package:flutter/material.dart';
import '../models/health_alert.dart';
import '../models/host_thresholds.dart';
import '../presentation/health_alert_presentation.dart';
import '../services/health_alert_settings_session.dart';
import '../theme/wing_theme.dart';
import '../widgets/compact_switch.dart';
import '../widgets/wing_app_bar.dart';
import '../widgets/studio_error.dart';
import 'administration/admin_widgets.dart';

class HealthAlertSettingsScreen extends StatelessWidget {
  const HealthAlertSettingsScreen({super.key, required this.session});
  final HealthAlertSettingsSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final settings = session.value;
      return Scaffold(
        appBar: WingAppBar(
          context: context,
          title: const Text('Alert settings'),
          leading: const StudioButtonPress(child: BackButton()),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            WingSpacing.lg,
            WingSpacing.sm,
            WingSpacing.lg,
            WingSpacing.xl,
          ),
          children: [
            AdminGroup(
              children: [
                _toggle(
                  'Health monitoring',
                  'Monitor CPU, RAM, and disk. Profile, connection, and service alerts stay available when this is off.',
                  settings.enabled,
                  (value) => session.update(
                    (current) => current.copyWith(enabled: value),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                WingSpacing.md,
                WingSpacing.sm,
                WingSpacing.md,
                0,
              ),
              child: Text(
                'Checks run while Wing is open or monitoring work.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: WingTokens.of(context).muted,
                ),
              ),
            ),
            _SaveError(session: session),
            _section(context, 'Host thresholds', [
              for (final metric in hostAlertMetrics)
                StudioButtonPress(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: WingSpacing.md,
                    ),
                    minTileHeight: 56,
                    visualDensity: VisualDensity.standard,
                    minVerticalPadding: WingSpacing.sm,
                    horizontalTitleGap: WingSpacing.md,
                    leading: Icon(switch (metric) {
                      HostMetric.memoryUsedPercent => Icons.memory,
                      HostMetric.diskUsedPercent => Icons.storage_outlined,
                      _ => Icons.developer_board_outlined,
                    }, size: 20),
                    title: Text(healthAlertMetricLabel(metric)),
                    subtitle: Text(
                      healthAlertRuleSummary(metric, settings.rules[metric]!),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          _RuleEditor(metric: metric, session: session),
                    ),
                  ),
                ),
            ]),
            _section(context, 'Profile', [
              _toggle(
                'Profile problems',
                'Access, connector or task failures.',
                settings.profile,
                (value) => session.update(
                  (current) => current.copyWith(profile: value),
                ),
              ),
            ]),
            _section(context, 'When an issue arrives', [
              _toggle(
                'Animate the alert icon',
                'Once for a new issue or escalation.',
                settings.animateBell,
                (value) => session.update(
                  (current) => current.copyWith(animateBell: value),
                ),
              ),
              _toggle(
                'Show a brief notice',
                'Tap the alert icon for details.',
                settings.showNotice,
                (value) => session.update(
                  (current) => current.copyWith(showNotice: value),
                ),
              ),
            ]),
          ],
        ),
      );
    },
  );
  Widget _section(BuildContext context, String title, List<Widget> children) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WingSpacing.md,
              WingSpacing.lg,
              WingSpacing.md,
              WingSpacing.sm,
            ),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: WingTokens.of(context).muted,
                ),
              ),
            ),
          ),
          AdminGroup(children: children),
        ],
      );

  Widget _toggle(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> choose,
  ) => CompactSwitchListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: WingSpacing.md),
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: choose,
  );
}

class _SaveError extends StatelessWidget {
  const _SaveError({required this.session});
  final HealthAlertSettingsSession session;
  @override
  Widget build(BuildContext context) => session.error == null
      ? const SizedBox.shrink()
      : Row(
          children: [
            Expanded(child: StudioError(session.error!)),
            StudioButtonPress(
              child: IconButton(
                tooltip: 'Retry saving alert settings',
                onPressed: () => session.retry(),
                icon: const Icon(Icons.refresh),
              ),
            ),
          ],
        );
}

class _RuleEditor extends StatefulWidget {
  const _RuleEditor({required this.metric, required this.session});
  final HostMetric metric;
  final HealthAlertSettingsSession session;
  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  HealthAlertRule get _rule => widget.session.value.rules[widget.metric]!;
  late final _warn = TextEditingController(
    text: healthAlertPercentage(_rule.warnAbove),
  );
  late final _clear = TextEditingController(
    text: healthAlertPercentage(_rule.clearBelow),
  );
  late final _alertMinutes = TextEditingController(
    text: '${_rule.alertMinutes}',
  );
  late final _clearMinutes = TextEditingController(
    text: '${_rule.clearMinutes}',
  );
  String? _error;
  void _edit(String _) {
    try {
      final warning = double.parse(_warn.text);
      final recovery = double.parse(_clear.text);
      final alertMinutes = int.parse(_alertMinutes.text);
      final clearMinutes = int.parse(_clearMinutes.text);
      widget.session.updateRule(
        widget.metric,
        (current) => current.copyWith(
          warnAbove: warning,
          clearBelow: recovery,
          alertMinutes: alertMinutes,
          clearMinutes: clearMinutes,
        ),
      );
      setState(() => _error = null);
    } on FormatException {
      _invalid();
    } on ArgumentError catch (error) {
      if (error.name == 'clearBelow') {
        setState(
          () => _error =
              'Not saved: clear below ${_clear.text}% must be lower than alert above ${_warn.text}%.',
        );
      } else {
        _invalid();
      }
    }
  }

  void _invalid() => setState(
    () => _error =
        'Not saved: use 0–100%, recovery below warning, and 1–30 minutes.',
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    healthAlertMetricLabel(widget.metric),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Close rule editor',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CompactSwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: WingSpacing.md,
                      ),
                      title: const Text('Usage warning'),
                      value: _rule.enabled,
                      onChanged: (value) => widget.session.updateRule(
                        widget.metric,
                        (current) => current.copyWith(enabled: value),
                      ),
                    ),
                    _condition(
                      'Alert after',
                      _alertMinutes,
                      'if above',
                      _warn,
                      'Warning',
                    ),
                    _condition(
                      'Clear after',
                      _clearMinutes,
                      'if below',
                      _clear,
                      'Recovery',
                    ),
                    if (healthAlertNativeCriticalLabel(widget.metric)
                        case final label?) ...[
                      const SizedBox(height: 8),
                      const Divider(height: 1),
                      CompactSwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        title: Text(label),
                        subtitle: Text(
                          healthAlertNativeCriticalDetail(widget.metric),
                        ),
                        value: _rule.nativeCriticalEnabled,
                        onChanged: (value) => widget.session.updateRule(
                          widget.metric,
                          (current) =>
                              current.copyWith(nativeCriticalEnabled: value),
                        ),
                      ),
                    ],
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: _SaveError(session: widget.session),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: StudioError(_error!),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _condition(
    String after,
    TextEditingController duration,
    String comparison,
    TextEditingController percent,
    String label,
  ) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: _labelWidth(['Alert after', 'Clear after']),
                child: Text(
                  after,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              _input('$label duration', duration, 'min', decimal: false),
            ],
          ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: _labelWidth(['if above', 'if below']),
                child: Text(
                  comparison,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              _input('$label threshold', percent, '%', decimal: true),
            ],
          ),
        ],
      ),
    ),
  );

  double _labelWidth(List<String> labels) {
    var width = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      if (painter.width > width) width = painter.width;
      painter.dispose();
    }
    return width;
  }

  Widget _input(
    String label,
    TextEditingController controller,
    String unit, {
    required bool decimal,
  }) {
    final large = MediaQuery.textScalerOf(context).scale(16) >= 24;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${healthAlertMetricLabel(widget.metric)} $label',
          child: SizedBox(
            width: decimal ? (large ? 112 : 64) : 48,
            child: viewportSelection(
              TextField(
                controller: controller,
                keyboardType: TextInputType.numberWithOptions(decimal: decimal),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                ),
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.end,
                onChanged: _edit,
                onSubmitted: _edit,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(unit),
      ],
    );
  }

  @override
  void dispose() {
    _warn.dispose();
    _clear.dispose();
    _alertMinutes.dispose();
    _clearMinutes.dispose();
    super.dispose();
  }
}
