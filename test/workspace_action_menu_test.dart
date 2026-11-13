import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/workspace_action_menu.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final removeBeforeLayout in [true, false]) {
      testWidgets(
        'chat menu survives row removal ${removeBeforeLayout ? 'during opening' : 'before resizing'} ($brightness)',
        (tester) async {
          final visible = ValueNotifier(true);
          addTearDown(visible.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              home: Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: visible,
                  builder: (context, showRow, _) => showRow
                      ? Builder(
                          builder: (anchor) => IconButton(
                            tooltip: 'Chat actions',
                            icon: const Icon(Icons.more_horiz),
                            onPressed: () => unawaited(
                              showWorkspaceActionMenu(
                                anchor,
                                'Test chat',
                                'personal',
                                [
                                  (
                                    'copy',
                                    'Copy ID',
                                    Icons.copy_outlined,
                                    true,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          );

          await tester.tap(find.byTooltip('Chat actions'));
          if (!removeBeforeLayout) await tester.pumpAndSettle();
          // A live list refresh can remove the invoking row in the same frame in
          // which the popup first measures its position.
          visible.value = false;
          if (!removeBeforeLayout) {
            await tester.binding.setSurfaceSize(const Size(320, 580));
            addTearDown(() => tester.binding.setSurfaceSize(null));
          }
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.byType(ErrorWidget), findsNothing);
          expect(find.text('Copy ID'), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.text('Copy ID'), findsNothing);
        },
      );
    }
  }
}
