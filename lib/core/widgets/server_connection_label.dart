import 'package:flutter/material.dart';
import '../models/connection.dart';
import '../services/server_connection_status.dart';
import '../theme/wing_theme.dart';
import 'connection_icon_picker.dart';
import 'studio_error.dart';
import 'workspace_profile_navigation.dart';
import 'workspace_picker.dart';
import 'read_recovery.dart';

typedef WorkspacePickerCallback =
    void Function(BuildContext context, {required WorkspacePickerMode mode});

const _connectionIdentityGap = 6.0;

/// Shared recovery sheet for header status controls and connection alerts.
Future<void> showServerConnectionDetails(
  BuildContext context, {
  required String label,
  required ServerConnectionStatus? status,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _ConnectionDetails(label: label, status: status),
);

class ServerConnectionScope extends InheritedWidget {
  final ServerConnectionStatus status;
  final WorkspacePickerCallback? onPickWorkspace;
  final WorkspaceProfileNavigation? profileNavigation;
  final ConnectionIcon? icon;
  ServerConnectionScope({
    super.key,
    required this.status,
    this.onPickWorkspace,
    this.profileNavigation,
    this.icon,
    required Widget child,
  }) : super(
         child: ReadRecovery(
           recoverOnEntry: true,
           shouldRetry: () => status.phase != ServerConnectionPhase.connected,
           retry: () async => status.retry?.call(),
           child: child,
         ),
       );
  static ServerConnectionScope? scopeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ServerConnectionScope>();
  static ServerConnectionStatus? of(BuildContext context) =>
      scopeOf(context)?.status;
  @override
  bool updateShouldNotify(ServerConnectionScope oldWidget) =>
      status != oldWidget.status ||
      onPickWorkspace != oldWidget.onPickWorkspace ||
      profileNavigation != oldWidget.profileNavigation ||
      icon != oldWidget.icon;
}

/// Independent status and workspace-selection targets shared by screen headers.
class ServerConnectionLabel extends StatelessWidget {
  final ServerConnectionStatus? status;
  final String label;
  final ConnectionIcon? icon;
  final String? suffix;
  final bool includeProfiles;
  final WorkspacePickerMode? pickerMode;
  final TextStyle? style;
  final AlignmentGeometry alignment;
  const ServerConnectionLabel({
    super.key,
    required this.label,
    this.icon,
    this.status,
    this.suffix,
    this.includeProfiles = false,
    this.pickerMode,
    this.style,
    this.alignment = Alignment.centerLeft,
  });
  @override
  Widget build(BuildContext context) {
    final scope = ServerConnectionScope.scopeOf(context);
    final pickProfiles = includeProfiles || (suffix?.isNotEmpty ?? false);
    final mode =
        pickerMode ??
        (pickProfiles
            ? WorkspacePickerMode.connectionAndProfile
            : WorkspacePickerMode.connections);
    final pickerLabel = mode.label;
    final effectiveIcon = icon ?? scope?.icon ?? ConnectionIcon.server;
    final identity =
        '$label${suffix == null || suffix!.isEmpty ? '' : ' · $suffix'}';
    void openDetails() =>
        showServerConnectionDetails(context, label: label, status: status);
    Widget labelBody() => Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          key: const ValueKey('connection-status-target'),
          button: true,
          label:
              '$label, ${status?.description ?? 'Not checked'}. Connection details',
          focusable: true,
          onTap: openDetails,
          excludeSemantics: true,
          child: Tooltip(
            message: 'Connection details',
            child: StudioButtonPress(
              child: InkWell(
                borderRadius: WingRadius.control,
                onTap: openDetails,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          effectiveIcon.glyph,
                          size: 16,
                          color:
                              style?.color ??
                              Theme.of(context).textTheme.bodySmall?.color,
                        ),
                        const SizedBox(width: 8),
                        _ConnectionLed(
                          phase:
                              status?.phase ?? ServerConnectionPhase.unchecked,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: _connectionIdentityGap),
        Flexible(
          child: Builder(
            builder: (anchor) => Semantics(
              label: '$identity. $pickerLabel',
              button: true,
              enabled: scope?.onPickWorkspace != null,
              excludeSemantics: true,
              onTap: scope?.onPickWorkspace == null
                  ? null
                  : () => scope!.onPickWorkspace!(anchor, mode: mode),
              child: Tooltip(
                message: pickerLabel,
                child: StudioButtonPress(
                  child: InkWell(
                    key: const ValueKey('workspace-picker-target'),
                    borderRadius: WingRadius.control,
                    onTap: scope?.onPickWorkspace == null
                        ? null
                        : () => scope!.onPickWorkspace!(anchor, mode: mode),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: 48,
                        minWidth: 48,
                      ),
                      child: Align(
                        alignment: alignment,
                        widthFactor: 1,
                        heightFactor: 1,
                        child: Text(
                          identity,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style ?? Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return status == null
        ? labelBody()
        : ListenableBuilder(
            listenable: status!,
            builder: (_, _) => labelBody(),
          );
  }
}

/// Compact menu identity: icon, name, then LED. Version actions are separate.
class DrawerConnectionLabel extends StatelessWidget {
  const DrawerConnectionLabel({
    super.key,
    required this.connection,
    this.status,
  });
  final SavedConnection? connection;
  final ServerConnectionStatus? status;

  @override
  Widget build(BuildContext context) {
    final label = connection?.label ?? 'No server selected';
    void openDetails() =>
        showServerConnectionDetails(context, label: label, status: status);
    Widget contents() {
      final description = '$label, ${status?.description ?? 'Not checked'}';
      final onTap = connection == null ? null : openDetails;
      return Semantics(
        label:
            '$description${connection == null ? '' : '. Connection details'}',
        button: onTap != null,
        onTap: onTap,
        excludeSemantics: true,
        child: Tooltip(
          message: description,
          child: StudioButtonPress(
            child: InkWell(
              key: const ValueKey('menu-connection'),
              borderRadius: WingRadius.control,
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    heightFactor: 1,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          (connection?.icon ?? ConnectionIcon.server).glyph,
                          size: 18,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: _connectionIdentityGap),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: _connectionIdentityGap),
                        _ConnectionLed(
                          phase:
                              status?.phase ?? ServerConnectionPhase.unchecked,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return status == null
        ? contents()
        : ListenableBuilder(listenable: status!, builder: (_, _) => contents());
  }
}

/// Used beside a navigable connection row so inspecting status never selects it.
class ServerConnectionIndicator extends StatelessWidget {
  final String label;
  final ServerConnectionStatus? status;
  final ConnectionIcon icon;
  final VoidCallback onIconPressed;
  const ServerConnectionIndicator({
    super.key,
    required this.label,
    required this.onIconPressed,
    this.status,
    this.icon = ConnectionIcon.server,
  });
  @override
  Widget build(BuildContext context) {
    void openDetails() =>
        showServerConnectionDetails(context, label: label, status: status);
    Widget contents() => Semantics(
      button: true,
      label:
          '$label, ${status?.description ?? 'Not checked'}. Connection details',
      focusable: true,
      onTap: openDetails,
      excludeSemantics: true,
      child: StudioButtonPress(
        child: InkWell(
          onTap: openDetails,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: _ConnectionLed(
                  phase: status?.phase ?? ServerConnectionPhase.unchecked,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConnectionIconButton(icon: icon, onPressed: onIconPressed),
        status == null
            ? contents()
            : ListenableBuilder(
                listenable: status!,
                builder: (_, _) => contents(),
              ),
      ],
    );
  }
}

class _ConnectionLed extends StatefulWidget {
  final ServerConnectionPhase phase;
  const _ConnectionLed({required this.phase});
  @override
  State<_ConnectionLed> createState() => _ConnectionLedState();
}

class _ConnectionLedState extends State<_ConnectionLed>
    with SingleTickerProviderStateMixin {
  late final AnimationController pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  void sync() {
    final animate =
        widget.phase == ServerConnectionPhase.reconnecting &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (animate && !pulse.isAnimating) pulse.repeat(reverse: true);
    if (!animate) {
      pulse.stop();
      pulse.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(covariant _ConnectionLed oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<WingTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? WingTokens.dark()
            : WingTokens.light());
    final color = switch (widget.phase) {
      ServerConnectionPhase.connected => tokens.success,
      ServerConnectionPhase.reconnecting ||
      ServerConnectionPhase.limited => tokens.warning,
      ServerConnectionPhase.disconnected => tokens.danger,
      ServerConnectionPhase.unchecked => tokens.muted,
    };
    return FadeTransition(
      opacity: Tween<double>(
        begin: .45,
        end: 1,
      ).animate(CurvedAnimation(parent: pulse, curve: Curves.easeInOut)),
      child: Container(
        key: const ValueKey('server-connection-led'),
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _ConnectionDetails extends StatelessWidget {
  final String label;
  final ServerConnectionStatus? status;
  const _ConnectionDetails({required this.label, this.status});
  String availability(ConnectionAvailability? state) => switch (state) {
    ConnectionAvailability.available => 'Available',
    ConnectionAvailability.unavailable => 'Unavailable',
    _ => 'Not checked',
  };
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget contents() => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Connection details',
                      style: theme.textTheme.titleLarge?.copyWith(fontSize: 20),
                    ),
                  ),
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Close connection details',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(label, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    _ConnectionLed(
                      phase: status?.phase ?? ServerConnectionPhase.unchecked,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        status?.description ?? 'Not checked',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: WingRadius.card,
                ),
                child: Column(
                  children: [
                    _ConnectionAvailabilityRow(
                      icon: Icons.dns_outlined,
                      title: 'Server access',
                      value: availability(status?.access),
                    ),
                    const Divider(height: 1),
                    _ConnectionAvailabilityRow(
                      icon: Icons.forum_outlined,
                      title: 'Live chat',
                      value: availability(status?.live),
                    ),
                  ],
                ),
              ),
              if (status?.problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: StudioError(status!.problem!),
                ),
              if (status?.chatEndpointUnsupported == true)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    'Open the instance menu, choose Edit instance and check the gateway Webapp address.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (status?.phase == ServerConnectionPhase.disconnected &&
                  status?.recoveryProblem == null &&
                  status?.chatEndpointUnsupported != true)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    'We’ll try again when your network returns or you reopen Wing. You can also retry now.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (status?.retry != null &&
                  status?.phase != ServerConnectionPhase.connected)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: StudioButtonPress(
                    child: IconButton.outlined(
                      onPressed: status?.recoveryAttemptInProgress == true
                          ? null
                          : () => status!.retry!(),
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Retry connection',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return status == null
        ? contents()
        : ListenableBuilder(listenable: status!, builder: (_, _) => contents());
  }
}

class _ConnectionAvailabilityRow extends StatelessWidget {
  const _ConnectionAvailabilityRow({
    required this.icon,
    required this.title,
    required this.value,
  });
  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodyMedium),
                Text(value, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
