import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/accessibility_timeout.dart';
import '../theme/wing_theme.dart';
import 'studio_form_actions.dart';

part 'studio_transient_error.dart';

/// The semantic tint follows the outcome independently of the user's accent.
enum StudioErrorSeverity {
  error,
  noResult;

  Color color(WingTokens tokens) => switch (this) {
    error => tokens.danger,
    noResult => tokens.warning,
  };

  Color surface(WingTokens tokens) => switch (this) {
    error => tokens.dangerSurface,
    noResult => tokens.warningSurface,
  };

  IconData get glyph => switch (this) {
    error => Icons.error_outline,
    noResult => Icons.warning_amber_rounded,
  };
}

/// Persistent error content beside the affected field, form, or recovery area.
class StudioError extends StatelessWidget {
  const StudioError(
    this.message, {
    super.key,
    this.detail,
    this.icon,
    this.severity = StudioErrorSeverity.error,
    this.framed = true,
    this.announce = true,
    this.stacked = false,
  }) : _centerIcon = false;

  const StudioError._capsule(
    this.message, {
    required this.detail,
    required this.icon,
    required this.severity,
  }) : framed = false,
       stacked = false,
       announce = false,
       _centerIcon = true;

  final bool _centerIcon;
  final String message;
  final String? detail;
  final IconData? icon;
  final StudioErrorSeverity severity;
  final bool framed;
  final bool announce;

  /// Put the status icon above the copy in compact attachment cards.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final tint = severity.color(tokens);
    final statusIcon = ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tint.withValues(alpha: .14),
        ),
        child: SizedBox.square(
          dimension: 38,
          child: Icon(icon ?? severity.glyph, size: 20, color: tint),
        ),
      ),
    );
    final copy = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: tokens.typography.section.copyWith(
            fontSize: 14,
            color: tokens.onSurface,
          ),
        ),
        if (detail case final detail?) ...[
          const SizedBox(height: WingSpacing.xs),
          Text(
            detail,
            style: tokens.typography.label.copyWith(
              color: tokens.muted,
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
            ),
          ),
        ],
      ],
    );
    final content = Semantics(
      liveRegion: announce,
      child: stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                statusIcon,
                const SizedBox(height: WingSpacing.sm),
                copy,
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: _centerIcon
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                statusIcon,
                const SizedBox(width: WingSpacing.md),
                Flexible(child: copy),
              ],
            ),
    );
    return framed
        ? StudioErrorFrame(
            severity: severity,
            child: Padding(
              padding: const EdgeInsets.all(WingSpacing.md),
              child: content,
            ),
          )
        : content;
  }
}

/// Common surface for error content that needs separate recovery controls.
class StudioErrorFrame extends StatelessWidget {
  const StudioErrorFrame({
    super.key,
    required this.child,
    this.severity = StudioErrorSeverity.error,
    this.floating = false,
  });

  final Widget child;
  final StudioErrorSeverity severity;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final tint = severity.color(tokens);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: severity.surface(tokens),
      surfaceTintColor: Colors.transparent,
      elevation: floating ? 6 : 0,
      shadowColor: Colors.black.withValues(alpha: .24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: floating
            ? const BorderRadius.all(Radius.circular(22))
            : WingRadius.card,
        side: BorderSide(color: tint.withValues(alpha: dark ? .42 : .30)),
      ),
      child: child,
    );
  }
}

/// Presents a failed explicit action that requires acknowledgement.
DialogRoute<void> showStudioError(BuildContext context, String message) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    builder: (context) => StudioDialog(
      content: StudioError(message),
      actions: const [StudioButtonPress(child: CloseButton())],
    ),
  );
  unawaited(navigator.push(route));
  return route;
}
