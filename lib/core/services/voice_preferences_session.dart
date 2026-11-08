import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../controllers/voice_output_controller.dart';
import '../models/app_preferences.dart';
import 'android_voice.dart';
import 'app_preferences.dart';
import 'voice_sample.dart';

class VoicePreferencesPresentation {
  VoicePreferencesPresentation({
    required this.liveMode,
    required this.liveVoice,
    required this.liveVoices,
    required this.input,
    required this.output,
    required this.language,
    required this.voice,
    required this.rate,
    required Iterable<({String value, String label})> languages,
    required Iterable<({String value, String label})> voices,
    required this.showLanguage,
    required this.manualLanguage,
    required this.languageUnavailableNotice,
    required this.saveManualLanguage,
    required this.showLocalOutput,
    required this.noVoicesNotice,
    required this.inputDescription,
    required this.outputDescription,
    required this.hermesDescription,
    required this.openHermesSettings,
    required this.loading,
    required this.capabilityError,
    required this.operationError,
    required this.previewError,
    required this.previewActive,
    required this.preview,
    required this.refresh,
  }) : languages = List.unmodifiable(languages),
       voices = List.unmodifiable(voices);

  final AppPreferenceControl<LiveVoiceMode> liveMode;
  final AppPreferenceControl<String>? liveVoice;
  final List<({String value, String label})> liveVoices;
  final AppPreferenceControl<AppVoiceProcessing> input;
  final AppPreferenceControl<AppVoiceProcessing> output;
  final AppPreferenceControl<String> language;
  final AppPreferenceControl<String> voice;
  final AppPreferenceControl<AppVoiceRate> rate;
  final List<({String value, String label})> languages;
  final List<({String value, String label})> voices;
  final bool showLanguage;
  final bool manualLanguage;
  final String? languageUnavailableNotice;
  final Future<bool> Function(String)? saveManualLanguage;
  final bool showLocalOutput;
  final String? noVoicesNotice;
  final String? inputDescription;
  final String? outputDescription;
  final String? hermesDescription;
  final VoidCallback? openHermesSettings;
  final bool loading;
  final String? capabilityError;
  final String? operationError;
  final String? previewError;
  final bool previewActive;
  final VoidCallback? preview;
  final VoidCallback? refresh;
}

/// Route-owned capability and preview lifetime. Saved facts and storage commands
/// stay with the borrowed app preference owner.
class VoicePreferencesSession {
  VoicePreferencesSession({
    required this.preferences,
    required VoiceDevice device,
    required this.hermesProfileLabel,
    required this.openHermesSettings,
  }) : _device = device,
       _preview = VoiceOutputController(device) {
    _presentation = ValueNotifier(_state());
    preferences.state.addListener(_publish);
    _preview.addListener(_publish);
    unawaited(refresh());
  }

  final AppPreferences preferences;
  final VoiceDevice _device;
  final VoiceOutputController _preview;
  final String? hermesProfileLabel;
  final VoidCallback? openHermesSettings;
  late final ValueNotifier<VoicePreferencesPresentation> _presentation;
  AndroidVoiceCapabilities? _capabilities;
  int _capabilityGeneration = 0;
  int _commandGeneration = 0;
  bool _loading = true;
  bool _choosing = false;
  bool _foreground = true;
  bool _closed = false;
  String? _capabilityError;
  String? _operationError;
  String? _manualLanguageError;

  ValueListenable<VoicePreferencesPresentation> get state => _presentation;
  VoicePreferencesPresentation get current => _presentation.value;

  AppPreferenceControl<T> _control<T>(
    AppPreferenceControl<T> Function(AppPreferencesState) select, {
    String? error,
  }) {
    final original = select(preferences.current);
    return AppPreferenceControl(
      selected: original.selected,
      busy: original.busy || _choosing,
      notice: original.notice,
      error: error ?? original.error,
      choose: _closed || !_foreground || _choosing || original.choose == null
          ? null
          : (value) => _choose(value, select),
    );
  }

