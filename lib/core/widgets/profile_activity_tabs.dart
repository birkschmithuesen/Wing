import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';
import 'anchored_expansion_tile.dart';

/// A category of chat activity. Stable ids preserve selection as counts change.
class ProfileActivityTab {
  const ProfileActivityTab({
    required this.id,
    required this.label,
    required this.child,
    this.onSelected,
  });
  final String id;
  final String label;
  final Widget child;
  final VoidCallback? onSelected;
}

/// The same 12dp inset separates the tab edge, guide and list content.
class ProfileActivityGuide extends StatelessWidget {
  const ProfileActivityGuide({super.key, required this.child, this.inset = 12});
  final Widget child;
  final double inset;
  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.only(left: inset),
    padding: const EdgeInsets.only(left: 12),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: .65),
        ),
      ),
    ),
    child: child,
  );
}

class ProfileActivityTabs extends StatefulWidget {
  const ProfileActivityTabs({super.key, required this.tabs, this.initialTabId});
  final List<ProfileActivityTab> tabs;
  final String? initialTabId;
  @override
  State<ProfileActivityTabs> createState() => _ProfileActivityTabsState();
}

class _ProfileActivityTabsState extends State<ProfileActivityTabs> {
  String? _selected;
  final _visited = <String>{};
  final _anchor = GlobalKey();
  bool _visible = false;

  void _activate(ProfileActivityTab tab, {bool notify = true}) {
    _selected = tab.id;
    _visited.add(tab.id);
    if (notify) _notifySelection(tab);
  }

  void _notifySelection(ProfileActivityTab tab) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _selected == tab.id &&
          TickerMode.valuesOf(context).enabled) {
        tab.onSelected?.call();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.tabs.isNotEmpty) {
      _activate(
        widget.tabs.firstWhere(
          (tab) => tab.id == widget.initialTabId,
          orElse: () => widget.tabs.first,
        ),
        notify: false,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_visible) {
      final selected = widget.tabs
          .where((tab) => tab.id == _selected)
          .firstOrNull;
      if (selected != null) _notifySelection(selected);
    }
    _visible = visible;
  }

  @override
  void didUpdateWidget(ProfileActivityTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.retainAll(widget.tabs.map((tab) => tab.id));
    if (!widget.tabs.any((tab) => tab.id == _selected)) {
      if (widget.tabs.isEmpty) {
        _selected = null;
      } else {
        _activate(widget.tabs.first);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExpansionSizeObserver(
      key: _anchor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.tabs.isNotEmpty) ...[
            Container(
              margin: const EdgeInsets.only(top: 3, bottom: 9),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(7),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Keep a slim single row at ordinary sizes. Large accessibility
                  // text and extra categories wrap instead of clipping labels.
                  final columns =
                      (constraints.maxWidth /
                              (100 *
                                  MediaQuery.textScalerOf(context).scale(13) /
                                  13))
                          .floor()
                          .clamp(1, widget.tabs.length);
                  return Wrap(
                    children: [
                      for (final tab in widget.tabs)
                        SizedBox(
                          width: constraints.maxWidth / columns,
                          child: Semantics(
                            selected: tab.id == _selected,
                            button: true,
                            child: Material(
                              color: tab.id == _selected
                                  ? colors.primaryContainer
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(4),
                              child: StudioButtonPress(
                                child: InkWell(
                                  key: ValueKey(('activity-tab', tab.id)),
                                  borderRadius: BorderRadius.circular(4),
                                  onTap: () {
                                    if (tab.id == _selected) return;
                                    final anchor = _anchor.currentContext;
                                    if (anchor != null) {
                                      ExpansionAnchorNotification(
                                        anchor,
                                        allowBottomGap: true,
                                      ).dispatch(context);
                                    }
                                    setState(() => _activate(tab));
                                  },
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minHeight: 24,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 3,
                                      ),
                                      child: Text(
                                        tab.label,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 13,
                                          height: 1.25,
                                          fontWeight: FontWeight.w400,
                                          letterSpacing: 0,
                                          color: tab.id == _selected
                                              ? colors.primary
                                              : colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            ProfileActivityGuide(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final tab in widget.tabs)
                    if (_visited.contains(tab.id))
                      Visibility(
                        key: ValueKey(('activity-page', tab.id)),
                        visible: _selected == tab.id,
                        maintainState: true,
                        child: tab.child,
                      ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
