import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Lets a reversed transcript hold the disclosure header in place during layout.
class ExpansionAnchorNotification extends Notification {
  ExpansionAnchorNotification(
    this.anchor, {
    required this.allowBottomGap,
    this.preserveHeader = true,
  });

  final BuildContext anchor;

  /// Live outer activity reveals its growing body in the reversed transcript.
  final bool preserveHeader;

  /// Expansion/tab selection can hold a control above the natural bottom.
  /// Collapse must remove that reserved space once the content shrinks.
  final bool allowBottomGap;
}

class AnchoredExpansionTile extends StatelessWidget {
  const AnchoredExpansionTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.showTrailingIcon = true,
    this.children = const [],
    this.initiallyExpanded = false,
    this.maintainState = false,
    this.anchorExpansion = true,
    this.minTileHeight,
    this.tilePadding,
    this.childrenPadding,
    this.shape,
    this.collapsedShape,
    this.expandedCrossAxisAlignment,
    this.onExpansionChanged,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool showTrailingIcon;
  final List<Widget> children;
  final bool initiallyExpanded;
  final bool maintainState;
  final bool anchorExpansion;
  final double? minTileHeight;
  final EdgeInsetsGeometry? tilePadding;
  final EdgeInsetsGeometry? childrenPadding;
  final ShapeBorder? shape;
  final ShapeBorder? collapsedShape;
  final CrossAxisAlignment? expandedCrossAxisAlignment;
  final ValueChanged<bool>? onExpansionChanged;

  @override
  Widget build(BuildContext context) => ExpansionSizeObserver(
    child: ExpansionTile(
      title: title,
      subtitle: subtitle,
      leading: leading,
      trailing: trailing,
      showTrailingIcon: showTrailingIcon,
      initiallyExpanded: initiallyExpanded,
      maintainState: maintainState,
      minTileHeight: minTileHeight,
      tilePadding: tilePadding,
      childrenPadding: childrenPadding,
      shape: shape,
      collapsedShape: collapsedShape,
      expandedCrossAxisAlignment: expandedCrossAxisAlignment,
      onExpansionChanged: (expanded) {
        ExpansionAnchorNotification(
          context,
          allowBottomGap: expanded,
          preserveHeader: anchorExpansion,
        ).dispatch(context);
        onExpansionChanged?.call(expanded);
      },
      children: children,
    ),
  );
}

/// Shares transcript anchoring with other disclosures, such as activity tabs.
class ExpansionSizeObserver extends SingleChildRenderObjectWidget {
  const ExpansionSizeObserver({super.key, required super.child});

  @override
  ExpansionAnchorBox createRenderObject(BuildContext context) =>
      ExpansionAnchorBox();
}

/// Reports the disclosure's own size, without reading descendants during layout.
class ExpansionAnchorBox extends RenderProxyBox {
  ValueChanged<double>? onHeightChanged;

  @override
  void performLayout() {
    final previousHeight = hasSize ? size.height : null;
    super.performLayout();
    if (previousHeight != null && previousHeight != size.height) {
      onHeightChanged?.call(size.height - previousHeight);
    }
  }
}
