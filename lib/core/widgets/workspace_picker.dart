import 'package:flutter/material.dart';

import '../models/connection.dart';
import '../models/hermes_profile.dart';
import '../theme/wing_theme.dart';
import 'connection_icon_picker.dart';

enum WorkspacePickerMode {
  connections,
  profiles,
  analytics,
  connectionAndProfile;

  bool get includesConnections =>
      this == connections || this == connectionAndProfile;
  bool get includesProfiles => this != connections;
  String get label => switch (this) {
    connections => 'Choose instance',
    profiles || analytics => 'Choose profile',
    connectionAndProfile => 'Choose instance and profile',
  };
}

enum WorkspaceChoiceKind { connection, profile, allProfiles }

typedef WorkspaceChoice = ({String? id, WorkspaceChoiceKind kind});

/// A separate profile filter beside the standard instance header.
class WorkspaceProfilePicker extends StatelessWidget {
  const WorkspaceProfilePicker({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final ValueChanged<BuildContext> onPressed;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => Semantics(
      label: '$label. Choose profile',
      button: true,
      excludeSemantics: true,
      onTap: () => onPressed(anchor),
      child: Tooltip(
        message: 'Choose profile',
        child: StudioButtonPress(
          child: InkWell(
            key: const ValueKey('analytics-profile-picker-target'),
            borderRadius: WingRadius.control,
            onTap: () => onPressed(anchor),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more, size: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<WorkspaceChoice?> showWorkspacePicker(
  BuildContext context, {
  required List<SavedConnection> connections,
  required String connectionId,
  required List<HermesProfile> profiles,
  required String? profileName,
  required bool busy,
  required WorkspacePickerMode mode,
}) {
  final tokens = WingTokens.of(context);
  final colors = Theme.of(context).colorScheme;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  RelativeRect position() {
    final box = context.findRenderObject()! as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    return RelativeRect.fromRect(
      Rect.fromLTWH(rect.left, rect.bottom + 4, rect.width, 0),
      Offset.zero & overlay.size,
    );
  }

  var lastPosition = position();
  PopupMenuItem<WorkspaceChoice> heading(String label) => StudioPopupMenuItem(
    enabled: false,
    height: 32,
    child: Text(label, style: Theme.of(context).textTheme.labelSmall),
  );
  PopupMenuItem<WorkspaceChoice> option(
    WorkspaceChoice value,
    String label,
    bool selected, {
    IconData? icon,
  }) => StudioPopupMenuItem(
    key: ValueKey(
      value.kind == WorkspaceChoiceKind.allProfiles
          ? 'workspace-all-profiles'
          : 'workspace-${value.kind.name}-${value.id}',
    ),
    value: value,
    enabled: !busy,
    padding: EdgeInsets.zero,
    child: Semantics(
      selected: selected,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        color: selected ? colors.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18),
              const SizedBox(width: 12),
            ],
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  );
  return showMenu<WorkspaceChoice>(
    context: context,
    semanticLabel: mode.label,
    requestFocus: true,
    positionBuilder: (_, _) {
      if (context.mounted) lastPosition = position();
      return lastPosition;
    },
    constraints: const BoxConstraints(minWidth: 240, maxWidth: 300),
    color: tokens.raised,
    surfaceTintColor: Colors.transparent,
    elevation: 4,
    shape: RoundedRectangleBorder(
      borderRadius: WingRadius.card,
      side: BorderSide(color: tokens.border),
    ),
    items: [
      if (mode.includesConnections) ...[
        heading('Hermes instance'),
        for (final connection in connections)
          option(
            (id: connection.id, kind: WorkspaceChoiceKind.connection),
            connection.label,
            connection.id == connectionId,
            icon: connection.icon.glyph,
          ),
      ],
      if (mode.includesProfiles) ...[
        if (mode.includesConnections) const PopupMenuDivider(),
        heading('Profile'),
        if (mode == WorkspacePickerMode.analytics && profiles.isNotEmpty)
          option(
            (id: null, kind: WorkspaceChoiceKind.allProfiles),
            'All',
            profileName == null,
          ),
        if (profiles.isEmpty) heading('Profiles unavailable'),
        for (final profile in profiles)
          option(
            (id: profile.name, kind: WorkspaceChoiceKind.profile),
            profile.label,
            profile.name == profileName,
          ),
      ],
    ],
  );
}
