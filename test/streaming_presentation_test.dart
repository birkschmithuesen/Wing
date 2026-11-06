import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

class _ReadingPreferences extends InMemorySharedPreferencesStore {
  _ReadingPreferences() : super.empty();

  int snapshotWrites = 0;
  Completer<void>? nextSnapshot;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.workspace_reading_v1_streaming-presentation') {
      snapshotWrites++;
      final waiting = nextSnapshot;
      if (waiting != null && !waiting.isCompleted) waiting.complete();
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  late SharedPreferences preferences;
  late AppPreferences appPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
  });
  tearDown(() => appPreferences.dispose());
  Future<ProfileWorkspaceController> initialize(Host host) async {
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'streaming-presentation',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    return controller;
  }

  test('streaming text does not prepare unchanged reading history', () async {
    final previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.setMockInitialValues({});
    final storage = _ReadingPreferences();
    SharedPreferencesStorePlatform.instance = storage;
    addTearDown(
      () => SharedPreferencesStorePlatform.instance = previousPlatform,
    );
    preferences = await SharedPreferences.getInstance();
    appPreferences.dispose();
    appPreferences = AppPreferences(preferences);
    final host = Host();
    final controller = await initialize(host);
    addTearDown(controller.dispose);
    final chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'message.start');
    // The controller uses wall time to rate-limit reading snapshots. Cross its
    // interval so this test catches a snapshot triggered by streaming alone.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    // Flush pending durable changes from initialization before observing an
    // unchanged history. Subsequent text must not mark it dirty again.
    host.event('a', 'message.delta', {'text': ''});
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    chat.reading.installSavedHistory([
      {'id': 1, 'role': 'assistant', 'content': 'Saved answer'},
    ]);
    final saved = chat.reading.messages.single;
    storage.snapshotWrites = 0;

    host.event('a', 'message.delta', {'text': 'First'});
    host.event('a', 'message.delta', {'text': ' second'});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    host.event('a', 'reasoning.delta', {'text': 'Thinking'});
    host.event('a', 'reasoning.delta', {'text': ' more'});
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(chat.reading.streaming, 'First second');
    expect(
      chat.runtime.activityEntries.whereType<ChatReasoningEntry>().last.text,
      'Thinking more',
    );
    expect(storage.snapshotWrites, 0);
    expect(chat.reading.messages.single, same(saved));

    // An actual saved-message change must still refresh offline reading.
    storage.nextSnapshot = Completer<void>();
    host.event('a', 'message.interim');
    await storage.nextSnapshot!.future.timeout(const Duration(seconds: 3));
    expect(storage.snapshotWrites, greaterThan(0));
    expect(chat.reading.messages.first, same(saved));
    final snapshotPreferences = await SharedPreferences.getInstance();
    final storageKey = 'workspace_reading_v1_streaming-presentation';
    expect(snapshotPreferences.getString(storageKey), contains('First second'));
    expect(snapshotPreferences.getString(storageKey), contains('Saved answer'));
  });

  test(
    'interim reading is saved while the next answer keeps streaming',
    () async {
      final host = Host();
      final controller = await initialize(host);
      addTearDown(controller.dispose);
      await controller.createChat(canDispatch: () => true);
      host.event('a', 'message.start');
      host.event('a', 'message.delta', {'text': 'Saved interim answer'});
      host.event('a', 'message.interim');
      for (var i = 0; i < 6; i++) {
        host.event('a', 'message.delta', {'text': 'Unfinished live answer'});
        await Future<void>.delayed(const Duration(milliseconds: 220));
      }

      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      final encoded = preferences.getString(
        'workspace_reading_v1_streaming-presentation',
      )!;
      final snapshot = jsonDecode(encoded) as Map;
      final messages = snapshot['profiles'][0]['chats'][0]['messages'] as List;
      expect(
        messages.map((row) => row['content']),
        contains('Saved interim answer'),
      );
      final pending = messages.singleWhere(
        (row) => row['_reply_streaming'] == true,
      );
      expect(pending['content'], contains('Unfinished live answer'));
      expect(pending['_reply_turn'], isNotEmpty);
      expect(pending['_reply_segment'], 1);
    },
  );

  testWidgets('text ingestion is immediate and phase changes publish at once', (
    tester,
  ) async {
    final host = Host();
    final controller = await initialize(host);
    addTearDown(controller.dispose);
    final chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'message.start');
    await tester.pump();
    var updates = 0;
    controller.addListener(() => updates++);

    host.event('a', 'message.delta', {'text': 'First'});
    expect(updates, 1);
    host.event('a', 'message.delta', {'text': ' second'});
    expect(chat.reading.streaming, 'First second');
    expect(updates, 1);
    await tester.pump(const Duration(milliseconds: 99));
    expect(updates, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(updates, 2);

    host.event('a', 'reasoning.delta', {'text': 'Thinking'});
    expect(chat.runtime.mainActivity, ChatMainActivity.thinking);
    expect(updates, 3);
    host.event('a', 'reasoning.delta', {'text': ' more'});
    expect(
      chat.runtime.activityEntries.whereType<ChatReasoningEntry>().last.text,
      'Thinking more',
    );
    expect(updates, 3);
    host.event('a', 'message.delta', {'text': ' third'});
    expect(chat.runtime.mainActivity, ChatMainActivity.writing);
    expect(updates, 4);
    expect(chat.reading.streaming, 'First second third');
    await tester.pump(const Duration(milliseconds: 100));
    expect(updates, 4);
  });

  for (final event in ['approval', 'turn.error', 'message.interim']) {
    testWidgets('$event publishes pending text without waiting for a timer', (
      tester,
    ) async {
      final host = Host();
      final controller = await initialize(host);
      addTearDown(controller.dispose);
      final chat = await controller.createChat(canDispatch: () => true);
      host.event('a', 'message.start');
      await tester.pump();
      var updates = 0;
      controller.addListener(() => updates++);
      host.event('a', 'message.delta', {'text': 'First'});
      host.event('a', 'message.delta', {'text': ' pending'});
      expect(updates, 1);

      host.event('a', event, {
        if (event == 'approval') ...{
          'request_id': 'review',
          'command': 'test command',
        },
        if (event == 'turn.error') 'message': 'Provider stopped',
      });
      expect(updates, 2);
      if (event == 'approval') {
        expect(chat.runtime.approval?.requestId, 'review');
        expect(chat.runtime.needsInput, isTrue);
        expect(chat.reading.streaming, 'First pending');
      } else if (event == 'turn.error') {
        expect(chat.runtime.error, 'Provider stopped');
        expect(chat.runtime.execution, ChatExecution.failed);
        expect(chat.reading.streaming, 'First pending');
      } else {
        expect(chat.reading.messages.last['content'], 'First pending');
        expect(chat.reading.streaming, isEmpty);
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(updates, 2);
    });
  }

  testWidgets('one chat error publishes other chats pending text and rows', (
    tester,
  ) async {
    final host = Host();
    final controller = await initialize(host);
    addTearDown(controller.dispose);
    final a = await controller.createChat(canDispatch: () => true);
    host.event('a', 'message.start');
    host.event('a', 'message.delta', {'text': 'A'});
    await controller.switchProfile('b');
    // Host's replacement counter is global; this is B's first independent chat.
    host.sessionCreates = 0;
    final b = await controller.createChat(canDispatch: () => true);
    host.event('b', 'message.start');
    await tester.pump();
    host.event('a', 'message.delta', {'text': ''});
    host.event('b', 'message.delta', {'text': 'B'});
    var updates = 0;
    controller.addListener(() => updates++);
    host.event('a', 'message.delta', {'text': ' pending'});
    host.event('b', 'message.delta', {'text': ' pending'});
    expect(updates, 0);
    host.event('a', 'turn.error', {'message': 'A stopped'});
    expect(updates, 1);
    expect(a.reading.streaming, 'A pending');
    expect(b.reading.streaming, 'B pending');
    expect(b.runtime.execution, ChatExecution.running);
    expect(controller.browserChanges.value.chat, isNull);
    await tester.pump(const Duration(milliseconds: 100));
    expect(updates, 1);
  });

  testWidgets('disposing with pending text cancels trailing presentation', (
    tester,
  ) async {
    final host = Host();
    final controller = await initialize(host);
    final chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'message.start');
    var updates = 0;
    controller.addListener(() => updates++);
    host.event('a', 'message.delta', {'text': 'First'});
    host.event('a', 'message.delta', {'text': ' pending'});
    expect(chat.reading.streaming, 'First pending');
    controller.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    expect(updates, 1);
    expect(tester.takeException(), isNull);
  });
}
