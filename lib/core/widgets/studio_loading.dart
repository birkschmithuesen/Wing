import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';

/// Wing's three feathers keep their shape while a quiet highlight passes across.
class StudioLoading extends StatefulWidget {
  const StudioLoading({
    super.key,
    required this.label,
    this.size = 24,
    this.color,
  });

  final String label;
  final double size;
  final Color? color;

  @override
  State<StudioLoading> createState() => _StudioLoadingState();
}

/// Static brand artwork, independent of work or loading state.
class StudioWingMark extends StatelessWidget {
  const StudioWingMark({super.key, this.size = 28});
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: _WingGlyph(
      label: 'Wing',
      size: size,
      color: Theme.of(context).colorScheme.primary,
      pulse: const AlwaysStoppedAnimation<double>(0),
      animate: false,
    ),
  );
}

/// A Wing-only mark for confirmed work. Callers render non-working states
/// separately; the conversation pulse takes priority over nested work.
class StudioWorkingIndicator extends StatefulWidget {
  const StudioWorkingIndicator({
    super.key,
    required this.label,
    required this.color,
    this.size = 18,
    this.conversation = false,
  }) : _independent = false;

  /// Separate roster/card work has its own status, not a nested conversation cue.
  const StudioWorkingIndicator.independent({
    super.key,
    required this.label,
    required this.color,
    this.size = 18,
  }) : conversation = false,
       _independent = true;
  final bool _independent;
  final bool conversation;
  final String label;
  final Color color;
  final double size;
  @override
  State<StudioWorkingIndicator> createState() => _StudioWorkingIndicatorState();
}

class _StudioWorkingIndicatorState extends State<StudioWorkingIndicator> {
  final _identity = Object();
  _LoadingPresentation? _presentation;
  void _report() {
    if (widget._independent) {
      _presentation?.work(_identity, false);
      _presentation = null;
      return;
    }
    final next = _LoadingPresentation.of(context);
    if (!identical(next, _presentation)) {
      _presentation?.work(_identity, false);
      _presentation = next;
    }
    next.work(
      _identity,
      (ModalRoute.isCurrentOf(context) ?? true) &&
          TickerMode.valuesOf(context).enabled,
      conversation: widget.conversation,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _report();
  }

  @override
  void didUpdateWidget(StudioWorkingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _report();
  }

  @override
  void dispose() {
    _presentation?.work(_identity, false);
    super.dispose();
  }

  Widget _glyph(bool selected) => SizedBox.square(
    dimension: widget.size,
    child: selected && (ModalRoute.isCurrentOf(context) ?? true)
        ? StudioLoading(
            label: widget.label,
            color: widget.color,
            size: widget.size,
          )
        : widget.conversation || widget._independent
        ? _WingGlyph(
            label: widget.label,
            size: widget.size,
            color: widget.color,
            pulse: const AlwaysStoppedAnimation<double>(0),
            animate: false,
          )
        : const SizedBox.shrink(),
  );
  @override
  Widget build(BuildContext context) => widget._independent
      ? _glyph(true)
      : ValueListenableBuilder<_LoadingState>(
          valueListenable: _presentation!,
          builder: (_, state, _) => _glyph(
            identical(state.work, _identity) &&
                !(state.headerLabel != null && state.slot != null),
          ),
        );
}

class _StudioLoadingState extends State<StudioLoading>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  bool _animate = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate =
        !MediaQuery.disableAnimationsOf(context) &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    if (_animate) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _WingGlyph(
    label: widget.label,
    size: widget.size,
    color: widget.color,
    pulse: _pulse,
    animate: _animate,
  );
}

