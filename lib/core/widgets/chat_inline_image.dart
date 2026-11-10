import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/owned_remote_files.dart';
import '../services/web_preview.dart';
import '../models/app_preferences.dart';
import '../theme/wing_theme.dart';
import 'chat_image_preview.dart';
import 'studio_error.dart';

/// A bounded conversation preview; the viewer always receives the original.
class ChatInlineImage extends StatefulWidget {
  const ChatInlineImage({
    super.key,
    required this.target,
    required this.title,
    this.loadImage,
    this.downloadAction,
    this.toolReceipt = false,
    this.headerBuilder,
  });

  final String target;
  final String title;
  final Future<Uint8List> Function(String path)? loadImage;
  final Widget? downloadAction;
  final bool toolReceipt;
  final Widget Function(BuildContext, VoidCallback?)? headerBuilder;

  @override
  State<ChatInlineImage> createState() => _ChatInlineImageState();
}

class _ChatInlineImageState extends State<ChatInlineImage> {
  late Future<ImageProvider> _image = _imageProvider();
  int _attempt = 0;

  Future<ImageProvider> _imageProvider() async {
    final resource = await (widget.toolReceipt
        ? acquireToolReceiptImage
        : acquireConversationImage)(widget.target, widget.loadImage);
    return resource.bytes != null
        ? MemoryImage(resource.bytes!)
        : NetworkImage(resource.uri.toString());
  }

  @override
  void didUpdateWidget(ChatInlineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target != widget.target ||
        (oldWidget.loadImage == null) != (widget.loadImage == null)) {
      _attempt++;
      _image = _imageProvider();
    }
  }

  void _open(ImageProvider provider) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatImagePreview(
          title: widget.title,
          resourceTarget: widget.target.startsWith('data:')
              ? null
              : widget.target,
          bytes: provider is MemoryImage ? provider.bytes : null,
          uri: provider is NetworkImage ? Uri.parse(provider.url) : null,
          onOpenExternal: provider is NetworkImage
              ? () async {
                  try {
                    if (await openWebLink(
                      Uri.parse(provider.url),
                      WebLinkDestination.externalBrowser,
                    )) {
                      return null;
                    }
                  } catch (_) {
                    // The preview remains usable if the external launch fails.
                  }
                  return 'Could not open this image in the browser.';
                }
              : null,
        ),
      ),
    );
  }

  Widget _loading(double width) => SizedBox(
    width: width,
    height: math.min(320, width * 3 / 4),
    child: const Center(
      child: CircularProgressIndicator(semanticsLabel: 'Loading image'),
    ),
  );

  Widget _unavailable() => Padding(
    padding: widget.headerBuilder != null
        ? EdgeInsets.zero
        : EdgeInsets.fromLTRB(
            WingSpacing.sm,
            WingSpacing.sm,
            WingSpacing.sm,
            widget.downloadAction == null ? WingSpacing.sm : 60,
          ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const StudioError('This image could not be previewed.'),
        const SizedBox(height: WingSpacing.xs),
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Retry image',
            constraints: widget.toolReceipt
                ? const BoxConstraints.tightFor(width: 32, height: 32)
                : null,
            padding: widget.toolReceipt
                ? EdgeInsets.zero
                : const EdgeInsets.all(8),
            visualDensity: widget.toolReceipt ? VisualDensity.compact : null,
            onPressed: () => setState(() {
              _attempt++;
              _image = _imageProvider();
            }),
            icon: Icon(Icons.refresh, size: widget.toolReceipt ? 16 : null),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.headerBuilder != null) {
      return FutureBuilder<ImageProvider>(
        future: _image,
        builder: (context, snapshot) {
          final provider = snapshot.data;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              widget.headerBuilder!(
                context,
                provider == null ? null : () => _open(provider),
              ),
              Padding(
                padding: const EdgeInsets.all(WingSpacing.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _preview(context),
                ),
              ),
            ],
          );
        },
      );
    }
    return _preview(context);
  }

  Widget _preview(BuildContext context) {
    // Desktop caps previews without cropping or upscaling. A 4:3 cold frame
    // reserves loading space; the decoded preview hugs the image. Avoid
    // LayoutBuilder because Markdown table cells measure intrinsic dimensions.
    final width = math.min(420.0, MediaQuery.sizeOf(context).width - 32);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: ClipRRect(
        borderRadius: WingRadius.control,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Stack(
            alignment: widget.toolReceipt
                ? Alignment.centerLeft
                : Alignment.center,
            children: [
              FutureBuilder<ImageProvider>(
                key: ValueKey((widget.target, _attempt)),
                future: _image,
                builder: (context, snapshot) {
                  if (snapshot.hasError) return _unavailable();
                  final provider = snapshot.data;
                  if (provider == null) return _loading(width);
                  return StudioButtonPress(
                    child: InkWell(
                      onTap: () => _open(provider),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: width,
                          maxHeight: 320,
                        ),
                        child: Image(
                          key: ValueKey((widget.target, _attempt)),
                          image: ResizeImage(
                            provider,
                            width: (width * ratio).ceil(),
                            height: (320 * ratio).ceil(),
                            policy: ResizeImagePolicy.fit,
                          ),
                          fit: BoxFit.scaleDown,
                          semanticLabel: 'Open image: ${widget.title}',
                          frameBuilder: (_, child, frame, _) =>
                              frame == null ? _loading(width) : child,
                          errorBuilder: (_, _, _) => _unavailable(),
                          loadingBuilder: (_, child, progress) =>
                              progress == null ? child : _loading(width),
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (widget.downloadAction != null)
                Positioned(
                  right: WingSpacing.xs,
                  bottom: WingSpacing.xs,
                  child: widget.downloadAction!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
