import 'studio_form_actions.dart';
import 'package:flutter/material.dart';

import '../models/connection_icon.dart';
import '../theme/wing_theme.dart';
import 'studio_error.dart';

extension ConnectionIconPresentation on ConnectionIcon {
  String get label => switch (this) {
    ConnectionIcon.server => 'Server',
    ConnectionIcon.cloud => 'Cloud',
    ConnectionIcon.home => 'Home',
    ConnectionIcon.terminal => 'Terminal',
    ConnectionIcon.globe => 'Globe',
    ConnectionIcon.database => 'Database',
    ConnectionIcon.rocket => 'Rocket',
    ConnectionIcon.beaker => 'Science',
    ConnectionIcon.repo => 'Repository',
    ConnectionIcon.folder => 'Folder',
    ConnectionIcon.star => 'Star',
    ConnectionIcon.target => 'Target',
    ConnectionIcon.lightbulb => 'Idea',
    ConnectionIcon.book => 'Book',
    ConnectionIcon.bug => 'Bug',
    ConnectionIcon.desktop => 'Desktop',
  };

  IconData get glyph => switch (this) {
    ConnectionIcon.server => Icons.dns_outlined,
    ConnectionIcon.cloud => Icons.cloud_outlined,
    ConnectionIcon.home => Icons.home_outlined,
    ConnectionIcon.terminal => Icons.terminal,
    ConnectionIcon.globe => Icons.public,
    ConnectionIcon.database => Icons.storage_outlined,
    ConnectionIcon.rocket => Icons.rocket_launch_outlined,
    ConnectionIcon.beaker => Icons.science_outlined,
    ConnectionIcon.repo => Icons.account_tree_outlined,
    ConnectionIcon.folder => Icons.folder_outlined,
    ConnectionIcon.star => Icons.star_outline,
    ConnectionIcon.target => Icons.adjust,
    ConnectionIcon.lightbulb => Icons.lightbulb_outline,
    ConnectionIcon.book => Icons.menu_book_outlined,
    ConnectionIcon.bug => Icons.bug_report_outlined,
    ConnectionIcon.desktop => Icons.desktop_windows_outlined,
  };
}

class ConnectionIconBadge extends StatelessWidget {
  const ConnectionIconBadge({super.key, required this.icon});

  final ConnectionIcon icon;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: WingRadius.control,
      ),
      child: Icon(
        icon.glyph,
        size: 20,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// A decorative 32 dp badge inside its own 48 dp editing target.
class ConnectionIconButton extends StatelessWidget {
  const ConnectionIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
  });

  final ConnectionIcon icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => StudioButtonPress(
    child: IconButton(
      tooltip: 'Change connection icon',
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.all(8),
        shape: const RoundedRectangleBorder(borderRadius: WingRadius.control),
      ),
      icon: ConnectionIconBadge(icon: icon),
    ),
  );
}

Future<void> showConnectionIconPicker(
  BuildContext context, {
  required String connectionName,
  required ConnectionIcon initialIcon,
  required Future<void> Function(ConnectionIcon) onSave,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _ConnectionIconPicker(
    connectionName: connectionName,
    initialIcon: initialIcon,
    onSave: onSave,
  ),
);

class _ConnectionIconPicker extends StatefulWidget {
  const _ConnectionIconPicker({
    required this.connectionName,
    required this.initialIcon,
    required this.onSave,
  });

  final String connectionName;
  final ConnectionIcon initialIcon;
  final Future<void> Function(ConnectionIcon) onSave;

  @override
  State<_ConnectionIconPicker> createState() => _ConnectionIconPickerState();
}

class _ConnectionIconPickerState extends State<_ConnectionIconPicker> {
  late ConnectionIcon _selected = widget.initialIcon;
  bool _saving = false;
  bool _failed = false;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.onSave(_selected);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: StudioFormSheet(
      actions: StudioFormActions(
        onCancel: _saving ? null : () => Navigator.pop(context),
        onConfirm: _saving ? null : _save,
        confirmLabel: 'Save connection icon',
        busy: _saving,
        progressLabel: 'Saving connection icon',
      ),
      children: [
        Text(
          'Instance icon',
          style: Theme.of(context).dialogTheme.titleTextStyle,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            ConnectionIconBadge(icon: _selected),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                widget.connectionName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(_selected.label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final icon in ConnectionIcon.values)
              Semantics(
                selected: icon == _selected,
                child: StudioButtonPress(
                  child: IconButton(
                    key: ValueKey('connection-icon-${icon.name}'),
                    tooltip: icon.label,
                    isSelected: icon == _selected,
                    style: ButtonStyle(
                      minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
                      shape: WidgetStatePropertyAll(
                        RoundedRectangleBorder(
                          borderRadius: WingRadius.control,
                        ),
                      ),
                      backgroundColor: WidgetStatePropertyAll(
                        icon == _selected
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                      ),
                      side: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.focused)
                            ? BorderSide(
                                color: Theme.of(context).colorScheme.primary,
                                width: 2,
                              )
                            : null,
                      ),
                    ),
                    onPressed: _saving
                        ? null
                        : () => setState(() => _selected = icon),
                    icon: Icon(icon.glyph, size: 24, semanticLabel: icon.label),
                  ),
                ),
              ),
          ],
        ),
        if (_failed) ...[
          const SizedBox(height: 16),
          const StudioError('Couldn’t save this icon. Try again.'),
        ],
        const SizedBox(height: 24),
      ],
    ),
  );
}
