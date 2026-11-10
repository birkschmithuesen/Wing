import 'package:flutter/foundation.dart' show mapEquals;
import 'dart:typed_data';

import 'studio_task_marker.dart';
import 'studio_error.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../models/chat_output.dart';
import '../models/deliverable_reference.dart';
import '../services/file_open_error_message.dart';
import '../services/email_composer.dart';
import '../services/markdown_inline_parser.dart';
import '../services/markdown_segments.dart';
import '../services/markdown_qa_variant.dart';
import '../services/completion_diagnostics.dart';
import '../services/web_preview.dart';
import '../theme/profile_markdown_style.dart';
import '../theme/wing_theme.dart';
import 'chat_inline_image.dart';
import 'studio_loading.dart';
import 'bot_mention_scope.dart';
import 'markdown_code_block.dart';
import 'block_reusing_markdown_body.dart';
import 'background_markdown_content.dart';
import 'deliverable_attachment.dart';

typedef MarkdownHeadingAnchor = ({String label, int level, GlobalKey key});

/// Renders Markdown message content without conversation chrome.
class MarkdownMessageContent extends StatefulWidget {
  final String data;
  final bool streaming;
  final bool loadImages;
  final Future<void> Function(ChatOutput output)? onOpenRemoteFile;
  final Future<bool> Function(ChatOutput output)? onDownloadRemoteFile;
  final Future<Uint8List> Function(String path)? loadImage;
  final bool deliverables;
  final String? documentPath;
  final String? initialFragment;
  final ValueChanged<List<MarkdownHeadingAnchor>>? onHeadings;

  const MarkdownMessageContent({
    super.key,
    required this.data,
    this.streaming = false,
    this.loadImages = true,
    this.onOpenRemoteFile,
    this.onDownloadRemoteFile,
    this.loadImage,
    this.deliverables = false,
    this.documentPath,
    this.initialFragment,
    this.onHeadings,
  });

  @override
  State<MarkdownMessageContent> createState() => _MarkdownMessageContentState();
}

