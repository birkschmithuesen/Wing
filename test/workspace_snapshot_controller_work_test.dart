import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_workspace_controller_test.dart' show Host;

/// Tracks caller-owned traversal at admission and accidental later reuse.
class _CountingMessage extends MapBase<String, dynamic> {
  _CountingMessage(this._data);

  final Map<String, dynamic> _data;
  int keyEnumerations = 0;

  @override
  dynamic operator [](Object? key) => _data[key];

  @override
  void operator []=(String key, dynamic value) => _data[key] = value;

  @override
  void clear() => _data.clear();

  @override
  dynamic remove(Object? key) => _data.remove(key);

  @override
  bool containsKey(Object? key) => _data.containsKey(key);

  @override
  Iterable<String> get keys {
    keyEnumerations++;
    return _data.keys;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'controller snapshots never traverse history rows on the UI isolate',
    () async {
      const storageKey = 'workspace_reading_v1_controller-work';
      final seed = <String, dynamic>{
        'selected': 'a',
        'profiles': [
          {
            'name': 'a',
            'sessions': [],
            'projects': [],
            'chats': [
              for (var c = 0; c < 10; c++)
                {'id': 'chat$c', 'title': 'chat$c', 'messages': []},
            ],
          },
        ],
      };
      final initialSnapshot = jsonEncode(seed);
      SharedPreferences.setMockInitialValues({storageKey: initialSnapshot});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'probe',
            label: 'Probe',
            host: 'unused',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'controller-work',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: Host().gateway,
      );
      final oversized = 'discarded history ' * 2200;
      final allRows = <_CountingMessage>[];
      final originalHistories = <ProfileChat, List<Map<String, dynamic>>>{};
      for (final chat in controller.current!.chats.values) {
        final incoming = [
          for (var m = 0; m < 80; m++)
            _CountingMessage({
              'id': m,
              'role': 'assistant',
              'content': m % 4 == 0 ? 'retained $m' : oversized,
              'timestamp': m,
              'metadata': {'private': 'excluded from reading snapshot'},
            }),
        ];
        chat.reading.installSavedHistory(incoming);
        originalHistories[chat] = chat.reading.messages;
        allRows.addAll(incoming);
        for (final row in incoming) {
          row.keyEnumerations = 0;
        }
      }

      controller.dispose();

      expect(
        allRows.every((row) => row.keyEnumerations == 0),
        isTrue,
        reason:
            'After immutable admission, snapshot preparation must not revisit '
            'caller-owned rows. Fixed fields and payload bounds are checked below.',
      );

      // Wait for the mocked platform write, rather than assuming a worker finishes
      // within a wall-clock delay. A test timeout still catches a missing write.
      await Future<void>(() async {
        while (true) {
          await preferences.reload();
          if (preferences.getString(storageKey) != initialSnapshot) return;
          await Future<void>.delayed(Duration.zero);
        }
      }).timeout(const Duration(seconds: 10));

      final saved = jsonDecode(preferences.getString(storageKey)!) as Map;
      final chats = saved['profiles'][0]['chats'] as List;
      expect(chats, hasLength(10));
      var retainedCount = 0;
      for (final chat in chats) {
        final messages = chat['messages'] as List;
        retainedCount += messages.length;
        expect(messages.map((row) => row['id']), [
          for (var m = 20; m < 80; m += 4) m,
        ]);
        for (final row in messages) {
          expect(
            (row as Map).keys,
            unorderedEquals(['id', 'role', 'content', 'timestamp']),
          );
          expect(row['content'], 'retained ${row['id']}');
        }
      }
      expect(retainedCount, 150);
      for (final entry in originalHistories.entries) {
        expect(entry.key.reading.messages, same(entry.value));
        expect(entry.value, hasLength(80));
        expect(entry.value[79]['content'], same(oversized));
        expect(entry.value[79]['metadata'], {
          'private': 'excluded from reading snapshot',
        });
      }
    },
  );
}
