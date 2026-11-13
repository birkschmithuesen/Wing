import 'package:wing/core/models/notification_input.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:wing/core/models/notification_focus.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/chat_notification_coordinator.dart';
import 'package:wing/core/services/turn_notification_service.dart';

import 'support/recording_turn_notification_sink.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const chat =
      '{"connection":"home","connection_identity":"owner","profile":"default","session":"chat"}';
  late SharedPreferences prefs;
  late AppPreferences owner;
  late RecordingTurnNotificationSink sink;
  late ChatNotificationCoordinator notices;

  Future<void> reply({bool attention = false}) => notices.result(
    chat: chat,
    title: 'Build site',
    scope: 'Home / default',
    focus: const NotificationFocus('answer', 'reply'),
    content: attention
        ? ChatNotificationContent.failed
        : ChatNotificationContent.reply('Build complete'),
  );

  Future<void> approval() => notices.inputs(
    chat: chat,
    title: 'Build site',
    scope: 'Home / default',
    inputs: [
      NotificationInput(
        focus: const NotificationFocus('approval', 'build'),
        content: ChatNotificationContent.approval(
          'npm run build',
          'Build site',
        ),
        choices: const ['once', 'session', 'always', 'deny'],
      ),
    ],
  );

  void restartNotices() {
    sink = RecordingTurnNotificationSink();
    notices = ChatNotificationCoordinator(prefs, sink, appPreferences: owner);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    owner = AppPreferences(prefs);
    restartNotices();
  });
  tearDown(() => owner.dispose());

  for (final refreshBeforeRestore in [true, false]) {
    test(
      'unrelated observation ${refreshBeforeRestore ? 'before' : 'after'} startup restore never duplicates its silent redraw',
      () async {
        await reply();
        final original = sink.shown.single;
        restartNotices();
        if (!refreshBeforeRestore) {
          await notices.restore(owns: (_) => true);
        }
        owner.visibilityFor('new-connection');
        await notices.refreshPreferences();
        if (refreshBeforeRestore) {
          expect(sink.shown, isEmpty);
          await notices.restore(owns: (_) => true);
        }
        await notices.refreshPreferences();
        expect(sink.shown, hasLength(1));
        expect(sink.shown.single.id, original.id);
        expect(sink.shown.single.revision, original.revision);
        expect(sink.shown.single.body, 'Build complete');
        expect(sink.shown.single.alert, isFalse);
        expect(sink.cancelled, isEmpty);
        expect(notices.hasNotice(chat), isTrue);
        final stored =
            jsonDecode(prefs.getString(ChatNotificationCoordinator.storageKey)!)
                as Map;
        expect((stored[chat] as Map)['posted'], original.revision);
      },
    );
  }

  test(
    'a confirmed theme change leaves a posted notification unchanged',
    () async {
      await reply();
      await owner.setTheme(AppThemePreference.dark);
      await notices.refreshPreferences();
      expect(owner.current.theme.selected, AppThemePreference.dark);
      expect(sink.shown, hasLength(1));
      expect(sink.cancelled, isEmpty);
      expect(sink.shown.single.alert, isTrue);
    },
  );

  test(
    'a real preview authority change refreshes once and hides controls',
    () async {
      await approval();
      expect(sink.shown.single.choices, isNotEmpty);
      await owner.setNotificationPreviews(false);
      await notices.refreshPreferences();
      expect(sink.shown, hasLength(2));
      expect(sink.shown.last.showPreview, isFalse);
      expect(sink.shown.last.body, 'Approval needed');
      expect(sink.shown.last.choices, isEmpty);
      expect(sink.shown.last.alert, isFalse);
      await notices.refreshPreferences();
      expect(sink.shown, hasLength(2));
    },
  );

  for (final attention in [false, true]) {
    test(
      'a real ${attention ? 'attention' : 'completion'} authority change withdraws once without replay',
      () async {
        await reply(attention: attention);
        final id = sink.shown.single.id;
        if (attention) {
          await owner.setAttentionNotifications(false);
        } else {
          await owner.setCompletedNotifications(false);
        }
        await notices.refreshPreferences();
        await notices.refreshPreferences();
        expect(sink.cancelled, [id]);
        expect(sink.shown, hasLength(1));
        expect(notices.hasNotice(chat), isFalse);
        expect(notices.resultFor(chat), isNotNull);
        if (attention) {
          await owner.setAttentionNotifications(true);
        } else {
          await owner.setCompletedNotifications(true);
        }
        await notices.refreshPreferences();
        expect(
          sink.shown,
          hasLength(1),
          reason: 'reenabling never replays history',
        );
      },
    );
  }

  for (final field in [
    AppPreferenceField.completedNotifications,
    AppPreferenceField.attentionNotifications,
    AppPreferenceField.notificationPreviews,
  ]) {
    test(
      'fresh malformed ${field.name} storage reconciles conservatively once',
      () async {
        if (field == AppPreferenceField.notificationPreviews) {
          await approval();
        } else {
          await reply(
            attention: field == AppPreferenceField.attentionNotifications,
          );
        }
        final id = sink.shown.single.id;
        await prefs.setString(field.storageKey, 'invalid');
        owner.dispose();
        owner = AppPreferences(prefs);
        expect(owner.current.isFieldCurrent(field), isFalse);
        restartNotices();
        await notices.refreshPreferences();
        if (field == AppPreferenceField.notificationPreviews) {
          expect(sink.shown, hasLength(1));
          expect(sink.shown.single.showPreview, isFalse);
          expect(sink.shown.single.choices, isEmpty);
          expect(sink.shown.single.alert, isFalse);
        } else {
          expect(sink.shown, isEmpty);
          expect(sink.cancelled, [id]);
          expect(notices.hasNotice(chat), isFalse);
        }
        final shownCount = sink.shown.length;
        final cancelledCount = sink.cancelled.length;
        await notices.refreshPreferences();
        expect(sink.shown, hasLength(shownCount));
        expect(sink.cancelled, hasLength(cancelledCount));
      },
    );
  }

  test(
    'failed policy delivery remains retryable with the same current facts',
    () async {
      final failing = _FailedShow();
      sink = failing;
      notices = ChatNotificationCoordinator(prefs, sink, appPreferences: owner);
      await approval();
      await owner.setNotificationPreviews(false);
      failing.failNext = true;
      await expectLater(notices.refreshPreferences(), throwsStateError);
      expect(sink.shown, hasLength(1));
      await notices.refreshPreferences();
      expect(sink.shown, hasLength(2));
      expect(sink.shown.last.showPreview, isFalse);
      expect(sink.shown.last.choices, isEmpty);
      expect(sink.shown.last.alert, isFalse);
    },
  );
}

class _FailedShow extends RecordingTurnNotificationSink {
  bool failNext = false;
  @override
  Future<void> show(TurnNotification notification) async {
    if (failNext) {
      failNext = false;
      throw StateError('Controlled notification delivery failure');
    }
    await super.show(notification);
  }
}
