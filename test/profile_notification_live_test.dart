import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const port = int.fromEnvironment('HERMES_TEST_PORT');

  for (final requestInput in [false, true]) {
    test(
      'real external ${requestInput ? 'input request' : 'completion'} alerts without opening its chat',
      () async {
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        SharedPreferences.setMockInitialValues({});
        final notifications = <({ProfileSessionKey key, bool needsInput})>[];
        final completion = Completer<void>();
        final attention = Completer<void>();
        final clients = <ProfileWorkspaceController>[];
        ProfileChat? ownedChat;
        try {
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          addTearDown(appPreferences.dispose);
          ProfileWorkspaceController client(String id, {bool observe = false}) {
            final result = ProfileWorkspaceController(
              access: ConnectionAccess(
                connection: SavedConnection(
                  id: id,
                  label: 'Notification coverage live QA',
                  host: '127.0.0.1',
                  port: port,
                  dashboardPortOverride: port,
                  apiKey: '',
                ),
                dashboardOAuth: null,
              ),
              connectionIdentity: id,
              preferences: preferences,
              appPreferences: appPreferences,
              onAttention: observe
                  ? (chat) async {
                      final needsInput = chat.content.needsAttention;
                      notifications.add((
                        key: chat.key,
                        needsInput: needsInput,
                      ));
                      if (needsInput && !attention.isCompleted) {
                        attention.complete();
                      }
                      if (!needsInput && !completion.isCompleted) {
                        completion.complete();
                      }
                    }
                  : null,
            );
            clients.add(result);
            return result;
          }

          final observer = client(
            'notification-observer-live-qa',
            observe: true,
          );
          await observer.initialize();
          expect(observer.error, isNull);
          expect(await observer.switchProfile('android-qa-b'), isTrue);
          observer.setRouteVisibility(observer, false);
          final producer = client('notification-producer-live-qa');
          await producer.initialize();
          expect(producer.error, isNull);
          expect(await producer.switchProfile('android-qa-a'), isTrue);
          final chat = await producer.createChat(canDispatch: () => true);
          ownedChat = chat;
          await producer.updateDraft(
            chat,
            requestInput
                ? 'Use the clarify tool to ask "Continue local alert check?" with '
                      'choices Yes and No. Wait for my answer, then reply exactly '
                      'NOTIFICATION_INPUT_OK. Do not do any other work.'
                : 'Use the terminal tool to run python -c "import time; time.sleep(6)" '
                      'once, then reply exactly NOTIFICATION_OUTSIDE_OK. Do not do any '
                      'other work or access any files.',
          );
          await producer.send(chat);
          if (requestInput) {
            await attention.future.timeout(const Duration(seconds: 45));
            expect(chat.runtime.pendingQuestion, isNotNull);
            await producer.clarify(chat, 'Yes');
          }
          await completion.future.timeout(const Duration(seconds: 105));
          await Future<void>.delayed(const Duration(seconds: 3));
          expect(notifications, hasLength(requestInput ? 2 : 1));
          expect(notifications.last.needsInput, isFalse);
          for (final notification in notifications) {
            expect(notification.key.sessionId, chat.key.sessionId);
            expect(notification.key.workspace.profileName, 'android-qa-a');
          }
          expect(observer.current?.scope.profileName, 'android-qa-b');
          expect(observer.current?.chat, isNull);
          expect(chat.runtime.execution, ChatExecution.completed);
          expect(chat.runtime.error, isNull);
        } finally {
          try {
            if (ownedChat?.runtime.blocksTurnAdmission == true) {
              await clients.last.stop(ownedChat!);
            }
          } finally {
            for (final client in clients) {
              client.dispose();
            }
            HttpOverrides.global = previousOverrides;
          }
        }
      },
      skip: port == 0,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'real backgrounded controller forwards its completion event',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      final notifications = <({ProfileSessionKey key, bool needsInput})>[];
      final completion = Completer<void>();
      ProfileWorkspaceController? controller;
      ProfileChat? ownedChat;
      Object? cleanupFailure;
      try {
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        final live = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: SavedConnection(
              id: 'notification-event-live-qa',
              label: 'Notification event live QA',
              host: '127.0.0.1',
              port: port,
              dashboardPortOverride: port,
              apiKey: '',
            ),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'notification-event-live-qa',
          preferences: preferences,
          appPreferences: appPreferences,
          onAttention: (chat) async {
            final needsInput = chat.content.needsAttention;
            notifications.add((key: chat.key, needsInput: needsInput));
            if (!completion.isCompleted) completion.complete();
          },
        );
        controller = live;
        await live.initialize();
        expect(live.error, isNull);
        expect(await live.switchProfile('android-qa-a'), isTrue);
        expect(live.current?.scope.profileName, 'android-qa-a');

        final chat = await live.createChat(canDispatch: () => true);
        ownedChat = chat;
        live.setRouteVisibility(live, false);
        await live.updateDraft(
          chat,
          'Reply exactly NOTIFICATION_EVENT_OK. Do not use tools or perform '
          'other work.',
        );
        await live.send(chat);

        await completion.future.timeout(const Duration(seconds: 105));
        expect(notifications, hasLength(1));
        expect(notifications.single.key, chat.key);
        expect(notifications.single.key.workspace.profileName, 'android-qa-a');
        expect(notifications.single.needsInput, isFalse);
        expect(chat.runtime.execution, ChatExecution.completed);
        expect(chat.runtime.error, isNull);
      } finally {
        final chat = ownedChat;
        if (chat != null && chat.runtime.blocksTurnAdmission) {
          try {
            await controller?.stop(chat);
          } catch (error) {
            cleanupFailure = error;
          }
        }
        controller?.dispose();
        HttpOverrides.global = previousOverrides;
        if (cleanupFailure != null) {
          fail('Notification live cleanup failed: $cleanupFailure');
        }
      }
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
