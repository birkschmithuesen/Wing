import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

import '../services/markdown_segments.dart';
import 'source_code_block.dart';
import '../models/email_draft.dart';
import 'email_draft_card.dart';
import 'web_output_preview.dart';

/// Splits raw markdown into text segments and fenced code blocks.
///
/// Returns a list of [String] (regular markdown, rendered by MarkdownBody)
/// and [MarkdownCodeBlock] (rendered with copy/wrap controls). The fenced
/// blocks are removed from the surrounding markdown so they render once,
/// with full fidelity, instead of relying on flutter_markdown's `pre`
/// builder (which leaves its internal inline state unbalanced).
List<Object> splitMarkdownCodeBlocks(String content, {bool streaming = false}) {
  return [
    for (final segment in splitMarkdownSegments(content))
      switch (segment) {
        MarkdownProseSegment() => segment.source,
        MarkdownFenceSegment() => MarkdownCodeBlock(
          code: segment.code,
          language: segment.language,
          previewEnabled: segment.closed && !streaming,
          highlightingEnabled: segment.closed && !streaming,
        ),
      },
  ];
}

/// Composes fenced source with its optional diagram preview action.
class MarkdownCodeBlock extends StatelessWidget {
  final String code;
  final String? language;
  final bool previewEnabled;
  final bool highlightingEnabled;

  const MarkdownCodeBlock({
    super.key,
    required this.code,
    this.language,
    this.previewEnabled = true,
    this.highlightingEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (language == 'wing-email-draft' && previewEnabled) {
      final reference = EmailDraftReference.parse(code);
      if (reference != null) return EmailDraftCard(reference: reference);
    }
    final diagramFormat = switch (language?.toLowerCase()) {
      'mermaid' => WebOutputFormat.mermaid,
      'svg' => WebOutputFormat.svg,
      _ => null,
    };
    final diagramLimit = diagramFormat == WebOutputFormat.svg
        ? WebOutputPreview.maxSvgSourceLength
        : WebOutputPreview.maxMermaidSourceLength;
    return SourceCodeBlock(
      highlightingEnabled: highlightingEnabled,
      code: code,
      language: language,
      headerAction:
          diagramFormat != null && previewEnabled && code.length <= diagramLimit
          ? StudioButtonPress(
              child: IconButton(
                tooltip: diagramFormat == WebOutputFormat.svg
                    ? 'Open SVG'
                    : 'Open diagram',
                icon: Icon(
                  diagramFormat == WebOutputFormat.svg
                      ? Icons.image_outlined
                      : Icons.account_tree_outlined,
                  size: 18,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        WebOutputPreview(source: code, format: diagramFormat),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