  VoicePreferencesPresentation _state() {
    final input = _control((state) => state.voiceInput);
    final output = _control((state) => state.voiceOutput);
    final language = _control(
      (state) => state.voiceLanguage,
      error: _manualLanguageError,
    );
    final voice = _control((state) => state.voice);
    final rate = _control((state) => state.voiceRate);
    final installed = _capabilities?.installedLanguages;
    final voiceRows = _capabilities?.voices ?? const [];
    final languageNeedsRepair = language.notice != null;
    final localOutputNeedsRepair = voice.notice != null || rate.notice != null;
    final showLanguage =
        !_loading &&
        ((input.selected == AppVoiceProcessing.local &&
                _capabilities?.recognitionAvailable != false) ||
            languageNeedsRepair);
    final showLocalOutput =
        !_loading &&
        (output.selected == AppVoiceProcessing.local || localOutputNeedsRepair);
    final canPreview =
        _foreground &&
        !_closed &&
        !_choosing &&
        output.selected == AppVoiceProcessing.local &&
        voiceRows.isNotEmpty &&
        preferences.current.localVoiceOutputSettings != null;
    final usesHermes =
        input.selected == AppVoiceProcessing.hermes ||
        output.selected == AppVoiceProcessing.hermes;
    final liveMode = preferences.current.liveVoiceMode.selected;
    return VoicePreferencesPresentation(
      liveMode: _control((state) => state.liveVoiceMode),
      liveVoice: liveMode == null
          ? null
          : _control((state) => state.liveVoiceFor(liveMode)),
      liveVoices: List.unmodifiable([
        for (final value in liveMode?.voices ?? <String>[])
          (value: value, label: value[0].toUpperCase() + value.substring(1)),
      ]),
      input: input,
      output: output,
      language: language,
      voice: voice,
      rate: rate,
      languages: [
        const (value: '', label: 'Device language'),
        for (final value in installed ?? const <String>[])
          (value: value, label: value),
        if (language.selected case final String value
            when value.isNotEmpty &&
                installed != null &&
                !installed.contains(value))
          (value: value, label: '$value · not installed'),
      ],
      voices: [
        const (value: '', label: 'Offline voice for device language'),
        for (final row in voiceRows) (value: row.id, label: row.label),
        if (voice.selected case final String value
            when value.isNotEmpty && !voiceRows.any((row) => row.id == value))
          (value: value, label: '$value · unavailable'),
      ],
      showLanguage: showLanguage,
      manualLanguage: installed == null,
      languageUnavailableNotice:
          input.selected == AppVoiceProcessing.local &&
              !_loading &&
              _capabilities?.recognitionAvailable == false
          ? 'On-device recognition is unavailable. It requires Android 12 or later and a supported speech service.'
          : null,
      saveManualLanguage: showLanguage && language.choose != null
          ? _saveManualLanguage
          : null,
      showLocalOutput: showLocalOutput,
      noVoicesNotice: showLocalOutput && voiceRows.isEmpty
          ? 'No installed offline voices found. Install voice data in Android text-to-speech settings, then refresh.'
          : null,
      inputDescription: switch (input.selected) {
        AppVoiceProcessing.local =>
          'Transcribe on this phone. Review the text before sending.',
        AppVoiceProcessing.hermes =>
          'Send a recording to the selected Hermes profile and its speech provider. Review the text before sending.',
        null => null,
      },
      outputDescription: switch (output.selected) {
        AppVoiceProcessing.local =>
          'Read aloud with an installed offline Android voice.',
        AppVoiceProcessing.hermes =>
          'Send reply text to the selected Hermes profile for speech generation.',
        null => null,
      },
      hermesDescription: usesHermes
          ? 'Hermes speech settings belong to the selected server profile. ${hermesProfileLabel == null ? 'Connect to a profile to open its settings.' : 'Current profile: $hermesProfileLabel.'}'
          : null,
      openHermesSettings:
          usesHermes && openHermesSettings != null && _foreground && !_choosing
          ? () => unawaited(_openProfileSettings())
          : null,
      loading: _loading,
      capabilityError: _capabilityError,
      operationError: _operationError,
      previewError: _preview.error,
      previewActive: _preview.owner != null,
      preview: canPreview ? () => unawaited(_togglePreview()) : null,
      refresh: !_loading && !_closed && _foreground
          ? () => unawaited(refresh())
          : null,
    );
  }

