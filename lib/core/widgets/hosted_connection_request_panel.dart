import 'package:flutter/material.dart';

import '../models/hosted_connector_accounts.dart';
import '../theme/wing_theme.dart';
import 'selection_viewport.dart';
import 'studio_error.dart';
import 'studio_form_actions.dart';

/// The received operation stays in its conversation. Account management lives
/// in Connected apps; this panel presents the operation and forwards intent.
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
    required this.onRespond,
  });
  final HostedConnectionOperation operation;
  final bool canContinue, canRefresh, working;
  final Future<void> Function() onContinue, onRefresh;
  final VoidCallback onOpenAccounts;
  final Future<void> Function(HostedConnectionTarget target) onAuthorize;
  final Future<void> Function(
    HostedConnectionTarget target, {
    required bool skip,
    required Map<String, String> credentials,
  })
  onRespond;

  @override
  State<HostedConnectionRequestPanel> createState() =>
      _HostedConnectionRequestPanelState();
}

class _HostedConnectionRequestPanelState
    extends State<HostedConnectionRequestPanel> {
  Object? _action;
  String? _pending, _error, _feedback, _actionTarget, _editingTarget;

  @override
  void didUpdateWidget(HostedConnectionRequestPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operation.id != widget.operation.id) {
      _action = null;
      _pending = _error = _feedback = _actionTarget = _editingTarget = null;
    } else if (widget.operation.settled) {
      _action = null;
      _pending = _error = _feedback = _actionTarget = _editingTarget = null;
    } else if (widget.operation.sequence != oldWidget.operation.sequence) {
      _feedback = null;
      if (!widget.operation.targets.any(
        (target) => target.name == _editingTarget && target.fields.isNotEmpty,
      )) {
        _editingTarget = null;
      }
    }
  }

  Future<void> _perform(
    String pending,
    Future<void> Function() action, {
    required String failure,
    String? feedback,
    String? target,
  }) async {
    if (_action != null) return;
    final token = Object();
    final sequence = widget.operation.sequence;
    setState(() {
      _action = token;
      _actionTarget = target;
      _pending = pending;
      _error = _feedback = null;
    });
    try {
      await action();
      if (!mounted || !identical(_action, token)) return;
      if (!widget.operation.settled &&
          (target == null || widget.operation.sequence == sequence)) {
        setState(() => _feedback = feedback);
      }
    } catch (_) {
      if (!mounted || !identical(_action, token) || widget.operation.settled) {
        return;
      }
      setState(() => _error = failure);
    } finally {
      if (mounted && identical(_action, token)) {
        setState(() {
          _action = null;
          _pending = null;
        });
      }
    }
  }

  Widget _icon(
    String label,
    IconData glyph,
    VoidCallback? onPressed, {
    bool primary = false,
  }) {
    final icon = Icon(glyph);
    return StudioButtonPress(
      child: primary
          ? IconButton.filledTonal(
              tooltip: label,
              onPressed: onPressed,
              icon: icon,
            )
          : IconButton(tooltip: label, onPressed: onPressed, icon: icon),
    );
  }

  Widget _progress(String label) => Row(
    children: [
      SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(
          value: MediaQuery.disableAnimationsOf(context) ? 0.75 : null,
          strokeWidth: 2,
          semanticsLabel: label,
        ),
      ),
      const SizedBox(width: WingSpacing.sm),
      Expanded(child: ExcludeSemantics(child: Text(label))),
    ],
  );

  List<Widget> _feedbackFor(String? target) => [
    if (_actionTarget == target) ...[
      if (_pending case final pending?) _progress(pending),
      if (_error case final error?) StudioError(error, framed: false),
      if (_feedback case final feedback?)
        Semantics(liveRegion: true, child: Text(feedback)),
    ],
  ];

  Future<void> _respond(
    HostedConnectionTarget target,
    String pending,
    String failure, {
    bool skip = false,
    Map<String, String> credentials = const {},
  }) => _perform(
    pending,
    () => widget.onRespond(target, skip: skip, credentials: credentials),
    failure: failure,
    target: target.name,
  );

  Widget _target(HostedConnectionTarget target, bool canAct) {
    final theme = Theme.of(context);
    final active = !widget.operation.settled;
    final step = target.step;
    final showStatus =
        step != HostedConnectionStep.working ||
        _actionTarget != target.name ||
        _pending == null;
    final name = target.title;
    final (verb, glyph, pending, failure) = switch (step) {
      HostedConnectionStep.enable => (
        'Enable',
        Icons.power_settings_new_rounded,
        'Enabling $name…',
        'Enable failed. Check connection status.',
      ),
      HostedConnectionStep.install => (
        'Install',
        Icons.download_rounded,
        'Installing $name…',
        'Install failed. Check connection status.',
      ),
      HostedConnectionStep.retry => (
        'Retry',
        Icons.replay_rounded,
        'Retrying $name…',
        'Could not retry $name. Check connection status.',
      ),
      _ => (
        'Authorize',
        Icons.open_in_new_rounded,
        'Opening authorization…',
        'Could not open the sign-in page. Try again.',
      ),
    };
    final editing =
        active &&
        _editingTarget == target.name &&
        target.fields.isNotEmpty &&
        (step == HostedConnectionStep.install ||
            step == HostedConnectionStep.retry);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(target.title, style: theme.textTheme.labelLarge),
                  if (showStatus)
                    Text(
                      target.statusLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (active &&
                !editing &&
                step != null &&
                step != HostedConnectionStep.working)
              _icon(
                '$verb $name',
                glyph,
                !canAct
                    ? null
                    : () {
                        if (step == HostedConnectionStep.signIn) {
                          _perform(
                            pending,
                            () => widget.onAuthorize(target),
                            failure: failure,
                            feedback: 'Sign-in opened in your browser.',
                            target: target.name,
                          );
                        } else if (target.fields.isNotEmpty) {
                          setState(() {
                            _editingTarget = target.name;
                            _error = _feedback = null;
                          });
                        } else {
                          _respond(target, pending, failure);
                        }
                      },
                primary: true,
              ),
          ],
        ),
        if (target.detail?.isNotEmpty == true)
          Text(target.detail!, style: theme.textTheme.bodySmall),
        if (target.discoveryError?.isNotEmpty == true)
          StudioError(target.discoveryError!, icon: Icons.cloud_off_outlined),
        if (!editing) ..._feedbackFor(target.name),
        if (target.launch case final launch? when active && target.canSkip) ...[
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
        if (editing)
          _ConnectionCredentials(
            key: ValueKey(target.name),
            target: target,
            canSubmit: canAct,
            label: '$verb $name',
            pending: _actionTarget == target.name ? _pending : null,
            error: _actionTarget == target.name ? _error : null,
            onClose: () => setState(() => _editingTarget = null),
            onSubmit: (values) =>
                _respond(target, pending, failure, credentials: values),
          ),
      ],
    );
  }

  Widget _moreActions(bool canAct, bool canRefresh) => StudioButtonPress(
    child: PopupMenuButton<({HostedConnectionTarget? skip})>(
      key: ObjectKey(widget.operation),
      tooltip: 'More connection actions',
      icon: const Icon(Icons.more_horiz),
      position: PopupMenuPosition.under,
      offset: const Offset(0, WingSpacing.xs),
      requestFocus: true,
      popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      enabled:
          canRefresh ||
          canAct && widget.operation.targets.any((target) => target.canSkip),
      onSelected: (choice) {
        if (choice.skip case final target?) {
          if (canAct) {
            _respond(
              target,
              'Skipping ${target.title}…',
              'Could not skip ${target.title}. Check connection status.',
              skip: true,
            );
          }
        } else if (canRefresh) {
          _perform(
            'Checking connection…',
            widget.onRefresh,
            failure: 'Could not check connection status. Try again.',
            feedback: 'Connection status checked.',
          );
        }
      },
      itemBuilder: (context) => [
        StudioPopupMenuItem(
          value: (skip: null),
          enabled: canRefresh,
          child: const Text('Check connection status'),
        ),
        for (final target in widget.operation.targets)
          if (target.canSkip)
            StudioPopupMenuItem(
              value: (skip: target),
              enabled: canAct,
              child: Text('Skip ${target.title}'),
            ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final operation = widget.operation;
    final theme = Theme.of(context);
    final busy = _action != null || widget.working;
    final canAct = widget.canContinue && !busy;
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
            operation.targets.any((target) => target.kind == 'mcp')
                ? 'MCP setup'
                : operation.settled
                ? 'Connection request closed'
                : 'Connect apps',
            style: theme.textTheme.titleSmall,
          ),
          if (!operation.settled && operation.isDirectory) ...[
            const SizedBox(height: WingSpacing.xs),
            const Text('Browse apps to connect an account.'),
            if (operation.suggested.isNotEmpty)
              Text(
                'Suggested · ${operation.suggested.join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
          ],
          for (final target in operation.targets) ...[
            const SizedBox(height: WingSpacing.sm),
            _target(target, canAct),
          ],
          ..._feedbackFor(null),
          if (!operation.settled && widget.working && _action == null)
            _progress('Updating connection request…'),
          if (!operation.settled)
            Wrap(
              alignment: WrapAlignment.end,
              spacing: WingSpacing.xs,
              children: [
                if (operation.isDirectory ||
                    operation.targets.any(
                      (target) => target.kind == 'connector',
                    ))
                  _icon(
                    operation.isDirectory
                        ? 'Browse apps'
                        : 'Manage connected apps',
                    operation.isDirectory
                        ? Icons.manage_search_rounded
                        : Icons.link_rounded,
                    canAct ? widget.onOpenAccounts : null,
                    primary: operation.isDirectory,
                  ),
                _moreActions(canAct, canRefresh),
                _icon(
                  'Close connection request',
                  Icons.close_rounded,
                  !canAct
                      ? null
                      : () => _perform(
                          'Closing request…',
                          widget.onContinue,
                          failure:
                              'Could not close the request. Check connection status.',
                        ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ConnectionCredentials extends StatefulWidget {
  const _ConnectionCredentials({
    super.key,
    required this.target,
    required this.canSubmit,
    required this.label,
    required this.pending,
    required this.error,
    required this.onClose,
    required this.onSubmit,
  });

  final HostedConnectionTarget target;
  final bool canSubmit;
  final String label;
  final String? pending, error;
  final VoidCallback onClose;
  final ValueChanged<Map<String, String>> onSubmit;

  @override
  State<_ConnectionCredentials> createState() => _ConnectionCredentialsState();
}

class _ConnectionCredentialsState extends State<_ConnectionCredentials> {
  final _edited = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final fields = widget.target.fields;
    final values = {
      for (final field in fields)
        field.name: _edited[field.name] ?? field.defaultValue,
    };
    final complete = widget.target.hasRequiredCredentials(values);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.target.instructions?.isNotEmpty == true)
          Text(widget.target.instructions!),
        for (final field in fields) ...[
          const SizedBox(height: WingSpacing.sm),
          Text(
            field.prompt?.isNotEmpty == true ? field.prompt! : field.name,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          Semantics(
            label: field.prompt?.isNotEmpty == true ? field.prompt : field.name,
            child: viewportSelection(
              TextFormField(
                key: ValueKey(field.name),
                initialValue: values[field.name],
                enabled: widget.canSubmit,
                obscureText: field.secret,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: field.required ? 'Required' : 'Optional',
                ),
                onChanged: (value) =>
                    setState(() => _edited[field.name] = value),
              ),
            ),
          ),
        ],
        const SizedBox(height: WingSpacing.sm),
        if (widget.error case final error?) StudioError(error),
        StudioFormActions(
          busy: widget.pending != null,
          progressLabel: widget.pending ?? widget.label,
          onCancel: widget.canSubmit ? widget.onClose : null,
          onConfirm: widget.canSubmit && complete
              ? () {
                  FocusScope.of(context).unfocus();
                  widget.onSubmit(values);
                }
              : null,
          confirmLabel: widget.label,
        ),
      ],
    );
  }
}
