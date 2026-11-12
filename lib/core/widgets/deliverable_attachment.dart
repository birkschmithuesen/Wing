import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/chat_output.dart';
import '../services/file_open_error_message.dart';
import '../theme/wing_theme.dart';
import 'studio_error.dart';
import 'chat_inline_image.dart';

/// Desktop's Download / Open preview actions adapted to a phone's width.
class DeliverableAttachment extends StatefulWidget {
  const DeliverableAttachment({
    super.key,
    required this.output,
    required this.onOpen,
    required this.onDownload,
    this.loadImage,
  });

  final ChatOutput output;
  final Future<void> Function(ChatOutput)? onOpen;
  final Future<bool> Function(ChatOutput)? onDownload;
  final Future<Uint8List> Function(String path)? loadImage;

  @override
  State<DeliverableAttachment> createState() => _DeliverableAttachmentState();
}

class _DeliverableAttachmentState extends State<DeliverableAttachment> {
  bool _opening = false;
  bool _downloading = false;
  String? _error;
  int _generation = 0;

  @override
  void didUpdateWidget(DeliverableAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.output.target != widget.output.target) {
      _generation++;
      _opening = false;
      _downloading = false;
      _error = null;
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

  Widget _actionIcon(
    IconData icon, {
    required bool pending,
    required String label,
  }) => SizedBox.square(
    dimension: 20,
    child: pending
        ? CircularProgressIndicator(
            strokeWidth: 2,
            backgroundColor: Theme.of(context).colorScheme.outlineVariant,
            value: MediaQuery.disableAnimationsOf(context) ? 0.75 : null,
            semanticsLabel: label,
          )
        : Icon(icon, size: 20),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.output.kind == ChatOutputKind.image) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: WingSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ChatInlineImage(
              target: widget.output.target,
              title: widget.output.label,
              loadImage: widget.loadImage,
              downloadAction: StudioButtonPress(
                child: IconButton.filledTonal(
                  tooltip: _downloading ? 'Saving image' : 'Download image',
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: widget.onDownload == null || _downloading
                      ? null
                      : () => _run(download: true),
                  icon: _actionIcon(
                    Icons.download_outlined,
                    pending: _downloading,
                    label: 'Saving image',
                  ),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: WingSpacing.xs),
              StudioError(_error!),
            ],
          ],
        ),
      );
    }
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
            crossAxisAlignment: CrossAxisAlignment.center,
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
              const SizedBox(width: WingSpacing.xs),
              StudioButtonPress(
                child: IconButton(
                  tooltip: 'Download',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: theme.colorScheme.primary,
                  ),
                  onPressed: widget.onDownload == null || _downloading
                      ? null
                      : () => _run(download: true),
                  icon: _actionIcon(
                    Icons.download_outlined,
                    pending: _downloading,
                    label: 'Saving file',
                  ),
                ),
              ),
              StudioButtonPress(
                child: IconButton(
                  tooltip: 'Open preview',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: theme.colorScheme.primary,
                  ),
                  onPressed: widget.onOpen == null || _opening
                      ? null
                      : () => _run(download: false),
                  icon: _actionIcon(
                    Icons.visibility_outlined,
                    pending: _opening,
                    label: 'Opening preview',
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: WingSpacing.xs),
            StudioError(_error!),
          ],
        ],
      ),
    );
  }
}
