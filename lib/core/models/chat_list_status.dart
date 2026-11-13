import 'profile_live_activity.dart';

enum ChatListStatus {
  needsInput('Needs input'),
  working('Working'),
  unread('Unread'),
  draft('Draft'),
  idle('Idle');

  const ChatListStatus(this.label);
  final String label;
}

typedef ChatListRuntimeObservation = ({
  bool needsInput,
  bool working,
  bool hasMessages,
});

/// Shared precedence for the row dot, filtering and ordering. Recent REST
/// activity is deliberately not treated as evidence of a running turn.
ChatListStatus chatListStatus(
  Map<String, dynamic> row, {
  ChatListRuntimeObservation? runtime,
  ProfileLiveActivityState? activity,
}) {
  if (runtime?.needsInput == true ||
      activity == ProfileLiveActivityState.needsInput) {
    return ChatListStatus.needsInput;
  }
  if (activity == ProfileLiveActivityState.running ||
      runtime?.working == true) {
    return ChatListStatus.working;
  }
  if (row['unread'] == true) return ChatListStatus.unread;
  if (row['message_count'] == 0 && runtime?.hasMessages != true) {
    return ChatListStatus.draft;
  }
  return ChatListStatus.idle;
}
