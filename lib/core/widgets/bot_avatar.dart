import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../theme/profile_colors.dart';
import '../models/bots.dart';
import '../models/hermes_profile.dart';
import '../services/bots_session.dart';
import 'wing_app_bar.dart';

enum BotAvatarMood { idle, work, think }

/// Supplies the existing image owner without retaining bytes in row definitions.
class BotAvatarScope extends InheritedTheme {
  const BotAvatarScope({
    super.key,
    required this.session,
    this.prepared = false,
    required super.child,
  });
  final BotsSession session;
  final bool prepared;
  @override
  Widget wrap(BuildContext context, Widget child) =>
      BotAvatarScope(session: session, prepared: prepared, child: child);
  static BotsSession? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BotAvatarScope>()?.session;
  @override
  bool updateShouldNotify(BotAvatarScope oldWidget) =>
      session != oldWidget.session || prepared != oldWidget.prepared;
}

/// Mounted rows own demand; frozen row and navigation facts stay metadata-only.
class BorrowedBotAvatar extends StatefulWidget {
  const BorrowedBotAvatar({
    super.key,
    required this.bot,
    this.name,
    this.mood,
    this.size = 40,
  });
  final BotRecord? bot;
  final String? name;
  final BotAvatarMood? mood;
  final double size;
  @override
  State<BorrowedBotAvatar> createState() => _BorrowedBotAvatarState();
}

class _BorrowedBotAvatarState extends State<BorrowedBotAvatar>
    with WidgetsBindingObserver {
  BotsSession? _owner;
  BotAvatarBorrower? _borrower;
  bool _active = false, _queued = false, _admissionQueued = false;
  ScrollPosition? _scroll;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = BotAvatarScope.maybeOf(context);
    if (!identical(owner, _owner)) {
      _borrower?.changes.removeListener(_changed);
      _borrower?.dispose();
      _owner = owner;
      _borrower = owner?.createAvatarBorrower();
      _borrower?.changes.addListener(_changed);
    }
    final scroll = Scrollable.maybeOf(context)?.position;
    if (!identical(scroll, _scroll)) {
      _scroll?.removeListener(_queueAdmission);
      _scroll = scroll;
      _scroll?.addListener(_queueAdmission);
    }
    // Fixed headers need no viewport geometry and can borrow cached identity
    // before their first paint. Sliver rows wait until layout has positioned them.
    if (_scroll == null) {
      _syncDemand();
    } else {
      _queueAdmission();
    }
  }

  @override
  void didUpdateWidget(BorrowedBotAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Retained sliver rows can be between positions until layout completes.
    _queueAdmission();
  }

  BotRecord? get _currentBot {
    final captured = widget.bot;
    return captured == null
        ? null
        : _owner?.cachedProfileAppearance(captured.scope) ?? captured;
  }

  bool _presented = true;

  @override
  void deactivate() {
    _presented = false;
    _active = false;
    _borrower?.replaceDemand(<WorkspaceScope>{});
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _presented = true;
    _queueAdmission();
  }

  void _syncDemand() {
    if (!_presented) return;
    final bot = _currentBot;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _active =
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        (TickerMode.valuesOf(context).enabled ||
            context
                    .dependOnInheritedWidgetOfExactType<BotAvatarScope>()
                    ?.prepared ==
                true) &&
        ModalRoute.isCurrentOf(context) != false &&
        _inNeighborhood;
    _borrower?.replaceDemand(
      _active && bot != null && !bot.hasExplicitClassicShape
          ? {bot.scope}
          : <WorkspaceScope>{},
    );
  }

  bool get _inNeighborhood {
    if (_scroll == null ||
        context
                .dependOnInheritedWidgetOfExactType<BotAvatarScope>()
                ?.prepared ==
            true) {
      return true;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    var visible = (Offset.zero & MediaQuery.sizeOf(context)).inflate(250);
    final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (viewport is RenderBox && viewport.hasSize) {
      visible = visible.intersect(
        (viewport.localToGlobal(Offset.zero) & viewport.size).inflate(250),
      );
    }
    return visible.overlaps(box.localToGlobal(Offset.zero) & box.size);
  }

  void _queueAdmission() {
    if (_admissionQueued) return;
    _admissionQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _admissionQueued = false;
      if (!mounted || !_presented) return;
      final wasActive = _active;
      _syncDemand();
      if (wasActive != _active) _changed();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _active = false;
      _borrower?.replaceDemand(<WorkspaceScope>{});
      if (_presented) _changed();
    } else {
      _queueAdmission();
    }
  }

  void _changed() {
    if (!mounted || _queued) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _queued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _queued = false;
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll?.removeListener(_queueAdmission);
    _borrower?.changes.removeListener(_changed);
    _borrower?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Owner notifications may change image mode while a sender future or frozen
    // selection still supplies the original metadata-only observation.
    _queueAdmission();
    final bot = _currentBot;
    final name = widget.name ?? bot?.title ?? '';
    if (bot == null) {
      return BotAvatar(name: name, shape: 'circle', size: widget.size);
    }
    if (widget.mood != null && bot.hasExplicitClassicShape) {
      return _AnimatedFace(
        key: ValueKey(bot.scope),
        shape: bot.shape,
        color: BotAvatar.resolveColor(bot.color, name),
        mood: widget.mood!,
        size: widget.size,
        phase:
            bot.id.codeUnits.fold(0, (int h, c) => (h * 31 + c) & 1023) /
            1024 *
            3.2,
      );
    }
    return BotAvatar(
      name: name,
      shape: bot.shape,
      color: bot.color,
      image: _active ? _borrower?.imageFor(bot.scope) : null,
      size: widget.size,
    );
  }
}

