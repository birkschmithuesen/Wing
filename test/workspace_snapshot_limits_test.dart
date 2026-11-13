import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/workspace_snapshot_store.dart';

import 'profile_workspace_controller_test.dart' show Host;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'message limit uses encoded characters and excludes its boundary',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = WorkspaceSnapshotStore(preferences, 'message-limits');

      Map<String, dynamic> row(
        String id,
        int length, {
        String character = 'x',
      }) {
        final message = <String, dynamic>{'id': id, 'content': ''};
        final overhead = jsonEncode(message).length;
        message['content'] = character * (length - overhead);
        expect(jsonEncode(message).length, length);
        return message;
      }

      final messages = [
        row('below', 32767),
        row('boundary', 32768),
        row('above', 32769),
        row('multibyte', 32767, character: '語'),
        {'id': 'escaped', 'content': '\n' * 17000},
      ];
      final snapshot = <String, dynamic>{
        'profiles': [
          {
            'name': 'a',
            'chats': [
              {'id': 'chat', 'messages': messages},
            ],
          },
        ],
      };

      await store.write(snapshot);

      final saved = store.read()['profiles'][0]['chats'][0]['messages'] as List;
      expect(saved.map((message) => message['id']), ['below', 'multibyte']);
      expect(snapshot['profiles'][0]['chats'][0]['messages'], same(messages));
      expect(messages, hasLength(5));
    },
  );

  test(
    'large excluded metadata does not discard small reading content',
    () async {
      const storageKey = 'workspace_reading_v1_metadata-projection';
      final seed = jsonEncode({
        'selected': 'a',
        'profiles': [
          {
            'name': 'a',
            'sessions': [],
            'projects': [],
            'chats': [
              {'id': 'chat', 'title': 'Chat', 'messages': []},
            ],
          },
        ],
      });
      SharedPreferences.setMockInitialValues({storageKey: seed});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'projection',
            label: 'Projection',
            host: 'unused',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'metadata-projection',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: Host().gateway,
      );
      final source = <String, dynamic>{
        'id': 7,
        'role': 'assistant',
        'content': 'Read this answer offline',
        'metadata': {'private': 'excluded private value ' * 2000},
      };
      expect(jsonEncode(source).length, greaterThan(32768));
      final chat = controller.current!.chats.values.single;
      chat.reading.installSavedHistory([source]);
      final admitted = chat.reading.messages.single;
      expect(admitted, isNot(same(source)));
      expect(admitted, source);
      (source['metadata'] as Map)['private'] = 'Caller rewrite';
      expect(
        (admitted['metadata'] as Map)['private'],
        contains('excluded private value'),
      );

      controller.dispose();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (preferences.getString(storageKey) == seed &&
          DateTime.now().isBefore(deadline)) {
        await preferences.reload();
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(
        preferences.getString(storageKey),
        isNot(seed),
        reason: 'Disposing the workspace must persist its projected reading.',
      );

      final encoded = preferences.getString(storageKey)!;
      final saved =
          jsonDecode(encoded)['profiles'][0]['chats'][0]['messages'] as List;
      expect(saved, [
        {'id': 7, 'role': 'assistant', 'content': 'Read this answer offline'},
      ]);
      expect(encoded, isNot(contains('excluded private value')));
      expect(chat.reading.messages.single, same(admitted));
      expect(source['metadata'], isNotNull);
    },
  );

  test('display metadata is typed before applying the message limit', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = WorkspaceSnapshotStore(preferences, 'display-limits');
    final source = <String, dynamic>{
      'id': 'notice',
      'role': 'user',
      'content': 'Small result',
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 2, 'private': 'excluded ' * 10000},
      'open_requests': [
        {'id': 'excluded'},
      ],
    };
    await store.write({
      'profiles': [
        {
          'name': 'a',
          'chats': [
            {
              'id': 'chat',
              'messages': [
                source,
                {
                  'id': 'oversized-display',
                  'content': 'Small content',
                  'display_content': 'x' * 32768,
                },
              ],
            },
          ],
        },
      ],
    });
    final saved = store.read()['profiles'][0]['chats'][0]['messages'] as List;
    expect(saved, [
      {
        'id': 'notice',
        'role': 'user',
        'display_kind': 'async_delegation_complete',
        'content': 'Small result',
        'display_metadata': {'task_count': 2},
      },
    ]);
    expect(source['display_metadata']['private'], isNotNull);
    expect(
      preferences.getString('workspace_reading_v1_display-limits'),
      isNot(contains('excluded')),
    );
  });
}
