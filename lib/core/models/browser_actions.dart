import 'chat_list_view.dart';
import 'hermes_profile.dart';
import 'profile_session_key.dart';
import 'session_visibility.dart';

enum BrowserAction {
  rename,
  pin,
  unread,
  copy,
  move,
  archive,
  delete,
  newChat,
  editProject,
  editDraft,
}

final class BrowserActionChoice {
  const BrowserActionChoice(this.action, this.label, this.enabled);
  final BrowserAction action;
  final String label;
  final bool enabled;
}

final class BrowserActionState {
  const BrowserActionState({
    this.submitting = false,
    this.generatingTitle = false,
    this.error,
    this.moving,
  });
  final bool submitting;
  final bool generatingTitle;
  final String? error;
  final BrowserProject? moving;
}

final class BrowserWorkspaceState {
  BrowserWorkspaceState({
    required this.initialized,
    required Iterable<HermesProfile> profiles,
    required this.scope,
    required this.switching,
    required this.repairRequired,
    required this.repairBusy,
    required this.recovering,
    required this.offline,
    required this.mutating,
    required this.error,
    required this.visibility,
    required this.visibilityNotice,
    required this.visibilityError,
    required this.canChooseVisibility,
  }) : profiles = List.unmodifiable(profiles);
  final List<HermesProfile> profiles;
  final WorkspaceScope? scope;
  final bool initialized,
      switching,
      repairRequired,
      repairBusy,
      recovering,
      offline,
      mutating,
      canChooseVisibility;
  final String? error, visibilityNotice, visibilityError;
  final SessionVisibility? visibility;
}

final class BrowserDraft {
  const BrowserDraft({
    required this.key,
    required this.text,
    required this.attachmentCount,
    required this.queuedCount,
    required this.submissionUncertain,
  });
  final ProfileSessionKey key;
  final String text;
  final int attachmentCount, queuedCount;
  final bool submissionUncertain;
}
