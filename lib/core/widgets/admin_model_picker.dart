import 'studio_form_actions.dart';
import 'package:flutter/material.dart';
import '../models/model_choice.dart';
import 'model_chooser.dart';

Future<ModelSelection?> chooseAdminModel(
  BuildContext context,
  List<ModelChoice> choices, {
  required String scopeLabel,
  required Future<List<ModelChoice>> Function() onRefresh,
  ModelSelection? initialSelection,
  bool allowAuto = false,
  String actionLabel = 'Use model',
}) {
  ModelSelection? selected = initialSelection;
  return showModalBottomSheet<ModelSelection>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, update) {
        final keyboard = MediaQuery.viewInsetsOf(context).bottom;
        final height = (MediaQuery.sizeOf(context).height - keyboard - 24)
            .clamp(0.0, MediaQuery.sizeOf(context).height * .82);
        return Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: SizedBox(
            height: height,
            child: Column(
              children: [
                ListTile(title: const Text('Choose model')),
                Expanded(
                  child: ModelChooser(
                    choices: choices,
                    selected: selected,
                    onSelected: (value) => update(() => selected = value),
                    onRefresh: onRefresh,
                    specialOptions: allowAuto
                        ? const [
                            ModelSpecialOption(
                              ModelSpecialChoice.automatic,
                              'Automatic',
                              description:
                                  'Hermes chooses for this helper task',
                            ),
                          ]
                        : const [],
                    scopeLabel: scopeLabel,
                    keyPrefix: 'admin-model',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: StudioFormActions(
                    onCancel: () => Navigator.pop(sheetContext),
                    onConfirm: selected == null || selected == initialSelection
                        ? null
                        : () => Navigator.pop(sheetContext, selected),
                    confirmLabel: actionLabel,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
