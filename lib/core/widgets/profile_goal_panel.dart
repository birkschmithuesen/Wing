import 'selection_viewport.dart';
import 'studio_form_actions.dart';
import 'activity/activity_detail_actions.dart';
import 'studio_error.dart';
import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';
import 'profile_transcript_disclosure.dart';
import 'tool_activity_details.dart';
import '../presentation/tool_activity_details.dart';

import '../models/session_control.dart';
import '../services/profile_supervision_session.dart';

/// Displays the server-owned goal for one captured chat and its supported
/// controls. The containing screen decides whether an empty panel is shown.
class ProfileGoalPanel extends StatefulWidget {
  final ProfileSupervisionSession session;
  final bool initiallyExpanded;

  const ProfileGoalPanel({
    super.key,
    required this.session,
    this.initiallyExpanded = false,
  });

  @override
  State<ProfileGoalPanel> createState() => _ProfileGoalPanelState();
}

class _ProfileGoalPanelState extends State<ProfileGoalPanel> {
  bool _requested = false;
  final _criterionDraft = TextEditingController();
  final _editors = <GoalCriterionEditor>{};

  @override
  void dispose() {
    for (final editor in _editors) {
      editor.dispose();
    }
    _criterionDraft.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _requestRefresh();
  }

  @override
  void didUpdateWidget(ProfileGoalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      for (final editor in _editors) {
        editor.dispose();
      }
      _editors.clear();
      _requested = false;
      _criterionDraft.clear();
      _requestRefresh();
    }
  }

  void _requestRefresh() {
    if (_requested) return;
    _requested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await widget.session.refreshControl();
      } catch (_) {
        // The controller retains the error for the panel.
      }
    });
  }

  Future<void> _refresh() async {
    try {
      await widget.session.refreshControl();
    } catch (_) {
      // The controller retains the error for the panel.
    }
  }

  Future<void> _run(SessionControlAction action) async {
    try {
      await widget.session.control(action);
    } catch (_) {
      // The controller retains the error and notice for the panel.
    }
  }

  Future<void> _addCriterion() async {
    final session = widget.session;
    final editor = session.editCriterion();
    _editors.add(editor);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _AddCriterionDialog(
          session: session,
          editor: editor,
          initialText: _criterionDraft.text,
          onDraftChanged: (value) {
            if (mounted && identical(widget.session, session)) {
              _criterionDraft.text = value;
            }
          },
          onAccepted: () {
            if (mounted && identical(widget.session, session)) {
              _criterionDraft.clear();
            }
          },
        ),
      );
    } finally {
      editor.dispose();
      _editors.remove(editor);
    }
  }

  Future<void> _removeCriterion(int index, String text) async {
    final session = widget.session;
    final review = session.reviewCriteria(index: index);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        scrollable: true,
        title: Text('Remove criterion ${index + 1}?'),
        content: Text(text),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: 'Remove criterion',
            confirmIcon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !identical(widget.session, session)) {
      return;
    }
    if (!review.current) {
      await _showCriteriaChanged();
      return;
    }
    final accepted = await session.applyCriteriaReview(review);
    if (!accepted &&
        mounted &&
        identical(widget.session, session) &&
        !review.current) {
      await _showCriteriaChanged();
    }
  }

  Future<void> _clearCriteria() async {
    final session = widget.session;
    final review = session.reviewCriteria();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        scrollable: true,
        title: const Text('Clear all criteria?'),
        content: const Text('This removes every criterion from this goal.'),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: 'Clear criteria',
            confirmIcon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !identical(widget.session, session)) {
      return;
    }
    if (!review.current) {
      await _showCriteriaChanged();
      return;
    }
    final accepted = await session.applyCriteriaReview(review);
    if (!accepted &&
        mounted &&
        identical(widget.session, session) &&
        !review.current) {
      await _showCriteriaChanged();
    }
  }

  Future<void> _showCriteriaChanged() => showDialog<void>(
    context: context,
    builder: (context) => StudioDialog(
      title: const Text('Criteria changed'),
      content: const Text(
        'Hermes updated these criteria. Review the refreshed list before trying again.',
      ),
      actions: [
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Close criteria notice',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    ),
  );

  Future<void> _clear() async {
    final session = widget.session;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        title: const Text('Clear goal?'),
        content: const Text('This clears the goal on the Hermes server.'),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: 'Clear goal',
            confirmIcon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
    );
    if (confirmed == true && mounted && identical(widget.session, session)) {
      await session.control(SessionControlAction.goalClear);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final chat = widget.session.state;
      final snapshot = chat.sessionControl;
      final goal = snapshot?.goal;
      final working =
          chat.actionBusy ||
          chat.sessionControlLoading ||
          chat.sessionControlWorking;
      final error = chat.sessionControlError;
      return ProfileTranscriptDisclosure(
        key: ValueKey(('goal', chat.key)),
        initiallyExpanded: widget.initiallyExpanded,
        maintainState: false,
        icon: Icons.track_changes_outlined,
        label: 'Goal',
        summary: Text(_summary(goal, chat.sessionControlNotice)),
        childrenPadding: EdgeInsets.zero,
        children: [
          if (error != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: StudioError(error)),
                ActivityDetailAction(
                  label: 'Retry',
                  icon: Icons.refresh,
                  onPressed: working ? null : _refresh,
                ),
              ],
            ),
          if (goal == null && error == null)
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Hermes has no active goal for this chat.'),
            ),
          if (goal != null)
            ActivityDetailsCard(
              children: [
                _GoalDetails(goal: goal),
                _CriteriaSection(
                  goal: goal,
                  disabled: working,
                  onAdd: _addCriterion,
                  onRemove: _removeCriterion,
                  onClear: _clearCriteria,
                ),
                ActivityDetailStatus(
                  label: goal.status == SessionGoalStatus.done
                      ? 'Completed'
                      : _statusLabel(goal.status),
                  icon: goal.status == SessionGoalStatus.active
                      ? Icons.timelapse_outlined
                      : goal.status == SessionGoalStatus.paused
                      ? Icons.pause_circle_outline
                      : Icons.check_circle_outline,
                  contextFacts: ['${goal.turnsUsed}/${goal.maxTurns} turns'],
                  actions: [
                    _GoalActions(
                      actions: chat.goalActions,
                      disabled: working,
                      onAction: _run,
                      onClear: _clear,
                    ),
                  ],
                ),
              ],
            ),
          Align(
            alignment: Alignment.centerRight,
            child: ActivityDetailAction(
              onPressed: working ? null : _refresh,
              icon: Icons.refresh,
              label: 'Refresh',
            ),
          ),
          if (chat.sessionControlNotice case final notice?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(notice),
            ),
        ],
      );
    },
  );

  static String _summary(SessionGoal? goal, String? notice) {
    if (goal == null) return notice ?? 'Server state';
    return '${_statusLabel(goal.status)} · ${goal.turnsUsed}/${goal.maxTurns} turns';
  }

  static String _statusLabel(SessionGoalStatus status) => switch (status) {
    SessionGoalStatus.active => 'Active',
    SessionGoalStatus.done => 'Done',
    SessionGoalStatus.paused => 'Paused',
  };
}

