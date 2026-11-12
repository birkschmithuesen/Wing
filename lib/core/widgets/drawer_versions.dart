import 'dart:async';

import 'package:flutter/material.dart';

import '../services/connection_access.dart';
import '../screens/versions_updates_screen.dart';
import '../services/versions_controller.dart';
import '../services/server_connection_status.dart';
import '../theme/wing_theme.dart';
import 'server_connection_label.dart';

class DrawerVersions extends StatefulWidget {
  const DrawerVersions({
    super.key,
    this.access,
    this.connectionStatus,
    this.controllerFactory,
  });

  final ConnectionAccess? access;
  final ServerConnectionStatus? connectionStatus;
  final VersionsControllerFactory? controllerFactory;

  @override
  State<DrawerVersions> createState() => _DrawerVersionsState();
}

class _DrawerVersionsState extends State<DrawerVersions> {
  late VersionsController _versions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _versions = (widget.controllerFactory ?? VersionsController.forConnection)(
      widget.access,
    );
    unawaited(_versions.refresh());
  }

  @override
  void didUpdateWidget(DrawerVersions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.access?.connection != widget.access?.connection ||
            oldWidget.access?.dashboardOAuth !=
                widget.access?.dashboardOAuth) ||
        oldWidget.controllerFactory != widget.controllerFactory) {
      _versions.dispose();
      _load();
    }
  }

  @override
  void dispose() {
    _versions.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final navigator = Navigator.of(context);
    final access = widget.access;
    final factory = widget.controllerFactory;
    // Keep the drawer and its scroll position beneath this route so Back
    // restores the exact menu that opened it. The page captures its connection.
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            VersionsUpdatesScreen(access: access, controllerFactory: factory),
      ),
    );
    if (mounted) unawaited(_versions.refresh());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _versions,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: DrawerConnectionLabel(
                connection: widget.access?.connection,
                status: widget.connectionStatus,
              ),
            ),
            if (widget.access != null) ...[
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .46,
                ),
                child: _version(context),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _version(BuildContext context) {
    final theme = Theme.of(context);
    final server = _versions.server;
    final version = server?.installedVersion;
    final updateAvailable = server?.check?.updateAvailable == true;
    final label = version == null
        ? (server?.versionLoading == true ? '…' : '—')
        : (version.startsWith('v') ? version : 'v$version');
    final description =
        'Server version: ${version ?? (server?.versionLoading == true ? 'Loading' : 'Unavailable')}'
        '${server?.versionStale == true ? ', last known version' : ''}'
        '${updateAvailable ? ', update available' : ''}';
    return Semantics(
      label: description,
      button: true,
      onTap: _open,
      excludeSemantics: true,
      child: Tooltip(
        message: description,
        child: StudioButtonPress(
          child: InkWell(
            key: const ValueKey('menu-server-version'),
            borderRadius: WingRadius.control,
            onTap: _open,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Align(
                  alignment: Alignment.bottomRight,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (updateAvailable) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.sync,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                      ],
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
}
