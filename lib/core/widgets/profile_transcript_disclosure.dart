import 'package:flutter/material.dart';
import 'anchored_expansion_tile.dart';

/// Quiet metadata header for optional details between conversation messages.
class ProfileTranscriptDisclosure extends StatefulWidget {
  const ProfileTranscriptDisclosure({
    super.key,
    required this.label,
    required this.icon,
    required this.children,
    this.summary,
    this.trailing,
    this.initiallyExpanded = false,
    this.anchorExpansion = true,
    this.isError = false,
    this.maintainState = true,
    this.onExpansionChanged,
    this.childrenPadding = EdgeInsets.zero,
  });

  final String label;
  final IconData? icon;
  final Widget? trailing;
  final Widget? summary;
  final List<Widget> children;
  final bool initiallyExpanded;
  final bool anchorExpansion;
  final bool isError;
  final bool maintainState;
  final ValueChanged<bool>? onExpansionChanged;
  final EdgeInsetsGeometry childrenPadding;

  @override
  State<ProfileTranscriptDisclosure> createState() =>
      _ProfileTranscriptDisclosureState();
}

class _ProfileTranscriptDisclosureState
    extends State<ProfileTranscriptDisclosure> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListTileTheme.merge(
      minVerticalPadding: 0,
      horizontalTitleGap: 0,
      child: AnchoredExpansionTile(
        initiallyExpanded: widget.initiallyExpanded,
        anchorExpansion: widget.anchorExpansion,
        maintainState: widget.maintainState,
        minTileHeight: widget.trailing == null ? 28 : 48,
        tilePadding: EdgeInsets.zero,
        childrenPadding: widget.childrenPadding,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        shape: const Border(),
        collapsedShape: const Border(),
        showTrailingIcon: false,
        onExpansionChanged: (expanded) {
          setState(() => _expanded = expanded);
          widget.onExpansionChanged?.call(expanded);
        },
        title: DefaultTextStyle(
          style: Theme.of(context).textTheme.labelMedium!.copyWith(
            fontSize: 13,
            height: 1.25,
            fontWeight: FontWeight.w400,
            letterSpacing: 0,
            color: color,
          ),
          child: Row(
            children: [
              if (widget.icon != null)
                Icon(
                  widget.icon,
                  size: 16,
                  color: widget.isError
                      ? Theme.of(context).colorScheme.error
                      : color,
                ),
              if (widget.icon != null) const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(widget.label),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.summary != null) ...[
                          Flexible(child: widget.summary!),
                          const SizedBox(width: 8),
                        ],
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_right_rounded,
                          size: 16,
                          color: color,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              ?widget.trailing,
            ],
          ),
        ),
        children: widget.children,
      ),
    );
  }
}
