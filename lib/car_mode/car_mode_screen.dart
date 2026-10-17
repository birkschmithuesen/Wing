import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/theme/profile_workspace_theme.dart';
import '../core/theme/wing_theme.dart';
import 'car_mode_palette.dart';
import 'car_mode_session.dart';
import 'car_mode_state.dart';

/// Fullscreen car mode: the whole screen is one button over the open chat
/// (spec §4). Android Back pops the route; the session leaves on pop.
class CarModeScreen extends StatefulWidget {
  const CarModeScreen({super.key, required this.session});
  final CarModeSession session;

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

class _CarModeScreenState extends State<CarModeScreen> {
  static const _hintFor = Duration(seconds: 6);
  bool _hint = true;
  Timer? _hintTimer;
  double _dragDx = 0;

  @override
  void initState() {
    super.initState();
    _hintTimer = Timer(_hintFor, () {
      if (mounted) setState(() => _hint = false);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The pushed route sits outside the workspace's accent theme.
    final theme = profileWorkspaceTheme(
      Theme.of(context),
      accent: WorkspaceAccent.fromName(
        widget.session.bridge.preferences.getString(WorkspaceAccent.preferenceKey),
      ),
    );
    return Theme(
      data: theme,
      child: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => _page(context),
      ),
    );
  }

  Widget _page(BuildContext context) {
    final tokens = WingTokens.of(context);
    final session = widget.session;
    final snap = session.snapshot;
    final phase = session.phase;
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final width = MediaQuery.sizeOf(context).width;
    final colors = carColorsFor(phase, tokens, Theme.of(context).brightness);
    final text = carTextFor(phase, snap);
    final status = carStatusLine(phase, snap);
    final connection = carConnectionText(snap.connection);
    return Scaffold(
      backgroundColor: tokens.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Semantics(
            button: true,
            liveRegion: true,
            label: [text.label, text.detail, text.hint, status, connection.label]
                .whereType<String>()
                .join('. '),
            hint: 'Swipe sideways to leave car mode',
            excludeSemantics: true,
            onTap: session.tap,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragUpdate: (details) =>
                  setState(() => _dragDx += details.primaryDelta ?? 0),
              onHorizontalDragEnd: (details) {
                final exits = carSwipeExits(
                  dx: _dragDx,
                  velocity: details.primaryVelocity ?? 0,
                  width: width,
                );
                setState(() => _dragDx = 0);
                session.swiped(exits: exits);
              },
              onHorizontalDragCancel: () => setState(() => _dragDx = 0),
              child: Material(
                key: const ValueKey('car-button'),
                color: colors.fill,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: colors.border == null
                      ? BorderSide.none
                      : BorderSide(color: colors.border!, width: 4),
                ),
                child: InkWell(
                  onTap: session.tap,
                  child: Transform.translate(
                    offset: Offset(_dragDx * .35, 0),
                    child: Padding(
                      padding: landscape
                          ? const EdgeInsets.fromLTRB(20, 16, 20, 12)
                          : const EdgeInsets.fromLTRB(20, 20, 20, 16),
                      child: _content(context, phase, snap, colors, text, status, landscape, width),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    CarPhase phase,
    CarSnapshot snap,
    CarColors colors,
    CarText text,
    String? status,
    bool landscape,
    double width,
  ) {
    final tokens = WingTokens.of(context);
    final badge = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: landscape ? 260 : width * .6),
      child: _Badge(connection: snap.connection, colors: carBadgeColorsFor(snap.connection, tokens)),
    );
    final title = Text(
      snap.title ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
      style: TextStyle(fontSize: 16, color: colors.hint),
    );
    final statusLine = _fitLine(
      Text(
        status ?? '',
        key: const ValueKey('car-status'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: landscape ? 30 : 34,
          fontWeight: FontWeight.w600,
          height: 1.25,
          color: colors.label,
        ),
      ),
    );
    final hint = _hint
        ? Row(
            key: const ValueKey('car-swipe-hint'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.swap_horiz, size: 22, color: colors.hint),
              const SizedBox(width: 8),
              Text('Swipe to leave', style: TextStyle(fontSize: 16, color: colors.hint)),
            ],
          )
        : null;
    final centre = LayoutBuilder(
      builder: (context, box) => Center(
        // Enlarged text scales down instead of overflowing the button.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: _centre(phase, colors, text, landscape, box.maxWidth),
        ),
      ),
    );
    final loopSwitch = _LoopSwitch(session: widget.session, colors: colors);
    if (landscape) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 56,
            child: Row(
              children: [
                badge,
                const SizedBox(width: 16),
                Expanded(child: statusLine),
                const SizedBox(width: 16),
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: title),
                loopSwitch,
              ],
            ),
          ),
          Expanded(child: centre),
          SizedBox(height: 24, child: FittedBox(fit: BoxFit.scaleDown, child: hint)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 56,
          child: Row(
            children: [badge, const SizedBox(width: 12), Expanded(child: title), loopSwitch],
          ),
        ),
        const SizedBox(height: 28),
        SizedBox(height: 48, child: statusLine),
        Expanded(child: centre),
        SizedBox(height: 28, child: FittedBox(fit: BoxFit.scaleDown, child: hint)),
      ],
    );
  }

  /// One line: ellipsised to the width, scaled down to the slot height.
  Widget _fitLine(Text text) => LayoutBuilder(
    builder: (context, box) => Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth), child: text),
      ),
    ),
  );

  Widget _centre(CarPhase phase, CarColors colors, CarText text, bool landscape, double maxWidth) {
    final iconSize = landscape ? 112.0 : 120.0;
    final icon = SizedBox.square(
      dimension: iconSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (phase == CarPhase.listening) _Pulse(color: colors.label),
          Icon(carIconFor(phase), size: iconSize * .8, color: colors.label),
        ],
      ),
    );
    final align = landscape ? TextAlign.start : TextAlign.center;
    final texts = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: landscape ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(
          text.label,
          textAlign: align,
          style: TextStyle(
            fontSize: landscape ? 40 : 44,
            fontWeight: FontWeight.w600,
            height: 1.1,
            color: colors.label,
          ),
        ),
        if (text.detail != null) ...[
          const SizedBox(height: 10),
          Text(text.detail!, textAlign: align, style: TextStyle(fontSize: 20, color: colors.hint)),
        ],
        if (text.hint != null) ...[
          const SizedBox(height: 10),
          Text(text.hint!, textAlign: align, style: TextStyle(fontSize: 22, color: colors.hint)),
        ],
      ],
    );
    if (landscape) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 36),
          ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth * .6), child: texts),
        ],
      );
    }
    return SizedBox(
      width: maxWidth,
      child: Column(mainAxisSize: MainAxisSize.min, children: [icon, const SizedBox(height: 18), texts]),
    );
  }
}

