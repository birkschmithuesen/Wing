import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_form_actions.dart';

import 'support/form_family_capture.dart';

void main() {
  setUpAll(loadFormFamilyFonts);
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final keyboard in [0.0, 260.0]) {
        testWidgets(
          'dialog frame ${brightness.name} $scale keyboard $keyboard',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final state = ValueNotifier('idle');
            addTearDown(state.dispose);
            await tester.pumpWidget(
              RepaintBoundary(
                key: formFamilyCapture,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: wingTheme(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(scale),
                      viewInsets: EdgeInsets.only(bottom: keyboard),
                    ),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Builder(
                      builder: (context) => IconButton(
                        tooltip: 'Edit example',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => ValueListenableBuilder(
                            valueListenable: state,
                            builder: (context, value, _) => StudioDialog(
                              title: const Text('Edit example'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const TextField(
                                    key: ValueKey('dialog-draft'),
                                    decoration: InputDecoration(
                                      labelText: 'Name',
                                    ),
                                  ),
                                  if (value == 'failed')
                                    const Text(
                                      'Save failed. Keep the draft and retry.',
                                    ),
                                ],
                              ),
                              actions: [
                                StudioFormActions(
                                  onCancel: () => Navigator.pop(context),
                                  onConfirm: () => state.value = 'saving',
                                  confirmLabel: 'Save example',
                                  busy: value == 'saving',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.byTooltip('Edit example'));
            await tester.pumpAndSettle();
            Rect surface() => tester.getRect(
              find
                  .descendant(
                    of: find.byType(AlertDialog),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            void check() {
              final frame = surface();
              final heading = tester.getRect(find.text('Edit example'));
              final cancel = tester.getRect(find.byTooltip('Cancel'));
              final save = tester.getRect(find.byTooltip('Save example'));
              final field = tester.getRect(
                find.byKey(const ValueKey('dialog-draft')),
              );
              expect(heading.left - frame.left, closeTo(12, .01));
              expect(frame.right - heading.right, closeTo(12, .01));
              expect(heading.top - frame.top, closeTo(12, .01));
              expect(frame.right - save.right, closeTo(12, .01));
              expect(frame.bottom - save.bottom, closeTo(12, .01));
              expect(save.left - cancel.right, closeTo(8, .01));
              expect(save.size, const Size(48, 48));
              expect(cancel.size, save.size);
              expect(field.left - frame.left, closeTo(12, .01));
              expect(frame.right - field.right, closeTo(12, .01));
              expect(save.bottom, lessThanOrEqualTo(844 - keyboard));
              expect(tester.takeException(), isNull);
            }

            check();
            await tester.enterText(
              find.byKey(const ValueKey('dialog-draft')),
              'Retained draft',
            );
            // Settle the text field's focused layout before measuring the
            // separate transition into saving.
            await tester.pumpAndSettle();
            await captureFormFamily(
              tester,
              'dialog-${brightness.name}-$scale-$keyboard-idle',
            );
            final before = tester.getRect(find.byTooltip('Save example'));
            await tester.tap(find.byTooltip('Save example'));
            await tester.pump();
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
            await tester.pump(WingMotion.buttonPress);
            await tester.pump(WingMotion.buttonRelease);
            check();
            expect(tester.getRect(find.byTooltip('Save example')), before);
            expect(
              tester
                  .widget<IconButton>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is IconButton && widget.tooltip == 'Cancel',
                    ),
                  )
                  .onPressed,
              isNull,
            );
            await captureFormFamily(
              tester,
              'dialog-${brightness.name}-$scale-$keyboard-saving',
            );
            state.value = 'failed';
            await tester.pumpAndSettle();
            check();
            expect(find.text('Retained draft'), findsOneWidget);
            await captureFormFamily(
              tester,
              'dialog-${brightness.name}-$scale-$keyboard-failed',
            );
          },
        );
      }
      testWidgets(
        'long dialog keeps actions reachable ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: StudioDialog(
                  title: const Text('Review changes'),
                  content: Text(
                    List.filled(
                      50,
                      'Keep the full consequence readable.',
                    ).join('\n'),
                  ),
                  actions: [
                    StudioFormActions(
                      onCancel: () {},
                      onConfirm: () {},
                      confirmLabel: 'Apply example',
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final action = tester.getRect(find.byTooltip('Apply example'));
          expect(action.bottom, lessThanOrEqualTo(640));
          final before = action;
          final heading = tester.getRect(find.text('Review changes'));
          await tester.drag(
            find.byType(SingleChildScrollView),
            const Offset(0, -400),
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byTooltip('Apply example')), before);
          expect(tester.getRect(find.text('Review changes')), heading);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
