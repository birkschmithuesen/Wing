import 'package:flutter_test/flutter_test.dart';

import 'phone_luna_live_performance_test.dart' show LunaTurnCancellation;

void main() {
  late bool terminal;
  late int interrupts;
  late int idleCancellations;
  late LunaTurnCancellation cancellation;

  setUp(() {
    terminal = false;
    interrupts = 0;
    idleCancellations = 0;
    cancellation = LunaTurnCancellation(
      isTerminal: () => terminal,
      interrupt: () async => interrupts++,
      cancelIdle: () {
        idleCancellations++;
        terminal = true;
      },
    );
  });

  test('cancellation before dispatch prevents generation', () async {
    await cancellation.request();
    expect(cancellation.beginDispatch(), isFalse);
    expect(idleCancellations, 1);
    expect(interrupts, 0);
  });

  test('idle observer cancellation never interrupts a session', () async {
    await cancellation.request();
    await cancellation.request();
    expect(terminal, isTrue);
    expect(idleCancellations, 1);
    expect(interrupts, 0);
  });

  test('an uncertain dispatch cannot start a second generation', () {
    expect(cancellation.beginDispatch(), isTrue);
    expect(cancellation.beginDispatch(), isFalse);
    expect(interrupts, 0);
  });

  test(
    'pending submission stays observed and interrupts on acceptance',
    () async {
      expect(cancellation.beginDispatch(), isTrue);
      await cancellation.request();
      expect(terminal, isFalse);
      expect(idleCancellations, 0);
      expect(interrupts, 0);
      await cancellation.dispatchAccepted();
      await cancellation.turnStarted();
      await cancellation.request();
      expect(interrupts, 1);
    },
  );

  test(
    'start event interrupts cancelled dispatch before its RPC returns',
    () async {
      expect(cancellation.beginDispatch(), isTrue);
      await cancellation.request();
      await cancellation.turnStarted();
      expect(interrupts, 1);
      await cancellation.dispatchAccepted();
      expect(interrupts, 1);
    },
  );

  for (final finished in [false, true]) {
    test(
      '${finished ? 'finished observer' : 'terminal turn'} blocks late interrupt',
      () async {
        expect(cancellation.beginDispatch(), isTrue);
        await cancellation.request();
        if (finished) {
          cancellation.finished = true;
        } else {
          terminal = true;
        }
        await cancellation.dispatchAccepted();
        await cancellation.turnStarted();
        await cancellation.request();
        expect(interrupts, 0);
        expect(idleCancellations, 0);
      },
    );
  }
}