  void _publish() {
    if (!_closed) _presentation.value = _state();
  }

  Future<void> refresh() async {
    if (_closed || !_foreground) return;
    final generation = ++_capabilityGeneration;
    _loading = true;
    _capabilityError = null;
    _publish();
    try {
      final result = await _device.capabilities().timeout(
        const Duration(seconds: 10),
      );
      if (_closed || !_foreground || generation != _capabilityGeneration) {
        return;
      }
      _capabilities = AndroidVoiceCapabilities(
        recognitionAvailable: result.recognitionAvailable,
        installedLanguages: result.installedLanguages == null
            ? null
            : List.unmodifiable(result.installedLanguages!),
        voices: List.unmodifiable(result.voices),
      );
    } catch (_) {
      if (!_closed && generation == _capabilityGeneration) {
        _capabilityError = 'Could not load Android speech capabilities.';
      }
    } finally {
      if (!_closed && generation == _capabilityGeneration) {
        _loading = false;
        _publish();
      }
    }
  }

  Future<bool> _choose<T>(
    T value,
    AppPreferenceControl<T> Function(AppPreferencesState) select,
  ) async {
    if (_closed || !_foreground || _choosing) return false;
    if (select(preferences.current).choose == null) return false;
    final generation = _commandGeneration;
    _choosing = true;
    _operationError = null;
    _publish();
    try {
      await _preview.stop();
      if (_closed || !_foreground || generation != _commandGeneration) {
        return false;
      }
      final choose = select(preferences.current).choose;
      if (choose == null) return false;
      return await choose(value);
    } catch (_) {
      if (!_closed) {
        _operationError = 'Could not stop voice preview. Please retry.';
      }
      return false;
    } finally {
      _choosing = false;
      _publish();
    }
  }

  Future<bool> _saveManualLanguage(String input) {
    final value = input.trim();
    if (value.isNotEmpty &&
        !RegExp(r'^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*$').hasMatch(value)) {
      _manualLanguageError = 'Enter a language tag such as en-US.';
      _publish();
      return Future.value(false);
    }
    _manualLanguageError = null;
    return _choose(value, (state) => state.voiceLanguage);
  }

  Future<void> _togglePreview() async {
    if (_closed || !_foreground || current.preview == null) return;
    if (_preview.owner != null) {
      try {
        await _preview.stop();
      } catch (_) {
        if (!_closed) {
          _operationError = 'Could not stop voice preview. Please retry.';
          _publish();
        }
      }
      return;
    }
    final settings = preferences.current.localVoiceOutputSettings;
    if (settings == null) return;
    await _preview.speak(
      'preview',
      voiceSampleText,
      settings,
      () => throw StateError('Local preview cannot use Hermes.'),
    );
  }

  Future<void> _openProfileSettings() async {
    final open = openHermesSettings;
    if (_closed || !_foreground || _choosing || open == null) {
      return;
    }
    final generation = _commandGeneration;
    try {
      await _preview.stop();
      if (_closed || !_foreground || generation != _commandGeneration) return;
      open();
    } catch (_) {
      if (!_closed) {
        _operationError = 'Could not open speech settings.';
        _publish();
      }
    }
  }

  void lifecycle(AppLifecycleState state) {
    if (_closed) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        unawaited(refresh());
      case AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached:
        if (!_foreground) return;
        _foreground = false;
        _commandGeneration++;
        _capabilityGeneration++;
        _loading = false;
        unawaited(_preview.stop().catchError((Object _) {}));
        _publish();
      case AppLifecycleState.inactive:
        break;
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _commandGeneration++;
    _capabilityGeneration++;
    preferences.state.removeListener(_publish);
    _preview.removeListener(_publish);
    _preview.dispose();
    _presentation.dispose();
  }
}
