import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/chat_working_border.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    bool reduced = false,
    bool working = true,
    VoidCallback? onTap,
    VoidCallback? onAction,
    VoidCallback? onLongPress,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: ChatWorkingBorder(
              working: working,
              child: ListTile(
                title: const Text('Working chat'),
                onTap: onTap,
                onLongPress: onLongPress,
                trailing: IconButton(
                  tooltip: 'Chat actions',
                  icon: const Icon(Icons.more_horiz),
                  onPressed: onAction,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final reduced in [false, true]) {
    for (final gesture in ['tap', 'action', 'long press']) {
      testWidgets(
        'working border passes $gesture with reduced motion $reduced',
        (tester) async {
          var taps = 0;
          var actions = 0;
          var longPresses = 0;
          await show(
            tester,
            reduced: reduced,
            onTap: () => taps++,
            onAction: () => actions++,
            onLongPress: () => longPresses++,
          );
          switch (gesture) {
            case 'tap':
              await tester.tap(find.text('Working chat'));
            case 'action':
              await tester.tap(find.byTooltip('Chat actions'));
            case 'long press':
              await tester.longPress(find.text('Working chat'));
          }
          expect(taps, gesture == 'tap' ? 1 : 0);
          expect(actions, gesture == 'action' ? 1 : 0);
          expect(longPresses, gesture == 'long press' ? 1 : 0);
        },
      );
    }
  }

  testWidgets('reduced motion stops ticks without moving the chat row', (
    tester,
  ) async {
    await show(tester);
    final bounds = tester.getRect(find.byType(ListTile));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await show(tester, reduced: true);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.getRect(find.byType(ListTile)), bounds);
    await show(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('settled work stops ticks without moving the chat row', (
    tester,
  ) async {
    await show(tester);
    final bounds = tester.getRect(find.byType(ListTile));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await show(tester, working: false);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.getRect(find.byType(ListTile)), bounds);
  });

  testWidgets('removing a working row retires its animation', (tester) async {
    await show(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
