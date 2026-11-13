import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/remote_files_client.dart';
import '../theme/wing_theme.dart';
import 'source_code_block.dart';
import 'resource_filename.dart';

enum WebOutputFormat { mermaid, svg, html }

/// A disposable native preview opened explicitly from its source.
class WebOutputPreview extends StatefulWidget {
  static const maxMermaidSourceLength = 50000;
  static const maxSvgSourceLength = 256 * 1024;
  static const maxHtmlSourceLength = maxFilePreviewBytes;
  static const viewType = 'com.tarkilhk.wing/mermaid_diagram';

  final String source;
  final WebOutputFormat format;
  final String? title;
  final String? resourceTarget;
  final String? actionLabel;
  final Future<void> Function(BuildContext)? onAction;

  const WebOutputPreview({
    super.key,
    required this.source,
    required this.format,
    this.title,
    this.resourceTarget,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<WebOutputPreview> createState() => _WebOutputPreviewState();
}

class _WebOutputPreviewState extends State<WebOutputPreview> {
  bool _showSource = false;
  bool _actionBusy = false;

  Future<void> _runAction(BuildContext anchor) async {
    final action = widget.onAction;
    if (_actionBusy || action == null) return;
    setState(() => _actionBusy = true);
    try {
      await action(anchor);
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final limit = switch (widget.format) {
      WebOutputFormat.mermaid => WebOutputPreview.maxMermaidSourceLength,
      WebOutputFormat.svg => WebOutputPreview.maxSvgSourceLength,
      WebOutputFormat.html => WebOutputPreview.maxHtmlSourceLength,
    };
    final canRender =
        supported && widget.source.isNotEmpty && widget.source.length <= limit;
    final label = switch (widget.format) {
      WebOutputFormat.mermaid => 'diagram',
      WebOutputFormat.svg => 'SVG',
      WebOutputFormat.html => 'HTML',
    };
    final language = widget.format.name;
    final previewIcon = switch (widget.format) {
      WebOutputFormat.mermaid => Icons.account_tree_outlined,
      WebOutputFormat.svg => Icons.image_outlined,
      WebOutputFormat.html => Icons.web_asset_outlined,
    };
    final theme = Theme.of(context);
    return Scaffold(
      appBar: ResourceViewerAppBar(
        context: context,
        title:
            widget.title ??
            (widget.format == WebOutputFormat.mermaid
                ? 'Diagram'
                : '$label preview'),
        target: widget.resourceTarget,
        actions: [
          if (canRender)
            ResourceViewerAction(
              label: _showSource ? 'Show $label' : 'Show source',
              icon: _showSource ? previewIcon : Icons.code,
              onPressed: () => setState(() => _showSource = !_showSource),
            ),
          if (widget.onAction != null)
            Builder(
              builder: (anchor) => ResourceViewerAction(
                label: _actionBusy
                    ? 'Preparing share'
                    : widget.actionLabel ?? 'Share resource',
                icon: _actionBusy ? Icons.hourglass_top : Icons.ios_share,
                onPressed: _actionBusy ? null : () => _runAction(anchor),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _showSource || !canRender
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!canRender)
                      Text('This $label is available as source here.'),
                    SourceCodeBlock(
                      code: widget.source,
                      language: language,
                      headerAction: null,
                    ),
                  ],
                ),
              )
            : AndroidView(
                key: ValueKey((theme.brightness, theme.colorScheme)),
                viewType: WebOutputPreview.viewType,
                creationParamsCodec: const StandardMessageCodec(),
                creationParams: {
                  'source': widget.source,
                  'dark': theme.brightness == Brightness.dark,
                  'format': language,
                  'palette': {
                    'canvas': theme.colorScheme.surface.toARGB32(),
                    'panel': theme.canvasColor.toARGB32(),
                    'text': theme.colorScheme.onSurface.toARGB32(),
                    'muted': theme.colorScheme.onSurfaceVariant.toARGB32(),
                    'border': theme.colorScheme.outlineVariant.toARGB32(),
                    'error': theme.colorScheme.error.toARGB32(),
                    'error-surface': WingTokens.of(
                      context,
                    ).dangerSurface.toARGB32(),
                    'accent': theme.colorScheme.primary.toARGB32(),
                  },
                },
              ),
      ),
    );
  }
}
