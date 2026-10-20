import 'dart:async';

import 'package:flutter/material.dart';

import '../core/controllers/voice_output_controller.dart';
import '../core/services/android_voice.dart';
import '../core/services/voice_preferences.dart';
import '../core/widgets/compact_switch.dart';
import '../core/widgets/studio_error.dart';
import '../core/widgets/studio_select.dart';
import 'barge_in_policy.dart';
import 'headphone_route.dart';
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
    this.route,
    this.playbackAvailable = bargeInPlaybackAvailable,
  });

  final VoicePreferences settings;
  final VoiceDevice device;
  final bool saving;
  final Future<void> Function(String key, String value) onSave;

  /// Native route check; tests pass a fake.
  final HeadphoneRouteHost? route;

  /// Shows "Interrupt read-aloud by speaking" (the echo gate, Task 7).
  final bool playbackAvailable;

  @override
  State<BargeInSettings> createState() => _BargeInSettingsState();
}

class _BargeInSettingsState extends State<BargeInSettings> {
  TurnListener? _listener;
  VoiceOutputController? _output;
  bool _probing = false;

  static const _headphonesOnly =
      'Only with headphones. On the speaker or in the car, tap to stop.';

  /// Owner lifted the Bluetooth lock 2026-10-20 without an echo measurement
  /// (t_fabcb273): the row says this whenever the switch is on.
  static const _headphonesWiredOrBluetooth =
      'Only with headphones (wired or Bluetooth). On the speaker or in the car, tap to stop.';

  HeadphoneRouteHost get _route =>
      widget.route ?? AndroidHeadphoneRouteHost.instance;

  /// Spec §6: saving never waits for the permission dialog. Still requested
  /// on switch-on so a Bluetooth headphone route is recognised without the
  /// user reinstalling the permission flow; the subtitle no longer depends
  /// on it.
  Future<void> _togglePlayback(bool on) async {
    unawaited(
      widget.onSave(VoicePreferences.bargeInPlaybackKey, on ? 'on' : 'off'),
    );
    if (!on) return;
    await _route.requestBluetooth();
  }

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
    final route = await _route.current();
    bargeLog(routeLogLine(route, classifyRoute(route, wingCarMode: false)));
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
        if (widget.playbackAvailable)
          CompactSwitchListTile(
            key: const ValueKey('voice-barge-in-playback'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Interrupt read-aloud by speaking'),
            subtitle: Text(
              s.bargeInPlayback ? _headphonesWiredOrBluetooth : _headphonesOnly,
            ),
            value: s.bargeInPlayback,
            onChanged: widget.saving
                ? null
                : (value) => unawaited(_togglePlayback(value)),
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
