import 'package:wing/core/models/notification_input.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:wing/core/models/notification_focus.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/chat_notification_coordinator.dart';
import 'support/recording_turn_notification_sink.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const chat =
      '{"connection":"home","connection_identity":"owner","profile":"default","session":"chat"}';

  Future<(AppPreferences, ChatNotificationCoordinator, _HeldPermission)>
  open() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final owner = AppPreferences(prefs);
    addTearDown(owner.dispose);
    final sink = _HeldPermission();
    return (
      owner,
      ChatNotificationCoordinator(prefs, sink, appPreferences: owner),
      sink,
    );
  }

  test(
    'a delayed permission read never posts a preview disabled before dispatch',
    () async {
      final (owner, notices, sink) = await open();
      final posting = notices.inputs(
        chat: chat,
        title: 'Build site',
        scope: 'Home / default',
        inputs: [
          NotificationInput(
            focus: const NotificationFocus('approval', 'build'),
            content: ChatNotificationContent.approval(
              'private build command',
              'Build site',
            ),
            choices: const ['once', 'session', 'always', 'deny'],
          ),
        ],
      );
      await sink.started.future;
      expect(sink.shown, isEmpty);
      expect(owner.current.notificationPreviewsAllowed, isTrue);
      await owner.setNotificationPreviews(false);
      await owner.reload();
      expect(owner.current.notificationPreviewsAllowed, isFalse);
      sink.release.complete();
      await posting;
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.showPreview, isFalse);
      expect(sink.shown.single.body, 'Approval needed');
      expect(sink.shown.single.expandedBody, 'Approval needed');
      expect(sink.shown.single.choices, isEmpty);
      expect(notices.inputFor(chat)?.focus.identity, 'approval:build');
    },
  );

  for (final attention in [false, true]) {
    test(
      'a delayed permission read cannot post a disabled ${attention ? 'attention' : 'completed'} notice',
      () async {
        final (owner, notices, sink) = await open();
        final posting = notices.result(
          chat: chat,
          title: 'Build site',
          scope: 'Home / default',
          focus: const NotificationFocus('answer', 'reply'),
          content: attention
              ? ChatNotificationContent.failed
              : ChatNotificationContent.reply('Build complete'),
        );
        await sink.started.future;
        expect(sink.shown, isEmpty);
        expect(
          attention
              ? owner.current.attentionNotificationsAllowed
              : owner.current.completedNotificationsAllowed,
          isTrue,
        );
        if (attention) {
          await owner.setAttentionNotifications(false);
        } else {
          await owner.setCompletedNotifications(false);
        }
        await owner.reload();
        expect(
          attention
              ? owner.current.attentionNotificationsAllowed
              : owner.current.completedNotificationsAllowed,
          isFalse,
        );
        sink.release.complete();
        await posting;
        expect(sink.shown, isEmpty);
        expect(notices.hasNotice(chat), isFalse);
        expect(notices.resultFor(chat), isNotNull);
      },
    );
  }
}

class _HeldPermission extends RecordingTurnNotificationSink {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool?> notificationsEnabled() async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return true;
  }
}
