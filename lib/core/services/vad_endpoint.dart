/// End-of-utterance policy for the "vad" voice input route.
///
/// Kotlin streams one Silero speech probability per 32 ms window; this state
/// machine decides when the round ends and which windows go to recognition.
/// tools/voice/vad_endpoint.py mirrors it for offline tuning; both run the
/// golden cases in test/fixtures/vad_endpoint_cases.json.
library;

const int vadWindowMs = 32;
const int vadWindowSamples = 512;
const double vadStartThreshold = 0.5;
const double vadEndThreshold = 0.35;
const Duration vadTail = Duration(milliseconds: 250);

int vadWindowsFor(Duration duration) =>
    (duration.inMilliseconds / vadWindowMs).ceil();

class VadEndpointConfig {
  const VadEndpointConfig({
    this.pause = const Duration(milliseconds: 1800),
    this.minSpeech = const Duration(milliseconds: 250),
    this.preRoll = const Duration(milliseconds: 300),
    this.maxDuration = const Duration(seconds: 120),
    this.noSpeechTimeout = const Duration(seconds: 8),
  });

  /// Silence after speech that ends the round.
  final Duration pause;

  /// Continuous speech needed before a round counts as started.
  final Duration minSpeech;

  /// Audio kept before the first speech window.
  final Duration preRoll;

  /// Longest round; ends with or without speech.
  final Duration maxDuration;

  /// A round in which no speech starts ends after this (no fixed 7 s stop).
  final Duration noSpeechTimeout;

  Map<String, Object> toJson() => {
    'pauseMs': pause.inMilliseconds,
    'minSpeechMs': minSpeech.inMilliseconds,
    'preRollMs': preRoll.inMilliseconds,
    'maxMs': maxDuration.inMilliseconds,
    'noSpeechMs': noSpeechTimeout.inMilliseconds,
    'startThreshold': vadStartThreshold,
    'endThreshold': vadEndThreshold,
    'tailMs': vadTail.inMilliseconds,
    'windowMs': vadWindowMs,
  };
}

enum VadEndReason { pause, maxDuration, manual, mediaKey, noSpeech }

/// Windows `[startWindow, endWindow)` go to recognition; [atWindow] is the
/// window on which the decision fell.
class VadDecision {
  const VadDecision(this.reason, this.startWindow, this.endWindow, this.atWindow);
  final VadEndReason reason;
  final int startWindow;
  final int endWindow;
  final int atWindow;

  bool get hasSpeech => reason != VadEndReason.noSpeech;
  Duration get segment =>
      Duration(milliseconds: (endWindow - startWindow) * vadWindowMs);
}

class VadEndpointer {
  VadEndpointer(this.config)
    : _pauseWindows = vadWindowsFor(config.pause),
      _minSpeechWindows = vadWindowsFor(config.minSpeech),
      _preRollWindows = vadWindowsFor(config.preRoll),
      _tailWindows = vadWindowsFor(vadTail),
      _maxWindows = config.maxDuration.inMilliseconds ~/ vadWindowMs,
      _noSpeechWindows = config.noSpeechTimeout.inMilliseconds ~/ vadWindowMs;

  final VadEndpointConfig config;
  final int _pauseWindows;
  final int _minSpeechWindows;
  final int _preRollWindows;
  final int _tailWindows;
  final int _maxWindows;
  final int _noSpeechWindows;

  int _windows = 0;
  int _run = 0;
  int _runStart = -1;
  int _speechStart = -1;
  int _lastSpeech = -1;
  int _silence = 0;
  VadDecision? _decision;

  int get windows => _windows;
  VadDecision? get decision => _decision;

  int get _cutStart =>
      _speechStart - _preRollWindows < 0 ? 0 : _speechStart - _preRollWindows;

  VadDecision? feed(double p) {
    if (_decision != null) return null;
    final i = _windows++;
    if (_speechStart < 0) {
      if (p >= vadStartThreshold) {
        if (_run == 0) _runStart = i;
        _run++;
        if (_run >= _minSpeechWindows) {
          _speechStart = _runStart;
          _lastSpeech = i;
          _silence = 0;
        }
      } else if (p < vadEndThreshold) {
        _run = 0;
      }
    } else if (p >= vadEndThreshold) {
      _lastSpeech = i;
      _silence = 0;
    } else {
      _silence++;
      if (_silence >= _pauseWindows) {
        final end = _lastSpeech + 1 + _tailWindows;
        return _decision = VadDecision(
          VadEndReason.pause,
          _cutStart,
          end < i + 1 ? end : i + 1,
          i,
        );
      }
    }
    // Nothing said: end after the no-speech timeout, but never cut a speech
    // start that is still being confirmed.
    if (_speechStart < 0 && _run == 0 && i + 1 >= _noSpeechWindows) {
      return _decision = VadDecision(VadEndReason.noSpeech, 0, 0, i);
    }
    if (i + 1 >= _maxWindows) {
      return _decision = _speechStart >= 0
          ? VadDecision(VadEndReason.maxDuration, _cutStart, i + 1, i)
          : VadDecision(VadEndReason.noSpeech, 0, 0, i);
    }
    return null;
  }

  /// Returns the first decision reached while feeding [probabilities].
  VadDecision? feedAll(Iterable<double> probabilities) {
    for (final p in probabilities) {
      final decision = feed(p);
      if (decision != null) return decision;
    }
    return null;
  }

  /// Stop button or media key: everything fed so far, from the first speech
  /// minus pre-roll, or the whole round when no speech was confirmed.
  VadDecision forceEnd(VadEndReason reason) {
    if (_decision != null) return _decision!;
    if (_windows == 0) {
      return _decision = const VadDecision(VadEndReason.noSpeech, 0, 0, 0);
    }
    return _decision = VadDecision(
      reason,
      _speechStart >= 0 ? _cutStart : 0,
      _windows,
      _windows - 1,
    );
  }
}

/// Time allowed for on-device recognition of [segment]: covers a cold model
/// load (3.1 s measured) and a real-time factor up to 0.5 (measured <= 0.11).
Duration vadRecognitionBudget(Duration segment) =>
    const Duration(seconds: 10) + segment * 0.5;
