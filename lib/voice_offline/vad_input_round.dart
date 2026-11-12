import 'dart:async';
import '../core/services/vad_endpoint.dart';
import 'car_mic_session.dart';
import 'vad_voice_device.dart';
import 'voice_offline_prefs.dart';

/// How long to let the native recognizer finish after stop(), scaled with
/// how long the user spoke: a fixed short window cuts off longer on-device
/// transcriptions before the model is done (card t_49d11117 - ~50s of audio
/// needs well over 5s to finalize on this hardware).
Duration transcriptionDeadlineFor(int recordedSeconds) {
  final ms = 5000 + recordedSeconds * 500;
  return Duration(milliseconds: ms < 90000 ? ms : 90000);
}

String micFallbackMessage(VoiceMicRoute chosen) => switch (chosen) {
  VoiceMicRoute.bluetooth =>
    'Bluetooth microphone not found. Used the automatic microphone for this recording.',
  VoiceMicRoute.wired =>
    'Wired microphone not found. Used the automatic microphone for this recording.',
  _ => 'Chosen microphone not available. Used the automatic microphone for this recording.',
};

/// The vad route of one [VoiceInputController] capture: endpointing, the car
/// kit's SCO hold, the mic fallback hint and the phone-side transcription.
/// The controller owns phase, timer and draft; this class reports back through
/// the callbacks it is handed.
class VadInputRound {
  VadInputRound({
    required this.device,
    this.carMicSession,
    bool Function()? carKitConnected,
    bool Function()? carModeActive,
  }) : _carKitConnected = carKitConnected ?? _never,
       _carModeActive = carModeActive ?? _never;

  final VadVoiceDevice device;

  /// Holds a connected car kit's SCO link open for the whole hands-free
  /// conversation, starting with the first dictation round (spec Birk
  /// decision 2026-10-19). Null keeps today's per-round behaviour (e.g.
  /// headphone routes never pass one in, see [_carKitConnected]).
  final CarMicSession? carMicSession;
  final bool Function() _carKitConnected;

  /// True while Wing's own car-mode screen is the current route (spec: SCO
  /// also opens on entering car mode with a car connected, not only on the
  /// first dictation of Conversation mode).
  final bool Function() _carModeActive;

  VadEndpointer? _endpointer;
  String? _id;
  bool _recording = false;
  bool _stopRequested = false;
  String? _micFallbackHint;

  static bool _never() => false;

  /// True while a vad round owns the recording.
  bool get active => _endpointer != null;

  /// Whether the last round ended by itself (endpoint), not by a user stop.
  bool get finishedOnItsOwn => !_stopRequested;

  /// Set once, right after [begin], when a manual [VoiceOfflinePrefs.micRoute]
  /// choice was not available and this round fell back to Automatic. The
  /// caller shows it once (e.g. a snackbar); reading it clears it.
  String? takeMicFallbackHint() {
    final hint = _micFallbackHint;
    _micFallbackHint = null;
    return hint;
  }

  /// Starts the capture. Answers false when the round was superseded
  /// ([isCurrent] turned false) before the device was started.
  Future<bool> begin(
    String id,
    VoiceOfflinePrefs prefs, {
    required bool Function() isCurrent,
  }) async {
    _id = id;
    _micFallbackHint = null;
    _stopRequested = false;
    _endpointer = VadEndpointer(prefs.vad);
    // Spec Birk decision 2026-10-19: the first dictation of a hands-free
    // conversation (or any dictation while Wing's own car mode is on,
    // with a car connected) opens the car kit's SCO link for the whole
    // conversation instead of just this round. A manual phone/wired mic
    // choice is left alone - it already skips the Bluetooth path.
    var mic = prefs.micRoute;
    var holdMic = false;
    final session = carMicSession;
    if (session != null &&
        _carKitConnected() &&
        (prefs.conversation || _carModeActive()) &&
        (mic == VoiceMicRoute.auto || mic == VoiceMicRoute.bluetooth)) {
      holdMic = await session.beginRound('conversation');
      if (holdMic) mic = VoiceMicRoute.bluetooth;
    }
    if (!isCurrent()) return false;
    final fellBack = await device.startVad(
      id,
      VadCaptureOptions(
        cues: prefs.cues,
        debug: prefs.debugRecordings,
        source: prefs.audioSource,
        maxDuration: prefs.vad.maxDuration,
        mic: mic,
        holdMic: holdMic,
      ),
    );
    // A superseded round must not touch the current round's state; the
    // controller cancels its device capture right after this returns.
    if (!isCurrent()) return true;
    if (fellBack) _micFallbackHint = micFallbackMessage(prefs.micRoute);
    // The controller moves to recording right after this returns, before any
    // further device event can be delivered.
    _recording = true;
    return true;
  }

  /// Feeds a device event; true when it was a vad event and was consumed.
  bool onEvent(
    Map<String, dynamic> event, {
    required void Function() transcribing,
    required void Function(String text) finish,
    required void Function(Object error) fail,
  }) {
    if (event['windows'] case final List<Object?> windows) {
      final endpointer = _endpointer;
      if (endpointer == null || !_recording) return true;
      final decision = endpointer.feedAll(
        windows.map((value) => (value as num).toDouble()),
      );
      if (decision != null) {
        unawaited(_finish(decision, transcribing, finish, fail));
      }
      return true;
    }
    return false;
  }

  /// User stop while a vad round runs.
  Future<void> forceEnd({
    required void Function() transcribing,
    required void Function(String text) finish,
    required void Function(Object error) fail,
  }) async {
    final endpointer = _endpointer;
    if (endpointer == null) return;
    await _finish(
      endpointer.forceEnd(VadEndReason.manual),
      transcribing,
      finish,
      fail,
    );
  }

  /// Media key: ends the round as a hands-free action (sent in conversation mode).
  Future<void> stopHandsFree({
    required void Function() transcribing,
    required void Function(String text) finish,
    required void Function(Object error) fail,
  }) async {
    final endpointer = _endpointer;
    if (endpointer == null) return;
    await _finish(
      endpointer.forceEnd(VadEndReason.mediaKey),
      transcribing,
      finish,
      fail,
    );
  }

  Future<void> _finish(
    VadDecision decision,
    void Function() transcribing,
    void Function(String text) finish,
    void Function(Object error) fail,
  ) async {
    final id = _id;
    final endpointer = _endpointer;
    if (id == null || endpointer == null || !_recording) return;
    if (!decision.hasSpeech) {
      // Tell the phone why the round ended (debug JSON reason "noSpeech"; Kotlin
      // skips recognition for it), then end the round. Channel calls keep their
      // order, so the following cancel finds no round left.
      unawaited(
        device
            .finishVad(id, decision, endpointer.config)
            .then((_) {}, onError: (Object _) {}),
      );
      fail(StateError('No speech detected. Try again.'));
      return;
    }
    _stopRequested =
        decision.reason != VadEndReason.pause &&
        decision.reason != VadEndReason.mediaKey;
    _recording = false;
    transcribing();
    try {
      final chunks = vadChunksFor(
        endpointer.probabilities,
        decision.startWindow,
        decision.endWindow,
      );
      final text = await device
          .finishVad(id, decision, endpointer.config, chunks: chunks)
          .timeout(vadRecognitionBudget(decision.segment, chunks: chunks.length));
      // dispose -> cancel -> clear() nulls _id, which replaces the old
      // `!_disposed` check.
      if (_id == id) finish(text);
    } catch (failure) {
      if (_id == id) fail(failure);
    }
  }

  void clear() {
    _id = null;
    _endpointer = null;
    _recording = false;
  }
}
