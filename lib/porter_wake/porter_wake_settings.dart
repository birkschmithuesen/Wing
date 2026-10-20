import 'package:flutter/material.dart';

import '../core/widgets/compact_switch.dart';
import '../core/widgets/studio_error.dart';
import 'porter_wake_api.dart';
import 'porter_wake_module.dart';

/// „Nachtruhe“ rows for the Notifications card. The server is the only truth;
/// nothing is stored on the device.
class PorterWakeSettings extends StatelessWidget {
  const PorterWakeSettings({super.key, required this.module});

  final PorterWakeModule module;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: module,
    builder: (context, _) {
      final active = module.activeConnections;
      if (active.isEmpty) return const SizedBox.shrink();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final connection in active)
            QuietHoursPanel(
              key: ValueKey(connection.id),
              api: module.apiFor(connection.id)!,
              connectionLabel: active.length > 1 ? connection.label : null,
            ),
        ],
      );
    },
  );
}

class QuietHoursPanel extends StatefulWidget {
  const QuietHoursPanel({super.key, required this.api, this.connectionLabel});

  final PorterWakeApi api;
  final String? connectionLabel;

  @override
  State<QuietHoursPanel> createState() => _QuietHoursPanelState();
}

class _QuietHoursPanelState extends State<QuietHoursPanel> {
  static const _unreachable =
      'Could not reach the server. Nachtruhe is unchanged.';

  PorterQuietHours? _server;
  PorterQuietHours? _shown;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.api.quietHours();
      if (mounted) setState(() => _server = _shown = value);
    } on Object {
      if (mounted) setState(() => _error = _unreachable);
    }
  }

  Future<void> _save(PorterQuietHours next) async {
    setState(() {
      _shown = next;
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.api.saveQuietHours(next);
      if (mounted) setState(() => _server = _shown = saved);
    } on PorterApiError catch (error) {
      if (mounted) {
        setState(() {
          _shown = _server;
          _error = error.message;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _shown = _server;
          _error = _unreachable;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pick(
    String current,
    PorterQuietHours Function(String) apply,
  ) async {
    final parts = current.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.parse(parts[0]),
        minute: int.parse(parts[1]),
      ),
      helpText: 'Time in Hermes’ timezone',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    if (text != current) await _save(apply(text));
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) {
      return _error == null
          ? const SizedBox(height: 48)
          : Padding(
              padding: const EdgeInsets.all(16),
              child: StudioError(_error!),
            );
    }
    final subtitle = [?widget.connectionLabel, shown.timezone].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CompactSwitchListTile(
          value: shown.enabled,
          onChanged: _saving
              ? null
              : (value) => _save(shown.copyWith(enabled: value)),
          title: const Text('Nachtruhe'),
          subtitle: Text(subtitle),
        ),
        ListTile(
          minTileHeight: 48,
          title: const Text('von'),
          trailing: Text(shown.from),
          enabled: !_saving,
          onTap: () => _pick(shown.from, (v) => shown.copyWith(from: v)),
        ),
        ListTile(
          minTileHeight: 48,
          title: const Text('bis'),
          trailing: Text(shown.to),
          enabled: !_saving,
          onTap: () => _pick(shown.to, (v) => shown.copyWith(to: v)),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: StudioError(_error!),
          ),
      ],
    );
  }
}
