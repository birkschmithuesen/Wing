import 'dart:async';

import 'package:flutter/material.dart';

import '../core/controllers/voice_output_controller.dart';
import '../core/services/android_voice.dart';
import '../core/services/voice_preferences.dart';
import '../core/widgets/compact_switch.dart';
import '../core/widgets/studio_error.dart';
import '../core/widgets/studio_select.dart';
import 'barge_in_policy.dart';
import 'turn_listener.dart';

/// Conversation-mode rows for listening while Hermes works, and the debug
/// echo probe. Shown only on the vad route with Conversation mode on.
class BargeInSettings extends StatefulWidget {
  const BargeInSettings({
    super.key,
    required this.settings,
    required this.device,
    required this.saving,
    required this.onSave,
  });

  final VoicePreferences settings;
  final VoiceDevice device;
  final bool saving;
  final Future<void> Function(String key, String value) onSave;

  @override
  State<BargeInSettings> createState() => _BargeInSettingsState();
}

class _BargeInSettingsState extends State<BargeInSettings> {
  TurnListener? _listener;
  VoiceOutputController? _output;
  bool _probing = false;

  @override
  void dispose() {
    _output?.dispose();
    _listener?.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final listener = _listener ??= TurnListener(device: widget.device);
    final output = _output ??= VoiceOutputController(widget.device);
    final settings = widget.settings;
    setState(() => _probing = true);
    try {
      await listener.probe(settings, () async {
        await output.speak(
          'echo-probe',
          echoProbeText,
          VoicePreferences(voice: settings.voice, rate: settings.rate),
          () => throw StateError('The echo probe uses the Android voice.'),
        );
      });
    } catch (_) {
      if (mounted) {
        showStudioError(context, 'The echo measurement failed. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  /// '400' → '0.4 s'.
  String _seconds(String ms) {
    final text = (int.parse(ms) / 1000).toString();
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} s';
  }

  void _toggle(String key, bool on) =>
      unawaited(widget.onSave(key, on ? 'on' : 'off'));

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    if (s.input != VoiceInputRoute.vad || !s.conversation) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CompactSwitchListTile(
          key: const ValueKey('voice-listen-turn'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Listen while Hermes works'),
          subtitle: const Text('Speak to steer the running reply'),
          value: s.listenTurn,
          onChanged: widget.saving
              ? null
              : (value) => _toggle(VoicePreferences.listenTurnKey, value),
        ),
        if (s.listenTurn) ...[
          const SizedBox(height: 12),
          StudioSelect<String>(
            key: ValueKey(
              'voice-listen-min-speech-${s.listenMinSpeech.inMilliseconds}',
            ),
            label: 'Speech needed to steer',
            value: s.listenMinSpeech.inMilliseconds.toString(),
            options: [
              for (final value in VoicePreferences.listenMinSpeechChoices)
                (value: value, label: _seconds(value)),
            ],
            onChanged: widget.saving
                ? null
                : (value) {
                    if (value != null) {
                      unawaited(
                        widget.onSave(
                          VoicePreferences.listenMinSpeechKey,
                          value,
                        ),
                      );
                    }
                  },
          ),
        ],
        if (bargeInPlaybackAvailable)
          CompactSwitchListTile(
            key: const ValueKey('voice-barge-in-playback'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Interrupt read-aloud by speaking'),
            subtitle: bargeInPlaybackHint == null
                ? null
                : Text(bargeInPlaybackHint!),
            value: s.bargeInPlayback,
            onChanged: widget.saving
                ? null
                : (value) =>
                      _toggle(VoicePreferences.bargeInPlaybackKey, value),
          ),
        if (s.debugRecordings)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('voice-echo-probe'),
              onPressed: _probing || widget.saving
                  ? null
                  : () => unawaited(_probe()),
              child: Text(
                _probing ? 'Measuring speaker echo…' : 'Measure speaker echo',
              ),
            ),
          ),
      ],
    );
  }
}
