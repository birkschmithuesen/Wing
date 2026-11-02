import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/upstream_capabilities_scenarios.dart';

void main() {
  registerUpstreamCapabilitiesScenarios();

  testWidgets(
    'control reveal observes a later keyboard resize before tapping',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 900),
                  TextButton(
                    onPressed: () => taps++,
                    child: const Text('Second'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final option = find.text('Second');
      tester.binding.addPostFrameCallback((_) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      });
      await revealUpstreamControl(tester, option);
      expect(taps, 0);
      await tester.tap(option.hitTestable());
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('control reveal rejects an unreachable target without tapping', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AbsorbPointer(
            child: TextButton(
              onPressed: () => taps++,
              child: const Text('Second'),
            ),
          ),
        ),
      ),
    );
    final started = tester.binding.clock.now();
    await expectLater(
      revealUpstreamControl(tester, find.text('Second')),
      throwsA(isA<TestFailure>()),
    );
    expect(
      tester.binding.clock.now().difference(started),
      const Duration(seconds: 5),
    );
    expect(taps, 0);
  });
}
