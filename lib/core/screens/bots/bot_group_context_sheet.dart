import 'package:flutter/material.dart';

import '../../models/bots.dart';
import '../../services/bot_group_session.dart';
import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/studio_form_actions.dart';
import '../../widgets/studio_select.dart';

/// Shared room settings. The session owns validation, write identity and receipt.
class BotGroupContextSheet extends StatefulWidget {
  const BotGroupContextSheet({super.key, required this.session});
  final BotGroupSession session;
  @override
  State<BotGroupContextSheet> createState() => _BotGroupContextSheetState();
}

class _BotGroupContextSheetState extends State<BotGroupContextSheet> {
  late final _initial = widget.session.context!;
  late final _purpose = TextEditingController(text: _initial.purpose);
  late final _notes = TextEditingController(text: _initial.notes);
  late String _routing = _initial.routing;
  late String _lead = _initial.leadMemberId;
  bool _saving = false;
  String? _error;
  BotGroupContext get _draft => BotGroupContext(
    purpose: _purpose.text,
    notes: _notes.text,
    routing: _routing,
    leadMemberId: _routing == 'lead' ? _lead : '',
  );

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await widget.session.saveContext(_draft);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = saved
          ? null
          : widget.session.error ??
                'Shared settings are unavailable. Refresh the group.';
    });
    if (saved) Navigator.pop(context);
  }

  @override
  void dispose() {
    _purpose.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: StudioFormSheet(
      actions: StudioFormActions(
        onCancel: () => Navigator.pop(context),
        onConfirm: _draft == _initial ? null : _save,
        confirmLabel: 'Save shared settings',
        busy: _saving,
        progressLabel: 'Saving shared settings',
      ),
      children: [
        Text('Shared settings', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Shared with this group. Changes apply to new discussions.'),
        const SizedBox(height: 16),
        viewportSelection(
          TextField(
            controller: _purpose,
            enabled: !_saving,
            maxLines: null,
            decoration: const InputDecoration(
              labelText: 'Purpose',
              helperText: 'Up to 500 characters',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: 16),
        viewportSelection(
          TextField(
            controller: _notes,
            enabled: !_saving,
            minLines: 3,
            maxLines: 7,
            decoration: const InputDecoration(
              labelText: 'Shared notes',
              helperText: 'Up to 4 KB of text',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: 16),
        StudioSelect<String>(
          label: 'Routing',
          value: _routing,
          options: [
            for (final mode in widget.session.runtime!.routingModes)
              (
                value: mode,
                label: switch (mode) {
                  'lead' => 'Lead',
                  'auto' => 'Auto',
                  _ => 'Everyone',
                },
              ),
          ],
          onChanged: _saving
              ? null
              : (value) {
                  if (value != null) setState(() => _routing = value);
                },
        ),
        const SizedBox(height: 8),
        Text(switch (_routing) {
          'auto' =>
            'Auto makes an extra model call to choose who replies. If routing fails, everyone replies.',
          'lead' =>
            'The lead chooses who replies. If its selection is invalid, only the lead replies.',
          _ => 'Every member gets a turn on messages without a mention.',
        }),
        if (_routing == 'lead') ...[
          const SizedBox(height: 16),
          StudioSelect<String>(
            label: 'Lead bot',
            value: _lead.isEmpty ? null : _lead,
            options: [
              for (final member in widget.session.group.members)
                (value: member.id, label: member.name),
            ],
            onChanged: _saving
                ? null
                : (value) {
                    if (value != null) setState(() => _lead = value);
                  },
          ),
        ],
        const SizedBox(height: 8),
        const Text(
          'Mentions select their recipients directly. Scheduled posts follow their own routing.',
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          StudioError(_error!),
        ],
      ],
    ),
  );
}
