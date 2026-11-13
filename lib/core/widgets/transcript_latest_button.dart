import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

/// The same reachable, icon-only transcript navigation control in every chat.
class TranscriptLatestButton extends StatelessWidget {
  const TranscriptLatestButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: StudioButtonPress(
      child: FilledButton.tonal(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 36),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        child: Icon(icon, size: 18),
      ),
    ),
  );
}

/// One motion contract for either transcript direction.
Future<void> scrollToTranscriptLatest(
  BuildContext context,
  ScrollController controller, {
  required double offset,
}) async {
  if (!controller.hasClients) return;
  if (MediaQuery.disableAnimationsOf(context)) {
    controller.jumpTo(offset);
  } else {
    await controller.animateTo(
      offset,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }
}
