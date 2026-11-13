import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_list_status.dart';
import 'package:wing/core/models/profile_live_activity.dart';

void main() {
  test('input outranks working, unread and empty-row draft evidence', () {
    expect(
      chatListStatus(
        {'unread': true, 'message_count': 0},
        runtime: (needsInput: true, working: true, hasMessages: false),
        activity: ProfileLiveActivityState.running,
      ),
      ChatListStatus.needsInput,
    );
  });

  test('server input request outranks local working and unread', () {
    expect(
      chatListStatus(
        {'unread': true},
        runtime: (needsInput: false, working: true, hasMessages: true),
        activity: ProfileLiveActivityState.needsInput,
      ),
      ChatListStatus.needsInput,
    );
  });

  test('local working outranks unread', () {
    expect(
      chatListStatus(
        {'unread': true},
        runtime: (needsInput: false, working: true, hasMessages: false),
      ),
      ChatListStatus.working,
    );
  });

  test('confirmed server work appears without a local runtime', () {
    expect(
      chatListStatus(const {}, activity: ProfileLiveActivityState.running),
      ChatListStatus.working,
    );
  });

  test(
    'retained messages prevent a stale empty REST row appearing as a draft',
    () {
      expect(
        chatListStatus(
          {'message_count': 0},
          runtime: (needsInput: false, working: false, hasMessages: true),
        ),
        ChatListStatus.idle,
      );
    },
  );

  test('REST activity alone cannot establish running work', () {
    expect(chatListStatus({'is_active': true}), ChatListStatus.idle);
  });

  test('empty saved chat without retained messages appears as a draft', () {
    expect(chatListStatus({'message_count': 0}), ChatListStatus.draft);
  });

  test('unread takes precedence over an empty REST row', () {
    expect(
      chatListStatus({'unread': true, 'message_count': 0}),
      ChatListStatus.unread,
    );
  });
}
