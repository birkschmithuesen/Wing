import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/android_voice.dart';
import '../core/services/device_preference.dart';
import '../core/services/voice_preferences.dart';
import '../core/widgets/studio_error.dart';
import '../core/widgets/studio_select.dart';
import '../core/widgets/vad_settings_section.dart';
import 'barge_in_settings.dart';
import 'vad_voice_device.dart';
import 'voice_offline_prefs.dart';

/// Which block of fork rows a [VoiceOfflineSettings] renders. The rows sit at
/// two positions of the voice card, so there are two parts.
enum VoiceOfflineSettingsPart { vadRoute, replies }

/// The "Recognize on this phone" choice of the input select.
({String value, String label}) vadInputChoice(BuildContext context) =>
    (value: 'vad', label: 'On this phone · Parakeet');

/// Prepares or releases the on-device model when the input route changes.
Future<void> onVoiceInputRouteChanged(
  VoiceDevice device,
  VoiceInputRoute from,
  VoiceInputRoute to,
) async {
  final wasVad = from == VoiceInputRoute.vad;
  final isVad = to == VoiceInputRoute.vad;
  if (isVad == wasVad) return;
  try {
    await (isVad
        ? VadVoiceDevice.of(device).prepareVad()
        : VadVoiceDevice.of(device).releaseVad());
  } catch (_) {
    // The workspace owns media keys and retries on resume; settings stay saved.
  }
}

/// Fork rows of the voice settings card: mic route, VAD settings, spoken
/// replies, conversation mode, barge-in. Rendered at the positions they had
/// in the card.
class VoiceOfflineSettings extends StatefulWidget {
  const VoiceOfflineSettings({
    super.key,
    required this.preferences,
    required this.device,
    required this.route,
    required this.part,
    this.saving = false,
    this.onSaving,
    this.stopPreview,
  });

  final SharedPreferences preferences;
  final VoiceDevice device;
  final VoiceInputRoute route;
  final VoiceOfflineSettingsPart part;

  /// True while the card saves one of its own rows.
  final bool saving;

  /// Reports that a fork row starts or finishes saving, so the card disables
  /// its rows meanwhile.
  final ValueChanged<bool>? onSaving;

  /// Stops a running voice preview before a setting is written.
  final Future<void> Function()? stopPreview;

  @override
  State<VoiceOfflineSettings> createState() => _VoiceOfflineSettingsState();
}

class _VoiceOfflineSettingsState extends State<VoiceOfflineSettings> {
  late VoiceOfflinePrefs _offline;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _offline = VoiceOfflinePrefs.read(widget.preferences);
  }

  Future<void> _save(String key, String value) async {
    if (_saving || widget.saving) return;
    setState(() => _saving = true);
    widget.onSaving?.call(true);
    try {
      await widget.stopPreview?.call();
      await saveDevicePreference(widget.preferences, key, value);
      if (mounted) {
        setState(() => _offline = VoiceOfflinePrefs.read(widget.preferences));
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
      widget.onSaving?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saving = _saving || widget.saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: switch (widget.part) {
        VoiceOfflineSettingsPart.vadRoute => [
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
            onChanged: saving
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
            device: widget.device,
            saving: saving,
            onSave: _save,
          ),
        ],
        VoiceOfflineSettingsPart.replies => [
          SwitchListTile(
            key: const ValueKey('voice-auto-speak'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Spoken replies'),
            subtitle: const Text(
              'Read each finished reply aloud automatically while the chat is open.',
            ),
            value: _offline.autoSpeak,
            onChanged: saving
                ? null
                : (value) =>
                      _save(VoiceOfflinePrefs.autoSpeakKey, value ? 'on' : 'off'),
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
            onChanged: saving
                ? null
                : (value) => _save(
                    VoiceOfflinePrefs.conversationKey,
                    value ? 'on' : 'off',
                  ),
          ),
          BargeInSettings(
            settings: VoicePreferences.read(widget.preferences),
            offline: _offline,
            device: widget.device,
            saving: saving,
            onSave: _save,
          ),
        ],
      },
    );
  }
}
