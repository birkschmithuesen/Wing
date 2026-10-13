import 'dart:async';
import 'package:flutter/material.dart';
import '../services/android_voice.dart';
import '../services/voice_preferences.dart';
import 'anchored_expansion_tile.dart';
import 'compact_switch.dart';
import 'studio_error.dart';
import 'studio_select.dart';

/// Settings that exist only for the vad input route: the on-phone speech
/// model, cue tones, pause detection and debug recordings. There is no
/// microphone choice: recording uses whatever input Android routes.
class VadSettingsSection extends StatefulWidget {
  const VadSettingsSection({
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
  State<VadSettingsSection> createState() => _VadSettingsSectionState();
}

class _VadSettingsSectionState extends State<VadSettingsSection> {
  static const _archiveMb = 487;
  VadModelStatus? _status;
  late final StreamSubscription<Map<String, dynamic>> _events;

  @override
  void initState() {
    super.initState();
    _events = widget.device.events.listen((event) {
      if (event['model'] case final Map<Object?, Object?> model) {
        if (mounted) setState(() => _status = VadModelStatus.fromMap(model));
      }
    });
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final status = await widget.device.vadModelStatus();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) {
        setState(
          () => _status = const VadModelStatus(
            state: VadModelState.failed,
            error: 'Could not read the speech model state.',
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }

  Future<void> _confirmRemove() async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove speech model?'),
        content: const Text('Frees about 670 MB. Downloading it again takes a while.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('vad-model-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove == true) {
      await widget.device.removeVadModel();
      await _refresh();
    }
  }

  Widget _model(BuildContext context) {
    final status = _status;
    if (status == null) return const LinearProgressIndicator();
    String mb(int bytes) => (bytes / 1000000).round().toString();
    Widget row(String text, Widget? action) => Row(
      children: [
        Expanded(child: Text(text)),
        ?action,
      ],
    );
    return switch (status.state) {
      VadModelState.absent => row(
        'Speech model · $_archiveMb MB download',
        TextButton(
          key: const ValueKey('vad-model-download'),
          onPressed: () => unawaited(widget.device.installVadModel()),
          child: const Text('Download'),
        ),
      ),
      VadModelState.downloading => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row(
            '${mb(status.bytes)} / ${mb(status.total == 0 ? 487170055 : status.total)} MB',
            TextButton(
              key: const ValueKey('vad-model-cancel'),
              onPressed: () => unawaited(widget.device.cancelVadModelInstall()),
              child: const Text('Cancel'),
            ),
          ),
          LinearProgressIndicator(
            value: status.total == 0 ? null : status.bytes / status.total,
          ),
        ],
      ),
      VadModelState.verifying || VadModelState.unpacking => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(status.state == VadModelState.verifying ? 'Checking…' : 'Unpacking…'),
          const LinearProgressIndicator(),
        ],
      ),
      VadModelState.installed => row(
        'Speech model ready',
        TextButton(
          key: const ValueKey('vad-model-remove'),
          onPressed: _confirmRemove,
          child: const Text('Remove'),
        ),
      ),
      VadModelState.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudioError(status.error ?? 'Speech model is unavailable.'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('vad-model-retry'),
              onPressed: () => unawaited(widget.device.installVadModel()),
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
    };
  }

  Widget _choice(
    String label,
    String key,
    String value,
    List<({String value, String label})> options,
  ) => StudioSelect<String>(
    key: ValueKey('$key-$value'),
    label: label,
    value: value,
    options: options,
    onChanged: widget.saving
        ? null
        : (next) {
            if (next != null) unawaited(widget.onSave(key, next));
          },
  );

  /// '1800' → '1.8 s', '1000' → '1 s', '150' → '0.15 s'.
  String _secondsLabel(String ms) {
    final text = (int.parse(ms) / 1000).toString();
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} s';
  }

  List<({String value, String label})> _seconds(List<String> ms) => [
    for (final value in ms) (value: value, label: _secondsLabel(value)),
  ];

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _model(context),
        const SizedBox(height: 12),
        CompactSwitchListTile(
          key: const ValueKey('vad-cues'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Cue tones'),
          value: s.cues,
          onChanged: widget.saving
              ? null
              : (value) => unawaited(
                  widget.onSave(VoicePreferences.vadCuesKey, value ? 'on' : 'off'),
                ),
        ),
        AnchoredExpansionTile(
          title: const Text('Pause detection'),
          tilePadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _choice(
              'Pause before sending',
              VoicePreferences.vadPauseKey,
              s.vad.pause.inMilliseconds.toString(),
              _seconds(VoicePreferences.vadPauseChoices),
            ),
            const SizedBox(height: 12),
            _choice(
              'Wait for speech',
              VoicePreferences.vadNoSpeechKey,
              s.vad.noSpeechTimeout.inSeconds.toString(),
              [
                for (final value in VoicePreferences.vadNoSpeechChoices)
                  (value: value, label: '$value s'),
              ],
            ),
            const SizedBox(height: 12),
            _choice(
              'Minimum speech',
              VoicePreferences.vadMinSpeechKey,
              s.vad.minSpeech.inMilliseconds.toString(),
              _seconds(VoicePreferences.vadMinSpeechChoices),
            ),
            const SizedBox(height: 12),
            _choice(
              'Lead-in kept',
              VoicePreferences.vadPreRollKey,
              s.vad.preRoll.inMilliseconds.toString(),
              _seconds(VoicePreferences.vadPreRollChoices),
            ),
            const SizedBox(height: 12),
            _choice(
              'Longest recording',
              VoicePreferences.vadMaxKey,
              s.vad.maxDuration.inSeconds.toString(),
              [
                for (final value in VoicePreferences.vadMaxChoices)
                  (value: value, label: '$value s'),
              ],
            ),
            CompactSwitchListTile(
              key: const ValueKey('vad-debug'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Debug recordings'),
              subtitle: const Text(
                'Keeps audio and timing of each round on this phone. Never uploaded.',
              ),
              value: s.debugRecordings,
              onChanged: widget.saving
                  ? null
                  : (value) => unawaited(
                      widget.onSave(VoicePreferences.vadDebugKey, value ? 'on' : 'off'),
                    ),
            ),
            if (s.debugRecordings) ...[
              _choice('Audio source', VoicePreferences.vadSourceKey, s.audioSource.name, const [
                (value: 'communication', label: 'Call processing'),
                (value: 'recognition', label: 'Recognition'),
              ]),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('vad-debug-delete'),
                  onPressed: () => unawaited(widget.device.deleteVadDebugRecordings()),
                  child: const Text('Delete debug recordings'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
