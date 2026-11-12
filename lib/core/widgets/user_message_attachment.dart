import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../models/user_message_content.dart';
import '../services/owned_remote_files.dart';
import '../theme/wing_theme.dart';
import 'chat_image_preview.dart';
import 'resource_filename.dart';
import 'studio_error.dart';

typedef UserAttachmentImageLoader = Future<Uint8List> Function(String path);

class _AttachmentPreviewFailure extends StatelessWidget {
  const _AttachmentPreviewFailure({
    required this.name,
    required this.onRetry,
    this.width = 240,
    this.minHeight = 0,
    this.openAction,
  });

  final String name;
  final VoidCallback onRetry;
  final double width, minHeight;
  final Widget? openAction;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      minWidth: width,
      maxWidth: width,
      minHeight: minHeight,
    ),
    child: StudioErrorFrame(
      child: Padding(
        padding: const EdgeInsets.all(WingSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            StudioError(
              'Can’t load image',
              framed: false,
              stacked:
                  minHeight > 0 &&
                  width < 156 * MediaQuery.textScalerOf(context).scale(14) / 14,
            ),
            const SizedBox(height: WingSpacing.xs),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                children: [
                  ?openAction,
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Retry image preview',
                      style: IconButton.styleFrom(
                        minimumSize: const Size.square(48),
                        visualDensity: VisualDensity.standard,
                      ),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class UserMessageAttachmentTile extends StatefulWidget {
  final UserMessageAttachment attachment;
  final UserAttachmentImageLoader? loadImage;
  final bool loadImages;
  final Size? previewSize;
  final bool imageServerAvailable;
  final void Function(ImageProvider?)? onOpen;
  final ValueChanged<ImageProvider>? onImageReady;
  final int additionalImages;
  final Future<bool> Function(UserMessageAttachment)? onDownload;

  const UserMessageAttachmentTile({
    super.key,
    required this.attachment,
    this.loadImage,
    this.loadImages = true,
    this.previewSize,
    this.imageServerAvailable = true,
    this.onOpen,
    this.onImageReady,
    this.additionalImages = 0,
    this.onDownload,
  });

  @override
  State<UserMessageAttachmentTile> createState() =>
      _UserMessageAttachmentTileState();
}

class _UserMessageAttachmentTileState extends State<UserMessageAttachmentTile>
    with WidgetsBindingObserver {
  bool _failed = false;
  bool _downloading = false;
  String? _downloadError;
  int _downloadGeneration = 0;
  bool _acquired = false;
  int _generation = 0;
  ImageProvider? _currentProvider;
  late Future<ImageProvider>? _image = _load();

  String get _remainingImagesLabel {
    final count = widget.additionalImages;
    return '$count more ${count == 1 ? 'image' : 'images'}';
  }

  Future<ImageProvider>? _load() {
    _failed = false;
    _acquired = false;
    _generation++;
    _currentProvider = null;
    return widget.loadImages && widget.attachment.isImage
        ? _imageProvider()
        : null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        widget.imageServerAvailable &&
        (_failed || !_acquired && _image != null)) {
      _retry();
    }
  }

  void _retry() => setState(() {
    _image = _load();
  });

  Future<ImageProvider> _imageProvider() async {
    final generation = _generation;
    final resource = await acquireUserAttachmentImage(
      widget.attachment.target,
      widget.loadImage,
    );
    final ImageProvider provider = resource.bytes != null
        ? MemoryImage(resource.bytes!)
        : NetworkImage(resource.uri.toString());
    if (mounted && generation == _generation) {
      _acquired = true;
      _currentProvider = provider;
      widget.onImageReady?.call(provider);
    }
    return provider;
  }

  @override
  void didUpdateWidget(covariant UserMessageAttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.target != widget.attachment.target) {
      _downloadGeneration++;
      _downloading = false;
      _downloadError = null;
    }
    if (oldWidget.attachment.target != widget.attachment.target ||
        oldWidget.loadImages != widget.loadImages ||
        oldWidget.attachment.isImage != widget.attachment.isImage ||
        (!oldWidget.imageServerAvailable &&
            widget.imageServerAvailable &&
            (_failed || !_acquired && _image != null))) {
      _image = _load();
    }
  }

  void _open(ImageProvider provider) {
    if (widget.onOpen case final open?) {
      open(provider);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatImagePreview(
          title: widget.attachment.name,
          bytes: provider is MemoryImage ? provider.bytes : null,
          uri: provider is NetworkImage ? Uri.parse(provider.url) : null,
        ),
      ),
    );
  }

  Widget _fileCard() {
    final theme = Theme.of(context);
    final attachment = widget.attachment;
    if (widget.previewSize case final size?) {
      return Semantics(
        label: 'Image: ${attachment.name}',
        child: SizedBox.fromSize(
          size: size,
          child: Material(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: WingRadius.card,
            child: const Center(child: Icon(Icons.image_outlined)),
          ),
        ),
      );
    }
    return Container(
      width: 240,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: WingRadius.card,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  attachment.extension,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _download() async {
    if (_downloading || widget.onDownload == null) return;
    final generation = _downloadGeneration;
    setState(() {
      _downloading = true;
      _downloadError = null;
    });
    try {
      final saved = await widget.onDownload!(widget.attachment);
      if (saved && mounted && generation == _downloadGeneration) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('File saved')));
      }
    } catch (_) {
      if (mounted && generation == _downloadGeneration) {
        setState(
          () => _downloadError =
              'File could not be saved. Try downloading again.',
        );
      }
    } finally {
      if (mounted && generation == _downloadGeneration) {
        setState(() => _downloading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview();
    if (widget.onDownload == null) return preview;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        preview,
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Download ${widget.attachment.name}',
            onPressed: _downloading ? null : _download,
            icon: _downloading
                ? SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: MediaQuery.disableAnimationsOf(context)
                          ? .75
                          : null,
                      semanticsLabel: 'Downloading ${widget.attachment.name}',
                    ),
                  )
                : const Icon(Icons.download_outlined, size: 20),
          ),
        ),
        if (_downloadError case final error?) StudioError(error),
      ],
    );
  }

  Widget _imageCard(Widget child, {VoidCallback? onTap}) => ConstrainedBox(
    constraints: BoxConstraints(
      maxWidth: widget.previewSize?.width ?? 240,
      maxHeight: widget.previewSize?.height ?? 320,
    ),
    child: ClipRRect(
      borderRadius: WingRadius.card,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: WingRadius.card,
        child: StudioButtonPress(
          child: InkWell(onTap: onTap, child: _withGalleryCount(child)),
        ),
      ),
    ),
  );

  Widget _withGalleryCount(Widget child) {
    if (widget.additionalImages == 0) return child;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: .55),
              child: Center(
                child: Text(
                  '+${widget.additionalImages}',
                  semanticsLabel: _remainingImagesLabel,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _preview() {
    if (!widget.loadImages || !widget.attachment.isImage) {
      return _withGalleryCount(_fileCard());
    }
    return FutureBuilder<ImageProvider>(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return _loading();
        if (snapshot.hasError) return _failure();
        final provider = snapshot.data;
        if (provider == null) return _loading();
        _failed = false;
        return Image(
          image: ResizeImage.resizeIfNeeded(720, null, provider),
          width: widget.previewSize?.width ?? 240,
          height: widget.previewSize?.height,
          // Fill the capped preview with the top of a long screenshot.
          // The original provider still opens in the full-image viewer.
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          semanticLabel: 'Open image: ${widget.attachment.name}',
          frameBuilder: (_, child, frame, _) => frame == null
              ? _loading()
              : _imageCard(child, onTap: () => _open(provider)),
          errorBuilder: (_, _, _) => _failure(provider),
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : _loading(),
        );
      },
    );
  }

  Widget _failure([ImageProvider? provider]) {
    _failed = true;
    final open = widget.onOpen;
    final overflow = widget.additionalImages > 0 && open != null;
    return _AttachmentPreviewFailure(
      name: widget.attachment.name,
      width: widget.previewSize?.width ?? 240,
      minHeight: widget.previewSize?.height ?? 0,
      onRetry: _retry,
      openAction: provider != null || overflow
          ? StudioButtonPress(
              child: IconButton(
                tooltip: overflow
                    ? 'Open image gallery, $_remainingImagesLabel'
                    : open == null
                    ? 'Open original image'
                    : 'Open image gallery',
                onPressed: provider == null
                    ? () => open!(_currentProvider)
                    : () => _open(provider),
                icon: Icon(
                  open == null
                      ? Icons.image_outlined
                      : Icons.photo_library_outlined,
                  size: 20,
                ),
              ),
            )
          : null,
    );
  }

  Widget _loading() => _imageCard(
    SizedBox(
      width: widget.previewSize?.width ?? 240,
      height: widget.previewSize?.height ?? 180,
      child: const Center(
        child: CircularProgressIndicator(semanticsLabel: 'Loading attachment'),
      ),
    ),
    onTap: widget.additionalImages > 0 && widget.onOpen != null
        ? () => widget.onOpen!(_currentProvider)
        : null,
  );
}