/// Animated and covered conversation states share the exact same Wing artwork.
class _WingGlyph extends StatelessWidget {
  const _WingGlyph({
    required this.label,
    required this.size,
    required this.color,
    required this.pulse,
    required this.animate,
  });
  final String label;
  final double size;
  final Color? color;
  final Animation<double> pulse;
  final bool animate;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: label,
    child: ExcludeSemantics(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: SizedBox.square(
            dimension: size,
            child: CustomPaint(
              painter: _Feathers(
                color: color ?? Theme.of(context).colorScheme.primary,
                pulse: pulse,
                animate: animate,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Feathers extends CustomPainter {
  _Feathers({required this.color, required this.pulse, required this.animate})
    : super(repaint: animate ? pulse : null);

  final Color color;
  final Animation<double> pulse;
  final bool animate;
  // Canonical paths from assets/icon/wing.svg and Android ic_stat_wing.
  static final _shapes = [
    Path()
      ..moveTo(2.8, 17.8)
      ..cubicTo(5, 9, 17, 8, 22, 2)
      ..cubicTo(22, 9, 9, 10, 2.8, 17.8)
      ..close(),
    Path()
      ..moveTo(2.4, 20.4)
      ..cubicTo(7, 12.6, 16, 13, 20.3, 9.4)
      ..cubicTo(18.3, 16, 9, 14.8, 2.4, 20.4)
      ..close(),
    Path()
      ..moveTo(2, 22)
      ..cubicTo(6, 16.8, 12.2, 18.3, 16.3, 15.6)
      ..cubicTo(14.2, 22, 7.3, 18.8, 2, 22)
      ..close(),
  ];

  static final _mark = Path()
    ..addPath(_shapes[0], Offset.zero)
    ..addPath(_shapes[1], Offset.zero)
    ..addPath(_shapes[2], Offset.zero);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 24;
    canvas.save();
    canvas.translate(
      (size.width - 24 * scale) / 2,
      (size.height - 24 * scale) / 2,
    );
    canvas.scale(scale);
    if (!animate) {
      canvas.drawPath(_mark, Paint()..color = color);
    } else {
      for (var i = 0; i < _shapes.length; i++) {
        final opacity =
            .70 +
            .30 * (.5 - .5 * math.cos(2 * math.pi * (pulse.value - i * .145)));
        canvas.drawPath(
          _shapes[i],
          Paint()..color = color.withValues(alpha: opacity),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Feathers oldDelegate) =>
      color != oldDelegate.color || animate != oldDelegate.animate;
}

/// The presentation belongs to a page Scaffold or an explicit modal frame.
/// Weak Scaffold keys keep independent pages isolated without an app-wide ledger.
final _pagePresentations = Expando<_LoadingPresentation>();

class _LoadingState {
  const _LoadingState({this.headerLabel, this.slot, this.work});
  final String? headerLabel;
  final Object? slot, work;
}

class _LoadingPresentation extends ValueNotifier<_LoadingState> {
  _LoadingPresentation() : super(const _LoadingState());
  final _operations = <Object, String>{};
  final _slots = <Object>{};
  final _works = <Object, bool>{};
  bool _queued = false, _disposed = false;

  static _LoadingPresentation of(BuildContext context) {
    final frame = context
        .dependOnInheritedWidgetOfExactType<_LoadingFrameScope>();
    if (frame != null) return frame.presentation;
    final page = Scaffold.of(context);
    return _pagePresentations[page] ??= _LoadingPresentation();
  }

  void report(Object operation, String? label) {
    if (_disposed || _operations[operation] == label) return;
    if (label == null) {
      _operations.remove(operation);
    } else {
      _operations[operation] = label;
    }
    _publish();
  }

  void slot(Object identity, bool present) =>
      _register(_slots, identity, present);
  void work(Object identity, bool present, {bool conversation = false}) {
    if (_disposed) return;
    if (!present) {
      if (_works.remove(identity) != null) _publish();
    } else if (_works[identity] != conversation) {
      _works[identity] = conversation;
      _publish();
    }
  }

  void _register(Set<Object> entries, Object identity, bool present) {
    if (_disposed) return;
    if (present ? entries.add(identity) : entries.remove(identity)) _publish();
  }

  void _publish() {
    if (_queued) return;
    _queued = true;
    // Sibling header/body changes are published together after build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!_disposed) {
        value = _LoadingState(
          headerLabel: _operations.values.firstOrNull,
          slot: _slots.firstOrNull,
          work:
              _works.entries.where((entry) => entry.value).firstOrNull?.key ??
              _works.keys.firstOrNull,
        );
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _operations.clear();
    _slots.clear();
    _works.clear();
    super.dispose();
  }
}

/// Gives a modal or an immersive page its own loading lifetime and header slot.
class StudioLoadingFrame extends StatefulWidget {
  const StudioLoadingFrame({super.key, required this.child});
  final Widget child;
  @override
  State<StudioLoadingFrame> createState() => _StudioLoadingFrameState();
}

class _StudioLoadingFrameState extends State<StudioLoadingFrame> {
  final _presentation = _LoadingPresentation();
  @override
  void dispose() {
    _presentation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _LoadingFrameScope(
    presentation: _presentation,
    child: _LoadingScope(active: false, child: widget.child),
  );
}

class _LoadingFrameScope extends InheritedWidget {
  const _LoadingFrameScope({required this.presentation, required super.child});
  final _LoadingPresentation presentation;
  @override
  bool updateShouldNotify(_LoadingFrameScope oldWidget) =>
      presentation != oldWidget.presentation;
}

/// A fixed header compartment; its width stays reserved when the page is ready.
class StudioLoadingSlot extends StatefulWidget {
  const StudioLoadingSlot({super.key, this.height = 48});
  final double height;
  @override
  State<StudioLoadingSlot> createState() => _StudioLoadingSlotState();
}

class _StudioLoadingSlotState extends State<StudioLoadingSlot> {
  final _identity = Object();
  _LoadingPresentation? _presentation;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = _LoadingPresentation.of(context);
    if (!identical(next, _presentation)) {
      _presentation?.slot(_identity, false);
      _presentation = next;
    }
    next.slot(
      _identity,
      (ModalRoute.isCurrentOf(context) ?? true) &&
          TickerMode.valuesOf(context).enabled,
    );
  }

  @override
  void dispose() {
    _presentation?.slot(_identity, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('studio-loading-slot'),
    width: 32,
    height: widget.height,
    child: Center(
      child: ValueListenableBuilder<_LoadingState>(
        valueListenable: _presentation!,
        builder: (_, state, _) =>
            state.headerLabel == null ||
                !identical(state.slot, _identity) ||
                !(ModalRoute.isCurrentOf(context) ?? true)
            ? const SizedBox.shrink()
            : Tooltip(
                message: state.headerLabel!,
                child: StudioLoading(label: state.headerLabel!, size: 18),
              ),
      ),
    ),
  );
}

/// Reports page loading to its header without painting over or moving content.
class StudioPageLoading extends StatefulWidget {
  const StudioPageLoading({
    super.key,
    required this.active,
    required this.label,
    required this.child,
  });
  const StudioPageLoading.waiting({super.key, required this.label})
    : active = true,
      child = const SizedBox.shrink();
  final bool active;
  final String label;
  final Widget child;
  @override
  State<StudioPageLoading> createState() => _StudioPageLoadingState();
}

class _StudioPageLoadingState extends State<StudioPageLoading> {
  final _operation = Object();
  _LoadingPresentation? _presentation;
  void _report() {
    if (!widget.active) {
      _presentation?.report(_operation, null);
      _presentation = null;
      return;
    }
    final next = _LoadingPresentation.of(context);
    if (!identical(next, _presentation)) {
      _presentation?.report(_operation, null);
      _presentation = next;
    }
    _presentation!.report(_operation, widget.label);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _report();
  }

  @override
  void didUpdateWidget(StudioPageLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    _report();
  }

  @override
  void dispose() {
    _presentation?.report(_operation, null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Availability admits a page pulse; nested regions share the outer operation.
class StudioLoadingRegion extends StatelessWidget {
  const StudioLoadingRegion({
    super.key,
    required this.busy,
    required this.available,
    required this.label,
    required this.child,
  });
  final bool busy, available;
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final inherited = _LoadingScope.maybeOf(context);
    final blocked = busy && !available;
    return StudioPageLoading(
      active: blocked && !inherited,
      label: label,
      child: _LoadingScope(active: blocked || inherited, child: child),
    );
  }
}

class _LoadingScope extends InheritedWidget {
  const _LoadingScope({required this.active, required super.child});
  final bool active;
  static bool maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LoadingScope>()?.active ??
      false;
  @override
  bool updateShouldNotify(_LoadingScope oldWidget) =>
      active != oldWidget.active;
}

/// Retains Android's refresh gesture; Wing owns its visible loading feedback.
class StudioRefresh extends StatefulWidget {
  const StudioRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    required this.available,
    this.label = 'Refreshing',
  });
  final RefreshCallback onRefresh;
  final Widget child;
  final String label;
  final bool available;
  @override
  State<StudioRefresh> createState() => _StudioRefreshState();
}

class _StudioRefreshState extends State<StudioRefresh> {
  RefreshIndicatorStatus? _status;
  @override
  Widget build(BuildContext context) => StudioLoadingRegion(
    available: widget.available,
    busy:
        _status == RefreshIndicatorStatus.drag ||
        _status == RefreshIndicatorStatus.armed ||
        _status == RefreshIndicatorStatus.snap ||
        _status == RefreshIndicatorStatus.refresh,
    label: widget.label,
    child: RefreshIndicator.noSpinner(
      onRefresh: widget.onRefresh,
      onStatusChange: (status) {
        if (mounted) setState(() => _status = status);
      },
      child: widget.child,
    ),
  );
}

/// A shared modal heading with a reserved progress slot and close action.
class WingModalHeader extends StatelessWidget {
  const WingModalHeader({
    super.key,
    required this.title,
    required this.onClose,
    required this.closeLabel,
  });
  final Widget title;
  final VoidCallback? onClose;
  final String closeLabel;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.titleMedium!,
          child: title,
        ),
      ),
      const StudioLoadingSlot(),
      StudioButtonPress(
        child: IconButton(
          tooltip: closeLabel,
          onPressed: onClose,
          icon: const Icon(Icons.close),
        ),
      ),
    ],
  );
}
