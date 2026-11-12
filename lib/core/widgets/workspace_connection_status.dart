import 'package:flutter/material.dart';
import '../services/server_connection_status.dart';
import '../theme/wing_theme.dart';
import 'status_transition.dart';
import 'studio_error.dart';
import 'studio_loading.dart';

/// Recovery uses the reserved header slot. The Alerts bell owns transport
/// outages; the local notice handles failures specific to opening a chat.
class WorkspaceConnectionStatus extends StatelessWidget {
  final ServerConnectionStatus status;
  final bool showHint;
  const WorkspaceConnectionStatus({
    super.key,
    required this.status,
    this.showHint = true,
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: status,
    builder: (context, _) {
      final reconnecting = status.phase == ServerConnectionPhase.reconnecting;
      final showLocalProblem =
          showHint &&
          !reconnecting &&
          status.transportAvailability != ConnectionAvailability.unavailable;
      final localProblem = !showLocalProblem
          ? null
          : status.chatEndpointUnsupported
          ? const StudioError(
              'Chat address needs changing',
              detail: 'Open connection details for help.',
            )
          : status.recoveryProblem != null
          ? const StudioError(
              'Chat unavailable',
              detail: 'Open connection details to retry.',
            )
          : null;
      return StudioPageLoading(
        active: reconnecting,
        label: 'Reconnecting',
        child: StatusTransition(
          key: const ValueKey('workspace-connection-status'),
          child: localProblem == null
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WingSpacing.lg,
                  ),
                  child: localProblem,
                ),
        ),
      );
    },
  );
}