/// Consecutive images share a compact two-column block; files retain order.
class UserMessageAttachments extends StatefulWidget {
  const UserMessageAttachments({
    super.key,
    required this.attachments,
    required this.width,
    this.loadImage,
    this.loadImages = true,
    this.imageServerAvailable = true,
    this.onDownload,
  });

  final Future<bool> Function(UserMessageAttachment)? onDownload;
  final List<UserMessageAttachment> attachments;
  final double width;
  final UserAttachmentImageLoader? loadImage;
  final bool loadImages;
  final bool imageServerAvailable;

  @override
  State<UserMessageAttachments> createState() => _UserMessageAttachmentsState();
}

class _UserMessageAttachmentsState extends State<UserMessageAttachments> {
  final _previewProviders = <String, ImageProvider>{};

  @override
  void didUpdateWidget(covariant UserMessageAttachments oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targets = widget.attachments
        .where((attachment) => attachment.isImage)
        .take(5)
        .map((attachment) => attachment.target)
        .toSet();
    _previewProviders.removeWhere(
      (target, _) => !widget.loadImages || !targets.contains(target),
    );
  }

  Widget _tile(
    BuildContext context,
    UserMessageAttachment attachment,
    List<UserMessageAttachment> images, [
    Size? size,
  ]) => UserMessageAttachmentTile(
    key: ValueKey(attachment.target),
    attachment: attachment,
    loadImage: widget.loadImage,
    loadImages: widget.loadImages,
    previewSize: size,
    imageServerAvailable: widget.imageServerAvailable,
    onDownload: widget.onDownload,
    onImageReady: (provider) {
      if (mounted) _previewProviders[attachment.target] = provider;
    },
    additionalImages: images.length > 5 && attachment == images[4]
        ? images.length - 5
        : 0,
    onOpen: widget.loadImages && attachment.isImage && images.length > 1
        ? (provider) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _UserMessageImageGallery(
                images: List.unmodifiable(images),
                initialIndex: images.indexOf(attachment),
                initialProvider: provider,
                previewProviders: Map.unmodifiable(_previewProviders),
                loadImage: widget.loadImage,
              ),
            ),
          )
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final images = widget.attachments
        .where((attachment) => attachment.isImage)
        .toList();
    final visible = images.take(5).toSet();
    final displayed = widget.attachments
        .where(
          (attachment) => !attachment.isImage || visible.contains(attachment),
        )
        .toList();
    final blocks = <Widget>[];
    for (var index = 0; index < displayed.length;) {
      final first = index++;
      if (displayed[first].isImage) {
        while (index < displayed.length && displayed[index].isImage) {
          index++;
        }
      }
      if (index - first == 1) {
        blocks.add(_tile(context, displayed[first], images));
        continue;
      }
      final edge = (widget.width - 4) / 2;
      final rows = <Widget>[];
      for (var image = first; image < index; image += 2) {
        if (rows.isNotEmpty) rows.add(const SizedBox(height: 4));
        rows.add(
          image + 1 == index
              ? _tile(
                  context,
                  displayed[image],
                  images,
                  Size(widget.width, edge),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tile(context, displayed[image], images, Size(edge, edge)),
                    const SizedBox(width: 4),
                    _tile(
                      context,
                      displayed[image + 1],
                      images,
                      Size(edge, edge),
                    ),
                  ],
                ),
        );
      }
      blocks.add(
        SizedBox(
          width: widget.width,
          child: Column(children: rows),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var index = 0; index < blocks.length; index++) ...[
          if (index > 0) const SizedBox(height: 12),
          blocks[index],
        ],
      ],
    );
  }
}