class LiveBotAvatar extends StatelessWidget {
  const LiveBotAvatar({
    super.key,
    required this.bot,
    required this.name,
    required this.mood,
    this.size = 40,
  });
  final BotRecord bot;
  final String name;
  final BotAvatarMood mood;
  final double size;
  @override
  Widget build(BuildContext context) =>
      BorrowedBotAvatar(bot: bot, name: name, mood: mood, size: size);
}

/// Owns only paint time. Scroll, route, ticker and app visibility all retire it.
class _AnimatedFace extends StatefulWidget {
  const _AnimatedFace({
    super.key,
    required this.shape,
    required this.color,
    required this.mood,
    required this.size,
    required this.phase,
  });
  final String shape;
  final Color color;
  final BotAvatarMood mood;
  final double size, phase;
  @override
  State<_AnimatedFace> createState() => _AnimatedFaceState();
}

class _AnimatedFaceState extends State<_AnimatedFace>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_tick);
  final _pose = ValueNotifier<_FacePose>(const _FacePose());
  ScrollPosition? _scroll;
  Duration _lastPaint = Duration.zero;
  double _time = 0, _transitionStart = -1;
  _FacePose _from = const _FacePose();
  bool _visibilityQueued = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Register dependencies even when animation is currently parked.
    TickerMode.valuesOf(context);
    MediaQuery.disableAnimationsOf(context);
    ModalRoute.isCurrentOf(context);
    final scroll = Scrollable.maybeOf(context)?.position;
    if (!identical(scroll, _scroll)) {
      _scroll?.removeListener(_queueVisibility);
      _scroll = scroll;
      _scroll?.addListener(_queueVisibility);
    }
    _queueVisibility();
  }

  @override
  void didUpdateWidget(_AnimatedFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mood != widget.mood) {
      _from = _pose.value;
      _transitionStart = _time;
    }
    _queueVisibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncVisibility();

  void _queueVisibility() {
    if (_visibilityQueued) return;
    _visibilityQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityQueued = false;
      if (mounted) _syncVisibility();
    });
  }

  bool get _canAnimate {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if ((lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
        !TickerMode.valuesOf(context).enabled ||
        MediaQuery.disableAnimationsOf(context) ||
        ModalRoute.isCurrentOf(context) == false) {
      return false;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    var visible = Offset.zero & MediaQuery.sizeOf(context);
    final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (viewport is RenderBox && viewport.hasSize) {
      visible = visible.intersect(
        viewport.localToGlobal(Offset.zero) & viewport.size,
      );
    }
    return visible.overlaps(box.localToGlobal(Offset.zero) & box.size);
  }

  void _syncVisibility() {
    if (_canAnimate) {
      if (!_ticker.isActive) {
        _lastPaint = Duration.zero;
        _ticker.start();
      }
    } else {
      _ticker.stop();
      _pose.value = const _FacePose();
      _transitionStart = -1;
    }
  }

  void _tick(Duration elapsed) {
    if (elapsed - _lastPaint < const Duration(microseconds: 66667)) return;
    _time += (elapsed - _lastPaint).inMicroseconds / 1000000;
    _lastPaint = elapsed;
    final target = _FacePose.at(widget.mood, _time + widget.phase);
    final blend = ((_time - _transitionStart) / .4).clamp(0.0, 1.0);
    _pose.value = _transitionStart < 0
        ? target
        : _FacePose.blend(_from, target, 1 - (1 - blend) * (1 - blend));
  }

  @override
  void dispose() {
    _scroll?.removeListener(_queueVisibility);
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _pose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _FacePainter(widget.shape, widget.color, motion: _pose),
      ),
    ),
  );
}