class _AddCriterionDialog extends StatefulWidget {
  final ProfileSupervisionSession session;
  final GoalCriterionEditor editor;
  final String initialText;
  final ValueChanged<String> onDraftChanged;
  final VoidCallback onAccepted;

  const _AddCriterionDialog({
    required this.session,
    required this.editor,
    required this.initialText,
    required this.onDraftChanged,
    required this.onAccepted,
  });

  @override
  State<_AddCriterionDialog> createState() => _AddCriterionDialogState();
}

class _AddCriterionDialogState extends State<_AddCriterionDialog> {
  late final TextEditingController _draft;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _draft = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      final accepted = await widget.editor.submit(_draft.text);
      if (!mounted) return;
      if (accepted) {
        widget.onAccepted();
        Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final working =
          _adding ||
          widget.session.state.actionBusy ||
          widget.session.state.sessionControlLoading ||
          widget.session.state.sessionControlWorking;
      return PopScope(
        canPop: !working,
        child: StudioDialog(
          scrollable: true,
          title: const Text('Add criterion'),
          content: viewportSelection(
            TextField(
              key: const ValueKey('goal-criterion-draft'),
              controller: _draft,
              enabled: !working,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Criterion',
                hintText: 'What must be true before this goal is done?',
                errorText: widget.editor.error,
                alignLabelWithHint: true,
                border: const OutlineInputBorder(
                  borderRadius: WingRadius.control,
                ),
              ),
              onChanged: (value) {
                widget.onDraftChanged(value);
                setState(() {});
              },
            ),
          ),
          actions: [
            StudioFormActions(
              onCancel: working ? null : () => Navigator.pop(context),
              onConfirm: working || !widget.editor.canSubmit(_draft.text)
                  ? null
                  : _add,
              confirmLabel: 'Add criterion',
              busy: _adding,
              progressLabel: 'Adding criterion',
            ),
          ],
        ),
      );
    },
  );
}

