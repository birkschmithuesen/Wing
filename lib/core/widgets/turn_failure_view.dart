import 'package:flutter/material.dart';

import '../models/turn_failure.dart';
import '../theme/wing_theme.dart';
import 'studio_error.dart';
import 'selection_viewport.dart';

/// Recovery choices for a captured failure. Callbacks keep chat authority.
class TurnFailureView extends StatefulWidget {
  const TurnFailureView({
    super.key,
    required this.failure,
    this.onChooseModel,
    this.onReviewProvider,
    this.onSelectModel,
    this.onContinue,
    this.onReviewEndpoint,
  });
  final TurnFailure failure;
  final Future<void> Function()? onChooseModel,
      onReviewProvider,
      onContinue,
      onReviewEndpoint;
  final Future<bool> Function(TurnModelSuggestion)? onSelectModel;

  @override
  State<TurnFailureView> createState() => _TurnFailureViewState();
}

class _TurnFailureViewState extends State<TurnFailureView> {
  Object? _pending;
  String? _error;
  String? _selected;

  Future<void> _perform(
    Object action,
    Future<String?> Function() perform,
  ) async {
    if (_pending != null) return;
    final failure = widget.failure;
    setState(() {
      _pending = action;
      _error = null;
      _selected = null;
    });
    try {
      final message = await perform();
      if (mounted && identical(widget.failure, failure)) {
        setState(() => _selected = message);
      }
    } catch (error) {
      if (mounted && identical(widget.failure, failure)) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && identical(widget.failure, failure)) {
        setState(() => _pending = null);
      }
    }
  }

  Future<void> _select(TurnModelSuggestion suggestion) =>
      _perform(suggestion, () async {
        final selected = await widget.onSelectModel!(suggestion);
        return selected
            ? '${suggestion.label} selected. Send your next message when ready.'
            : null;
      });

  @override
  void didUpdateWidget(TurnFailureView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.failure, widget.failure)) {
      _pending = null;
      _error = null;
      _selected = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = widget.failure;
    final limit = failure.usageLimit;
    final reset = limit?.resetsAt ?? failure.resetsAt;
    final colors = WingTokens.of(context);
    final local = reset?.toLocal();
    final material = MaterialLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (failure.blocking)
          StudioError(failure.title)
        else
          Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 20, color: colors.muted),
                const SizedBox(width: 12),
                Expanded(child: Text(failure.title)),
              ],
            ),
          ),
        if (limit != null) Text(limit.message),
        if (failure.description case final description? when limit == null)
          Text(description),
        if (failure.recovery case final recovery?) Text(recovery),
        if (local != null)
          Text(
            'Resets ${material.formatShortDate(local)} · ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}',
            style: colors.typography.label.copyWith(color: colors.muted),
          ),
        for (final suggestion
            in limit?.suggestions ?? const <TurnModelSuggestion>[])
          Row(
            children: [
              Expanded(
                child: Text(
                  '${suggestion.label}${suggestion.note == 'free'
                      ? ' · Free'
                      : suggestion.note == 'included'
                      ? ' · Included'
                      : ''}',
                ),
              ),
              _FailureAction(
                label: 'Use ${suggestion.label}',
                icon: Icons.swap_horiz,
                onPressed: widget.onSelectModel == null || _pending != null
                    ? null
                    : () => _select(suggestion),
                busy: identical(_pending, suggestion),
              ),
            ],
          ),
        if (_selected case final selected?) Text(selected),
        if (_error case final error?) StudioError(error),
        if (limit?.creditsAction != null)
          Text(
            'Credits are managed in your provider account. Model selection does not enable credit spending.',
            style: colors.typography.label.copyWith(color: colors.muted),
          ),
        Wrap(
          children: [
            if (failure.canContinue && widget.onContinue != null)
              _FailureAction(
                label: 'Continue',
                icon: Icons.play_arrow_outlined,
                busy: _pending == 'continue',
                onPressed: _pending == null && _selected == null
                    ? () => _perform('continue', () async {
                        await widget.onContinue!();
                        return 'Continuation accepted. Your draft is unchanged.';
                      })
                    : null,
              ),
            if (failure.canReviewEndpoint && widget.onReviewEndpoint != null)
              _FailureAction(
                label: 'Review model endpoint',
                icon: Icons.dns_outlined,
                busy: _pending == 'endpoint',
                onPressed: _pending == null
                    ? () => _perform('endpoint', () async {
                        await widget.onReviewEndpoint!();
                        return null;
                      })
                    : null,
              ),
            if (failure.canChooseModel && widget.onChooseModel != null)
              _FailureAction(
                label: 'Choose model',
                icon: Icons.tune,
                busy: _pending == 'model',
                onPressed: _pending == null
                    ? () => _perform('model', () async {
                        await widget.onChooseModel!();
                        return null;
                      })
                    : null,
              ),
            if (failure.canReviewProvider && widget.onReviewProvider != null)
              _FailureAction(
                label: 'Review provider access',
                icon: Icons.key_outlined,
                busy: _pending == 'provider',
                onPressed: _pending == null
                    ? () => _perform('provider', () async {
                        await widget.onReviewProvider!();
                        return null;
                      })
                    : null,
              ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Error details'),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: viewportSelection(
                SelectableText(
                  [
                    failure.message,
                    if (failure.provider != null)
                      'Provider: ${failure.providerLabel ?? failure.provider}',
                    if (failure.model != null) 'Model: ${failure.model}',
                    if (failure.code.isNotEmpty) 'Code: ${failure.code}',
                    if (failure.retryable case final retryable?)
                      'Retryable: ${retryable ? 'yes' : 'no'}',
                  ].join('\n'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _FailureAction extends StatelessWidget {
  const _FailureAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.busy = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => StudioButtonPress(
    child: IconButton(
      tooltip: label,
      onPressed: busy ? null : onPressed,
      icon: busy
          ? SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                backgroundColor: Theme.of(context).colorScheme.outlineVariant,
                semanticsLabel: label,
                value: MediaQuery.disableAnimationsOf(context) ? .75 : null,
              ),
            )
          : Icon(icon),
    ),
  );
}