/// Native adaptation of Hermes' MIT-licensed face timing. See NOTICE.md.
class _FacePose {
  const _FacePose({
    this.turn = 0,
    this.tilt = 0,
    this.roll = 0,
    this.gazeX = 0,
    this.gazeY = 0,
    this.blink = false,
    this.dots = const [0, 0, 0],
  });
  final double turn, tilt, roll, gazeX, gazeY;
  final bool blink;
  final List<double> dots;

  factory _FacePose.at(BotAvatarMood mood, double t) {
    if (mood == BotAvatarMood.idle) {
      return _FacePose(
        turn: math.sin(t * .5) * 1.5,
        tilt: math.sin(t * .27),
        roll: math.sin(t * .85) * 1.2,
        blink: t % 3.2 > 3.02,
      );
    }
    final thinking = mood == BotAvatarMood.think;
    return _FacePose(
      turn: thinking
          ? -18 + math.sin(t * .55) * 14
          : -11 + math.sin(t * .48) * 8,
      tilt: thinking
          ? math.sin(t * .48) * 12 + math.sin(t * 1.35) * 3
          : math.sin(t * .42) * 8 + math.sin(t * 1.1) * 1.6,
      roll: math.sin(t * (thinking ? .95 : .75)) * (thinking ? 10 : 4.2),
      gazeX: math.sin(t * (thinking ? .7 : .55)) * 3.6,
      gazeY: thinking
          ? -2.2 + math.sin(t * .4) * 2.2
          : -1.6 + math.sin(t * .38) * 2,
      blink: t % 1.45 > 1.26,
      dots: [
        for (var i = 0; i < 3; i++)
          .2 + .8 * math.max(0, math.sin(t * (thinking ? 2.4 : 2.6) - i * .7)),
      ],
    );
  }

  factory _FacePose.blend(_FacePose a, _FacePose b, double p) {
    double mix(double x, double y) => x + (y - x) * p;
    return _FacePose(
      turn: mix(a.turn, b.turn),
      tilt: mix(a.tilt, b.tilt),
      roll: mix(a.roll, b.roll),
      gazeX: mix(a.gazeX, b.gazeX),
      gazeY: mix(a.gazeY, b.gazeY),
      blink: b.blink,
      dots: [for (var i = 0; i < 3; i++) mix(a.dots[i], b.dots[i])],
    );
  }
}

/// Desktop's friendly shape faces, rendered natively with Studio sizing.
class BotAvatar extends StatelessWidget {
  const BotAvatar({
    super.key,
    required this.name,
    required this.shape,
    this.color = '',
    this.image,
    this.size = 40,
  });
  final String name, shape, color;
  final Uint8List? image;
  final double size;
  @override
  Widget build(BuildContext context) {
    if (image != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          image!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
          errorBuilder: (_, _, _) => _face(context),
        ),
      );
    }
    return _face(context);
  }

  Widget _face(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _FacePainter(shape, resolveColor(color, name))),
  );
  static Color resolveColor(String color, String name) =>
      _color(color) ?? desktopProfileColor(name) ?? const Color(0xff8b5cf6);

  static Color? _color(String text) {
    if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text)) {
      return Color(0xff000000 | int.parse(text.substring(1), radix: 16));
    }
    final hsl = RegExp(
      r'^hsl\(\s*([\d.]+)[,\s]+([\d.]+)%[,\s]+([\d.]+)%\s*\)$',
    ).firstMatch(text);
    if (hsl != null) {
      final h = double.parse(hsl[1]!);
      final s = double.parse(hsl[2]!) / 100;
      final l = double.parse(hsl[3]!) / 100;
      if (h <= 360 && s <= 1 && l <= 1) {
        return HSLColor.fromAHSL(1, h, s, l).toColor();
      }
    }
    return null;
  }
}