class _GoalDetails extends StatelessWidget {
  final SessionGoal goal;

  const _GoalDetails({required this.goal});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ActivityDetailSection(
        block: ToolDetailBlock(
          label: 'Objective',
          text: goal.title,
          copyable: true,
        ),
      ),
      _Field(label: 'Outcome', value: goal.contract.outcome),
      _Field(label: 'Verification', value: goal.contract.verification),
      _Field(label: 'Constraints', value: goal.contract.constraints),
      _Field(label: 'Boundaries', value: goal.contract.boundaries),
      _Field(label: 'Stop when', value: goal.contract.stopWhen),
      for (var index = 0; index < goal.gates.length; index++)
        ActivityDetailSection(
          block: ToolDetailBlock(
            label: 'Verification gate ${index + 1}',
            role: ToolDetailRole.command,
            format: ToolDetailFormat.source,
            text: goal.gates[index].command,
            copyable: true,
          ),
          facts: [
            '${goal.gates[index].attempts} attempts',
            '${goal.gates[index].maxRetries} retries allowed',
            '${goal.gates[index].timeoutSeconds}s timeout',
            goal.gates[index].lastExitCode == null
                ? goal.gates[index].attempts == 0
                      ? 'Not run'
                      : 'Exit code not supplied'
                : 'Exit ${goal.gates[index].lastExitCode}',
          ],
        ),
      if (goal.pausedReason case final reason?)
        _Field(label: 'Paused', value: reason, copyable: false),
      if (goal.lastReason case final reason?)
        ActivityDetailSection(
          block: ToolDetailBlock(
            label: 'Latest decision',
            text: reason,
            copyable: false,
          ),
          facts: [
            if (goal.lastVerdict case final verdict?) _verdictText(verdict),
          ],
        )
      else if (goal.lastVerdict case final verdict?)
        ActivityDetailFacts(facts: ['Last verdict: ${_verdictText(verdict)}']),
      if (goal.waitBarrier case final barrier?)
        ActivityDetailStatus(
          label: 'Waiting',
          icon: Icons.schedule_outlined,
          contextFacts: [_barrierText(context, barrier)],
        ),
    ],
  );

  String _barrierText(BuildContext context, SessionGoalWaitBarrier barrier) {
    if (barrier.type == SessionGoalWaitType.until) {
      final local = DateTime.fromMillisecondsSinceEpoch(
        (barrier.untilAt! * 1000).round(),
      ).toLocal();
      final material = MaterialLocalizations.of(context);
      final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(local));
      return '${barrier.reason} (until ${material.formatFullDate(local)} $time)';
    }
    return switch (barrier.type) {
      SessionGoalWaitType.session =>
        '${barrier.reason} (session ${barrier.sessionTarget})',
      SessionGoalWaitType.pid =>
        '${barrier.reason} (process ${barrier.processId})',
      SessionGoalWaitType.until => barrier.reason,
    };
  }

  static String _verdictText(SessionGoalVerdict verdict) => switch (verdict) {
    SessionGoalVerdict.blocked => 'Blocked',
    SessionGoalVerdict.continueRunning => 'Continue',
    SessionGoalVerdict.done => 'Done',
    SessionGoalVerdict.skipped => 'Skipped',
    SessionGoalVerdict.wait => 'Waiting',
  };
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  final bool copyable;

  const _Field({
    required this.label,
    required this.value,
    this.copyable = true,
  });

  @override
  Widget build(BuildContext context) => value.trim().isEmpty
      ? const SizedBox.shrink()
      : ActivityDetailSection(
          block: ToolDetailBlock(label: label, text: value, copyable: copyable),
        );
}

