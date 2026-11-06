import 'package:flutter/material.dart';

import '../models/hosted_connector_accounts.dart';
import '../theme/wing_theme.dart';
import 'selection_viewport.dart';
import 'studio_error.dart';

/// The received operation stays in its conversation. Account management lives
/// in Connected apps; this panel only presents its owner’s observations/actions.
class HostedConnectionRequestPanel extends StatefulWidget {
  const HostedConnectionRequestPanel({
    super.key,
    required this.operation,
    required this.canContinue,
    required this.canRefresh,
    required this.working,
    required this.onContinue,
    required this.onRefresh,
    required this.onOpenAccounts,
    required this.onAuthorize,
  });
  final HostedConnectionOperation operation;
  final bool canContinue, canRefresh, working;
  final Future<void> Function() onContinue, onRefresh, onOpenAccounts;
  final Future<void> Function(HostedConnectionTarget target) onAuthorize;

  @override
  State<HostedConnectionRequestPanel> createState() =>
      _HostedConnectionRequestPanelState();
}

class _HostedConnectionRequestPanelState
    extends State<HostedConnectionRequestPanel> {
  Object? _action;
  String? _pending, _error, _feedback;

  @override
  void didUpdateWidget(HostedConnectionRequestPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operation.id != widget.operation.id) {
      _action = null;
      _pending = _error = _feedback = null;
    } else if (widget.operation.settled) {
      _error = _feedback = null;
    }
  }

  Future<void> _perform(
    String pending,
    Future<void> Function() action, {
    String? feedback,
  }) async {
    if (_action != null) return;
    final token = Object();
    setState(() {
      _action = token;
      _pending = pending;
      _error = _feedback = null;
    });
    try {
      await action();
      if (!mounted || !identical(_action, token)) return;
      setState(() => _feedback = widget.operation.settled ? null : feedback);
    } catch (_) {
      if (!mounted || !identical(_action, token) || widget.operation.settled) {
        return;
      }
      setState(() {
        _error = 'Could not finish. Check status or refresh.';
      });
    } finally {
      if (mounted && identical(_action, token)) {
        setState(() {
          _action = null;
          _pending = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final operation = widget.operation;
    final theme = Theme.of(context);
    final busy = _action != null || widget.working;
    final canContinue = widget.canContinue && !busy;
    final canRefresh = widget.canRefresh && !busy;
    return Container(
      padding: const EdgeInsets.all(WingSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: WingRadius.card,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            operation.settled ? 'Connection request closed' : 'Connect apps',
            style: theme.textTheme.titleSmall,
          ),
          if (!operation.settled) ...[
            const SizedBox(height: WingSpacing.xs),
            const Text('Connect accounts, then continue.'),
          ],
          for (final target in operation.targets) ...[
            const SizedBox(height: WingSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        target.alias == null
                            ? target.name
                            : '${target.name} · ${target.alias}',
                        style: theme.textTheme.labelLarge,
                      ),
                      Text(target.statusLabel),
                      if (target.detail?.isNotEmpty == true)
                        Text(target.detail!, style: theme.textTheme.bodySmall),
                      if (target.launch case final launch?) ...[
                        const SizedBox(height: WingSpacing.xs),
                        Text(launch.label, style: theme.textTheme.labelSmall),
                        viewportSelection(
                          SelectableText(
                            launch.target,
                            style: WingTokens.of(context).typography.mono,
                          ),
                        ),
                        if (launch.environmentNames.isNotEmpty)
                          Text(
                            'Environment: ${launch.environmentNames.join(', ')}',
                            style: theme.textTheme.bodySmall,
                          ),
                        if (launch.cwd?.isNotEmpty == true)
                          viewportSelection(
                            SelectableText(
                              'Working directory: ${launch.cwd}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                if (target.needsAuthorization && !operation.settled)
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Authorize ${target.alias ?? target.name}',
                      onPressed: !canContinue
                          ? null
                          : () => _perform(
                              'Opening authorization…',
                              () => widget.onAuthorize(target),
                              feedback:
                                  'Authorization opened. Return here and check status.',
                            ),
                      icon: const Icon(Icons.open_in_new),
                    ),
                  ),
              ],
            ),
          ],
          if (operation.isDirectory && operation.suggested.isNotEmpty) ...[
            const SizedBox(height: WingSpacing.sm),
            Text('Suggested: ${operation.suggested.join(', ')}'),
          ],
          if (_error != null) ...[
            const SizedBox(height: WingSpacing.sm),
            StudioError(_error!),
          ],
          if (_feedback != null) ...[
            const SizedBox(height: WingSpacing.sm),
            Semantics(liveRegion: true, child: Text(_feedback!)),
          ],
          if (busy) ...[
            const SizedBox(height: WingSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  value: MediaQuery.disableAnimationsOf(context) ? 0.75 : null,
                  strokeWidth: 2,
                  semanticsLabel: _pending ?? 'Checking connection…',
                ),
              ),
            ),
          ],
          if (!operation.settled)
            Wrap(
              alignment: WrapAlignment.end,
              spacing: WingSpacing.xs,
              children: [
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Connected apps',
                    onPressed: !canContinue
                        ? null
                        : () => _perform(
                            'Opening connected apps…',
                            widget.onOpenAccounts,
                          ),
                    icon: const Icon(Icons.apps_outlined),
                  ),
                ),
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Check connection status',
                    onPressed: !canRefresh
                        ? null
                        : () => _perform(
                            'Checking connection…',
                            widget.onRefresh,
                            feedback: 'Connection status checked.',
                          ),
                    icon: const Icon(Icons.refresh),
                  ),
                ),
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Continue connection request',
                    onPressed: !canContinue
                        ? null
                        : () => _perform('Continuing…', widget.onContinue),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
