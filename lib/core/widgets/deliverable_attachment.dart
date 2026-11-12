import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../fork/inline_media_thumbnail.dart';
import '../models/chat_output.dart';
import '../services/file_open_error_message.dart';
import '../theme/wing_theme.dart';
import 'studio_action_label.dart';
import 'studio_error.dart';

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
  final Future<Uint8List> Function(ChatOutput)? onLoadImage;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actions = Wrap(
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
    final card = Container(
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
          actions,
          if (_error != null) ...[
            const SizedBox(height: WingSpacing.xs),
            StudioError(_error!),
          ],
        ],
      ),
    );
    final load = widget.onLoadImage;
    if (load != null &&
        widget.output.kind == ChatOutputKind.image &&
        InlineMediaThumbnail.handles(widget.output.target)) {
      return InlineMediaThumbnail(
        path: widget.output.target,
        label: widget.output.label,
        load: (_) => load(widget.output),
        card: card,
        actions: actions,
        error: _error,
      );
    }
    return card;
  }
}
