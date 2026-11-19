import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/wing_bg_watch.dart';
import '../theme/wing_theme.dart';

/// Desktop's `arc-border arc-row`, painted over the row without changing its
/// layout, gestures or semantics. Only the border repaints on animation ticks.
class ChatWorkingBorder extends StatefulWidget {
  const ChatWorkingBorder({
    super.key,
    required this.working,
    required this.child,
  });

  final bool working;
  final Widget child;

  @override
  State<ChatWorkingBorder> createState() => ChatWorkingBorderState();
}

/// Public so `WidgetTester.state<ChatWorkingBorderState>` can read
/// [isAnimating] directly: the test binding's `hasScheduledFrame` goes
/// false for the whole app on `AppLifecycleState.paused` regardless of
/// whether this controller actually stopped, so it cannot tell a gated
/// ticker from an ungated one.
class ChatWorkingBorderState extends State<ChatWorkingBorder>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _animation =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2230),
      )..addListener(_onTick);

  // Card t_482d3051: a repeating border animation kept ticking (and the
  // raster thread kept compositing it) while the app was paused and nobody
  // could see it. Only `widget.working` and reduced motion gated it before;
  // app focus now gates it too.
  bool _resumed = true;

  @visibleForTesting
  bool get isAnimating => _animation.isAnimating;

  void _onTick() {
    // Only a regression (the ticker still running once paused) ever logs
    // here: recordWakeup is a no-op while foreground.
    WingBgWatch.instance.recordWakeup('chat_working_border');
  }

  void _syncAnimation() {
    if (widget.working && _resumed && !MediaQuery.disableAnimationsOf(context)) {
      if (!_animation.isAnimating) _animation.repeat();
    } else {
      _animation.stop();
      _animation.value = 0;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _resumed) return;
    _resumed = resumed;
    _syncAnimation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ChatWorkingBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    return Stack(
      children: [
        widget.child,
        if (widget.working)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _WorkingBorderPainter(
                    _animation,
                    Theme.of(context).brightness == Brightness.dark
                        ? tokens.onSurface
                        : tokens.muted,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _WorkingBorderPainter extends CustomPainter {
  _WorkingBorderPainter(this.animation, this.color) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Match desktop's 300% gradient layer translated from -10% to -50%,
    // with a 160-degree CSS gradient and a 45%-opacity trailing stop.
    final layer = Size(size.width * 3, size.height * 3);
    final travel = -.1 - .4 * animation.value;
    final center = Offset(
      layer.width * (.5 + travel),
      layer.height * (.5 + travel),
    );
    const angle = 160 * math.pi / 180;
    final direction = Offset(math.sin(angle), -math.cos(angle));
    final length =
        layer.width * direction.dx.abs() + layer.height * direction.dy.abs();
    final half = direction * (length / 2);
    final clear = color.withValues(alpha: 0);
    final tail = color.withValues(alpha: .45);
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        center - half,
        center + half,
        [
          clear,
          clear,
          color,
          tail,
          clear,
          clear,
          clear,
          color,
          tail,
          clear,
          clear,
          clear,
          color,
        ],
        [0, .15, .20, .25, .35, .40, .55, .60, .65, .75, .80, .95, 1],
      );
    final outer = WingRadius.control.toRRect(Offset.zero & size);
    canvas.drawDRRect(outer, outer.deflate(1.25), paint);
  }

  @override
  bool shouldRepaint(_WorkingBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.animation != animation;
}
