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
import '../services/web_preview.dart';
import '../theme/profile_markdown_style.dart';
import 'chat_image_preview.dart';
import 'markdown_code_block.dart';
import 'deliverable_attachment.dart';

/// Renders Markdown message content without conversation chrome.
class MarkdownMessageContent extends StatefulWidget {
  final String data;
  final bool streaming;
  final Future<void> Function(ChatOutput output)? onOpenRemoteFile;
  final Future<bool> Function(ChatOutput output)? onDownloadRemoteFile;
  final Future<Uint8List> Function(ChatOutput output)? onLoadRemoteImage;
  final bool deliverables;
  final String? documentPath;
  final String? initialFragment;

  const MarkdownMessageContent({
    super.key,
    required this.data,
    this.streaming = false,
    this.onOpenRemoteFile,
    this.onDownloadRemoteFile,
    this.onLoadRemoteImage,
    this.deliverables = false,
    this.documentPath,
    this.initialFragment,
  });

  @override
  State<MarkdownMessageContent> createState() => _MarkdownMessageContentState();
}

class _MarkdownMessageContentState extends State<MarkdownMessageContent> {
  // Retain only this mounted message's rendering. Unrelated stream/activity
  // updates must not split code fences, recreate styles and reparse its prose.
  Widget? _content;
  final _headingKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: StudioError('This heading is not in the available preview.'),
        ),
      );
    }
  }

  @override
  void didUpdateWidget(covariant MarkdownMessageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data ||
        widget.streaming != oldWidget.streaming ||
        widget.deliverables != oldWidget.deliverables ||
        widget.documentPath != oldWidget.documentPath ||
        widget.initialFragment != oldWidget.initialFragment ||
        (widget.onOpenRemoteFile == null) !=
            (oldWidget.onOpenRemoteFile == null) ||
        (widget.onDownloadRemoteFile == null) !=
            (oldWidget.onDownloadRemoteFile == null) ||
        (widget.onLoadRemoteImage == null) !=
            (oldWidget.onLoadRemoteImage == null)) {
      _content = null;
    }
    if (widget.initialFragment != oldWidget.initialFragment) {
      _scheduleFragment();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme, text scale and viewport changes still refresh the rendered content.
    _content = null;
  }

  Future<void> _open(BuildContext context, String href) async {
    final uri = externalWebLink(href);
    var opened = false;
    if (uri != null) {
      opened = await openWebPreview(uri);
    } else {
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
          return;
        } catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: StudioError(fileOpenErrorMessage(error))),
            );
          }
          return;
        }
      }
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: StudioError(
            uri == null
                ? 'Only web links and linked Hermes files can be opened here.'
                : 'Could not open this link.',
          ),
        ),
      );
    }
  }

  void _previewImage(BuildContext context, String href, String title) {
    final uri = externalWebLink(href);
    if (uri == null) {
      _open(context, href);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (previewContext) => ChatImagePreview(
          uri: uri,
          title: title,
          onOpenExternal: () => _open(previewContext, href),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _content ??= _buildContent(context);

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    _headingKeys.clear();
    final headings = _HeadingBuilder(_headingKeys);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final segment in splitMarkdownCodeBlocks(
          widget.data,
          streaming: widget.streaming,
        ))
          if (segment is MarkdownCodeBlock)
            segment
          else
            // This is an inline viewport, not the screen edge. Otherwise the
            // system bottom inset lifts table scrollbars into the last row.
            MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: Theme(
                data: profileMarkdownTheme(theme),
                child: MarkdownBody(
                  checkboxBuilder: (checked) =>
                      StudioTaskMarker(completed: checked),
                  data: segment as String,
                  inlineSyntaxes: widget.deliverables
                      ? [
                          MediaReferenceSyntax(),
                          DeliverableLinkSyntax(),
                          DeliverableCodeSyntax(),
                          HtmlFilePathSyntax(),
                        ]
                      : null,
                  paddingBuilders: {
                    if (widget.documentPath != null)
                      for (var level = 1; level <= 6; level++)
                        'h$level': headings,
                  },
                  builders: {
                    if (widget.documentPath != null) ...{
                      _headingAnchorTag: _HeadingAnchorBuilder(_headingKeys),
                    },
                    if (widget.deliverables)
                      deliverableElementTag: _DeliverableBuilder(
                        widget.onOpenRemoteFile == null
                            ? null
                            : (output) => widget.onOpenRemoteFile!(output),
                        widget.onDownloadRemoteFile == null
                            ? null
                            : (output) => widget.onDownloadRemoteFile!(output),
                        widget.onLoadRemoteImage == null
                            ? null
                            : (output) => widget.onLoadRemoteImage!(output),
                        maxWidth: MediaQuery.sizeOf(context).width,
                      ),
                  },
                  selectable: true,
                  onTapLink: (_, href, _) {
                    if (href != null) _open(context, href);
                  },
                  sizedImageBuilder: (config) => OutlinedButton.icon(
                    onPressed: () => _previewImage(
                      context,
                      config.uri.toString(),
                      config.alt ?? 'Image',
                    ),
                    icon: const Icon(Icons.image_outlined),
                    label: Text(
                      config.alt ?? 'Open image link',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  styleSheet: profileMarkdownStyle(theme),
                ),
              ),
            ),
      ],
    );
  }
}

class _DeliverableBuilder extends MarkdownElementBuilder {
  _DeliverableBuilder(
    this.onOpen,
    this.onDownload,
    this.onLoadImage, {
    required this.maxWidth,
  });

  final Future<void> Function(ChatOutput)? onOpen;
  final Future<bool> Function(ChatOutput)? onDownload;
  final Future<Uint8List> Function(ChatOutput)? onLoadImage;
  final double maxWidth;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final path = element.attributes['path']!;
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
        onLoadImage: onLoadImage,
      ),
    );
  }
}

const _headingAnchorTag = 'wing-heading-anchor';

/// Insert an invisible scroll target while retaining the renderer's heading
/// typography, emphasis, links and selection behavior.
class _HeadingBuilder extends MarkdownPaddingBuilder {
  _HeadingBuilder(this.keys);
  final Map<String, GlobalKey> keys;

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
