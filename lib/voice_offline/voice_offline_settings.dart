import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models/voice_processing_settings.dart';
import '../core/services/android_voice.dart';
import '../core/services/device_preference.dart';
import '../core/services/voice_preferences_session.dart';
import '../core/widgets/studio_error.dart';
import '../core/widgets/studio_select.dart';
import '../core/widgets/vad_settings_section.dart';
import 'barge_in_settings.dart';
import 'vad_voice_device.dart';
import 'voice_input_settings_for.dart';
import 'voice_offline_prefs.dart';

/// Which block of fork rows a [VoiceOfflineSettings] renders.
enum VoiceOfflineSettingsPart { replies }

/// Prepares or releases the on-device model when the Local engine changes.
Future<void> onVoiceInputRouteChanged(
  VoiceDevice device,
  bool wasParakeet,
  bool isParakeet,
) async {
  if (isParakeet == wasParakeet) return;
  try {
    await (isParakeet
        ? VadVoiceDevice.of(device).prepareVad()
        : VadVoiceDevice.of(device).releaseVad());
  } catch (_) {
    // The workspace owns media keys and retries on resume; settings stay saved.
  }
}

/// The fork prefs of one voice settings session, shared by every fork row
/// block and the card's language rows, so an engine change reaches all of
/// them at once.
class VoiceOfflineModel extends ValueNotifier<VoiceOfflinePrefs> {
  VoiceOfflineModel() : super(const VoiceOfflinePrefs());

  static final _models = Expando<VoiceOfflineModel>();

  static VoiceOfflineModel of(VoicePreferencesSession session) {
    final existing = _models[session];
    if (existing != null) return existing;
    final model = _models[session] = VoiceOfflineModel();
    SharedPreferences.getInstance().then(
      (preferences) => model.value = VoiceOfflinePrefs.read(preferences),
      onError: (_) {},
    );
    return model;
  }
}

/// Fork (Wing Voice): rebuilds [builder] with whether the Local engine is
/// Parakeet, which does not use the Android recognizer's language.
class VoiceOfflineEngineBuilder extends StatelessWidget {
  const VoiceOfflineEngineBuilder({
    super.key,
    required this.session,
    required this.builder,
  });

  final VoicePreferencesSession session;
  final Widget Function(BuildContext context, bool parakeet) builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: VoiceOfflineModel.of(session),
    builder: (context, offline, _) =>
        builder(context, offline.localEngine == VoiceLocalEngine.parakeet),
  );
}

