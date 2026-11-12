import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

/// Deletion waits for ordered cache writes, which can encode on a real isolate.
/// Widget pumps alone cannot finish those writes inside the fake-async zone.
Future<void> waitForChatDeletionCleanup(
  WidgetTester tester,
  ProfileWorkspaceController controller,
  ProfileSessionKey key,
) async {
  final resource = controller.current!;
  expect(resource.scope, key.workspace);
  bool pending() => resource.mutatingSessions.contains(key.sessionId);
  for (var attempt = 0; attempt < 100 && pending(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    // Real I/O completes outside fake async; its continuations need a pump.
    await tester.pump();
  }
  expect(pending(), isFalse, reason: 'Confirmed deletion cleanup must finish');
  await tester.pumpAndSettle();
}

Future<void> filterChatsToProfile(WidgetTester tester, String name) async {
  final filter = find.byKey(const ValueKey('chat-filter-profile'));
  expect(
    filter,
    findsOneWidget,
    reason: 'The requested profile filter must exist',
  );
  await tester.ensureVisible(filter);
  expect(filter.hitTestable(), findsOneWidget);
  await tester.tap(filter);
  await tester.pumpAndSettle();
  final choice = find.byKey(ValueKey('chat-menu-$name'));
  expect(choice.hitTestable(), findsOneWidget);
  await tester.tap(choice);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Close filters'));
  await tester.pumpAndSettle();
}

Future<void> revealChatProject(
  WidgetTester tester,
  String profile,
  String id,
) async {
  final row = find.byKey(ValueKey('project-$profile-$id'));
  await tester.scrollUntilVisible(
    row,
    220,
    scrollable: find
        .descendant(
          of: find.byWidgetPredicate(
            (w) => w is ListView && w.scrollDirection == Axis.vertical,
          ),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await Scrollable.ensureVisible(tester.element(row), alignment: 0.4);
  await tester.pumpAndSettle();
}