/// Large coloured connection state, readable from the corner of the eye.
class _Badge extends StatelessWidget {
  const _Badge({required this.connection, required this.colors});
  final CarConnection connection;
  final CarBadgeColors colors;

  @override
  Widget build(BuildContext context) {
    final text = carConnectionText(connection);
    return Container(
      key: const ValueKey('car-connection'),
      height: 56,
      padding: const EdgeInsets.fromLTRB(14, 0, 18, 0),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: colors.foreground, width: 3),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(text.icon, size: 28, color: colors.foreground),
            const SizedBox(width: 8),
            Text(
              text.label,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: colors.foreground),
            ),
          ],
        ),
      ),
    );
  }
}

/// Session-local conversation-mode switch, docked at the status row's edge
/// so a normal tap on the big button never reaches it (spec §4). Its own
/// gesture recognizer wins the arena before the big GestureDetector's.
class _LoopSwitch extends StatelessWidget {
  const _LoopSwitch({required this.session, required this.colors});
  final CarModeSession session;
  final CarColors colors;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Conversation mode for this session',
    toggled: session.loopOn,
    child: Switch(
      key: const ValueKey('car-loop-switch'),
      value: session.loopOn,
      activeThumbColor: colors.label,
      onChanged: session.setLoop,
    ),
  );
}

/// "Microphone is live" ring; exists only while listening. Static with
/// reduced motion.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.color});
  final Color color;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = .35;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final t = _controller.value;
      return Transform.scale(
        scale: .7 + .55 * t,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: widget.color.withValues(alpha: .55 * (1 - t)), width: 6),
          ),
          child: const SizedBox.expand(),
        ),
      );
    },
  );
}
