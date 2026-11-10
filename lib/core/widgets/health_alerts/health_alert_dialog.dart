import 'package:flutter/material.dart';
import '../../models/health_alert.dart';
import '../../presentation/health_alert_presentation.dart';
import '../../theme/wing_theme.dart';
import 'health_alerts_scope.dart';
import 'health_alert_notice.dart';
import '../studio_loading.dart';
import '../studio_error.dart';

Future<void> showHealthAlerts(
  BuildContext context,
  HealthAlertsScope scope, {
  bool includeSilenced = false,
}) {
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
    builder: (_) => StudioLoadingFrame(
      child: _HealthAlertDialog(scope: scope, includeSilenced: includeSilenced),
    ),
  );
}

class _HealthAlertDialog extends StatefulWidget {
  const _HealthAlertDialog({
    required this.scope,
    required this.includeSilenced,
  });
  final HealthAlertsScope scope;
  final bool includeSilenced;
  @override
  State<_HealthAlertDialog> createState() => _HealthAlertDialogState();
}

class _HealthAlertDialogState extends State<_HealthAlertDialog> {
  String? _selected;
  @override
  void initState() {
    super.initState();
    _selected =
        (widget.includeSilenced
                ? widget.scope.alerts.alerts
                : widget.scope.alerts.attentionAlerts)
            .firstOrNull
            ?.id;
  }

  void _open(HealthAlert alert) {
    Navigator.pop(context);
    widget.scope.openAlert(alert);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.scope.alerts,
    builder: (context, _) {
      // Keep the issue being acted on visible for immediate acknowledgement or
      // snooze feedback. Other silenced issues are reviewed from Hermes health.
      final alerts = widget.scope.alerts.alerts
          .where(
            (alert) =>
                widget.includeSilenced ||
                alert.id == _selected ||
                alert.remindsAt(widget.scope.alerts.now),
          )
          .toList();
      var index = alerts.indexWhere((a) => a.id == _selected);
      if (index < 0) index = 0;
      final alert = alerts.isEmpty ? null : alerts[index];
      final canOpen = alert?.canOpen ?? false;
      final saving = widget.scope.alerts.saving;
      final error = alert == null ? null : widget.scope.alerts.error(alert);
      return Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 420,
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (saving)
                const StudioPageLoading.waiting(label: 'Saving alert choice'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: WingModalHeader(
                  title: const Text('Alerts'),
                  closeLabel: 'Close alerts',
                  onClose: () => Navigator.pop(context),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: Semantics(
                  button: canOpen,
                  label: canOpen ? healthAlertActionLabel(alert!) : null,
                  child: StudioButtonPress(
                    child: InkWell(
                      key: const ValueKey('health-alert-open-issue'),
                      onTap: canOpen ? () => _open(alert!) : null,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: alert == null
                            ? const Text('No current alerts.')
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (alerts.length > 1)
                                    Row(
                                      children: [
                                        StudioButtonPress(
                                          child: IconButton(
                                            tooltip: 'Previous issue',
                                            onPressed: () => setState(
                                              () => _selected =
                                                  alerts[(index -
                                                              1 +
                                                              alerts.length) %
                                                          alerts.length]
                                                      .id,
                                            ),
                                            icon: const Icon(
                                              Icons.chevron_left,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            '${index + 1} of ${alerts.length}',
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                        StudioButtonPress(
                                          child: IconButton(
                                            tooltip: 'Next issue',
                                            onPressed: () => setState(
                                              () => _selected =
                                                  alerts[(index + 1) %
                                                          alerts.length]
                                                      .id,
                                            ),
                                            icon: const Icon(
                                              Icons.chevron_right,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  StudioError(
                                    alert.title,
                                    detail: alert.detail,
                                    severity: healthAlertErrorSeverity(alert),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      if (alert.scope !=
                                          HealthAlertScope.operational)
                                        alert.scope.name,
                                      alert.connectionLabel,
                                      ?alert.profileName,
                                    ].join(' · '),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 12),
                                  if (healthAlertTriggerSummary(alert)
                                      case final summary?) ...[
                                    Text('At alert: $summary'),
                                    const SizedBox(height: 12),
                                  ],
                                  Text(
                                    '${alert.lastKnown ? 'Last known' : 'Observed'} ${TimeOfDay.fromDateTime(alert.observedAt.toLocal()).format(context)}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  if (alert.lastKnown)
                                    const Text(
                                      'A fresh reading is needed to confirm recovery.',
                                    ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              if (alert != null) ...[
                const Divider(height: 1),
                if (!saving &&
                    (alert.acknowledged ||
                        alert.snoozedUntil != null &&
                            alert.snoozedUntil!.isAfter(
                              widget.scope.alerts.now,
                            )))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        alert.acknowledged
                            ? 'Acknowledged.'
                            : 'Snoozed until ${TimeOfDay.fromDateTime(alert.snoozedUntil!.toLocal()).format(context)}.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: StudioError(error),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      StudioButtonPress(
                        child: IconButton(
                          tooltip: 'Acknowledge issue',
                          onPressed: saving || alert.acknowledged
                              ? null
                              : () => widget.scope.alerts.acknowledge(alert),
                          icon: const Icon(Icons.done),
                        ),
                      ),
                      StudioButtonPress(
                        child: IconButton(
                          tooltip: 'Snooze for 30 minutes',
                          onPressed: saving || alert.acknowledged
                              ? null
                              : () => widget.scope.alerts.snooze(alert),
                          icon: const Icon(Icons.snooze_outlined),
                        ),
                      ),
                      if (canOpen)
                        StudioButtonPress(
                          child: IconButton(
                            tooltip: healthAlertActionLabel(alert),
                            onPressed: () => _open(alert),
                            icon: Icon(switch (alert.scope) {
                              HealthAlertScope.host =>
                                Icons.health_and_safety_outlined,
                              HealthAlertScope.profile => Icons.tune,
                              HealthAlertScope.connection => Icons.dns_outlined,
                              HealthAlertScope.operational => Icons.open_in_new,
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
