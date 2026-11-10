import 'studio_error.dart';
import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'resource_filename.dart';

/// Opened only after tapping an image in a conversation.
class ChatImagePreview extends StatefulWidget {
  final Uri? uri;
  final Uint8List? bytes;
  final String title;
  final String? resourceTarget;
  final Future<String?> Function()? onOpenExternal;
  final String actionLabel;
  final IconData actionIcon;

  const ChatImagePreview({
    super.key,
    this.uri,
    this.bytes,
    required this.title,
    this.resourceTarget,
    this.onOpenExternal,
    this.actionLabel = 'Open in browser',
    this.actionIcon = Icons.open_in_new,
  }) : assert((uri == null) != (bytes == null));

  @override
  State<ChatImagePreview> createState() => _ChatImagePreviewState();
}

class _ChatImagePreviewState extends State<ChatImagePreview> {
  final _errorKey = Object();
  bool _opening = false;

  Future<void> _openExternal(BuildContext anchor) async {
    final open = widget.onOpenExternal;
    if (_opening || open == null) return;
    dismissTransientError(anchor, errorKey: _errorKey);
    setState(() => _opening = true);
    try {
      final error = await open();
      if (error != null && anchor.mounted) {
        showTransientError(
          anchor,
          error,
          errorKey: _errorKey,
          icon: widget.actionIcon,
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _action() => Builder(
    builder: (anchor) => ResourceViewerAction(
      label: _opening ? 'Preparing image' : widget.actionLabel,
      icon: _opening ? Icons.hourglass_top : widget.actionIcon,
      onPressed: _opening ? null : () => _openExternal(anchor),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: ResourceViewerAppBar(
      context: context,
      title: widget.title,
      target: widget.resourceTarget,
      actions: [if (widget.onOpenExternal != null) _action()],
    ),
    body: ChatImageViewport(
      uri: widget.uri,
      bytes: widget.bytes,
      title: widget.title,
      imageDecoration: const BoxDecoration(),
      failureAction: widget.onOpenExternal == null ? null : _action(),
    ),
  );
}

/// Image-only zoom surface shared by single-image and gallery routes.
class ChatImageViewport extends StatefulWidget {
  const ChatImageViewport({
    super.key,
    this.uri,
    this.bytes,
    required this.title,
    required this.imageDecoration,
    this.failureAction,
    this.onNavigationEnabled,
  }) : assert((uri == null) != (bytes == null));

  final Uri? uri;
  final Uint8List? bytes;
  final String title;
  final BoxDecoration imageDecoration;
  final Widget? failureAction;
  final ValueChanged<bool>? onNavigationEnabled;

  @override
  State<ChatImageViewport> createState() => _ChatImageViewportState();
}

class _ChatImageViewportState extends State<ChatImageViewport> {
  final _transform = TransformationController();
  final _pointers = <int>{};
  bool _zoomed = false;
  bool _navigationEnabled = true;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_reportNavigation);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onNavigationEnabled?.call(_navigationEnabled);
    });
  }

  void _reportNavigation() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
    final enabled = !zoomed && _pointers.length < 2;
    if (enabled == _navigationEnabled) return;
    _navigationEnabled = enabled;
    widget.onNavigationEnabled?.call(enabled);
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) {
      _pointers.add(event.pointer);
      _reportNavigation();
    },
    onPointerUp: (event) {
      _pointers.remove(event.pointer);
      _reportNavigation();
    },
    onPointerCancel: (event) {
      _pointers.remove(event.pointer);
      _reportNavigation();
    },
    child: Center(
      child: InteractiveViewer(
        transformationController: _transform,
        panEnabled: _zoomed,
        minScale: 0.5,
        maxScale: 5,
        child: Padding(
          padding: widget.imageDecoration.boxShadow?.isNotEmpty == true
              ? const EdgeInsets.all(8)
              : EdgeInsets.zero,
          child: DecoratedBox(
            decoration: _zoomed
                ? const BoxDecoration()
                : widget.imageDecoration,
            child: ClipRRect(
              borderRadius: _zoomed
                  ? BorderRadius.zero
                  : (widget.imageDecoration.borderRadius ?? BorderRadius.zero)
                        .resolve(Directionality.of(context)),
              child: Image(
                image: widget.bytes == null
                    ? NetworkImage(widget.uri.toString())
                    : MemoryImage(widget.bytes!),
                semanticLabel: widget.title,
                fit: BoxFit.contain,
                frameBuilder: (context, child, frame, synchronouslyLoaded) =>
                    frame != null || synchronouslyLoaded
                    ? child
                    : const Center(
                        child: CircularProgressIndicator(
                          semanticsLabel: 'Loading image',
                        ),
                      ),
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : const Center(
                        child: CircularProgressIndicator(
                          semanticsLabel: 'Loading image',
                        ),
                      ),
                errorBuilder: (context, error, stack) => SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const StudioError('This image could not be previewed.'),
                      if (widget.failureAction case final action?) ...[
                        const SizedBox(height: 12),
                        action,
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
  );
}
