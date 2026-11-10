import 'support/composer_fixture.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/workspace_snapshot_store.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/user_message_attachment.dart';
import 'package:wing/core/models/user_message_content.dart';
import 'helpers/pump_markdown_widget.dart';
import 'profile_workspace_controller_test.dart' show Host;

void main() {
  testWidgets(
    'cached transcript preserves display meaning without live authority',
    (tester) async {
      const storageKey = 'workspace_reading_v1_display-semantics';
      SharedPreferences.setMockInitialValues({
        storageKey: jsonEncode({
          'selected': 'a',
          'profiles': [
            {
              'name': 'a',
              'sessions': [],
              'projects': [],
              'chats': [
                {'id': 'durable-chat', 'title': 'Cached chat', 'messages': []},
              ],
            },
          ],
        }),
      });
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final runtimes = WorkspaceRuntimeFixture();
      ProfileWorkspaceController owner() => ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'display',
            label: 'Display',
            host: 'unused',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'display-semantics',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: Host().gateway,
        runtimeFactory: runtimes.create,
      );
      final original = owner();
      final cached = original.current!.chats.values.single;
      final runtime = runtimes.forChat(cached);
      runtime.receiveApproval({
        'request_id': 'uncached-input',
        'command': 'Review',
      });
      final originalChat = cached;

      originalChat.reading.installSavedHistory([
        {
          'id': 1,
          'role': 'user',
          'content': 'Hidden context',
          'display_kind': 'hidden',
          'prompts': [
            {
              'kind': 'approval',
              'prompt_id': 'excluded',
              'execution_generation': 0,
            },
          ],
        },
        {
          'id': 2,
          'role': 'user',
          'content': 'Model-facing context',
          'display_kind': 'steer',
          'display_content': 'Keep searching',
        },
        {
          'id': 3,
          'role': 'user',
          'content': 'Finished result',
          'display_kind': 'async_delegation_complete',
          'display_metadata': {'task_count': 2, 'unrelated': 'excluded'},
        },
        {'id': 4, 'role': 'system', 'content': 'review:Review completed'},
        {
          'id': 5,
          'role': 'user',
          'content': '',
          'submitted_attachments': const [
            UserMessageAttachment(
              name: 'Original report.pdf',
              target: '@file:/server/report.pdf',
              isImage: false,
            ),
            UserMessageAttachment(
              name: 'Shared photo.jpg',
              target: '/server/photo.jpg',
              isImage: true,
            ),
          ],
        },
      ]);
      original.dispose();
      await tester.runAsync(
        () => Future<void>(() async {
          while (true) {
            await preferences.reload();
            final saved = jsonDecode(preferences.getString(storageKey)!);
            if ((saved['profiles'][0]['chats'][0]['messages'] as List).length ==
                5) {
              return;
            }
            await Future<void>.delayed(Duration.zero);
          }
        }).timeout(const Duration(seconds: 10)),
      );
      final restored = owner();
      addTearDown(restored.dispose);
      final chat = restored.current!.chats.values.single;
      expect(chat.runtime.runtimeId, 'durable-chat');
      expect(chat.runtime.offline, isTrue);
      expect(chat.runtime.execution, ChatExecution.idle);
      expect(chat.runtime.approval, isNull);
      expect(chat.runtime.questions, isNull);
      expect(chat.runtime.secureInput, isNull);
      expect(preferences.getString(storageKey), isNot(contains('excluded')));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (final row in chat.reading.messages)
                    ProfileMessage(message: TranscriptMessage.fromRow(row)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hidden context'), findsNothing);
      expect(find.text('Model-facing context'), findsNothing);
      expect(find.text('steered'), findsNothing);
      expect(find.text('Keep searching'), findsOneWidget);
      final savedSteer = tester.widget<ProfileMessage>(
        find.byWidgetPredicate(
          (widget) => widget is ProfileMessage && widget.message.id == 2,
        ),
      );
      expect(savedSteer.message.kind, TranscriptMessageKind.dialogue);
      expect(savedSteer.message.copyText, 'Keep searching');
      expect(find.text('2 background agents finished'), findsOneWidget);
      expect(find.text('Memory and skills review'), findsOneWidget);
      expect(find.text('Reported changes'), findsNothing);
      expect(find.byType(UserMessageAttachmentTile), findsNWidgets(2));
      expect(find.text('Original report.pdf'), findsOneWidget);
      expect(find.text('Shared photo.jpg'), findsOneWidget);
      expect(find.text('Can’t load image'), findsOneWidget);
      expect(find.byTooltip('Retry image preview'), findsOneWidget);
      await tester.tap(find.text('Memory and skills review'));
      await tester.pumpAndSettle();
      expect(find.text('Reported changes'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('Memory and skills review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View result'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(find.text('Finished result'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cold notification retains cached reading, offline outbox and fresh draft',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final host = Host()..running = false;
      final connection = SavedConnection(
        id: 'claw',
        label: 'Claw',
        host: 'unused',
        port: 1,
        apiKey: '',
      );
      ProfileWorkspaceController owner(String identity) =>
          ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: connection,
              dashboardOAuth: null,
            ),
            connectionIdentity: identity,
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: host.gateway,
          );
      var controller = owner('verified');
      final starting = controller.initialize();
      await tester.pump();
      await starting;
      final chat = await controller.createChat(canDispatch: () => true);
      final key = chat.key;
      await controller.updateDraft(chat, 'My unsent thought');
      expect(chat.reading.messages.single['content'], 'a completed');
      controller.dispose();
      controller = owner('verified');
      expect(controller.current!.sessions, isNotEmpty);
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.unchecked,
      );
      host.discoveryFailure = const SocketException(
        'Failed host lookup: private.host',
      );
      await controller.openNotification(key);
      expect(
        controller.notificationChat!.reading.messages.single['content'],
        'a completed',
      );
      expect(
        controller.notificationChat!.composer.observation.text,
        'My unsent thought',
      );
      expect(controller.notificationChat!.runtime.offline, isTrue);
      expect(controller.notificationChat!.runtime.opening, isTrue);
      expect(controller.error, isNull);
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.reconnecting,
      );
      final offlineChat = controller.notificationChat!;
      await controller.send(offlineChat);
      expect(offlineChat.composer.observation.text, isEmpty);
      expect(
        offlineChat.composer.observation.queue.single.text,
        'My unsent thought',
      );
      expect(
        offlineChat.composer.observation.queue.single.submissionUncertain,
        isFalse,
      );
      expect(offlineChat.reading.messages.single['content'], 'a completed');
      final waiting = (await controller.savedDraft(key))!;
      expect(waiting.text, isEmpty);
      expect(waiting.queuedPrompts.single.text, 'My unsent thought');
      expect(waiting.queuedPrompts.single.submissionUncertain, isFalse);
      await controller.updateDraft(offlineChat, 'Fresh thought while offline');
      final fresh = (await controller.savedDraft(key))!;
      expect(fresh.text, 'Fresh thought while offline');
      expect(fresh.queuedPrompts.single.text, 'My unsent thought');
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
      for (final seconds in [1, 2, 4, 8, 16, 30, 30]) {
        await tester.pump(Duration(seconds: seconds));
      }
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.reconnecting,
      );
      expect(controller.connectionStatus.recoveryAttemptInProgress, isFalse);
      expect(controller.notificationChat!.key, key);
      expect(
        controller.notificationChat!.composer.observation.text,
        'Fresh thought while offline',
      );
      expect(
        controller.notificationChat!.composer.observation.queue.single.text,
        'My unsent thought',
      );
      expect(
        controller.notificationChat!.reading.messages.single['content'],
        'a completed',
      );
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
      final changedCredentials = owner('other-credentials');
      expect(changedCredentials.current, isNull);
      changedCredentials.dispose();
      host.discoveryFailure = null;
      final resuming = controller.resumeConnection();
      await tester.pump();
      await resuming;
      expect(controller.notificationChat, isNull);
      expect(controller.current!.chat!.key, key);
      for (
        var attempt = 0;
        attempt < 20 &&
            (controller.current!.chat!.composer.observation.sending ||
                controller
                    .current!
                    .chat!
                    .composer
                    .observation
                    .queue
                    .isNotEmpty);
        attempt++
      ) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 10));
      }
      final resumedChat = controller.current!.chat!;
      expect(
        resumedChat.composer.observation.text,
        'Fresh thought while offline',
      );
      expect(resumedChat.runtime.offline, isFalse);
      expect(resumedChat.composer.observation.sending, isFalse);
      expect(resumedChat.composer.observation.queue, isEmpty);
      expect(
        resumedChat.reading.messages.any(
          (message) => message['content'] == 'a completed',
        ),
        isTrue,
      );
      final remaining = (await controller.savedDraft(key))!;
      expect(remaining.text, 'Fresh thought while offline');
      expect(remaining.queuedPrompts, isEmpty);
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.connected,
      );
      expect(
        host.calls
            .where((c) => c.$2 == 'prompt.submit')
            .map((call) => call.$3['text']),
        ['My unsent thought'],
      );
      controller.dispose();
    },
  );

  test(
    'oversized snapshots replace stale content and stay below the byte limit',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = WorkspaceSnapshotStore(preferences, 'verified');
      await store.write({'selected': 'stale', 'profiles': []});
      await store.write({
        'selected': 'new',
        'profiles': [
          {
            'name': 'new',
            'sessions': [],
            'projects': [],
            'chats': [
              {
                'id': 'recent',
                'messages': List.generate(
                  100,
                  (i) => {'id': i, 'content': '語' * 10000},
                ),
              },
            ],
          },
        ],
      });
      final saved = store.read();
      expect(saved['selected'], 'new');
      expect(
        utf8.encode(jsonEncode(saved)).length,
        lessThanOrEqualTo(2 * 1024 * 1024),
      );
      final messages = saved['profiles'][0]['chats'][0]['messages'] as List;
      expect(messages.last['id'], 99);
    },
  );
}