class _FacePainter extends CustomPainter {
  _FacePainter(this.shape, this.color, {this.motion}) : super(repaint: motion);
  final String shape;
  final Color color;
  final ValueNotifier<_FacePose>? motion;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 40, size.height / (motion == null ? 40 : 44));
    final pose = motion?.value ?? const _FacePose();
    canvas.save();
    canvas.translate(20, 20);
    canvas.rotate((pose.roll + pose.tilt) * math.pi / 180);
    canvas.scale(
      math.cos(pose.turn * math.pi / 180),
      math.cos(pose.tilt * math.pi / 180),
    );
    canvas.translate(-20, -20);
    final paint = Paint()..color = color;
    final path = Path();
    switch (shape) {
      case 'circle':
        canvas.drawCircle(const Offset(20, 20), 18, paint);
      case 'triangle':
        path.moveTo(20, 2);
        path.quadraticBezierTo(23, 2, 25, 6);
        path.lineTo(38, 32);
        path.quadraticBezierTo(40, 37, 34, 37);
        path.lineTo(6, 37);
        path.quadraticBezierTo(0, 37, 2, 32);
        path.lineTo(15, 6);
        path.close();
        canvas.drawPath(path, paint);
      case 'hexagon':
        for (var i = 0; i < 6; i++) {
          final angle = math.pi / 3 * i;
          final p = Offset(
            20 + 19 * math.cos(angle),
            20 + 19 * math.sin(angle),
          );
          if (i == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        path.close();
        canvas.drawPath(path, paint);
      case 'pill':
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(5, 1, 30, 38),
            const Radius.circular(15),
          ),
          paint,
        );
      case 'drop':
        path.moveTo(20, 1);
        path.cubicTo(23, 8, 38, 16, 38, 24);
        path.cubicTo(38, 44, 2, 44, 2, 24);
        path.cubicTo(2, 16, 17, 8, 20, 1);
        path.close();
        canvas.drawPath(path, paint);
      case 'blob':
        path.moveTo(20, 2);
        path.cubicTo(34, -2, 43, 16, 36, 26);
        path.cubicTo(41, 38, 21, 43, 13, 36);
        path.cubicTo(-2, 39, -2, 16, 6, 12);
        path.cubicTo(8, 1, 13, 4, 20, 2);
        path.close();
        canvas.drawPath(path, paint);
      case 'cloud':
        canvas.drawCircle(const Offset(12, 17), 11, paint);
        canvas.drawCircle(const Offset(25, 14), 12, paint);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(1, 15, 38, 22),
            const Radius.circular(11),
          ),
          paint,
        );
      default:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(2, 2, 36, 36),
            const Radius.circular(10),
          ),
          paint,
        );
    }
    final eyes = Paint()
      ..color = color.computeLuminance() > .4
          ? const Color(0xff17232c)
          : const Color(0xfff4f5ed);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          12 + pose.gazeX,
          (shape == 'cloud' && motion != null ? 22 : 19.5) +
              pose.gazeY -
              (pose.blink ? .5 : 3.5),
          4,
          pose.blink ? 1 : 7,
        ),
        const Radius.circular(2),
      ),
      eyes,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          24 + pose.gazeX,
          (shape == 'cloud' && motion != null ? 22 : 19.5) +
              pose.gazeY -
              (pose.blink ? .5 : 3.5),
          4,
          pose.blink ? 1 : 7,
        ),
        const Radius.circular(2),
      ),
      eyes,
    );
    canvas.restore();
    for (var i = 0; i < 3; i++) {
      if (pose.dots[i] > 0) {
        canvas.drawCircle(
          Offset(16.4 + i * 3.6, 41.2),
          1.15,
          Paint()..color = color.withValues(alpha: pose.dots[i]),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FacePainter oldDelegate) =>
      oldDelegate.shape != shape ||
      oldDelegate.color != color ||
      oldDelegate.motion != motion;
}

/// The shared title for live and passive canonical bot conversations.
class BotConversationTitle extends StatelessWidget {
  const BotConversationTitle({
    super.key,
    required this.title,
    required this.bot,
    required this.mood,
  });
  final String title;
  final BotRecord? bot;

  /// Null selects the stable passive rendition used for Recents capture.
  final BotAvatarMood? mood;
  @override
  Widget build(BuildContext context) => WingConversationTitle(
    title: bot?.title ?? title,
    avatar: switch (bot) {
      final appearance? =>
        mood == null
            ? BorrowedBotAvatar(
                bot: appearance,
                name: appearance.title,
                size: 32,
              )
            : LiveBotAvatar(
                bot: appearance,
                name: appearance.title,
                mood: mood!,
                size: 32,
              ),
      null => null,
    },
  );
}
