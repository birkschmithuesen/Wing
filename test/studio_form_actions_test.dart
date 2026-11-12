import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_form_actions.dart';

import 'support/form_family_capture.dart';

void main() {
  setUpAll(loadFormFamilyFonts);
  for (final brightness in Brightness.values) {
    testWidgets(
      'filled confirmation keeps contrast when opened from a list row ${brightness.name}',
      (tester) async {
        final theme = wingTheme(brightness);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: ListTile(
                title: const Text('Saved chat'),
                trailing: Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Chat actions',
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => StudioDialog(
                        title: const Text('Move chat?'),
                        actions: [
                          StudioFormActions(
                            onCancel: () {},
                            onConfirm: () {},
                            confirmLabel: 'Move chat',
                            confirmIcon: Icons.drive_file_move_outlined,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Chat actions'));
        await tester.pumpAndSettle();
        final glyph = find.byIcon(Icons.drive_file_move_outlined);
        final richText = tester.widget<RichText>(
          find.descendant(of: glyph, matching: find.byType(RichText)),
        );
        expect(richText.text.style!.color, theme.colorScheme.onPrimary);
      },
    );
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'shared form preserves body and keyboard targets ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          var saves = 0;
          await tester.pumpWidget(
            RepaintBoundary(
              key: formFamilyCapture,
              child: MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: const SizedBox.expand(
                    child: SingleChildScrollView(
                      child: TextField(key: ValueKey('draft')),
                    ),
                  ),
                  bottomNavigationBar: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: StudioFormActions(
                        onCancel: () {},
                        onConfirm: () => saves++,
                        confirmLabel: 'Save example draft',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final cancel = find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == 'Cancel',
          );
          final confirm = find.byWidgetPredicate(
            (widget) =>
                widget is IconButton && widget.tooltip == 'Save example draft',
          );
          for (final action in [cancel, confirm]) {
            expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
            expect(action.hitTestable(), findsOneWidget);
          }
          expect(
            tester.getRect(cancel).right,
            lessThan(tester.getRect(confirm).left),
          );
          expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(844));
          expect(
            find.byKey(const ValueKey('draft')).hitTestable(),
            findsOneWidget,
          );
          await tester.enterText(
            find.byKey(const ValueKey('draft')),
            'Keep my draft',
          );
          expect(find.text('Keep my draft'), findsOneWidget);
          expect(find.text('Cancel'), findsNothing);
          expect(find.text('Save example draft'), findsNothing);
          await tester.tap(find.byKey(const ValueKey('draft')));
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          await captureFormFamily(
            tester,
            'shared-${brightness.name}-$scale-focus',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(saves, 1);
          expect(find.text('Keep my draft'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'short form sheet fits its content and pins actions above keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => StudioFormSheet(
                    actions: StudioFormActions(
                      onCancel: () => Navigator.pop(context),
                      onConfirm: () {},
                      confirmLabel: 'Apply draft',
                    ),
                    children: const [Text('Short draft'), TextField()],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(StudioFormSheet)).height,
        lessThan(400),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      final apply = find.byTooltip('Apply draft');
      expect(apply.hitTestable(), findsOneWidget);
      expect(tester.getRect(apply).bottom, lessThanOrEqualTo(584));
      expect(tester.takeException(), isNull);
    },
  );
}
