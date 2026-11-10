import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'support/profile_paging_fixture.dart';

void main() {
  late ProfilePagingFixture fixture;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = ProfilePagingFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Paging QA',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'paging',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });
  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
  }

  testWidgets('all pages load in bounded requests and pins remain unique', (
    tester,
  ) async {
    await show(tester);
    await tester.pumpAndSettle();
    final reads = fixture.reads
        .where((r) => r.$1 == 'sessions' && r.$2['limit'] == '100')
        .toList();
    final browserReads = reads.where((r) => r.$2['archived'] != 'include');
    final recentsReads = reads.where((r) => r.$2['archived'] == 'include');
    expect(browserReads, hasLength(4));
    expect(browserReads.where((r) => r.$2['offset'] == '100'), hasLength(2));
    expect(recentsReads, hasLength(4));
    expect(recentsReads.where((r) => r.$2['offset'] == '100'), hasLength(2));
    expect(
      find.byKey(const ValueKey('chat-personal-chat-120')),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(find.text('Show more'), findsWidgets);
  });
  testWidgets('page failure preserves rows and has an explicit retry', (
    tester,
  ) async {
    fixture.pageFailures.add(('personal', 100));
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('Could not finish loading personal.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-personal-chat-120')),
      findsOneWidget,
    );
    fixture.pageFailures.clear();
    await tester.tap(find.text('Retry').first);
    await tester.pumpAndSettle();
    expect(find.text('Could not finish loading personal.'), findsNothing);
  });
  testWidgets('Show more adds ten per tap until the group is exhausted', (
    tester,
  ) async {
    fixture.count = 28;
    await show(tester);
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('chat-list-false'));
    final more = find.byKey(
      const ValueKey('chat-show-more-project/personal/shared-project'),
    );
    Future<void> reachMore() async {
      await tester.scrollUntilVisible(
        more,
        300,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(more), alignment: 1);
      await tester.pumpAndSettle();
    }

    final reads = fixture.reads.length;
    await reachMore();
    expect(find.text('personal chat 2'), findsOneWidget);
    expect(find.text('personal chat 4'), findsNothing);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await reachMore();
    expect(find.text('personal chat 13'), findsOneWidget);
    expect(find.text('personal chat 14'), findsNothing);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await reachMore();
    expect(find.text('personal chat 23'), findsOneWidget);
    expect(find.text('personal chat 24'), findsNothing);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('personal chat 27'),
      200,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();
    expect(find.text('personal chat 27'), findsOneWidget);
    expect(more, findsNothing);
    expect(fixture.reads.length, reads);
  });
  testWidgets(
    'search finds older chats across profiles without an archive scan',
    (tester) async {
      await show(tester);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'chat 110');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('personal chat 110'), findsOneWidget);
      expect(find.text('work chat 110'), findsOneWidget);
      expect(
        fixture.reads.where(
          (r) => r.$1 == 'sessions' && r.$2['archived'] == 'only',
        ),
        isEmpty,
      );
    },
  );
}
