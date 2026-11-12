import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';

import '../models/composer_action.dart';
import '../services/app_preferences.dart';
import 'composer_action_button.dart';
import 'studio_error.dart';

class ComposerActionSettings extends StatelessWidget {
  const ComposerActionSettings({super.key, required this.preferences});
  final AppPreferences preferences;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<AppPreferencesState>(
    valueListenable: preferences.state,
    builder: (context, state, _) {
      final control = state.runningAction;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: StudioLoadingRegion(
            available: !control.busy,
            busy: control.busy,
            label: 'Saving composer action',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'While your agent is working',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text('Choose what a tap on the chat button does.'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final action in ComposerAction.runningDefaults)
                      StudioButtonPress(
                        child: ChoiceChip(
                          showCheckmark: false,
                          avatar: Icon(composerActionIcon(action), size: 18),
                          label: Text(action.label),
                          selected: action == control.selected,
                          onSelected: control.choose == null
                              ? null
                              : (_) => control.choose!(action),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(switch (control.selected) {
                  ComposerAction.queue =>
                    'Queue sends your message after the current reply.',
                  ComposerAction.stop => 'Stop ends the current response.',
                  ComposerAction.steer =>
                    'Steer sends your message into the work in progress.',
                  _ =>
                    'Choose a default action. Named actions remain available in chat.',
                }, style: Theme.of(context).textTheme.bodyMedium),
                if (control.notice != null) StudioError(control.notice!),
                if (control.error != null) StudioError(control.error!),

                const SizedBox(height: 8),
                Text(
                  'Hold and slide to use another action.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
