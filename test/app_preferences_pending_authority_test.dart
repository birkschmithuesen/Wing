import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/models/notification_focus.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/chat_notification_coordinator.dart';
import 'support/recording_turn_notification_sink.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AppPreferences, _HeldPreference)> open(
    AppPreferenceField field,
  ) async {
    SharedPreferences.resetStatic();
    final platform = _HeldPreference(field);
    SharedPreferencesStorePlatform.instance = platform;
    final owner = AppPreferences(await SharedPreferences.getInstance());
    addTearDown(() {
      owner.dispose();
      SharedPreferences.setMockInitialValues({});
    });
    return (owner, platform);
  }

  test(
    'pending failed action save keeps the previously confirmed default',
    () async {
      final (owner, platform) = await open(AppPreferenceField.runningAction);
      final saving = owner.setRunningAction(ComposerAction.queue);
      final failure = expectLater(
        saving,
        throwsA(isA<AppPreferenceSaveException>()),
      );
      await platform.started.future;
      try {
        expect(owner.current.runningAction.selected, ComposerAction.steer);
        expect(owner.current.runningAction.busy, isTrue);
        expect(owner.current.storageVerified, isFalse);
        expect(owner.current.preferredRunningAction, ComposerAction.steer);
      } finally {
        platform.release.complete();
        await failure;
      }
      await owner.reload();
      expect(owner.current.preferredRunningAction, ComposerAction.steer);
      expect(owner.current.storageVerified, isTrue);
    },
  );

  test(
    'pending failed category save never cancels its confirmed posted notice',
    () async {
      final (owner, platform) = await open(
        AppPreferenceField.completedNotifications,
      );
      final prefs = await SharedPreferences.getInstance();
      final sink = RecordingTurnNotificationSink();
      final notices = ChatNotificationCoordinator(
        prefs,
        sink,
        appPreferences: owner,
      );
      const chat =
          '{"connection":"home","connection_identity":"owner","profile":"default","session":"chat"}';
      await notices.result(
        chat: chat,
        title: 'Build site',
        scope: 'Home / default',
        focus: const NotificationFocus('answer', 'reply'),
        content: ChatNotificationContent.reply('Build complete'),
      );
      expect(sink.shown.single.body, 'Build complete');
      expect(notices.hasNotice(chat), isTrue);
      void refresh() {
        unawaited(notices.refreshPreferences());
      }

      owner.state.addListener(refresh);
      final saving = owner.setCompletedNotifications(false);
      final failure = expectLater(
        saving,
        throwsA(isA<AppPreferenceSaveException>()),
      );
      await platform.started.future;
      try {
        await notices.refreshPreferences();
        expect(owner.current.completedNotifications.selected, isTrue);
        expect(owner.current.completedNotifications.busy, isTrue);
        expect(owner.current.storageVerified, isFalse);
        expect(
          sink.cancelled,
          isEmpty,
          reason:
              'unconfirmed preference intent must not remove an existing confirmed notice',
        );
        expect(notices.hasNotice(chat), isTrue);
        expect(owner.current.completedNotificationsAllowed, isTrue);
      } finally {
        platform.release.complete();
        await failure;
        await notices.refreshPreferences();
        owner.state.removeListener(refresh);
      }
      expect(sink.cancelled, isEmpty);
      expect(notices.hasNotice(chat), isTrue);
      expect(
        sink.shown.every((notice) => notice.body == 'Build complete'),
        isTrue,
      );
      await owner.reload();
      expect(owner.current.completedNotificationsAllowed, isTrue);
    },
  );
}

class _HeldPreference extends InMemorySharedPreferencesStore {
  _HeldPreference(this.field)
    : super.withData({
        'flutter.composer_running_action': 'steer',
        'flutter.completion_notifications': true,
      });
  final AppPreferenceField field;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.${field.storageKey}' && !started.isCompleted) {
      started.complete();
      await release.future;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
