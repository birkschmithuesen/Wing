import 'package:wing/core/models/notification_input.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
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

  Future<void> approval(ChatNotificationCoordinator notices) => notices.inputs(
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

  test(
    'preview ABA during permission and show is reconciled by queued refresh',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      final sink = _HeldRefreshSink();
      final notices = ChatNotificationCoordinator(
        prefs,
        sink,
        appPreferences: owner,
      );
      addTearDown(owner.dispose);
      await approval(notices);
      final original = sink.shown.single;
      expect(original.showPreview, isTrue);
      expect(original.choices, isNotEmpty);

      await owner.setNotificationPreviews(false);
      sink.holdNextRefresh = true;
      final first = notices.refreshPreferences();
      await sink.permissionStarted.future;
      Future<void>? next;
      try {
        expect(sink.shown, hasLength(1));
        await owner.setNotificationPreviews(true);
        sink.permissionRelease.complete();
        final admitted = await sink.showStarted.future;
        expect(admitted.showPreview, isTrue);
        expect(admitted.choices, isNotEmpty);
        expect(admitted.body, original.body);
        await owner.setNotificationPreviews(false);
        expect(owner.current.notificationPreviewsAllowed, isFalse);
        next = notices.refreshPreferences();
      } finally {
        if (!sink.permissionRelease.isCompleted) {
          sink.permissionRelease.complete();
        }
        if (!sink.showRelease.isCompleted) sink.showRelease.complete();
        await first;
        if (next != null) await next;
      }

      // The latest physical delivery, rather than an owner flag, must be private.
      expect(sink.shown.last.showPreview, isFalse);
      expect(sink.shown.last.choices, isEmpty);
      expect(sink.shown.last.body, 'Approval needed');
      expect(sink.shown.last.expandedBody, 'Approval needed');
      expect(sink.shown.last.id, original.id);
      expect(sink.shown.last.revision, original.revision);
      expect(sink.shown.last.alert, isFalse);
      expect(sink.cancelled, isEmpty);
      final count = sink.shown.length;
      await notices.refreshPreferences();
      expect(sink.shown, hasLength(count));
    },
  );

  test(
    'false journal acknowledgement cannot suppress same-policy repair',
    () async {
      SharedPreferences.resetStatic();
      final platform = _FailedJournal();
      SharedPreferencesStorePlatform.instance = platform;
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      final sink = RecordingTurnNotificationSink();
      final notices = ChatNotificationCoordinator(
        prefs,
        sink,
        appPreferences: owner,
      );
      addTearDown(() {
        owner.dispose();
        SharedPreferences.setMockInitialValues({});
      });
      await approval(notices);
      final oldJournal = await platform.journal();
      await owner.setNotificationPreviews(false);
      platform.failNextJournal = true;
      Object? failure;
      try {
        await notices.refreshPreferences();
      } catch (error) {
        failure = error;
      }
      expect(platform.failedWrites, 1);
      expect(sink.shown, hasLength(2));
      expect(sink.shown.last.showPreview, isFalse);
      expect(sink.shown.last.choices, isEmpty);
      expect(
        await platform.journal(),
        oldJournal,
        reason:
            'controlled false acknowledgement left the physical journal old',
      );

      await notices.refreshPreferences();
      final stored = jsonDecode((await platform.journal())!) as Map;
      final rendered =
          jsonDecode((stored[chat] as Map)['rendered'] as String) as Map;
      expect(rendered['preview'], isFalse);
      expect(rendered['choices'], isEmpty);
      expect(rendered['body'], 'Approval needed');
      expect(
        failure,
        isA<StateError>(),
        reason: 'physical delivery does not confirm journal settlement',
      );
      final writes = platform.journalWrites;
      final shown = sink.shown.length;
      await notices.refreshPreferences();
      expect(platform.journalWrites, writes);
      expect(sink.shown, hasLength(shown));
    },
  );

  for (final restoring in [false, true]) {
    test(
      '${restoring ? 'restore' : 'inputs'} ABA invalidates policy acknowledgment',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final owner = AppPreferences(prefs);
        addTearDown(owner.dispose);
        if (restoring) {
          final initial = ChatNotificationCoordinator(
            prefs,
            RecordingTurnNotificationSink(),
            appPreferences: owner,
          );
          await approval(initial);
        }
        await owner.setNotificationPreviews(false);
        final sink = _HeldRefreshSink()..holdNextRefresh = true;
        final notices = ChatNotificationCoordinator(
          prefs,
          sink,
          appPreferences: owner,
        );
        final first = restoring
            ? notices.restore(owns: (_) => true)
            : approval(notices);
        await sink.permissionStarted.future;
        Future<void>? next;
        try {
          expect(sink.shown, isEmpty);
          await owner.setNotificationPreviews(true);
          sink.permissionRelease.complete();
          final admitted = await sink.showStarted.future;
          expect(admitted.showPreview, isTrue);
          expect(admitted.choices, isNotEmpty);
          expect(admitted.alert, !restoring);
          await owner.setNotificationPreviews(false);
          expect(owner.current.notificationPreviewsAllowed, isFalse);
          next = notices.refreshPreferences();
        } finally {
          if (!sink.permissionRelease.isCompleted) {
            sink.permissionRelease.complete();
          }
          if (!sink.showRelease.isCompleted) sink.showRelease.complete();
          await first;
          if (next != null) await next;
        }
        expect(sink.shown.last.showPreview, isFalse);
        expect(sink.shown.last.choices, isEmpty);
        expect(sink.shown.last.body, 'Approval needed');
        expect(sink.shown.last.expandedBody, 'Approval needed');
        expect(sink.shown.last.alert, isFalse);
        expect(sink.cancelled, isEmpty);
        final count = sink.shown.length;
        await notices.refreshPreferences();
        expect(sink.shown, hasLength(count));
      },
    );
  }

  test(
    'failed read journal settles on same-policy refresh without replay',
    () async {
      SharedPreferences.resetStatic();
      final platform = _FailedJournal();
      SharedPreferencesStorePlatform.instance = platform;
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      final sink = RecordingTurnNotificationSink();
      final notices = ChatNotificationCoordinator(
        prefs,
        sink,
        appPreferences: owner,
      );
      addTearDown(() {
        owner.dispose();
        SharedPreferences.setMockInitialValues({});
      });
      const focus = NotificationFocus('answer', 'reply');
      await notices.result(
        chat: chat,
        title: 'Build site',
        scope: 'Home / default',
        focus: focus,
        content: ChatNotificationContent.reply('Build complete'),
      );
      final original = sink.shown.single;
      final oldJournal = await platform.journal();
      platform.failNextJournal = true;
      Object? failure;
      try {
        await notices.read(chat, focus.identity);
      } catch (error) {
        failure = error;
      }
      expect(sink.cancelled, [original.id]);
      expect(sink.shown, hasLength(1));
      expect(notices.resultFor(chat), isNull);
      expect(notices.hasNotice(chat), isFalse);
      expect(platform.failedWrites, 1);
      expect(await platform.journal(), oldJournal);
      expect(failure, isA<StateError>());

      await notices.refreshPreferences();
      final stored = jsonDecode((await platform.journal())!) as Map;
      final row = stored[chat] as Map;
      expect(
        row['result'],
        isNull,
        reason: 'fresh restart data must not resurrect the read answer',
      );
      expect(row['posted'], isNull);
      expect(row['rendered'], isNull);
      expect(sink.cancelled, [original.id]);
      expect(sink.shown, hasLength(1));
      final writes = platform.journalWrites;
      await notices.refreshPreferences();
      expect(platform.journalWrites, writes);
    },
  );
}

