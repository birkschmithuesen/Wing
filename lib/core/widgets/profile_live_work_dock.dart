import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme/wing_theme.dart';

/// Fixed live-work controls. The anchored overlay never changes composer layout.
class ProfileLiveWorkDock extends StatefulWidget {
  const ProfileLiveWorkDock({
    super.key,
    required this.taskCount,
    required this.completedTasks,
    required this.subagentCount,
    required this.taskSummary,
    required this.subagentSummary,
    required this.tasks,
    required this.subagents,
    required this.onAgentsSelected,
    this.onOpenChanged,
    this.processCount,
    this.processes,
    this.processSummary,
    this.onProcessesSelected,
  });

  static const slideDuration = Duration(milliseconds: 220);
  final int? taskCount, completedTasks, subagentCount;
  final Widget tasks, subagents;
  final Widget taskSummary, subagentSummary;
  final Future<void> Function() onAgentsSelected;
  final VoidCallback? onOpenChanged;
  final int? processCount;
  final Widget? processes, processSummary;
  final Future<void> Function()? onProcessesSelected;

  @override
  ProfileLiveWorkDockState createState() => ProfileLiveWorkDockState();
}

class ProfileLiveWorkDockState extends State<ProfileLiveWorkDock>
    with TickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _target = GlobalKey();
  final _pages = PageController();
  final _closedBarScroll = ScrollController();
  var _openBarScroll = ScrollController();
  late final AnimationController _reveal, _split;
  final _contentHeights = <int, double>{};
  Map<int, double> _fromShares = {};
  bool _open = false, _openingPages = false;
  final _refreshing = <int>{};
  bool _instantHeight = false;
  bool _expanded = false;
  double? _dragHeight;
  final _rowScroll = {for (var id = 0; id < 3; id++) id: ScrollController()};
  Offset? _barDistance;
  _WorkPanelPan? _panelPan;
  DragStartDetails? _panStart;
  Offset _panDistance = Offset.zero;
  Axis? _panAxis;
  Drag? _scrollDrag;
  bool _resizing = false;
  double _readerDragDistance = 0;
  double? _readerStartHeight;
  static const _handleHeight = 24.0;
  int _selected = 0, _generation = 0;

  List<int> get _tabs => [
    if ((widget.subagentCount ?? 0) > 0) 0,
    if ((widget.taskCount ?? 0) > 0) 1,
    if (widget.processCount != null) 2,
  ];

  double get _pagePosition =>
      !_openingPages &&
          _pages.hasClients &&
          _pages.position.hasContentDimensions
      ? (_pages.page ?? 0).clamp(0.0, (_tabs.length - 1).toDouble())
      : math.max(0, _tabs.indexOf(_selected)).toDouble();

  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  bool get isOpen => _open;

  /// Let the workspace consume Back before its own conversation navigation.
  bool dismiss() {
    if (!_open) return false;
    _close(keyboard: true);
    return true;
  }

  @override
  void initState() {
    super.initState();
    _selected = _tabs.firstOrNull ?? 0;
    _split = AnimationController(
      vsync: this,
      duration: ProfileLiveWorkDock.slideDuration,
      value: 1,
    );
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 180),
    );
  }

  @override
  void didUpdateWidget(ProfileLiveWorkDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldTabs = [
      if ((oldWidget.subagentCount ?? 0) > 0) 0,
      if ((oldWidget.taskCount ?? 0) > 0) 1,
      if (oldWidget.processCount != null) 2,
    ];
    final tabs = _tabs;
    if (oldTabs.length == tabs.length && oldTabs.every(tabs.contains)) return;
    _cancelPan();
    _fromShares = _shares(oldTabs);
    if (_reduced || tabs.length < oldTabs.length) {
      _split.value = 1;
    } else {
      _split.forward(from: 0);
    }
    _contentHeights.removeWhere((id, _) => !tabs.contains(id));
    if (tabs.isEmpty) {
      ++_generation;
      _open = false;
      _reveal.value = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabs.isEmpty && _portal.isShowing) _portal.hide();
        if (mounted) widget.onOpenChanged?.call();
      });
      return;
    }
    final selectionRemoved = !tabs.contains(_selected);
    if (selectionRemoved) _selected = tabs.first;
    if (_open) {
      _openingPages = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_open || !_pages.hasClients) return;
        _pages.jumpToPage(_tabs.indexOf(_selected));
        setState(() => _openingPages = false);
        if (selectionRemoved) _refreshTab(_selected);
      });
    }
  }

  void _measureContent(int id, double height) {
    if (!mounted || !_tabs.contains(id) || _contentHeights[id] == height) {
      return;
    }
    setState(() => _contentHeights[id] = height);
  }

  Future<void> _refreshTab(int id) async {
    final refresh = switch (id) {
      0 => widget.onAgentsSelected,
      2 => widget.onProcessesSelected,
      _ => null,
    };
    if (refresh == null || _refreshing.contains(id)) return;
    setState(() => _refreshing.add(id));
    try {
      await refresh();
    } catch (_) {
      // Borrowed panels retain errors; reopening retries their read.
    } finally {
      if (mounted) setState(() => _refreshing.remove(id));
    }
  }

  void _select(int index, {bool keyboard = false}) {
    if (!_tabs.contains(index)) return;
    if (_open && index == _selected) {
      _close(keyboard: keyboard);
      return;
    }
    _instantHeight = keyboard;
    final wasOpen = _open;
    ++_generation;
    setState(() {
      _open = true;
      _selected = index;
    });
    if (!wasOpen) widget.onOpenChanged?.call();
    _revealBarTab(index);
    _portal.show();
    if (!wasOpen) {
      _expanded = false;
      _dragHeight = null;
      _openingPages = true;
      if (_reduced || keyboard) {
        _reveal.value = 1;
      } else {
        _reveal.forward();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _open && _pages.hasClients) {
          _pages.jumpToPage(_tabs.indexOf(index));
          _openingPages = false;
        }
      });
    } else if (_pages.hasClients) {
      if (_reduced || keyboard) {
        _pages.jumpToPage(_tabs.indexOf(index));
      } else {
        _pages.animateToPage(
          _tabs.indexOf(index),
          duration: ProfileLiveWorkDock.slideDuration,
          curve: const _WorkPageCurve(),
        );
      }
    }
    _refreshTab(index);
  }

  Future<void> _close({bool keyboard = false}) async {
    final generation = ++_generation;
    setState(() => _open = false);
    widget.onOpenChanged?.call();
    if (_reduced || keyboard) {
      _reveal.value = 0;
    } else {
      try {
        await _reveal.reverse().orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (mounted && generation == _generation && !_open) _portal.hide();
  }

  // Both the bar and the panel use the same distance/flick admission.
  int _swipeDirection(double distance, double velocity) {
    if (velocity.abs() > 250) return velocity.sign.toInt();
    return distance.abs() >= 56 ? distance.sign.toInt() : 0;
  }

  void _openOrExpandTab(int index) {
    if (!_open) {
      _select(index);
      return;
    }
    if (_selected != index) _select(index);
    setState(() {
      _instantHeight = false;
      _expanded = true;
      _dragHeight = null;
    });
  }

  Widget _tabGesture(int index, Widget child) => Listener(
    onPointerCancel: (_) => _barDistance = null,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onPanStart: (_) => _barDistance = Offset.zero,
      onPanUpdate: (details) {
        final distance = _barDistance;
        if (distance != null) _barDistance = distance + details.delta;
      },
      onPanEnd: (details) {
        final distance = _barDistance;
        _barDistance = null;
        if (distance == null || distance.dy.abs() <= distance.dx.abs()) return;
        if (_swipeDirection(distance.dy, details.velocity.pixelsPerSecond.dy) <
            0) {
          _openOrExpandTab(index);
        }
      },
      onPanCancel: () => _barDistance = null,
      child: child,
    ),
  );

  void _cancelPan() {
    _panStart = null;
    _readerDragDistance = 0;
    _readerStartHeight = null;
    _scrollDrag?.cancel();
    _scrollDrag = null;
    if (mounted && _dragHeight != null) setState(() => _dragHeight = null);
  }

  Widget _panelGesture(double fitted, double maximum, Widget child) => Listener(
    // Flutter also ends accepted drags on a raw pointer cancellation.
    onPointerCancel: (_) => _cancelPan(),
    onPointerMove: (event) {
      _panelPan?.admit(event, vertical: !_expanded);
    },
    child: RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _WorkPanelPan: GestureRecognizerFactoryWithHandlers<_WorkPanelPan>(
          () => _WorkPanelPan(debugOwner: this),
          (instance) {
            _panelPan = instance;
            instance
              ..gestureSettings = MediaQuery.gestureSettingsOf(context)
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = (details) {
                _panStart = details;
                _panDistance = Offset.zero;
                _panAxis = null;
                _resizing = false;
              }
              ..onUpdate = (details) {
                if (_panStart == null) return;
                _panDistance += details.delta;
                if (_panAxis == null && _panDistance == Offset.zero) return;
                if (_panAxis == null) {
                  _panAxis = _panDistance.dx.abs() > _panDistance.dy.abs()
                      ? Axis.horizontal
                      : Axis.vertical;
                  final rows = _rowScroll[_selected]!;
                  _resizing =
                      _panAxis == Axis.vertical &&
                      (!_expanded ||
                          (details.delta.dy > 0 && rows.position.pixels <= 0));
                  if (!_resizing) {
                    final position = _panAxis == Axis.horizontal
                        ? _pages.position
                        : rows.position;
                    _scrollDrag = position.drag(
                      _panStart!,
                      () => _scrollDrag = null,
                    );
                  }
                }
                // A downward row drag hands back to the sheet when it reaches the top.
                if (_panAxis == Axis.vertical &&
                    !_resizing &&
                    details.delta.dy > 0 &&
                    _rowScroll[_selected]!.position.pixels <= 0) {
                  _scrollDrag?.cancel();
                  _scrollDrag = null;
                  _resizing = true;
                  _panDistance = Offset(0, details.delta.dy);
                }
                if (_resizing) {
                  setState(() {
                    _instantHeight = false;
                    _dragHeight = ((_dragHeight ?? fitted) - details.delta.dy)
                        .clamp(_handleHeight, maximum);
                  });
                } else {
                  final horizontal = _panAxis == Axis.horizontal;
                  _scrollDrag?.update(
                    DragUpdateDetails(
                      sourceTimeStamp: details.sourceTimeStamp,
                      delta: horizontal
                          ? Offset(details.delta.dx, 0)
                          : Offset(0, details.delta.dy),
                      primaryDelta: horizontal
                          ? details.delta.dx
                          : details.delta.dy,
                      globalPosition: details.globalPosition,
                      localPosition: details.localPosition,
                    ),
                  );
                }
              }
              ..onEnd = (details) {
                if (_panStart == null) return;
                _panStart = null;
                if (!_resizing) {
                  final horizontal = _panAxis == Axis.horizontal;
                  final velocity = horizontal
                      ? details.velocity.pixelsPerSecond.dx
                      : details.velocity.pixelsPerSecond.dy;
                  _scrollDrag?.end(
                    DragEndDetails(
                      velocity: Velocity(
                        pixelsPerSecond: horizontal
                            ? Offset(velocity, 0)
                            : Offset(0, velocity),
                      ),
                      primaryVelocity: velocity,
                    ),
                  );
                  _scrollDrag = null;
                  return;
                }
                _settleResize(
                  _panDistance.dy,
                  details.velocity.pixelsPerSecond.dy,
                );
              }
              ..onCancel = _cancelPan;
          },
        ),
      },
      // This coordinator admits the dominant axis once; the inner viewports
      // retain scrolling/semantics/physics without racing pointer recognizers.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(
          context,
        ).copyWith(dragDevices: const {}),
        child: child,
      ),
    ),
  );

  void _settleResize(double distance, double velocity) {
    final direction = _swipeDirection(distance, velocity);
    if (direction > 0) {
      _close();
    } else {
      setState(() {
        if (direction < 0) _expanded = true;
        _dragHeight = null;
      });
    }
  }

  bool _readerScroll(
    ScrollNotification notification,
    double fitted,
    double maximum,
  ) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _readerDragDistance = 0;
      _readerStartHeight = null;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        notification.overscroll < 0) {
      _readerStartHeight ??= fitted;
      _readerDragDistance -= notification.overscroll;
      setState(() {
        _instantHeight = false;
        _dragHeight = (_readerStartHeight! - _readerDragDistance).clamp(
          _handleHeight,
          maximum,
        );
      });
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        _readerDragDistance > 0 &&
        (notification.scrollDelta ?? 0) > 0) {
      _readerDragDistance = math.max(
        0,
        _readerDragDistance - notification.scrollDelta!,
      );
      setState(
        () => _dragHeight = _readerDragDistance == 0
            ? null
            : (_readerStartHeight! - _readerDragDistance).clamp(
                _handleHeight,
                maximum,
              ),
      );
    } else if (notification is ScrollEndNotification &&
        _readerDragDistance > 0) {
      final distance = _readerDragDistance;
      _readerDragDistance = 0;
      _readerStartHeight = null;
      _settleResize(distance, notification.dragDetails?.primaryVelocity ?? 0);
    }
    return false;
  }

  Widget _handle() {
    final label = _expanded ? 'Collapse drawer' : 'Expand drawer';
    void toggle({bool keyboard = false}) => setState(() {
      _instantHeight = keyboard;
      _dragHeight = null;
      _expanded = !_expanded;
    });
    return Semantics(
      button: true,
      label: label,
      onIncrease: _expanded ? null : toggle,
      onDecrease: _expanded ? toggle : null,
      child: Tooltip(
        message: label,
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              _close(keyboard: true);
              return KeyEventResult.handled;
            }
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.space)) {
              toggle(keyboard: true);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: StudioButtonPress(
            child: TextButton(
              key: const ValueKey('live-work-handle'),
              onPressed: toggle,
              style: TextButton.styleFrom(
                minimumSize: const Size(double.infinity, _handleHeight),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: EdgeInsets.zero,
                shape: const RoundedRectangleBorder(),
              ),
              child: ExcludeSemantics(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    ++_generation;
    _panStart = null;
    _barDistance = null;
    _scrollDrag?.cancel();
    for (final controller in _rowScroll.values) {
      controller.dispose();
    }
    _pages.dispose();
    _closedBarScroll.dispose();
    _openBarScroll.dispose();
    _reveal.dispose();
    _split.dispose();
    super.dispose();
  }

  Map<int, double> _shares(List<int> tabs) {
    final split = Curves.easeOutCubic.transform(_split.value);
    return {
      for (final id in tabs)
        id: (_fromShares[id] ?? 0) * (1 - split) + split / tabs.length,
    };
  }

  double _barContentWidth(double width) {
    final minTabWidth = MediaQuery.textScalerOf(context).scale(11) * 6 + 40;
    return _tabs.length > 2
        ? math.max(width, _tabs.length * minTabWidth)
        : width;
  }

  void _revealBarTab(int id) {
    final box = _target.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final width = box.size.width;
    final contentWidth = _barContentWidth(width);
    final offset =
        ((_tabs.indexOf(id) + 1) * contentWidth / _tabs.length - width)
            .clamp(0.0, math.max(0.0, contentWidth - width))
            .toDouble();
    if (_openBarScroll.hasClients) {
      _openBarScroll.jumpTo(offset);
    } else {
      _openBarScroll.dispose();
      _openBarScroll = ScrollController(initialScrollOffset: offset);
    }
  }

  Widget _bar(double width, double height, {required bool overlay}) {
    // Three enlarged labels scroll horizontally rather than growing another
    // row above the draft or overriding the user's text-size preference.
    final contentWidth = _barContentWidth(width);
    final bar = AnimatedBuilder(
      animation: _split,
      builder: (_, _) => _buildBar(contentWidth, height, overlay: overlay),
    );
    return contentWidth > width
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            controller: overlay ? _openBarScroll : _closedBarScroll,
            child: bar,
          )
        : bar;
  }

  Widget _buildBar(double width, double height, {required bool overlay}) {
    final tokens = WingTokens.of(context);
    final large =
        MediaQuery.textScalerOf(context).scale(12) > 16 || _tabs.length > 2;
    final labels = [
      widget.subagentCount == null
          ? 'Subagents'
          : '${widget.subagentCount} subagents',
      widget.taskCount == null
          ? 'Tasks'
          : 'Tasks ${widget.completedTasks}/${widget.taskCount}',
      (widget.processCount ?? 0) > 0
          ? 'Background ${widget.processCount}'
          : 'Background',
    ];
    final tabs = _tabs;
    final shares = _shares(tabs);
    final widths = {for (final id in tabs) id: width * shares[id]!};
    double leftOf(int page) =>
        tabs.take(page).fold(0.0, (sum, id) => sum + widths[id]!);
    return Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent || !_open) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          _close(keyboard: true);
          return KeyEventResult.handled;
        }
        final direction = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowLeft => -1,
          LogicalKeyboardKey.arrowRight => 1,
          _ => null,
        };
        if (direction == null) return KeyEventResult.ignored;
        final page = (tabs.indexOf(_selected) + direction).clamp(
          0,
          tabs.length - 1,
        );
        if (_selected != tabs[page]) _select(tabs[page], keyboard: true);
        return KeyEventResult.handled;
      },
      child: SizedBox(
        width: width,
        height: height + 12,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  border: Border(
                    top: BorderSide(color: tokens.border),
                    left: BorderSide(color: tokens.border),
                    right: BorderSide(color: tokens.border),
                  ),
                  borderRadius: overlay
                      ? null
                      : const BorderRadius.vertical(top: Radius.circular(8)),
                ),
              ),
            ),
            if (_open && overlay)
              AnimatedBuilder(
                animation: _pages,
                builder: (_, _) {
                  final progress = _pagePosition;
                  final from = progress.floor(), to = progress.ceil();
                  final fraction = progress - from;
                  final left =
                      leftOf(from) + (leftOf(to) - leftOf(from)) * fraction;
                  final selectedWidth =
                      widths[tabs[from]]! +
                      (widths[tabs[to]]! - widths[tabs[from]]!) * fraction;
                  return Positioned(
                    left: 3 + left,
                    bottom: 3,
                    width: math.max(0, selectedWidth - 6),
                    height: height - 6,
                    child: DecoratedBox(
                      key: const ValueKey('live-work-selection'),
                      decoration: BoxDecoration(
                        color: tokens.accent.withValues(alpha: .13),
                        border: Border.all(
                          color: tokens.accent.withValues(alpha: .35),
                        ),
                        borderRadius: WingRadius.control,
                      ),
                    ),
                  );
                },
              ),
            if (!_open)
              for (var page = 1; page < tabs.length; page++)
                Positioned(
                  left: leftOf(page),
                  bottom: (height - 16) / 2,
                  child: Container(
                    key: ValueKey(
                      page == 1
                          ? 'live-work-divider'
                          : 'live-work-divider-$page',
                    ),
                    width: 1,
                    height: 16,
                    color: Color.lerp(tokens.border, tokens.muted, .4),
                  ),
                ),
            Positioned.fill(
              child: Row(
                children: [
                  for (final index in tabs)
                    SizedBox(
                      key: ValueKey(('live-work-tab-slot', index, overlay)),
                      width: widths[index]!,
                      child: _tabGesture(
                        index,
                        ClipRect(
                          child: OverflowBox(
                            alignment: index == 0
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            minHeight: height + 12,
                            maxHeight: height + 12,
                            minWidth: math.min(
                              width / tabs.length,
                              widths[index]!,
                            ),
                            maxWidth: math.max(
                              width / tabs.length,
                              widths[index]!,
                            ),
                            child: Opacity(
                              opacity: (shares[index]! * tabs.length).clamp(
                                0.0,
                                1.0,
                              ),
                              child: Semantics(
                                button: true,
                                expanded: _open && _selected == index,
                                label: labels[index],
                                child: StudioButtonPress(
                                  child: TextButton(
                                    key: ValueKey((
                                      'live-work-tab',
                                      index,
                                      overlay,
                                    )),
                                    onPressed: () => _select(index),
                                    style: TextButton.styleFrom(
                                      minimumSize: Size.zero,
                                      padding: const EdgeInsets.fromLTRB(
                                        8,
                                        12,
                                        8,
                                        0,
                                      ),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      foregroundColor:
                                          _open && _selected == index
                                          ? tokens.accent
                                          : tokens.muted,
                                      shape: const RoundedRectangleBorder(),
                                    ),
                                    child: Row(
                                      children: [
                                        if (!large) ...[
                                          SizedBox.square(
                                            dimension: 16,
                                            child: _refreshing.contains(index)
                                                ? CircularProgressIndicator(
                                                    strokeWidth: 1.5,
                                                    semanticsLabel: index == 0
                                                        ? 'Refreshing subagents'
                                                        : 'Refreshing background processes',
                                                  )
                                                : Icon(switch (index) {
                                                    0 => Icons.people_outline,
                                                    1 => Icons.checklist,
                                                    _ => Icons.terminal_rounded,
                                                  }, size: 16),
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        Expanded(
                                          child: Text(
                                            labels[index],
                                            maxLines: 2,
                                            style: TextStyle(
                                              fontSize: large ? 11 : 12,
                                              height: 1.1,
                                              fontWeight: FontWeight.w400,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        if (large &&
                                            _refreshing.contains(index))
                                          SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.5,
                                              semanticsLabel: index == 0
                                                  ? 'Refreshing subagents'
                                                  : 'Refreshing background processes',
                                            ),
                                          )
                                        else
                                          Icon(
                                            _open && _selected == index
                                                ? Icons
                                                      .keyboard_arrow_down_rounded
                                                : Icons
                                                      .keyboard_arrow_up_rounded,
                                            size: 16,
                                          ),
                                      ],
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final height = math.max(
        36.0,
        MediaQuery.textScalerOf(context).scale(12) * 3,
      );
      if (_tabs.isEmpty) return const SizedBox.shrink();
      return OverlayPortal(
        controller: _portal,
        // Measure the anchor during overlay layout, after the composer has
        // moved for an IME inset. Build-time coordinates lag by one layout.
        overlayChildBuilder: (context) => LayoutBuilder(
          builder: (context, _) {
            final box =
                _target.currentContext!.findRenderObject()! as RenderBox;
            final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
            final query = MediaQuery.of(context);
            final available = math.max(
              48.0,
              bottom - height - query.padding.top - 8,
            );
            final panelHeight = math.min(
              available,
              math.min(320.0, query.size.height * .4),
            );
            return Stack(
              children: [
                Positioned.fill(
                  child: ModalBarrier(
                    color: Colors.black.withValues(alpha: .54),
                    dismissible: true,
                    onDismiss: _close,
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  child: CompositedTransformFollower(
                    link: _link,
                    targetAnchor: Alignment.bottomLeft,
                    followerAnchor: Alignment.bottomLeft,
                    showWhenUnlinked: false,
                    child: SizedBox(
                      width: width,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedBuilder(
                            animation: Listenable.merge([_pages, _reveal]),
                            builder: (context, _) {
                              final tabs = _tabs;
                              final position = _pagePosition;
                              final from = position.floor();
                              final to = position.ceil();
                              double pageHeight(int page) => math.min(
                                panelHeight,
                                (_contentHeights[tabs[page]] ?? panelHeight) +
                                    _handleHeight,
                              );
                              final compact =
                                  pageHeight(from) +
                                  (pageHeight(to) - pageHeight(from)) *
                                      (position - from);
                              final fitted =
                                  (_dragHeight ??
                                          (_expanded ? available : compact))
                                      .clamp(_handleHeight, available);
                              final scrolling =
                                  _pages.hasClients &&
                                  _pages.position.isScrollingNotifier.value;
                              final ready = _contentHeights.containsKey(
                                tabs[from],
                              );
                              return ClipRect(
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  heightFactor: Curves.easeOutCubic.transform(
                                    _reveal.value,
                                  ),
                                  child: AnimatedContainer(
                                    key: const ValueKey('live-work-panel'),
                                    duration:
                                        _reduced ||
                                            _instantHeight ||
                                            _dragHeight != null ||
                                            scrolling ||
                                            !ready
                                        ? Duration.zero
                                        : ProfileLiveWorkDock.slideDuration,
                                    curve: Curves.easeOutCubic,
                                    height: fitted,
                                    child: Opacity(
                                      opacity: ready ? 1 : 0,
                                      child: _panelGesture(
                                        fitted,
                                        available,
                                        Material(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerLow,
                                          shape: RoundedRectangleBorder(
                                            side: BorderSide(
                                              color: WingTokens.of(
                                                context,
                                              ).border,
                                            ),
                                            borderRadius: WingRadius.sheet,
                                          ),
                                          child: ClipRRect(
                                            borderRadius: WingRadius.sheet,
                                            child: Column(
                                              children: [
                                                _handle(),
                                                Expanded(
                                                  child: PageView(
                                                    controller: _pages,
                                                    pageSnapping: false,
                                                    allowImplicitScrolling:
                                                        true,
                                                    physics: _WorkPagePhysics(
                                                      reducedMotion: _reduced,
                                                    ),
                                                    onPageChanged: (page) {
                                                      final id = _tabs[page];
                                                      if (!_openingPages &&
                                                          _selected != id) {
                                                        setState(
                                                          () => _selected = id,
                                                        );
                                                        _revealBarTab(id);
                                                        _refreshTab(id);
                                                      }
                                                    },
                                                    children: [
                                                      for (final id in tabs)
                                                        _WorkPage(
                                                          key: ValueKey((
                                                            'live-work-page',
                                                            id,
                                                          )),
                                                          scrollController:
                                                              _rowScroll[id]!,
                                                          onHeight: (value) =>
                                                              _measureContent(
                                                                id,
                                                                value,
                                                              ),
                                                          summary: switch (id) {
                                                            0 =>
                                                              widget
                                                                  .subagentSummary,
                                                            1 =>
                                                              widget
                                                                  .taskSummary,
                                                            _ =>
                                                              widget
                                                                  .processSummary!,
                                                          },
                                                          child: NotificationListener<ScrollNotification>(
                                                            onNotification:
                                                                (
                                                                  notification,
                                                                ) => _readerScroll(
                                                                  notification,
                                                                  fitted,
                                                                  available,
                                                                ),
                                                            child: ScrollConfiguration(
                                                              // Nested source readers keep their own scrolling
                                                              // once the panel has reached full height.
                                                              behavior:
                                                                  _expanded
                                                                  ? ScrollConfiguration.of(
                                                                      context,
                                                                    )
                                                                  : ScrollConfiguration.of(
                                                                      context,
                                                                    ).copyWith(
                                                                      dragDevices:
                                                                          const {},
                                                                    ),
                                                              child: switch (id) {
                                                                0 =>
                                                                  widget
                                                                      .subagents,
                                                                1 =>
                                                                  widget.tasks,
                                                                _ =>
                                                                  widget
                                                                      .processes!,
                                                              },
                                                            ),
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          // The 12dp hit-target extension overlaps the panel;
                          // only the visible bar sits below its bottom edge.
                          SizedBox(
                            height: height,
                            child: OverflowBox(
                              alignment: Alignment.bottomCenter,
                              minHeight: height + 12,
                              maxHeight: height + 12,
                              child: _bar(width, height, overlay: true),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        child: CompositedTransformTarget(
          key: _target,
          link: _link,
          child: ExcludeSemantics(
            excluding: _portal.isShowing,
            child: _bar(width, height, overlay: false),
          ),
        ),
      );
    },
  );
}

/// Admit compact-sheet drags before text's tap-and-pan selection recognizer
/// claims movement. A settled long press has already rejected this recognizer,
/// and expanded nested readers retain their native scrolling gestures.
class _WorkPanelPan extends PanGestureRecognizer {
  _WorkPanelPan({super.debugOwner});
  int? _pointer;
  Offset? _origin;
  bool _canAdmit = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _origin = event.position;
    _canAdmit = true;
    super.addAllowedPointer(event);
  }

  void admit(PointerMoveEvent event, {required bool vertical}) {
    if (!_canAdmit || event.pointer != _pointer || _origin == null) return;
    final distance = event.position - _origin!;
    final slop = gestureSettings?.touchSlop ?? kTouchSlop;
    if (distance.distance <= slop ||
        (!vertical && distance.dy.abs() >= distance.dx.abs())) {
      return;
    }
    _canAdmit = false;
    resolve(GestureDisposition.accepted);
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == _pointer) _canAdmit = false;
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
    _origin = null;
    _canAdmit = false;
    super.didStopTrackingLastPointer(pointer);
  }
}

class _WorkPage extends StatefulWidget {
  const _WorkPage({
    super.key,
    required this.child,
    required this.summary,
    required this.onHeight,
    required this.scrollController,
  });
  final ScrollController scrollController;
  final Widget child;
  final Widget summary;
  final ValueChanged<double> onHeight;
  @override
  State<_WorkPage> createState() => _WorkPageState();
}

class _WorkPageState extends State<_WorkPage>
    with AutomaticKeepAliveClientMixin {
  double _headerHeight = 0, _bodyHeight = 0;

  void _measure({double? header, double? body}) {
    _headerHeight = header ?? _headerHeight;
    _bodyHeight = body ?? _bodyHeight;
    widget.onHeight(_headerHeight + _bodyHeight);
  }

  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return CustomMultiChildLayout(
      delegate: _WorkPageLayout(),
      children: [
        LayoutId(
          id: 0,
          child: _WorkContentSize(
            onHeight: (height) => _measure(header: height),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                child: widget.summary,
              ),
            ),
          ),
        ),
        LayoutId(
          id: 1,
          child: SingleChildScrollView(
            controller: widget.scrollController,
            child: _WorkContentSize(
              onHeight: (height) => _measure(body: height),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Kept-alive neighbors may have a taller summary than the selected short page.
/// Lay out that summary naturally and clip it during page-height interpolation.
class _WorkPageLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final header = layoutChild(0, BoxConstraints.tightFor(width: size.width));
    positionChild(0, Offset.zero);
    layoutChild(
      1,
      BoxConstraints.tight(
        Size(size.width, math.max(0, size.height - header.height)),
      ),
    );
    positionChild(1, Offset(0, header.height));
  }

  @override
  bool shouldRelayout(_WorkPageLayout oldDelegate) => false;
}

/// Measure real laid-out content, including text wrapping, without a duplicate
/// tree or intrinsic passes through the borrowed panels.
class _WorkContentSize extends SingleChildRenderObjectWidget {
  const _WorkContentSize({required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _WorkContentSizeBox(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _WorkContentSizeBox renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _WorkContentSizeBox extends RenderProxyBox {
  _WorkContentSizeBox(this.onHeight);
  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (_reported == size.height) return;
    _reported = size.height;
    final height = size.height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached && _reported == height) onHeight(height);
    });
  }
}

class _WorkPagePhysics extends PageScrollPhysics {
  const _WorkPagePhysics({required this.reducedMotion, super.parent});
  final bool reducedMotion;
  @override
  _WorkPagePhysics applyTo(ScrollPhysics? ancestor) => _WorkPagePhysics(
    reducedMotion: reducedMotion,
    parent: buildParent(ancestor),
  );
  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final width = position.viewportDimension;
    if (width == 0) return null;
    var page = position.pixels / width;
    if (velocity < -toleranceFor(position).velocity) page -= .5;
    if (velocity > toleranceFor(position).velocity) page += .5;
    final target = (page.round() * width).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < .01) return null;
    return _WorkPageSimulation(
      position.pixels,
      target,
      reducedMotion
          ? 0
          : ProfileLiveWorkDock.slideDuration.inMicroseconds / 1000000,
    );
  }
}

class _WorkPageSimulation extends Simulation {
  _WorkPageSimulation(this.start, this.end, this.duration);
  final double start, end, duration;
  @override
  double x(double time) => duration == 0
      ? end
      : start +
            (end - start) *
                const _WorkPageCurve().transform(
                  (time / duration).clamp(0.0, 1.0),
                );
  @override
  double dx(double time) => duration == 0 || time >= duration
      ? 0
      : (end - start) * 3 * math.pow(1 - time / duration, 2) / duration;
  @override
  bool isDone(double time) => time >= duration;
}

class _WorkPageCurve extends Curve {
  const _WorkPageCurve();
  @override
  double transformInternal(double t) => 1 - math.pow(1 - t, 3).toDouble();
}
