import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

/// Presentation-only geometry. Independent spring velocities survive a new
/// target; dragging changes position directly without an easing queue.
final class ConversationCardMotion extends ChangeNotifier {
  ConversationCardMotion(TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }
  late final Ticker _ticker;
  double position = 0, lift = 0, zoom = 0;
  double positionVelocity = 0, liftVelocity = 0, zoomVelocity = 0;
  Simulation? _position, _lift, _zoom;
  double _positionStarted = 0;
  double? _coastTarget;
  VoidCallback? _settled;
  bool get animating => _ticker.isActive;

  void _tick(Duration elapsed) {
    final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (_coastTarget case final target?) {
      final coast = _position!;
      if (coast.dx(t).abs() < 1.2) {
        _position = _spring(coast.x(t), target, coast.dx(t), horizontal: true);
        _positionStarted = t;
        _coastTarget = null;
      }
    }
    if (_position case final spring?) {
      position = spring.x(t - _positionStarted);
      positionVelocity = spring.dx(t - _positionStarted);
    }
    if (_lift case final spring?) {
      lift = spring.x(t);
      liftVelocity = spring.dx(t);
    }
    if (_zoom case final spring?) {
      zoom = spring.x(t);
      zoomVelocity = spring.dx(t);
    }
    notifyListeners();
    if ([_position, _lift, _zoom].indexed.every(
      (entry) =>
          entry.$2 == null ||
          entry.$2!.isDone(t - (entry.$1 == 0 ? _positionStarted : 0)),
    )) {
      _ticker.stop();
      final callback = _settled;
      _settled = null;
      callback?.call();
    }
  }

  void stop() {
    _ticker.stop();
    _position = _lift = _zoom = null;
    _positionStarted = 0;
    _coastTarget = null;
    _settled = null;
  }

  void drag(double value, double velocity) {
    position = value;
    positionVelocity = velocity;
    notifyListeners();
  }

  void pinch(double elevation, double amount) {
    lift = elevation;
    zoom = amount;
    liftVelocity = zoomVelocity = 0;
    notifyListeners();
  }

  void jump({
    required double position,
    required double lift,
    required double zoom,
  }) {
    stop();
    this.position = position;
    this.lift = lift;
    this.zoom = zoom;
    positionVelocity = liftVelocity = zoomVelocity = 0;
    notifyListeners();
  }

  void spring({
    double? position,
    required double lift,
    required double zoom,
    bool reducedMotion = false,
    VoidCallback? settled,
  }) {
    stop();
    if (reducedMotion) {
      jump(position: position ?? this.position, lift: lift, zoom: zoom);
      settled?.call();
      return;
    }
    if (position != null) {
      _position = _spring(
        this.position,
        position,
        positionVelocity,
        horizontal: true,
      );
    }
    _lift = _spring(this.lift, lift, liftVelocity);
    _zoom = _spring(this.zoom, zoom, zoomVelocity);
    _settled = settled;
    _ticker.start();
  }

  /// A continuous ring has no page boundary: friction determines travel, then
  /// a short spring lands on the projected card. A press can stop it anywhere.
  void coast({
    required double velocity,
    required bool reducedMotion,
    required VoidCallback settled,
  }) {
    final friction = FrictionSimulation(.055, position, velocity);
    final target = friction.finalX.roundToDouble();
    positionVelocity = velocity;
    spring(
      position: velocity.abs() < 1.2 || reducedMotion ? target : null,
      lift: 1,
      zoom: 1,
      reducedMotion: reducedMotion,
      settled: settled,
    );
    if (!reducedMotion && velocity.abs() >= 1.2) {
      _position = friction;
      _coastTarget = target;
    }
  }

  /// Returning to a frequently used chat has a fixed, short duration. The
  /// separate live-content handoff must not wait for a spring's long tail.
  void expand({
    required double position,
    required bool reducedMotion,
    required VoidCallback settled,
  }) {
    stop();
    if (reducedMotion) {
      jump(position: position, lift: 0, zoom: 0);
      settled();
      return;
    }
    _position = _Expansion(this.position, position);
    _lift = _Expansion(lift, 0);
    _zoom = _Expansion(zoom, 0);
    _settled = settled;
    _ticker.start();
  }

  SpringSimulation _spring(
    double from,
    double to,
    double velocity, {
    bool horizontal = false,
  }) => SpringSimulation(
    SpringDescription(
      mass: 1,
      stiffness: horizontal ? 500 : 560,
      damping: horizontal ? 29 : 31,
    ),
    from,
    to,
    velocity,
    tolerance: const Tolerance(distance: .0007, velocity: .012),
  );

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

final class _Expansion extends Simulation {
  _Expansion(this.from, this.to);
  final double from, to;
  static const duration = .24;
  double _remaining(double t) => 1 - (t / duration).clamp(0.0, 1.0);
  @override
  double x(double t) {
    final remaining = _remaining(t);
    return to + (from - to) * remaining * remaining * remaining;
  }

  @override
  double dx(double t) {
    final remaining = _remaining(t);
    return (to - from) * 3 * remaining * remaining / duration;
  }

  @override
  bool isDone(double t) => t >= duration;
}
