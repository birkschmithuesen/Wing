import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/context_occupancy.dart';
import '../theme/wing_theme.dart';

/// Session-owned occupancy and composition, independent of task progress.
class ContextRing extends StatefulWidget {
  const ContextRing({
    super.key,
    this.occupancy,
    this.compressions,
    this.loading = false,
    this.error,
    this.onRefresh,
  });

  final ContextOccupancy? occupancy;
  final int? compressions;
  final bool loading;
  final String? error;
  final VoidCallback? onRefresh;

  @override
  State<ContextRing> createState() => _ContextRingState();
}

class _ContextRingState extends State<ContextRing>
    with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _anchor = GlobalKey();
  final _buttonFocus = FocusNode();
  late final AnimationController _animation;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(vsync: this, duration: WingMotion.fast)
      ..addStatusListener((status) {
        if (status == AnimationStatus.dismissed) {
          _portal.hide();
          if (mounted) setState(() {});
        }
      });
  }

  @override
  void dispose() {
    _animation.dispose();
    _buttonFocus.dispose();
    super.dispose();
  }

  void _close() => _animation.reverse();

  void _toggle() {
    _animation.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : WingMotion.fast;
    if (_portal.isShowing && _animation.status != AnimationStatus.reverse) {
      _close();
    } else {
      _portal.show();
      setState(() {});
      _animation.forward();
      widget.onRefresh?.call();
    }
  }

  Widget _details(BuildContext context, Color color) {
    final tokens = WingTokens.of(context);
    final media = MediaQuery.of(context);
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return const SizedBox.shrink();
    final origin = box.localToGlobal(Offset.zero);
    final width = math.min(320.0, media.size.width - WingSpacing.lg * 2);
    final left = origin.dx.clamp(
      WingSpacing.lg,
      math.max(WingSpacing.lg, media.size.width - WingSpacing.lg - width),
    );
    final value = widget.occupancy;
    final numbers = MaterialLocalizations.of(context);
    final categories = value?.categories ?? const <ContextCategory>[];
    final labelStyle = tokens.typography.label.copyWith(
      color: tokens.onSurface,
      fontSize: 13,
      letterSpacing: 0,
    );
    return Positioned.fill(
      child: Stack(
        children: [
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: Offset(left - origin.dx, -WingSpacing.sm),
            child: TextFieldTapRegion(
              child: TapRegion(
                groupId: _link,
                onTapOutside: (_) => _close(),
                child: FadeTransition(
                  opacity: _animation,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: math.max(
                        0,
                        origin.dy -
                            media.padding.top -
                            WingSpacing.lg -
                            WingSpacing.sm,
                      ),
                    ),
                    child: SizedBox(
                      width: width,
                      child: Material(
                        key: const ValueKey('context-usage-popover'),
                        color: tokens.raised,
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: WingRadius.card,
                          side: BorderSide(color: tokens.border),
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(
                            WingSpacing.md,
                            0,
                            WingSpacing.md,
                            WingSpacing.md,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Context window',
                                      style: labelStyle.copyWith(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  SizedBox.square(
                                    dimension: 24,
                                    child: widget.loading
                                        ? Semantics(
                                            label: 'Loading context breakdown',
                                            child: Center(
                                              child: SizedBox.square(
                                                dimension: 16,
                                                child: media.disableAnimations
                                                    ? Icon(
                                                        Icons.hourglass_top,
                                                        size: 16,
                                                        color: tokens.muted,
                                                      )
                                                    : const CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                              ),
                                            ),
                                          )
                                        : null,
                                  ),
                                  StudioButtonPress(
                                    child: IconButton(
                                      tooltip: 'Close context window',
                                      onPressed: _close,
                                      icon: const Icon(Icons.close, size: 18),
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(
                                width: double.infinity,
                                child: Wrap(
                                  alignment: WrapAlignment.spaceBetween,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: WingSpacing.sm,
                                  runSpacing: WingSpacing.xs,
                                  children: [
                                    Text(
                                      value == null
                                          ? 'Context usage unknown'
                                          : '${value.estimated ? '~' : ''}${value.percent.round()}% full',
                                      style: tokens.typography.label.copyWith(
                                        color: color,
                                        letterSpacing: 0,
                                      ),
                                    ),
                                    if (value != null)
                                      Text(
                                        '${numbers.formatDecimal(value.used)} / ${numbers.formatDecimal(value.max)}${value.pinned ? ' (pinned)' : ''}',
                                        style: tokens.typography.label.copyWith(
                                          color: tokens.muted,
                                          letterSpacing: 0,
                                          fontFeatures: const [
                                            ui.FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: WingSpacing.md),
                              if (categories.isNotEmpty) ...[
                                _CompositionBar(categories: categories),
                                const SizedBox(height: WingSpacing.md),
                                for (final category in categories)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: WingSpacing.sm,
                                    ),
                                    child: _ContextCategoryRow(
                                      category: category,
                                      style: labelStyle,
                                      numbers: numbers,
                                    ),
                                  ),
                              ] else if (!widget.loading &&
                                  widget.error == null)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: WingSpacing.sm,
                                  ),
                                  child: Text(
                                    value == null
                                        ? 'Context usage is unavailable for this chat.'
                                        : 'No composition breakdown available yet.',
                                    style: labelStyle.copyWith(
                                      color: tokens.muted,
                                    ),
                                  ),
                                ),
                              if (widget.error != null && !widget.loading)
                                Text(
                                  widget.error!,
                                  style: labelStyle.copyWith(
                                    color: tokens.muted,
                                  ),
                                ),
                              if (widget.error != null &&
                                  !widget.loading &&
                                  widget.onRefresh != null)
                                StudioButtonPress(
                                  child: IconButton(
                                    onPressed: widget.onRefresh,
                                    tooltip: 'Retry context breakdown',
                                    icon: const Icon(Icons.refresh),
                                  ),
                                ),
                              if (value != null ||
                                  widget.compressions != null) ...[
                                Divider(height: WingSpacing.md),
                                SizedBox(
                                  width: double.infinity,
                                  child: Wrap(
                                    alignment: WrapAlignment.spaceBetween,
                                    spacing: WingSpacing.sm,
                                    runSpacing: WingSpacing.xs,
                                    children: [
                                      Text(
                                        categories.isEmpty
                                            ? 'Tokens'
                                            : 'Estimated tokens',
                                        style: tokens.typography.label.copyWith(
                                          fontSize: 11,
                                          color: tokens.muted,
                                          letterSpacing: 0,
                                        ),
                                      ),
                                      if (widget.compressions case final count?)
                                        Text.rich(
                                          TextSpan(
                                            children: [
                                              WidgetSpan(
                                                alignment: ui
                                                    .PlaceholderAlignment
                                                    .middle,
                                                child: Icon(
                                                  Icons.layers_outlined,
                                                  size: 13,
                                                  color: tokens.muted,
                                                ),
                                              ),
                                              TextSpan(
                                                text:
                                                    ' $count ${count == 1 ? 'compression' : 'compressions'}',
                                              ),
                                            ],
                                          ),
                                          style: tokens.typography.label
                                              .copyWith(
                                                fontSize: 11,
                                                color: tokens.muted,
                                                letterSpacing: 0,
                                              ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.occupancy;
    final tokens = WingTokens.of(context);
    final label = value == null
        ? 'Context usage unknown'
        : '${value.estimated ? 'Approximately ' : ''}${value.used} of ${value.max} tokens, ${value.percent.round()} percent used';
    final color = value == null
        ? tokens.muted
        : value.percent >= 85
        ? tokens.danger
        : value.percent >= 65
        ? tokens.warning
        : tokens.accent;
    final scaler = MediaQuery.textScalerOf(context);
    final diameter = scaler.scale(32).clamp(32.0, 40.0);

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              if (_portal.isShowing) _close();
              return null;
            },
          ),
        },
        child: TextFieldTapRegion(
          child: TapRegion(
            groupId: _link,
            child: OverlayPortal(
              controller: _portal,
              overlayChildBuilder: (context) => _details(context, color),
              child: Tooltip(
                message: label,
                excludeFromSemantics: true,
                child: Semantics(
                  label: label,
                  button: true,
                  onTap: _toggle,
                  excludeSemantics: true,
                  expanded: _portal.isShowing,
                  child: StudioButtonPress(
                    child: IconButton(
                      key: const ValueKey('context-ring-details'),
                      padding: const EdgeInsets.all(WingSpacing.xs),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      focusNode: _buttonFocus,
                      onPressed: _toggle,
                      icon: CompositedTransformTarget(
                        key: _anchor,
                        link: _link,
                        child: CustomPaint(
                          key: const ValueKey('context-ring-paint'),
                          size: Size.square(diameter),
                          painter: ContextRingPainter(
                            progress: value == null
                                ? null
                                : value.percent.clamp(0, 100) / 100,
                            color: color,
                            track: tokens.muted.withValues(alpha: .5),
                            label: value == null
                                ? '—'
                                : '${value.percent.round()}%',
                            labelColor: tokens.onSurface,
                            labelFontSize: scaler.scale(10),
                          ),
                        ),
                      ),
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
}

Color _categoryColor(String id, WingTokens tokens) => switch (id) {
  'system_prompt' => const Color(0xFFFB5375),
  'tool_definitions' => const Color(0xFF8C80EE),
  'rules' => const Color(0xFFFFB547),
  'skills' => const Color(0xFFCC80CE),
  'mcp' => const Color(0xFF67C1CA),
  'subagent_definitions' => const Color(0xFF45CA87),
  'memory' => const Color(0xFFEDCE46),
  'conversation' => const Color(0xFF419AF6),
  _ => tokens.muted,
};

class _ContextCategoryRow extends StatelessWidget {
  const _ContextCategoryRow({
    required this.category,
    required this.style,
    required this.numbers,
  });

  final ContextCategory category;
  final TextStyle style;
  final MaterialLocalizations numbers;

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final label = Text(
      category.label,
      style: style.copyWith(color: tokens.muted),
    );
    final count = Semantics(
      label: 'Approximately ${numbers.formatDecimal(category.tokens)} tokens',
      excludeSemantics: true,
      child: Text(
        '~${numbers.formatDecimal(category.tokens)}',
        style: style.copyWith(
          fontFeatures: const [ui.FontFeature.tabularFigures()],
        ),
      ),
    );
    final fontSize = style.fontSize!;
    final stacked =
        MediaQuery.textScalerOf(context).scale(fontSize) >= fontSize * 1.5;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _categoryColor(category.id, tokens),
              borderRadius: BorderRadius.circular(2),
            ),
            child: const SizedBox.square(dimension: 8),
          ),
        ),
        const SizedBox(width: WingSpacing.sm),
        Expanded(
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label,
                    Align(alignment: Alignment.centerRight, child: count),
                  ],
                )
              : label,
        ),
        if (!stacked) ...[const SizedBox(width: WingSpacing.md), count],
      ],
    );
  }
}

class _CompositionBar extends StatelessWidget {
  const _CompositionBar({required this.categories});
  final List<ContextCategory> categories;

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final total = categories.fold<int>(0, (sum, value) => sum + value.tokens);
    return Semantics(
      label: 'Estimated composition of used context',
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          key: const ValueKey('context-composition-bar'),
          width: double.infinity,
          height: 6,
          child: total == 0
              ? ColoredBox(color: tokens.border)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final category in categories)
                      if (category.tokens > 0)
                        Expanded(
                          flex: category.tokens,
                          child: ColoredBox(
                            color: _categoryColor(category.id, tokens),
                          ),
                        ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Gauge and label share one canvas and center; null draws a broken neutral ring.
class ContextRingPainter extends CustomPainter {
  const ContextRingPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.label,
    required this.labelColor,
    required this.labelFontSize,
  });

  final double? progress;
  final Color color;
  final Color track;
  final String label;
  final Color labelColor;
  final double labelFontSize;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final ring = bounds.deflate(1.5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = track;
    if (progress == null) {
      for (var i = 0; i < 3; i++) {
        canvas.drawArc(
          ring,
          -math.pi / 2 + i * math.pi * 2 / 3,
          math.pi / 2,
          false,
          paint,
        );
      }
    } else {
      canvas.drawOval(ring, paint);
      if (progress! > 0) {
        paint
          ..color = color
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round;
        canvas.drawArc(
          ring,
          -math.pi / 2,
          math.pi * 2 * progress!,
          false,
          paint,
        );
      }
    }
    if (progress == null) {
      canvas.drawLine(
        bounds.center - const Offset(3, 0),
        bounds.center + const Offset(3, 0),
        Paint()
          ..color = labelColor
          ..strokeWidth = 1,
      );
      return;
    }
    final text = TextPainter(textDirection: TextDirection.ltr, maxLines: 1);
    var fontSize = labelFontSize;
    void layout(String value) {
      text.text = TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: WingTypography.sans,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: labelColor,
          fontFeatures: const [ui.FontFeature.tabularFigures()],
        ),
      );
      text.layout();
    }

    // Reserve the same type size for every percentage, including 100%, so a
    // changing value never makes the digits jump in size.
    layout('100%');
    final available = size.width - 8;
    if (text.width > available) {
      fontSize *= available / text.width;
    }
    layout(label);
    // Roboto's cap height is 1456 / 2048 em. Center the visible capitals/digits
    // on the circle, rather than centering the ascent/descent line box.
    final capHeight = fontSize * (1456 / 2048);
    // LineMetrics adjusts its baseline to a rounded line height. The paragraph's
    // alphabetic baseline retains the font metric needed for small labels.
    final baseline = text.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    // Keep the fractional origin in the canvas transform: paragraph paint
    // offsets can snap tiny labels by a whole logical pixel.
    canvas.save();
    canvas.translate(
      (size.width - text.width) / 2,
      (size.height + capHeight) / 2 - baseline,
    );
    text.paint(canvas, Offset.zero);
    canvas.restore();
    text.dispose();
  }

  @override
  bool shouldRepaint(ContextRingPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      color != oldDelegate.color ||
      track != oldDelegate.track ||
      label != oldDelegate.label ||
      labelColor != oldDelegate.labelColor ||
      labelFontSize != oldDelegate.labelFontSize;
}
