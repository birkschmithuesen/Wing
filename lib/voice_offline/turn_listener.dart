import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/services/android_voice.dart';
import '../core/services/vad_endpoint.dart';
import '../core/services/voice_preferences.dart';
import 'barge_in_policy.dart';

enum ListenPhase { idle, listening, transcribing }

/// Listen rounds on the vad route while Hermes works or reads aloud. One
/// round at a time; a round that ends without a usable utterance is replaced
/// silently. Knows nothing about chats: [onUtterance] hands every transcript
/// to the caller, [onBarge] asks it to stop read-aloud now.
class TurnListener extends ChangeNotifier {
  TurnListener({required this.device, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _events = device.events.listen(_event);
  }

  final VoiceDevice device;
  final DateTime Function() _clock;
  late final StreamSubscription<Map<String, dynamic>> _events;

  ListenPhase phase = ListenPhase.idle;
  void Function(String text)? onUtterance;
  Future<void> Function()? onBarge;

  /// True only while [onUtterance] runs for an utterance whose round fired
  /// the playback gate (a voice barge-in into read-aloud).
  bool utteranceBarged = false;

  VoicePreferences? _settings;
  String? _id;
  VadEndpointer? _endpointer;
  PlaybackGate? _gate;
  EchoStats? _stats;
  PlaybackGate? _probeGate;
  DateTime? _roundStart;
  bool _disposed = false;
  bool _barged = false;

  bool get isOpen => phase != ListenPhase.idle;

  /// The round uses the stricter read-aloud gate.
  bool get playback => _gate != null;

  /// Speech confirmed in the current round, or its transcript still pending.
  bool get speechInProgress =>
      phase == ListenPhase.transcribing ||
      (_endpointer?.speechStarted ?? false);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> open(VoicePreferences settings, {bool playback = false}) async {
    if (_disposed) return;
    _settings = settings;
    if (isOpen) {
      setPlayback(playback);
      return;
    }
    bargeLog('listen open mode=${playback ? 'playback' : 'turn'}');
    await _startRound(playback: playback);
  }

  /// Read-aloud started or ended; only playback needs the stricter gate.
  void setPlayback(bool playing) {
    if (!isOpen) return;
    _gate = playing ? (_gate ?? PlaybackGate()) : null;
  }

  Future<void> _startRound({required bool playback, bool cues = true}) async {
    final settings = _settings;
    if (settings == null || _disposed) return;
    final id = const Uuid().v4();
    _id = id;
    _endpointer = VadEndpointer(listenConfig(settings));
    _gate = playback ? PlaybackGate() : null;
    _barged = false;
    _roundStart = null;
    phase = ListenPhase.listening;
    _notify();
    try {
      await device.startVad(
        id,
        VadCaptureOptions(
          cues: cues && settings.cues,
          startCue: false,
          keepPlayback: true,
          // Spec 2026-10-16 E1 = A: listening never holds the headset link,
          // so read-aloud stays in A2DP quality.
          mic: VadMic.phone,
          debug: settings.debugRecordings,
          source: settings.audioSource,
          maxDuration: settings.vad.maxDuration,
        ),
      );
      if (_id != id || _disposed) {
        await device.cancel(id);
        return;
      }
      _roundStart = _clock();
    } catch (_) {
      if (_id == id) await _close('error');
    }
  }

  void _event(Map<String, dynamic> event) {
    if (_id == null || event['id'] != _id || _disposed) return;
    if (event['error'] is String) {
      unawaited(_close('error'));
      return;
    }
    final windows = event['windows'];
    final endpointer = _endpointer;
    if (windows is! List || endpointer == null) return;
    if (phase != ListenPhase.listening) return;
    var index = (event['first'] as num?)?.toInt() ?? endpointer.windows;
    for (final value in windows) {
      final p = (value as num).toDouble();
      final window = index++;
      final stats = _stats;
      if (stats != null) {
        stats.add(p);
        _probeGate?.feed(window, p);
        continue;
      }
      final onset = _gate?.feed(window, p);
      if (onset != null) {
        _barged = true;
        unawaited(_barge(onset));
      }
      final decision = endpointer.feed(p);
      if (decision != null) {
        unawaited(_decided(decision));
        return;
      }
    }
  }

  Future<void> _barge(int onsetWindow) async {
    final started = _roundStart;
    final before = _clock();
    try {
      await onBarge?.call();
    } catch (_) {
      // Stopping playback is best effort; the utterance is still recorded.
    }
    final after = _clock();
    final onset = started?.add(
      Duration(milliseconds: onsetWindow * vadWindowMs),
    );
    final since = onset == null ? -1 : after.difference(onset).inMilliseconds;
    bargeLog(
      'barge trigger sinceOnsetMs=$since '
      'stopMs=${after.difference(before).inMilliseconds}',
    );
  }

  Future<void> _decided(VadDecision decision) async {
    final id = _id;
    final endpointer = _endpointer;
    if (id == null || endpointer == null) return;
    final barged = _barged;
    final gate = _gate;
    if (!decision.hasSpeech) {
      bargeLog('listen restart reason=${decision.reason.name}');
      if (barged) bargeLog('falseTrigger=1');
      await _replace(id, playback: gate != null);
      return;
    }
    if (gate != null && gate.firedAt == null) {
      bargeLog('barge reject runWindows=${gate.longestRun}');
      await _replace(id, playback: true);
      return;
    }
    phase = ListenPhase.transcribing;
    _notify();
    final String text;
    try {
      final chunks = vadChunksFor(
        endpointer.probabilities,
        decision.startWindow,
        decision.endWindow,
      );
      text = await device
          .finishVad(id, decision, endpointer.config, chunks: chunks)
          .timeout(
            vadRecognitionBudget(decision.segment, chunks: chunks.length),
          );
    } catch (_) {
      if (_id == id && !_disposed) {
        bargeLog('utterance failed');
        await _startRound(playback: false);
      }
      return;
    }
    if (_id != id || _disposed) return;
    bargeLog(
      'utterance segmentMs=${decision.segment.inMilliseconds} '
      'textLen=${text.trim().length}',
    );
    // Echo misfire: the gate fired but nothing sendable followed it.
    if (barged && !isSendableTranscript(text)) bargeLog('falseTrigger=1');
    await _startRound(playback: false);
    utteranceBarged = barged;
    try {
      onUtterance?.call(text);
    } finally {
      utteranceBarged = false;
    }
  }

  /// Ends round [id] without recognition and starts the next one.
  Future<void> _replace(String id, {required bool playback}) async {
    await device.cancel(id).catchError((Object _) {});
    if (_id == id && !_disposed) await _startRound(playback: playback);
  }

  /// Media key: end the utterance now, or close when nothing was said.
  Future<void> endUtterance() async {
    final endpointer = _endpointer;
    if (phase != ListenPhase.listening || endpointer == null) return;
    if (!endpointer.speechStarted) {
      await _close('mediaKey');
      return;
    }
    _gate = null;
    await _decided(endpointer.forceEnd(VadEndReason.mediaKey));
  }

  Future<void> close(String reason) => _close(reason);

  Future<void> _close(String reason) async {
    final id = _id;
    if (id == null && phase == ListenPhase.idle) return;
    _id = null;
    _endpointer = null;
    _gate = null;
    _roundStart = null;
    phase = ListenPhase.idle;
    _notify();
    bargeLog('listen close reason=$reason');
    if (id != null) await device.cancel(id).catchError((Object _) {});
  }

  /// Debug: records speech probabilities while [play] runs (nobody speaking)
  /// and logs one `probe` line. No recognition, no utterances.
  Future<EchoStats> probe(
    VoicePreferences settings,
    Future<void> Function() play,
  ) async {
    await _close('probe');
    final stats = EchoStats();
    final gate = PlaybackGate();
    _settings = settings;
    _stats = stats;
    _probeGate = gate;
    try {
      await _startRound(playback: false, cues: false);
      await play();
    } finally {
      _stats = null;
      _probeGate = null;
      await _close('probe');
    }
    bargeLog(
      stats.logLine(
        source: settings.audioSource == VadAudioSource.communication
            ? 'VOICE_COMMUNICATION'
            : 'VOICE_RECOGNITION',
        wouldTrigger: gate.firedAt != null,
      ),
    );
    return stats;
  }

  @override
  void dispose() {
    unawaited(_close('dispose'));
    _disposed = true;
    unawaited(_events.cancel());
    super.dispose();
  }
}
