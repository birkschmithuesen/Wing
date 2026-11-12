import 'package:flutter/material.dart';
import 'health_alerts/health_alert_bell.dart';
import 'studio_loading.dart';

/// Shared identity geometry for bot chats and passive group previews.
class WingConversationTitle extends StatelessWidget {
  const WingConversationTitle({super.key, required this.title, this.avatar});

  final String title;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (avatar case final artwork?) ...[
        ExcludeSemantics(child: artwork),
        const SizedBox(width: 8),
      ],
      Flexible(
        child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}

/// All routes share the Chats density: a 48dp title/action row, followed by
/// optional scope context. At enlarged text, secondary actions get their own
/// row. They also move below when they would squeeze a title onto extra
/// lines; the bell always remains beside the title. No business policy or I/O.
class WingAppBar extends StatelessWidget implements PreferredSizeWidget {
  WingAppBar({
    super.key,
    required BuildContext context,
    this.title,
    this.leading,
    this.actions = const [],
    this.contextRow,
    this.contextActions = const [],
    this.contextHeight = 48,
    this.inlineContext = false,
    this.bottom,
    this.backgroundColor,
    this.surfaceTintColor,
    this.shape,
    this.centerTitle = false,
    this.titleSpacing = 8,
    this.automaticallyImplyLeading = true,
    bool inlineActions = false,
  }) : assert(contextRow != null || contextActions.isEmpty) {
    var separateActions =
        !inlineActions &&
        !inlineContext &&
        MediaQuery.textScalerOf(context).scale(16) >= 24;
    final style = titleStyle(context);
    final label = title is Text ? (title as Text).data : null;
    final actionsWidth = actions.fold<double>(
      0,
      (width, action) =>
          width +
          (action is PreferredSizeWidget ? action.preferredSize.width : 48),
    );
    final available =
        (MediaQuery.sizeOf(context).width -
                56 -
                2 * titleSpacing -
                48 -
                (contextRow == null ? 32 : 0))
            .clamp(0.0, double.infinity);
    final painter =
        TextPainter(
          text: TextSpan(text: label ?? 'Title', style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: title is Text ? (title as Text).maxLines ?? 6 : 1,
        )..layout(
          maxWidth: (available - (separateActions ? 0 : actionsWidth)).clamp(
            0.0,
            double.infinity,
          ),
        );
    if (!inlineActions &&
        !inlineContext &&
        !separateActions &&
        actions.isNotEmpty &&
        painter.computeLineMetrics().length > 1) {
      separateActions = true;
      painter.layout(maxWidth: available);
    }
    _large = separateActions;
    _rowHeight = (painter.height + 8).clamp(48.0, double.infinity);
    painter.dispose();
  }
  final Widget? title, leading, contextRow;
  final List<Widget> actions, contextActions;
  final PreferredSizeWidget? bottom;
  final double contextHeight, titleSpacing;
  final bool inlineContext;
  final Color? backgroundColor, surfaceTintColor;
  final ShapeBorder? shape;
  final bool centerTitle, automaticallyImplyLeading;
  late final bool _large;
  late final double _rowHeight;
  static TextStyle titleStyle(BuildContext context) => Theme.of(
    context,
  ).textTheme.titleLarge!.copyWith(fontSize: 24, fontWeight: FontWeight.w600);

  /// Conversation previews and mounted chats use a single-line title surface.
  /// Cached pixels reserve the same context-row slot for opening feedback.
  static double conversationTitleHeight(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: 'Title', style: titleStyle(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = (painter.height + 8).clamp(48.0, double.infinity);
    painter.dispose();
    return height;
  }

  double get _bottomHeight =>
      (contextRow == null || inlineContext ? 0 : contextHeight) +
      (_large && actions.isNotEmpty ? 48 : 0) +
      (bottom?.preferredSize.height ?? 0);
  @override
  Size get preferredSize => Size.fromHeight(_rowHeight + _bottomHeight);
  @override
  Widget build(BuildContext context) => AppBar(
    toolbarHeight: _rowHeight,
    titleSpacing: titleSpacing,
    leading: leading,
    automaticallyImplyLeading: automaticallyImplyLeading,
    centerTitle: centerTitle,
    backgroundColor: backgroundColor,
    surfaceTintColor: surfaceTintColor,
    shape: shape,
    titleTextStyle: titleStyle(context),
    title: title == null
        ? null
        : MediaQuery(
            data: MediaQuery.of(context),
            child: title is Text && (title as Text).data != null
                ? Text(
                    (title as Text).data!,
                    maxLines: (title as Text).maxLines ?? 6,
                    softWrap: (title as Text).softWrap,
                    overflow: (title as Text).overflow,
                  )
                : inlineContext && contextRow != null
                ? Row(
                    children: [
                      Flexible(flex: 2, child: title!),
                      const SizedBox(width: 12),
                      Flexible(flex: 3, child: contextRow!),
                    ],
                  )
                : title!,
          ),
    actions: [
      const HealthAlertBell(),
      if (inlineContext) ...contextActions,
      if (!_large) ...actions,
      if (contextRow == null || inlineContext) const StudioLoadingSlot(),
    ],
    bottom: _bottomHeight == 0
        ? null
        : PreferredSize(
            preferredSize: Size.fromHeight(_bottomHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (contextRow != null && !inlineContext)
                  SizedBox(
                    height: contextHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: contextHeight,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: contextRow!,
                                ),
                              ),
                            ),
                            ...contextActions,
                            const StudioLoadingSlot(),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_large && actions.isNotEmpty)
                  SizedBox(
                    height: 48,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: actions,
                    ),
                  ),
                ?bottom,
              ],
            ),
          ),
  );
}
