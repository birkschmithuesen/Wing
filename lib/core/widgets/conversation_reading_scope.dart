import 'package:flutter/material.dart';

/// Mounted conversation presentation only. Drafts and transcript state remain
/// with their existing owners; callers key this scope by conversation identity.
class ConversationReadingScope extends StatefulWidget {
  const ConversationReadingScope({super.key, required this.builder});

  final WidgetBuilder builder;

  static ConversationReadingMode? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ReadingMode>()?.mode;

  static bool compact(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height && size.shortestSide < 600;
  }

  static bool keyboardOpen(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ReadingMode>()!.keyboard;

  static bool compactKeyboard(BuildContext context) =>
      compact(context) && keyboardOpen(context);

  @override
  State<ConversationReadingScope> createState() => _ReadingState();
}

class ConversationReadingMode {
  const ConversationReadingMode(this.active, this.exit, this.toggle);
  final bool active;
  final VoidCallback exit, toggle;
}

class _ReadingState extends State<ConversationReadingScope> {
  bool _active = false;

  void _set(bool active) {
    if (_active == active) return;
    if (active) FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _active = active);
  }

  @override
  Widget build(BuildContext context) => _ReadingMode(
    // Scaffold consumes keyboard insets before building its body. Observe them
    // here so the composer sees the actual IME state without subtracting twice.
    keyboard: MediaQuery.viewInsetsOf(context).bottom > 0,
    mode: ConversationReadingMode(
      _active,
      () => _set(false),
      () => _set(!_active),
    ),
    child: PopScope(
      canPop: !_active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _active) _set(false);
      },
      child: Builder(builder: widget.builder),
    ),
  );
}

class _ReadingMode extends InheritedWidget {
  const _ReadingMode({
    required this.mode,
    required this.keyboard,
    required super.child,
  });
  final ConversationReadingMode mode;
  final bool keyboard;

  @override
  bool updateShouldNotify(_ReadingMode oldWidget) =>
      oldWidget.mode.active != mode.active || oldWidget.keyboard != keyboard;
}
