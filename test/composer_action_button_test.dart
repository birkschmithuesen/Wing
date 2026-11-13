import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/widgets/composer_action_button.dart';

void main() {
  late List<ComposerAction> selected;
  setUp(() => selected = []);

  Future<void> show(
    WidgetTester tester, {
    ComposerAction? primary = ComposerAction.steer,
    ComposerAction? resting = ComposerAction.send,
    String? steerReason,
    double scale = 1,
    bool reduceMotion = false,
  }) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: ComposerActionButton(
              primary: primary,
              resting: primary == null ? null : resting,
              unavailable: {
                ComposerAction.steer: steerReason,
                ComposerAction.stop: null,
                ComposerAction.queue: null,
              },
              onSelected: selected.add,
            ),
          ),
        ),
      ),
    );
  }

  Future<TestGesture> hold(
    WidgetTester tester, {
    String primary = 'Steer',
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip(primary)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.byKey(const ValueKey('composer-action-selector')),
      findsOneWidget,
    );
    expect(selected, isEmpty);
    return gesture;
  }

  testWidgets('no configured primary requires a named choice before dispatch', (
    tester,
  ) async {
    await show(tester, primary: null);
    await tester.tap(find.byTooltip('Choose chat action'));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(
      find.byKey(const ValueKey('composer-keyboard-stop')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('composer-keyboard-stop')));
    await tester.pumpAndSettle();
    expect(selected, [ComposerAction.stop]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap uses the configured primary without a popup', (
    tester,
  ) async {
    await show(tester, primary: ComposerAction.queue);
    await tester.tap(find.byTooltip('Queue'));
    expect(selected, [ComposerAction.queue]);
    expect(
      find.byKey(const ValueKey('composer-action-selector')),
      findsNothing,
    );
  });

  for (final reduced in [false, true]) {
    testWidgets('Stop and typing transitions, reduced motion: $reduced', (
      tester,
    ) async {
      await show(tester, reduceMotion: reduced);
      await show(
        tester,
        primary: ComposerAction.stop,
        resting: ComposerAction.stop,
        reduceMotion: reduced,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(
        find.byKey(const ValueKey('composer-button-icon-stop')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('composer-button-icon-send')),
        reduced ? findsNothing : findsOneWidget,
      );
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Stop')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey('composer-action-selector')),
        findsNothing,
      );
      await gesture.cancel();
      await show(tester, reduceMotion: reduced);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(
        find.byKey(const ValueKey('composer-button-icon-send')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('composer-button-icon-stop')),
        reduced ? findsNothing : findsOneWidget,
      );
      await tester.pumpAndSettle();
      final typingGesture = await hold(tester);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('composer-choice-steer')))
            .dy,
        greaterThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('composer-choice-stop')))
              .dy,
        ),
      );
      await typingGesture.cancel();
      expect(selected, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'automatic Stop cancels a held choice even with the same primary',
    (tester) async {
      await show(tester, primary: ComposerAction.stop);
      final gesture = await hold(tester, primary: 'Stop');
      await show(
        tester,
        primary: ComposerAction.stop,
        resting: ComposerAction.stop,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(
        find.byKey(const ValueKey('composer-button-icon-stop')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('composer-action-selector')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'automatic Stop exposes no alternative keyboard or screen reader actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await show(
          tester,
          primary: ComposerAction.stop,
          resting: ComposerAction.stop,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('composer-keyboard-stop')),
          findsNothing,
        );
        final node = tester.getSemantics(find.byType(ComposerActionButton));
        final ids = node.getSemanticsData().customSemanticsActionIds!;
        expect(ids.map((id) => CustomSemanticsAction.getAction(id)!.label), [
          'Stop',
        ]);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(selected, [ComposerAction.stop]);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('keyboard primary activation and action menu restore focus', (
    tester,
  ) async {
    await show(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focus = tester
        .widget<Focus>(find.byKey(const ValueKey('composer-action-focus')))
        .focusNode!;
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(selected, [ComposerAction.steer, ComposerAction.steer]);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('composer-keyboard-stop')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('composer-keyboard-stop')), findsNothing);
    expect(focus.hasFocus, isTrue);
  });

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets(
      'alternative-only button is reachable with Tab and ${key.keyLabel}',
      (tester) async {
        await show(tester, steerReason: 'Type a message');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          tester
              .widget<Focus>(
                find.byKey(const ValueKey('composer-action-focus')),
              )
              .focusNode!
              .hasFocus,
          isTrue,
        );
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('composer-keyboard-stop')),
          findsOneWidget,
        );
        expect(selected, isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selected, [ComposerAction.stop]);
        expect(
          find.byKey(const ValueKey('composer-keyboard-stop')),
          findsNothing,
        );
      },
    );
  }

  for (final action in [
    ComposerAction.steer,
    ComposerAction.queue,
    ComposerAction.stop,
  ]) {
    testWidgets(
      'up arrow animates to configured ${action.name} only while held',
      (tester) async {
        await show(tester, primary: action);
        expect(
          find.byKey(const ValueKey('composer-button-icon-send')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('composer-button-icon-${action.name}')),
          findsNothing,
        );
        final gesture = await hold(tester, primary: action.label);
        await tester.pump(const Duration(milliseconds: 110));
        expect(
          find.byKey(const ValueKey('composer-button-icon-send')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('composer-button-icon-${action.name}')),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 140));
        expect(
          find.byKey(const ValueKey('composer-button-icon-send')),
          findsNothing,
        );
        expect(selected, isEmpty);
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('composer-button-icon-send')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('composer-button-icon-${action.name}')),
          findsNothing,
        );
        expect(selected, isEmpty);
      },
    );
  }

  testWidgets(
    'sliding updates the button icon and release restores the arrow',
    (tester) async {
      await show(tester);
      final gesture = await hold(tester);
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('composer-choice-queue'))),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('composer-button-icon-queue')),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected, [ComposerAction.queue]);
      expect(
        find.byKey(const ValueKey('composer-button-icon-send')),
        findsOneWidget,
      );
    },
  );

  testWidgets('reduced motion changes the held icon without animation', (
    tester,
  ) async {
    await show(tester, reduceMotion: true);
    final gesture = await hold(tester);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('composer-button-icon-steer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('composer-button-icon-send')),
      findsNothing,
    );
    await gesture.cancel();
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('composer-button-icon-send')),
      findsOneWidget,
    );
  });

  testWidgets('holding in place commits steer only on release', (tester) async {
    await show(tester);
    final gesture = await hold(tester);
    await gesture.up();
    await tester.pump();
    expect(selected, [ComposerAction.steer]);
    expect(
      find.byKey(const ValueKey('composer-action-selector')),
      findsNothing,
    );
  });

  testWidgets(
    'choices stack vertically above the button with the default nearest',
    (tester) async {
      await show(tester);
      final gesture = await hold(tester);
      final button = tester.getRect(find.byTooltip('Steer'));
      final choices = [
        for (final name in ['stop', 'queue', 'steer'])
          tester.getRect(find.byKey(ValueKey('composer-choice-$name'))),
      ];
      for (var i = 0; i < choices.length; i++) {
        expect(choices[i].center.dx, choices.first.center.dx);
        expect(choices[i].left, lessThan(button.center.dx));
        expect(choices[i].right, greaterThan(button.center.dx));
        expect(choices[i].bottom, lessThan(button.top));
        if (i > 0) {
          expect(choices[i].top, greaterThanOrEqualTo(choices[i - 1].bottom));
        }
      }
      await gesture.cancel();
      await tester.pump();
    },
  );

  for (final action in [
    ComposerAction.stop,
    ComposerAction.queue,
    ComposerAction.steer,
  ]) {
    testWidgets(
      'held slide to ${action.name} commits exactly once on release',
      (tester) async {
        await show(tester, scale: 2.4);
        final gesture = await hold(tester);
        await gesture.moveTo(
          tester.getCenter(
            find.byKey(ValueKey('composer-choice-${action.name}')),
          ),
        );
        await tester.pump();
        expect(selected, isEmpty);
        await gesture.up();
        await tester.pump();
        expect(selected, [action]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('sliding outside cancels without sending or stopping', (
    tester,
  ) async {
    await show(tester);
    final gesture = await hold(tester);
    await gesture.moveTo(const Offset(10, 10));
    await tester.pump();
    expect(find.text('Release to cancel'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(selected, isEmpty);
    expect(
      find.byKey(const ValueKey('composer-action-selector')),
      findsNothing,
    );
  });

  testWidgets('empty steer still allows holding and sliding to stop', (
    tester,
  ) async {
    await show(tester, steerReason: 'Type a message');
    await tester.tap(find.byTooltip('Steer'));
    expect(selected, isEmpty);
    final gesture = await hold(tester);
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('composer-choice-stop'))),
    );
    await gesture.up();
    expect(selected, [ComposerAction.stop]);
  });

  testWidgets('pointer cancellation discards the selection', (tester) async {
    await show(tester);
    final gesture = await hold(tester);
    await gesture.cancel();
    await tester.pump();
    expect(selected, isEmpty);
    expect(
      find.byKey(const ValueKey('composer-action-selector')),
      findsNothing,
    );
  });

  testWidgets('changed availability cancels a held selection', (tester) async {
    await show(tester);
    final gesture = await hold(tester);
    await show(tester, steerReason: 'Turn completed');
    await gesture.up();
    await tester.pump();
    expect(selected, isEmpty);
    expect(
      find.byKey(const ValueKey('composer-action-selector')),
      findsNothing,
    );
  });

  testWidgets('leaving the screen removes the selector', (tester) async {
    await show(tester);
    final gesture = await hold(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await gesture.up();
    await tester.pump();
    expect(selected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen readers can invoke alternatives without dragging', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await show(tester);
      final node = tester.getSemantics(find.byType(ComposerActionButton));
      final ids = node.getSemanticsData().customSemanticsActionIds!;
      final stopId = ids.singleWhere(
        (id) => CustomSemanticsAction.getAction(id)!.label == 'Stop',
      );
      tester.binding.rootPipelineOwner.visitChildren(
        (owner) => owner.semanticsOwner?.performAction(
          node.id,
          SemanticsAction.customAction,
          stopId,
        ),
      );
      expect(selected, [ComposerAction.stop]);
    } finally {
      semantics.dispose();
    }
  });
}
