import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

/// A small switch face with an unscaled touch and accessibility target.
class CompactSwitch extends StatelessWidget {
  const CompactSwitch({
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      label: semanticLabel,
      child: SizedBox.square(
        dimension: 48,
        child: Transform.scale(
          scale: .75,
          transformHitTests: false,
          child: Switch(
            value: value,
            onChanged: onChanged,
            padding: EdgeInsets.zero,
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
      ),
    ),
  );
}

/// The entire setting row toggles, with one merged accessibility action.
class CompactSwitchListTile extends StatelessWidget {
  const CompactSwitchListTile({
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.contentPadding,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: StudioButtonPress(
      child: ListTile(
        contentPadding:
            contentPadding ?? const EdgeInsets.symmetric(horizontal: 16),
        minTileHeight: 48,
        minVerticalPadding: 4,
        horizontalTitleGap: 12,
        title: title,
        subtitle: subtitle,
        titleTextStyle: Theme.of(context).textTheme.bodyLarge,
        subtitleTextStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: CompactSwitch(value: value, onChanged: onChanged),
      ),
    ),
  );
}
