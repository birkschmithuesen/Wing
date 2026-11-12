import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/theme/wing_theme.dart';
import '../core/widgets/chat_image_preview.dart';
import '../core/widgets/studio_error.dart';

/// Formats `Image.memory` can decode directly; svg has no renderer here.
final _inlineImageExtension = RegExp(
  r'\.(?:png|jpe?g|gif|webp|bmp)(?:\?.*)?$',
  caseSensitive: false,
);

/// Without a minimum, `Image`'s dry layout is zero-height until its bytes
/// finish decoding (`RenderImage` has no aspect ratio to size from yet), so
/// a tap landing in that instant would hit nothing.
const _minThumbnailHeight = 160.0;

/// Inline thumbnail for an image deliverable; falls back to [card] while
/// loading or on error.
class InlineMediaThumbnail extends StatefulWidget {
  const InlineMediaThumbnail({
    super.key,
    required this.path,
    required this.label,
    required this.load,
    required this.card,
    required this.actions,
    this.error,
  });

  final String path;

  /// Names the thumbnail for accessibility and titles the zoom preview.
  final String label;

  /// Same authenticated fetch the card's Download/Open actions use, reused
  /// here to decode a thumbnail instead of saving or opening the file.
  final Future<Uint8List> Function(String path) load;

  /// The file card shown while the image loads or when it fails to load.
  final Widget card;

  /// The Download / Open preview row shown under the thumbnail.
  final Widget actions;

  /// Action error shown under [actions].
  final String? error;

  static bool handles(String path) => _inlineImageExtension.hasMatch(path);

  @override
  State<InlineMediaThumbnail> createState() => _InlineMediaThumbnailState();
}

class _InlineMediaThumbnailState extends State<InlineMediaThumbnail> {
  // Static: survives the list recycling individual rows out of existence
  // while the user scrolls, so a re-shown thumbnail does not refetch.
  static final _imageCache = <String, Uint8List>{};

  late Future<Uint8List> _image;

  @override
  void initState() {
    super.initState();
    _image = _loadImage();
  }

  Future<Uint8List> _loadImage() {
    final target = widget.path;
    final cached = _imageCache[target];
    if (cached != null) return Future.value(cached);
    return widget.load(target).then((bytes) {
      _imageCache[target] = bytes;
      return bytes;
    });
  }

  @override
  void didUpdateWidget(InlineMediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _image = _loadImage();
  }

  void _openPreview(Uint8List bytes) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatImagePreview(bytes: bytes, title: widget.label),
      ),
    );
  }

  Widget _imageCard(BuildContext context, Uint8List bytes) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: WingSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: WingRadius.control,
            child: Material(
              color: theme.colorScheme.surfaceContainerLow,
              child: InkWell(
                onTap: () => _openPreview(bytes),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: _minThumbnailHeight,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.6,
                  ),
                  child: Image.memory(
                    bytes,
                    width: double.infinity,
                    fit: BoxFit.contain,
                    semanticLabel: 'Open image: ${widget.label}',
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: WingSpacing.xs),
          widget.actions,
          if (widget.error != null) ...[
            const SizedBox(height: WingSpacing.xs),
            StudioError(widget.error!),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _image,
      builder: (context, snapshot) => snapshot.hasData
          ? _imageCard(context, snapshot.data!)
          : widget.card,
    );
  }
}