/// Lazily shares original reads between the viewer and visible strip thumbnails.
class _UserMessageImageGallery extends StatefulWidget {
  const _UserMessageImageGallery({
    required this.images,
    required this.initialIndex,
    required this.initialProvider,
    required this.previewProviders,
    required this.loadImage,
  });

  final List<UserMessageAttachment> images;
  final int initialIndex;
  final ImageProvider? initialProvider;
  final Map<String, ImageProvider> previewProviders;
  final UserAttachmentImageLoader? loadImage;

  @override
  State<_UserMessageImageGallery> createState() =>
      _UserMessageImageGalleryState();
}

class _UserMessageImageGalleryState extends State<_UserMessageImageGallery>
    with SingleTickerProviderStateMixin {
  static const _thumbnailExtent = 76.0;
  final _thumbnails = ScrollController();
  final _providers = <String, Future<ImageProvider>>{};
  final _navigationByPage = <int, bool>{};
  int _providerCapacity = 12;
  late int _index = widget.initialIndex;
  late final _pages = PageController(initialPage: widget.initialIndex);
  bool _navigationEnabled = true;
  late final AnimationController _jumpFade;

  @override
  void initState() {
    super.initState();
    _jumpFade = AnimationController(
      vsync: this,
      duration: WingMotion.standard,
      value: 1,
    );
    for (final entry in widget.previewProviders.entries) {
      _providers[entry.key] = Future.value(entry.value);
    }
    if (widget.initialProvider case final provider?) {
      _providers[widget.images[_index].target] = Future.value(provider);
    }
    _revealSelectedThumbnail();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareNeighbors());
  }

  @override
  void dispose() {
    _jumpFade.dispose();
    _pages.dispose();
    _thumbnails.dispose();
    super.dispose();
  }

  Future<ImageProvider> _provider(int index) {
    final target = widget.images[index].target;
    final image = _providers.remove(target) ?? _load(target);
    _providers[target] = image;
    // Keep a visible neighborhood, rather than every original in a large set.
    while (_providers.length > _providerCapacity) {
      _providers.remove(_providers.keys.first);
    }
    return image;
  }

  Future<ImageProvider> _load(String target) async {
    final resource = await acquireUserAttachmentImage(target, widget.loadImage);
    return resource.bytes != null
        ? MemoryImage(resource.bytes!)
        : NetworkImage(resource.uri.toString());
  }

  void _select(int index) {
    if (!_pages.hasClients || _pages.page == index.toDouble()) return;
    // Distant thumbnail jumps skip intervening originals rather than fetching
    // every image crossed by a long animated scroll.
    if (MediaQuery.disableAnimationsOf(context)) {
      _jumpFade.value = 1;
      _pages.jumpToPage(index);
    } else if ((index - _index).abs() > 1) {
      _pages.jumpToPage(index);
      _jumpFade.forward(from: 0);
    } else {
      _pages.animateToPage(
        index,
        duration: WingMotion.standard,
        curve: WingMotion.curve,
      );
    }
  }

  void _pageChanged(int index) {
    setState(() {
      _index = index;
      _navigationEnabled = _navigationByPage[index] ?? true;
    });
    _revealSelectedThumbnail(animate: true);
    _prepareNeighbors();
  }

  void _prepareNeighbors() {
    if (!mounted) return;
    for (final index in [_index - 1, _index + 1]) {
      if (index < 0 || index >= widget.images.length) continue;
      _provider(index).then((provider) {
        if (!mounted || (index - _index).abs() > 1) return;
        // Preparing only the immediate originals makes the incoming card
        // visible throughout the swipe without eagerly decoding an album.
        precacheImage(provider, context, onError: (_, _) {});
      }, onError: (Object _, StackTrace _) {});
    }
  }

  void _setNavigationEnabled(int index, bool enabled) {
    _navigationByPage[index] = enabled;
    if (index != _index || enabled == _navigationEnabled) return;
    if (!enabled && _pages.hasClients) {
      // A second finger or a zoom cancels paging already in progress.
      _pages.jumpToPage(_index);
    }
    setState(() => _navigationEnabled = enabled);
  }

  void _retry(int index) => setState(() {
    _providers.remove(widget.images[index].target);
  });

  void _revealSelectedThumbnail({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_thumbnails.hasClients) return;
      final position = _thumbnails.position;
      final offset =
          (_index + .5) * _thumbnailExtent - 4 - position.viewportDimension / 2;
      final target = offset.clamp(0.0, position.maxScrollExtent);
      // Animate the local reveal, but skip a distant stretch of originals.
      final nearby =
          (target - position.pixels).abs() <= position.viewportDimension;
      if (animate && nearby && !MediaQuery.disableAnimationsOf(context)) {
        _thumbnails.animateTo(
          target,
          duration: WingMotion.standard,
          curve: WingMotion.curve,
        );
      } else {
        _thumbnails.jumpTo(target);
      }
    });
  }

  Widget _thumbnail(int index) {
    final attachment = widget.images[index];
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: index == _index,
        label: attachment.name,
        child: Tooltip(
          message: attachment.name,
          child: AnimatedScale(
            scale: index == _index ? 1 : .94,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : WingMotion.fast,
            curve: WingMotion.curve,
            child: Material(
              color: index == _index
                  ? colors.primary
                  : colors.surfaceContainerHigh,
              animationDuration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : WingMotion.fast,
              borderRadius: WingRadius.card,
              child: StudioButtonPress(
                child: InkWell(
                  key: ValueKey('image-thumbnail-$index'),
                  borderRadius: WingRadius.card,
                  onTap: () => _select(index),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: ExcludeSemantics(
                        child: FutureBuilder<ImageProvider>(
                          future: _provider(index),
                          builder: (context, snapshot) {
                            final provider =
                                snapshot.connectionState == ConnectionState.done
                                ? snapshot.data
                                : null;
                            if (provider != null) {
                              return Image(
                                image: ResizeImage(
                                  provider,
                                  width: 144,
                                  height: 144,
                                  policy: ResizeImagePolicy.fit,
                                ),
                                fit: BoxFit.cover,
                                alignment: Alignment.topCenter,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.broken_image_outlined),
                              );
                            }
                            return Icon(
                              snapshot.hasError
                                  ? Icons.broken_image_outlined
                                  : Icons.image_outlined,
                            );
                          },
                        ),
                      ),
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

  Widget _navigation() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 72,
            child: ListView.builder(
              key: const PageStorageKey('user-image-gallery-thumbnails'),
              controller: _thumbnails,
              scrollDirection: Axis.horizontal,
              scrollCacheExtent: const ScrollCacheExtent.pixels(0),
              itemExtent: _thumbnailExtent,
              itemCount: widget.images.length,
              itemBuilder: (_, index) => _thumbnail(index),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              StudioButtonPress(
                child: IconButton(
                  tooltip: 'Previous image',
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(48),
                    visualDensity: VisualDensity.standard,
                  ),
                  onPressed: _index > 0 ? () => _select(_index - 1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
              ),
              Expanded(
                child: Text(
                  '${_index + 1} / ${widget.images.length}',
                  semanticsLabel:
                      'Image ${_index + 1} of ${widget.images.length}',
                  textAlign: TextAlign.center,
                ),
              ),
              StudioButtonPress(
                child: IconButton(
                  tooltip: 'Next image',
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(48),
                    visualDensity: VisualDensity.standard,
                  ),
                  onPressed: _index + 1 < widget.images.length
                      ? () => _select(_index + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _galleryFailure(int index) => SingleChildScrollView(
    primary: false,
    padding: const EdgeInsets.all(WingSpacing.lg),
    child: _AttachmentPreviewFailure(
      name: widget.images[index].name,
      onRetry: () => _retry(index),
    ),
  );

  Widget _page(int index) => FutureBuilder<ImageProvider>(
    future: _provider(index),
    builder: (context, snapshot) {
      final attachment = widget.images[index];
      final provider = snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : null;
      if (provider != null) {
        return ChatImageViewport(
          key: ValueKey(attachment.target),
          title: attachment.name,
          imageDecoration: BoxDecoration(
            borderRadius: WingRadius.card,
            boxShadow: [
              BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: .18),
                offset: const Offset(0, 6),
                blurRadius: 18,
              ),
            ],
          ),
          bytes: provider is MemoryImage ? provider.bytes : null,
          uri: provider is NetworkImage ? Uri.parse(provider.url) : null,
          failureContent: _galleryFailure(index),
          onNavigationEnabled: (enabled) =>
              _setNavigationEnabled(index, enabled),
        );
      }
      return Center(
        child:
            snapshot.connectionState == ConnectionState.done &&
                snapshot.hasError
            ? _galleryFailure(index)
            : const CircularProgressIndicator(
                semanticsLabel: 'Loading attachment',
              ),
      );
    },
  );

  Widget _cardPage(int index) => LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: _pages,
      child: _page(index),
      builder: (context, child) {
        final page = _pages.hasClients && _pages.position.hasContentDimensions
            ? _pages.page ?? _index.toDouble()
            : _index.toDouble();
        final distance = (index - page).clamp(-1.0, 1.0);
        final travel = distance.abs();
        if (MediaQuery.disableAnimationsOf(context)) return child!;
        // Compress the travel between fitted originals, so portrait images
        // exchange as neighboring cards rather than crossing a wide blank gap.
        final direction = Directionality.of(context) == TextDirection.rtl
            ? -1.0
            : 1.0;
        final inset =
            -distance * direction * (1 - travel) * constraints.maxWidth * .5;
        return Transform.translate(
          offset: Offset(inset, travel * 8),
          child: Transform.scale(
            key: ValueKey('gallery-card-motion-$index'),
            scale: 1 - travel * .12,
            child: Opacity(opacity: 1 - travel * .12, child: child),
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final visibleCapacity =
        (MediaQuery.sizeOf(context).width / _thumbnailExtent).ceil() + 4;
    _providerCapacity = visibleCapacity < 12 ? 12 : visibleCapacity;
    return Scaffold(
      appBar: ResourceViewerAppBar(
        context: context,
        title: widget.images[_index].name,
      ),
      bottomNavigationBar: _navigation(),
      body: Padding(
        padding: const EdgeInsets.all(4),
        child: FadeTransition(
          opacity: _jumpFade.drive(CurveTween(curve: WingMotion.curve)),
          child: ScaleTransition(
            scale: _jumpFade.drive(
              Tween(
                begin: .97,
                end: 1.0,
              ).chain(CurveTween(curve: WingMotion.curve)),
            ),
            child: PageView.builder(
              key: const ValueKey('user-image-gallery-pages'),
              controller: _pages,
              physics: _navigationEnabled
                  ? null
                  : const NeverScrollableScrollPhysics(),
              onPageChanged: _pageChanged,
              itemCount: widget.images.length,
              itemBuilder: (_, index) => _cardPage(index),
            ),
          ),
        ),
      ),
    );
  }
}
