import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../controllers/voice_output_controller.dart';
import '../services/android_voice.dart';
import '../services/device_preference.dart';
import '../services/voice_preferences.dart';
import '../services/voice_sample.dart';
import 'studio_error.dart';
import 'studio_select.dart';

class VoicePreferencesPage extends StatelessWidget {
  const VoicePreferencesPage({
    super.key,
    required this.preferences,
    this.openHermesSettings,
    this.hermesProfileLabel,
  });
  final SharedPreferences preferences;
  final VoidCallback? openHermesSettings;
  final String? hermesProfileLabel;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Voice')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: VoicePreferencesCard(
              preferences: preferences,
              openHermesSettings: openHermesSettings,
              hermesProfileLabel: hermesProfileLabel,
            ),
          ),
        ),
      ),
    ),
  );
}

class VoicePreferencesCard extends StatefulWidget {
  const VoicePreferencesCard({
    super.key,
    required this.preferences,
    this.openHermesSettings,
    this.hermesProfileLabel,
    this.device,
  });
  final SharedPreferences preferences;
  final VoidCallback? openHermesSettings;
  final String? hermesProfileLabel;
  final VoiceDevice? device;
  @override
  State<VoicePreferencesCard> createState() => _VoicePreferencesCardState();
}

class _VoicePreferencesCardState extends State<VoicePreferencesCard>
    with WidgetsBindingObserver {
  late VoicePreferences _preferences;
  late final _language = TextEditingController();
  late final _preview = VoiceOutputController(
    widget.device ?? AndroidVoice.instance,
  );
  AndroidVoiceCapabilities? _capabilities;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _preferences = VoicePreferences.read(widget.preferences);
    _language.text = _preferences.language;
    _preview.addListener(_changed);
    _load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final capabilities = await (widget.device ?? AndroidVoice.instance)
          .capabilities()
          .timeout(const Duration(seconds: 10));
      if (mounted) setState(() => _capabilities = capabilities);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load Android speech capabilities.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(String key, String value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _preview.stop();
      await saveDevicePreference(widget.preferences, key, value);
      if (mounted) {
        setState(
          () => _preferences = VoicePreferences.read(widget.preferences),
        );
      }
    } catch (_) {
      if (mounted) {
        showStudioError(
          context,
          'Could not save this voice setting. Please retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ({
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    }.contains(state)) {
      _preview.stop().catchError((Object _) {});
    } else if (state == AppLifecycleState.resumed) {
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _preview.dispose();
    _language.dispose();
    super.dispose();
  }

  Widget _engine(String title, String key, VoiceProcessing selected) =>
      StudioSelect<String>(
        key: ValueKey('$key-${selected.name}'),
        label: title,
        value: selected.name,
        options: const [
          (value: 'local', label: 'Local · Android'),
          (value: 'hermes', label: 'Hermes · server profile'),
        ],
        onChanged: _saving
            ? null
            : (value) {
                if (value != null) _save(key, value);
              },
      );
  Widget _languageChoice() {
    final installed = _capabilities?.installedLanguages;
    if (installed != null) {
      return StudioSelect<String>(
        key: ValueKey('voice-language-${_preferences.language}'),
        label: 'Recognition language',
        value: _preferences.language,
        options: [
          const (value: '', label: 'Device language'),
          for (final language in installed) (value: language, label: language),
          if (_preferences.language.isNotEmpty &&
              !installed.contains(_preferences.language))
            (
              value: _preferences.language,
              label: '${_preferences.language} · not installed',
            ),
        ],
        onChanged: _saving
            ? null
            : (value) {
                if (value != null) _save(VoicePreferences.languageKey, value);
              },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _language,
          enabled: !_saving,
          decoration: const InputDecoration(
            labelText: 'Recognition language',
            hintText: 'Device language',
            helperText:
                'Language tag, e.g. en-US. Empty uses the device language.',
            helperMaxLines: 3,
          ),
        ),
        const Text(
          'Android does not report installed recognition languages on this device. Unsupported choices will show an error when recording.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _saving
                ? null
                : () {
                    final value = _language.text.trim();
                    if (value.isNotEmpty &&
                        !RegExp(
                          r'^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*$',
                        ).hasMatch(value)) {
                      showStudioError(
                        context,
                        'Enter a language tag such as en-US.',
                      );
                      return;
                    }
                    _save(VoicePreferences.languageKey, value);
                  },
            child: const Text('Save language'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final voices = _capabilities?.voices ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Saved on this phone',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        _engine('Voice input', VoicePreferences.inputKey, _preferences.input),
        const SizedBox(height: 12),
        Text(
          _preferences.input == VoiceProcessing.local
              ? 'Transcribe on this phone. Review the text before sending.'
              : 'Send a recording to the selected Hermes profile and its speech provider. Review the text before sending.',
        ),
        if (_preferences.input == VoiceProcessing.local) ...[
          const SizedBox(height: 12),
          if (_capabilities?.recognitionAvailable == false)
            const Text(
              'On-device recognition is unavailable. It requires Android 12 or later and a supported speech service.',
            )
          else if (!_loading)
            _languageChoice(),
        ],
        const SizedBox(height: 24),
        _engine(
          'Voice output',
          VoicePreferences.outputKey,
          _preferences.output,
        ),
        const SizedBox(height: 12),
        Text(
          _preferences.output == VoiceProcessing.local
              ? 'Read aloud with an installed offline Android voice.'
              : 'Send reply text to the selected Hermes profile for speech generation.',
        ),
        SwitchListTile(
          key: const ValueKey('voice-auto-speak'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Spoken replies'),
          subtitle: const Text(
            'Read each finished reply aloud automatically while the chat is open.',
          ),
          value: _preferences.autoSpeak,
          onChanged: _saving
              ? null
              : (value) =>
                    _save(VoicePreferences.autoSpeakKey, value ? 'on' : 'off'),
        ),
        if (_preferences.output == VoiceProcessing.local && !_loading) ...[
          const SizedBox(height: 12),
          StudioSelect<String>(
            key: ValueKey('android-voice-${_preferences.voice}'),
            label: 'Android voice',
            value: _preferences.voice,
            options: [
              const (value: '', label: 'Offline voice for device language'),
              for (final voice in voices) (value: voice.id, label: voice.label),
              if (_preferences.voice.isNotEmpty &&
                  !voices.any((v) => v.id == _preferences.voice))
                (
                  value: _preferences.voice,
                  label: '${_preferences.voice} · unavailable',
                ),
            ],
            onChanged: _saving
                ? null
                : (value) {
                    if (value != null) {
                      _save(VoicePreferences.voiceKey, value);
                    }
                  },
          ),
          if (voices.isEmpty)
            const Text(
              'No installed offline voices found. Install voice data in Android text-to-speech settings, then refresh.',
            ),
          const SizedBox(height: 12),
          StudioSelect<String>(
            key: ValueKey('voice-rate-${_preferences.rate}'),
            label: 'Speaking speed',
            value: _preferences.rate.toString(),
            options: const [
              (value: '0.8', label: 'Slower'),
              (value: '1.0', label: 'Normal'),
              (value: '1.2', label: 'Faster'),
            ],
            onChanged: _saving
                ? null
                : (value) {
                    if (value != null) {
                      _save(VoicePreferences.rateKey, value);
                    }
                  },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _saving || voices.isEmpty
                  ? null
                  : () {
                      if (_preview.owner != null) {
                        _preview.stop();
                      } else {
                        _preview.speak(
                          'preview',
                          voiceSampleText,
                          VoicePreferences(
                            voice: _preferences.voice,
                            rate: _preferences.rate,
                          ),
                          () => throw StateError(
                            'Local preview cannot use Hermes.',
                          ),
                        );
                      }
                    },
              icon: Icon(
                _preview.owner == null ? Icons.volume_up_outlined : Icons.stop,
              ),
              label: Text(
                _preview.owner == null
                    ? 'Preview Android voice'
                    : 'Stop preview',
              ),
            ),
          ),
          if (_preview.error != null) StudioError(_preview.error!),
        ],
        if (_preferences.input == VoiceProcessing.hermes ||
            _preferences.output == VoiceProcessing.hermes) ...[
          const SizedBox(height: 12),
          Text(
            'Hermes speech settings belong to the selected server profile. ${widget.hermesProfileLabel == null ? 'Connect to a profile to open its settings.' : 'Current profile: ${widget.hermesProfileLabel}.'}',
          ),
          if (widget.openHermesSettings != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () async {
                  await _preview.stop();
                  if (mounted) widget.openHermesSettings?.call();
                },
                child: const Text('Open speech synthesis'),
              ),
            ),
        ],
        const SizedBox(height: 12),
        const Text(
          'Input and output are independent. Wing never switches processing engines automatically.',
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) StudioError(_error!),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _loading ? null : _load,
            child: const Text('Refresh Android voices and languages'),
          ),
        ),
      ],
    );
  }
}
