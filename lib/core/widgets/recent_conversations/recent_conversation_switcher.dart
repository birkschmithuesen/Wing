import '../wing_app_bar.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../models/recent_conversation.dart';
import '../../services/recent_conversation_session.dart';
import '../studio_error.dart';
import '../background_markdown_content.dart';
import 'conversation_card_motion.dart';
import 'conversation_card_snapshots.dart';
import 'conversation_gestures.dart';
import 'conversation_preview.dart';

/// A transient layer over the real chat. It owns only input, card geometry,
/// bounded ephemeral raster captures and nudge paint. The session owns reads
/// and selection; the normal conversation remains mounted underneath.
class RecentConversationSwitcher extends StatefulWidget {
  const RecentConversationSwitcher({
    super.key,
    required this.session,
    required this.chatKey,
    required this.child,
    required this.previewBuilder,
    required this.gesturesEnabled,
    required this.nudgesEnabled,
    required this.onPresentationChanged,
  });
  final RecentConversationSession session;
  final RecentConversationKey chatKey;
  final Widget child;
  final Widget Function(RecentConversationCard) previewBuilder;
  final bool gesturesEnabled, nudgesEnabled;
  final void Function(bool obscured, bool stack) onPresentationChanged;

  @override
  RecentConversationSwitcherState createState() =>
      RecentConversationSwitcherState();
}

