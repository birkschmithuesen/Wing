import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/bots/bot_group_history_screen.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/services/bot_group_history_session.dart';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bots_preferences.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/conversation_page.dart';
import 'package:wing/core/widgets/conversation_composer.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';

import 'helpers/pump_markdown_widget.dart';
import 'phone_reading_test.dart' as normal;
import 'support/bots_fixture.dart';

const _capture = bool.fromEnvironment('CAPTURE_CONVERSATION_ASSEMBLY');

Future<void> _render(WidgetTester tester, String name) async {
  expect(find.byType(ConversationPage), findsOneWidget);
  expect(find.byType(ConversationLayout), findsOneWidget);
  expect(
    find.byType(ConversationComposer, skipOffstage: false),
    name.startsWith('worker-') ? findsNothing : findsOneWidget,
  );
  final attachment = find.byTooltip(
    name.startsWith('group-') ? 'Add group attachment' : 'Attach file',
  );
  if (attachment.evaluate().isNotEmpty) {
    final surface = tester.getRect(
      find.byKey(const ValueKey('conversation-composer')),
    );
    final glyph = find.descendant(
      of: attachment,
      matching: find.byIcon(Icons.add),
    );
    expect(
      tester.getCenter(glyph).dx,
      closeTo(surface.left + 8 + 24, .01),
      reason: 'Every composer anchors its attachment glyph at the leading edge',
    );
    expect(tester.getSize(attachment).width, 48);
    expect(attachment.hitTestable(), findsOneWidget);
  }
  if (!_capture) return;
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/design-previews/conversation-assembly/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      WingTypography.sans: 'Roboto-Regular.ttf',
      'monospace': 'RobotoMono-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$directory/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  normal.main(capture: _render);

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final worker in [false, true]) {
        testWidgets(
          '${worker ? 'worker' : 'group'} shares conversation reading and layout ${brightness.name} $scale',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            final preferences = await BotsPreferences.load();
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final fixture = BotsFixture();
            final group = (await readFixtureGroups(
              fixture.repository,
              groupMessages: null,
            )).single;
            fixture.events.add({
              'room_id': group.id,
              'seq': 1,
              'kind': 'message.member',
              'actor': {'kind': 'member', 'id': 'atlas', 'profile': 'atlas'},
              'payload': {'text': normal.phoneReadingTable},
              'created_at': 1791756000.0,
            });
            fixture.workerRows['atlas'] = [
              {
                'id': 'atlas-root',
                'resolved_id': 'atlas-tip',
                'title': 'Group: room-1',
                'source': 'bot_room',
              },
            ];
            fixture.workerMessages['atlas'] = [
              {
                'id': 1,
                'role': 'assistant',
                'content': normal.phoneReadingTable,
              },
            ];
            await tester.pumpMarkdownWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: worker
                    ? BotGroupHistoryScreen(
                        appearanceForMember: (_) => null,
                        createSession: () =>
                            BotGroupHistorySession(fixture.repository, group),
                      )
                    : BotGroupScreen(
                        voiceInputSettings: () => null,
                        stopVoicePlayback: () async {},
                        createSession: () => BotGroupSession(
                          fixture.repository,
                          group,
                          reads: BotGroupReadState(),
                          preferences: preferences,
                          groupMessages: null,
                          appearances: FixedGroupAppearances(const []),
                        ),
                      ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.settleMarkdown();
            await tester.pumpAndSettle();
            final field = find.byKey(const ValueKey('group-message-composer'));
            TextEditingController? draft;
            if (!worker) {
              await tester.enterText(field, 'Keep this group draft');
              draft = tester.widget<TextField>(field).controller!;
              tester.widget<TextField>(field).focusNode!.unfocus();
              await tester.pumpAndSettle();
            }
            final headerHeight = tester
                .widget<WingAppBar>(find.byType(WingAppBar))
                .preferredSize
                .height;
            final enter = find.byTooltip('Enter reading mode');
            expect(enter, findsOneWidget);
            await tester.ensureVisible(enter);
            await tester.pumpAndSettle();
            final name =
                '${worker ? 'worker' : 'group'}-${brightness.name}-$scale';
            await _render(tester, '$name-portrait');
            if (!worker) {
              await tester.tap(field);
              tester.view.viewInsets = const FakeViewPadding(bottom: 260);
              await tester.pumpAndSettle();
              await _render(tester, '$name-portrait-keyboard');
              expect(
                find.byTooltip('Send group message').hitTestable(),
                findsOneWidget,
              );
              tester.view.viewInsets = const FakeViewPadding();
              tester.widget<TextField>(field).focusNode!.unfocus();
              await tester.pumpAndSettle();
            }
            await tester.tap(enter);
            await tester.pumpAndSettle();
            expect(find.byTooltip('Exit reading mode'), findsOneWidget);
            expect(field, findsNothing);
            if (worker) expect(find.byType(ChoiceChip), findsNothing);
            expect(
              tester
                  .widget<WingAppBar>(find.byType(WingAppBar))
                  .preferredSize
                  .height,
              lessThan(headerHeight),
            );
            await _render(tester, '$name-reading');
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(find.byTooltip('Enter reading mode'), findsOneWidget);
            if (worker) {
              expect(
                find.byType(ChoiceChip),
                findsNWidgets(group.members.length),
              );
              expect(find.byType(TextField), findsNothing);
            } else {
              expect(tester.widget<TextField>(field).controller, same(draft));
              expect(draft!.text, 'Keep this group draft');
              tester.view.physicalSize = const Size(844, 390);
              await tester.pumpAndSettle();
              expect(tester.widget<TextField>(field).maxLines, 1);
              expect(
                find.byTooltip('Expand composer controls'),
                findsOneWidget,
              );
              await tester.tap(find.byTooltip('Expand composer controls'));
              await tester.pumpAndSettle();
              await _render(tester, '$name-landscape-expanded');
              await tester.tap(find.byTooltip('Collapse composer controls'));
              await tester.pumpAndSettle();
              await tester.tap(field);
              tester.view.viewInsets = const FakeViewPadding(bottom: 240);
              await tester.pumpAndSettle();
              final send = find.byTooltip('Send group message');
              expect(send.hitTestable(), findsOneWidget);
              expect(tester.getBottomLeft(send).dy, lessThanOrEqualTo(150));
              await _render(tester, '$name-keyboard');
              expect(draft.text, 'Keep this group draft');
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }
}
