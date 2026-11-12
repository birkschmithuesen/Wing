import 'recent_conversations/conversation_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/completion_diagnostics.dart';
import '../theme/wing_theme.dart';
import 'source_code_text.dart';

/// Selectable source with copy and wrap controls and an optional header action.
///
/// Preview eligibility and navigation belong to the composing presentation.
class SourceCodeBlock extends StatefulWidget {
  final String code;
  final String? language;
  final Widget? headerAction;
  final bool highlightingEnabled;

  const SourceCodeBlock({
    super.key,
    required this.code,
    this.language,
    required this.headerAction,
    this.highlightingEnabled = true,
  });

  @override
  State<SourceCodeBlock> createState() => _SourceCodeBlockState();
}

class _SourceCodeBlockState extends State<SourceCodeBlock> {
  bool _wrap = true;
  final _sourceKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.code.init');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.code.dependencies');
    }
  }

  @override
  void didUpdateWidget(covariant SourceCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event(
        'markdown.code.update',
        values: {
          'codeChanged': oldWidget.code != widget.code ? 1 : 0,
          'previewChanged':
              (oldWidget.headerAction != null) != (widget.headerAction != null)
              ? 1
              : 0,
        },
      );
    }
  }

  @override
  void dispose() {
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.code.dispose');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = CompletionDiagnostics.enabled
        ? CompletionDiagnostics.start()
        : 0;
    final theme = Theme.of(context);
    final background = theme.colorScheme.surfaceContainerLow;
    final header = theme.colorScheme.surfaceContainerHighest;
    final foreground = theme.colorScheme.onSurface;
    final content = SourceCodeText(
      key: _sourceKey,
      highlightingEnabled: widget.highlightingEnabled,
      text: widget.code,
      language: widget.language,
      wrap: _wrap,
      maxHeight: MediaQuery.sizeOf(context).height / 2,
      style: WingTokens.of(
        context,
      ).typography.mono.copyWith(height: 1.45, color: foreground),
    );

    final result = Container(
      key: const Key('markdown-code-block'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: WingRadius.card,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: header,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.language ?? 'code',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.headerAction != null) widget.headerAction!,
                Tooltip(
                  message: _wrap ? 'Scroll horizontally' : 'Wrap lines',
                  child: StudioButtonPress(
                    child: IconButton(
                      icon: Icon(
                        _wrap ? Icons.swap_horiz : Icons.wrap_text,
                        size: 18,
                      ),
                      onPressed: () => setState(() => _wrap = !_wrap),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Copy code',
                  child: StudioButtonPress(
                    child: IconButton(
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: widget.code)),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.all(12), child: content),
        ],
      ),
    );
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.finish('markdown.code.build', start);
    }
    return ConversationGestureBoundary(blocked: true, child: result);
  }
}
