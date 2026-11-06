import 'model_choice.dart';

enum ChatFastMode {
  normal,
  fast,
  ultrafast;

  bool get enabled => this != normal;
  static ChatFastMode fromValue(Object? value) {
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    throw const FormatException('Invalid stock fast-mode observation');
  }
}

/// The per-chat model, reasoning and fast values chosen in the picker.
class ChatIntelligenceSelection {
  final ModelChoice choice;
  final String reasoningEffort;
  final ChatFastMode fastMode;
  final bool useProfileDefault;

  /// Switching routes keeps only controls the new catalog route offers.
  ChatIntelligenceSelection withChoice(
    ModelChoice next,
  ) => ChatIntelligenceSelection(
    choice: next,
    reasoningEffort:
        reasoningEffort == 'none' && next.controls?.canDisableReasoning == false
        ? 'minimal'
        : reasoningEffort,
    fastMode: next.controls?.fast != true
        ? ChatFastMode.normal
        : fastMode == ChatFastMode.ultrafast && next.controls?.ultrafast != true
        ? ChatFastMode.fast
        : fastMode,
  );

  const ChatIntelligenceSelection({
    required this.choice,
    required this.reasoningEffort,
    required this.fastMode,
    this.useProfileDefault = false,
  });
}
