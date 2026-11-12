import 'package:flutter/material.dart';

import '../theme/wing_theme.dart';

/// Keeps an action's caption and measured size unchanged while work is pending.
class StudioActionLabel extends StatelessWidget {
  const StudioActionLabel(this.label, {required this.busy, super.key})
    : _leadingIcon = null,
      _compact = false;

  /// Centers an unchanged icon and caption as a group.
  const StudioActionLabel.compact(
    this.label, {
    required this.busy,
    required IconData icon,
    super.key,
  }) : _leadingIcon = icon,
       _compact = true;

  /// A left-aligned caption whose action icon stays visible while pending.
  const StudioActionLabel.row(
    this.label, {
    required this.busy,
    required IconData icon,
    super.key,
  }) : _leadingIcon = icon,
       _compact = false;

  final String label;
  final bool busy;
  final IconData? _leadingIcon;
  final bool _compact;

  @override
  Widget build(BuildContext context) => Semantics(
    label: busy ? '$label, in progress' : label,
    liveRegion: busy,
    child: ExcludeSemantics(
      child: _leadingIcon != null && !_compact
          ? Row(
              children: [
                SizedBox.square(
                  dimension: 20,
                  child: Icon(_leadingIcon, size: 20),
                ),
                const SizedBox(width: WingSpacing.md),
                Expanded(child: Text(label)),
              ],
            )
          : Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: EdgeInsets.only(left: 24, right: _compact ? 0 : 24),
                  child: Text(label, textAlign: TextAlign.center),
                ),
                if (busy || _leadingIcon != null)
                  Positioned(
                    left: 0,
                    child: SizedBox.square(
                      dimension: 16,
                      child: _leadingIcon == null
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : Icon(_leadingIcon, size: 16),
                    ),
                  ),
              ],
            ),
    ),
  );
}
