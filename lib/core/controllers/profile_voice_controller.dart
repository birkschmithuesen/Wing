import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/profile_voice.dart';
import '../models/settings_edit.dart';
import '../models/profile_tool_setup.dart';
import '../models/voice_processing_settings.dart';
import '../services/administration_repository.dart';
import '../services/administration_operation_session.dart';
import '../services/profile_voice_repository.dart';
import '../services/android_voice.dart';
import '../services/voice_sample.dart';
import '../services/workspace_connection_failure.dart';
import 'voice_output_controller.dart';

/// One captured route's configuration, provider workflow and sample playback.
/// Autosave targets admitted before retirement retain their exact write authority.
class ProfileVoiceController extends ChangeNotifier {
  ProfileVoiceController(
    ProfileVoiceRepository repository, {
    required VoiceDevice device,
  }) : _repository = repository,
       _player = VoiceOutputController(device) {
    _player.addListener(_notify);
  }
  final ProfileVoiceRepository _repository;
  final VoiceOutputController _player;
  String get scopeLabel => _repository.scopeLabel;
  ProfileVoiceSettings? _settings;
  List<ProfileVoiceChoice> _choices = const [];
  List<AdminField> _defaults = const [];
  ToolSetupReadiness? _readiness;
  String? _selected, _error, _catalogueError, _voiceAcknowledged;
  ProfileVoicePhase _phase = ProfileVoicePhase.idle;
  bool _fresh = false, _disposed = false, _retryable = false;
  bool get canRecoverRead => !_disposed && !state.busy && _retryable;
  String _readError(Object error) => error is FormatException
      ? 'The server returned an invalid response.'
      : administrationError(error);
  int _generation = 0, _previewGeneration = 0, _notificationDepth = 0;
  ProfileVoiceSaveTarget? _pendingTarget;
  Future<void>? _pendingSave;
  ProfileVoiceState get state => ProfileVoiceState(
    settings: _settings,
    selected: _selected,
    choices: _choices,
    defaults: _defaults,
    readiness: _readiness,
    phase: _phase,
    fresh: _fresh,
    error: _error,
    catalogueError: _catalogueError,
    voiceAcknowledged: _voiceAcknowledged,
    playing: _player.owner != null,
    preparing: _player.preparing,
    playbackError: _player.error,
  );
  bool _live(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (_disposed) return;
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  Future<void> stopPreview() async {
    _previewGeneration++;
    try {
      await _player.stop();
    } catch (_) {
      // Native playback may already have ended.
    }
  }

  Future<void> play() async {
    if (_disposed) return;
    if (state.playing) {
      await stopPreview();
      return;
    }
    if (!state.canPlay || _settings == null) return;
    final expected = _settings!;
    final generation = _previewGeneration;
    await _player.speak(
      'profile-voice',
      voiceSampleText,
      const HermesVoiceOutputSettings(),
      () => _repository.speech(
        expected,
        canDispatch: () =>
            !_disposed && generation == _previewGeneration && state.enabled,
      ),
    );
  }

  Future<void> _read(int generation, {required bool defaultsOnly}) async {
    final configuration = await _repository.load();
    if (!_live(generation)) return;
    ToolSetupReadiness? readiness;
    if (!defaultsOnly) {
      readiness = await _repository.readiness();
      if (!_live(generation)) return;
    }
    _settings = configuration.speech;
    _defaults = configuration.defaults;
    _selected = _settings!.voice;
    _readiness = readiness;
    _choices = const [];
    _fresh = true;
    _notify();
    if (!_live(generation) || defaultsOnly) return;
    try {
      final choices = await _repository.choices(_settings!.provider);
      if (_live(generation)) _choices = List.unmodifiable(choices);
    } catch (error) {
      if (_live(generation)) _catalogueError = administrationError(error);
    }
  }

  Future<void> load() => _load(defaultsOnly: false);
  Future<void> loadDefaults() => _load(defaultsOnly: true);
  Future<void> _load({required bool defaultsOnly}) async {
    if (_disposed || state.busy) return;
    final generation = ++_generation;
    _phase = ProfileVoicePhase.loading;
    _fresh = false;
    _error = null;
    _catalogueError = null;
    _retryable = false;
    _notify();
    try {
      if (!_live(generation)) return;
      await stopPreview();
      if (!_live(generation)) return;
      await _read(generation, defaultsOnly: defaultsOnly);
    } catch (error) {
      if (_live(generation)) {
        _fresh = false;
        _error = _readError(error);
        _retryable = isTemporaryWorkspaceFailure(error);
      }
    } finally {
      if (_live(generation)) {
        _phase = ProfileVoicePhase.idle;
        _notify();
      }
    }
  }

  Future<void> selectCustom(String text) {
    if (text.trim().isEmpty || text.trim() == _selected) return Future.value();
    return select(text);
  }

  Future<void> select(String voice) {
    voice = voice.trim();
    if (_disposed || !state.canSelectVoice) return Future.value();
    if (voice.isEmpty || voice.length > 256) {
      _error = 'Enter a voice ID of 1–256 characters.';
      _notify();
      return Future.value();
    }
    if (_pendingSave == null && voice == _settings!.voice) {
      _selected = voice;
      _error = null;
      unawaited(stopPreview());
      _notify();
      return Future.value();
    }
    final target = _repository.admitVoice(voice);
    _pendingTarget?.close();
    _pendingTarget = target;
    _selected = voice;
    _error = null;
    final existing = _pendingSave;
    if (existing != null) {
      unawaited(stopPreview());
      _notify();
      return existing;
    }
    final completion = Completer<void>();
    _pendingSave = completion.future;
    _phase = ProfileVoicePhase.savingVoice;
    // Reserve the drain before a listener can submit another exact target.
    unawaited(stopPreview());
    _notify();
    unawaited(_saveLatest(completion));
    return completion.future;
  }

  Future<void> _saveLatest(Completer<void> completion) async {
    try {
      while (_pendingTarget != null) {
        final target = _pendingTarget!;
        _pendingTarget = null;
        var acknowledged = false;
        try {
          if (target.voice != _settings!.voice) {
            final saved = await _repository.save(
              _settings!,
              target,
              onAcknowledged: (voice) {
                acknowledged = true;
                _voiceAcknowledged = voice;
              },
            );
            _settings = saved;
          }
          if (_pendingTarget == null) _selected = _settings!.voice;
          _notify();
        } catch (error) {
          _pendingTarget?.close();
          _pendingTarget = null;
          _selected = _settings!.voice;
          _fresh = false;
          _error = acknowledged
              ? 'Voice saved. Current settings could not be confirmed. Refresh before trying again.'
              : error is AdministrationFailure &&
                    error.message.contains('changed elsewhere')
              ? error.message
              : 'Save not confirmed. Refresh before trying again.';
          break;
        } finally {
          target.close();
        }
      }
    } finally {
      _pendingSave = null;
      _phase = ProfileVoicePhase.idle;
      _notify();
      completion.complete();
    }
  }

  Future<void> selectProvider(String name) async {
    final opening = _readiness?.provider(name);
    if (_disposed ||
        !state.enabled ||
        opening == null ||
        opening == state.provider) {
      return;
    }
    final generation = ++_generation;
    _phase = ProfileVoicePhase.changingProvider;
    _fresh = false;
    _error = null;
    _catalogueError = null;
    _retryable = false;
    var dispatched = false, acknowledged = false;
    _notify();
    try {
      if (!_live(generation)) return;
      await stopPreview();
      if (!_live(generation)) return;
      await _repository.selectProvider(
        opening,
        canDispatch: () => _live(generation),
        onDispatched: () => dispatched = true,
      );
      acknowledged = true;
      if (!_live(generation)) return;
      await _read(generation, defaultsOnly: false);
      if (!_live(generation)) return;
      final expected = opening.requiresAccount
          ? 'nous'
          : opening.speechProvider;
      if (_settings?.provider != expected) {
        throw const AdministrationFailure(
          'Provider selection saved, but current settings differ. Refresh to continue.',
        );
      }
    } catch (error) {
      if (_live(generation)) {
        _fresh = false;
        _error = acknowledged
            ? error is AdministrationFailure
                  ? error.message
                  : 'Provider selection saved. Readiness is unavailable; refresh to check it.'
            : dispatched
            ? 'Provider selection could not be confirmed. Refresh to continue.'
            : administrationError(error);
      }
    } finally {
      if (_live(generation)) {
        _phase = ProfileVoicePhase.idle;
        _notify();
      }
    }
  }

  Future<void> reviewCredentials(
    ToolSetupCredential credential,
    Future<void> Function() open,
  ) async {
    if (_disposed ||
        !state.canReviewCredentials ||
        !(_readiness?.providers.any(
              (row) =>
                  row.credentials.any((field) => identical(field, credential)),
            ) ??
            false)) {
      return;
    }
    final generation = ++_generation;
    _phase = ProfileVoicePhase.reviewingCredentials;
    _error = null;
    _notify();
    try {
      if (!_live(generation)) return;
      await stopPreview();
      if (!_live(generation)) return;
      await open();
      if (!_live(generation)) return;
      _fresh = false;
      _catalogueError = null;
      await _read(generation, defaultsOnly: false);
    } catch (error) {
      if (_live(generation)) {
        _fresh = false;
        _error = _readError(error);
        _retryable = isTemporaryWorkspaceFailure(error);
      }
    } finally {
      if (_live(generation)) {
        _phase = ProfileVoicePhase.idle;
        _notify();
      }
    }
  }

  Future<void> setup(
    String key, {
    required Future<bool> Function() confirm,
    required Future<void> Function(AdministrationOperationSession) openResult,
  }) async {
    if (_disposed ||
        !state.enabled ||
        !(_readiness?.providers.any((row) => row.setupKey == key) ?? false)) {
      return;
    }
    final generation = ++_generation;
    _phase = ProfileVoicePhase.confirmingSetup;
    _notify();
    var dispatched = false, acknowledged = false;
    try {
      if (!_live(generation) || !await confirm() || !_live(generation)) return;
      _phase = ProfileVoicePhase.runningSetup;
      _fresh = false;
      _error = null;
      _notify();
      if (!_live(generation)) return;
      await stopPreview();
      if (!_live(generation)) return;
      final operation = await _repository.setup(
        key,
        canDispatch: () => _live(generation),
        onDispatched: () => dispatched = true,
      );
      acknowledged = true;
      try {
        if (!_live(generation)) return;
        await openResult(operation);
        if (!_live(generation)) return;
        _catalogueError = null;
        await _read(generation, defaultsOnly: false);
      } finally {
        operation.dispose();
      }
    } catch (error) {
      if (_live(generation)) {
        _fresh = false;
        _error = acknowledged
            ? 'Setup started. Readiness is unavailable; refresh to check it.'
            : dispatched
            ? 'Setup could not be confirmed. Refresh and review before trying again.'
            : administrationError(error);
      }
    } finally {
      if (_live(generation)) {
        _phase = ProfileVoicePhase.idle;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _previewGeneration++;
    _player.removeListener(_notify);
    // Retirement may originate in a native-player notification. Revoke route
    // authority now; dispose the child notifier after that callback unwinds.
    if (_notificationDepth == 0) {
      _player.dispose();
    } else {
      scheduleMicrotask(_player.dispose);
    }
    // Existing exact targets retain their admitted leases; no new target is issued.
    _repository.dispose();
    if (_notificationDepth == 0) super.dispose();
  }
}