class _MarkdownMessageContentState extends State<MarkdownMessageContent> {
  bool _openingEmail = false;
  String? _linkError;
  // Retain only this mounted message's rendering. Unrelated stream/activity
  // updates must not split code fences, recreate styles and reparse its prose.
  Widget? _content;
  List<({Object source, Widget child})> _segments = const [];
  bool _refreshSegments = true;
  Object? _renderingInputs;
  Map<String, String>? _mentionNames;
  bool _segmentsStreaming = false;
  MarkdownStyleSheet? _styleSheet;
  ThemeData? _markdownTheme;
  Map<String, MarkdownElementBuilder>? _markdownBuilders;
  final _parsers = <int, MarkdownInlineParser>{};
  final _deliverableSyntaxes = <md.InlineSyntax>[
    MediaReferenceSyntax(),
    DeliverableLinkSyntax(),
    LiteralCodeSyntax(guard: markdownQaVariant != MarkdownQaVariant.baseline),
    HtmlFilePathSyntax(),
  ];
  final _headingKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event(
        'markdown.message.init',
        values: {'streaming': widget.streaming ? 1 : 0},
      );
    }
    _scheduleFragment();
  }

  void _scheduleFragment() {
    if (widget.initialFragment == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToFragment(widget.initialFragment!);
    });
  }

  Future<void> _scrollToFragment(String fragment) async {
    final target = fragment.isEmpty
        ? context
        : _headingKeys[fragment]?.currentContext;
    if (target != null) {
      // The marker is inline; align the complete heading, not its midpoint.
      final heading = target.findAncestorRenderObjectOfType<RenderWrap>();
      await Scrollable.of(target).position.ensureVisible(
        heading ?? target.findRenderObject()!,
        alignment: 0,
      );
    } else if (mounted) {
      _showLinkFailure('This heading is not in the available preview.');
    }
  }

  @override
  void didUpdateWidget(covariant MarkdownMessageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data ||
        widget.documentPath != oldWidget.documentPath) {
      _linkError = null;
    }
    if (widget.data != oldWidget.data ||
        widget.loadImages != oldWidget.loadImages ||
        widget.streaming != oldWidget.streaming ||
        widget.deliverables != oldWidget.deliverables ||
        widget.documentPath != oldWidget.documentPath ||
        widget.initialFragment != oldWidget.initialFragment ||
        (widget.onHeadings == null) != (oldWidget.onHeadings == null) ||
        (widget.loadImage == null) != (oldWidget.loadImage == null) ||
        (widget.onOpenRemoteFile == null) !=
            (oldWidget.onOpenRemoteFile == null) ||
        (widget.onDownloadRemoteFile == null) !=
            (oldWidget.onDownloadRemoteFile == null)) {
      _content = null;
      if (CompletionDiagnostics.enabled) {
        CompletionDiagnostics.event(
          'markdown.message.invalidate',
          values: {
            'dataChanged': widget.data != oldWidget.data ? 1 : 0,
            'streamingChanged': widget.streaming != oldWidget.streaming ? 1 : 0,
          },
        );
      }
    }
    if (widget.deliverables != oldWidget.deliverables ||
        widget.loadImages != oldWidget.loadImages ||
        (widget.loadImage == null) != (oldWidget.loadImage == null) ||
        widget.documentPath != oldWidget.documentPath ||
        (widget.onOpenRemoteFile == null) !=
            (oldWidget.onOpenRemoteFile == null) ||
        (widget.onDownloadRemoteFile == null) !=
            (oldWidget.onDownloadRemoteFile == null)) {
      _markdownBuilders = null;
      _refreshSegments = true;
      _parsers.clear();
    }
    if (widget.initialFragment != oldWidget.initialFragment) {
      _scheduleFragment();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inputs = (
      Theme.of(context),
      MediaQuery.sizeOf(context),
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
    );
    final names = BotMentionScope.of(context)?.names;
    // Reparenting a completed answer rechecks dependencies. Keep its rendered
    // blocks when the actual environment is unchanged.
    if (_renderingInputs == inputs && mapEquals(_mentionNames, names)) return;
    _renderingInputs = inputs;
    _mentionNames = names;
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.message.dependencies');
    }
    // Theme, text scale and viewport changes still refresh the rendered content.
    _content = null;
    _styleSheet = null;
    _markdownTheme = null;
    _markdownBuilders = null;
    _refreshSegments = true;
  }

  void _showLinkFailure(String message) {
    if (mounted && ModalRoute.of(context)?.isCurrent != false) {
      setState(() => _linkError = message);
    }
  }

  Future<void> _open(String href) async {
    if (_openingEmail) return;
    if (_linkError != null) setState(() => _linkError = null);
    if (EmailComposer.accepts(href)) {
      setState(() => _openingEmail = true);
      final opened = await EmailComposer.open(href);
      if (!mounted) return;
      setState(() => _openingEmail = false);
      if (!opened) {
        _showLinkFailure(
          'Could not open an email app. Install or enable one and try again.',
        );
      }
      return;
    }
    final uri = externalWebLink(href);
    if (uri != null) {
      final opened = await openWebPreview(uri);
      if (!opened) _showLinkFailure('Could not open this link.');
      return;
    }
    final output = widget.documentPath == null
        ? explicitRemoteFileOutput(href)
        : resolveDocumentFileLink(href, widget.documentPath!);
    if (output != null &&
        output.path == widget.documentPath &&
        output.fragment != null) {
      await _scrollToFragment(output.fragment!);
      return;
    }
    if (output != null && widget.onOpenRemoteFile != null) {
      try {
        await widget.onOpenRemoteFile!(output);
      } catch (error) {
        _showLinkFailure(fileOpenErrorMessage(error));
      }
      return;
    }
    _showLinkFailure(
      'Only web links, email links and linked Hermes files can be opened here.',
    );
  }

  void _tapLink(String text, String? href, String title) {
    if (href != null) _open(href);
  }

  Widget _buildImage(MarkdownImageConfig config) {
    if (!widget.loadImages) {
      return Text(config.alt?.isNotEmpty == true ? config.alt! : 'Image');
    }
    final href = config.uri.toString();
    final remote = widget.documentPath == null
        ? explicitRemoteFileOutput(href)
        : resolveDocumentFileLink(href, widget.documentPath!);
    final title = config.alt?.isNotEmpty == true ? config.alt! : 'Image';
    if (remote != null) {
      return DeliverableAttachment(
        output: ChatOutput(
          kind: ChatOutputKind.image,
          path: remote.path,
          url: null,
          label: title,
        ),
        onOpen: widget.onOpenRemoteFile == null
            ? null
            : (output) => widget.onOpenRemoteFile!(output),
        onDownload: widget.onDownloadRemoteFile == null
            ? null
            : (output) => widget.onDownloadRemoteFile!(output),
        loadImage: widget.loadImage == null
            ? null
            : (path) => widget.loadImage!(path),
      );
    }
    return ChatInlineImage(
      target: href,
      title: title,
      loadImage: widget.loadImage == null
          ? null
          : (path) => widget.loadImage!(path),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StudioPageLoading(
      active: _openingEmail,
      label: 'Opening email apps',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCachedContent(context),
          if (_linkError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: WingSpacing.sm),
              child: StudioError(error, icon: Icons.link),
            ),
        ],
      ),
    );
  }

  Widget _buildCachedContent(BuildContext context) {
    if (_content != null) {
      if (CompletionDiagnostics.enabled) {
        CompletionDiagnostics.event('markdown.message.cached');
      }
      return _content!;
    }
    final start = CompletionDiagnostics.enabled
        ? CompletionDiagnostics.start()
        : 0;
    final result = _content =
        widget.documentPath == null &&
            widget.onHeadings == null &&
            markdownQaVariant == MarkdownQaVariant.background
        ? BackgroundMarkdownContent(
            data: widget.data,
            deliverables: widget.deliverables,
            streaming: widget.streaming,
            builder: (_, segments) {
              final renderStart = CompletionDiagnostics.enabled
                  ? CompletionDiagnostics.start()
                  : 0;
              final child = _buildContent(context, prepared: segments);
              if (CompletionDiagnostics.enabled) {
                CompletionDiagnostics.finish(
                  'markdown.message.prepared.build',
                  renderStart,
                  values: {'segments': segments.length},
                );
              }
              return child;
            },
          )
        : _buildContent(context);
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.finish(
        'markdown.message.build',
        start,
        values: {'segments': _segments.length},
      );
    }
    return result;
  }

  Widget _buildContent(
    BuildContext context, {
    List<MarkdownSegment>? prepared,
  }) {
    MediaQuery.sizeOf(context);
    MediaQuery.textScalerOf(context);
    final theme = Theme.of(context);
    final styleSheet = _styleSheet ??= profileMarkdownStyle(theme);
    final markdownTheme = _markdownTheme ??= profileMarkdownTheme(theme);
    final mentions = BotMentionScope.of(context);
    final builders = _markdownBuilders ??= {
      if (mentions != null) BotMentionScope.tag: BotMentionBuilder(),
      if (widget.documentPath != null || widget.onHeadings != null)
        _headingAnchorTag: _HeadingAnchorBuilder(_headingKeys),
      if (widget.deliverables)
        deliverableElementTag: _DeliverableBuilder(
          widget.onOpenRemoteFile == null
              ? null
              : (output) => widget.onOpenRemoteFile!(output),
          widget.onDownloadRemoteFile == null
              ? null
              : (output) => widget.onDownloadRemoteFile!(output),
          maxWidth: MediaQuery.sizeOf(context).width,
          loadImages: widget.loadImages,
          loadImage: widget.loadImage == null
              ? null
              : (path) => widget.loadImage!(path),
        ),
    };
    _headingKeys.clear();
    final anchors = <MarkdownHeadingAnchor>[];
    final headings = _HeadingBuilder(_headingKeys, anchors);
    if (widget.onHeadings != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && anchors.isNotEmpty) {
          widget.onHeadings?.call(List.unmodifiable(anchors));
        }
      });
    }
    // The production message path receives a complete snapshot from the
    // worker. Only the explicit synchronous QA variants and document previews
    // run the splitter here.
    final List<Object> sources;
    if (prepared != null) {
      sources = [
        for (final segment in prepared)
          switch (segment) {
            MarkdownProseSegment() => segment.source,
            MarkdownFenceSegment() => MarkdownCodeBlock(
              code: segment.code,
              language: segment.language,
              previewEnabled: segment.closed && !widget.streaming,
              highlightingEnabled: segment.closed && !widget.streaming,
            ),
          },
      ];
    } else {
      final splitStart = CompletionDiagnostics.enabled
          ? CompletionDiagnostics.start()
          : 0;
      sources = splitMarkdownCodeBlocks(
        widget.data,
        streaming: widget.streaming,
      );
      if (CompletionDiagnostics.enabled) {
        CompletionDiagnostics.finish(
          'markdown.fence.split',
          splitStart,
          values: {'segments': sources.length},
        );
      }
    }
    final next = <({Object source, Widget child})>[];
    final usedParsers = <int>{};
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      final previous = index < _segments.length ? _segments[index] : null;
      // Retain the complete subtree, including code controls and the inherited
      // wrappers around prose. Heading previews still traverse every segment
      // to rebuild their document-wide anchor registry.
      if (!_refreshSegments &&
          widget.documentPath == null &&
          widget.onHeadings == null &&
          previous != null &&
          (prepared != null ||
              _segmentsStreaming == widget.streaming ||
              source is MarkdownCodeBlock) &&
          _sameMarkdownSegment(previous.source, source)) {
        next.add(previous);
        if (_parsers.containsKey(index)) usedParsers.add(index);
        continue;
      }
      Widget prose(String text, List<md.Node>? nodes) {
        final options = BlockReusingMarkdownBody(
          data: text,
          parsedNodes: nodes,
          paddingBuilders:
              widget.documentPath != null || widget.onHeadings != null
              ? {for (var level = 1; level <= 6; level++) 'h$level': headings}
              : const {},
          checkboxBuilder: _buildTaskMarker,
          inlineSyntaxes: widget.deliverables ? _deliverableSyntaxes : null,
          builders: builders,
          selectable: true,
          onTapLink: _tapLink,
          sizedImageBuilder: _buildImage,
          styleSheet: styleSheet,
        );
        return options;
      }

      List<md.Node>? nodes =
          prepared != null && prepared[index] is MarkdownProseSegment
          ? (prepared[index] as MarkdownProseSegment).nodes
          : null;
      if (source is String &&
          widget.documentPath == null &&
          markdownQaVariant == MarkdownQaVariant.cache) {
        usedParsers.add(index);
        nodes = (_parsers[index] ??= MarkdownInlineParser(
          deliverables: widget.deliverables,
        )).parse(source);
      }
      final child = source is MarkdownCodeBlock
          ? source
          // This is an inline viewport, not the screen edge. Otherwise the
          // system bottom inset lifts table scrollbars into the last row.
          : MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: Theme(
                data: markdownTheme,
                child: prose(source as String, nodes),
              ),
            );
      next.add((source: source, child: child));
    }
    _segments = next;
    _segmentsStreaming = widget.streaming;
    _parsers.removeWhere((index, _) => !usedParsers.contains(index));
    _refreshSegments = false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final segment in next) RepaintBoundary(child: segment.child),
      ],
    );
  }

  @override
  void dispose() {
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.message.dispose');
    }
    super.dispose();
  }
}

