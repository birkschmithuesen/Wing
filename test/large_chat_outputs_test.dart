import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/chat_find_sheet.dart';
import 'helpers/pump_markdown_widget.dart';

import 'support/profile_history_fixture.dart';

class _LargeChat extends ProfileHistoryFixture {
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    for (var i = 1; i <= 10000; i++)
      {
        'id': i,
        'role': 'assistant',
        'content': i == 10000
            ? 'Saved /srv/latest.pdf'
            : i == 9500
            ? 'Saved /srv/earlier.pdf'
            : i == 1
            ? 'Saved /srv/oldest.pdf'
            : 'Message $i',
      },
  ];
}

void main() {
  testWidgets('Find opens a large chat without loading its entire transcript', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final host = _LargeChat();
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
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
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();
    host.reads.clear();
    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find in chat'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('This chat is too large to load here'),
      findsNothing,
    );
    await tester.enterText(
      find.descendant(
        of: find.byType(ChatFindSheet),
        matching: find.byType(TextField),
      ),
      'Saved /srv/latest.pdf',
    );
    await tester.pump();
    expect(
      find.widgetWithText(ExpansionTile, 'Saved /srv/latest.pdf'),
      findsOneWidget,
    );
    expect(find.byTooltip('Search older messages'), findsOneWidget);
    final reads = host.reads
        .where((read) => read.$1.endsWith('/messages'))
        .toList();
    expect(reads, hasLength(1));
    expect(reads.single.$2, {
      'profile': 'personal',
      'limit': '500',
      'offset': '0',
      'order': 'latest',
      'include_compacted': 'true',
      'inline_images': 'true',
    });

    await tester.enterText(
      find.descendant(
        of: find.byType(ChatFindSheet),
        matching: find.byType(TextField),
      ),
      'Saved /srv/earlier.pdf',
    );
    await tester.tap(find.byTooltip('Search older messages'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(ExpansionTile, 'Saved /srv/earlier.pdf'),
      findsOneWidget,
    );
    await tester.tap(
      find.widgetWithText(ExpansionTile, 'Saved /srv/earlier.pdf'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('View in chat'));
    await tester.pumpAndSettle();
    await tester.settleMarkdown();

    final chat = controller.current!.chat!;
    expect(find.text('Search result'), findsOneWidget);
    expect(find.byTooltip('Back to latest'), findsOneWidget);
    expect(find.text('Saved /srv/earlier.pdf'), findsOneWidget);
    expect(chat.reading.messages, hasLength(50));
    expect(chat.reading.messages.any((row) => row['id'] == 9500), isFalse);

    await tester.tap(find.byTooltip('Back to latest'));
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    expect(find.text('Search result'), findsNothing);
    expect(find.text('Saved /srv/latest.pdf'), findsOneWidget);
    expect(chat.reading.readingPosition.resume, isNull);

    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find in chat'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(ChatFindSheet),
        matching: find.byType(TextField),
      ),
      'Saved /srv/latest.pdf',
    );
    await tester.pump();
    await tester.tap(
      find.widgetWithText(ExpansionTile, 'Saved /srv/latest.pdf'),
    );
    await tester.pumpAndSettle();
    chat.reading.cancelReads();
    await tester.tap(find.text('View in chat'));
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    expect(find.text('Search result'), findsNothing);
  });

  testWidgets(
    'Outputs opens a large chat without loading its entire transcript',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final host = _LargeChat();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
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
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      host.reads.clear();
      await tester.tap(find.byTooltip('Chat actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Outputs'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'This chat is too large to load here. Use the paginated conversation view.',
        ),
        findsNothing,
      );
      expect(find.text('latest.pdf'), findsOneWidget);
      expect(
        host.reads.where((read) => read.$1.endsWith('/messages')),
        hasLength(1),
      );
      host.failHistory = true;
      await tester.tap(find.text('Load older outputs'));
      await tester.pumpAndSettle();
      expect(find.text('latest.pdf'), findsOneWidget);
      expect(
        find.textContaining('Your current results are still here'),
        findsOneWidget,
      );
      expect(find.text('History offline'), findsNothing);

      host.failHistory = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('earlier.pdf'), findsOneWidget);
      expect(find.text('latest.pdf'), findsOneWidget);
      final reads = host.reads
          .where((read) => read.$1.endsWith('/messages'))
          .toList();
      expect(reads.map((read) => read.$2['offset']), ['0', '500', '500']);
      expect(
        reads.every(
          (read) =>
              read.$2['profile'] == 'personal' && read.$2['limit'] == '500',
        ),
        isTrue,
      );

      for (var i = 0; i < 19; i++) {
        await tester.tap(find.text('Load older outputs'));
        await tester.pumpAndSettle();
      }
      expect(find.text('oldest.pdf'), findsOneWidget);
      expect(find.text('Load older outputs'), findsNothing);
      expect(find.text('latest.pdf'), findsOneWidget);
    },
  );
}
