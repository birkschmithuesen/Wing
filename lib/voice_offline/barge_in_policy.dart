/// Barge-in policy: thresholds, echo statistics and what happens with an
/// utterance heard while Hermes works or reads aloud. Pure; no Flutter
/// widgets, no chat types (spec 2026-10-14-wing-voice-barge-in-design.md).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/services/vad_endpoint.dart';
import '../core/services/voice_preferences.dart';

/// Offer "Interrupt read-aloud by speaking" (set by the echo gate, Task 7).
const bool bargeInPlaybackAvailable = true;

/// While Wing reads aloud, speech only counts after [bargeGateWindows]
/// consecutive windows (32 ms each) with p >= [bargeGateThreshold].
const double bargeGateThreshold = 0.7;
const int bargeGateWindows = 16;

/// Synthetic text read during the echo probe (about 30 s). Never shown.
const String echoProbeText =
    'Dies ist ein Messtext für die Echoprüfung. Er enthält keine echten '
    'Inhalte. Die Sprachausgabe liest ihn gleichmäßig vor, während das '
    'Mikrofon mithört. Eins, zwei, drei, vier, fünf, sechs, sieben, acht, '
    'neun, zehn. Der Wind weht über das flache Land, und am Horizont ziehen '
    'graue Wolken auf. Ein Zug fährt langsam durch den kleinen Bahnhof, ohne '
    'anzuhalten. Elf, zwölf, dreizehn, vierzehn, fünfzehn. Jetzt endet der '
    'Messtext.';

/// One logcat line (tag flutter). Callers pass numbers and states only,
/// never transcript, reply or prompt text.
void bargeLog(String message) => debugPrint('WingBargeIn $message');

/// Endpointing for listen rounds: same pause and lead-in as dictation, a
/// higher minimum speech, and no early no-speech stop (a tool turn can run
/// for minutes; the round restarts at its maximum duration instead).
VadEndpointConfig listenConfig(VoicePreferences settings) => VadEndpointConfig(
  pause: settings.vad.pause,
  minSpeech: settings.listenMinSpeech,
  preRoll: settings.vad.preRoll,
  maxDuration: settings.vad.maxDuration,
  noSpeechTimeout: settings.vad.maxDuration,
);

/// Confirms a barge-in during read-aloud: a run of [windows] consecutive
/// windows at or above [threshold]. Fires once; [firedAt] is the run's first
/// window.
class PlaybackGate {
  PlaybackGate({
    this.threshold = bargeGateThreshold,
    this.windows = bargeGateWindows,
  });

  final double threshold;
  final int windows;
  int? firedAt;
  int longestRun = 0;
  int _run = 0;
  int _runStart = -1;
  int _last = -2;

  /// Returns the run's first window when the gate fires, otherwise null.
  int? feed(int window, double p) {
    if (window != _last + 1) _run = 0;
    _last = window;
    if (p < threshold) {
      _run = 0;
      return null;
    }
    if (_run == 0) _runStart = window;
    _run++;
    if (_run > longestRun) longestRun = _run;
    if (firedAt == null && _run >= windows) return firedAt = _runStart;
    return null;
  }
}

/// Speech probabilities measured while Wing plays its own voice.
class EchoStats {
  final List<double> _values = [];
  int run50 = 0;
  int run70 = 0;
  int _current50 = 0;
  int _current70 = 0;

  int get windows => _values.length;
  double get max => _values.isEmpty ? 0 : _values.reduce(math.max);

  void add(double p) {
    _values.add(p);
    _current50 = p >= 0.5 ? _current50 + 1 : 0;
    _current70 = p >= 0.7 ? _current70 + 1 : 0;
    if (_current50 > run50) run50 = _current50;
    if (_current70 > run70) run70 = _current70;
  }

  /// Nearest-rank percentile; [q] in 0..1.
  double percentile(double q) {
    if (_values.isEmpty) return 0;
    final sorted = [..._values]..sort();
    final rank = (q * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  String logLine({required String source, required bool wouldTrigger}) {
    String f(double value) => value.toStringAsFixed(3);
    return 'probe windows=$windows max=${f(max)} p50=${f(percentile(0.5))} '
        'p95=${f(percentile(0.95))} p99=${f(percentile(0.99))} '
        'run50=$run50 run70=$run70 wouldTrigger=${wouldTrigger ? 1 : 0} '
        'source=$source';
  }
}

const _fillers = {'äh', 'ähm', 'öh', 'hm', 'hmm', 'mhm', 'uh', 'um', 'uhm', 'eh'};
final _letter = RegExp(r'\p{L}', unicode: true);
final _nonLetter = RegExp(r'[^\p{L}]', unicode: true);

/// False for empty text, text without letters, or fillers only. "ja" and
/// "nein" are answers, not fillers.
bool isSendableTranscript(String text) {
  final trimmed = text.trim();
  if (!_letter.hasMatch(trimmed)) return false;
  return trimmed
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map((word) => word.replaceAll(_nonLetter, ''))
      .where((word) => word.isNotEmpty)
      .any((word) => !_fillers.contains(word));
}

/// Chat state as the listener needs it (mapped from ProfileTurnStatus by
/// the workspace screen): running/attention → steerable,
/// submitting/reconnecting → busy, everything else → idle.
enum ListenChatState { steerable, busy, idle }

enum ListenDelivery { drop, steer, queue, send }

ListenDelivery decideDelivery(
  ListenChatState state,
  String transcript, {
  bool steerRejected = false,
}) {
  if (!isSendableTranscript(transcript)) return ListenDelivery.drop;
  return switch (state) {
    ListenChatState.steerable =>
      steerRejected ? ListenDelivery.queue : ListenDelivery.steer,
    ListenChatState.busy => ListenDelivery.queue,
    ListenChatState.idle => ListenDelivery.send,
  };
}

/// Appended to a message that cut off read-aloud by voice (spec §3.6). The
/// profile's Wing platform hint asks Hermes to fold the unheard points of
/// the previous reply into the next one. No percentage: Wing has no
/// sentence-level read-aloud progress.
const String interruptedReplyHint =
    '[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen '
    'und nicht zu Ende gehört.]';

String withInterruptedReplyHint(String text) =>
    '${text.trimRight()}\n\n$interruptedReplyHint';
