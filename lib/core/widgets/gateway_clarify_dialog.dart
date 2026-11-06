import 'package:flutter/material.dart';
import '../models/gateway_clarify.dart';
import '../theme/wing_theme.dart';
import '../theme/profile_markdown_style.dart';
import 'block_reusing_markdown_body.dart';
import 'selection_viewport.dart';
import 'studio_error.dart';
import 'studio_form_actions.dart';
import 'studio_selection_tile.dart';
import 'studio_task_marker.dart';

/// One locally staged answer set. The runtime alone owns confirmed locks.
class GatewayClarifyDialog extends StatefulWidget {
  const GatewayClarifyDialog({
    required this.requests,
    required this.onRespond,
    required this.onSkip,
    this.answeredIds = const {},
    this.lockedAnswers = const {},
    super.key,
  });
  final List<GatewayClarifyRequest> requests;
  final Set<String> answeredIds;
  final Map<String, String> lockedAnswers;
  final Future<void> Function(Map<String, String?> answers) onRespond;
  final Future<void> Function() onSkip;

  @override
  State<GatewayClarifyDialog> createState() => _GatewayClarifyDialogState();
}

class _GatewayClarifyDialogState extends State<GatewayClarifyDialog>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final _answers = <String, String?>{};
  bool _submitting = false;
  String? _error;
  final _errorAnchor = GlobalKey();
  String _id(GatewayClarifyRequest q) => q.questionId ?? q.requestId;
  bool _locked(GatewayClarifyRequest q) => widget.answeredIds.contains(_id(q));

  Future<void> _respond({bool skip = false}) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (skip) {
        await widget.onSkip();
      } else {
        await widget.onRespond({
          for (final q in widget.requests)
            if (!_locked(q)) _id(q): _answers[_id(q)],
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Send failed. Try again.');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final anchor = _errorAnchor.currentContext;
          if (mounted && anchor != null) {
            Scrollable.ensureVisible(anchor, alignment: .1);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final ready = widget.requests
        .where((q) => !_locked(q))
        .every(
          (q) =>
              _answers.containsKey(_id(q)) &&
              (_answers[_id(q)] == null || _answers[_id(q)]!.isNotEmpty),
        );
    return Container(
      constraints: BoxConstraints(
        maxHeight:
            (MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom -
                MediaQuery.paddingOf(context).vertical) *
            .55,
      ),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: WingRadius.card,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: .35),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your input',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (
                    var index = 0;
                    index < widget.requests.length;
                    index++
                  ) ...[
                    if (index > 0) const Divider(height: 24),
                    _ClarifyQuestion(
                      key: ValueKey(('question', _id(widget.requests[index]))),
                      request: widget.requests[index],
                      enabled: !_submitting && !_locked(widget.requests[index]),
                      locked: _locked(widget.requests[index]),
                      lockedAnswer:
                          widget.lockedAnswers[_id(widget.requests[index])],
                      fieldKey: widget.requests.length == 1
                          ? 'clarify-other-field'
                          : 'clarify-other-${_id(widget.requests[index])}',
                      choicePrefix: widget.requests.length == 1
                          ? 'clarify-choice'
                          : 'clarify-${_id(widget.requests[index])}-choice',
                      onChanged: (answer) => setState(() {
                        _answers[_id(widget.requests[index])] = answer;
                        _error = null;
                      }),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            KeyedSubtree(
              key: _errorAnchor,
              child: StudioError(_error!, key: const Key('clarify-error')),
            ),
          ],
          const SizedBox(height: 12),
          StudioFormActions(
            onCancel: _submitting ? null : () => _respond(skip: true),
            cancelLabel: 'Skip clarification',
            cancelKey: const Key('clarify-skip'),
            confirmKey: const Key('clarify-continue'),
            onConfirm: _submitting || !ready ? null : _respond,
            confirmLabel: 'Confirm answers and continue',
            busy: _submitting,
            progressLabel: 'Sending answers',
          ),
        ],
      ),
    );
  }
}

