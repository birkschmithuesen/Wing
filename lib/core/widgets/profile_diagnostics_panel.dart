import 'studio_error.dart';
import '../models/health_finding.dart';
import 'package:flutter/material.dart';

import '../services/profile_diagnostics_controller.dart';
import '../services/administration_overview.dart';
import '../theme/wing_theme.dart';

/// Passive Health observation. Only a reported problem exposes an action.
class ProfileModelAccessRow extends StatelessWidget {
  final ProfileDiagnosticsController controller;
  final ModelAccessObservation modelObservation;
  final bool refreshing;
  final VoidCallback onRetry;
  final VoidCallback? onManageConnections;
  final VoidCallback onFixAccess;

  const ProfileModelAccessRow({
    super.key,
    required this.controller,
    required this.modelObservation,
    required this.refreshing,
    required this.onRetry,
    required this.onFixAccess,
    this.onManageConnections,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final result = controller.result;
      final checking = controller.checking || refreshing;
      final tokens = WingTokens.of(context);
      final theme = Theme.of(context);
      final model = modelObservation.model?.model;
      final provider = modelObservation.model?.provider;
      final hasModel = modelObservation.model?.hasModel == true;
      final unavailable = modelObservation.unavailable;
      final modelLabel = hasModel
          ? '$model · ${provider != null && provider.isNotEmpty ? provider : 'Automatic provider'}'
          : modelObservation.loading
          ? 'Loading model…'
          : unavailable
          ? 'Model unavailable'
          : 'No model selected';
      final color = checking
          ? theme.colorScheme.onSurfaceVariant
          : switch (result.status) {
              AdministrationHealthStatus.healthy => tokens.success,
              AdministrationHealthStatus.failure => tokens.danger,
              AdministrationHealthStatus.warning => tokens.warning,
              _ => theme.colorScheme.onSurfaceVariant,
            };
      final (action, label) = switch (result.recovery) {
        ProfileAccessRecovery.provider => (
          onFixAccess,
          result.status == AdministrationHealthStatus.warning
              ? 'Review access'
              : 'Fix access',
        ),
        ProfileAccessRecovery.connection when onManageConnections != null => (
          onManageConnections,
          'Review connection',
        ),
        _
            when result.status == AdministrationHealthStatus.unknown &&
                controller.checkedAt != null =>
          (onRetry, 'Retry'),
        _ => (null, ''),
      };
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                !checking &&
                        (result.status == AdministrationHealthStatus.failure ||
                            result.status == AdministrationHealthStatus.warning)
                    ? Icons.error_outline
                    : Icons.key_outlined,
                color: color,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Model access', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  if (!checking &&
                      (result.status == AdministrationHealthStatus.failure ||
                          result.status == AdministrationHealthStatus.warning))
                    StudioError(
                      'Access needs attention',
                      detail: result.title,
                      icon: Icons.key_outlined,
                      framed: false,
                      severity:
                          result.status == AdministrationHealthStatus.failure
                          ? StudioErrorSeverity.error
                          : StudioErrorSeverity.noResult,
                    )
                  else
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        checking ? 'Checking access…' : result.title,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(modelLabel, style: theme.textTheme.bodySmall),
                  if (unavailable && hasModel)
                    const StudioError(
                      'Last known model; refresh failed.',
                      icon: Icons.refresh,
                      framed: false,
                    ),
                  if (!checking &&
                      result != ProfileAccessResult.notChecked &&
                      result.message.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(result.message, style: theme.textTheme.bodySmall),
                  ],
                  if (!checking && action != null)
                    StudioButtonPress(
                      child: TextButton(onPressed: action, child: Text(label)),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