bool _sameMarkdownSegment(Object previous, Object current) =>
    previous is String && current is String
    ? previous == current
    : previous is MarkdownCodeBlock &&
          current is MarkdownCodeBlock &&
          previous.code == current.code &&
          previous.language == current.language &&
          previous.previewEnabled == current.previewEnabled &&
          previous.highlightingEnabled == current.highlightingEnabled;

class _DeliverableBuilder extends MarkdownElementBuilder {
  _DeliverableBuilder(
    this.onOpen,
    this.onDownload, {
    required this.maxWidth,
    required this.loadImages,
    this.loadImage,
  });

  final Future<void> Function(ChatOutput)? onOpen;
  final Future<bool> Function(ChatOutput)? onDownload;
  final double maxWidth;
  final bool loadImages;
  final Future<Uint8List> Function(String path)? loadImage;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final path = element.attributes['path']!;
    if (!loadImages && element.attributes['kind'] == 'image') {
      return Text(element.attributes['name']!);
    }
    // Keep this an inline node: Markdown tables and emphasized links cannot
    // contain block nodes. Bound table cells, which scroll horizontally, too.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DeliverableAttachment(
        output: ChatOutput(
          kind: ChatOutputKind.values.byName(element.attributes['kind']!),
          path: path,
          url: null,
          label: element.attributes['name']!,
          fragment: element.attributes['fragment']?.isEmpty == false
              ? element.attributes['fragment']
              : null,
        ),
        onOpen: onOpen,
        onDownload: onDownload,
        loadImage: loadImage,
      ),
    );
  }
}

