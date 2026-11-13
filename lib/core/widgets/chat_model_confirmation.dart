import 'studio_form_actions.dart';
import 'package:flutter/material.dart';

import '../theme/wing_theme.dart';

/// Keep the decision buttons visible while a long Hermes warning scrolls.
Future<bool> showChatModelConfirmation(
  BuildContext context, {
  required String message,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  return await showDialog<bool>(
        context: context,
        builder: (context) => _ModelConfirmationDialog(message: message),
      ) ??
      false;
}

class _ModelConfirmationDialog extends StatefulWidget {
  const _ModelConfirmationDialog({required this.message});

  final String message;

  @override
  State<_ModelConfirmationDialog> createState() =>
      _ModelConfirmationDialogState();
}

class _ModelConfirmationDialogState extends State<_ModelConfirmationDialog> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StudioDialog(
    scrollable: false,
    insetPadding: const EdgeInsets.all(WingSpacing.md),
    title: Text(
      'Confirm model change',
      style: Theme.of(context).textTheme.titleMedium,
    ),
    content: Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scroll,
        child: Padding(
          padding: const EdgeInsets.only(right: WingSpacing.sm),
          child: Text(widget.message),
        ),
      ),
    ),
    actions: [
      StudioFormActions(
        onCancel: () => Navigator.pop(context, false),
        onConfirm: () => Navigator.pop(context, true),
        confirmLabel: 'Switch model',
      ),
    ],
  );
}
