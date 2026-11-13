import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

import '../controllers/voice_input_controller.dart';
import 'studio_error.dart';

class VoiceInputButton extends StatelessWidget {
  const VoiceInputButton({
    super.key,
    required this.enabled,
    required this.onPressed,
    this.controller,
  });
  final bool enabled;
  final VoidCallback onPressed;
  final VoiceInputController? controller;
  @override
  Widget build(BuildContext context) {
    final owner = controller;
    if (owner == null) return _button();
    return ListenableBuilder(
      listenable: owner,
      builder: (context, _) {
        final notice = owner.notice;
        return StudioTransientErrorAnchor(
          errorKey: notice == null ? null : (owner, notice.attempt),
          message: notice == null
              ? null
              : switch (notice.result) {
                  VoiceInputEmptyResult.noSpeech => 'No speech detected',
                  VoiceInputEmptyResult.noRecording => 'No recording captured',
                },
          detail: 'Tap the mic to try again.',
          icon: Icons.mic_none,
          severity: StudioErrorSeverity.noResult,
          child: _button(),
        );
      },
    );
  }

  Widget _button() => StudioButtonPress(
    child: IconButton(
      tooltip: 'Dictate message',
      icon: const Icon(Icons.mic_none),
      onPressed: enabled ? onPressed : null,
    ),
  );
}

/// Shared recording, transcription and recovery chrome for every composer.
class VoiceInputActivity extends StatelessWidget {
  VoiceInputActivity({
    super.key,
    required BuildContext context,
    required this.controller,
  }) : _errorMaxHeight =
           ((MediaQuery.sizeOf(context).height -
                       MediaQuery.viewInsetsOf(context).bottom -
                       MediaQuery.paddingOf(context).vertical) *
                   .18)
               .clamp(0.0, double.infinity);
  final VoiceInputController controller;
  // Capture the screen viewport before Scaffold consumes keyboard insets.
  final double _errorMaxHeight;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (controller.active)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(switch (controller.phase) {
                  VoiceInputPhase.starting => 'Opening microphone…',
                  VoiceInputPhase.recording =>
                    'Recording · ${controller.seconds}s / ${controller.maxSeconds}s',
                  VoiceInputPhase.transcribing => 'Transcribing…',
                  VoiceInputPhase.idle => '',
                }),
              ),
              if (controller.partial.isNotEmpty)
                Text(
                  controller.partial,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              Wrap(
                spacing: 8,
                children: [
                  if (controller.phase == VoiceInputPhase.recording)
                    StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Stop recording',
                        onPressed: controller.stop,
                        icon: const Icon(Icons.stop),
                      ),
                    ),
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Cancel recording',
                      onPressed: controller.cancel,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (controller.error case final error?)
        Padding(
          padding: const EdgeInsets.all(12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _errorMaxHeight),
            child: SingleChildScrollView(child: StudioError(error)),
          ),
        ),
    ],
  );
}
