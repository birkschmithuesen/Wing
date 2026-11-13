import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/journey_controls.dart';

void main() {
  testWidgets('waits for delayed content and route transition before one tap', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const SizedBox()),
    );
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    navigator.currentState!.push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(seconds: 2),
        pageBuilder: (_, _, _) => Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: ready,
            builder: (_, value, _) => value
                ? TextButton(
                    onPressed: () => taps++,
                    child: const Text('Continue'),
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      ),
    );
    await tester.pump();
    Future<void>.delayed(const Duration(seconds: 1), () => ready.value = true);
    final started = tester.binding.clock.now();
    await revealJourneyControl(tester, find.text('Continue'));
    expect(
      tester.binding.clock.now().difference(started),
      greaterThanOrEqualTo(const Duration(seconds: 2)),
    );
    expect(taps, 0);
    await tester.tap(find.text('Continue'));
    expect(taps, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('a reachable control preserves the existing scroll position', (
    tester,
  ) async {
    final scroll = ScrollController(initialScrollOffset: 100);
    addTearDown(scroll.dispose);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: [
                const SizedBox(height: 200),
                TextButton(
                  onPressed: () => taps++,
                  child: const Text('Reachable'),
                ),
                const SizedBox(height: 1000),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Reachable').hitTestable(), findsOneWidget);
    await tapJourneyControl(tester, find.text('Reachable'));
    expect(taps, 1);
    expect(scroll.offset, 100);
  });

  testWidgets('an obscured control fails with viewport evidence', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const Center(child: Text('Blocked')),
            const Positioned.fill(
              child: AbsorbPointer(child: ColoredBox(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
    await expectLater(
      () => revealJourneyControl(
        tester,
        find.text('Blocked'),
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(
        isA<TestFailure>().having(
          (error) => error.message,
          'diagnostic',
          allOf(
            contains('Blocked'),
            contains('viewport='),
            contains('keyboardInset='),
          ),
        ),
      ),
    );
  });

  testWidgets('missing and ambiguous controls cannot pass readiness', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(children: [Text('Duplicate'), Text('Duplicate')]),
      ),
    );
    for (final label in ['Missing', 'Duplicate']) {
      await expectLater(
        () => revealJourneyControl(
          tester,
          find.text(label),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<TestFailure>()),
      );
    }
  });
}
