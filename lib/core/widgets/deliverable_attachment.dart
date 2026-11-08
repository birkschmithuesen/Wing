import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/chat_output.dart';
import '../services/file_open_error_message.dart';
import '../theme/wing_theme.dart';
import 'chat_image_preview.dart';
import 'studio_action_label.dart';
import 'studio_error.dart';

/// Formats `Image.memory` can decode directly; svg has no renderer here.
final _inlineImageExtension = RegExp(
  r'\.(?:png|jpe?g|gif|webp|bmp)(?:\?.*)?$',
  caseSensitive: false,
);

/// Without a minimum, `Image`'s dry layout is zero-height until its bytes
/// finish decoding (`RenderImage` has no aspect ratio to size from yet), so
/// a tap landing in that instant would hit nothing.
const _minThumbnailHeight = 160.0;

/// Desktop's Download / Open preview actions adapted to a phone's width.
class DeliverableAttachment extends StatefulWidget {
  const DeliverableAttachment({
    super.key,
    required this.output,
    required this.onOpen,
    required this.onDownload,
    this.onLoadImage,
  });

  final ChatOutput output;
  final Future<void> Function(ChatOutput)? onOpen;
  final Future<bool> Function(ChatOutput)? onDownload;

  /// Same authenticated fetch the card's Download/Open actions use, reused
  /// here to decode a thumbnail instead of saving or opening the file.
  final Future<Uint8List> Function(ChatOutput)? onLoadImage;

  @override
  State<DeliverableAttachment> createState() => _DeliverableAttachmentState();
}

class _DeliverableAttachmentState extends State<DeliverableAttachment> {
  bool _opening = false;
  bool _downloading = false;
  String? _error;
  int _generation = 0;
  Future<Uint8List>? _image;

  // Static: survives the list recycling individual rows out of existence
  // while the user scrolls, so a re-shown thumbnail does not refetch.
  static final _imageCache = <String, Uint8List>{};

  bool get _showsInlineImage =>
      widget.output.kind == ChatOutputKind.image &&
      widget.onLoadImage != null &&
      _inlineImageExtension.hasMatch(widget.output.target);

  @override
  void initState() {
    super.initState();
    if (_showsInlineImage) _image = _loadImage();
  }

  Future<Uint8List> _loadImage() {
    final target = widget.output.target;
    final cached = _imageCache[target];
    if (cached != null) return Future.value(cached);
    return widget.onLoadImage!(widget.output).then((bytes) {
      _imageCache[target] = bytes;
      return bytes;
    });
  }

  @override
  void didUpdateWidget(DeliverableAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.output.target != widget.output.target) {
      _generation++;
      _opening = false;
      _downloading = false;
      _error = null;
      _image = _showsInlineImage ? _loadImage() : null;
    }
  }

  Future<void> _run({required bool download}) async {
    if (download ? _downloading : _opening) return;
    final generation = _generation;
    setState(() {
      if (download) {
        _downloading = true;
      } else {
        _opening = true;
      }
      _error = null;
    });
    try {
      if (download) {
        final saved = await widget.onDownload!(widget.output);
        if (saved && mounted && generation == _generation) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('File saved')));
        }
      } else {
        await widget.onOpen!(widget.output);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = fileOpenErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          if (download) {
            _downloading = false;
          } else {
            _opening = false;
          }
        });
      }
    }
  }

  Widget _actions() => Wrap(
    alignment: WrapAlignment.center,
    spacing: WingSpacing.sm,
    runSpacing: WingSpacing.xs,
    children: [
      OutlinedButton(
        onPressed: widget.onDownload == null || _downloading
            ? null
            : () => _run(download: true),
        child: StudioActionLabel.compact(
          'Download',
          busy: _downloading,
          icon: Icons.download_outlined,
        ),
      ),
      OutlinedButton(
        onPressed: widget.onOpen == null || _opening
            ? null
            : () => _run(download: false),
        child: const Text('Open preview', textAlign: TextAlign.center),
      ),
    ],
  );

  Widget _card(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: WingSpacing.xs),
      padding: const EdgeInsets.all(WingSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: WingRadius.control,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: WingSpacing.sm),
              Expanded(
                child: Text(
                  widget.output.label,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: WingSpacing.xs),
          _actions(),
          if (_error != null) ...[
            const SizedBox(height: WingSpacing.xs),
            StudioError(_error!),
          ],
        ],
      ),
    );
  }

  void _openPreview(Uint8List bytes) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ChatImagePreview(bytes: bytes, title: widget.output.label),
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
                    semanticLabel: 'Open image: ${widget.output.label}',
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: WingSpacing.xs),
          _actions(),
          if (_error != null) ...[
            const SizedBox(height: WingSpacing.xs),
            StudioError(_error!),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_showsInlineImage) return _card(context);
    return FutureBuilder<Uint8List>(
      future: _image,
      builder: (context, snapshot) => snapshot.hasData
          ? _imageCard(context, snapshot.data!)
          : _card(context),
    );
  }
}
