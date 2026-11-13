import 'dart:async';
import 'studio_loading.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../models/composer_reference.dart';
import '../theme/wing_theme.dart';
import 'studio_error.dart';
import 'bot_avatar.dart';

/// Cursor, focus and popup lifetime are presentation state. All discovery and
/// draft mutation pass through captured feature commands.
class MentionSuggestions extends StatefulWidget {
  const MentionSuggestions({
    super.key,
    required this.composer,
    required this.composerFocus,
    required this.load,
    required this.select,
  });
  final TextEditingController composer;
  final FocusNode composerFocus;
  final Future<MentionCompletion> Function(
    MentionQuery query,
    String? directory,
    bool Function() canRead,
  )
  load;
  final Future<void> Function(String text, ComposerReference reference) select;

  @override
  State<MentionSuggestions> createState() => _MentionSuggestionsState();
}

class _MentionSuggestionsState extends State<MentionSuggestions> {
  Timer? _debounce;
  int _generation = 0, _highlighted = 0;
  MentionQuery? _query;
  MentionCompletion? _completion;
  String? _directory, _error;
  bool _pending = false, _loading = false, _dismissed = false;
  final _scroll = ScrollController();
  final _rowKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    widget.composer.addListener(_changed);
    HardwareKeyboard.instance.addHandler(_key);
    _changed();
  }

  @override
  void didUpdateWidget(MentionSuggestions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.composer != widget.composer) {
      oldWidget.composer.removeListener(_changed);
      widget.composer.addListener(_changed);
      _query = null;
      _changed();
    }
  }

  void _changed() {
    final value = widget.composer.value;
    final next = MentionQuery.at(
      value.text,
      value.selection.extentOffset,
      collapsed: value.selection.isValid && value.selection.isCollapsed,
    );
    if (_query?.text == next?.text && _query?.end == next?.end) return;
    _debounce?.cancel();
    final generation = ++_generation;
    final retainCompletion =
        !_dismissed &&
        next != null &&
        _query != null &&
        next.start == _query!.start &&
        next.text.substring(0, next.start) ==
            _query!.text.substring(0, _query!.start);
    setState(() {
      _query = next;
      if (!retainCompletion) {
        _completion = null;
        _rowKeys.clear();
      }
      _directory = null;
      _highlighted = 0;
      _error = null;
      _dismissed = false;
      _pending = next != null;
      _loading = false;
    });
    if (next != null) {
      _debounce = Timer(
        const Duration(milliseconds: 300),
        () => _load(next, null, generation),
      );
    }
  }

  Future<void> _load(
    MentionQuery query,
    String? directory,
    int generation,
  ) async {
    if (!mounted || generation != _generation || _dismissed) return;
    setState(() => _loading = true);
    try {
      final completion = await widget.load(
        query,
        directory,
        () => mounted && generation == _generation && !_dismissed,
      );
      if (!mounted || generation != _generation || _dismissed) return;
      setState(() {
        _completion = completion;
        _pending = false;
        _loading = false;
        _highlighted = 0;
        _rowKeys.clear();
      });
    } catch (_) {
      if (!mounted || generation != _generation || _dismissed) return;
      setState(() {
        _error = 'References could not load. Retry or edit the query.';
        _pending = false;
        _loading = false;
      });
    }
  }

  void _browse(String? directory) {
    final query = _query;
    if (query == null) return;
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _directory = directory;
      _completion = null;
      _error = null;
      _pending = true;
      _loading = true;
    });
    unawaited(_load(query, directory, generation));
  }

  void _close() {
    _generation++;
    _debounce?.cancel();
    setState(() {
      _dismissed = true;
    });
  }

  Future<void> _select(ComposerReference reference) async {
    final query = _query;
    final value = widget.composer.value;
    if (_pending ||
        query == null ||
        query.text != value.text ||
        query.end != value.selection.extentOffset ||
        !value.selection.isCollapsed) {
      return;
    }
    final next = query.insert(reference);
    _generation++;
    _debounce?.cancel();
    widget.composer.value = TextEditingValue(
      text: next.text,
      selection: TextSelection.collapsed(offset: next.cursor),
    );
    try {
      await widget.select(next.text, reference);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'The reference could not be saved. Your text is kept.';
        });
      }
    }
  }

  bool _key(KeyEvent event) {
    if (event is! KeyDownEvent ||
        !widget.composerFocus.hasFocus ||
        _query == null ||
        _dismissed) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return true;
    }
    final items = _completion?.items ?? const <MentionCandidate>[];
    if (items.isEmpty || _pending) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlighted =
            (_highlighted +
                (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1)) %
            items.length;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (_highlighted == 0) _scroll.jumpTo(0);
        if (_highlighted == items.length - 1) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
        final row = _rowKeys[_highlighted]?.currentContext;
        if (row != null) Scrollable.ensureVisible(row);
      });
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      unawaited(_select(items[_highlighted].reference));
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    widget.composer.removeListener(_changed);
    HardwareKeyboard.instance.removeHandler(_key);
    _scroll.dispose();
    super.dispose();
  }

  Widget _header(MentionCompletion? completion, {required bool compact}) => Row(
    children: [
      if (completion?.parent case final parent?)
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Browse parent folder',
            onPressed: _pending ? null : () => _browse(parent),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
      Expanded(
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 12),
          child: Tooltip(
            message: completion?.directory ?? 'References',
            child: Text(
              completion?.directory ?? 'References',
              maxLines: compact || completion?.directory == null ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
      ),
      if (completion?.directory case final directory?)
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Add this folder as context',
            onPressed: _pending
                ? null
                : () => _select(
                    ComposerReference(
                      kind: ComposerReferenceKind.folder,
                      token: composerPathToken(
                        ComposerReferenceKind.folder,
                        directory,
                      ),
                      target: directory,
                    ),
                  ),
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ),
      if (_error != null)
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Retry references',
            onPressed: _pending ? null : () => _browse(_directory),
            icon: const Icon(Icons.refresh),
          ),
        ),
      StudioButtonPress(
        child: IconButton(
          tooltip: 'Close references',
          onPressed: _close,
          icon: const Icon(Icons.close),
        ),
      ),
    ],
  );

  Widget _failure(String error) => Flexible(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: StudioError(error),
      ),
    ),
  );

  Widget _leading(MentionCandidate item) {
    if (item.appearance case final bot?) {
      return BorrowedBotAvatar(bot: bot, name: bot.profile.name, size: 32);
    }
    return Icon(
      item.isCollective
          ? Icons.groups_outlined
          : item.reference.kind == ComposerReferenceKind.folder
          ? Icons.folder_outlined
          : item.reference.kind == ComposerReferenceKind.agent
          ? Icons.smart_toy_outlined
          : Icons.insert_drive_file_outlined,
      size: item.isCollective ? 24 : 20,
      color: Theme.of(context).colorScheme.primary,
    );
  }

  Widget _row(MentionCandidate item, int index) {
    final folder = item.reference.kind == ComposerReferenceKind.folder;
    final tokens = WingTokens.of(context);
    return StudioButtonPress(
      child: InkWell(
        key: _rowKeys.putIfAbsent(index, GlobalKey.new),
        onTap: _pending
            ? null
            : () {
                if (folder) {
                  _browse(item.reference.target);
                } else {
                  unawaited(_select(item.reference));
                }
              },
        child: Container(
          color: index == _highlighted
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsetsDirectional.only(start: 12),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 32,
                child: Center(child: _leading(item)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.label,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      if (item.detail.isNotEmpty)
                        Text(
                          item.detail,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: tokens.muted),
                        ),
                    ],
                  ),
                ),
              ),
              if (folder)
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Add ${item.label} as folder context',
                    onPressed: _pending ? null : () => _select(item.reference),
                    icon: const Icon(Icons.add),
                  ),
                ),
              if (!folder) const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_query == null || _dismissed) return const SizedBox.shrink();
    final completion = _completion;
    final tokens = WingTokens.of(context);
    final items = completion?.items ?? const <MentionCandidate>[];
    final notices = [
      ?completion?.warning,
      if (!_pending && items.isEmpty) 'No matching references. Edit the query.',
    ];
    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Material(
          color: tokens.raised,
          shape: RoundedRectangleBorder(
            borderRadius: WingRadius.card,
            side: BorderSide(color: tokens.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: LayoutBuilder(
              builder: (context, constraints) => StudioLoadingRegion(
                available: items.isNotEmpty || notices.isNotEmpty,
                busy: _loading,
                label: 'Loading mentions',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(completion, compact: constraints.maxHeight < 180),
                    if (_error case final error?) _failure(error),
                    if (_error == null &&
                        (items.isNotEmpty || notices.isNotEmpty))
                      Flexible(
                        child: ListView.builder(
                          controller: _scroll,
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            280,
                          ),
                          shrinkWrap: true,
                          padding: const EdgeInsets.only(bottom: 4),
                          itemCount: items.length + notices.length,
                          itemBuilder: (context, index) =>
                              index < notices.length
                              ? Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(notices[index]),
                                )
                              : _row(
                                  items[index - notices.length],
                                  index - notices.length,
                                ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
