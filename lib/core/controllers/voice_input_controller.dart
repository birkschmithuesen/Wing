import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../models/composer_action.dart';
import '../models/composer_work.dart';
import 'package:uuid/uuid.dart';
import '../services/android_voice.dart';
import '../services/hermes_voice.dart';
import '../models/voice_processing_settings.dart';
import '../../voice_offline/vad_input_round.dart';

enum VoiceInputPhase { idle, starting, recording, transcribing }

enum VoiceInputEmptyResult { noSpeech, noRecording }

typedef VoiceInputNotice = ({String attempt, VoiceInputEmptyResult result});

/// A single capture, tied to a draft snapshot and an immutable remote owner.
/// Only a completed transcript edits the draft; cancellation preserves it exactly.
class VoiceInputController extends ChangeNotifier {
  /// Hard ceiling on a single hermes recording, in seconds. Spec/brainstorming
  /// sessions run 3-6 minutes; 600s leaves headroom above that.
  static const maxRecordingSeconds = 600;

  final VoiceDevice device;
  final VadInputRound? vadRound;
  late final StreamSubscription<Map<String, dynamic>> _events;
  VoiceInputPhase _phase = VoiceInputPhase.idle;
  String _partial = '';
  String? _error;
  VoiceInputNotice? _notice;
  int _seconds = 0;

  /// Whether the last transcript arrived because the recognizer ended the
  /// utterance itself (end of speech), not because the user pressed Stop or
  /// the recording limit was reached. Set before the result callback runs.
  bool finishedOnItsOwn = false;
  bool _stopRequested = false;
  String? _id;
  bool _disposed = false;
  int _commandGeneration = 0;
  int _notificationDepth = 0;
  Object? _target;
  RemoteVoice? _remote;

  /// Upper bound shown while recording ("Recording · 12s / 600s" on vad).
  int maxSeconds = maxRecordingSeconds;

  /// True while a round on the vad route is active.
  bool get vad => vadRound?.active ?? false;
  Timer? _timer;
  VoiceDraft? _draft;
  void Function(VoiceDraft)? _onResult;

  VoiceInputController({required this.device, this.vadRound}) {
    _events = device.events.listen(_event);
  }
  VoiceInputPhase get phase => _phase;
  String get partial => _partial;
  String? get error => _error;
  VoiceInputNotice? get notice => _notice;
  int get seconds => _seconds;
  bool get active => _phase != VoiceInputPhase.idle;

  void _notify() {
    if (_disposed) return;
    ++_notificationDepth;
    try {
      notifyListeners();
    } finally {
      --_notificationDepth;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  bool canDictate(bool targetAvailable) =>
      !_disposed && !active && targetAvailable;

  Map<ComposerAction, ComposerUnavailableReason?> composerAvailability(
    ComposerActions composer,
  ) => active
      ? Map.unmodifiable({
          for (final action in ComposerAction.values)
            action: ComposerUnavailableReason.dictation,
        })
      : composer.unavailable;

  void retainTarget(Object? target) {
    if (_target != null && _target != target) {
      unawaited(cancel().catchError((Object _) {}));
    }
  }

  /// Recorder admission and completion use the same captured chat and intent.
  Future<void> dictate<T extends Object>({
    required T target,
    required VoiceDraft draft,
    required VoiceInputSettings? Function() settings,
    required Future<void> Function() stopPlayback,
    required bool Function(T) admitsTarget,
    required bool Function() admitPresentation,
    required RemoteVoice Function(T) createRemote,
    required Future<void> Function(String) applyDraft,
    required void Function(VoiceDraft) onApplied,
    required void Function(String) onNotice,
  }) async {
    if (_disposed || active) return;
    final generation = ++_commandGeneration;
    _target = target;
    bool current() =>
        !_disposed && generation == _commandGeneration && admitsTarget(target);
    try {
      await stopPlayback();
    } catch (failure) {
      if (current() && admitPresentation()) {
        onNotice(voiceFailureMessage(failure));
      }
      return;
    }
    if (!current() || !admitPresentation()) return;
    final choice = settings();
    if (choice == null) {
      onNotice('Repair voice input settings in App settings before recording.');
      return;
    }
    await start(choice, draft, (result) {
      Future<void> complete() async {
        if (!current() || !admitPresentation()) return;
        try {
          // The composer's command admits the exact captured text revision
          // synchronously, before persistence yields. Cursor application is UI.
          final saving = applyDraft(result.text);
          if (current() && admitPresentation()) onApplied(result);
          await saving;
        } catch (failure) {
          if (current() && admitPresentation()) {
            onNotice(voiceFailureMessage(failure));
          }
        }
      }

      unawaited(complete());
    }, createRemote: () => createRemote(target));
  }

  Future<void> start(
    VoiceInputSettings settings,
    VoiceDraft draft,
    void Function(VoiceDraft) onResult, {
    required RemoteVoice Function() createRemote,
  }) async {
    if (_disposed || active) return;
    final id = const Uuid().v4();
    _id = id;
    _draft = draft;
    _onResult = onResult;
    _error = null;
    _notice = null;
    _partial = '';
    _seconds = 0;
    finishedOnItsOwn = false;
    _stopRequested = false;
    _phase = VoiceInputPhase.starting;
    _notify();
    if (_disposed || _id != id) return;
    try {
      switch (settings) {
        case VadVoiceInputSettings():
          final offline = vadRound!.roundSettings();
          maxSeconds = offline.vad.maxDuration.inSeconds;
          final current = await vadRound!.begin(
            id,
            offline,
            isCurrent: () => _id == id && !_disposed,
          );
          if (!current) return;
        case LocalVoiceInputSettings(:final language):
          maxSeconds = maxRecordingSeconds;
          await device.start(id, local: true, language: language);
        case HermesVoiceInputSettings():
          maxSeconds = maxRecordingSeconds;
          _remote = createRemote();
          await device.start(id, local: false, language: '');
      }
      if (_id != id || _disposed) {
        await device.cancel(id);
        return;
      }
      _phase = VoiceInputPhase.recording;
      _notify();
      if (_disposed || _id != id) return;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        _seconds++;
        _notify();
        // The vad endpointer owns its own limit.
        if (!vad && _seconds >= maxRecordingSeconds) {
          unawaited(stop());
        }
      });
    } catch (failure) {
      if (_id == id) _fail(failure);
    }
  }

