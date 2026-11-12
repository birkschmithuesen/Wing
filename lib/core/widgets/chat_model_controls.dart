import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../models/chat_intelligence.dart';
import '../presentation/chat_model_labels.dart';
import '../theme/wing_theme.dart';

const _shortEfforts = {
  'none': 'Off',
  'minimal': 'Min',
  'low': 'Low',
  'medium': 'Med',
  'high': 'High',
  'xhigh': 'XHigh',
  'max': 'Max',
  'ultra': 'Ultra',
};
const _effortBadges = {
  'none': '0',
  'minimal': 'm',
  'low': 'L',
  'medium': 'M',
  'high': 'H',
  'xhigh': 'X',
  'max': '+',
  'ultra': 'U',
};

/// A small face inside a full touch target; the level menu appears only on intent.
class ChatReasoningControl extends StatelessWidget {
  const ChatReasoningControl({
    required this.effort,
    required this.onChanged,
    required this.canDisable,
    super.key,
  });
  final String effort;
  final bool canDisable;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    return Builder(
      builder: (anchor) => StudioButtonPress(
        child: IconButton(
          key: const Key('chat-reasoning-control'),
          style: IconButton.styleFrom(
            minimumSize: const Size(36, 36),
            padding: const EdgeInsets.all(2),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.standard,
          ),
          tooltip: 'Reasoning: ${chatReasoningEffortLabel(effort)}',
          onPressed: onChanged == null
              ? null
              : () async {
                  final box = anchor.findRenderObject() as RenderBox;
                  final origin = box.localToGlobal(Offset.zero);
                  final size = MediaQuery.sizeOf(context);
                  final scale = MediaQuery.textScalerOf(context).scale(1);
                  final width = math.min(
                    scale > 1.3 ? 272.0 : 218.0,
                    size.width - 16,
                  );
                  final height = math.max(108.0, 108 * scale / 1.5);
                  final left = (origin.dx - 8).clamp(
                    8.0,
                    math.max(8.0, size.width - width - 8),
                  );
                  final top = origin.dy >= height + 8
                      ? origin.dy - height - 4
                      : origin.dy + box.size.height + 4;
                  final value = await showDialog<String>(
                    context: context,
                    barrierColor: Colors.transparent,
                    builder: (menuContext) => Stack(
                      children: [
                        Positioned(
                          left: left.toDouble(),
                          top: top.toDouble().clamp(
                            8.0,
                            math.max(8.0, size.height - height - 8),
                          ),
                          width: width,
                          child: Material(
                            key: const Key('reasoning-menu'),
                            elevation: 0,
                            color: tokens.raised,
                            shape: RoundedRectangleBorder(
                              borderRadius: WingRadius.card,
                              side: BorderSide(color: tokens.border),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: FocusTraversalGroup(
                                child: Wrap(
                                  children: [
                                    for (final entry in _shortEfforts.entries)
                                      if (canDisable || entry.key != 'none')
                                        SizedBox(
                                          width: (width - 8) / 4,
                                          height: (height - 8) / 2,
                                          child: Semantics(
                                            selected: entry.key == effort,
                                            label:
                                                'Reasoning ${chatReasoningEffortLabel(entry.key)}',
                                            child: Tooltip(
                                              message: chatReasoningEffortLabel(
                                                entry.key,
                                              ),
                                              child: StudioButtonPress(
                                                child: TextButton(
                                                  key: Key(
                                                    'reasoning-${entry.key}',
                                                  ),
                                                  autofocus:
                                                      entry.key == effort,
                                                  style: TextButton.styleFrom(
                                                    padding: EdgeInsets.zero,
                                                    minimumSize: const Size(
                                                      48,
                                                      48,
                                                    ),
                                                    foregroundColor:
                                                        entry.key == effort
                                                        ? tokens.accent
                                                        : tokens.onSurface,
                                                    backgroundColor:
                                                        entry.key == effort
                                                        ? tokens.accent
                                                              .withValues(
                                                                alpha: 0.12,
                                                              )
                                                        : Colors.transparent,
                                                    textStyle:
                                                        tokens.typography.label,
                                                  ),
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                        menuContext,
                                                        entry.key,
                                                      ),
                                                  child: Text(
                                                    scale > 1.3 &&
                                                            entry.key == 'xhigh'
                                                        ? 'XHi'
                                                        : entry.value,
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
                        ),
                      ],
                    ),
                  );
                  if (value != null) onChanged?.call(value);
                },
          icon: SizedBox.square(
            dimension: 32,
            child: Stack(
              children: [
                Center(
                  child: CircuitBrainIcon(
                    color: onChanged == null ? tokens.muted : tokens.accent,
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: tokens.raised,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      _effortBadges[effort] ?? '',
                      style: tokens.typography.label.copyWith(
                        fontSize: 10,
                        color: tokens.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatFastControl extends StatelessWidget {
  const ChatFastControl({
    required this.mode,
    required this.onChanged,
    this.showLabel = false,
    super.key,
  });
  final ChatFastMode mode;
  final ValueChanged<ChatFastMode>? onChanged;
  final bool showLabel;
  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final icon = Icon(
      mode.enabled ? Icons.bolt : Icons.bolt_outlined,
      size: 22,
    );
    void toggle() =>
        onChanged?.call(mode.enabled ? ChatFastMode.normal : ChatFastMode.fast);
    final style = TextButton.styleFrom(
      minimumSize: const Size(36, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      foregroundColor: mode.enabled ? tokens.accent : tokens.muted,
      backgroundColor: mode.enabled
          ? tokens.accent.withValues(alpha: 0.12)
          : Colors.transparent,
    );
    return Tooltip(
      message: 'Fast: ${mode.enabled ? 'On' : 'Off'}',
      child: Semantics(
        toggled: mode.enabled,
        label: 'Fast mode',
        child: StudioButtonPress(
          child: TextButton(
            key: const Key('chat-fast-control'),
            onPressed: onChanged == null ? null : toggle,
            style: style,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                if (showLabel)
                  Text(
                    mode.enabled ? 'On' : 'Off',
                    style: tokens.typography.label,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Matches Send's held-pointer gesture: preview while sliding, commit on lift.
/// The picker keeps its separate tap menu; this compact face belongs to composer.
class ChatReasoningScrubControl extends StatefulWidget {
  const ChatReasoningScrubControl({
    required this.effort,
    required this.canDisable,
    required this.onChanged,
    super.key,
  });
  final String effort;
  final bool canDisable;
  final ValueChanged<String>? onChanged;
  @override
  State<ChatReasoningScrubControl> createState() =>
      _ChatReasoningScrubControlState();
}

class _ChatReasoningScrubControlState extends State<ChatReasoningScrubControl>
    with WidgetsBindingObserver {
  final _anchorKey = GlobalKey();
  OverlayEntry? _overlay;
  Rect _anchor = Rect.zero;
  Rect _choices = Rect.zero;
  String? _selected;
  RawDialogRoute<void>? _menuRoute;
  VoidCallback? _rebuildMenu;

  List<String> get _efforts => [
    for (final value in _shortEfforts.keys)
      if (widget.canDisable || value != 'none') value,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(ChatReasoningScrubControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effort != widget.effort ||
        oldWidget.canDisable != widget.canDisable ||
        (oldWidget.onChanged == null) != (widget.onChanged == null)) {
      _close();
    }
  }

  @override
  void didChangeMetrics() => _close();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _close();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _close();
    super.dispose();
  }

  void _close() {
    _overlay?.remove();
    _overlay?.dispose();
    _overlay = null;
    _selected = null;
    final route = _menuRoute;
    _menuRoute = null;
    _rebuildMenu = null;
    if (route != null) {
      HardwareKeyboard.instance.removeHandler(_dismissKey);
      void dismiss() {
        if (route.isActive) route.navigator?.removeRoute(route);
      }

      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
      } else {
        dismiss();
      }
    }
  }

  bool _dismissKey(KeyEvent event) {
    if (_menuRoute == null ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    _close();
    return true;
  }

  void _openMenu() => _open(interactive: true);

  void _openHeld(LongPressStartDetails _) => _open();

  void _open({bool interactive = false, bool keyboard = false}) {
    if (_overlay != null || _menuRoute != null || widget.onChanged == null) {
      return;
    }
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject()! as RenderBox;
    final box = _anchorKey.currentContext!.findRenderObject()! as RenderBox;
    _anchor = box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final width = math.min(
      scale > 1.3 ? 88.0 : 64.0,
      overlayBox.size.width - 16,
    );
    final left = (_anchor.center.dx - width / 2).clamp(
      8.0,
      math.max(8.0, overlayBox.size.width - width - 8),
    );
    final bottom = _anchor.top - 8;
    final height = math.min(
      _efforts.length * 32.0 * scale,
      bottom - MediaQuery.paddingOf(context).top - 8,
    );
    if (height <= 0) return;
    _choices = Rect.fromLTWH(left.toDouble(), bottom - height, width, height);
    _selected = widget.effort;
    if (interactive) {
      final themes = InheritedTheme.capture(from: context, to: overlay.context);
      final route = RawDialogRoute<void>(
        pageBuilder: (context, _, _) => themes.wrap(
          StatefulBuilder(
            builder: (context, setState) {
              _rebuildMenu = () => setState(() {});
              return Focus(
                autofocus: keyboard,
                onKeyEvent: _menuKey,
                child: _buildSelector(context, interactive: true),
              );
            },
          ),
        ),
        barrierColor: Colors.transparent,
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        requestFocus: keyboard,
        transitionDuration: Duration.zero,
      );
      _menuRoute = route;
      HardwareKeyboard.instance.addHandler(_dismissKey);
      Navigator.of(context).push(route).then((_) {
        if (identical(_menuRoute, route)) {
          HardwareKeyboard.instance.removeHandler(_dismissKey);
          _menuRoute = null;
          _rebuildMenu = null;
          _selected = null;
        }
      });
    } else {
      _overlay = OverlayEntry(
        builder: (_) => InheritedTheme.captureAll(
          context,
          Builder(builder: _buildSelector),
        ),
      );
      overlay.insert(_overlay!);
    }
    HapticFeedback.selectionClick();
  }

  void _choose(String? selected) {
    final canApply = _overlay != null || _menuRoute != null;
    _close();
    if (canApply &&
        selected != null &&
        selected != widget.effort &&
        _efforts.contains(selected)) {
      widget.onChanged?.call(selected);
    }
  }

  KeyEventResult _menuKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
    } else if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _choose(_selected);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final index = _efforts.indexOf(_selected ?? widget.effort);
      final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
      _selected = _efforts[(index + delta).clamp(0, _efforts.length - 1)];
      _rebuildMenu?.call();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _buildSelector(BuildContext context, {bool interactive = false}) {
    final tokens = WingTokens.of(context);
    return IgnorePointer(
      ignoring: !interactive,
      child: Stack(
        children: [
          Positioned(
            left: _choices.left,
            top: _choices.top,
            width: _choices.width,
            height: _choices.height,
            child: Material(
              key: const Key('composer-reasoning-selector'),
              color: tokens.raised,
              shape: RoundedRectangleBorder(
                borderRadius: WingRadius.control,
                side: BorderSide(color: tokens.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final effort in _efforts)
                    Expanded(
                      child: Semantics(
                        button: interactive,
                        selected: _selected == effort,
                        child: StudioButtonPress(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: interactive ? () => _choose(effort) : null,
                            child: Container(
                              key: Key('composer-reasoning-choice-$effort'),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: _selected == effort
                                    ? tokens.accent.withValues(alpha: .12)
                                    : Colors.transparent,
                                borderRadius: WingRadius.control,
                              ),
                              child: Text(
                                _shortEfforts[effort]!,
                                style: tokens.typography.label.copyWith(
                                  color: _selected == effort
                                      ? tokens.accent
                                      : tokens.onSurface,
                                ),
                                semanticsLabel: chatReasoningEffortLabel(
                                  effort,
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
          ),
        ],
      ),
    );
  }

  void _move(LongPressMoveUpdateDetails details) {
    if (_overlay == null) return;
    final overlayBox =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlayBox.globalToLocal(details.globalPosition);
    String? next;
    if (_choices.contains(point)) {
      final index =
          ((point.dy - _choices.top) / _choices.height * _efforts.length)
              .floor()
              .clamp(0, _efforts.length - 1);
      next = _efforts[index];
    } else if (Rect.fromLTRB(
      _anchor.left - 8,
      _choices.bottom,
      _anchor.right + 8,
      _anchor.bottom + 8,
    ).contains(point)) {
      next = widget.effort;
    }
    if (_selected != next) {
      _selected = next;
      _overlay!.markNeedsBuild();
      HapticFeedback.selectionClick();
    }
  }

  void _release(LongPressEndDetails _) => _choose(_selected);

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    return Semantics(
      button: true,
      label: 'Reasoning ${chatReasoningEffortLabel(widget.effort)}',
      hint:
          'Tap to choose a level, or hold and slide, then release. Slide away to cancel. Keyboard: Down arrow opens levels.',
      onTap: widget.onChanged == null ? null : _openMenu,
      onLongPress: widget.onChanged == null ? null : _openMenu,
      customSemanticsActions: {
        if (widget.onChanged != null)
          for (final effort in _efforts)
            CustomSemanticsAction(
              label: chatReasoningEffortLabel(effort),
            ): () =>
                widget.onChanged?.call(effort),
      },
      child: Focus(
        canRequestFocus: widget.onChanged != null,
        skipTraversal: widget.onChanged == null,
        onKeyEvent: (_, event) {
          if (widget.onChanged != null &&
              event is KeyDownEvent &&
              [
                LogicalKeyboardKey.arrowDown,
                LogicalKeyboardKey.contextMenu,
                LogicalKeyboardKey.enter,
                LogicalKeyboardKey.space,
              ].contains(event.logicalKey)) {
            _open(interactive: true, keyboard: true);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: StudioButtonPress(
          child: GestureDetector(
            key: const Key('composer-reasoning-control'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onChanged == null ? null : _openMenu,
            onLongPressStart: widget.onChanged == null ? null : _openHeld,
            onLongPressMoveUpdate: _move,
            onLongPressEnd: _release,
            onLongPressCancel: _close,
            child: ExcludeSemantics(
              child: SizedBox(
                key: _anchorKey,
                height: 32,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 14,
                        child: CircuitBrainIcon(color: tokens.muted),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        compactChatReasoningLabel(widget.effort),
                        style: tokens.typography.label.copyWith(
                          fontSize: 12,
                          height: 1.25,
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
  }
}

/// Circuit brain stroke artwork, following the existing Lucide icon language.
class CircuitBrainIcon extends StatelessWidget {
  const CircuitBrainIcon({required this.color, super.key});
  final Color color;
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(22),
    painter: _CircuitBrainPainter(color),
  );
}

class _CircuitBrainPainter extends CustomPainter {
  _CircuitBrainPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(12, 5)
      ..cubicTo(12, 1, 6, 1, 6, 5.125)
      ..cubicTo(2, 5, 1, 8.5, 3.477, 10.896)
      ..cubicTo(0, 13, 1, 16, 4.033, 17.484)
      ..cubicTo(3, 23, 12, 24, 12, 18)
      ..close()
      ..moveTo(9, 13)
      ..cubicTo(11, 12.5, 12, 10.5, 12, 9)
      ..moveTo(6.003, 5.125)
      ..lineTo(6.401, 6.5)
      ..moveTo(3.477, 10.896)
      ..lineTo(4.062, 10.5)
      ..moveTo(6, 18)
      ..lineTo(4.033, 17.484)
      ..moveTo(12, 13)
      ..lineTo(16, 13)
      ..moveTo(12, 18)
      ..lineTo(18, 18)
      ..quadraticBezierTo(20, 18, 20, 20)
      ..lineTo(20, 21)
      ..moveTo(12, 8)
      ..lineTo(20, 8)
      ..moveTo(16, 8)
      ..lineTo(16, 5)
      ..quadraticBezierTo(16, 3, 18, 3);
    canvas.drawPath(path, pen);
    for (final point in [
      const Offset(16, 13),
      const Offset(18, 3),
      const Offset(20, 21),
      const Offset(20, 8),
    ]) {
      canvas.drawCircle(point, 0.5, pen);
    }
  }

  @override
  bool shouldRepaint(_CircuitBrainPainter oldDelegate) =>
      oldDelegate.color != color;
}
