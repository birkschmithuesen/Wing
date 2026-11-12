import 'support/composer_fixture.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/turn_notification_service.dart';

import 'profile_workspace_controller_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('previews remove markup, hidden content and URLs', () {
    final content = ChatNotificationContent.reply('''
<think>private reasoning</think>
# Result
**Fixed** the [channel](https://example.com/private).
```sh
secret command
```
![image](https://example.com/image)
See https://example.com/raw
token=not-for-alerts
''');
    expect(content.preview, 'Result Fixed the channel. See [redacted]');
    expect(content.body(showPreview: false), 'Reply ready');
    expect(
      ChatNotificationContent.reply('```sh\nprivate command\n```').preview,
      'Open the chat to read the reply.',
    );
    expect(
      ChatNotificationContent.reply('<reasoning>unfinished secret').preview,
      'Open the chat to read the reply.',
    );
    expect(
      ChatNotificationContent.reply(
        '    private command\n    private output',
      ).preview,
      'Open the chat to read the reply.',
    );
  });

  test('bounded previews preserve joined emoji and non-Latin text', () {
    final reply = ChatNotificationContent.reply('👩🏽‍💻你好' * 350);
    final body = reply.body(showPreview: true);
    expect(body.characters.length, lessThanOrEqualTo(180));
    expect(body, contains('👩🏽‍💻你好'));
    expect(body, endsWith('…'));
    expect(
      reply.body(showPreview: true, limit: 800).characters.length,
      lessThanOrEqualTo(800),
    );
  });

  test(
    'chat title and ownership survive preview hiding and per-chat ID stability',
    () {
      TurnNotification alert(
        String profile,
        ChatNotificationContent content, {
        bool preview = true,
      }) => TurnNotification.chat(
        payload: jsonEncode({
          'connection': 'host',
          'profile': profile,
          'session': 'same',
        }),
        title: 'Same chat name',
        scopeLabel: 'Home / $profile',
        content: content,
        showPreview: preview,
      );
      final reply = alert('a', ChatNotificationContent.reply('Actual result'));
      final input = alert('a', ChatNotificationContent.input('Which target?'));
      final hidden = alert(
        'a',
        ChatNotificationContent.reply('Actual result'),
        preview: false,
      );
      expect(reply.id, input.id);
      expect(
        reply.id,
        isNot(alert('b', ChatNotificationContent.reply('Other')).id),
      );
      expect(reply.id, hidden.id);
      expect(hidden.title, 'Same chat name');
      expect(hidden.body, 'Reply ready');
      expect(hidden.expandedBody, 'Reply ready');
      expect(reply.scopeLabel, 'Home / a');
      expect(
        reply.payload,
        isNot(alert('b', ChatNotificationContent.updated).payload),
      );
      expect(
        TurnNotification.chat(
          payload: 'target',
          title: '  ',
          scopeLabel: '',
          content: ChatNotificationContent.updated,
          showPreview: true,
        ).title,
        'Untitled chat',
      );
    },
  );

  group('controller event content', () {
    late fixture.Host host;
    late ProfileWorkspaceController controller;
    late AppPreferences appPreferences;
    late ProfileChat chat;
    late List<ProfileNotification> alerts;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      host = fixture.Host();
      alerts = [];
      final preferences = await SharedPreferences.getInstance();
      appPreferences = AppPreferences(preferences);
      controller = ProfileWorkspaceController(
        connectionIdentity: 'identity',
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Home',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        onAttention: (notification) async => alerts.add(notification),
      );
      await controller.initialize();
      chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'session.title', {
        'session_id': chat.key.sessionId,
        'title': 'Original title',
      });
      emitChatEvent(controller, chat, 'message.start');
    });
    tearDown(() {
      controller.dispose();
      appPreferences.dispose();
    });

    test('visible approval still alerts when action is required', () {
      controller.setRouteVisibility(controller, true);
      host.event('a', 'approval', {
        'request_id': 'first',
        'command': 'private command',
        'description': 'Review this action',
      });
      expect(alerts, hasLength(1));
      expect(alerts.single.content.needsAttention, isTrue);
    });

    test(
      'successive approvals remain available after the first response',
      () async {
        for (final id in ['first', 'second']) {
          host.event('a', 'approval', {
            'request_id': id,
            'command': 'command $id',
            'choices': ['once', 'deny'],
          });
        }
        expect(chat.runtime.approval?.requestId, 'first');
        await controller.approve(
          chat,
          'once',
          requestId: chat.runtime.approval!.requestId,
        );
        expect(chat.runtime.approval?.requestId, 'second');
        expect(chat.runtime.needsInput, isTrue);
        await controller.approve(
          chat,
          'deny',
          requestId: chat.runtime.approval!.requestId,
        );
        expect(chat.runtime.approval, isNull);
        expect(
          host.calls
              .where((c) => c.$2 == 'approval.respond')
              .map((c) => c.$3['prompt_id']),
          ['first', 'second'],
        );
      },
    );

    test(
      'completion keeps its text and title across delayed history refresh',
      () async {
        host.delays['a'] = Completer<void>();
        host.event('a', 'message.complete', {
          'text': 'This turn result',
          'mobile_push_event_id': 'event',
        });
        emitChatEvent(controller, chat, 'session.title', {
          'session_id': chat.key.sessionId,
          'title': 'Renamed while awaiting history',
        });
        chat.reading.updateStreaming('Newer text');
        host.historyMessages = [
          {'role': 'assistant', 'content': 'Unrelated history'},
        ];
        host.delays['a']!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(alerts.single.title, 'Original title');
        expect(alerts.single.content.preview, 'This turn result');
        expect(alerts.single.eventId, 'event');
        expect(alerts.single.key, chat.key);
      },
    );

    test('missing final text never borrows historical answer', () async {
      host.event('a', 'message.complete');
      await Future<void>.delayed(Duration.zero);
      expect(alerts.single.content.preview, 'Open the chat to read the reply.');
    });

    test(
      'delivered turns retain setup, A, B and identical C reply text',
      () async {
        for (final text in [
          'Round setup',
          'WING-N02-A: First result',
          'WING-N02-B: Replacement result',
          'WING-N02-B: Replacement result',
        ]) {
          host.event('a', 'message.start');
          host.event('a', 'message.complete', {'text': text});
          await Future<void>.delayed(Duration.zero);
        }
        expect(alerts.map((notice) => notice.content.preview), [
          'Round setup',
          'WING-N02-A: First result',
          'WING-N02-B: Replacement result',
          'WING-N02-B: Replacement result',
        ]);
      },
    );

    test(
      'side and background results use their own content while main runs',
      () {
        chat.reading.updateStreaming('Main reply');
        host.event('a', 'btw.complete', {
          'text': 'Side answer',
          'task_id': 'side',
        });
        host.event('a', 'background.complete', {
          'text': 'Background answer',
          'task_id': 'background',
        });
        expect(alerts.map((e) => e.content.preview), [
          'Side answer',
          'Background answer',
        ]);
        expect(alerts.every((e) => e.content.status == 'Reply ready'), isTrue);
        expect(chat.runtime.execution, ChatExecution.running);
      },
    );

    test(
      'questions and approvals share input presentation without commands',
      () {
        host.event('a', 'approval', {
          'request_id': 'private',
          'command': 'raw private command',
          'description': 'Restart the service',
        });
        host.event('a', 'clarify', {
          'request_id': 'q',
          'questions': [
            {'qid': 'one', 'question': 'Already answered'},
            {'qid': 'two', 'question': 'Which environment?'},
          ],
          'answers': {'one': 'yes'},
        });
        expect(alerts.map((e) => e.content.preview), [
          'Restart the service',
          'Which environment?',
        ]);
        expect(
          alerts.every(
            (e) => e.content.category == ChatNotificationCategory.inputNeeded,
          ),
          isTrue,
        );
      },
    );

    test('secure input and raw failures expose only fixed copy', () {
      host.event('a', 'secret', {
        'request_id': 's',
        'prompt': 'Sensitive prompt',
        'name': 'private-name',
      });
      host.event('a', 'turn.error', {
        'message': 'raw exception with credentials',
      });
      expect(alerts, hasLength(2));
      expect(alerts.first.content, ChatNotificationContent.secureInput);
      expect(alerts.last.content, ChatNotificationContent.failed);
    });

    for (final status in ['interrupted', 'error']) {
      test('$status completion is work stopped, not a reply', () async {
        host.event('a', 'message.complete', {
          'status': status,
          'text': 'raw private error',
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          alerts.single.content.category,
          ChatNotificationCategory.stopped,
        );
        expect(
          alerts.single.content.status,
          status == 'error' ? 'Turn failed' : 'Stopped',
        );
        expect(
          alerts.single.content.preview,
          isNot(contains('raw private error')),
        );
      });
    }
  });
}
