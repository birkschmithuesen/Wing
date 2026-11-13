import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

/// Shared normal/group composer action surface, without execution policy.
class ComposerIconButton extends StatelessWidget {
  const ComposerIconButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.focused,
  });
  final String label;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool focused;
  @override
  Widget build(BuildContext context) => StudioButtonPress(
    child: IconButton.filled(
      tooltip: label,
      icon: icon,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        side: focused
            ? BorderSide(
                color: onPressed != null
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.primary,
                width: 2,
              )
            : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}

/// Wing's arrow lift and Stop settle, reused without alternative-action policy.
class ComposerActionGlyph extends StatelessWidget {
  const ComposerActionGlyph({
    super.key,
    required this.icon,
    required this.identity,
  });
  final IconData icon;
  final String identity;
  Widget _animateIcon(Widget child, Animation<double> animation) {
    final stop = child.key == const ValueKey('composer-button-icon-stop');
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final value = animation.value;
        final leaving = animation.status == AnimationStatus.reverse;
        // Send lifts off; Stop settles down. Typing lifts the arrow back in.
        final direction = stop ? (leaving ? 1 : -1) : (leaving ? -1 : 1);
        final scale = leaving ? value : Curves.easeOutBack.transform(value);
        return Opacity(
          opacity: value,
          child: FractionalTranslation(
            translation: Offset(0, direction * .55 * (1 - value)),
            child: Transform.scale(scale: .72 + .28 * scale, child: child),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: _animateIcon,
    child: Icon(icon, key: ValueKey('composer-button-icon-$identity')),
  );
}
