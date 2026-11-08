import 'package:flutter/material.dart';

import '../theme/wing_theme.dart';
import 'adaptive_conversation_composer.dart';
import 'conversation_reading_scope.dart';
import 'selection_viewport.dart';

enum ComposerAttachmentSource { camera, photos, files }

/// Shared composer surface and responsive controls; callers supply capabilities.
class ConversationComposer extends StatelessWidget {
  const ConversationComposer({
    super.key,
    required this.field,
    required this.focusNode,
    required this.primaryAction,
    this.controls = const [],
    this.beforeField = const [],
    this.dock,
    this.editing = false,
    this.onAttach,
    this.canCapturePhoto = false,
  });

  final Widget field, primaryAction;
  final List<Widget> controls;
  final FocusNode focusNode;
  final List<Widget> beforeField;
  final Widget? dock;
  final bool editing;
  final Future<void> Function(ComposerAttachmentSource)? onAttach;
  final bool canCapturePhoto;

  Future<void> _chooseAttachment(BuildContext context) async {
    final selected = await showModalBottomSheet<ComposerAttachmentSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final source in ComposerAttachmentSource.values)
                StudioButtonPress(
                  child: ListTile(
                    leading: Icon(switch (source) {
                      ComposerAttachmentSource.camera =>
                        Icons.camera_alt_outlined,
                      ComposerAttachmentSource.photos =>
                        Icons.photo_library_outlined,
                      ComposerAttachmentSource.files =>
                        Icons.insert_drive_file_outlined,
                    }),
                    title: Text(switch (source) {
                      ComposerAttachmentSource.camera => 'Camera',
                      ComposerAttachmentSource.photos => 'Photos',
                      ComposerAttachmentSource.files => 'Files',
                    }),
                    enabled:
                        source != ComposerAttachmentSource.camera ||
                        canCapturePhoto,
                    onTap:
                        source == ComposerAttachmentSource.camera &&
                            !canCapturePhoto
                        ? null
                        : () => Navigator.pop(context, source),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (context.mounted && selected != null) await onAttach?.call(selected);
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = ConversationReadingScope.compactKeyboard(context);
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, keyboard ? 0 : 8, 16, keyboard ? 0 : 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?dock,
          DecoratedBox(
            key: const ValueKey('conversation-composer'),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: dock == null
                  ? WingRadius.card
                  : const BorderRadius.vertical(bottom: Radius.circular(8)),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Padding(
              padding: EdgeInsets.all(keyboard ? 4 : 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...beforeField,
                  AdaptiveConversationComposer(
                    field: field,
                    controls: [
                      if (!editing)
                        StudioButtonPress(
                          child: IconButton(
                            tooltip: 'Attach file',
                            style: IconButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            icon: const Icon(Icons.add),
                            onPressed: onAttach == null
                                ? null
                                : () => _chooseAttachment(context),
                          ),
                        ),
                      ...controls,
                    ],
                    primaryAction: primaryAction,
                    focusNode: focusNode,
                    editing: editing,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Native editing and field geometry shared by every writable conversation.
class ConversationComposerField extends StatelessWidget {
  const ConversationComposerField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    this.fieldKey,
    this.enabled = true,
    this.readOnly = false,
    this.microphone,
    this.onChanged,
    this.contentInsertionConfiguration,
    this.contextMenuBuilder,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Key? fieldKey;
  final String hintText;
  final bool enabled, readOnly;
  final Widget? microphone;
  final ValueChanged<String>? onChanged;
  final ContentInsertionConfiguration? contentInsertionConfiguration;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  @override
  Widget build(BuildContext context) => viewportSelection(
    TextField(
      key: fieldKey,
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      readOnly: readOnly,
      minLines: 1,
      maxLines: ConversationReadingScope.compact(context)
          ? 1
          : ConversationReadingScope.keyboardOpen(context) &&
                MediaQuery.textScalerOf(context).scale(16) >= 24
          ? 2
          : 5,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      onChanged: onChanged,
      contentInsertionConfiguration: contentInsertionConfiguration,
      contextMenuBuilder:
          contextMenuBuilder ??
          (context, editableText) => AdaptiveTextSelectionToolbar.editableText(
            editableTextState: editableText,
          ),
      decoration: InputDecoration(
        suffixIcon: microphone,
        isDense: true,
        hintMaxLines: 1,
        hintText: hintText,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: ConversationReadingScope.compactKeyboard(context) ? 4 : 12,
        ),
      ),
    ),
  );
}
