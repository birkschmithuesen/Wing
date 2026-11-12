import 'package:wing/core/models/transcript_position.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/notification_focus.dart';
import 'package:wing/core/models/notification_input.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/services/chat_notification_coordinator.dart';
import 'package:wing/core/services/android_share_intent_service.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/workspace_snapshot_store.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/native_notification_sink.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/main.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;
import 'profile_notification_coverage_test.dart' show NotificationCoverageHost;
import 'support/recording_turn_notification_sink.dart';
import 'helpers/pump_markdown_widget.dart';

const _nativeNotifications = MethodChannel(NativeNotificationSink.channelName);

void main() {
  for (final scenario in [
    'open',
    'unloaded',
    'cached',
    'failed-read',
    'missing-snapshot',
    'still-pending',
    'local-answer',
    'desktop-answer',
  ]) {
    test('restored desktop question reconciles through $scenario', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final settings = AppPreferences(preferences);
      addTearDown(settings.dispose);
      final host = NotificationCoverageHost();
      final sink = RecordingTurnNotificationSink();
      final key = ProfileSessionKey(
        WorkspaceScope(
          connectionId: identityTestConnection().id,
          connectionIdentity: 'restored-question',
          profileName: 'a',
        ),
        'outside',
      );
      final encoded = jsonEncode(key.toJson());
      final seed = ChatNotificationCoordinator(
        preferences,
        sink,
        appPreferences: settings,
      );
      await seed.inputs(
        chat: encoded,
        title: 'Bot Chat',
        scope: 'Claw / butler',
        inputs: [
          NotificationInput(
            focus: const NotificationFocus('question', 'answered-on-desktop'),
            content: ChatNotificationContent.input('Restart Chrome now?'),
          ),
        ],
      );
      final restored = ChatNotificationCoordinator(
        preferences,
        sink,
        appPreferences: settings,
      );
      await restored.restore(owns: (_) => true);
      expect(restored.inputFor(encoded), isNotNull);
      if (scenario == 'cached') {
        await WorkspaceSnapshotStore(preferences, 'restored-question').write({
          'selected': 'a',
          'profiles': [
            {
              'name': 'a',
              'sessions': [
                {'id': 'outside', 'title': 'Bot Chat', 'profile': 'a'},
              ],
              'chats': [
                {
                  'id': 'outside',
                  'title': 'Bot Chat',
                  'messages': [
                    {'id': 1, 'role': 'assistant', 'content': 'Earlier reply'},
                  ],
                  'history_session': 'outside',
                },
              ],
            },
          ],
        });
      }
      final owner = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'restored-question',
        preferences: preferences,
        appPreferences: settings,
        gatewayFactory: host.gateway,
        onAttention: (_) async {},
        notificationInputsFor: restored.pendingInputsFor,
        onNotificationInputs: (notice) => restored.inputs(
          chat: jsonEncode(notice.key.toJson()),
          title: notice.title,
          scope: notice.connectionLabel,
          inputs: notice.inputs,
          alert: notice.alert,
        ),
      );
      addTearDown(owner.dispose);
      await owner.initialize();
      if (scenario == 'failed-read') host.resumeFails = true;
      if (scenario == 'missing-snapshot') {
        host.resumeSnapshots[1] = {'open_requests': null};
      }
      if (scenario == 'still-pending') host.waitingProfiles.add('a');
      if (scenario == 'open' || scenario == 'missing-snapshot') {
        await owner.openSession(key);
      } else {
        await owner.reconcileNotificationRequests({key});
        expect(
          owner.current!.chat,
          isNull,
          reason: 'Reconciliation must not navigate',
        );
      }
      await Future<void>.delayed(Duration.zero);
      if (scenario == 'failed-read') {
        expect(restored.inputFor(encoded)?.focus.id, 'answered-on-desktop');
        expect(sink.cancelled, isEmpty);
        host.resumeFails = false;
        await owner.reconcileNotificationRequests({key});
        await Future<void>.delayed(Duration.zero);
      }
      if (scenario == 'missing-snapshot') {
        expect(restored.inputFor(encoded)?.focus.id, 'answered-on-desktop');
        expect(sink.cancelled, isEmpty);
        return;
      }
      if (scenario == 'still-pending') {
        expect(restored.inputFor(encoded)?.focus.id, 'question-a');
        expect(
          owner.notificationChats.single.runtime.pendingQuestion?.requestId,
          'question-a',
        );
        expect(sink.cancelled, isEmpty);
        return;
      }
      expect(owner.notificationChats.single.runtime.pendingQuestion, isNull);
      expect(
        restored.inputFor(encoded),
        isNull,
        reason:
            'The confirmed empty request snapshot must retire the restored question',
      );
      expect(restored.hasNotice(encoded), isFalse);
      expect(sink.cancelled, contains(sink.shown.first.id));
      if (scenario == 'local-answer' || scenario == 'desktop-answer') {
        final chat = owner.notificationChats.single;
        host.gateways['a']!.onEvent!(
          StreamEvent(
            type: 'clarify',
            sessionId: chat.runtime.runtimeId,
            data: const {
              'request_id': 'live-question',
              'question': 'Continue?',
              'choices': ['Yes', 'No'],
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(restored.inputFor(encoded)?.focus.id, 'live-question');
        final cancellationCount = sink.cancelled.length;
        if (scenario == 'local-answer') {
          await owner.clarify(chat, 'Yes');
        } else {
          host.gateways['a']!.onEvent!(
            StreamEvent(
              type: 'request.cancel',
              sessionId: chat.runtime.runtimeId,
              data: const {
                'id': 'live-question',
                'method': 'clarify',
                'reason': 'resolved',
              },
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);
        expect(chat.runtime.pendingQuestion, isNull);
        expect(restored.inputFor(encoded), isNull);
        expect(restored.hasNotice(encoded), isFalse);
        expect(sink.cancelled.length, cancellationCount + 1);
      }
      final restarted = ChatNotificationCoordinator(
        preferences,
        sink,
        appPreferences: settings,
      );
      expect(
        restarted.inputFor(encoded),
        isNull,
        reason: 'Clearing must survive restart',
      );
    });
  }

  for (final savedOffset in [0.0, 1000.0]) {
    testWidgets(
      'restored notice tap overrides saved offset $savedOffset and clears read state across restart',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({
          'notification_permission_requested': true,
          'microphone_permission_requested': true,
        });
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final manager = await ConnectionManager.create(preferences);
        final connection = identityTestConnection();
        await manager.importConnections(
          [connection],
          replaceExisting: true,
          canCommit: () => true,
        );
        final identity = await ProfileConnectionIdentity().resolve(connection);
        final key = ProfileSessionKey(
          WorkspaceScope(
            connectionId: connection.id,
            connectionIdentity: identity,
            profileName: 'a',
          ),
          'same',
        );
        final seedSink = RecordingTurnNotificationSink();
        final seed = ChatNotificationCoordinator(
          preferences,
          seedSink,
          appPreferences: appPreferences,
        );
        const answer =
            'WING-RESTORE-REPLY: The unread result is ready. Open Wing to read it.';
        await seed.result(
          chat: jsonEncode(key.toJson()),
          title: 'Notification test',
          scope: 'Host / a',
          focus: const NotificationFocus('answer', 'original-reply'),
          content: ChatNotificationContent.reply(answer),
        );
        if (savedOffset > 0) {
          await seed.inputs(
            chat: jsonEncode(key.toJson()),
            title: 'Notification test',
            scope: 'Host / a',
            inputs: [
              NotificationInput(
                focus: const NotificationFocus(
                  'question',
                  'old-desktop-question',
                ),
                content: ChatNotificationContent.input(
                  'Already answered on desktop',
                ),
              ),
            ],
          );
        }
        final shown = <Map<dynamic, dynamic>>[];
        final cancelled = <int>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const plugin = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        messenger.setMockMethodCallHandler(
          plugin,
          (call) async => switch (call.method) {
            'initialize' => true,
            'getNotificationAppLaunchDetails' => {
              'notificationLaunchedApp': false,
            },
            'areNotificationsEnabled' => true,
            _ => null,
          },
        );
        messenger.setMockMethodCallHandler(_nativeNotifications, (call) async {
          if (call.method == 'show') shown.add(call.arguments as Map);
          if (call.method == 'cancel') cancelled.add(call.arguments as int);
          return call.method == 'initialize' ? [] : null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(plugin, null);
          messenger.setMockMethodCallHandler(_nativeNotifications, null);
        });
        final host = Host()
          ..running = false
          ..historyMessages = [
            if (savedOffset > 0)
              for (var index = 1; index <= 30; index++)
                {
                  'id': index,
                  'role': 'user',
                  'content':
                      'Earlier question $index with enough text to fill the history.',
                },
            {'id': 100, 'role': 'user', 'content': 'Prepare the result'},
            {'id': 101, 'role': 'assistant', 'content': answer},
          ];
        final app = GlobalKey<WingAppState>();
        final captures = <Object?>[];
        const shares = MethodChannel(AndroidShareIntentService.channelName);
        messenger.setMockMethodCallHandler(shares, (call) async {
          if (call.method == 'capturePhoto') captures.add(call.arguments);
          return null;
        });
        final shareIntents = AndroidShareIntentService();
        addTearDown(() {
          shareIntents.dispose();
          messenger.setMockMethodCallHandler(shares, null);
        });
        await shareIntents.initialize();
        await tester.pumpWidget(
          WingApp(
            key: app,
            shareIntents: shareIntents,
            connManager: manager,
            appPreferences: appPreferences,
            gatewayFactory: (_, scope) => host.gateway(scope),
          ),
        );
        await tester.pumpAndSettle();
        expect(shown, hasLength(1));
        expect(shown.single['alert'], isFalse);
        expect(cancelled, isEmpty);
        await tester.tap(find.text('Host').first);
        await tester.pumpAndSettle();
        final controller = await app.currentState!.profileController(
          connection,
        );
        if (savedOffset > 0) {
          expect(
            controller.current!.chat,
            isNull,
            reason: 'Restored question reconciliation must not open a route',
          );
          expect(shown.last['pending'], isEmpty);
          expect(
            shown.last['kind'],
            'answer',
            reason: 'Clearing a resolved input retains the unread answer',
          );
          expect(
            host.calls.where((call) => call.$2 == 'session.resume'),
            hasLength(1),
          );
          final previousChat = (await controller.openSession(key))!;
          previousChat.reading.recordReading(
            const TranscriptBookmark(messageId: 1),
          );
          await controller.updateDraft(
            previousChat,
            'An unsent draft to preserve',
          );
          controller.showList();
          await tester.pumpAndSettle();
          expect(cancelled, isEmpty);
        }
        // Exercise the native interaction entry point and production-created
        // controller callbacks, not a coordinator.read or app routing test double.
        final tap = messenger.handlePlatformMessage(
          _nativeNotifications.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('interaction', {'payload': shown.last['payload']}),
          ),
          (_) {},
        );
        var handled = false;
        unawaited(tap.then((_) => handled = true));
        for (var frame = 0; frame < 30 && !handled; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(handled, isTrue, reason: 'native tap handling must finish');
        await tester.pumpAndSettle();
        expect(find.byType(ProfileTranscript), findsOneWidget);
        final chat = controller.current!.chat!;
        await tester.settleMarkdown();
        await tester.pumpAndSettle();
        expect(find.text(answer), findsWidgets);
        final viewport = tester.getRect(
          find.byKey(const ValueKey('profile-transcript')),
        );
        expect(
          viewport.overlaps(tester.getRect(find.text(answer).first)),
          isTrue,
        );
        if (savedOffset > 0) {
          expect(chat.reading.readingPosition.resume?.messageId, isNot(1));
          expect(chat.composer.observation.text, 'An unsent draft to preserve');
          expect(
            tester
                .widget<TextField>(
                  find.byKey(const Key('profile-message-composer')),
                )
                .controller!
                .text,
            'An unsent draft to preserve',
          );
        }
        expect(chat.reading.historyError, isNull);
        expect(chat.runtime.offline, isFalse);
        expect(cancelled, isNot(contains(seedSink.shown.first.id)));
        await tester.drag(
          find.byKey(const ValueKey('profile-transcript')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();
        expect(cancelled, contains(seedSink.shown.first.id));
        expect(controller.visible, isTrue);
        await tester.tap(find.byTooltip('Attach file'));
        await tester.pumpAndSettle();
        final camera = find.ancestor(
          of: find.text('Camera'),
          matching: find.byType(ListTile),
        );
        expect(
          tester.widget<ListTile>(camera).enabled,
          isTrue,
          reason: 'Notification-opened chats retain the app camera capability',
        );
        await tester.tap(camera);
        await tester.pumpAndSettle();
        expect(captures, [
          {'target': key.toJson()},
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
        shown.clear();
        cancelled.clear();
        final restartedPreferences = AppPreferences(preferences);
        addTearDown(restartedPreferences.dispose);
        await tester.pumpWidget(
          WingApp(
            connManager: manager,
            appPreferences: restartedPreferences,
            gatewayFactory: (_, scope) => host.gateway(scope),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          shown,
          isEmpty,
          reason: 'read acknowledgement must survive the next cold launch',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