class _CriteriaSection extends StatelessWidget {
  final SessionGoal goal;
  final bool disabled;
  final Future<void> Function() onAdd;
  final Future<void> Function(int index, String text) onRemove;
  final Future<void> Function() onClear;

  const _CriteriaSection({
    required this.goal,
    required this.disabled,
    required this.onAdd,
    required this.onRemove,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ActivityDetailStatus(
        label: 'Criteria (${goal.subgoals.length})',
        icon: Icons.checklist_outlined,
        actions: [
          ActivityDetailAction(
            label: 'Add criterion',
            icon: Icons.add,
            onPressed: disabled ? null : onAdd,
          ),
          if (goal.subgoals.isNotEmpty)
            ActivityDetailAction(
              label: 'Clear criteria',
              icon: Icons.clear_all,
              onPressed: disabled ? null : onClear,
            ),
        ],
      ),
      for (var index = 0; index < goal.subgoals.length; index++)
        ActivityDetailSection(
          copyable: false,
          viewable: false,
          block: ToolDetailBlock(
            label: 'Criterion ${index + 1}',
            text: goal.subgoals[index],
          ),
          actions: [
            ActivityDetailAction(
              label: 'Remove criterion ${index + 1}',
              icon: Icons.close,
              onPressed: disabled
                  ? null
                  : () => onRemove(index, goal.subgoals[index]),
            ),
          ],
        ),
    ],
  );
}

class _GoalActions extends StatelessWidget {
  final List<SessionControlAction> actions;
  final bool disabled;
  final Future<void> Function(SessionControlAction) onAction;
  final Future<void> Function() onClear;

  const _GoalActions({
    required this.actions,
    required this.disabled,
    required this.onAction,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 0,
    runSpacing: 0,
    children: [
      if (actions.contains(SessionControlAction.goalPause))
        ActivityDetailAction(
          onPressed: disabled
              ? null
              : () => onAction(SessionControlAction.goalPause),
          icon: Icons.pause,
          label: 'Pause',
        ),
      if (actions.contains(SessionControlAction.goalResume))
        ActivityDetailAction(
          onPressed: disabled
              ? null
              : () => onAction(SessionControlAction.goalResume),
          icon: Icons.play_arrow,
          label: 'Resume',
        ),
      if (actions.contains(SessionControlAction.goalUnwait))
        ActivityDetailAction(
          onPressed: disabled
              ? null
              : () => onAction(SessionControlAction.goalUnwait),
          icon: Icons.play_circle_outline,
          label: 'Resume now',
        ),
      ActivityDetailAction(
        onPressed: disabled ? null : onClear,
        icon: Icons.delete_outline,
        label: 'Clear',
      ),
    ],
  );
}
