import 'package:wing/core/models/transcript_reading.dart';
import 'dart:async';
import 'package:wing/core/models/chat_reading.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/profile_history_fixture.dart';

void main() {
  late ProfileHistoryFixture host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = ProfileHistoryFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Test',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'test',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'chat-0'),
    );
    chat = controller.current!.chat!;
    host.reads.clear();
  });

  test(
    'saved pages use the resolved chat identity and current profile',
    () async {
      chat.reading.installSnapshot(
        TranscriptReadingSnapshot(
          messages: chat.reading.messages,
          historySessionId: 'canonical-chat',
        ),
      );
      final page = await controller.savedHistoryPage(chat);
      expect(page.sessionId, 'canonical-chat');
      expect(page.rows, hasLength(500));
      expect(host.reads.single.$1, 'sessions/canonical-chat/messages');
      expect(host.reads.single.$2, {
        'profile': 'personal',
        'limit': '500',
        'offset': '0',
        'order': 'latest',
        'include_compacted': 'true',
        'inline_images': 'true',
      });
    },
  );

  test('a saved page cannot cross into a different chat', () async {
    host.historySessionIdOverride = 'different';
    await expectLater(controller.savedHistoryPage(chat), throwsFormatException);
  });

  test('Find refuses a held page after another chat becomes current', () async {
    final sourceSession = chat.reading.historySessionId ?? chat.key.sessionId;
    final gate = Completer<void>();
    host.historyDelays[(sourceSession, 0)] = gate;
    final reading = controller.openReadingSession(chat);
    addTearDown(reading.dispose);
    final loading = reading.start();
    await Future<void>.delayed(Duration.zero);
    expect(
      host.reads.where((read) => read.$1 == 'sessions/$sourceSession/messages'),
      hasLength(1),
    );
    expect(reading.observation.loading, isTrue);
    expect(gate.isCompleted, isFalse);
    final replacement = await controller.openSession(
      ProfileSessionKey(chat.key.workspace, 'chat-1'),
    );
    expect(replacement, isNotNull);
    expect(controller.current!.chat, same(replacement));
    expect(replacement, isNot(same(chat)));
    gate.complete();
    await loading;
    reading.search('message');
    expect(reading.observation.matches, isEmpty);
    expect(reading.observation.retired, isTrue);
    expect(controller.readingFocus(replacement!), isNull);
    expect(controller.current!.chat, same(replacement));
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
  });

  test(
    'Find accepts only issued matches from the captured history revision',
    () async {
      final reading = controller.openReadingSession(chat);
      addTearDown(reading.dispose);
      await reading.start();
      reading.search('message 620');
      final match = reading.observation.matches.single;
      final before = List<Map<String, dynamic>>.of(chat.reading.messages);
      final status = chat.runtime.execution;
      expect(
        reading.select(
          ChatReadingMatch(
            text: match.text,
            role: match.role,
            canSelect: match.canSelect,
          ),
        ),
        isFalse,
      );
      expect(controller.readingFocus(chat), isNull);
      expect(reading.select(match), isTrue);
      expect(controller.readingFocus(chat)!.rowId, 620);
      expect(controller.readingFocus(chat)!.offset, 0);
      final oldFocus = controller.readingFocus(chat)!;
      final newer = controller.openReadingSession(chat);
      addTearDown(newer.dispose);
      await newer.start();
      newer.search('message 620');
      final newerMatch = newer.observation.matches.single;
      expect(newer.select(newerMatch), isTrue);
      final newerFocus = controller.readingFocus(chat)!;
      expect(newerFocus, isNot(same(oldFocus)));
      controller.releaseReadingFocus(oldFocus);
      expect(controller.readingFocus(chat), same(newerFocus));
      expect(chat.reading.messages, before);
      expect(chat.runtime.execution, status);
      expect(() => reading.observation.matches.clear(), throwsUnsupportedError);
      await controller.refreshHistory(chat);
      expect(newer.select(newerMatch), isFalse);
      expect(controller.readingFocus(chat), isNull);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      reading.dispose();
      expect(reading.select(match), isFalse);
    },
  );

  test(
    'Find replaces its one nearby window when another chat is selected',
    () async {
      final first = chat;
      final readingA = controller.openReadingSession(first);
      addTearDown(readingA.dispose);
      await readingA.start();
      readingA.search('message 620');
      expect(readingA.select(readingA.observation.matches.single), isTrue);
      final focusA = controller.readingFocus(first)!;
      expect(focusA.rowId, 620);

      final second = await controller.openSession(
        ProfileSessionKey(first.key.workspace, 'chat-1'),
      );
      expect(second, isNotNull);
      expect(second, isNot(same(first)));
      final readingB = controller.openReadingSession(second!);
      addTearDown(readingB.dispose);
      await readingB.start();
      readingB.search('message 619');
      expect(readingB.select(readingB.observation.matches.single), isTrue);
      final focusB = controller.readingFocus(second)!;
      expect(focusB.rowId, 619);
      expect(controller.nearbyReadingMessages(second), isNotEmpty);
      controller.releaseReadingFocus(focusA);
      expect(controller.readingFocus(second), same(focusB));
      expect(controller.nearbyReadingMessages(second), isNotEmpty);

      final returned = await controller.openSession(first.key);
      expect(returned, same(first));
      expect(controller.current!.chat, same(first));
      expect(controller.readingFocus(first), isNull);
      expect(controller.nearbyReadingMessages(first), isNull);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );
}
