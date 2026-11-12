part of 'skill_document_viewer.dart';

/// Equal section travel and finger tracking, independent of document length.
class _SkillReaderNavigation extends StatefulWidget {
  const _SkillReaderNavigation({
    required this.scroll,
    required this.headings,
    required this.trigger,
    required this.child,
  });
  final ScrollController scroll;
  final List<MarkdownHeadingAnchor> headings;
  final GlobalKey trigger;
  final Widget child;
  @override
  State<_SkillReaderNavigation> createState() => _SkillReaderNavigationState();
}

class _SkillReaderNavigationState extends State<_SkillReaderNavigation>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _box = GlobalKey();
  late final AnimationController _settle;
  Timer? _hold;
  int? _pointer;
  double _pressY = 0,
      _lastY = 0,
      _railTop = 0,
      _railHeight = 1,
      _bodyHeight = 0;
  double? _fingerY;
  bool _held = false, _moved = false;
  int _candidate = 0;
  ({double start, double end, double from, double to})? _handoff;
  ({double from, double to})? _settling;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    )..addListener(_changed);
    widget.scroll.addListener(_changed);
  }

  @override
  void didUpdateWidget(_SkillReaderNavigation old) {
    super.didUpdateWidget(old);
    if (old.scroll != widget.scroll) {
      old.scroll.removeListener(_changed);
      widget.scroll.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hold?.cancel();
    _settle.dispose();
    widget.scroll.removeListener(_changed);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _hold?.cancel();
    _hold = null;
    _pointer = null;
    setState(() {
      _held = false;
      _fingerY = null;
    });
  }

  List<double> _positions() => [
    for (final heading in widget.headings)
      if (heading.key.currentContext case final target?) _offset(target) else 0,
  ];
  double _offset(BuildContext target) {
    final render =
        target.findAncestorRenderObjectOfType<RenderWrap>() ??
        target.findRenderObject();
    if (render == null || !widget.scroll.hasClients) return 0;
    return RenderAbstractViewport.of(render)
        .getOffsetToReveal(render, 0)
        .offset
        .clamp(0, widget.scroll.position.maxScrollExtent);
  }

  int get _active {
    final positions = _positions(),
        pixels = widget.scroll.hasClients ? widget.scroll.offset : 0;
    var result = 0;
    for (var i = 0; i < positions.length; i++) {
      if (pixels + 24 >= positions[i]) result = i;
    }
    return result;
  }

  double _normalY(double pixels) {
    if (!widget.scroll.hasClients || widget.headings.isEmpty) return _railTop;
    final positions = _positions();
    var index = 0;
    for (var i = 0; i < positions.length; i++) {
      if (pixels >= positions[i]) index = i;
    }
    final end = index + 1 < positions.length
        ? positions[index + 1]
        : widget.scroll.position.maxScrollExtent;
    final fraction =
        ((pixels - positions[index]) / math.max(1, end - positions[index]))
            .clamp(0.0, 1.0);
    return _railTop + (index + fraction) * _railHeight / positions.length;
  }

  double get _restY {
    final pixels = widget.scroll.hasClients ? widget.scroll.offset : 0.0;
    if (_handoff case final handoff?) {
      final progress =
          ((pixels - handoff.start) / (handoff.end - handoff.start)).clamp(
            0.0,
            1.0,
          );
      return handoff.from + (handoff.to - handoff.from) * progress;
    }
    if (_settling case final settling? when _settle.isAnimating) {
      return settling.from +
          (settling.to - settling.from) *
              Curves.easeOutCubic.transform(_settle.value);
    }
    return _normalY(pixels);
  }

  void _jump(int index, {bool fromGrip = false, bool keyboard = false}) {
    if (!widget.scroll.hasClients) return;
    final target = _positions()[index.clamp(0, widget.headings.length - 1)];
    final reduced = MediaQuery.disableAnimationsOf(context) || keyboard;
    if (fromGrip && !reduced && _fingerY != null) {
      if ((target - widget.scroll.offset).abs() > .5) {
        _handoff = (
          start: widget.scroll.offset,
          end: target,
          from: _fingerY!,
          to: _normalY(target),
        );
      } else {
        _settling = (from: _fingerY!, to: _normalY(target));
        _settle.forward(from: 0);
      }
    } else {
      _handoff = null;
      _settling = null;
    }
    if (reduced) {
      widget.scroll.jumpTo(target);
      _handoff = null;
    } else {
      unawaited(
        widget.scroll
            .animateTo(
              target,
              duration: const Duration(milliseconds: 250),
              curve: WingMotion.curve,
            )
            .whenComplete(() {
              if (mounted) setState(() => _handoff = null);
            }),
      );
    }
  }

  double _localY(PointerEvent event) =>
      (_box.currentContext!.findRenderObject()! as RenderBox)
          .globalToLocal(event.position)
          .dy;
  void _down(PointerDownEvent event) {
    if (_pointer != null || event.buttons != 1) return;
    _settle.stop();
    _handoff = null;
    _settling = null;
    if (widget.scroll.hasClients) widget.scroll.jumpTo(widget.scroll.offset);
    _pointer = event.pointer;
    _pressY = _lastY = _localY(event);
    _moved = false;
    _held = false;
    _hold = Timer(const Duration(milliseconds: 250), _activate);
  }

  void _activate() {
    if (!mounted || _pointer == null) return;
    _hold?.cancel();
    _hold = null;
    _held = true;
    _preview(_lastY);
  }

  void _preview(double y) {
    _candidate = ((y - _railTop) / _railHeight * widget.headings.length)
        .floor()
        .clamp(0, widget.headings.length - 1);
    setState(() => _fingerY = y.clamp(38.0, math.max(38, _bodyHeight - 100)));
  }

  void _move(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    _lastY = _localY(event);
    _moved |= (_lastY - _pressY).abs() > 6;
    if (_held) {
      _preview(_lastY);
    } else if ((_lastY - _pressY).abs() >= 12) {
      _activate();
    }
  }

  void _end(PointerEvent event) {
    if (_pointer != event.pointer) return;
    _hold?.cancel();
    _hold = null;
    _pointer = null;
    if (event is PointerUpEvent && _held && _moved) {
      _jump(_candidate, fromGrip: true);
    }
    setState(() {
      _held = false;
      _fingerY = null;
    });
  }

  Future<void> _contents() async {
    final active = _active,
        keys = List.generate(widget.headings.length, (_) => GlobalKey());
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      backgroundColor: WingTokens.of(context).raised,
      shape: const RoundedRectangleBorder(borderRadius: WingRadius.sheet),
      builder: (sheet) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = keys[active].currentContext;
          if (target != null) Scrollable.ensureVisible(target, alignment: .5);
        });
        return LayoutBuilder(
          builder: (sheet, constraints) {
            final style = WingTokens.of(sheet).typography.body;
            final scaler = MediaQuery.textScalerOf(sheet);
            final labelWidth = math.max(1.0, constraints.maxWidth - 64);
            var rowHeight = 48.0;
            for (final heading in widget.headings) {
              final label = TextPainter(
                text: TextSpan(text: heading.label, style: style),
                textDirection: Directionality.of(sheet),
                textScaler: scaler,
                maxLines: 2,
                ellipsis: '…',
              )..layout(maxWidth: labelWidth);
              rowHeight = math.max(rowHeight, label.height + 24);
              label.dispose();
            }
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: () => Navigator.pop(sheet),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Contents',
                              style: WingTokens.of(sheet).typography.section,
                            ),
                          ),
                          ActivityDetailAction(
                            label: 'Close contents',
                            icon: Icons.close,
                            onPressed: () => Navigator.pop(sheet),
                          ),
                        ],
                      ),
                    ),
                    const _SkillRule(),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight:
                              rowHeight * math.min(5, widget.headings.length) +
                              16,
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            children: [
                              for (var i = 0; i < widget.headings.length; i++)
                                SizedBox(
                                  height: rowHeight,
                                  child: Material(
                                    key: keys[i],
                                    color: i == active
                                        ? Theme.of(
                                            sheet,
                                          ).colorScheme.primaryContainer
                                        : Colors.transparent,
                                    borderRadius: WingRadius.control,
                                    child: StudioButtonPress(
                                      child: InkWell(
                                        borderRadius: WingRadius.control,
                                        onTap: () {
                                          Navigator.pop(sheet);
                                          _jump(i);
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              SizedBox(
                                                width: 24,
                                                child: Text(
                                                  (i + 1).toString(),
                                                  style: WingTokens.of(sheet)
                                                      .typography
                                                      .label
                                                      .copyWith(
                                                        color: WingTokens.of(
                                                          sheet,
                                                        ).muted,
                                                      ),
                                                ),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  widget.headings[i].label,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: style,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final index = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => _active - 1,
      LogicalKeyboardKey.arrowDown => _active + 1,
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => widget.headings.length - 1,
      _ => null,
    };
    if (index == null) return KeyEventResult.ignored;
    _jump(index, keyboard: true);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final reading = Positioned.fill(
        child: NotificationListener<ScrollStartNotification>(
          onNotification: (notice) {
            if (notice.dragDetails != null) {
              _handoff = null;
              _settle.stop();
            }
            return false;
          },
          child: widget.child,
        ),
      );
      if (widget.headings.length < 2) {
        return Stack(key: _box, children: [reading]);
      }
      final colors = WingTokens.of(context),
          active = _active,
          count = widget.headings.length;
      _bodyHeight = box.maxHeight;
      final media = MediaQuery.of(context);
      _railTop = math.max(
        88,
        media.size.height * .2 + 64 - media.viewPadding.top - kToolbarHeight,
      );
      final trigger = widget.trigger.currentContext?.findRenderObject();
      final origin = _box.currentContext?.findRenderObject();
      if (trigger is RenderBox && origin is RenderBox && trigger.hasSize) {
        final bottom =
            trigger.localToGlobal(Offset(0, trigger.size.height)).dy -
            origin.localToGlobal(Offset.zero).dy +
            widget.scroll.offset;
        _railTop = math.max(
          _railTop,
          math.min(bottom + 32, box.maxHeight - 184),
        );
      }
      _railHeight = math.max(
        80,
        math.min(
          math.min(media.size.height * .48, 460),
          box.maxHeight - _railTop - 104,
        ),
      );
      final y = (_fingerY ?? _restY).clamp(
        30.0,
        math.max(30, box.maxHeight - 90),
      );
      Widget arrow(IconData icon, String label, VoidCallback? command) =>
          SizedBox(
            width: 44,
            height: 48,
            child: StudioButtonPress(
              child: IconButton(
                tooltip: label,
                icon: Icon(icon, size: 18),
                onPressed: command,
              ),
            ),
          );
      return Stack(
        key: _box,
        children: [
          reading,
          Positioned(
            top: _railTop,
            right: 32,
            width: 8,
            height: _railHeight,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _held ? 1 : 0,
                duration: media.disableAnimations
                    ? Duration.zero
                    : const Duration(milliseconds: 140),
                child: Column(
                  children: [
                    for (var i = 0; i < count; i++)
                      Expanded(
                        child: Center(
                          child: Container(
                            width: _held && i == _candidate ? 8 : 4,
                            height: _held && i == _candidate
                                ? 24
                                : i == active
                                ? 20
                                : 8,
                            decoration: BoxDecoration(
                              color: i == (_held ? _candidate : active)
                                  ? colors.accent
                                  : colors.muted.withValues(alpha: .65),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_held)
            Positioned(
              top: (y - 20).clamp(8.0, box.maxHeight - 100).toDouble(),
              right: 68,
              width: math.min(280.0, box.maxWidth - 80),
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    border: Border.all(color: colors.border),
                    borderRadius: WingRadius.card,
                  ),
                  child: Text(
                    '${_candidate + 1} · ${widget.headings[_candidate].label}',
                    style: colors.typography.label.copyWith(fontSize: 14),
                  ),
                ),
              ),
            ),
          Positioned(
            top: y - 30,
            right: 4,
            width: 64,
            height: 60,
            child: Focus(
              onKeyEvent: _key,
              child: Semantics(
                label: 'Browse sections',
                value:
                    '${active + 1} of $count. ${widget.headings[active].label}',
                increasedValue: active < count - 1
                    ? '${active + 2} of $count. ${widget.headings[active + 1].label}'
                    : null,
                decreasedValue: active > 0
                    ? '$active of $count. ${widget.headings[active - 1].label}'
                    : null,
                onIncrease: active < count - 1
                    ? () => _jump(active + 1, keyboard: true)
                    : null,
                onDecrease: active > 0
                    ? () => _jump(active - 1, keyboard: true)
                    : null,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerUp: _end,
                  onPointerCancel: _end,
                  child: Center(
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _held
                            ? colors.onSurface
                            : colors.accent.withValues(alpha: .28),
                        border: Border.all(
                          color: _held
                              ? colors.onSurface
                              : colors.accent.withValues(alpha: .55),
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          if (_held)
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .2),
                              offset: const Offset(0, 3),
                              blurRadius: 12,
                            ),
                        ],
                      ),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 20,
                        color: _held ? colors.surface : colors.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 0,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 8),
              child: Container(
                decoration: BoxDecoration(
                  color: colors.raised,
                  border: Border.all(color: colors.border),
                  borderRadius: WingRadius.card,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .15),
                      offset: const Offset(0, 3),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    arrow(
                      Icons.chevron_left,
                      'Previous section',
                      active == 0 ? null : () => _jump(active - 1),
                    ),
                    Expanded(
                      child: StudioButtonPress(
                        child: InkWell(
                          onTap: _contents,
                          borderRadius: WingRadius.control,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 4,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.format_list_numbered,
                                  size: 16,
                                  color: colors.muted,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.headings[active].label,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: colors.typography.label,
                                      ),
                                      Text(
                                        '${active + 1} / $count',
                                        style: colors.typography.label.copyWith(
                                          fontSize: 11,
                                          color: colors.muted,
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
                    arrow(
                      Icons.chevron_right,
                      'Next section',
                      active == count - 1 ? null : () => _jump(active + 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
