import 'bots_repository.dart';
import '../models/operational_error.dart';
import 'bots_session.dart';
import 'connection_manager.dart';
import 'profile_workspace_registry.dart';

/// App composition: resolve secure saved authority through the existing registry,
/// sharing its OAuth owner and administration clients instead of creating logins.
BotsSession savedBotsSession(
  ConnectionManager manager,
  ProfileWorkspaceRegistry registry, {
  OperationalErrorReporter? onOperationalError,
}) => BotsSession(
  onOperationalError: onOperationalError,
  onIdentityChanged: registry.observeMonitoringBotIdentity,
  (canUse) async {
    final connections = await manager.loadConnectionsWithSecrets();
    final sources = <BotsRepository>[];
    for (final connection in connections) {
      if (!canUse()) return const [];
      final controller = await registry.forSavedConnection(
        manager,
        connection.id,
        canUse: canUse,
      );
      if (!canUse()) return const [];
      sources.add(
        BotsRepository.forServer(
          controller.healthSession().server,
          groupObservations: controller.groupObservations,
          isCurrent: () {
            try {
              manager.accessFor(controller.connection);
              return true;
            } catch (_) {
              return false;
            }
          },
        ),
      );
      await controller.activateGroupNotifications();
    }
    return sources;
  },
  onGroupRead: (group, sequence) async {
    final owner = registry.controllers
        .where(
          (owner) => owner.connectionIdentity == group.scope.connectionIdentity,
        )
        .firstOrNull;
    await owner?.acknowledgeGroupAnswer(group, sequence);
  },
  beforeGroupSend: (group, eventId) async {
    final owner = registry.controllers
        .where(
          (owner) => owner.connectionIdentity == group.scope.connectionIdentity,
        )
        .firstOrNull;
    if (owner == null) throw StateError('Group connection is unavailable');
    await owner.beginGroupSend(group, eventId);
  },
  afterGroupSend: (group, outcome) async {
    final owner = registry.controllers
        .where(
          (owner) => owner.connectionIdentity == group.scope.connectionIdentity,
        )
        .firstOrNull;
    await owner?.finishGroupSend(
      group,
      outcome.eventId,
      dispatched: outcome.dispatched,
      sequence: outcome.sequence,
    );
  },
);
