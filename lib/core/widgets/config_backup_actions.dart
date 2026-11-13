import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

/// App-wide configuration actions, shared by both settings navigation paths.
class ConfigBackupActions extends StatefulWidget
    implements PreferredSizeWidget {
  const ConfigBackupActions({
    super.key,
    required this.onBackup,
    required this.onRestore,
  });

  final Future<void> Function() onBackup;
  final Future<void> Function() onRestore;

  // Both settings routes pass this pair as one app-bar action. Publish its
  // full width so the shared header measures the space left for its title.
  @override
  Size get preferredSize => const Size(96, 48);

  @override
  State<ConfigBackupActions> createState() => _ConfigBackupActionsState();
}

class _ConfigBackupActionsState extends State<ConfigBackupActions> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox.fromSize(
    size: widget.preferredSize,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StudioButtonPress(
          child: IconButton(
            key: const Key('settings_backup_config'),
            tooltip: 'Backup configuration',
            onPressed: _busy ? null : () => _run(widget.onBackup),
            icon: const Icon(Icons.upload_file),
          ),
        ),
        StudioButtonPress(
          child: IconButton(
            key: const Key('settings_restore_config'),
            tooltip: 'Restore configuration',
            onPressed: _busy ? null : () => _run(widget.onRestore),
            icon: const Icon(Icons.settings_backup_restore),
          ),
        ),
      ],
    ),
  );
}