class _HeldRefreshSink extends RecordingTurnNotificationSink {
  bool holdNextRefresh = false;
  final permissionStarted = Completer<void>();
  final permissionRelease = Completer<void>();
  final showStarted = Completer<TurnNotification>();
  final showRelease = Completer<void>();

  @override
  Future<bool?> notificationsEnabled() async {
    if (holdNextRefresh && !permissionStarted.isCompleted) {
      permissionStarted.complete();
      await permissionRelease.future;
    }
    return super.notificationsEnabled();
  }

  @override
  Future<void> show(TurnNotification notification) async {
    if (holdNextRefresh && !showStarted.isCompleted) {
      showStarted.complete(notification);
      await showRelease.future;
    }
    await super.show(notification);
  }
}

class _FailedJournal extends InMemorySharedPreferencesStore {
  _FailedJournal() : super.empty();
  bool failNextJournal = false;
  int failedWrites = 0;
  int journalWrites = 0;
  static const key = 'flutter.${ChatNotificationCoordinator.storageKey}';

  Future<String?> journal() async => (await getAll())[key] as String?;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == _FailedJournal.key) {
      journalWrites++;
      if (failNextJournal) {
        failNextJournal = false;
        failedWrites++;
        return false;
      }
    }
    return super.setValue(valueType, key, value);
  }
}
