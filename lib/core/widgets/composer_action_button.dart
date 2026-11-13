import 'package:wing/core/theme/wing_theme.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../models/composer_action.dart';
import '../theme/wing_icons.dart';
import 'composer_icon_button.dart';

IconData composerActionIcon(ComposerAction action) => switch (action) {
  ComposerAction.send => Icons.arrow_upward,
  ComposerAction.steer => WingIcons.steer,
  ComposerAction.stop => Icons.stop,
  ComposerAction.queue => WingIcons.queue,
};

/// A held pointer chooses an action; lifting commits it, leaving cancels it.
class ComposerActionButton extends StatefulWidget {
  const ComposerActionButton({
    super.key,
    required this.primary,
    required this.resting,
    required this.unavailable,
    required this.onSelected,
  });

  final ComposerAction? primary;
  final ComposerAction? resting;

  /// A null reason means the action is available.
  final Map<ComposerAction, String?> unavailable;
  final ValueChanged<ComposerAction> onSelected;

  @override
  State<ComposerActionButton> createState() => _ComposerActionButtonState();
}

class _ComposerActionButtonState extends State<ComposerActionButton>
    with WidgetsBindingObserver {
  final _anchorKey = GlobalKey();
  final _iconAction = ValueNotifier<ComposerAction?>(null);
  final _keyboardFocus = FocusNode(debugLabel: 'Composer actions');
  bool _keyboardFocused = false;
  int _menuRevision = 0;
  OverlayEntry? _overlay;
  Rect _anchor = Rect.zero;
  Rect _choices = Rect.zero;
  ComposerAction? _selected;
  List<ComposerAction> _actions = [];

  bool _enabled(ComposerAction? action) =>
      widget.unavailable.containsKey(action) &&
      widget.unavailable[action] == null;

  bool get _hasAlternatives =>
      widget.resting != ComposerAction.stop &&
      widget.unavailable.values.any((reason) => reason == null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _iconAction.value = widget.resting;
  }

  @override
  void didUpdateWidget(ComposerActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.primary != widget.primary ||
        oldWidget.resting != widget.resting ||
        oldWidget.unavailable.length != widget.unavailable.length ||
        oldWidget.unavailable.entries.any(
          (entry) =>
              !widget.unavailable.containsKey(entry.key) ||
              widget.unavailable[entry.key] != entry.value,
        )) {
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
    _iconAction.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  void _close() {
    _menuRevision++;
    _overlay?.remove();
    _overlay?.dispose();
    _overlay = null;
    _selected = null;
    _iconAction.value = widget.resting;
  }

  Future<void> _openKeyboardMenu() async {
    if (!_hasAlternatives) return;
    if (_overlay != null) _close();
    final revision = ++_menuRevision;
    final overlayBox =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final anchorBox =
        _anchorKey.currentContext!.findRenderObject()! as RenderBox;
    final anchor =
        anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox) &
        anchorBox.size;
    final selected = await showMenu<ComposerAction>(
      context: context,
      requestFocus: true,
      semanticLabel: 'Composer actions',
      position: RelativeRect.fromRect(anchor, Offset.zero & overlayBox.size),
      items: [
        for (final action in widget.unavailable.keys)
          StudioPopupMenuItem<ComposerAction>(
            key: ValueKey('composer-keyboard-${action.name}'),
            value: action,
            enabled: _enabled(action),
            child: Text(
              widget.unavailable[action] == null
                  ? action.label
                  : '${action.label}: ${widget.unavailable[action]}',
            ),
          ),
      ],
    );
    if (!mounted) return;
    _keyboardFocus.requestFocus();
    if (revision == _menuRevision && selected != null && _enabled(selected)) {
      widget.onSelected(selected);
    }
  }

  KeyEventResult _keyboardEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.arrowDown ||
        (key == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed)) {
      if (!_hasAlternatives) return KeyEventResult.ignored;
      _openKeyboardMenu();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      if (_enabled(widget.primary)) {
        widget.onSelected(widget.primary!);
      } else {
        _openKeyboardMenu();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _open(LongPressStartDetails details) {
    if (_overlay != null || !_hasAlternatives) return;
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject()! as RenderBox;
    final anchorBox =
        _anchorKey.currentContext!.findRenderObject()! as RenderBox;
    _anchor =
        anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox) &
        anchorBox.size;
    _actions = [
      ComposerAction.stop,
      ComposerAction.queue,
      widget.primary == ComposerAction.send
          ? ComposerAction.send
          : ComposerAction.steer,
    ];
    // Keep the default directly above the finger.
    if (widget.primary case final ComposerAction primary) {
      _actions.remove(primary);
      _actions.add(primary);
    }
    final media = MediaQuery.of(context);
    final width = math.min(64.0, overlayBox.size.width - 16);
    final left = (_anchor.center.dx - width / 2).clamp(
      8.0,
      math.max(8.0, overlayBox.size.width - width - 8),
    );
    final bottom = _anchor.top - 12;
    final height = math.min(240.0, bottom - media.padding.top - 8);
    if (height <= 0) return;
    _choices = Rect.fromLTWH(left.toDouble(), bottom - height, width, height);
    _selected = widget.primary;
    _overlay = OverlayEntry(
      builder: (_) =>
          InheritedTheme.captureAll(context, Builder(builder: _buildSelector)),
    );
    overlay.insert(_overlay!);
    _iconAction.value = widget.primary;
    HapticFeedback.selectionClick();
  }

  Widget _buildSelector(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = _selected;
    final label = selected == null
        ? 'Release to cancel'
        : widget.unavailable[selected] ?? selected.label;
    final overlayBox =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final labelOnLeft = _choices.left >= 160;
    final labelWidth = math.min(
      200.0,
      labelOnLeft
          ? _choices.left - 16
          : overlayBox.size.width - _choices.right - 16,
    );
    final selectedIndex = selected == null
        ? _actions.length - 1
        : _actions.indexOf(selected);
    final rowHeight = _choices.height / _actions.length;
    final labelTop = _choices.top + rowHeight * selectedIndex;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: labelOnLeft
                ? _choices.left - labelWidth - 8
                : _choices.right + 8,
            top: labelTop,
            width: math.max(0, labelWidth),
            height: rowHeight,
            child: Align(
              alignment: labelOnLeft
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Material(
                color: colors.inverseSurface,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    label,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onInverseSurface,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: _choices.left,
            top: _choices.top,
            width: _choices.width,
            height: _choices.height,
            child: Material(
              key: const ValueKey('composer-action-selector'),
              color: colors.surfaceContainerHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final action in _actions)
                    Expanded(
                      child: Container(
                        key: ValueKey('composer-choice-${action.name}'),
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: selected == action
                              ? colors.primaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : Duration(
                                  milliseconds:
                                      160 +
                                      (_actions.length -
                                              1 -
                                              _actions.indexOf(action)) *
                                          30,
                                ),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, child) => Opacity(
                            opacity: value,
                            child: Transform.translate(
                              offset: Offset(0, 12 * (1 - value)),
                              child: child,
                            ),
                          ),
                          child: Icon(
                            composerActionIcon(action),
                            color: !_enabled(action)
                                ? colors.onSurface.withValues(alpha: .3)
                                : selected == action
                                ? colors.onPrimaryContainer
                                : colors.onSurface,
                            semanticLabel: action.label,
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
    ComposerAction? next;
    if (_choices.contains(point)) {
      final index =
          ((point.dy - _choices.top) / _choices.height * _actions.length)
              .floor()
              .clamp(0, _actions.length - 1);
      next = _actions[index];
    } else if (Rect.fromLTRB(
      _anchor.left - 8,
      _choices.bottom,
      _anchor.right + 8,
      _anchor.bottom + 8,
    ).contains(point)) {
      next = widget.primary;
    }
    if (_selected != next) {
      _selected = next;
      _iconAction.value = next ?? widget.resting;
      _overlay!.markNeedsBuild();
      HapticFeedback.selectionClick();
    }
  }

  void _release(LongPressEndDetails details) {
    final selected = _selected;
    _close();
    if (selected != null && _enabled(selected)) widget.onSelected(selected);
  }

  @override
  Widget build(BuildContext context) {
    final hasActions = _enabled(widget.primary) || _hasAlternatives;
    return Semantics(
      hint: _hasAlternatives
          ? 'Hold, slide to an action, then release. Slide away to cancel. '
                'Keyboard: Down arrow opens actions.'
          : null,
      customSemanticsActions: {
        for (final action in widget.unavailable.keys)
          if (_enabled(action) &&
              (_hasAlternatives || action == widget.primary))
            CustomSemanticsAction(label: action.label): () =>
                widget.onSelected(action),
      },
      child: Focus(
        key: const ValueKey('composer-action-focus'),
        focusNode: _keyboardFocus,
        canRequestFocus: hasActions,
        skipTraversal: !hasActions,
        onFocusChange: (focused) => setState(() => _keyboardFocused = focused),
        onKeyEvent: hasActions ? _keyboardEvent : null,
        child: ExcludeFocus(
          child: GestureDetector(
            onLongPressStart: _hasAlternatives ? _open : null,
            onLongPressMoveUpdate: _hasAlternatives ? _move : null,
            onLongPressEnd: _hasAlternatives ? _release : null,
            onLongPressCancel: _hasAlternatives ? _close : null,
            child: TooltipTheme(
              data: const TooltipThemeData(
                triggerMode: TooltipTriggerMode.manual,
              ),
              child: ComposerIconButton(
                key: _anchorKey,
                focused: _keyboardFocused,
                label: widget.primary?.label ?? 'Choose chat action',
                icon: ValueListenableBuilder<ComposerAction?>(
                  valueListenable: _iconAction,
                  builder: (context, action, _) => ComposerActionGlyph(
                    icon: action == null
                        ? Icons.tune
                        : composerActionIcon(action),
                    identity: action?.name ?? 'choose',
                  ),
                ),
                onPressed: _enabled(widget.primary)
                    ? () => widget.onSelected(widget.primary!)
                    : widget.primary == null && hasActions
                    ? _openKeyboardMenu
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