class _ClarifyQuestion extends StatefulWidget {
  const _ClarifyQuestion({
    super.key,
    required this.request,
    required this.enabled,
    required this.locked,
    required this.lockedAnswer,
    required this.fieldKey,
    required this.choicePrefix,
    required this.onChanged,
  });
  final GatewayClarifyRequest request;
  final bool enabled, locked;
  final String? lockedAnswer;
  final String fieldKey, choicePrefix;
  final ValueChanged<String?> onChanged;
  @override
  State<_ClarifyQuestion> createState() => _ClarifyQuestionState();
}

class _ClarifyQuestionState extends State<_ClarifyQuestion> {
  final _text = TextEditingController();
  final _selected = <int>{};
  int? _single;
  bool _skip = false;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _publish() => widget.onChanged(
    _skip
        ? null
        : widget.request.answer(
            selectedIndex: _single,
            selectedIndices: _selected,
            customText: _text.text,
          ),
  );
  void _select(int index) {
    if (!widget.enabled) return;
    setState(() {
      _skip = false;
      if (widget.request.multiSelect) {
        if (!_selected.add(index)) _selected.remove(index);
      } else {
        _single = index;
        _text.clear();
      }
    });
    _publish();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Theme(
          data: profileMarkdownTheme(theme),
          child: BlockReusingMarkdownBody(
            checkboxBuilder: (checked) => StudioTaskMarker(completed: checked),
            data: request.question,
            selectable: true,
            sizedImageBuilder: (_) => const Text('[Image omitted]'),
            styleSheet: profileMarkdownStyle(theme, compact: true),
          ),
        ),
        if (widget.locked) ...[
          const SizedBox(height: 8),
          Text(
            widget.lockedAnswer?.isNotEmpty == true
                ? widget.lockedAnswer!
                : 'Answered on another device',
            style: theme.textTheme.bodySmall,
          ),
        ] else ...[
          if (request.hasChoices) ...[
            const SizedBox(height: 8),
            RadioGroup<int>(
              groupValue: _single,
              onChanged: (index) {
                if (index != null) _select(index);
              },
              child: Column(
                children: [
                  for (var i = 0; i < request.choices.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color:
                            !_skip &&
                                (request.multiSelect
                                    ? _selected.contains(i)
                                    : _single == i)
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainer,
                        borderRadius: WingRadius.card,
                        child: request.multiSelect
                            ? StudioSelectionTile(
                                key: Key('${widget.choicePrefix}-$i'),
                                value: !_skip && _selected.contains(i),
                                onChanged: widget.enabled
                                    ? (_) => _select(i)
                                    : null,
                                title: Text(request.choices[i]),
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                              )
                            : StudioRadioTile<int>(
                                key: Key('${widget.choicePrefix}-$i'),
                                value: i,
                                enabled: widget.enabled,
                                title: Text(request.choices[i]),
                                minTileHeight: 48,
                                minVerticalPadding: 8,
                                contentPadding: EdgeInsets.zero,
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          viewportSelection(
            TextField(
              key: Key(widget.fieldKey),
              controller: _text,
              enabled: widget.enabled,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                isDense: true,
                border: OutlineInputBorder(borderRadius: WingRadius.control),
                labelText: request.hasChoices ? 'Other answer' : 'Your answer',
              ),
              onChanged: (_) {
                setState(() {
                  _skip = false;
                  if (!request.multiSelect && _text.text.trim().isNotEmpty) {
                    _single = null;
                  }
                });
                _publish();
              },
            ),
          ),
          if (request.questionId != null)
            Align(
              alignment: Alignment.centerRight,
              child: StudioButtonPress(
                child: IconButton(
                  tooltip: _skip
                      ? 'Include this question'
                      : 'Skip this question',
                  isSelected: _skip,
                  icon: const Icon(Icons.skip_next_outlined),
                  onPressed: widget.enabled
                      ? () {
                          setState(() => _skip = !_skip);
                          _publish();
                        }
                      : null,
                ),
              ),
            ),
        ],
      ],
    );
  }
}
