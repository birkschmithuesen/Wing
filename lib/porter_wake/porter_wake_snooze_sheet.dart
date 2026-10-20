import 'package:flutter/material.dart';

import 'porter_wake_notice.dart';

/// Wing-local snooze choices besides the notice's own snooze action (the
/// first chooser entry, labelled as the server sent it): label and value.
const porterSnoozeChoices = [('in 2 Stunden', '2h'), ('morgen', 'morgen')];

/// The in-app sheet of an `items` notice (contract §6.4): tap opens an item's
/// session, long-press or the snooze button offers the snooze chooser.
Future<void> showPorterNoticeSheet(
  BuildContext context, {
  required PorterNotice notice,
  required Future<bool> Function(Map<String, String> body) feedback,
  required Future<void> Function(String profile, String sessionId) openItem,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _PorterNoticeSheet(
      notice: notice,
      feedback: feedback,
      openItem: openItem,
    ),
  );
}

class _PorterNoticeSheet extends StatefulWidget {
  const _PorterNoticeSheet({
    required this.notice,
    required this.feedback,
    required this.openItem,
  });

  final PorterNotice notice;
  final Future<bool> Function(Map<String, String> body) feedback;
  final Future<void> Function(String profile, String sessionId) openItem;

  @override
  State<_PorterNoticeSheet> createState() => _PorterNoticeSheetState();
}

class _PorterNoticeSheetState extends State<_PorterNoticeSheet> {
  bool _pending = false;
  bool _failed = false;

  PorterNoticeAction? get _later =>
      widget.notice.actions.where((a) => a.id == 'snooze').firstOrNull;

  Future<void> _open(PorterNoticeItem item) async {
    final navigator = Navigator.of(context);
    navigator.pop();
    await widget.openItem(item.profile, item.sessionId);
  }

  Future<void> _choose() async {
    final later = _later;
    if (later == null || _pending) return;
    final value = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (chooser) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, value) in [
              (later.label, later.defaultValue ?? 'default'),
              ...porterSnoozeChoices,
            ])
              ListTile(
                minTileHeight: 48,
                title: Text(label),
                onTap: () => Navigator.of(chooser).pop(value),
              ),
          ],
        ),
      ),
    );
    if (value == null || !mounted) return;
    setState(() {
      _pending = true;
      _failed = false;
    });
    var saved = false;
    try {
      saved = await widget.feedback({'action': 'snooze', 'value': value});
    } on Object catch (error) {
      debugPrint('porter_wake: snooze failed (${error.runtimeType})');
    }
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _pending = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSnooze = _later != null;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(widget.notice.title, style: theme.textTheme.titleMedium),
          ),
          // Reserved height so the pending state does not shift the rows.
          SizedBox(
            height: 4,
            child: _pending ? const LinearProgressIndicator() : null,
          ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Could not save. Try again.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          for (final item in widget.notice.items)
            ListTile(
              minTileHeight: 48,
              enabled: !_pending,
              title: Text(item.line),
              subtitle: _subtitle(item),
              trailing: canSnooze
                  ? IconButton(
                      tooltip: 'Snooze',
                      icon: const Icon(Icons.snooze),
                      onPressed: _pending ? null : _choose,
                    )
                  : null,
              onTap: _pending ? null : () => _open(item),
              onLongPress: canSnooze && !_pending ? _choose : null,
            ),
        ],
      ),
    );
  }

  Widget? _subtitle(PorterNoticeItem item) {
    final parts = [
      if (item.why != null) item.why!,
      if (item.snoozeLabel != null) item.snoozeLabel!,
    ];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }
}
