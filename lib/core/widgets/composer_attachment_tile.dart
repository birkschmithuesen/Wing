import 'dart:typed_data';

import 'chat_image_preview.dart';
import 'resource_filename.dart';
import 'studio_error.dart';
import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';

import '../models/attachment_draft.dart';
import '../models/composer_work.dart';

/// Reveals new preparation feedback even when older attachments fill the strip.
class ComposerAttachmentStrip extends StatefulWidget {
  const ComposerAttachmentStrip({
    super.key,
    required this.preparing,
    required this.children,
  });

  final bool preparing;
  final List<Widget> children;

  @override
  State<ComposerAttachmentStrip> createState() =>
      _ComposerAttachmentStripState();
}

class _ComposerAttachmentStripState extends State<ComposerAttachmentStrip> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.preparing) _revealPending();
  }

  @override
  void didUpdateWidget(ComposerAttachmentStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.preparing && !oldWidget.preparing) _revealPending();
  }

  void _revealPending() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && widget.preparing && _scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  });

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: WingSpacing.sm,
        vertical: WingSpacing.sm,
      ),
      child: Row(children: widget.children),
    ),
  );
}

/// Keeps a pending batch and its first finished thumbnail in the same slot.
class ComposerAttachmentSlot extends StatelessWidget {
  const ComposerAttachmentSlot({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: WingSpacing.xs),
    child: MediaQuery.disableAnimationsOf(context)
        ? child
        : AnimatedSwitcher(
            duration: WingMotion.standard,
            switchInCurve: WingMotion.curve,
            switchOutCurve: WingMotion.curve,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.center,
              children: [
                for (final child in previous)
                  ExcludeSemantics(child: IgnorePointer(child: child)),
                ?current,
              ],
            ),
            child: child,
          ),
  );
}

/// Shared preparation feedback for camera, picker, clipboard and shared files.
class ComposerPendingAttachmentTile extends StatelessWidget {
  const ComposerPendingAttachmentTile({super.key, required this.preparation});

  final ComposerAttachmentPreparation preparation;

  @override
  Widget build(BuildContext context) {
    final photos = preparation.imageCount == preparation.count;
    final label = preparation.count == 1
        ? photos
              ? 'Adding photo…'
              : 'Adding file…'
        : photos
        ? 'Adding ${preparation.count} photos…'
        : 'Adding ${preparation.count} attachments…';
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Tooltip(
          message: label,
          child: SizedBox(
            width: 96,
            height: 96,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: WingRadius.card,
              ),
              child: Padding(
                padding: const EdgeInsets.all(WingSpacing.xs),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox.square(
                          dimension: 24,
                          child: MediaQuery.disableAnimationsOf(context)
                              ? Icon(
                                  photos
                                      ? Icons.photo_outlined
                                      : Icons.attach_file,
                                  color: theme.colorScheme.primary,
                                  size: 24,
                                )
                              : const CircularProgressIndicator(strokeWidth: 2),
                        ),
                        if (preparation.count > 1) ...[
                          const SizedBox(width: WingSpacing.sm),
                          Flexible(
                            child: Text(
                              '${preparation.count}',
                              style: theme.textTheme.labelSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: WingSpacing.sm),
                    Text(
                      'Adding',
                      style: theme.textTheme.labelSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

/// One presentation for image drafts from the clipboard, picker, camera or share.
class ComposerAttachmentTile extends StatelessWidget {
  final String name;
  final String? error;
  final AttachmentDraftKind kind;
  final ImageProvider? previewImage;
  final Future<Uint8List> Function()? readPreview;
  final VoidCallback? onRemove;

  const ComposerAttachmentTile({
    super.key,
    required this.name,
    required this.kind,
    required this.previewImage,
    this.error,
    this.readPreview,
    this.onRemove,
  }) : assert(kind != AttachmentDraftKind.image || previewImage != null);

  @override
  Widget build(BuildContext context) {
    final warning = error == null
        ? null
        : Tooltip(
            message: error!,
            child: const Icon(Icons.warning_amber_rounded, size: 18),
          );
    if (kind != AttachmentDraftKind.image) {
      return StudioButtonPress(
        child: InputChip(
          showCheckmark: false,
          avatar: warning,
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(name, overflow: TextOverflow.ellipsis),
          ),
          onDeleted: onRemove,
        ),
      );
    }

    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      key: const ValueKey('composer-image-thumbnail'),
      width: 96,
      height: 96,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: WingRadius.card,
            child: Material(
              child: StudioButtonPress(
                child: InkWell(
                  onTap: readPreview == null
                      ? null
                      : () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => _ComposerAttachmentPreview(
                              name: name,
                              readBytes: readPreview!,
                            ),
                          ),
                        ),
                  child: Tooltip(
                    message: 'Preview $name',
                    child: Image(
                      image: previewImage!,
                      fit: BoxFit.cover,
                      semanticLabel: 'Preview $name',
                      errorBuilder: (context, error, stackTrace) => ColoredBox(
                        color: colors.surfaceContainerHighest,
                        child: const Center(
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: 0,
              right: 0,
              child: StudioButtonPress(
                child: IconButton(
                  tooltip: 'Remove $name',
                  onPressed: onRemove,
                  icon: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHigh,
                      borderRadius: WingRadius.control,
                    ),
                    child: Icon(Icons.close, color: colors.onSurface, size: 16),
                  ),
                ),
              ),
            ),
          if (warning != null)
            Positioned(
              left: 4,
              bottom: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: warning,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ComposerAttachmentPreview extends StatefulWidget {
  const _ComposerAttachmentPreview({
    required this.name,
    required this.readBytes,
  });

  final String name;
  final Future<Uint8List> Function() readBytes;

  @override
  State<_ComposerAttachmentPreview> createState() =>
      _ComposerAttachmentPreviewState();
}

class _ComposerAttachmentPreviewState
    extends State<_ComposerAttachmentPreview> {
  late final Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = Future<Uint8List>.sync(widget.readBytes);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) {
      if (snapshot.data case final bytes?) {
        return ChatImagePreview(bytes: bytes, title: widget.name);
      }
      return Scaffold(
        appBar: ResourceViewerAppBar(context: context, title: widget.name),
        body: Center(
          child: snapshot.hasError
              ? const StudioError('This image could not be previewed.')
              : const CircularProgressIndicator(
                  semanticsLabel: 'Loading image',
                ),
        ),
      );
    },
  );
}
