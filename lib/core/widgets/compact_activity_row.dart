import 'package:flutter/material.dart';

import '../theme/wing_theme.dart';
import 'activity_time.dart';
import 'anchored_expansion_tile.dart';

/// Text-sized tool/saved-agent headers. Spacing cannot be overridden by callers.
/// Detail content keeps its own layout; empty details produce a passive row.
class CompactActivityRow extends StatelessWidget {
  const CompactActivityRow({
    super.key,
    required this.icon,
    required this.title,
    this.lines = const [],
    required this.time,
    this.details = const [],
    this.initiallyExpanded = false,
    this.onExpansionChanged,
  });

  final Widget icon;
  final Text title;
  final List<Widget> lines;
  final ActivityTime time;
  final List<Widget> details;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    final titleStyle = DefaultTextStyle.of(context).style.merge(title.style);
    final firstLineHeight =
        MediaQuery.textScalerOf(context).scale(titleStyle.fontSize!) *
        (titleStyle.height ?? 1);
    final header = LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            height: firstLineHeight,
            child: Center(
              child: IconTheme(
                data: IconThemeData(
                  size: 16,
                  color: WingTokens.of(context).muted,
                ),
                child: icon,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, ...lines],
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * .35),
            child: SizedBox(
              height: firstLineHeight,
              child: Center(widthFactor: 1, child: time),
            ),
          ),
        ],
      ),
    );
    if (details.isEmpty) return header;
    return IconTheme.merge(
      data: const IconThemeData(size: 16),
      child: ListTileTheme.merge(
        minVerticalPadding: 0,
        horizontalTitleGap: 8,
        child: AnchoredExpansionTile(
          initiallyExpanded: initiallyExpanded,
          onExpansionChanged: onExpansionChanged,
          minTileHeight: 0,
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: header,
          children: details,
        ),
      ),
    );
  }
}
