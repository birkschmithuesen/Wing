import 'package:flutter/material.dart';

import '../models/email_draft.dart';
import '../services/email_composer.dart';
import 'studio_error.dart';
import 'studio_loading.dart';

/// The conversation supplies its origin; draft references never select a server.
class EmailDraftScope extends InheritedWidget {
  const EmailDraftScope({
    super.key,
    required this.owner,
    required this.read,
    required super.child,
  });
  final Object owner;
  final Future<EmailDraft> Function(EmailDraftReference) read;
  static EmailDraftScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EmailDraftScope>();
  @override
  bool updateShouldNotify(EmailDraftScope oldWidget) =>
      owner != oldWidget.owner;
}

class EmailDraftCard extends StatefulWidget {
  const EmailDraftCard({super.key, required this.reference});
  final EmailDraftReference reference;
  @override
  State<EmailDraftCard> createState() => _EmailDraftCardState();
}

class _EmailDraftCardState extends State<EmailDraftCard> {
  EmailDraftScope? _scope;
  EmailDraft? _draft;
  bool _loading = false, _opening = false;
  String? _error;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EmailDraftScope.maybeOf(context);
    if (_scope?.owner != scope?.owner || _scope == null) {
      _scope = scope;
      _load();
    }
  }

  @override
  void didUpdateWidget(EmailDraftCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final scope = _scope;
    setState(() {
      _draft = null;
      _error = null;
      _loading = scope != null;
      _opening = false;
    });
    if (scope == null) {
      _error = 'Open this draft in its original conversation.';
      return;
    }
    try {
      final draft = await scope.read(widget.reference);
      if (!mounted || generation != _generation) return;
      setState(() => _draft = draft);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(
        () => _error =
            'Could not load this draft. Check the connection and Wing plugin, then retry.',
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open() async {
    final draft = _draft;
    if (_opening || draft == null) return;
    final generation = _generation;
    setState(() {
      _opening = true;
      _error = null;
    });
    final opened = await EmailComposer.open(draft.mailto);
    if (!mounted || generation != _generation) return;
    setState(() {
      _opening = false;
      if (!opened) {
        _error =
            'Could not open an email app. Install or enable one and try again.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _draft;
    return StudioPageLoading(
      active: _opening,
      label: 'Opening email apps',
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Email draft', style: theme.textTheme.titleSmall),
                ),
                if (_loading)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 24,
                      child: MediaQuery.disableAnimationsOf(context)
                          ? const Icon(
                              Icons.mail_outline,
                              semanticLabel: 'Loading email draft',
                            )
                          : const CircularProgressIndicator(
                              strokeWidth: 2,
                              semanticsLabel: 'Loading email draft',
                            ),
                    ),
                  )
                else if (draft != null)
                  IconButton(
                    tooltip: 'Open in email app',
                    onPressed: _opening ? null : _open,
                    icon: const Icon(Icons.forward_to_inbox_outlined),
                  )
                else if (_scope != null)
                  IconButton(
                    tooltip: 'Retry loading draft',
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
            if (draft != null) ...[
              _field(
                'To',
                draft.to.isEmpty
                    ? 'Add a recipient in your email app'
                    : draft.to.join(', '),
              ),
              if (draft.cc.isNotEmpty) _field('Cc', draft.cc.join(', ')),
              if (draft.bcc.isNotEmpty) _field('Bcc', draft.bcc.join(', ')),
              const SizedBox(height: 12),
              SelectableText(
                draft.subject.isEmpty ? '(No subject)' : draft.subject,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              SelectableText(draft.body, style: theme.textTheme.bodyMedium),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: StudioError(_error!),
              ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: value),
        ],
      ),
    ),
  );
}