  void _event(Map<String, dynamic> event) {
    if (_id == null || event['id'] != _id || _disposed) return;
    if (event['error'] case final String message) {
      if (event['code'] == 'no_speech') {
        _emptyResult(VoiceInputEmptyResult.noSpeech);
        return;
      }
      _fail(StateError(message));
      return;
    }
    if (event['limit'] == true) {
      unawaited(stop());
      return;
    }
    if (vadRound?.onEvent(
          event,
          transcribing: _vadTranscribing,
          finish: _finish,
          fail: _fail,
          noSpeech: () => _emptyResult(VoiceInputEmptyResult.noSpeech),
        ) ??
        false) {
      return;
    }
    if (event['text'] case final String text) {
      _partial = text;
      if (event['final'] == true) {
        _finish(text);
      } else {
        _notify();
      }
    }
  }

  Future<void> stop() async {
    final id = _id;
    if (id == null || _phase != VoiceInputPhase.recording) return;
    if (vad) {
      return vadRound!.forceEnd(
        transcribing: _vadTranscribing,
        finish: _finish,
        fail: _fail,
        noSpeech: () => _emptyResult(VoiceInputEmptyResult.noSpeech),
      );
    }
    _stopRequested = true;
    _timer?.cancel();
    _phase = VoiceInputPhase.transcribing;
    _notify();
    if (_disposed || _id != id) return;
    try {
      final bytes = await device.stop(
        id,
        timeout: transcriptionDeadlineFor(seconds),
      );
      if (_id != id || _disposed) return;
      final remote = _remote;
      if (remote != null) {
        if (bytes == null || bytes.isEmpty) {
          _emptyResult(VoiceInputEmptyResult.noRecording);
          return;
        }
        final text = await remote.transcribe(bytes);
        if (_id == id && !_disposed) _finish(text);
      }
      // Local stop completes through a final native event, including timeout.
    } catch (failure) {
      if (_id == id) _fail(failure);
    }
  }

  /// Media key: ends the round as a hands-free action (sent in conversation mode).
  Future<void> stopHandsFree() async {
    if (_id == null || _phase != VoiceInputPhase.recording) return;
    if (!vad) return stop();
    await vadRound!.stopHandsFree(
      transcribing: _vadTranscribing,
      finish: _finish,
      fail: _fail,
      noSpeech: () => _emptyResult(VoiceInputEmptyResult.noSpeech),
    );
  }

  void _vadTranscribing() {
    _timer?.cancel();
    _phase = VoiceInputPhase.transcribing;
    _notify();
  }

  void _finish(String transcript) {
    if (transcript.trim().isEmpty) {
      _emptyResult(VoiceInputEmptyResult.noSpeech);
      return;
    }
    final draft = _draft!;
    final callback = _onResult;
    finishedOnItsOwn = vad
        ? vadRound!.finishedOnItsOwn
        : !_stopRequested && _remote == null;
    final result = insertVoiceTranscript(draft, transcript.trim());
    _clear();
    callback?.call(result);
    _target = null;
    _notify();
  }

  void _fail(Object failure) {
    final id = _id;
    _notice = null;
    _error = voiceFailureMessage(failure);
    _target = null;
    _clear();
    _notify();
    if (id != null) unawaited(device.cancel(id).catchError((Object _) {}));
  }

  void _emptyResult(VoiceInputEmptyResult result) {
    final id = _id;
    if (id == null) return;
    _notice = (attempt: id, result: result);
    _error = null;
    _target = null;
    _clear();
    _notify();
    unawaited(device.cancel(id).catchError((Object _) {}));
  }

  void _clear() {
    _id = null;
    _timer?.cancel();
    _timer = null;
    _remote?.close();
    _remote = null;
    vadRound?.clear();
    _draft = null;
    _onResult = null;
    _phase = VoiceInputPhase.idle;
    _partial = '';
  }

  Future<void> cancel() async {
    _commandGeneration++;
    _target = null;
    final id = _id;
    _error = null;
    _notice = null;
    _clear();
    _notify();
    if (id != null) await device.cancel(id);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(cancel().catchError((Object _) {}));
    unawaited(_events.cancel());
    if (_notificationDepth == 0) super.dispose();
  }
}

VoiceDraft insertVoiceTranscript(VoiceDraft draft, String text) {
  final valid =
      draft.selectionStart >= 0 &&
      draft.selectionEnd >= draft.selectionStart &&
      draft.selectionEnd <= draft.text.length;
  final start = valid ? draft.selectionStart : draft.text.length;
  final end = valid ? draft.selectionEnd : draft.text.length;
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
  final cursor = start + leading.length + text.length;
  return VoiceDraft(
    text: draft.text.replaceRange(start, end, '$leading$text$trailing'),
    selectionStart: cursor,
    selectionEnd: cursor,
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