class RecentConversationSwitcherState extends State<RecentConversationSwitcher>
    with TickerProviderStateMixin {
  late final ConversationCardMotion _motion = ConversationCardMotion(this);
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: _PondRipplePainter.duration,
  );
  final _liveBoundary = GlobalKey();
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
  );
  late ConversationCardSnapshots _snapshots = _snapshotAdapter();
  ConversationCardSnapshots _snapshotAdapter() => ConversationCardSnapshots(
    widget.session.snapshots,
    environment: () => (_renderEnvironment, _size),
    liveEnvironment: () => (_renderEnvironment, _size, _liveInsets),
  );

  void _snapshotsChanged() {
    if (mounted) setState(() {});
  }

  final _previewBoundary = GlobalKey();
  final _stackFooter = GlobalKey();
  double _footerHeight = 0;
  bool _footerMeasurementPending = false;
  final _placeholders =
      <RecentConversationKey, ({Object revision, Widget child})>{};
  Widget? _stagingView;
  final _failures = <RecentConversationKey, Object>{};
  final _initialBatch = <RecentConversationKey>{};
  final _completed = <RecentConversationKey>{};
  Timer? _batchTimer;
  Completer<void>? _preparationCancel;
  Future<void>? _liveCapture;
  bool get _batchPending => _initialBatch.difference(_completed).isNotEmpty;

  Timer? _idleTimer;
  bool _preparing = false, _preparationRequested = false, _liveDirty = true;
  bool _openingPreparation = false;
  Object? _renderEnvironment;
  EdgeInsets? _liveInsets;
  Completer<void>? _selectionCompletion;
  Completer<void>? _expansionCompletion;
  Widget? _selectionChild;
  RecentConversationKey? _openingKey;
  bool _paintingSelected = false, _selectionPainted = false;
  bool _expansionFinished = false;
  bool get _moving => _gesture != null || _motion.animating || _selecting;

  int _captureGeneration = 0;
  bool _active = false, _stack = false, _selecting = false;
  int _base = 0;
  late List<RecentConversationEntry> _membership;
  double _startPosition = 0, _pinchPosition = 0, _pinchLift = 0;
  ConversationGestureKind? _gesture;
  double _lastPosition = 0, _velocity = 0;
  Duration? _lastMove;
  Size _size = Size.zero;
  ConversationNudge? _cue;
  bool get _reduced => MediaQuery.disableAnimationsOf(context);
  bool get _canGesture =>
      widget.gesturesEnabled &&
      widget.session.active &&
      widget.session.entries.isNotEmpty;
  bool get _canSlide =>
      !widget.session.modeEnabled || widget.session.entries.length > 1;
  bool get _canBrowse =>
      widget.session.modeEnabled && widget.session.entries.length > 1;
  List<int> get _cardOffsets =>
      widget.session.entries.length == 1 ? [0] : [-1, 0, 1];
  int get _focusedIndex => _base - _motion.position.round();
  int _indexOf(RecentConversationKey key) =>
      widget.session.entries.indexWhere((entry) => entry.key == key);

  @override
  void initState() {
    super.initState();
    _membership = widget.session.entries;
    _base = math.max(0, _indexOf(widget.chatKey));
    widget.session.snapshots.addListener(_snapshotsChanged);
    _motion.addListener(_motionChanged);
    widget.session.addListener(_sessionChanged);
    widget.session.nudges.addListener(_nudgeChanged);
    _pulse.addStatusListener(_pulseStatusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _queueIdleWork());
  }

  @override
  void didUpdateWidget(RecentConversationSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _clearCue();
      oldWidget.session.setVisible(false);
      oldWidget.session.snapshots.removeListener(_snapshotsChanged);
      widget.session.snapshots.addListener(_snapshotsChanged);
      oldWidget.session.removeListener(_sessionChanged);
      oldWidget.session.nudges.removeListener(_nudgeChanged);
      widget.session.addListener(_sessionChanged);
      widget.session.nudges.addListener(_nudgeChanged);
      _clearCaptures();
      _snapshots = _snapshotAdapter();
      _completeSelection();
      _active = _stack = _selecting = false;
      _base = math.max(0, _indexOf(widget.chatKey));
      _membership = widget.session.entries;
      _motion.jump(position: 0, lift: 0, zoom: 0);
    } else if (oldWidget.chatKey != widget.chatKey && !_selecting) {
      _clearCue();
      _base = math.max(0, _indexOf(widget.chatKey));
      _active = _stack = false;
      _motion.jump(position: 0, lift: 0, zoom: 0);
    }
    if (oldWidget.child != widget.child) {
      _liveDirty = true;
    }
    _queueIdleWork();
    if (!widget.gesturesEnabled && _gesture != null) _cancel();
    _syncCueAdmission();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final environment = (
      // Workspace rebuilds recreate ThemeData and its extension instances.
      // Compare the supported appearance values, not extension identity.
      theme.colorScheme,
      theme.textTheme,
      theme.iconTheme,
      theme.appBarTheme,
      theme.visualDensity,
      theme.platform,
      media.size,
      media.padding,
      media.devicePixelRatio,
      media.textScaler,
      Directionality.of(context),
    );
    if (_renderEnvironment != environment) {
      _renderEnvironment = environment;
      _clearCaptures();
      if (_stack) _beginBatch();
      _queueIdleWork();
    }
    if (_liveInsets != media.viewInsets) {
      _liveInsets = media.viewInsets;
      _liveDirty = true;
    }
    _syncCueAdmission();
  }

  void _sessionChanged() {
    if (!mounted) return;
    if (!identical(_membership, widget.session.entries)) {
      final focused = _membership[_focusedIndex % _membership.length].key;
      _membership = widget.session.entries;
      // Adding entries changes modulo arithmetic after a circular lap. Rebase
      // the settled stack on its identity before exposing the expanded ring.
      _base = math.max(0, _indexOf(focused));
      _motion.jump(position: 0, lift: _motion.lift, zoom: _motion.zoom);
      if (_stack) _beginBatch();
    }
    if (!widget.session.active) {
      _clearCue();
      _active = _stack = _selecting = false;
      _gesture = null;
      _motion.stop();
      _clearCaptures();
      _completeSelection();
      _notifyPresentation();
    }
    setState(() {});
    _queueIdleWork();
  }

  void _syncCueAdmission() {
    widget.session.setVisible(widget.gesturesEnabled);
    widget.session.setMembershipPaused(_moving);
    final enabled =
        widget.session.modeEnabled &&
        widget.nudgesEnabled &&
        !_reduced &&
        !_selecting &&
        _gesture == null &&
        !_motion.animating &&
        (!_active || _stack);
    widget.session.setInteractive(
      enabled,
      origin: _active && _stack
          ? widget.session.entryAt(_focusedIndex).key
          : widget.chatKey,
    );
    if (!enabled) {
      _clearCue();
    }
  }

  void _nudgeChanged() {
    if (!mounted ||
        !widget.nudgesEnabled ||
        _active && !_stack ||
        _gesture != null ||
        _motion.animating ||
        _reduced) {
      return;
    }
    setState(() => _cue = widget.session.nudges.value);
    _pulse.forward(from: 0);
  }

  void _clearCue() {
    _pulse.stop();
    _cue = null;
  }

  void _pulseStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _cue = null);
    }
  }

  void _motionChanged() {
    if (_moving) {
      widget.session.setMembershipPaused(true);
      if (_openingPreparation && _gesture == null && _stack && !_selecting) {
        _pauseCaptures();
      } else {
        _pausePreparation();
      }
    }
  }

  void _pausePreparation() {
    _openingPreparation = false;
    widget.session.pausePreparation();
    _pauseCaptures();
  }

  void _pauseCaptures() {
    _idleTimer?.cancel();
    final cancel = _preparationCancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  void _beginBatch() {
    _batchTimer?.cancel();
    _failures.clear();
    _initialBatch
      ..clear()
      ..addAll(widget.session.keysAround(_focusedIndex));
    _completed.clear();
    for (final key in _initialBatch) {
      if (_preservesMountedViewport(key) ||
          _snapshots.imageFor(key) != null &&
              _snapshots.revisionFor(key) == _snapshotRevision(key)) {
        _completeCard(key);
      }
    }
    _batchTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted) return;
      for (final key in _initialBatch.difference(_completed)) {
        _failures[key] = _snapshotRevision(key);
      }
      _pausePreparation();
      setState(() => _completed.addAll(_initialBatch));
    });
  }

  void _completeCard(RecentConversationKey key) {
    if (_initialBatch.contains(key)) _completed.add(key);
  }

  void _endBatch() {
    _batchTimer?.cancel();
    _initialBatch.clear();
    _completed.clear();
    _pausePreparation();
  }

  void _queueIdleWork() {
    _idleTimer?.cancel();
    if (!mounted || !_active || !_stack || _moving || !widget.session.active) {
      return;
    }
    if (_preparing) {
      _preparationRequested = true;
      return;
    }
    // This is event-driven gesture settling, not recurring prewarming or
    // Priority.idle: an animated progress indicator cannot starve this queue.
    final delay = _openingPreparation
        ? Duration.zero
        : const Duration(milliseconds: 80);
    _idleTimer = Timer(delay, () {
      if (mounted && !_moving) {
        widget.session.setMembershipPaused(false);
        unawaited(_prepareIdle());
      }
    });
  }

  Future<void> _prepareIdle() async {
    if (_preparing ||
        !_stack ||
        _moving ||
        !widget.session.active ||
        _size.isEmpty) {
      return;
    }
    final snapshots = _snapshots;
    _preparing = true;
    _openingPreparation = false;
    _preparationRequested = false;
    final generation = _captureGeneration;
    final cancel = _preparationCancel = Completer<void>();
    bool current() =>
        mounted &&
        widget.session.active &&
        _stack &&
        !_moving &&
        generation == _captureGeneration &&
        !cancel.isCompleted;
    try {
      // The departing real-page readback and synthetic readbacks share one lane.
      if (_liveCapture != null) {
        await Future.any<void>([_liveCapture!, cancel.future]);
      }
      if (!current()) return;
      final neighborhood = widget.session.keysAround(_focusedIndex, limit: 3);
      final order = <RecentConversationKey>{
        ...neighborhood,
        ..._initialBatch.where((key) => !_completed.contains(key)),
      };
      // Visible demand may replace distant speculative work, never enlarge
      // the physical/passive preparation window beyond ten conversations.
      final priorities = order
          .take(RecentConversationSession.preparationLimit)
          .toList();
      _failures.removeWhere((key, _) => !priorities.contains(key));
      snapshots.retain(neighborhood.toSet());
      final needed = <RecentConversationKey>[];
      for (final key in priorities) {
        final revision = _snapshotRevision(key);
        // Retain the last usable pixels while refreshing this same identity.
        // record() replaces/disposes them atomically after a completed paint.
        if (_preservesMountedViewport(key) ||
            snapshots.imageFor(key) != null &&
                snapshots.revisionFor(key) == revision ||
            _failures[key] == revision) {
          _completeCard(key);
        } else {
          needed.add(key);
        }
      }
      widget.session.prepare(needed);
      if (!current()) return;
      for (final key in needed) {
        if (!current()) return;
        final index = _indexOf(key);
        final card = widget.session.cardAt(index);
        // In-flight history is admitted in parallel by the session, but never
        // blocks a ready neighboring card's single rendering lane.
        if (card.loading || card.preview == null && card.error == null) {
          continue;
        }
        final revision = _snapshotRevision(key);
        if (card.error != null) {
          _failures[key] = revision;
          _completeCard(key);
          continue;
        }
        _placeholders.remove(key);
        final deadline = Timer(const Duration(seconds: 5), () {
          _failures[key] = revision;
          _completeCard(key);
          if (!cancel.isCompleted) cancel.complete();
          _preparationRequested = true;
        });
        try {
          setState(() => _stagingView = widget.previewBuilder(card));
          // Await the production Markdown worker, then a completed paint.
          // A hidden page is still UI work; each job yields before capture.
          do {
            await Future.any<void>([
              SchedulerBinding.instance.endOfFrame,
              cancel.future,
            ]);
            if (!current()) return;
          } while (_markdownPending(_previewBoundary.currentContext) ||
              _imagesPending(_previewBoundary.currentContext));
          final boundary = _previewBoundary.currentContext?.findRenderObject();
          if (boundary is! RenderRepaintBoundary || !boundary.attached) {
            _failures[key] = revision;
            _completeCard(key);
            continue;
          }
          final ratio = _captureRatio();
          final bytes = _captureBytes(ratio);
          snapshots.reserve(bytes);
          ui.Image? image;
          try {
            image = await boundary.toImage(pixelRatio: ratio);
          } catch (_) {
            // This card is terminal for the batch; other ready cards continue.
          } finally {
            snapshots.release(bytes);
          }
          if (!current() || revision != _snapshotRevision(key)) {
            image?.dispose();
            return;
          }
          if (image != null) {
            snapshots.record(key, image, live: false, revision: revision);
          }
          if (image == null || snapshots.imageFor(key) == null) {
            _failures[key] = revision;
          } else {
            _failures.remove(key);
          }
          _completeCard(key);
          // Only the arriving image changes the stack, never its geometry.
          setState(() => _stagingView = null);
          await Future.any<void>([
            SchedulerBinding.instance.endOfFrame,
            cancel.future,
          ]);
        } finally {
          deadline.cancel();
        }
      }
    } finally {
      _preparing = false;
      if (identical(_preparationCancel, cancel)) _preparationCancel = null;
      if (mounted) {
        setState(() => _stagingView = null);
        if (!_batchPending) _batchTimer?.cancel();
        if (_preparationRequested && _stack) {
          _preparationRequested = false;
          _queueIdleWork();
        }
      }
    }
  }

  bool _markdownPending(BuildContext? subtree) {
    var pending = false;
    void visit(Element element) {
      if (pending) return;
      if (element is StatefulElement &&
          element.state is BackgroundMarkdownContentState &&
          (element.state as BackgroundMarkdownContentState).pending) {
        pending = true;
      } else {
        element.visitChildren(visit);
      }
    }

    if (subtree is Element) subtree.visitChildren(visit);
    return pending;
  }

  double _captureRatio() {
    final slots = RecentConversationSession.preparationLimit + 1;
    var ratio = math.min(
      math.min(
        MediaQuery.devicePixelRatioOf(context),
        1280 / _size.longestSide,
      ),
      // Ten retained images plus one readback fit even in a square viewport.
      math.sqrt(
        _snapshots.byteLimit / (slots * _size.width * _size.height * 4),
      ),
    );
    // Readback rounds both dimensions upward to whole pixels.
    while (_captureBytes(ratio) > _snapshots.byteLimit ~/ slots) {
      ratio *= .999;
    }
    return ratio;
  }

  int _captureBytes(double ratio) =>
      (_size.width * ratio).ceil() * (_size.height * ratio).ceil() * 4;

  Object _snapshotRevision(RecentConversationKey key) =>
      widget.session.cardRevision(key);

  // Keep the genuine viewport while its live subtree is parked beneath cards.
  // The next opening captures its completed real paint with current identity.
  bool _preservesMountedViewport(RecentConversationKey key) =>
      key == widget.chatKey &&
      _snapshots.isLive(key) &&
      _snapshots.imageFor(key) != null;

  bool _imagesPending(BuildContext? subtree) {
    var pending = false;
    void visit(RenderObject object) {
      if (object is RenderImage && object.image == null) pending = true;
      if (!pending) object.visitChildren(visit);
    }

    final object = subtree?.findRenderObject();
    if (object != null) visit(object);
    return pending;
  }

  void _captureLive() {
    if (_snapshots.revisionFor(widget.chatKey) !=
        widget.session.cardRevision(widget.chatKey)) {
      _liveDirty = true;
    }
    if (_liveCapture != null || !_liveDirty || _active || _size.isEmpty) return;
    final boundary = _liveBoundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.attached) return;
    final snapshots = _snapshots;
    final key = widget.chatKey;
    final session = widget.session;
    final environment = _renderEnvironment;
    final insets = _liveInsets;
    final size = _size;
    final revision = session.cardRevision(key);
    final ratio = _captureRatio();
    final bytes = _captureBytes(ratio);
    snapshots.reserve(bytes);
    // Called at gesture/menu admission, while the last completed real paint is
    // still available. Do not wait for a frame that would hide it Offstage.
    final readback = boundary.toImage(pixelRatio: ratio);
    _liveCapture =
        () async {
          ui.Image? image;
          try {
            image = await readback;
          } catch (_) {
            // Missing pixels leave a title card; passive preparation can fill it.
          } finally {
            snapshots.release(bytes);
          }
          if (!mounted ||
              widget.session != session ||
              !session.active ||
              environment != _renderEnvironment ||
              insets != _liveInsets ||
              size != _size ||
              revision != session.cardRevision(key)) {
            image?.dispose();
            return;
          }
          if (image != null) {
            snapshots.record(key, image, live: true, revision: revision);
            if (widget.chatKey == key) _liveDirty = false;
            setState(() {});
          }
        }().whenComplete(() {
          _liveCapture = null;
          _queueIdleWork();
        });
  }

  void _clearCaptures() {
    ++_captureGeneration;
    _endBatch();
    _failures.clear();
    _liveDirty = true;
    _placeholders.clear();
  }

  void _notifyPresentation() {
    widget.onPresentationChanged(_active, _stack);
    _syncCueAdmission();
  }

  void _start(ConversationGestureSample sample) {
    if (!_canGesture ||
        sample.kind == ConversationGestureKind.slide && !_canSlide) {
      return;
    }
    if (_selecting) {
      widget.session.cancelOpening();
      _completeSelection();
      _selecting = false;
    }
    _pausePreparation();
    _idleTimer?.cancel();
    ++_captureGeneration;
    _captureLive();
    final origin = _active
        ? _focusedIndex
        : math.max(0, widget.session.selectedIndex);
    _motion.stop();
    _motion.position += origin - _base;
    _base = origin;
    _startPosition = _lastPosition = _motion.position;
    _velocity = 0;
    _lastMove = sample.timeStamp;
    _gesture = sample.kind;
    _pinchPosition = _motion.position;
    _pinchLift = _motion.lift.clamp(0.0, 1.0);
    setState(() => _active = true);
    if (sample.kind != ConversationGestureKind.pinch) {
      _motion.spring(lift: 1, zoom: 0, reducedMotion: _reduced);
    }
    _notifyPresentation();
    _update(sample);
  }

  void _update(ConversationGestureSample sample) {
    if (_gesture == null || !_active) return;
    if (sample.kind == ConversationGestureKind.pinch) {
      if (_gesture != sample.kind) {
        _pinchPosition = _motion.position;
        _pinchLift = _motion.lift.clamp(0.0, 1.0);
      }
      _gesture = sample.kind;
      _motion.stop();
      final progress = ((1 - sample.scale) / .42).clamp(0.0, 1.12);
      _motion.position = _pinchPosition + sample.delta.dx / _size.width * .1;
      _motion.pinch(_pinchLift + (1 - _pinchLift) * progress, progress);
      return;
    }
    final unit = _size.width * .77;
    var position = _startPosition + sample.delta.dx / unit;
    if (sample.kind == ConversationGestureKind.slide) {
      position = position.clamp(-1.0, 1.0);
    }
    _track(position, sample.timeStamp);
  }

  void _track(double position, Duration? timeStamp) {
    final last = _lastMove;
    final dt = timeStamp != null && last != null
        ? (timeStamp - last).inMicroseconds / 1000000
        : 0.0;
    if (dt > .002) {
      final sample = ((position - _lastPosition) / dt).clamp(-8.0, 8.0);
      _velocity = dt > .1 ? sample : _velocity * .55 + sample * .45;
    }
    _lastMove = timeStamp;
    _lastPosition = position;
    _motion.drag(position, _velocity);
  }

  void _end() {
    final kind = _gesture;
    if (kind == null) return;
    _gesture = null;
    if (kind == ConversationGestureKind.pinch) {
      if (_motion.zoom > .42) {
        openStack();
      } else {
        _returnToChat();
      }
      return;
    }
    final index =
        _motion.position.abs() > .22 / .77 ||
            (_motion.position.abs() > .08 / .77 && _velocity.abs() > 1.2)
        ? _base + (_motion.position.isNegative ? 1 : -1)
        : _base;
    if (index == _base) {
      _returnToChat();
    } else if (!widget.session.modeEnabled) {
      unawaited(_activateSlide(index - _base));
    } else {
      unawaited(_select(index));
    }
  }

  Future<void> _activateSlide(int delta) async {
    final generation = _captureGeneration;
    _motion.stop();
    final ready = widget.session.activate();
    widget.session.setMembershipPaused(false);
    if (widget.session.entries.length < 2) await ready;
    if (!mounted ||
        !widget.session.active ||
        !_active ||
        _stack ||
        _gesture != null ||
        generation != _captureGeneration) {
      return;
    }
    widget.session.setMembershipPaused(false);
    await _select(math.max(0, widget.session.selectedIndex) + delta);
  }

  void _cancel() {
    _gesture = null;
    if (_stack) {
      _settleStack(_motion.position.roundToDouble());
    } else {
      _returnToChat();
    }
  }

  /// Used by the existing overflow menu and accessible alternatives.
  void openStack() {
    if (_selecting ||
        !widget.session.active ||
        widget.session.entries.isEmpty) {
      return;
    }
    if (!_active) {
      _captureLive();
      _base = math.max(0, widget.session.selectedIndex);
      _motion.jump(position: 0, lift: 0, zoom: 0);
    }
    setState(() {
      _active = _stack = true;
      _gesture = null;
    });
    widget.session.setMembershipPaused(true);
    widget.session.activate();
    _beginBatch();
    _openingPreparation = true;
    widget.session.prepareOpeningNeighbors({
      for (final key in _snapshots.keys)
        if (_snapshots.revisionFor(key) == _snapshotRevision(key)) key,
    });
    _settleStack(_motion.position.roundToDouble());
    _notifyPresentation();
  }

  void _settleStack(double position) {
    _motion.spring(
      position: position,
      lift: 1,
      zoom: 1,
      reducedMotion: _reduced,
      settled: () {
        _syncCueAdmission();
        _queueIdleWork();
      },
    );
    _syncCueAdmission();
  }

  bool dismissStack() {
    if (!_stack) return false;
    if (!_selecting) _returnToChat();
    return true;
  }

  void _returnToChat({int? cardIndex}) {
    if (!mounted) return;
    _endBatch();
    _gesture = null;
    final selected = math.max(0, widget.session.selectedIndex);
    final count = widget.session.entries.length;
    final target =
        cardIndex ??
        selected +
            ((_base - _motion.position - selected) / count).round() * count;
    // Circular copies represent the same chat. Expand the tapped copy, or the
    // nearest copy on Back, rather than rewinding every lap the user browsed.
    _motion.position += target - _base;
    _base = target;
    _motion.expand(
      position: 0,
      reducedMotion: _reduced,
      settled: _finishPresentation,
    );
    _syncCueAdmission();
  }

  void _finishPresentation() {
    if (!mounted) return;
    _completeSelection();
    setState(() {
      _active = _stack = _selecting = false;
      _base = math.max(0, widget.session.selectedIndex);
    });
    _motion.jump(position: 0, lift: 0, zoom: 0);
    _notifyPresentation();
    _queueIdleWork();
  }

  Future<void> selectAdjacent(int delta) => _canBrowse
      ? _select(math.max(0, widget.session.selectedIndex) + delta)
      : Future.value();

  Future<void> _select(int index) {
    if (_selecting || !widget.session.active) return Future.value();
    final entry = widget.session.entryAt(index);
    final key = entry.key;
    if (key == widget.session.selected) {
      _returnToChat(cardIndex: index);
      return Future.value();
    }
    if (widget.session.opensRoute(key)) return _selectRoute(key);
    final fromStack = _stack;
    _captureLive();
    _endBatch();
    ++_captureGeneration;
    final completion = _selectionCompletion = Completer<void>();
    final expansion = _expansionCompletion = Completer<void>();
    _selectionChild = widget.child;
    _openingKey = key;
    _paintingSelected = _selectionPainted = _expansionFinished = false;
    _reveal.value = 0;
    setState(() {
      _selecting = _active = true;
      _stack = false;
    });
    _notifyPresentation();
    // Start I/O immediately, but retain the mounted child during pixel motion.
    // Building the selected transcript here can stall the expansion animation.
    _motion.expand(
      position: (_base - index).toDouble(),
      reducedMotion: _reduced,
      settled: () {
        _expansionFinished = true;
        if (!expansion.isCompleted) expansion.complete();
        _tryReveal(completion);
      },
    );
    unawaited(_openSelected(index, fromStack, completion, expansion.future));
    return completion.future;
  }

  Future<void> _selectRoute(RecentConversationKey key) async {
    final fromStack = _stack;
    _endBatch();
    ++_captureGeneration;
    _motion.stop();
    setState(() => _selecting = true);
    _syncCueAdmission();
    final session = widget.session;
    await session.select(key);
    if (!mounted || widget.session != session || !session.active) return;
    setState(() => _selecting = false);
    if (fromStack) {
      _beginBatch();
      _syncCueAdmission();
      _queueIdleWork();
    } else {
      _returnToChat();
    }
  }

  void _tryReveal(Completer<void> completion) {
    if (!mounted ||
        _selectionCompletion != completion ||
        !_expansionFinished ||
        !_selectionPainted ||
        _reveal.isAnimating) {
      return;
    }
    if (_reduced) {
      _finishPresentation();
    } else {
      _reveal.forward().whenCompleteOrCancel(() {
        if (mounted && _selectionCompletion == completion) {
          _finishPresentation();
        }
      });
    }
  }

  Future<void> _openSelected(
    int index,
    bool fromStack,
    Completer<void> completion,
    Future<void> expansion,
  ) async {
    final session = widget.session;
    try {
      if (!mounted || !session.active) return;
      final opened = await session.select(session.entryAt(index).key);
      if (!mounted ||
          !session.active ||
          widget.session != session ||
          _selectionCompletion != completion) {
        return;
      }
      if (!opened) {
        _motion.stop();
        _completeSelection();
        setState(() {
          _selecting = false;
          _stack = fromStack;
        });
        if (fromStack) {
          _beginBatch();
          _settleStack(_motion.position.roundToDouble());
        } else {
          if (widget.session.error case final error?) {
            showStudioError(context, error);
          }
          _returnToChat();
        }
        return;
      }
      await expansion;
      if (!mounted ||
          !session.active ||
          widget.session != session ||
          _selectionCompletion != completion) {
        return;
      }
      setState(() => _paintingSelected = true);
      // The first layout can schedule Markdown/reading-position corrections.
      // Give those a paint frame under the opaque cover before fading it away.
      for (var frame = 0; frame < 2; frame++) {
        await SchedulerBinding.instance.endOfFrame;
        if (!mounted ||
            !session.active ||
            widget.session != session ||
            _selectionCompletion != completion) {
          return;
        }
      }
      _liveDirty = true;
      _selectionPainted = true;
      _tryReveal(completion);
    } finally {
      if ((!mounted || !session.active || widget.session != session) &&
          !completion.isCompleted) {
        completion.complete();
      }
    }
  }

  void _completeSelection() {
    final completion = _selectionCompletion;
    _selectionCompletion = null;
    final expansion = _expansionCompletion;
    _expansionCompletion = null;
    if (expansion != null && !expansion.isCompleted) expansion.complete();
    _selectionChild = null;
    _reveal.stop();
    _reveal.value = 0;
    _openingKey = null;
    _paintingSelected = _selectionPainted = _expansionFinished = false;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  Offset? _browseStart;
  double _browsePosition = 0;
  void _browseDown(DragDownDetails details) {
    if (_selecting) return;
    _pausePreparation();
    _motion.stop();
    _browseStart = details.localPosition;
    _browsePosition = _lastPosition = _motion.position;
    _velocity = 0;
    _lastMove = null;
    _gesture = ConversationGestureKind.slide;
    _syncCueAdmission();
  }

  void _browseUpdate(DragUpdateDetails details) {
    final start = _browseStart;
    if (start == null || _selecting) return;
    final dx = details.localPosition.dx - start.dx;
    _track(_browsePosition + dx / (_size.width * .67), details.sourceTimeStamp);
  }

  void _browseEnd(DragEndDetails details) {
    if (_browseStart == null || _selecting) return;
    _browseStart = null;
    _gesture = null;
    _motion.coast(
      velocity: details.velocity.pixelsPerSecond.dx / (_size.width * .67),
      reducedMotion: _reduced,
      settled: () {
        _syncCueAdmission();
        _queueIdleWork();
      },
    );
    _syncCueAdmission();
  }

  int? _hitCard(Offset point) {
    final candidates = <({int index, double distance, Matrix4 transform})>[];
    final step = -_motion.position.round(), fraction = _motion.position + step;
    for (final offset in _cardOffsets) {
      final relative = offset + fraction;
      candidates.add((
        index: _base + step + offset,
        distance: relative.abs(),
        transform: _cardTransform(relative),
      ));
    }
    candidates.sort((a, b) => a.distance.compareTo(b.distance));
    final centered = point - Offset(_size.width / 2, _size.height / 2);
    for (final candidate in candidates) {
      final inverse = Matrix4.copy(candidate.transform);
      if (inverse.invert() == 0) continue;
      final local = MatrixUtils.transformPoint(inverse, centered);
      if (local.dx.abs() <= _size.width / 2 &&
          local.dy.abs() <= _size.height / 2) {
        return candidate.index;
      }
    }
    return null;
  }

  void _measureFooterAfterLayout() {
    if (_footerMeasurementPending) return;
    _footerMeasurementPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _footerMeasurementPending = false;
      if (!mounted || !_stack) return;
      final footer = _stackFooter.currentContext?.findRenderObject();
      if (footer is! RenderBox || !footer.hasSize) return;
      final height = footer.size.height;
      if ((height - _footerHeight).abs() > .5) {
        setState(() => _footerHeight = height);
      }
    });
  }

  Matrix4 _cardTransform(double relative) {
    final distance = relative.abs().clamp(0.0, 1.5);
    var scale =
        1 -
        _motion.lift * (.14 + .055 * math.min(distance, 1)) -
        _motion.zoom * (.14 + .015 * math.min(distance, 1));
    var vertical =
        _motion.lift * (distance * 8 - 3) +
        _motion.zoom *
            (distance * 7 -
                5 -
                (MediaQuery.accessibleNavigationOf(context) ? 28 : 0));
    if (_footerHeight > 0 && _motion.zoom > 0) {
      final padding = MediaQuery.paddingOf(context);
      final top = padding.top + 72;
      final bottom = padding.bottom + 16 + _footerHeight + 12;
      final fit = ((_size.height - top - bottom) / _size.height).clamp(.2, .72);
      if (fit < .72) {
        final progress = _motion.zoom.clamp(0.0, 1.0);
        scale *= 1 + progress * (fit / .72 - 1);
        vertical =
            vertical * (1 - progress) +
            progress * ((top - bottom) / 2 + distance * 15);
      }
    }
    final pitch = _size.width * (1 - .23 * _motion.lift - .10 * _motion.zoom);
    return Matrix4.identity()
      ..translateByDouble(relative * pitch, vertical, 0, 1)
      ..rotateZ(
        _motion.lift * (relative * 1.3).clamp(-1.4, 1.4) * math.pi / 180,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  Widget _cards() {
    final step = -_motion.position.round(), fraction = _motion.position + step;
    final slots = _cardOffsets
      ..sort((a, b) => (b + fraction).abs().compareTo((a + fraction).abs()));
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final offset in slots)
          Positioned.fill(
            key: ValueKey(_base + step + offset),
            child: Transform(
              alignment: Alignment.center,
              transform: _cardTransform(offset + fraction),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    24 * _motion.lift.clamp(0.0, 1.0),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: .30 * _motion.lift.clamp(0.0, 1.0),
                      ),
                      offset: const Offset(0, 14),
                      blurRadius: 32,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    24 * _motion.lift.clamp(0.0, 1.0),
                  ),
                  child: ExcludeSemantics(
                    child: IgnorePointer(
                      child: _unreadCard(_base + step + offset),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _unreadCard(int index) {
    final entry = widget.session.entryAt(index);
    final content = _cardContent(index);
    if (!entry.unread) return content;
    final t = WingTokens.of(context);
    final tint = t.recentUnreadTint(
      Theme.of(context).colorScheme.primaryContainer,
    );
    final lift = _motion.lift.clamp(0.0, 1.0);
    // Paint over retained pixels; unread changes never invalidate captures or
    // admit preview work. Direct alpha paint avoids an offscreen filter layer.
    return DecoratedBox(
      key: ValueKey((entry.key, 'unread-tint')),
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: tint.a * lift),
        borderRadius: BorderRadius.circular(24 * lift),
        border: Border.all(color: t.recentUnreadBorder.withValues(alpha: lift)),
      ),
      child: content,
    );
  }

  Widget _cardContent(int index) {
    final key = widget.session.entryAt(index).key;
    final capture = _snapshots.imageFor(key);
    final content = _preparedCard(index, key, capture);
    if (key != _openingKey || _snapshots.isLive(key)) return content;
    // An excerpt is useful in a thumbnail, but isn't the normal chat. Fade it
    // into an opening frame instead of magnifying a different transcript.
    final excerptOpacity = _motion.lift.clamp(0.0, 1.0);
    return Stack(
      children: [
        Positioned.fill(
          child: Opacity(opacity: excerptOpacity, child: content),
        ),
        Positioned.fill(
          child: Opacity(
            opacity: 1 - excerptOpacity,
            child: _placeholder(index),
          ),
        ),
      ],
    );
  }

  Widget _preparedCard(
    int index,
    RecentConversationKey key,
    ui.Image? capture,
  ) {
    if (capture != null) {
      return RawImage(
        key: ValueKey((key, 'snapshot')),
        image: capture,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.low,
      );
    }
    return _placeholder(index);
  }

  Widget _placeholder(int index) {
    final card = widget.session.cardAt(index);
    final key = card.entry.key;
    if (_placeholders.length >= 6 && !_placeholders.containsKey(key)) {
      _placeholders.remove(_placeholders.keys.first);
    }
    final revision = (
      card.entry.title,
      card.entry.group,
      card.bot,
      card.groupAppearance,
    );
    final previous = _placeholders[key];
    if (previous?.revision == revision) return previous!.child;
    final child = RepaintBoundary(
      child: ConversationCardPlaceholder(card: card),
    );
    _placeholders[key] = (revision: revision, child: child);
    return child;
  }

  Widget _nudge() {
    final cue = _cue;
    if (cue == null || _reduced) return const SizedBox.shrink();
    final light = Theme.of(context).brightness == Brightness.light;
    final color = cue.kind == ConversationActivityKind.inputNeeded
        ? light
              ? const Color(0xffaa5e1e)
              : const Color(0xfff4b160)
        : light
        ? const Color(0xff2a393f)
        : const Color(0xffe8f7f7);
    return Positioned(
      left: cue.direction == ConversationDirection.left ? 0 : null,
      right: cue.direction == ConversationDirection.right ? 0 : null,
      top: 0,
      bottom: 0,
      width: _size.width * (.25 + 48 / 360),
      child: IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            key: const ValueKey('recent-conversation-nudge'),
            painter: _PondRipplePainter(
              progress: _pulse,
              color: color,
              direction: cue.direction,
              viewportWidth: _size.width,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_stack) _measureFooterAfterLayout();
      if (_size != constraints.biggest) {
        _size = constraints.biggest;
        _clearCaptures();
        if (_stack) _beginBatch();
        _queueIdleWork();
      }
      return RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          ConversationGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                ConversationGestureRecognizer
              >(ConversationGestureRecognizer.new, (recognizer) {
                recognizer.admits = (event) =>
                    _canGesture &&
                    !_stack &&
                    event.position.dx > 24 &&
                    event.position.dx < MediaQuery.sizeOf(context).width - 24 &&
                    (_active || admitsConversationGesture(event));
                recognizer.allowSlide = _canSlide;
                recognizer.onStart = _start;
                recognizer.onUpdate = _update;
                recognizer.onEnd = _end;
                recognizer.onCancel = _cancel;
              }),
        },
        child: Stack(
          children: [
            if (_stagingView case final view?)
              Positioned.fill(
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: ExcludeFocus(
                      child: TickerMode(
                        enabled: false,
                        child: RepaintBoundary(
                          key: _previewBoundary,
                          child: MediaQuery.removeViewInsets(
                            context: context,
                            removeLeft: true,
                            removeTop: true,
                            removeRight: true,
                            removeBottom: true,
                            child: view,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            NotificationListener<ScrollEndNotification>(
              onNotification: (_) {
                _liveDirty = true;
                _queueIdleWork();
                return false;
              },
              child: TickerMode(
                enabled: !_active,
                child: Offstage(
                  offstage: _active && !_paintingSelected,
                  child: RepaintBoundary(
                    key: _liveBoundary,
                    child: ExcludeSemantics(
                      excluding: _active,
                      child: ExcludeFocus(
                        excluding: _active,
                        child: IgnorePointer(
                          ignoring: _active,
                          child: StudioLoadingFrame(
                            child: _selecting && !_paintingSelected
                                ? _selectionChild ?? widget.child
                                : widget.child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_active)
              Positioned.fill(
                child: FadeTransition(
                  opacity: ReverseAnimation(_reveal),
                  child: Material(
                    color: Theme.of(context).brightness == Brightness.light
                        ? const Color(0xffbccac7)
                        : const Color(0xff202c33),
                    child: ClipRect(
                      child: Stack(
                        children: [
                          AnimatedBuilder(
                            animation: _motion,
                            builder: (context, _) => _cards(),
                          ),
                          if (_selecting)
                            PositionedDirectional(
                              top:
                                  MediaQuery.paddingOf(context).top +
                                  WingAppBar.conversationTitleHeight(context),
                              end: 16,
                              child: StudioLoadingFrame(
                                child: StudioPageLoading(
                                  active: true,
                                  label: 'Opening conversation',
                                  child: const StudioLoadingSlot(),
                                ),
                              ),
                            ),
                          if (_stack)
                            Positioned.fill(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onHorizontalDragDown: _canBrowse
                                    ? _browseDown
                                    : null,
                                onHorizontalDragUpdate: _canBrowse
                                    ? _browseUpdate
                                    : null,
                                onHorizontalDragEnd: _canBrowse
                                    ? _browseEnd
                                    : null,
                                onHorizontalDragCancel: !_canBrowse
                                    ? null
                                    : () {
                                        _browseStart = null;
                                        _gesture = null;
                                        _settleStack(
                                          _motion.position.roundToDouble(),
                                        );
                                      },
                                onTapUp: (details) {
                                  final index = _hitCard(details.localPosition);
                                  _gesture = null;
                                  _browseStart = null;
                                  if (index != null && !_selecting) {
                                    unawaited(_select(index));
                                  }
                                },
                              ),
                            ),
                          if (_stack)
                            Positioned(
                              top: MediaQuery.paddingOf(context).top + 8,
                              left: 8,
                              child: StudioButtonPress(
                                child: IconButton.filledTonal(
                                  tooltip: 'Return to conversation',
                                  onPressed: _selecting ? null : _returnToChat,
                                  icon: const Icon(Icons.close),
                                ),
                              ),
                            ),
                          if (_stack)
                            Positioned(
                              bottom: MediaQuery.paddingOf(context).bottom + 16,
                              left: 16,
                              right: 16,
                              child: Column(
                                key: _stackFooter,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.session.catalogError
                                      case final error?)
                                    Row(
                                      children: [
                                        Expanded(child: StudioError(error)),
                                        StudioButtonPress(
                                          child: IconButton(
                                            tooltip: 'Retry recent chats',
                                            onPressed:
                                                widget.session.catalogLoading
                                                ? null
                                                : widget.session.retryCatalog,
                                            icon: const Icon(Icons.refresh),
                                          ),
                                        ),
                                      ],
                                    ),
                                  if (!_selecting &&
                                      widget.session.error != null)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: StudioError(widget.session.error!),
                                    ),
                                  if (!_selecting)
                                    Semantics(
                                      liveRegion: _stack,
                                      label:
                                          '${widget.session.entryAt(_focusedIndex).title}, conversation ${_focusedIndex % widget.session.entries.length + 1} of ${widget.session.entries.length}',
                                      child: Text(
                                        MediaQuery.accessibleNavigationOf(
                                              context,
                                            )
                                            ? (_canBrowse
                                                  ? 'Choose a conversation'
                                                  : _singleCardLabel)
                                            : (_canBrowse
                                                  ? 'Swipe to browse · tap to open'
                                                  : _singleCardLabel),
                                        textAlign: TextAlign.center,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ),
                                  if (MediaQuery.accessibleNavigationOf(
                                    context,
                                  ))
                                    Wrap(
                                      alignment: WrapAlignment.center,
                                      children: [
                                        StudioButtonPress(
                                          child: IconButton(
                                            tooltip: 'Previous conversation',
                                            onPressed: _selecting || !_canBrowse
                                                ? null
                                                : () => _settleStack(
                                                    _motion.position
                                                            .roundToDouble() +
                                                        1,
                                                  ),
                                            icon: const Icon(
                                              Icons.chevron_left,
                                            ),
                                          ),
                                        ),
                                        StudioButtonPress(
                                          child: IconButton(
                                            tooltip: 'Open conversation',
                                            onPressed: _selecting
                                                ? null
                                                : () => _select(_focusedIndex),
                                            icon: const Icon(
                                              Icons.open_in_full,
                                            ),
                                          ),
                                        ),
                                        StudioButtonPress(
                                          child: IconButton(
                                            tooltip: 'Next conversation',
                                            onPressed: _selecting || !_canBrowse
                                                ? null
                                                : () => _settleStack(
                                                    _motion.position
                                                            .roundToDouble() -
                                                        1,
                                                  ),
                                            icon: const Icon(
                                              Icons.chevron_right,
                                            ),
                                          ),
                                        ),
                                      ],
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
            _nudge(),
          ],
        ),
      );
    },
  );

  String get _singleCardLabel =>
      widget.session.catalogLoading || widget.session.catalogError != null
      ? 'Tap to return to conversation'
      : 'No other recent chats.';

  @override
  void dispose() {
    widget.session.setVisible(false);
    widget.session.setInteractive(false, origin: null);
    widget.session.snapshots.removeListener(_snapshotsChanged);
    widget.session.removeListener(_sessionChanged);
    widget.session.nudges.removeListener(_nudgeChanged);
    _motion.removeListener(_motionChanged);
    _motion.dispose();
    _pulse.dispose();
    _clearCaptures();
    _completeSelection();
    _reveal.dispose();
    super.dispose();
  }
}

/// The approved pond study, in its 360 × 800 reference viewport. Ticks repaint
/// only this clipped edge layer; the transcript never rebuilds for the ripples.
class _PondRipplePainter extends CustomPainter {
  _PondRipplePainter({
    required this.progress,
    required this.color,
    required this.direction,
    required this.viewportWidth,
  }) : super(repaint: progress);

  static const duration = Duration(milliseconds: 3800);
  static const _sourceRadius = 1200.0;
  static const _texture = .35;
  static const _intensity = .45;
  static const _spacing = 25.0;
  static const _reach = 360 * .25;
  static const _lifetime = 3.0;
  static const _speed = (_reach + 14) / _lifetime;
  static const _interval = _spacing / _speed;

  final Animation<double> progress;
  final Color color;
  final ConversationDirection direction;
  final double viewportWidth;

  static double _smooth(double value) {
    final t = value.clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0 || t >= 1 || size.isEmpty || viewportWidth <= 0) return;
    final strength =
        (1 - math.pow(1 - (t / .04).clamp(0.0, 1.0), 3)) *
        (1 - _smooth((t - .72) / .28)) *
        _intensity;
    final seconds = t * duration.inMilliseconds / 1000;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (direction == ConversationDirection.right) {
      canvas.translate(size.width, 0);
    }
    canvas.scale(
      viewportWidth / 360 * (direction == ConversationDirection.right ? -1 : 1),
      size.height / 800,
    );

    canvas.save();
    canvas.translate(0, 400);
    canvas.scale(54, 244);
    canvas.drawCircle(
      Offset.zero,
      1,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [
            color.withValues(alpha: .13 * strength),
            color.withValues(alpha: .13 * strength * .62),
            color.withValues(alpha: 0),
          ],
          const [0, .35, 1],
        ),
    );
    canvas.restore();

    final newest = (seconds / _interval).floor();
    final oldest = math.max(0, ((seconds - _lifetime) / _interval).ceil());
    for (var n = oldest; n <= newest; n++) {
      final age = seconds - n * _interval;
      if (age <= 0 || age >= _lifetime) continue;
      final energy =
          _smooth(age / .24) *
          (1 - _smooth((age - .6) / 2.4)) *
          (.92 + .08 * math.sin(n * 2.1)) *
          strength;
      final radius = _sourceRadius - 14 + age * _speed;
      final path = Path();
      for (var i = 0; i <= 96; i++) {
        final y = 100 + i / 96 * 600;
        final dy = y - 400;
        final water =
            _texture *
            (4.5 * math.sin(dy * .019 + seconds * .7) +
                2.4 * math.sin(dy * .041 - seconds * .5 + n * .28) +
                1.2 * math.sin(dy * .083 + seconds * .8 + n * .5));
        final x = math.sqrt(radius * radius - dy * dy) - _sourceRadius + water;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      final colors = <Color>[];
      final stops = <double>[];
      for (var i = 0; i <= 16; i++) {
        final u = i / 16;
        final edge = math.pow(math.sin(math.pi * u), .8);
        final shimmer =
            1 -
            _texture * .16 +
            _texture * .10 * math.sin(u * 19 - seconds * .55 + n * .65) +
            _texture * .06 * math.sin(u * 37 + seconds * .45);
        colors.add(
          color.withValues(alpha: (energy * edge * shimmer).clamp(0.0, 1.0)),
        );
        stops.add(u);
      }
      void stroke(double width, double blur, double opacity) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            // The study's canvas was painted at 2× resolution; CSS filter blur
            // used device pixels while its stroke geometry used logical pixels.
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur / 2)
            ..shader = ui.Gradient.linear(
              const Offset(0, 100),
              const Offset(0, 700),
              colors
                  .map((value) => value.withValues(alpha: value.a * opacity))
                  .toList(),
              stops,
            ),
        );
      }

      stroke(25, 16, .46);
      stroke(9 + math.sin(n * 1.7) * 1.3, 6, .82);
      stroke(3, 3.5, .22);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PondRipplePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.direction != direction ||
      oldDelegate.viewportWidth != viewportWidth;
}
