import 'package:flutter/material.dart';

import '../theme/wing_theme.dart';
import 'conversation_reading_scope.dart';

/// Owns the control row, so a single control keeps the same leading position as
/// several controls. Reflows without owning editing or action admission; the
/// field stays mounted in the same slot in both modes.
class AdaptiveConversationComposer extends StatefulWidget {
  const AdaptiveConversationComposer({
    super.key,
    required this.field,
    required this.controls,
    required this.primaryAction,
    required this.focusNode,
    this.editing = false,
  });

  final Widget field, primaryAction;
  final List<Widget> controls;
  final FocusNode focusNode;
  final bool editing;

  @override
  State<AdaptiveConversationComposer> createState() => _ComposerState();
}

class _ComposerState extends State<AdaptiveConversationComposer> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.focusNode,
    builder: (context, _) {
      final compact = ConversationReadingScope.compact(context);
      final keyboard = ConversationReadingScope.compactKeyboard(context);
      final showControls =
          !compact ||
          widget.editing ||
          !keyboard && (_expanded || widget.focusNode.hasFocus);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: widget.field),
              if (!showControls) widget.primaryAction,
              if (compact)
                StudioButtonPress(
                  child: IconButton(
                    tooltip: showControls
                        ? 'Collapse composer controls'
                        : 'Expand composer controls',
                    icon: Icon(
                      showControls ? Icons.expand_more : Icons.expand_less,
                    ),
                    onPressed: () {
                      if (showControls || keyboard) widget.focusNode.unfocus();
                      setState(() => _expanded = !showControls);
                    },
                  ),
                ),
            ],
          ),
          if (showControls)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: widget.controls,
                  ),
                ),
                if (!widget.editing) ...[
                  const SizedBox(width: 8),
                  widget.primaryAction,
                ],
              ],
            ),
        ],
      );
    },
  );
}
