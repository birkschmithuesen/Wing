import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/vad_endpoint.dart';

VadEndpointConfig _config(Map<String, dynamic> raw) => VadEndpointConfig(
  pause: Duration(milliseconds: raw['pauseMs'] as int? ?? 1800),
  minSpeech: Duration(milliseconds: raw['minSpeechMs'] as int? ?? 250),
  preRoll: Duration(milliseconds: raw['preRollMs'] as int? ?? 300),
  maxDuration: Duration(milliseconds: raw['maxMs'] as int? ?? 600000),
  noSpeechTimeout: Duration(milliseconds: raw['noSpeechMs'] as int? ?? 8000),
);

Iterable<double> _expand(List<dynamic> runs) sync* {
  for (final run in runs) {
    for (var i = 0; i < (run[1] as int); i++) {
      yield (run[0] as num).toDouble();
    }
  }
}

VadDecision? _run(Map<String, dynamic> raw) {
  final endpointer = VadEndpointer(_config(raw['config'] as Map<String, dynamic>));
  final decision = endpointer.feedAll(_expand(raw['runs'] as List<dynamic>));
  if (decision != null) return decision;
  return switch (raw['force']) {
    'manual' => endpointer.forceEnd(VadEndReason.manual),
    'mediaKey' => endpointer.forceEnd(VadEndReason.mediaKey),
    _ => null,
  };
}

void main() {
  final cases = (jsonDecode(
    File('test/fixtures/vad_endpoint_cases.json').readAsStringSync(),
  ) as Map<String, dynamic>)['cases'] as List<dynamic>;

  for (final raw in cases.cast<Map<String, dynamic>>()) {
    test(raw['name'] as String, () {
      final decision = _run(raw);
      final expected = raw['expect'] as Map<String, dynamic>?;
      if (expected == null) {
        expect(decision, isNull);
        return;
      }
      expect(decision, isNotNull);
      expect(decision!.reason.name, expected['reason']);
      expect(decision.startWindow, expected['startWindow']);
      expect(decision.endWindow, expected['endWindow']);
      expect(decision.atWindow, expected['atWindow']);
    });
  }

  test('pre-roll is included in the cut', () {
    final endpointer = VadEndpointer(const VadEndpointConfig());
    final decision = endpointer.feedAll([
      for (var i = 0; i < 50; i++) 0.05,
      for (var i = 0; i < 20; i++) 0.9,
      for (var i = 0; i < 60; i++) 0.1,
    ])!;
    // Speech starts at window 50; 300 ms pre-roll = 10 windows.
    expect(decision.startWindow, 40);
    expect(decision.segment, Duration(milliseconds: (decision.endWindow - 40) * 32));
  });

  test('feeding after a decision is ignored', () {
    final endpointer = VadEndpointer(const VadEndpointConfig());
    final first = endpointer.feedAll([
      for (var i = 0; i < 20; i++) 0.9,
      for (var i = 0; i < 60; i++) 0.1,
    ]);
    expect(first, isNotNull);
    final windows = endpointer.windows;
    expect(endpointer.feed(0.9), isNull);
    expect(endpointer.windows, windows);
    expect(endpointer.decision, same(first));
  });

  test('forceEnd before any window is no speech', () {
    final decision = VadEndpointer(const VadEndpointConfig()).forceEnd(VadEndReason.manual);
    expect(decision.reason, VadEndReason.noSpeech);
    expect(decision.hasSpeech, isFalse);
  });

  test('defaults match the card', () {
    const config = VadEndpointConfig();
    expect(config.pause, const Duration(milliseconds: 1800));
    expect(config.minSpeech, const Duration(milliseconds: 250));
    expect(config.preRoll, const Duration(milliseconds: 300));
    expect(config.maxDuration, const Duration(seconds: 600));
    expect(config.noSpeechTimeout, const Duration(seconds: 8));
    expect(vadWindowsFor(config.pause), 57);
    expect(config.toJson(), {
      'pauseMs': 1800, 'minSpeechMs': 250, 'preRollMs': 300, 'maxMs': 600000,
      'noSpeechMs': 8000,
      'startThreshold': 0.5, 'endThreshold': 0.35, 'tailMs': 250, 'windowMs': 32,
    });
  });

  test('no fixed 7 s stop: silence ends only at the configured no-speech timeout', () {
    final endpointer = VadEndpointer(const VadEndpointConfig());
    // 7 s = 218 windows of noise: still recording.
    expect(endpointer.feedAll(List.filled(219, 0.05)), isNull);
    final decision = endpointer.feedAll(List.filled(40, 0.05))!;
    expect(decision.reason, VadEndReason.noSpeech);
    expect(decision.atWindow, 249);
  });

  test('recognition budget scales with the segment instead of a fixed deadline', () {
    expect(vadRecognitionBudget(const Duration(seconds: 2)), const Duration(seconds: 11));
    expect(vadRecognitionBudget(const Duration(minutes: 10)), const Duration(seconds: 310));
    expect(vadRecognitionBudget(const Duration(minutes: 30)), const Duration(seconds: 910));
    expect(vadRecognitionBudget(Duration.zero), const Duration(seconds: 10));
  });
}
