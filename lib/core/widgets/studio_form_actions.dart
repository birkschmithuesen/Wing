import 'package:flutter/material.dart';

import '../theme/wing_theme.dart';
import 'studio_loading.dart';

/// Compact popup framing. Padding stays consistent when text scales; callers
/// supply content and decisions rather than inheriting Material dialog gutters.
class StudioDialog extends StatelessWidget {
  const StudioDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.scrollable = true,
    this.insetPadding = const EdgeInsets.all(WingSpacing.md),
    this.titleTextStyle,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final bool scrollable;
  final EdgeInsets insetPadding;
  final TextStyle? titleTextStyle;

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: insetPadding,
    scrollable: false,
    titleTextStyle: titleTextStyle,
    titlePadding: EdgeInsets.zero,
    contentPadding: EdgeInsets.zero,
    actionsPadding: const EdgeInsets.fromLTRB(
      WingSpacing.md,
      0,
      WingSpacing.md,
      WingSpacing.md,
    ),
    buttonPadding: const EdgeInsets.symmetric(horizontal: WingSpacing.sm),
    title: title == null
        ? null
        : Padding(
            padding: EdgeInsets.fromLTRB(
              WingSpacing.md,
              WingSpacing.md,
              WingSpacing.md,
              content == null ? WingSpacing.md : WingSpacing.xs,
            ),
            child: title,
          ),
    content: content == null
        ? null
        : Padding(
            padding: EdgeInsets.fromLTRB(
              WingSpacing.md,
              title == null ? WingSpacing.md : WingSpacing.sm,
              WingSpacing.md,
              actions == null || actions!.isEmpty
                  ? WingSpacing.md
                  : WingSpacing.sm,
            ),
            child: scrollable ? SingleChildScrollView(child: content) : content,
          ),
    actions: actions,
  );
}

/// Draft forms dismiss through their footer, reserving the header for context
/// and the existing independently admitted read-progress slot.
class StudioFormHeader extends StatelessWidget {
  const StudioFormHeader({super.key, required this.title});
  final Widget title;

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
    ],
  );
}

/// Keeps a sheet's draft scrollable and its decisions above the keyboard.
class StudioFormSheet extends StatelessWidget {
  const StudioFormSheet({
    super.key,
    required this.children,
    required this.actions,
  });

  final List<Widget> children;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final screen = MediaQuery.sizeOf(context).height;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (screen - keyboard - 24).clamp(0.0, screen * .82),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    WingSpacing.md,
                    WingSpacing.md,
                    WingSpacing.md,
                    WingSpacing.sm,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  WingSpacing.md,
                  0,
                  WingSpacing.md,
                  WingSpacing.md,
                ),
                child: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Presentation for explicitly committing a draft. Owners retain validation,
/// write admission, errors and route lifetime; this widget forwards intent.
class StudioFormActions extends StatelessWidget {
  const StudioFormActions({
    super.key,
    required this.onCancel,
    required this.onConfirm,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.busy = false,
    this.progressLabel = 'Saving changes',
    this.cancelKey,
    this.confirmKey,
    this.confirmIcon = Icons.check,
    this.destructive = false,
    this.leadingActions = const [],
  });

  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;
  final String cancelLabel;
  final String confirmLabel;
  final bool busy;
  final String progressLabel;
  final Key? cancelKey;
  final Key? confirmKey;

  /// Non-draft decisions name their operation with its own glyph.
  final IconData confirmIcon;
  final bool destructive;
  final List<Widget> leadingActions;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerEnd,
    heightFactor: 1,
    widthFactor: 1,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        ...leadingActions,
        StudioButtonPress(
          child: IconButton(
            key: cancelKey,
            tooltip: cancelLabel,
            onPressed: busy ? null : onCancel,
            style: _style(context, filled: false),
            icon: const Icon(Icons.close),
          ),
        ),
        const SizedBox(width: WingSpacing.sm),
        StudioButtonPress(
          child: IconButton.filled(
            key: confirmKey,
            tooltip: confirmLabel,
            onPressed: busy ? null : onConfirm,
            style: _style(context, filled: true).copyWith(
              backgroundColor: destructive
                  ? WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.disabled)
                          ? null
                          : Theme.of(context).colorScheme.error,
                    )
                  : null,
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? null
                    : destructive
                    ? Theme.of(context).colorScheme.onError
                    : Theme.of(context).colorScheme.onPrimary,
              ),
            ),
            icon: busy
                ? SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      value: MediaQuery.disableAnimationsOf(context)
                          ? 0.75
                          : null,
                      strokeWidth: 2,
                      semanticsLabel: progressLabel,
                    ),
                  )
                : Icon(confirmIcon),
          ),
        ),
      ],
    ),
  );

  ButtonStyle _style(BuildContext context, {required bool filled}) =>
      ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        fixedSize: const WidgetStatePropertyAll(Size(48, 48)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(12)),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: WingRadius.control),
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? BorderSide(
                  color: filled
                      ? destructive
                            ? Theme.of(context).colorScheme.onError
                            : Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.primary,
                  width: 2,
                )
              : null,
        ),
      );
}