const _headingAnchorTag = 'wing-heading-anchor';

/// Insert an invisible scroll target while retaining the renderer's heading
/// typography, emphasis, links and selection behavior.
class _HeadingBuilder extends MarkdownPaddingBuilder {
  _HeadingBuilder(this.keys, this.anchors);
  final Map<String, GlobalKey> keys;
  final List<MarkdownHeadingAnchor> anchors;

  @override
  void visitElementBefore(md.Element element) {
    final slug = element.textContent
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[^\p{L}\p{N}_\-\s]', unicode: true), '')
        .replaceAll(RegExp(r'\s'), '-');
    var id = slug;
    var suffix = 0;
    while (keys.containsKey(id)) {
      id = '$slug-${++suffix}';
    }
    keys[id] = GlobalKey();
    anchors.add((
      label: element.textContent,
      level: int.parse(element.tag.substring(1)),
      key: keys[id]!,
    ));
    element.children!.insert(
      0,
      md.Element.empty(_headingAnchorTag)..attributes['id'] = id,
    );
  }
}

class _HeadingAnchorBuilder extends MarkdownElementBuilder {
  _HeadingAnchorBuilder(this.keys);
  final Map<String, GlobalKey> keys;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => SizedBox(key: keys[element.attributes['id']], width: 0, height: 1);
}

Widget _buildTaskMarker(bool checked) => StudioTaskMarker(completed: checked);
