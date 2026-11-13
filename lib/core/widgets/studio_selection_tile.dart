import 'package:flutter/material.dart';

import '../theme/wing_theme.dart';

/// A multiple-choice row. Selection is painted by the row background.
class StudioSelectionTile extends StatelessWidget {
  const StudioSelectionTile({
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 12),
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      checked: value,
      selected: value,
      enabled: onChanged != null,
      child: _SelectionSurface(
        selected: value,
        enabled: onChanged != null,
        title: title,
        subtitle: subtitle,
        contentPadding: contentPadding,
        onTap: onChanged == null ? null : () => onChanged!(!value),
      ),
    ),
  );
}

/// A single-choice row using RadioGroup's focus, arrow keys and semantics.
/// RawRadio supplies interaction without drawing a radio dot or a checkmark.
class StudioRadioTile<T> extends StatefulWidget {
  const StudioRadioTile({
    required this.value,
    required this.title,
    this.subtitle,
    this.enabled = true,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 12),
    this.minTileHeight = 48,
    this.minVerticalPadding = 8,
    super.key,
  });

  final T value;
  final Widget title;
  final Widget? subtitle;
  final bool enabled;
  final EdgeInsetsGeometry contentPadding;
  final double minTileHeight;
  final double minVerticalPadding;

  @override
  State<StudioRadioTile<T>> createState() => _StudioRadioTileState<T>();
}

class _StudioRadioTileState<T> extends State<StudioRadioTile<T>> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: RawRadio<T>(
      value: widget.value,
      enabled: widget.enabled,
      groupRegistry: RadioGroup.maybeOf<T>(context),
      focusNode: _focusNode,
      autofocus: false,
      toggleable: false,
      mouseCursor: WidgetStateMouseCursor.clickable,
      builder: (context, state) => _SelectionSurface(
        selected: state.value == true,
        enabled: widget.enabled,
        focused: state.states.contains(WidgetState.focused),
        title: widget.title,
        subtitle: widget.subtitle,
        contentPadding: widget.contentPadding,
        minTileHeight: widget.minTileHeight,
        minVerticalPadding: widget.minVerticalPadding,
      ),
    ),
  );
}

class _SelectionSurface extends StatelessWidget {
  const _SelectionSurface({
    required this.selected,
    required this.enabled,
    required this.title,
    required this.subtitle,
    required this.contentPadding,
    this.focused = false,
    this.minTileHeight = 48,
    this.minVerticalPadding = 8,
    this.onTap,
  });

  final bool selected;
  final bool enabled;
  final bool focused;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry contentPadding;
  final double minTileHeight;
  final double minVerticalPadding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.primaryContainer : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: WingRadius.control,
        side: focused
            ? BorderSide(color: colors.primary, width: 2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: StudioButtonPress(
        child: ListTile(
          selected: selected,
          enabled: enabled,
          title: title,
          subtitle: subtitle,
          contentPadding: contentPadding,
          minTileHeight: minTileHeight,
          minVerticalPadding: minVerticalPadding,
          onTap: onTap,
        ),
      ),
    );
  }
}
