import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/wing_theme.dart';
import '../studio_error.dart';

const activityActionStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size.square(32)),
  maximumSize: WidgetStatePropertyAll(Size.square(32)),
  padding: WidgetStatePropertyAll(EdgeInsets.all(WingSpacing.sm)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.standard,
);

/// Icon-only captured commands, with the same geometry as content actions.
class ActivityDetailAction extends StatelessWidget {
  const ActivityDetailAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.busy = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => StudioButtonPress(
    child: IconButton(
      style: activityActionStyle,
      tooltip: label,
      onPressed: busy ? null : onPressed,
      icon: busy
          ? SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                backgroundColor: Theme.of(context).colorScheme.outlineVariant,
                value: MediaQuery.disableAnimationsOf(context) ? 0.75 : null,
                semanticsLabel: label,
              ),
            )
          : Icon(icon, size: 16),
    ),
  );
}

/// Exact observed text, copied independently of wrapping, clipping or markup.
class ToolDetailCopyButton extends StatefulWidget {
  const ToolDetailCopyButton({
    super.key,
    required this.label,
    required this.text,
  });
  final String label;
  final String text;
  @override
  State<ToolDetailCopyButton> createState() => _ToolDetailCopyButtonState();
}

class _ToolDetailCopyButtonState extends State<ToolDetailCopyButton> {
  bool _copied = false;
  bool _copying = false;
  Timer? _reset;
  @override
  void didUpdateWidget(ToolDetailCopyButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _reset?.cancel();
      _copied = false;
    }
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StudioButtonPress(
    child: IconButton(
      style: activityActionStyle,
      tooltip: _copying
          ? '${widget.label}: copying'
          : _copied
          ? '${widget.label}: copied'
          : widget.label,
      icon: _copying
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(_copied ? Icons.check : Icons.copy_outlined, size: 16),
      onPressed: _copying
          ? null
          : () async {
              dismissTransientError(context, errorKey: 'copy-tool-detail');
              final text = widget.text;
              setState(() => _copying = true);
              try {
                await Clipboard.setData(ClipboardData(text: text));
              } catch (_) {
                if (context.mounted) {
                  showTransientError(
                    context,
                    'Could not copy this text. Try again.',
                    errorKey: 'copy-tool-detail',
                    icon: Icons.copy_outlined,
                  );
                }
                return;
              } finally {
                if (mounted) setState(() => _copying = false);
              }
              if (!mounted || widget.text != text) return;
              _reset?.cancel();
              setState(() => _copied = true);
              _reset = Timer(const Duration(seconds: 2), () {
                if (mounted) setState(() => _copied = false);
              });
            },
    ),
  );
}
