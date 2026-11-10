import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:flutter/material.dart';

import '../../models/scheduled_task.dart';
import '../../models/scheduled_task_edit.dart';
import '../../services/scheduled_tasks_controller.dart';
import '../../services/scheduled_task_edit_session.dart';
import '../../widgets/model_chooser.dart';
import '../../widgets/studio_action_label.dart';
import '../../widgets/studio_select.dart';
import '../../widgets/studio_selection_tile.dart';
import 'admin_widgets.dart';
import 'scheduled_task_widgets.dart';

class AdminScheduledTaskEditorPage extends StatefulWidget {
  const AdminScheduledTaskEditorPage({
    super.key,
    required this.controller,
    this.original,
    this.now,
  });
  final ScheduledTasksController controller;
  final ScheduledTask? original;
  final DateTime Function()? now;
  @override
  State<AdminScheduledTaskEditorPage> createState() =>
      _AdminScheduledTaskEditorPageState();
}

class _AdminScheduledTaskEditorPageState
    extends State<AdminScheduledTaskEditorPage> {
  late final session = ScheduledTaskEditSession(
    widget.controller,
    original: widget.original,
    now: widget.now,
  );
  ScheduledTaskEditState get state => session.state;
  final scroll = ScrollController();
  late final name = TextEditingController(text: state.name);
  late final prompt = TextEditingController(text: state.prompt);
  late final custom = TextEditingController(text: state.schedule.custom);
  late final minutes = TextEditingController(text: state.schedule.minutes);
  late final timezone = TextEditingController(text: state.timezone);
  late final grace = TextEditingController(text: state.graceMinutes);
  bool allowPop = false;
  ScheduledTasksController get controller => widget.controller;
  bool get editing => state.editing;
  String get id => session.id;
  bool get dirty => state.dirty;
  bool get saving => state.saving;
  TaskScheduleKind get kind => state.schedule.kind;
  TimeOfDay get time =>
      TimeOfDay(hour: state.schedule.hour, minute: state.schedule.minute);
  int get weekday => state.schedule.weekday;
  int get monthDay => state.schedule.monthDay;
  DateTime? get once => state.schedule.once;
  bool get clock => state.schedule.usesClock;
  List<ModelChoice>? get models => state.models;
  List<TaskTemplate>? get templates => state.templateCatalog;
  TaskTemplate? get template => state.template;
  Map<String, String> get templateValues => state.templateValues;
  String? get targetError => state.targetError;
  String? get modelError => state.modelError;
  String? get templateError => state.templateError;
  String? get error => state.error;
  String get model => state.selection.choice?.model ?? '';
  String get provider => state.selection.choice?.provider ?? '';
  Future<void> loadTargets() => session.load(TaskEditCatalog.delivery);
  Widget _catalogRetry(TaskEditCatalog catalog, String name) {
    final loading = session.loadingCatalog(catalog);
    return StudioButtonPress(
      child: IconButton(
        tooltip: 'Refresh $name',
        onPressed: loading ? null : () => session.load(catalog),
        icon: loading
            ? SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  semanticsLabel: 'Refreshing $name',
                  strokeWidth: 2,
                ),
              )
            : const Icon(Icons.refresh),
      ),
    );
  }

  @override
  void dispose() {
    session.dispose();
    scroll.dispose();
    name.dispose();
    prompt.dispose();
    custom.dispose();
    minutes.dispose();
    timezone.dispose();
    grace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => PopScope(
      canPop: allowPop || (!dirty && !saving),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || saving) return;
        if (await adminConfirm(
              context,
              'Discard your changes?',
              'Your task has not been saved.',
              action: 'Discard changes',

              actionIcon: Icons.delete_outline,
              destructive: true,
            ) &&
            mounted) {
          setState(() => allowPop = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context);
          });
        }
      },
      child: TaskPage(
        title: editing ? 'Edit task' : 'New task',
        scope: session.scopeLabel,
        bottom: StudioFormActions(
          onCancel: saving ? null : () => Navigator.maybePop(context),
          onConfirm: !state.canSubmit ? null : save,
          confirmLabel: editing ? 'Save changes' : 'Create task',
          busy: saving,
          progressLabel: editing ? 'Saving task' : 'Creating task',
        ),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            if (MediaQuery.viewInsetsOf(context).bottom == 0 &&
                MediaQuery.textScalerOf(context).scale(16) <= 24) ...[
              Text(
                editing
                    ? 'Fine-tune the routine.'
                    : 'One less thing to remember.',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Hermes runs this task on your server, even when Wing is closed.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
            ],
            if (error != null)
              TaskMessage(
                error!,
                error: true,
                action: state.canReview || state.reviewing
                    ? StudioButtonPress(
                        child: TextButton(
                          onPressed: state.canReview ? reviewChanges : null,
                          child: StudioActionLabel(
                            'Review changes',
                            busy: state.reviewing,
                          ),
                        ),
                      )
                    : null,
              ),
            if (controller.savedUnregisteredId != null)
              StudioButtonPress(
                child: TextButton(
                  onPressed: () {
                    setState(() {
                      allowPop = true;
                    });
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) Navigator.pop(context);
                    });
                  },
                  child: const Text('Return to tasks to review the saved task'),
                ),
              ),
            TaskUncertainty(controller: controller, id: id),
            if (!editing && MediaQuery.viewInsetsOf(context).bottom == 0) ...[
              if (templates?.isNotEmpty == true)
                TaskSurface(
                  child: StudioButtonPress(
                    child: ListTile(
                      leading: const Icon(Icons.auto_awesome_outlined),
                      title: Text(template?.title ?? 'Start from a template'),
                      subtitle: Text(
                        template?.description ??
                            'A useful starting point, ready to make yours.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: saving ? null : chooseTemplate,
                    ),
                  ),
                ),
              if (templateError != null)
                TaskMessage(
                  'Templates could not be loaded. You can still create your own task.',
                  error: true,
                  action: _catalogRetry(
                    TaskEditCatalog.blueprints,
                    'templates',
                  ),
                ),
              const SizedBox(height: 24),
            ],
            if (template != null)
              ...templateFields()
            else ...[
              TaskSection(
                'Task',
                key: const ValueKey('task-editor-instructions'),
                child: Column(
                  children: [
                    viewportSelection(
                      TextFormField(
                        controller: name,
                        onChanged: (value) =>
                            session.setText(TaskEditText.name, value),
                        enabled: !saving,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'Name (optional)',
                          hintText: 'Morning briefing',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (state.scriptOnly)
                      const TaskMessage(
                        'This task runs a server script without an agent. Its execution settings stay on the server.',
                      ),
                    viewportSelection(
                      TextFormField(
                        controller: prompt,
                        onChanged: (value) =>
                            session.setText(TaskEditText.prompt, value),
                        enabled: !saving && !state.scriptOnly,
                        minLines: 4,
                        maxLines: null,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'Instructions',
                          alignLabelWithHint: true,
                          hintText: 'What should your agent do?',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              TaskSection(
                'Schedule',
                description: state.timezone.isEmpty
                    ? 'Recurring times follow the Hermes profile timezone.'
                    : 'Recurring times follow ${state.timezone}.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StudioSelect<TaskScheduleKind>(
                      key: ValueKey(kind),
                      label: 'Frequency',
                      value: kind,
                      options: [
                        for (final k in TaskScheduleKind.values)
                          (value: k, label: k.label),
                      ],
                      onChanged: saving
                          ? null
                          : (value) {
                              if (value != null) {
                                session.setSchedule(
                                  state.schedule.copyWith(kind: value),
                                );
                              }
                            },
                    ),
                    const SizedBox(height: 16),
                    if (clock)
                      StudioButtonPress(
                        child: OutlinedButton.icon(
                          onPressed: saving ? null : chooseTime,
                          icon: const Icon(Icons.schedule_outlined),
                          label: Text(
                            'At ${time.format(context)} · ${state.timezone.isEmpty ? 'Hermes time' : state.timezone}',
                          ),
                        ),
                      ),
                    if (kind == TaskScheduleKind.weekly) ...[
                      const SizedBox(height: 12),
                      StudioSelect<int>(
                        key: ValueKey('weekday-$weekday'),
                        label: 'Day of week',
                        value: weekday,
                        options: [
                          for (var i = 0; i < 7; i++)
                            (
                              value: i,
                              label: [
                                'Sunday',
                                'Monday',
                                'Tuesday',
                                'Wednesday',
                                'Thursday',
                                'Friday',
                                'Saturday',
                              ][i],
                            ),
                        ],
                        onChanged: saving
                            ? null
                            : (v) {
                                if (v != null) {
                                  session.setSchedule(
                                    state.schedule.copyWith(weekday: v),
                                  );
                                }
                              },
                      ),
                    ],
                    if (kind == TaskScheduleKind.monthly) ...[
                      const SizedBox(height: 12),
                      StudioSelect<int>(
                        key: ValueKey('month-$monthDay'),
                        label: 'Day of month',
                        value: monthDay,
                        options: [
                          for (var i = 1; i <= 31; i++) (value: i, label: '$i'),
                        ],
                        onChanged: saving
                            ? null
                            : (v) {
                                if (v != null) {
                                  session.setSchedule(
                                    state.schedule.copyWith(monthDay: v),
                                  );
                                }
                              },
                      ),
                      const SizedBox(height: 8),
                      const Text('Months without this date are skipped.'),
                    ],
                    if (kind == TaskScheduleKind.interval ||
                        kind == TaskScheduleKind.delay)
                      viewportSelection(
                        TextFormField(
                          controller: minutes,
                          onChanged: (value) => session.setSchedule(
                            state.schedule.copyWith(minutes: value),
                          ),
                          enabled: !saving,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: kind == TaskScheduleKind.delay
                                ? 'Run once after (minutes)'
                                : 'Repeat every (minutes)',
                          ),
                        ),
                      ),
                    if (kind == TaskScheduleKind.once)
                      StudioButtonPress(
                        child: OutlinedButton.icon(
                          onPressed: saving ? null : chooseDate,
                          icon: const Icon(Icons.calendar_today_outlined),
                          label: Text(
                            once == null
                                ? 'Choose date and time · Phone time'
                                : '${taskTime(context, once)} · Phone time',
                          ),
                        ),
                      ),
                    if (kind == TaskScheduleKind.custom)
                      viewportSelection(
                        TextFormField(
                          controller: custom,
                          onChanged: (value) => session.setSchedule(
                            state.schedule.copyWith(custom: value),
                          ),
                          enabled: !saving,
                          style: const TextStyle(fontFamily: 'monospace'),
                          decoration: const InputDecoration(
                            labelText: 'Schedule expression',
                            hintText: '0 9 * * 1-5',
                            helperText:
                                'Cron, “every 30m”, or “in 30m” for a single run.',
                            helperMaxLines: 3,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    viewportSelection(
                      TextFormField(
                        controller: timezone,
                        enabled: !saving,
                        onChanged: session.setTimezone,
                        decoration: const InputDecoration(
                          labelText: 'Schedule timezone',
                          hintText: 'Asia/Singapore',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Timezone: IANA name, or empty for the Hermes profile timezone. One-time phone dates remain exact instants.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    StudioSelect<TaskCatchUp>(
                      label: 'Missed runs',
                      value: state.catchUp,
                      options: const [
                        (value: TaskCatchUp.inherit, label: 'Hermes default'),
                        (value: TaskCatchUp.runOnce, label: 'Run one catch-up'),
                        (value: TaskCatchUp.skip, label: 'Skip missed runs'),
                      ],
                      onChanged: saving
                          ? null
                          : (value) {
                              if (value != null) session.setCatchUp(value);
                            },
                    ),
                    const SizedBox(height: 16),
                    viewportSelection(
                      TextFormField(
                        controller: grace,
                        enabled: !saving,
                        onChanged: session.setGrace,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Late window (min)',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Cron window: 0–1440 minutes, or empty for the computed window. Run one catch-up also permits work beyond this window.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'External schedulers control their own delivery and retry timing.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (kind != TaskScheduleKind.custom)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          scheduleSummary(),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            TaskSection(
              'Results',
              description:
                  'Keep the result on your server or send it to a configured server destination.',
              child: StudioLoadingRegion(
                available: true,
                busy: session.loadingDestinations || session.loadingRooms,
                label: 'Loading destinations',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (targetError != null)
                      TaskMessage(
                        targetError!,
                        error: true,
                        action: StudioButtonPress(
                          child: TextButton(
                            onPressed: loadTargets,
                            child: const Text('Refresh destinations'),
                          ),
                        ),
                      ),

                    if (state.roomError != null)
                      TaskMessage(
                        'Group destinations could not be loaded. Existing destinations are kept.',
                        error: true,
                        action: StudioButtonPress(
                          child: IconButton(
                            tooltip: 'Refresh group destinations',
                            onPressed: session.loadingRooms
                                ? null
                                : () => session.load(TaskEditCatalog.rooms),
                            icon: const Icon(Icons.refresh),
                          ),
                        ),
                      ),
                    if (state.deliveryChoices.any(
                      (choice) => choice.discovered,
                    ))
                      TaskSurface(
                        child: Column(
                          children: [
                            for (final destination
                                in state.deliveryChoices.where(
                                  (choice) => choice.discovered,
                                ))
                              StudioSelectionTile(
                                value: destination.selected,
                                onChanged: destination.enabled
                                    ? (selected) => session.setDestination(
                                        destination.id,
                                        selected,
                                      )
                                    : null,
                                title: Text(destination.label),
                                subtitle: Text(destination.description),
                              ),
                          ],
                        ),
                      ),
                    for (final destination in state.deliveryChoices.where(
                      (choice) => !choice.discovered,
                    ))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: StudioSelectionTile(
                          value: destination.selected,
                          onChanged: destination.enabled
                              ? (selected) => session.setDestination(
                                  destination.id,
                                  selected,
                                )
                              : null,
                          title: Text(destination.label),
                          subtitle: Text(destination.description),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (template == null && !state.scriptOnly)
              TaskSection(
                'Model',
                description:
                    'Use the profile’s model at run time, or choose one for this task.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TaskSurface(
                      child: StudioButtonPress(
                        child: ListTile(
                          leading: const Icon(Icons.auto_awesome_outlined),
                          title: Text(
                            model.isEmpty ? 'Profile default' : model,
                          ),
                          subtitle: model.isEmpty
                              ? const Text(
                                  'Follows future profile model changes',
                                )
                              : Text(provider),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: saving || state.customEndpoint
                              ? null
                              : chooseModel,
                        ),
                      ),
                    ),
                    if (state.customEndpoint)
                      const TaskMessage(
                        'This task uses a custom endpoint. Manage its model routing on the server.',
                      ),
                    if (modelError != null) ...[
                      const SizedBox(height: 8),
                      TaskMessage(
                        'Model choices could not be loaded. Your current choice is kept.',
                        error: true,
                        action: _catalogRetry(TaskEditCatalog.models, 'models'),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  String scheduleSummary() => state.schedule.summary(time.format(context));

  Future<void> reviewChanges() async {
    final review = await session.reviewConflicts();
    if (!mounted || review == null) return;
    final pending = <TaskConflictField, TaskConflictDecision>{};
    final decisions =
        await showModalBottomSheet<
          Map<TaskConflictField, TaskConflictDecision>
        >(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (sheetContext) => StatefulBuilder(
            builder: (context, updateChoices) => SizedBox(
              height: MediaQuery.sizeOf(context).height * .8,
              child: Column(
                children: [
                  ListTile(
                    title: const Text('Review task changes'),
                    trailing: StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        const Text(
                          'Choose which values to keep. Apply decisions updates your draft; Save changes saves it on Hermes.',
                        ),
                        const SizedBox(height: 16),
                        if (review.fields.isEmpty)
                          const TaskMessage(
                            'The edited fields no longer conflict with Hermes.',
                          ),
                        for (final field in review.fields)
                          TaskSection(
                            switch (field.field) {
                              TaskConflictField.name => 'Name',
                              TaskConflictField.prompt => 'Instructions',
                              TaskConflictField.schedule => 'Schedule',
                              TaskConflictField.delivery => 'Results',
                              TaskConflictField.timezone => 'Timezone',
                              TaskConflictField.grace => 'Late-run window',
                              TaskConflictField.catchUp => 'Missed runs',
                              TaskConflictField.modelRouting => 'Model routing',
                            },
                            child: Column(
                              children: [
                                StudioSelectionTile(
                                  key: ValueKey(
                                    'task-conflict-${field.field.name}-mine',
                                  ),
                                  value:
                                      pending[field.field] ==
                                      TaskConflictDecision.keepMine,
                                  onChanged: field.canKeepMine
                                      ? (_) => updateChoices(
                                          () => pending[field.field] =
                                              TaskConflictDecision.keepMine,
                                        )
                                      : null,
                                  title: const Text('Keep mine'),
                                  subtitle: Text(
                                    field.mine.isEmpty ? 'Empty' : field.mine,
                                  ),
                                ),
                                StudioSelectionTile(
                                  key: ValueKey(
                                    'task-conflict-${field.field.name}-server',
                                  ),
                                  value:
                                      pending[field.field] ==
                                      TaskConflictDecision.useServer,
                                  onChanged: (_) => updateChoices(
                                    () => pending[field.field] =
                                        TaskConflictDecision.useServer,
                                  ),
                                  title: const Text('Use server'),
                                  subtitle: Text(
                                    field.server.isEmpty
                                        ? 'Empty'
                                        : field.server,
                                  ),
                                ),
                                if (field.keepMineUnavailableReason != null)
                                  TaskMessage(field.keepMineUnavailableReason!),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: StudioFormActions(
                      onCancel: () => Navigator.pop(sheetContext),
                      onConfirm: pending.length == review.fields.length
                          ? () => Navigator.pop(sheetContext, pending)
                          : null,
                      confirmLabel: 'Apply decisions',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    if (!mounted) return;
    if (decisions == null) {
      session.cancelReview(review);
    } else if (session.applyReview(review, decisions) ==
        TaskReviewOutcome.applied) {
      name.text = state.name;
      prompt.text = state.prompt;
      custom.text = state.schedule.custom;
      minutes.text = state.schedule.minutes;
      timezone.text = state.timezone;
      grace.text = state.graceMinutes;
    }
  }

  Future<void> chooseTime() async {
    final value = await showTimePicker(
      context: context,
      initialTime: time,
      helpText:
          'Time in ${state.timezone.isEmpty ? 'the Hermes profile timezone' : state.timezone}',
    );
    if (value != null && mounted) {
      session.setSchedule(
        state.schedule.copyWith(hour: value.hour, minute: value.minute),
      );
    }
  }

  Future<void> chooseDate() async {
    final input = session.datePickerInput;
    final date = await showDatePicker(
      context: context,
      initialDate: input.initialDate,
      firstDate: input.firstDate,
      lastDate: input.lastDate,
      helpText: 'Date in your phone’s timezone',
    );
    if (date == null || !mounted) return;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(input.initialTime),
      helpText: 'Time in your phone’s timezone',
    );
    if (selected != null && mounted) {
      session.setOnceDateTime(
        date,
        hour: selected.hour,
        minute: selected.minute,
      );
    }
  }

  Future<void> chooseModel() async {
    final initial = state.selection;
    ModelSelection pending = initial;
    final selected = await showModalBottomSheet<ModelSelection>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updatePicker) {
          final keyboard = MediaQuery.viewInsetsOf(context).bottom;
          final height = (MediaQuery.sizeOf(context).height - keyboard - 24)
              .clamp(0.0, MediaQuery.sizeOf(context).height * .82);
          return Padding(
            padding: EdgeInsets.only(bottom: keyboard),
            child: SizedBox(
              height: height,
              child: Column(
                children: [
                  ListTile(
                    title: const Text('Task model'),
                    trailing: StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ModelChooser(
                      choices: models ?? const [],
                      selected: pending,
                      specialOptions: const [
                        ModelSpecialOption(
                          ModelSpecialChoice.profileDefault,
                          'Profile default',
                          description: 'Follows future profile model changes',
                        ),
                      ],
                      scopeLabel: 'Models for ${session.profileName}',
                      onRefresh: session.refreshModels,
                      onSelected: (choice) =>
                          updatePicker(() => pending = choice),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: StudioFormActions(
                      onCancel: () => Navigator.pop(sheetContext),
                      onConfirm: pending == initial
                          ? null
                          : () => Navigator.pop(sheetContext, pending),
                      confirmLabel: 'Use in task',
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || selected == null) return;
    session.setModel(selected);
  }

  Future<void> chooseTemplate() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Start with a routine',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              StudioButtonPress(
                child: ListTile(
                  title: const Text('Write my own task'),
                  onTap: () => Navigator.pop(context, ''),
                ),
              ),
              for (final item in templates!)
                StudioButtonPress(
                  child: ListTile(
                    title: Text(item.title),
                    subtitle: Text(
                      item.supported
                          ? item.description
                          : 'This template uses unsupported fields.',
                    ),
                    enabled: item.supported,
                    onTap: () => Navigator.pop(context, item.key),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    session.setTemplate(selected);
  }

  List<Widget> templateFields() => [
    for (final field in template!.inputFields)
      TaskSection(
        field.label,
        description: field.help.isEmpty ? null : field.help,
        child: _templateField(field),
      ),
  ];
  Widget _templateField(TaskTemplateField field) {
    final value = templateValues[field.name];
    if (field.selectable) {
      return StudioSelect<String>(
        key: ValueKey('${template!.key}-${field.name}-$value'),
        label: field.label,
        value: field.options.contains(value) ? value : null,
        options: [
          for (final option in field.options) (value: option, label: option),
        ],
        onChanged: saving
            ? null
            : (value) {
                if (value != null) session.setTemplateValue(field.name, value);
              },
      );
    }
    return viewportSelection(
      TextFormField(
        key: ValueKey('${template!.key}-${field.name}'),
        initialValue: value,
        enabled: !saving,
        decoration: InputDecoration(
          labelText: field.label,
          hintText: field.kind == TaskTemplateFieldKind.time
              ? '09:00 · Hermes time'
              : null,
        ),
        onChanged: (value) => session.setTemplateValue(field.name, value),
      ),
    );
  }

  Future<void> save() async {
    final outcome = await session.save();
    if (!mounted) return;
    if (outcome == TaskEditOutcome.confirmed) {
      setState(() => allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } else if (state.error != null && scroll.hasClients) {
      scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    }
  }
}
