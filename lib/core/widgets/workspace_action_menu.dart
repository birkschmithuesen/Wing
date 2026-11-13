import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/wing_theme.dart';

/// Compact row actions anchored to the invoking control, with native dismissal
/// and keyboard navigation. The menu repositions when the viewport changes.
Future<String?> showWorkspaceActionMenu(
  BuildContext context,
  String title,
  String scope,
  List<(String, String, IconData, bool)> actions, {
  String keyPrefix = 'action',
}) {
  final theme = Theme.of(context);
  final tokens = WingTokens.of(context);
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  // A live list update can deactivate the invoking element before the popup's
  // first layout. Capture its render box while the element is still active;
  // mounted alone does not make a later findRenderObject() safe.
  final box = context.findRenderObject()! as RenderBox;
  RelativeRect position() {
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    // Anchor the trailing control, including when opened by long-pressing a row.
    return RelativeRect.fromRect(
      Rect.fromLTWH(rect.right - 48, rect.bottom + 4, 48, 0),
      Offset.zero & overlay.size,
    );
  }

  var lastPosition = position();
  HapticFeedback.selectionClick();
  return showMenu<String>(
    context: context,
    semanticLabel: 'Actions for $title in $scope',
    requestFocus: true,
    positionBuilder: (_, _) {
      if (box.attached && overlay.attached && box.hasSize && overlay.hasSize) {
        lastPosition = position();
      }
      return lastPosition;
    },
    constraints: const BoxConstraints(minWidth: 240, maxWidth: 280),
    color: tokens.raised,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: WingRadius.card,
      side: BorderSide(color: tokens.border),
    ),
    elevation: 4,
    menuPadding: const EdgeInsets.symmetric(vertical: WingSpacing.xs),
    popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(duration: Duration(milliseconds: 160)),
    items: [
      StudioPopupMenuItem<String>(
        enabled: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                scope,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      const PopupMenuDivider(height: 9),
      for (final (id, label, icon, enabled) in actions) ...[
        if (id == 'archive' || id == 'delete')
          const PopupMenuDivider(height: 9),
        StudioPopupMenuItem<String>(
          key: ValueKey('$keyPrefix-$id'),
          value: id,
          enabled: enabled,
          height: 48,
          child: Row(
            children: [
              Icon(
                icon,
                size: 19,
                color: !enabled
                    ? theme.disabledColor
                    : id == 'delete'
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    color: !enabled
                        ? theme.disabledColor
                        : id == 'delete'
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ],
  );
}
