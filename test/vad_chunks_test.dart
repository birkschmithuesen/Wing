import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/vad_endpoint.dart';

/// Speech everywhere except the given `[start, end)` quiet ranges.
List<double> _speech(int windows, [List<List<int>> quiet = const []]) {
  final values = List<double>.filled(windows, 0.9);
  for (final range in quiet) {
    for (var i = range[0]; i < range[1]; i++) {
      values[i] = 0.05;
    }
  }
  return values;
}

void _expectCover(List<VadChunk> chunks, int start, int end) {
  expect(chunks, isNotEmpty);
  expect(chunks.first.startWindow, start);
  expect(chunks.last.endWindow, end);
  for (var i = 1; i < chunks.length; i++) {
    expect(chunks[i].startWindow, chunks[i - 1].endWindow);
  }
  for (final chunk in chunks) {
    expect(chunk.windows, greaterThan(0));
  }
}

void main() {
  const maxWindows = 938; // 30 s at 32 ms
  test('an empty segment has no chunks', () {
    expect(vadChunksFor(const [], 5, 5), isEmpty);
  });

  test('segments up to 30 s are one chunk', () {
    expect(vadChunksFor(_speech(100), 0, 100), [const VadChunk(0, 100)]);
    expect(
      vadChunksFor(_speech(2000), 10, 10 + maxWindows),
      [const VadChunk(10, 10 + maxWindows)],
    );
  });

  test('no pause at all cuts at 30 s exactly', () {
    final chunks = vadChunksFor(_speech(2000), 0, 2000);
    expect(chunks, [
      const VadChunk(0, 938),
      const VadChunk(938, 1876),
      const VadChunk(1876, 2000),
    ]);
  });

  test('a cut lands in the middle of the longest pause of the last 10 s', () {
    // Pauses inside the search range 625..938: [700, 710) and [800, 840).
    final chunks = vadChunksFor(
      _speech(1500, [
        [700, 710],
        [800, 840],
        [300, 500], // outside the search range: ignored
      ]),
      0,
      1500,
    );
    expect(chunks.first, const VadChunk(0, 820));
    _expectCover(chunks, 0, 1500);
  });

  test('equally long pauses cut at the earliest one', () {
    final chunks = vadChunksFor(
      _speech(1500, [
        [700, 720],
        [800, 820],
      ]),
      0,
      1500,
    );
    expect(chunks.first, const VadChunk(0, 710));
  });

  test('a pause that only dips above the end threshold is not a pause', () {
    final values = _speech(1500);
    for (var i = 700; i < 760; i++) {
      values[i] = 0.4;
    }
    expect(vadChunksFor(values, 0, 1500).first, const VadChunk(0, 938));
  });

  test('ten minutes with pauses: cuts in pauses, chunks <= 30 s, full coverage', () {
    const total = 18700; // about 10 min
    // A 0.5 s pause about every 9.6 s (period 300 windows).
    final quiet = [
      for (var s = 100; s + 16 <= total; s += 300) [s, s + 16],
    ];
    final values = _speech(total, quiet);
    final chunks = vadChunksFor(values, 40, total);
    _expectCover(chunks, 40, total);
    for (final chunk in chunks) {
      expect(chunk.windows, lessThanOrEqualTo(maxWindows));
    }
    for (final chunk in chunks.take(chunks.length - 1)) {
      // The cut falls before a quiet window or right after one.
      final cut = chunk.endWindow;
      final near = [values[cut - 1], values[cut]].any((p) => p < vadEndThreshold);
      expect(near, isTrue, reason: 'cut at $cut is not inside a pause');
    }
    expect(chunks.length, greaterThan(18));
  });

  test('a remainder under 2 s joins the previous chunk (up to 32 s)', () {
    // 938 + 40 windows: the 40-window tail (1.28 s) merges into one chunk.
    expect(vadChunksFor(_speech(2000), 0, 938 + 40), [const VadChunk(0, 978)]);
    // 938 + 62 = 1000 windows = exactly 32 s still merges.
    expect(vadChunksFor(_speech(2000), 0, 938 + 62), [const VadChunk(0, 1000)]);
  });

  test('a remainder of 2 s or more stays a separate chunk', () {
    expect(vadChunksFor(_speech(2000), 0, 938 + 63), [
      const VadChunk(0, 938),
      const VadChunk(938, 1001),
    ]);
  });

  test('the merge is limited to 32 s', () {
    const config = VadChunkConfig(mergeLimit: Duration(seconds: 30));
    expect(vadChunksFor(_speech(2000), 0, 938 + 40, config: config), [
      const VadChunk(0, 938),
      const VadChunk(938, 978),
    ]);
  });
}