/// Loads the device preferences once and saves one row at a time. Each row
/// block owns its own `_saving`; the prefs themselves live in the session's
/// [VoiceOfflineModel].
mixin _ForkRows<T extends StatefulWidget> on State<T> {
  SharedPreferences? _preferences;
  VoiceOfflinePrefs _offline = const VoiceOfflinePrefs();
  bool _saving = false;
  VoiceOfflineModel? _model;

  void _modelChanged() {
    if (mounted) setState(() => _offline = _model!.value);
  }

  Future<void> _load(VoicePreferencesSession session) async {
    final model = _model = VoiceOfflineModel.of(session);
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    model.addListener(_modelChanged);
    model.value = VoiceOfflinePrefs.read(preferences);
    setState(() {
      _preferences = preferences;
      _offline = model.value;
    });
  }

  @override
  void dispose() {
    _model?.removeListener(_modelChanged);
    super.dispose();
  }

  Future<void> _save(String key, String value) async {
    final preferences = _preferences;
    if (_saving || preferences == null) return;
    setState(() => _saving = true);
    try {
      await saveDevicePreference(preferences, key, value);
      _model?.value = VoiceOfflinePrefs.read(preferences);
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
}

/// Fork rows under the Local voice input: the recognition engine and, for
/// Parakeet, the microphone and end-of-speech settings.
class VoiceOfflineInputRows extends StatefulWidget {
  const VoiceOfflineInputRows({super.key, required this.session});

  final VoicePreferencesSession session;

  @override
  State<VoiceOfflineInputRows> createState() => _VoiceOfflineInputRowsState();
}

class _VoiceOfflineInputRowsState extends State<VoiceOfflineInputRows>
    with _ForkRows<VoiceOfflineInputRows> {
  @override
  void initState() {
    super.initState();
    _load(widget.session);
  }

  Future<void> _chooseEngine(VoiceLocalEngine engine) async {
    final was = _offline.localEngine == VoiceLocalEngine.parakeet;
    await _save(VoiceOfflinePrefs.localEngineKey, engine.name);
    if (!mounted) return;
    final now = _offline.localEngine == VoiceLocalEngine.parakeet;
    await onVoiceInputRouteChanged(widget.session.device, was, now);
  }

  @override
  Widget build(BuildContext context) {
    if (_preferences == null) return const SizedBox.shrink();
    final parakeet = _offline.localEngine == VoiceLocalEngine.parakeet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudioSelect<VoiceLocalEngine>(
          key: ValueKey('voice-local-engine-${_offline.localEngine.name}'),
          label: 'Recognition engine',
          value: _offline.localEngine,
          options: const [
            (value: VoiceLocalEngine.system, label: 'Android system recognizer'),
            (value: VoiceLocalEngine.parakeet, label: 'Parakeet on this phone'),
          ],
          onChanged: _saving
              ? null
              : (value) {
                  if (value != null) _chooseEngine(value);
                },
        ),
        if (parakeet) ...[
          const SizedBox(height: 12),
          StudioSelect<String>(
            key: ValueKey('voice-mic-route-${_offline.micRoute.name}'),
            label: 'Microphone',
            value: _offline.micRoute.name,
            options: const [
              (value: 'auto', label: 'Automatic'),
              (value: 'phone', label: 'Phone mic'),
              (value: 'bluetooth', label: 'Bluetooth device'),
              (value: 'wired', label: 'Wired headset'),
            ],
            onChanged: _saving
                ? null
                : (value) {
                    if (value != null) {
                      _save(VoiceOfflinePrefs.micRouteKey, value);
                    }
                  },
          ),
          const SizedBox(height: 12),
          Text(
            _offline.micRoute == VoiceMicRoute.auto
                ? 'Prefers a connected Bluetooth or wired headset mic, otherwise the phone.'
                : 'If this microphone is not connected when recording starts, Wing uses Automatic instead.',
          ),
          const SizedBox(height: 12),
          VadSettingsSection(
            settings: _offline,
            device: widget.session.device,
            saving: _saving,
            onSave: _save,
          ),
        ],
      ],
    );
  }
}

/// Fork rows of the voice settings card that follow the output choice:
/// spoken replies, conversation mode, barge-in.
class VoiceOfflineSettings extends StatefulWidget {
  const VoiceOfflineSettings({
    super.key,
    required this.part,
    required this.session,
  });

  final VoiceOfflineSettingsPart part;
  final VoicePreferencesSession session;

  @override
  State<VoiceOfflineSettings> createState() => _VoiceOfflineSettingsState();
}

class _VoiceOfflineSettingsState extends State<VoiceOfflineSettings>
    with _ForkRows<VoiceOfflineSettings> {
  @override
  void initState() {
    super.initState();
    _load(widget.session);
  }

  @override
  Widget build(BuildContext context) {
    final preferences = _preferences;
    if (preferences == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: widget.session.state,
      builder: (context, _) {
        final app = widget.session.preferences;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: switch (widget.part) {
            VoiceOfflineSettingsPart.replies => [
              SwitchListTile(
                key: const ValueKey('voice-auto-speak'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Spoken replies'),
                subtitle: const Text(
                  'Read each finished reply aloud automatically while the chat is open.',
                ),
                value: _offline.autoSpeak,
                onChanged: _saving
                    ? null
                    : (value) => _save(
                        VoiceOfflinePrefs.autoSpeakKey,
                        value ? 'on' : 'off',
                      ),
              ),
              SwitchListTile(
                key: const ValueKey('voice-conversation'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Conversation mode'),
                subtitle: const Text(
                  'Send dictation when you stop speaking, read the reply aloud and '
                  'listen again. Stop, Cancel or silence ends the conversation.',
                ),
                value: _offline.conversation,
                onChanged: _saving
                    ? null
                    : (value) => _save(
                        VoiceOfflinePrefs.conversationKey,
                        value ? 'on' : 'off',
                      ),
              ),
              BargeInSettings(
                vad:
                    voiceInputSettingsFor(app, preferences)
                        is VadVoiceInputSettings,
                output: app.current.localVoiceOutputSettings,
                offline: _offline,
                device: widget.session.device,
                saving: _saving,
                onSave: _save,
              ),
            ],
          },
        );
      },
    );
  }
}
