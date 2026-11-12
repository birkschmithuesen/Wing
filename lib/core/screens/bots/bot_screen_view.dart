import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'dart:async';
import '../../widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/transcript_message.dart';
import '../../services/bot_screen_session.dart';
import '../../services/bot_screen_window.dart';
import '../../widgets/bot_display_viewport.dart';
import '../../widgets/bot_display_surface.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/wing_app_bar.dart';
import '../../widgets/server_connection_label.dart';
import '../../theme/wing_theme.dart';

class BotScreenView extends StatefulWidget {
  const BotScreenView({
    super.key,
    required this.createSession,
    required this.conversation,
    required this.readConversation,
    required this.readRequest,
    required this.sendMessage,
  });
  final Listenable conversation;
  final List<TranscriptMessage> Function() readConversation;
  final String? Function() readRequest;
  final Future<void> Function(String)? sendMessage;
  final BotScreenSession Function() createSession;
  @override
  State<BotScreenView> createState() => _BotScreenViewState();
}

class _BotScreenViewState extends State<BotScreenView>
    with WidgetsBindingObserver {
  late final _session = widget.createSession();
  final _typing = TextEditingController(text: '\u200b');
  final _handoffNote = TextEditingController();
  final _reply = TextEditingController();
  final _focus = FocusNode();
  bool _resettingKeyboard = false;
  bool _keyboard = false, _leaving = false, _canPop = false;
  bool _more = false, _foreground = true, _panel = true, _extraKeys = false;
  String? _working, _notice, _actionError;
  double _scrollRemainder = 0;
  bool? _landscape, _manualFullscreen, _windowFullscreen;
  String? _windowError;
  double _lastKeyboardInset = 0;
  Timer? _restoreBars, _imeBackExpiry;
  bool _imeBackPending = false;
  final _modifiers = <int>{};
  late final _viewport = BotDisplayViewport(onPointer: _session.pointer);
  bool get _fullscreen => _manualFullscreen ?? (_landscape == true);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_changed);
    widget.conversation.addListener(_changed);
    _typing.addListener(_type);
    _session.setVisible(true);
  }

  void _changed() {
    if (!mounted) return;
    if (!_session.canInput) {
      _modifiers.clear();
      _viewport.setInput(false);
      _resetKeyboard();
    }
    if (!_foreground || !_session.controlling || !_session.connected) {
      _keyboard = false;
      _focus.unfocus();
    }
    if (_session.error != null) _panel = true;
    setState(() {});
  }

  void _resetKeyboard() {
    _resettingKeyboard = true;
    _typing.value = const TextEditingValue(
      text: '\u200b',
      selection: TextSelection.collapsed(offset: 1),
    );
    _resettingKeyboard = false;
  }

  void _type() {
    if (_resettingKeyboard ||
        !_session.canInput ||
        !_typing.value.composing.isCollapsed) {
      return;
    }
    final text = _typing.text;
    if (text.isEmpty) {
      _session.key(0xff08, modifiers: _modifiers);
    } else {
      _session.typeText(text.replaceAll('\u200b', ''), modifiers: _modifiers);
    }
    _modifiers.clear();
    _resetKeyboard();
    setState(() {});
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    final released = await _session.close();
    if (!mounted) return;
    _leaving = false;
    if (released) {
      setState(() {
        _canPop = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  Future<void> _handBack() async {
    if (_session.controlling) {
      if (widget.sendMessage == null) {
        await _perform('Returning control', _session.handBack);
        return;
      }
      await _handoff();
      return;
    }
    final force = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        title: const Text('Hand control back?'),
        content: const Text(
          'This releases the current human controller, including another device, and lets the bot use its screen.',
        ),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: 'Hand control back',
            confirmIcon: Icons.screen_share_outlined,
            destructive: false,
          ),
        ],
      ),
    );
    if (force == true && mounted) {
      await _perform('Returning control', () => _session.handBack(force: true));
    }
  }

  Future<void> _takeOver() async {
    if (_session.humanHasControl) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StudioDialog(
          title: const Text('Take control from another device?'),
          content: const Text(
            'The current controller will return to watching the screen.',
          ),
          actions: [
            StudioFormActions(
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
              confirmLabel: 'Take control',
              confirmIcon: Icons.touch_app_outlined,
              destructive: false,
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _perform('Taking control', _session.takeOver);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // System UI overlays can temporarily remove focus. Changing immersion on
    // inactive/resumed would repeatedly dismiss/reopen Android's first-use tip.
    _foreground =
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached;
    _session.setFocused(state == AppLifecycleState.resumed);
    _session.setVisible(_foreground);
    _syncWindow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_changed);
    widget.conversation.removeListener(_changed);
    _restoreBars?.cancel();
    _imeBackExpiry?.cancel();
    _viewport.dispose();
    unawaited(BotScreenWindow.setImmersive(false));
    _session.dispose();
    _typing.dispose();
    _handoffNote.dispose();
    _reply.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _syncWindow() {
    final desired = _fullscreen && _foreground;
    if (_windowFullscreen == desired) return;
    _windowFullscreen = desired;
    unawaited(
      BotScreenWindow.setImmersive(desired).catchError((Object _) {
        if (mounted) {
          setState(
            () => _windowError =
                'Phone fullscreen could not be updated. Exit fullscreen and try again.',
          );
        }
      }),
    );
  }

  @override
  void didChangeMetrics() {
    final inset = View.of(context).viewInsets.bottom;
    if (_lastKeyboardInset > 0 && inset == 0) {
      // Android may hide IME before forwarding that same Back to Flutter.
      // Consume its route callback once, without acting on the next UI layer.
      if (_keyboard) {
        _imeBackPending = true;
        _imeBackExpiry?.cancel();
        _imeBackExpiry = Timer(const Duration(milliseconds: 350), () {
          _imeBackPending = false;
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _keyboard) _hideKeyboard();
      });
      _restoreBars?.cancel();
      _restoreBars = Timer(const Duration(milliseconds: 1200), () {
        _windowFullscreen = null;
        if (mounted) _syncWindow();
      });
    }
    _lastKeyboardInset = inset;
  }

  void _hideKeyboard() {
    _focus.unfocus();
    _resetKeyboard();
    setState(() => _keyboard = false);
  }

  void _toggleKeyboard() {
    _imeBackPending = false;
    _imeBackExpiry?.cancel();
    if (_keyboard) {
      _hideKeyboard();
      return;
    }
    setState(() {
      _keyboard = true;
      _more = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _keyboard) _focus.requestFocus();
    });
  }

  void _toggleFullscreen() {
    setState(() {
      _manualFullscreen = !_fullscreen;
      _more = false;
      _windowError = null;
    });
    _syncWindow();
  }

  void _back() {
    if (_imeBackPending) {
      _imeBackPending = false;
      _imeBackExpiry?.cancel();
    } else if (_keyboard) {
      _hideKeyboard();
    } else if (_more) {
      setState(() => _more = false);
    } else if (_fullscreen) {
      _toggleFullscreen();
    } else {
      _leave();
    }
  }

  void _key(int value) {
    _session.key(value, modifiers: _modifiers);
    setState(() => _modifiers.clear());
  }

  Widget _action(
    String label,
    IconData icon,
    VoidCallback? action, {
    bool selected = false,
  }) => Semantics(
    selected: selected,
    child: StudioButtonPress(
      child: IconButton(
        tooltip: label,
        onPressed: action,
        style: selected
            ? IconButton.styleFrom(
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.secondaryContainer,
              )
            : null,
        icon: Icon(icon),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      ),
    ),
  );

  Future<void> _perform(
    String label,
    Future<void> Function() work, {
    String? success,
  }) async {
    if (_working != null) return;
    setState(() {
      _working = label;
      _notice = null;
      _actionError = null;
    });
    try {
      await work();
      if (mounted) {
        setState(() => _notice = success);
        if (!_panel && success != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(success)));
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _panel = true;
          _actionError = error is StateError
              ? error.message.toString()
              : 'Could not complete the action. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  Future<void> _paste() => _perform(
    'Pasting phone clipboard',
    () => _session.pasteClipboard(
      () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
    ),
    success: 'Paste sent to the computer',
  );

  Future<void> _conversation() async {
    _hideKeyboard();
    bool sending = false;
    String? error, notice;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SizedBox(
            height:
                (MediaQuery.sizeOf(context).height -
                    MediaQuery.viewInsetsOf(context).bottom) *
                .85,
            child: StudioLoadingFrame(
              child: StudioPageLoading(
                active: sending,
                label: 'Queueing message',
                child: AnimatedBuilder(
                  animation: widget.conversation,
                  builder: (context, _) {
                    final messages = widget.readConversation();
                    final request = widget.readRequest();
                    return Column(
                      children: [
                        Row(
                          children: [
                            const SizedBox(width: 16),
                            const Expanded(
                              child: Text(
                                'Conversation',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const StudioLoadingSlot(),
                            if (widget.sendMessage != null)
                              _action('Return to chat', Icons.open_in_full, () {
                                Navigator.pop(context);
                                _leave();
                              }),
                            _action(
                              'Close conversation',
                              Icons.close,
                              () => Navigator.pop(context),
                            ),
                          ],
                        ),
                        if (request != null)
                          Flexible(
                            flex: 0,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 90),
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Text(request),
                              ),
                            ),
                          ),
                        Expanded(
                          child: ListView.builder(
                            reverse: true,
                            padding: const EdgeInsets.all(16),
                            itemCount: messages.length,
                            itemBuilder: (context, i) {
                              final message = messages[messages.length - i - 1];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 20),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      message.role == 'user'
                                          ? 'You'
                                          : _session.bot.title,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelMedium,
                                    ),
                                    viewportSelection(
                                      SelectableText(message.text),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: StudioError(error!),
                          ),
                        if (notice != null)
                          Text(
                            notice!,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        if (widget.sendMessage != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: viewportSelection(
                                    TextField(
                                      controller: _reply,
                                      enabled: !sending,
                                      minLines: 1,
                                      maxLines: 2,
                                      decoration: const InputDecoration(
                                        hintText: 'Message agent',
                                      ),
                                    ),
                                  ),
                                ),
                                _action(
                                  'Send message to agent',
                                  Icons.send_outlined,
                                  sending
                                      ? null
                                      : () async {
                                          final text = _reply.text.trim();
                                          if (text.isEmpty) return;
                                          update(() {
                                            sending = true;
                                            error = null;
                                            notice = null;
                                          });
                                          try {
                                            await widget.sendMessage!(text);
                                            if (mounted) _reply.clear();
                                            if (sheetContext.mounted) {
                                              update(
                                                () => notice = 'Message queued',
                                              );
                                            }
                                          } catch (_) {
                                            if (sheetContext.mounted) {
                                              update(
                                                () => error =
                                                    'Message could not be queued. Your text is kept.',
                                              );
                                            }
                                          } finally {
                                            if (sheetContext.mounted) {
                                              update(() => sending = false);
                                            }
                                          }
                                        },
                                ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handoff() async {
    _hideKeyboard();
    final note = _handoffNote..clear();
    bool resume = true, pending = false, released = false;
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !pending,
          child: StudioLoadingFrame(
            child: StudioPageLoading(
              active: pending,
              label: released ? 'Queueing message' : 'Returning control',
              child: StudioDialog(
                title: StudioFormHeader(
                  title: Text(
                    released ? 'Control returned' : 'Hand back to agent',
                  ),
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      viewportSelection(
                        TextField(
                          controller: note,
                          enabled: !pending,
                          minLines: 1,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            hintText: 'Note (optional)',
                          ),
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Ask agent to continue'),
                        value: resume,
                        onChanged: pending
                            ? null
                            : (value) => update(() => resume = value!),
                      ),
                      if (error != null) StudioError(error!),
                    ],
                  ),
                ),
                actions: [
                  StudioFormActions(
                    onCancel: pending ? null : () => Navigator.pop(context),
                    onConfirm: pending
                        ? null
                        : () async {
                            update(() {
                              pending = true;
                              error = null;
                            });
                            try {
                              if (!released) {
                                await _session.handBack();
                                if (_session.humanHasControl ||
                                    _session.error != null) {
                                  throw StateError(
                                    'Control could not be returned. Retry when connected.',
                                  );
                                }
                                released = true;
                              }
                              final text = note.text.trim();
                              if (resume || text.isNotEmpty) {
                                await widget.sendMessage!(
                                  [
                                    if (text.isNotEmpty) text,
                                    if (resume)
                                      'I have handed the computer back to you. Please continue the task.',
                                  ].join('\n\n'),
                                );
                              }
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }
                              if (mounted) {
                                setState(
                                  () => _notice = resume || text.isNotEmpty
                                      ? 'Control returned · message queued'
                                      : 'Control returned',
                                );
                              }
                            } catch (_) {
                              if (dialogContext.mounted) {
                                update(() {
                                  pending = false;
                                  error = released
                                      ? 'Control returned, but the message could not be queued. Your note is kept; retry or close.'
                                      : 'Control could not be returned. Try again.';
                                });
                              }
                            }
                          },
                    confirmLabel: released ? 'Retry message' : 'Hand back',
                    confirmIcon: Icons.screen_share_outlined,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _commands() => SingleChildScrollView(
    child: Wrap(
      children: [
        _action(
          _panel ? 'Hide agent panel' : 'Show agent panel',
          Icons.chat_bubble_outline,
          () => setState(() {
            _panel = !_panel;
            _more = false;
          }),
        ),
        _action(
          _fullscreen ? 'Exit fullscreen' : 'Enter fullscreen',
          _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          _toggleFullscreen,
        ),
        _action(
          'Refresh screen',
          Icons.refresh,
          _working == null
              ? () => _perform('Refreshing screen', _session.refreshScreen)
              : null,
        ),
        if (_session.status?.running == true)
          _action(
            'Stop screen',
            Icons.stop_outlined,
            _session.canStop && _working == null
                ? () => _perform('Stopping screen', () => _session.power(false))
                : null,
          )
        else
          _action(
            'Start screen',
            Icons.play_arrow_outlined,
            _session.canStart && _working == null
                ? () => _perform('Starting screen', () => _session.power(true))
                : null,
          ),
        if (_session.humanHasControl && !_session.controlling)
          _action(
            'Hand control back (force)',
            Icons.pan_tool_outlined,
            _session.busy || _working != null ? null : _handBack,
          ),
        _action(
          'Gesture help',
          Icons.help_outline,
          () => showDialog<void>(
            context: context,
            builder: (context) => StudioDialog(
              title: const Text('Touch controls'),
              content: const SingleChildScrollView(
                child: Text(
                  'Tap: click where you touch.\nDouble tap: double-click.\nHold: right-click.\nDouble-tap, hold and move: drag an item.\n\nOne finger: move around the zoomed view.\nTwo fingers together: scroll the computer.\nPinch: zoom.\n\nThe side strip also scrolls the computer at the last touched point.\n\nKeyboard: type directly into the selected computer field. Paste uses your phone clipboard; it does not press Enter.',
                ),
              ),
              actions: [
                _action(
                  'Close help',
                  Icons.close,
                  () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
        if (_fullscreen || _keyboard)
          _action('Close screen', Icons.arrow_back, _leave),
      ],
    ),
  );

  Widget _keys() {
    Widget key(String label, IconData icon, int value) =>
        _action(label, icon, _session.canInput ? () => _key(value) : null);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_extraKeys)
          SingleChildScrollView(
            key: const ValueKey('bot-screen-extra-keys'),
            primary: false,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final modifier in [
                  ('Control modifier', Icons.keyboard_control_key, 0xffe3),
                  ('Alt modifier', Icons.alt_route, 0xffe9),
                  ('Shift modifier', Icons.keyboard_capslock, 0xffe1),
                  ('Super modifier', Icons.window_outlined, 0xffeb),
                ])
                  _action(
                    modifier.$1,
                    modifier.$2,
                    _session.canInput
                        ? () => setState(() {
                            if (!_modifiers.add(modifier.$3)) {
                              _modifiers.remove(modifier.$3);
                            }
                          })
                        : null,
                    selected: _modifiers.contains(modifier.$3),
                  ),
                key('Home', Icons.first_page, 0xff50),
                key('End', Icons.last_page, 0xff57),
                key('Page up', Icons.vertical_align_top, 0xff55),
                key('Page down', Icons.vertical_align_bottom, 0xff56),
                key('Delete', Icons.delete_outline, 0xffff),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('bot-screen-basic-keys'),
                primary: false,
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    key('Tab', Icons.keyboard_tab, 0xff09),
                    key('Escape', Icons.cancel_outlined, 0xff1b),
                    key('Enter', Icons.keyboard_return, 0xff0d),
                    key('Backspace', Icons.backspace_outlined, 0xff08),
                    key('Left arrow', Icons.keyboard_arrow_left, 0xff51),
                    key('Up arrow', Icons.keyboard_arrow_up, 0xff52),
                    key('Down arrow', Icons.keyboard_arrow_down, 0xff54),
                    key('Right arrow', Icons.keyboard_arrow_right, 0xff53),
                  ],
                ),
              ),
            ),
            _action(
              'More keyboard keys',
              Icons.keyboard_command_key,
              () => setState(() => _extraKeys = !_extraKeys),
              selected: _extraKeys || _modifiers.isNotEmpty,
            ),
          ],
        ),
      ],
    );
  }

  Widget _dock() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      _action(
        _keyboard ? 'Hide keyboard' : 'Show keyboard',
        Icons.keyboard_outlined,
        _session.canInput ? _toggleKeyboard : null,
        selected: _keyboard,
      ),
      _action(
        'Paste phone clipboard',
        Icons.content_paste,
        _session.canInput && _working == null && !_session.pasting
            ? _paste
            : null,
      ),
      _action(
        'More screen controls',
        Icons.more_horiz,
        () => setState(() => _more = !_more),
        selected: _more,
      ),
      _session.controlling
          ? _action(
              'Hand control back',
              Icons.screen_share_outlined,
              _session.busy || _working != null ? null : _handBack,
            )
          : _action(
              'Take control',
              Icons.touch_app_outlined,
              _session.canTakeOver && _working == null ? _takeOver : null,
            ),
    ],
  );

  Widget _companion(String control, String? message, {required bool compact}) {
    if (!_panel) {
      return Material(
        child: Row(
          children: [
            if (_fullscreen || _keyboard) const StudioLoadingSlot(),
            Expanded(child: _dock()),
          ],
        ),
      );
    }
    final messages = widget.readConversation();
    final latest = messages
        .where((m) => m.role == 'assistant')
        .lastOrNull
        ?.text;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          if (_panel) ...[
            if (compact)
              const StudioLoadingSlot(height: 24)
            else
              Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: Tooltip(
                      message: control,
                      child: Text(
                        control,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ),
                  if (_fullscreen || _keyboard) const StudioLoadingSlot(),
                  _action(
                    'Open conversation',
                    Icons.chat_bubble_outline,
                    _conversation,
                  ),
                ],
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.readRequest() ??
                          latest ??
                          'The agent’s latest message appears here.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: StudioError(message),
                      ),
                    if (_session.status?.installed == false &&
                        _session.status?.installCommand != null)
                      viewportSelection(
                        SelectableText(_session.status!.installCommand!),
                      ),
                    if (_notice != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _notice!,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          _dock(),
        ],
      ),
    );
  }

  Widget _scrollStrip() => LayoutBuilder(
    builder: (context, bounds) => SizedBox(
      width: 48,
      child: Column(
        children: [
          if (bounds.maxHeight >= 144)
            _action(
              'Scroll up',
              Icons.keyboard_arrow_up,
              _session.canInput ? () => _viewport.click(8) : null,
            ),
          Expanded(
            child: Semantics(
              label: 'Scroll computer',
              onIncrease: _session.canInput ? () => _viewport.click(8) : null,
              onDecrease: _session.canInput ? () => _viewport.click(16) : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) => _scrollRemainder = 0,
                onVerticalDragUpdate: _session.canInput
                    ? (e) {
                        _scrollRemainder += e.delta.dy;
                        while (_scrollRemainder.abs() >= 12) {
                          _viewport.click(_scrollRemainder > 0 ? 16 : 8);
                          _scrollRemainder -= _scrollRemainder > 0 ? 12 : -12;
                        }
                      }
                    : null,
                child: Center(
                  child: Container(
                    width: 4,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (bounds.maxHeight >= 144)
            _action(
              'Scroll down',
              Icons.keyboard_arrow_down,
              _session.canInput ? () => _viewport.click(16) : null,
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final landscape =
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    if (_landscape != landscape) {
      _landscape = landscape;
      _manualFullscreen = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncWindow();
      });
    }
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final status = _session.status;
    final control = _session.controlling
        ? 'You have control'
        : _session.humanHasControl
        ? 'Human has control'
        : _session.connected
        ? 'Bot has control'
        : 'Screen offline';
    final message =
        _actionError ??
        _windowError ??
        _session.error ??
        (status == null
            ? null
            : !status.supported
            ? 'Bot Screen needs a supported Linux host.'
            : !status.installed
            ? 'Install the Bot Screen components on the bot’s host to use its screen.'
            : status.blocker ??
                  (!status.running
                      ? 'Start the bot’s screen to view it.'
                      : null));
    return StudioLoadingFrame(
      child: PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: (popped, _) {
          if (!popped) _back();
        },
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          appBar: _fullscreen || _keyboard
              ? null
              : WingAppBar(
                  context: context,
                  title: Text(
                    '${_session.bot.title} screen',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  leading: _action('Close screen', Icons.arrow_back, _leave),
                  contextRow: ServerConnectionLabel(
                    label: _session.bot.instance,
                    status: _session.repository.connectionStatus,
                  ),
                ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, bounds) {
                final available = (bounds.maxHeight - inset).clamp(
                  1.0,
                  bounds.maxHeight,
                );
                final keysHeight = _keyboard ? (_extraKeys ? 96.0 : 48.0) : 0.0;
                final panelWidth = _panel
                    ? (bounds.maxWidth * .25).clamp(208.0, 280.0)
                    : 64.0;
                final panelHeight = _panel
                    ? (available * .32).clamp(
                        96.0 +
                            MediaQuery.textScalerOf(context).scale(16) * 1.75,
                        240.0,
                      )
                    : 48.0;
                final desktopHeight =
                    (available - keysHeight - (landscape ? 0 : panelHeight))
                        .clamp(1.0, bounds.maxHeight);
                final desktopWidth =
                    (bounds.maxWidth - (landscape ? panelWidth : 0) - 48).clamp(
                      1.0,
                      bounds.maxWidth,
                    );
                return Stack(
                  children: [
                    if (_working != null ||
                        (_session.frame == null &&
                            (_session.busy || _session.connecting)))
                      StudioPageLoading.waiting(
                        label: _working ?? 'Connecting to bot screen',
                      ),
                    Positioned(
                      left: 0,
                      top: 0,
                      width: desktopWidth,
                      height: desktopHeight + inset,
                      key: const ValueKey('bot-screen-display'),
                      child: _session.frame == null
                          ? const Center(
                              child: Icon(
                                Icons.desktop_windows_outlined,
                                size: 48,
                              ),
                            )
                          : BotDisplaySurface(
                              frame: _session.frame!,
                              viewport: _viewport,
                              canInput: _session.canInput,
                              keyboardInset: inset,
                              barInset: 0,
                            ),
                    ),
                    Positioned(
                      left: desktopWidth,
                      top: 0,
                      width: 48,
                      height: desktopHeight,
                      child: _scrollStrip(),
                    ),
                    Positioned(
                      right: 0,
                      bottom: inset + keysHeight,
                      width: landscape ? panelWidth : bounds.maxWidth,
                      height: landscape ? desktopHeight : panelHeight,
                      key: const ValueKey('bot-screen-controls'),
                      child: !_panel && landscape
                          ? Material(
                              child: SingleChildScrollView(
                                child: Column(
                                  children: [
                                    const StudioLoadingSlot(),
                                    _action(
                                      'Show agent panel',
                                      Icons.chat_bubble_outline,
                                      () => setState(() => _panel = true),
                                    ),
                                    _action(
                                      _keyboard
                                          ? 'Hide keyboard'
                                          : 'Show keyboard',
                                      Icons.keyboard_outlined,
                                      _session.canInput
                                          ? _toggleKeyboard
                                          : null,
                                    ),
                                    _action(
                                      'Paste phone clipboard',
                                      Icons.content_paste,
                                      _session.canInput && _working == null
                                          ? _paste
                                          : null,
                                    ),
                                    _action(
                                      'More screen controls',
                                      Icons.more_horiz,
                                      () => setState(() => _more = !_more),
                                    ),
                                    _action(
                                      _session.controlling
                                          ? 'Hand control back'
                                          : 'Take control',
                                      Icons.screen_share_outlined,
                                      _session.busy
                                          ? null
                                          : _session.controlling
                                          ? _handBack
                                          : _takeOver,
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : _companion(
                              control,
                              message,
                              compact: landscape && desktopHeight < 176,
                            ),
                    ),
                    if (_keyboard)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: inset,
                        height: keysHeight,
                        child: Material(child: _keys()),
                      ),
                    if (_more)
                      Positioned(
                        right: 8,
                        bottom: inset + keysHeight + 56,
                        width: (bounds.maxWidth - 16).clamp(1.0, 192.0),
                        child: Material(
                          elevation: 4,
                          borderRadius: WingRadius.card,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: (available - keysHeight - 64).clamp(
                                48.0,
                                320.0,
                              ),
                            ),
                            child: _commands(),
                          ),
                        ),
                      ),
                    if (_keyboard &&
                        _foreground &&
                        _session.controlling &&
                        _session.connected)
                      Positioned(
                        key: const ValueKey('bot-screen-keyboard'),
                        left: 0,
                        top: 0,
                        width: 1,
                        height: 1,
                        child: IgnorePointer(
                          child: Opacity(
                            opacity: 0,
                            child: viewportSelection(
                              TextField(
                                controller: _typing,
                                focusNode: _focus,
                                // Desktop gestures and controls share this bridge.
                                // Only explicit keyboard dismissal should unfocus it.
                                onTapOutside: (_) {},
                                obscureText: true,
                                obscuringCharacter: '\u200b',
                                autocorrect: false,
                                enableSuggestions: false,
                                enableIMEPersonalizedLearning: false,
                                enableInteractiveSelection: false,
                                decoration: const InputDecoration.collapsed(
                                  hintText: 'Type on the bot’s screen',
                                ),
                                onSubmitted: (_) {
                                  _key(0xff0d);
                                  _focus.requestFocus();
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
