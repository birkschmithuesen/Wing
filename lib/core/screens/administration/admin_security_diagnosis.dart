import '../../widgets/selection_viewport.dart';
import 'package:flutter/material.dart';

import '../../services/security_audit_report.dart';
import '../../theme/wing_theme.dart';
import 'admin_widgets.dart';

class AdminSecurityDiagnosis extends StatelessWidget {
  const AdminSecurityDiagnosis({
    super.key,
    required this.report,
    required this.checkedAt,
  });

  final SecurityAuditReport report;
  final DateTime? checkedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = WingTokens.of(context);
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 24;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: WingSpacing.xs),
              child: Icon(
                report.hasVulnerabilities
                    ? Icons.error_outline
                    : Icons.shield_outlined,
                size: 24,
                color: report.hasHighSeverity
                    ? tokens.danger
                    : report.hasVulnerabilities
                    ? tokens.warning
                    : tokens.success,
              ),
            ),
            const SizedBox(width: WingSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      report.summary,
                      style: largeText
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.titleLarge,
                    ),
                  ),
                  if (checkedAt != null) ...[
                    const SizedBox(height: WingSpacing.xs),
                    Text(
                      'Checked ${TimeOfDay.fromDateTime(checkedAt!).format(context)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: WingSpacing.xl),
        for (final severity in SecuritySeverity.values)
          if (report.atSeverity(severity) case final findings
              when findings.isNotEmpty) ...[
            AdminGroup(
              children: [
                ExpansionTile(
                  key: ValueKey(severity),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: Text(
                    '${severity.label} · ${findings.length}',
                    style: theme.textTheme.titleMedium,
                  ),
                  leading: largeText
                      ? null
                      : Icon(
                          severity == SecuritySeverity.unknown
                              ? Icons.help_outline
                              : Icons.error_outline,
                          size: 22,
                          color: switch (severity) {
                            SecuritySeverity.critical ||
                            SecuritySeverity.high => tokens.danger,
                            SecuritySeverity.moderate ||
                            SecuritySeverity.medium => tokens.warning,
                            _ => tokens.muted,
                          },
                        ),
                  children: [
                    for (var i = 0; i < findings.length; i++) ...[
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(WingSpacing.lg),
                        child: SizedBox(
                          width: double.infinity,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              viewportSelection(
                                SelectableText(
                                  '${findings[i].package} ${findings[i].version}',
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                              const SizedBox(height: WingSpacing.xs),
                              viewportSelection(
                                SelectableText(
                                  '${findings[i].component} · ${findings[i].advisory}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              if (findings[i].description
                                  case final description?) ...[
                                const SizedBox(height: WingSpacing.sm),
                                viewportSelection(
                                  SelectableText(
                                    description,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                              if (findings[i].fixedIn case final fixedIn?) ...[
                                const SizedBox(height: WingSpacing.sm),
                                viewportSelection(
                                  SelectableText(
                                    'Fixed in: $fixedIn',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: tokens.muted,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: WingSpacing.sm),
          ],
        if (report.notices.isNotEmpty)
          AdminGroup(
            children: [
              ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                leading: Icon(
                  Icons.info_outline,
                  color: tokens.warning,
                  size: 22,
                ),
                title: const Text('Audit notices'),
                childrenPadding: const EdgeInsets.all(WingSpacing.lg),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: viewportSelection(SelectableText(report.notices)),
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}
