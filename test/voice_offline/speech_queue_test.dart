import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:wing/voice_offline/speech_queue.dart';

void main() {
  test('a second entry waits for the first instead of cutting it off', () async {
    final queue = SpeechQueue();
    final first = Completer<bool>();
    final started = <int>[];
    final settled = <int>[];
    queue.add(() {
      started.add(1);
      return first.future;
    }, (finished) => settled.add(1));
    queue.add(() async {
      started.add(2);
      return true;
    }, (finished) => settled.add(2));
    await pumpEventQueue();
    expect(
      started,
      [1],
      reason: 'the second entry must not start before the first ends',
    );
    expect(settled, isEmpty, reason: 'nothing has finished yet');
    first.complete(true);
    await pumpEventQueue();
    expect(started, [1, 2], reason: 'arrival order is speaking order');
    expect(
      settled,
      [1, 2],
      reason: 'each entry settles with its own result once it ends',
    );
  });

  test(
    'isEmpty only turns true once the entry settling is the last one left',
    () async {
      final queue = SpeechQueue();
      final first = Completer<bool>();
      final isEmptyDuringSettle = <bool>[];
      queue.add(() => first.future, (finished) {
        isEmptyDuringSettle.add(queue.isEmpty);
      });
      queue.add(() async => true, (finished) {
        isEmptyDuringSettle.add(queue.isEmpty);
      });
      first.complete(true);
      await pumpEventQueue();
      expect(
        isEmptyDuringSettle,
        [false, true],
        reason:
            'the first entry settles while the second is already running; '
            'only the second sees the queue as truly empty',
      );
    },
  );

  test('clear drops entries waiting behind the one that is speaking', () async {
    final queue = SpeechQueue();
    final first = Completer<bool>();
    var secondStarted = false;
    final settled = <bool>[];
    queue.add(() => first.future, (finished) => settled.add(finished));
    queue.add(() async {
      secondStarted = true;
      return true;
    }, (finished) => settled.add(finished));
    queue.clear();
    first.complete(false);
    await pumpEventQueue();
    expect(
      secondStarted,
      isFalse,
      reason: 'cleared before its turn, it must never run',
    );
    expect(
      settled,
      [false],
      reason: 'the interrupted first entry still reports how it ended',
    );
  });

  test('a lone entry settles with its own result', () async {
    final queue = SpeechQueue();
    bool? result;
    queue.add(() async => true, (finished) => result = finished);
    await pumpEventQueue();
    expect(result, isTrue);
  });

  test('isEmpty is false while an entry runs or waits, true once drained', () async {
    final queue = SpeechQueue();
    expect(queue.isEmpty, isTrue);
    final first = Completer<bool>();
    queue.add(() => first.future, (finished) {});
    expect(queue.isEmpty, isFalse);
    queue.add(() async => true, (finished) {});
    expect(queue.isEmpty, isFalse);
    first.complete(true);
    await pumpEventQueue();
    expect(queue.isEmpty, isTrue);
  });
}
