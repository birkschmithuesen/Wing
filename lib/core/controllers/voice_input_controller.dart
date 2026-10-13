import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import '../services/android_voice.dart';
import '../services/hermes_voice.dart';
import '../services/voice_preferences.dart';

enum VoiceInputPhase { idle, starting, recording, transcribing }

/// How long to let the native recognizer finish after stop(), scaled with
/// how long the user spoke: a fixed short window cuts off longer on-device
/// transcriptions before the model is done (card t_49d11117 - ~50s of audio
/// needs well over 5s to finalize on this hardware).
Duration transcriptionDeadlineFor(int recordedSeconds) {
  final ms = 5000 + recordedSeconds * 500;
  return Duration(milliseconds: ms < 90000 ? ms : 90000);
}

/// A single capture, tied to a draft snapshot and an immutable remote owner.
/// Only a completed transcript edits the draft; cancellation preserves it exactly.
class VoiceInputController extends ChangeNotifier {
  final VoiceDevice device;
  final RemoteVoice Function() createRemote;
  late final StreamSubscription<Map<String, dynamic>> _events;
  VoiceInputPhase phase = VoiceInputPhase.idle;
  String partial = '';
  String? error;
  int seconds = 0;

  /// Whether the last transcript arrived because the recognizer ended the
  /// utterance itself (end of speech), not because the user pressed Stop or
  /// the recording limit was reached. Set before the result callback runs.
  bool finishedOnItsOwn = false;
  bool _stopRequested = false;
  String? _id;
  bool _disposed = false;
  RemoteVoice? _remote;
  Timer? _timer;
  TextEditingValue? _draft;
  void Function(TextEditingValue)? _onResult;

  VoiceInputController({required this.device, required this.createRemote}) {
    _events = device.events.listen(_event);
  }
  bool get active => phase != VoiceInputPhase.idle;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(
    VoicePreferences settings,
    TextEditingValue draft,
    void Function(TextEditingValue) onResult,
  ) async {
    if (_disposed || active) return;
    final id = const Uuid().v4();
    _id = id;
    _draft = draft;
    _onResult = onResult;
    error = null;
    partial = '';
    seconds = 0;
    finishedOnItsOwn = false;
    _stopRequested = false;
    phase = VoiceInputPhase.starting;
    _notify();
    try {
      if (settings.input == VoiceProcessing.hermes) _remote = createRemote();
      await device.start(
        id,
        local: _remote == null,
        language: settings.language,
      );
      if (_id != id || _disposed) {
        await device.cancel(id);
        return;
      }
      phase = VoiceInputPhase.recording;
      _notify();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        seconds++;
        _notify();
        if (seconds >= 120) unawaited(stop());
      });
    } catch (failure) {
      if (_id == id) _fail(failure);
    }
  }

  void _event(Map<String, dynamic> event) {
    if (_id == null || event['id'] != _id || _disposed) return;
    if (event['error'] case final String message) {
      _fail(StateError(message));
      return;
    }
    if (event['limit'] == true) {
      unawaited(stop());
      return;
    }
    if (event['text'] case final String text) {
      partial = text;
      if (event['final'] == true) {
        _finish(text);
      } else {
        _notify();
      }
    }
  }

  Future<void> stop() async {
    final id = _id;
    if (id == null || phase != VoiceInputPhase.recording) return;
    _stopRequested = true;
    _timer?.cancel();
    phase = VoiceInputPhase.transcribing;
    _notify();
    try {
      final bytes = await device.stop(
        id,
        timeout: transcriptionDeadlineFor(seconds),
      );
      if (_id != id || _disposed) return;
      final remote = _remote;
      if (remote != null) {
        if (bytes == null) {
          throw StateError('No recording was returned. Please retry.');
        }
        final text = await remote.transcribe(bytes);
        if (_id == id && !_disposed) _finish(text);
      }
      // Local stop completes through a final native event, including timeout.
    } catch (failure) {
      if (_id == id) _fail(failure);
    }
  }

  void _finish(String transcript) {
    if (transcript.trim().isEmpty) {
      _fail(StateError('No speech detected. Try again.'));
      return;
    }
    final draft = _draft!;
    final callback = _onResult;
    finishedOnItsOwn = !_stopRequested && _remote == null;
    final result = insertVoiceTranscript(draft, transcript.trim());
    _clear();
    callback?.call(result);
    _notify();
  }

  void _fail(Object failure) {
    final id = _id;
    error = voiceFailureMessage(failure);
    _clear();
    _notify();
    if (id != null) unawaited(device.cancel(id).catchError((Object _) {}));
  }

  void _clear() {
    _id = null;
    _timer?.cancel();
    _timer = null;
    _remote?.close();
    _remote = null;
    _draft = null;
    _onResult = null;
    phase = VoiceInputPhase.idle;
    partial = '';
  }

  Future<void> cancel() async {
    final id = _id;
    error = null;
    _clear();
    _notify();
    if (id != null) await device.cancel(id);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(cancel().catchError((Object _) {}));
    unawaited(_events.cancel());
    super.dispose();
  }
}

TextEditingValue insertVoiceTranscript(TextEditingValue draft, String text) {
  final selection = draft.selection;
  final valid = selection.isValid && selection.end <= draft.text.length;
  final start = valid ? selection.start : draft.text.length;
  final end = valid ? selection.end : draft.text.length;
  final leading =
      start > 0 &&
          draft.text[start - 1].trim().isNotEmpty &&
          !'.,!?;:)]}'.contains(text[0])
      ? ' '
      : '';
  final trailing =
      end < draft.text.length &&
          draft.text[end].trim().isNotEmpty &&
          !'([{'.contains(text[text.length - 1])
      ? ' '
      : '';
  return TextEditingValue(
    text: draft.text.replaceRange(start, end, '$leading$text$trailing'),
    selection: TextSelection.collapsed(
      offset: start + leading.length + text.length,
    ),
  );
}

String voiceFailureMessage(Object failure) => switch (failure) {
  PlatformException error => error.message ?? 'Android voice is unavailable.',
  MissingPluginException() => 'Voice is available in the Android app.',
  StateError error => error.message.toString(),
  FormatException error => error.message,
  TimeoutException() => 'Speech processing timed out. Please retry.',
  _ =>
    'Speech processing failed. Check your connection and profile speech settings, then retry.',
};
