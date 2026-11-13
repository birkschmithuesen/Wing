import 'package:wing/core/services/bots_session.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'support/profile_history_fixture.dart';
import 'helpers/pump_markdown_widget.dart';

void main() {
  late ProfileHistoryFixture host;
  late ProfileWorkspaceController controller;
  late ChatBrowserData browser;
  late AppPreferences appPreferences;
  String? runningAssistant;
  var disableAnimations = false;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = ProfileHistoryFixture();
    runningAssistant = null;
    disableAnimations = false;
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
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
      gatewayFactory: (scope) {
        final gateway = host.gateway(scope);
        return ProfileGateway(
          scope: scope,
          get: gateway.read,
          rpc: (method, params) async {
            final result = await gateway.call(method, params);
            if (method == 'session.resume' &&
                scope.profileName == 'personal' &&
                params['session_id'] == 'chat-0' &&
                runningAssistant != null) {
              return {
                ...result,
                'running': true,
                'inflight': {'assistant': runningAssistant},
              };
            }
            return result;
          },
          discover: gateway.discover,
          connect: gateway.connect,
          close: gateway.close,
          disconnect: gateway.disconnect,
        );
      },
    );
    await controller.initialize();
    browser = ChatBrowserData(controller);
  });
  tearDown(() {
    browser.dispose();
    controller.dispose();
    appPreferences.dispose();
  });
  Future<ProfileChat> open([String id = 'chat-0']) async {
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, id),
    );
    return controller.current!.chat!;
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    await tester.pumpAndSettle();
  }

  test(
    'opens latest fifty and reads beyond five hundred to the start',
    () async {
      final chat = await open();
      expect(chat.reading.messages.first['id'], 571);
      expect(chat.reading.messages.last['id'], 620);
      final pageLimit = (host.messageCount / 50).ceil();
      for (
        var attempt = 0;
        attempt < pageLimit && chat.reading.nextHistoryOffset != null;
        attempt++
      ) {
        await controller.loadOlderMessages(chat);
      }
      expect(chat.reading.nextHistoryOffset, isNull);
      expect(chat.reading.messages.length, 620);
      expect(
        chat.reading.messages.map((r) => r['id']).toList(),
        List.generate(620, (i) => i + 1),
      );
      expect(
        host.calls
            .lastWhere((call) => call.$2 == 'session.resume')
            .$3['display_projection'],
        true,
      );
      final reads = host.reads.where((r) => r.$1.endsWith('/messages'));
      expect(reads, isNotEmpty);
      expect(
        reads.every(
          (r) =>
              r.$2['profile'] == 'personal' &&
              r.$2['include_compacted'] == 'true',
        ),
        isTrue,
      );
    },
  );

  test(
    'overlapping pages after new persisted rows deduplicate and advance',
    () async {
      final chat = await open();
      host.messageCount += 5;
      await controller.loadOlderMessages(chat);
      expect(chat.reading.messages.length, 95);
      expect(chat.reading.nextHistoryOffset, 100);
      await controller.loadOlderMessages(chat);
      expect(chat.reading.messages.length, 145);
      expect(chat.reading.messages.map((r) => r['id']).toSet().length, 145);
    },
  );

  test(
    'tail refresh preserves older pages and replaces optimistic rows',
    () async {
      final chat = await open();
      await controller.loadOlderMessages(chat);
      chat.reading.installSavedHistory([
        ...chat.reading.messages,
        {'role': 'user', 'content': 'optimistic'},
      ]);
      host.messageCount += 2;
      await controller.refreshHistory(chat);
      expect(chat.reading.messages.first['id'], 521);
      expect(chat.reading.messages.last['id'], 622);
      expect(chat.reading.messages.length, 102);
      expect(chat.reading.nextHistoryOffset, 102);
    },
  );

  test('failed page preserves history and retries its offset', () async {
    final chat = await open();
    host.failHistory = true;
    await controller.loadOlderMessages(chat);
    expect(chat.reading.messages.length, 50);
    expect(chat.reading.nextHistoryOffset, 50);
    expect(chat.reading.historyError, isNotNull);
    host.failHistory = false;
    await controller.loadOlderMessages(chat);
    expect(chat.reading.messages.length, 100);
    expect(chat.reading.historyError, isNull);
  });

  test('refresh invalidates an older page in flight', () async {
    final chat = await open();
    final delay = host.historyDelays[('chat-0', 50)] = Completer<void>();
    final pending = controller.loadOlderMessages(chat);
    await controller.loadOlderMessages(chat);
    await controller.refreshHistory(chat);
    delay.complete();
    await pending;
    expect(chat.reading.messages.length, 50);
    expect(chat.reading.nextHistoryOffset, 50);
  });

  test('A B A and chat navigation discard old history responses', () async {
    final chat = await open();
    final delay = host.historyDelays[('chat-0', 50)] = Completer<void>();
    final pending = controller.loadOlderMessages(chat);
    await controller.navigateProfile('work');
    final other = await open();
    expect(other.reading.messages.last['content'], 'work message 620');
    await controller.navigateProfile('personal');
    await open();
    delay.complete();
    await pending;
    expect(chat.reading.messages.length, 50);
    expect(chat.reading.historyLoading, isFalse);
  });

  test(
    'browser search finds unloaded archived content across discovered profiles',
    () async {
      await browser.search('needle');
      expect(
        controller.current!.sessions.any((r) => r['id'] == 'beyond-list'),
        isFalse,
      );
      final matches = browser.project('needle').entries;
      expect(matches, hasLength(2));
      expect(browser.state.searchError, isNull);
      expect(matches.every((entry) => entry.archived), isTrue);
      expect(
        matches.map((entry) => entry.profile),
        containsAll(['personal', 'work']),
      );
      for (final profile in ['personal', 'work']) {
        expect(browser.state.profiles[profile]!.searchMatches, {'beyond-list'});
        expect(
          host.reads
              .where(
                (read) =>
                    read.$1 == 'sessions/beyond-list' &&
                    read.$2['profile'] == profile,
              )
              .single
              .$2,
          {'profile': profile},
        );
        expect(
          host.reads
              .where(
                (read) =>
                    read.$1 == 'sessions/search' &&
                    read.$2['profile'] == profile,
              )
              .single
              .$2,
          {'q': 'needle', 'limit': '100', 'profile': profile},
        );
      }
      final target = matches.singleWhere(
        (entry) => entry.profile == 'personal',
      );
      expect(target.title, 'personal archive match');
      await browser.open(target);
      expect(controller.current!.chat!.key, target.sessionKey);
    },
  );

  test('an older query cannot replace newer search results', () async {
    final delay = host.searchDelays['old'] = Completer<void>();
    final pending = browser.search('old');
    await browser.search('new');
    delay.complete();
    await pending;
    expect(browser.project('new').entries, hasLength(2));
    expect(
      browser
          .project('new')
          .entries
          .every((entry) => entry.snippet!.contains('new')),
      isTrue,
    );
  });

  test('profile navigation retains browser search ownership', () async {
    final second = host.searchDelays['away'] = Completer<void>();
    final away = browser.search('away');
    await controller.navigateProfile('work');
    await controller.navigateProfile('personal');
    second.complete();
    await away;
    expect(
      browser.project('away').entries.map((entry) => entry.profile),
      containsAll(['personal', 'work']),
    );
  });

  test('clearing search fences its pending result', () async {
    final third = host.searchDelays['cleared'] = Completer<void>();
    final cleared = browser.search('cleared');
    await browser.search('');
    third.complete();
    await cleared;
    expect(browser.state.searching, isFalse);
    expect(
      browser.state.profiles.values.every(
        (profile) => profile.searchMatches.isEmpty,
      ),
      isTrue,
    );
    expect(
      browser.project('').entries.any((entry) => entry.id == 'beyond-list'),
      isFalse,
    );
  });

  test('search failure is not an empty result and retry works', () async {
    host.failSearch = true;
    await browser.search('needle');
    expect(browser.state.searchError, isNotNull);
    expect(
      browser.state.profiles.values.every(
        (profile) => profile.searchMatches.isEmpty,
      ),
      isTrue,
    );
    host.failSearch = false;
    await browser.search('needle');
    expect(browser.state.searchError, isNull);
    expect(browser.project('needle').entries, hasLength(2));
  });

  testWidgets(
    'latest opens at bottom; older pages and stream updates keep a visible row anchored',
    (tester) async {
      disableAnimations = true;
      // Keep the running viewport stable while measuring stream growth and
      // resume; an idle-to-running chrome change is a different transition.
      runningAssistant = '';
      final chat = await open();
      expect(chat.runtime.blocksTurnAdmission, isTrue);
      await show(tester);
      expect(find.text('personal message 620'), findsOneWidget);
      final list = find.byKey(const ValueKey('profile-transcript'));
      await tester.drag(list, const Offset(0, 360));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      final viewport = tester.getRect(list);
      final visible =
          find
                  .byType(SelectableText)
                  .evaluate()
                  .where((e) {
                    final top = tester.getTopLeft(find.byWidget(e.widget)).dy;
                    return top > viewport.top + viewport.height * .25 &&
                        top < viewport.top + viewport.height * .75;
                  })
                  .first
                  .widget
              as SelectableText;
      final text = visible.data ?? visible.textSpan!.toPlainText();
      final before = tester.getTopLeft(find.text(text)).dy;
      await controller.loadOlderMessages(chat);
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text(text)).dy, closeTo(before, 1));
      emitChatEvent(controller, chat, 'message.delta', {
        'text': List.filled(12, 'Streaming line\n').join(),
      });
      runningAssistant = chat.reading.streaming;
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text(text)).dy, closeTo(before, 2));
      final position = chat.reading.readingPosition.resume;
      final ongoingSource = chat.reading.streaming;
      expect(chat.runtime.blocksTurnAdmission, isTrue);
      controller.showList();
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      await open();
      expect(chat.runtime.blocksTurnAdmission, isTrue);
      expect(chat.reading.streaming, ongoingSource);
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      expect(
        chat.reading.readingPosition.resume?.messageId,
        position?.messageId,
      );
      final restoredTop = tester.getTopLeft(find.text(text)).dy;
      emitChatEvent(controller, chat, 'message.delta', {
        'text': List.filled(12, 'More streaming line\n').join(),
      });
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text(text)).dy, closeTo(restoredTop, 2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a sparse long answer restores its offset after initial empty Markdown',
    (tester) async {
      final chat = await open();
      chat.reading.installSavedHistory([
        {
          'id': 620,
          'role': 'assistant',
          'content': List.generate(
            80,
            (index) =>
                'Paragraph $index has **formatted text** and more words.',
          ).join('\n\n'),
        },
      ]);
      await show(tester);
      final scroll = find
          .descendant(
            of: find.byKey(const ValueKey('profile-transcript')),
            matching: find.byType(Scrollable),
          )
          .first;
      tester.state<ScrollableState>(scroll).position.jumpTo(1000);
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      final saved = chat.reading.readingPosition.resume;
      expect(saved!.messageId, 620);
      expect(saved.fraction, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
          ),
        ),
      );
      // Temporary empty message bodies must not overwrite the saved target.
      expect(chat.reading.readingPosition.resume?.messageId, saved.messageId);
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      expect(
        chat.reading.readingPosition.resume?.fraction,
        closeTo(saved.fraction, .001),
      );
      expect(chat.reading.readingPosition.resume?.messageId, saved.messageId);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'search debounce discards stale work and displays archived snippets',
    (tester) async {
      await show(tester);
      await tester.enterText(find.byType(TextField), 'old');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      expect(
        host.reads
            .where((r) => r.$1 == 'sessions/search')
            .map((r) => r.$2['q']),
        ['needle', 'needle'],
      );
      expect(find.text('personal archive match'), findsOneWidget);
      expect(find.textContaining('Archived · needle'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('chat-filter-profile')));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-menu-work')));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close filters'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      await tester.pumpAndSettle();
      expect(find.text('personal archive match'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
