import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/adaptive_markdown_table.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';

import 'helpers/pump_markdown_widget.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';
import 'support/composer_fixture.dart';

const phoneReadingTable = '''
## My first proposed changes

| Current UI | Proposed change |
| --- | --- |
| Today says **All normal. A regular training day fits.** Other rules recommend going hard. | Show factual context and the plan we actually agreed, rather than an independent training recommendation. |
| A prominent **Recovery score** combines HRV and resting HR percentiles. | Show the underlying signals separately. Remove the composite from the primary view. |
| Weigh in three times a week to unlock a goal date. | Explain why a projection is unavailable without making it an unlock mechanic. |
''';

class _ReadingFixture extends ProfileActionsFixture {
  String content = phoneReadingTable;

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {'id': 1, 'role': 'assistant', 'content': content},
  ];
}

void main({
  Future<void> Function(WidgetTester, String)? capture,
  Future<void> Function(WidgetTester, bool)? rotate,
}) {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'phone reading preserves chat and draft ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          final fixture = _ReadingFixture();
          final runtimes = WorkspaceRuntimeFixture();
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'phone-reading',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: fixture.gateway,
            runtimeFactory: runtimes.create,
          );
          addTearDown(controller.dispose);
          addTearDown(appPreferences.dispose);
          await controller.initialize();
          final chat = await controller.createChat(canDispatch: () => true);
          await controller.refreshHistory(chat);
          await controller.updateDraft(chat, 'Keep this unsent draft.');
          if (rotate == null) {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
          } else {
            await rotate(tester, false);
          }
          await tester.pumpMarkdownWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => []),
              ),
            ),
          );
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.settleMarkdown();
          final table = find.byType(AdaptiveMarkdownTable);
          expect(table, findsOneWidget);
          expect(
            find.descendant(of: table, matching: find.byType(Table)),
            findsOneWidget,
          );
          final tableState = tester.state(table);
          final field = find.byKey(const Key('profile-message-composer'));
          final draft = tester.widget<TextField>(field).controller!;
          final portraitHeader = tester
              .widget<WingAppBar>(find.byType(WingAppBar))
              .preferredSize
              .height;
          final enter = find.byTooltip('Enter reading mode');
          await tester.ensureVisible(enter);
          await tester.pump();
          expect(enter, findsOneWidget);
          expect(
            find.descendant(of: find.byType(WingAppBar), matching: enter),
            findsNothing,
          );
          await capture?.call(tester, 'phone-table-${brightness.name}-$scale');
          await tester.ensureVisible(find.byTooltip('Read as table'));
          await tester.pump();
          await tester.tap(find.byTooltip('Read as table'));
          await tester.pump();
          expect(
            find.descendant(of: table, matching: find.byType(Table)),
            findsOneWidget,
          );
          fixture.content = phoneReadingTable.replaceFirst(
            'Today says',
            'Today said',
          );
          await controller.refreshHistory(chat);
          await tester.pump();
          await tester.settleMarkdown();
          expect(tester.state(table), same(tableState));
          expect(
            find.descendant(of: table, matching: find.byType(Table)),
            findsOneWidget,
          );
          await capture?.call(
            tester,
            'phone-table-updated-${brightness.name}-$scale',
          );
          await tester.ensureVisible(find.byTooltip('Read as stacked rows'));
          await tester.pump();
          await tester.tap(find.byTooltip('Read as stacked rows'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(enter);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(enter);
          await tester.pump();
          expect(field, findsNothing);
          expect(
            tester
                .widget<WingAppBar>(find.byType(WingAppBar))
                .preferredSize
                .height,
            lessThan(portraitHeader),
          );
          expect(find.byTooltip('Exit reading mode'), findsOneWidget);
          expect(tester.state(table), same(tableState));
          expect(controller.current!.chat, same(chat));
          await capture?.call(
            tester,
            'phone-reading-${brightness.name}-$scale',
          );

          if (rotate == null) {
            tester.view.physicalSize = const Size(844, 390);
          } else {
            await rotate(tester, true);
          }
          await tester.pump();
          await tester.settleMarkdown();
          await tester.pump();
          await tester.pumpAndSettle();
          expect(find.byTooltip('Exit reading mode'), findsOneWidget);
          expect(
            find.descendant(of: table, matching: find.byType(Table)),
            findsNothing,
            reason: 'Rotation must retain the most recent explicit choice.',
          );
          await capture?.call(
            tester,
            'phone-reading-landscape-${brightness.name}-$scale',
          );
          await tester.ensureVisible(find.byTooltip('Exit reading mode'));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Exit reading mode'));
          await tester.pump();
          expect(tester.widget<TextField>(field).controller, same(draft));
          expect(draft.text, 'Keep this unsent draft.');
          await tester.pumpAndSettle();
          expect(find.byType(ComposerActionButton), findsOneWidget);
          expect(find.byTooltip('Attach file'), findsNothing);
          expect(
            tester
                .widget<WingAppBar>(find.byType(WingAppBar))
                .preferredSize
                .height,
            lessThan(portraitHeader),
          );
          await capture?.call(
            tester,
            'phone-compact-${brightness.name}-$scale',
          );
          await tester.tap(find.byTooltip('Expand composer controls'));
          await tester.pump();
          expect(find.byTooltip('Attach file'), findsOneWidget);
          await tester.tap(find.byTooltip('Collapse composer controls'));
          await tester.pump();
          await tester.tap(field);
          await tester.pump();
          if (rotate == null) {
            expect(find.byTooltip('Attach file'), findsOneWidget);
            tester.view.viewInsets = const FakeViewPadding(bottom: 240);
          }
          if (rotate != null) {
            for (var i = 0; i < 50 && tester.view.viewInsets.bottom == 0; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(tester.view.viewInsets.bottom, greaterThan(0));
          }
          await tester.pumpAndSettle();
          expect(find.byTooltip('Attach file'), findsNothing);
          final send = find.byType(ComposerActionButton);
          expect(send.hitTestable(), findsOneWidget);
          final usableBottom =
              (tester.view.physicalSize.height -
                  tester.view.viewInsets.bottom) /
              tester.view.devicePixelRatio;
          expect(
            tester.getBottomLeft(send).dy,
            lessThanOrEqualTo(usableBottom),
          );
          expect(tester.getTopLeft(field).dy, greaterThanOrEqualTo(0));
          await capture?.call(
            tester,
            'phone-composing-${brightness.name}-$scale',
          );
          await tester.tap(find.byTooltip('Expand composer controls'));
          await tester.pump();
          if (rotate == null) tester.view.resetViewInsets();
          if (rotate != null) {
            for (var i = 0; i < 50 && tester.view.viewInsets.bottom > 0; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(tester.view.viewInsets.bottom, 0);
          }
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(find.byTooltip('Attach file'), findsOneWidget);
          await tester.tap(find.byTooltip('Collapse composer controls'));
          await tester.pumpAndSettle();
          if (find.byTooltip('Enter reading mode').evaluate().isEmpty) {
            await tester.tap(find.byTooltip('Latest'));
            await tester.pumpAndSettle();
            await tester.settleMarkdown();
          }
          await tester.ensureVisible(find.byTooltip('Enter reading mode'));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Enter reading mode'));
          await tester.pump();
          await tester.binding.handlePopRoute();
          await tester.pump();
          expect(field, findsOneWidget);
          expect(controller.current!.chat, same(chat));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
