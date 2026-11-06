import '../../widgets/selection_viewport.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../../models/profile_session_key.dart';
import 'package:flutter/material.dart';

import '../../models/scheduled_task.dart';
import '../../services/scheduled_tasks_controller.dart';
import '../../services/scheduled_task_detail_session.dart';
import '../../widgets/activity/activity_detail_actions.dart';
import 'admin_scheduled_task_editor_page.dart';
import 'admin_widgets.dart';
import 'scheduled_task_widgets.dart';

class AdminScheduledTaskDetailPage extends StatefulWidget {
  const AdminScheduledTaskDetailPage({
    super.key,
    required this.controller,
    required this.initial,
    required this.onOpenSession,
    this.onInvestigate,
  });
  final ScheduledTasksController controller;
  final ScheduledTask initial;
  final Future<void> Function(ProfileSessionKey) onOpenSession;
  final ValueChanged<ScheduledTaskInvestigationRequest>? onInvestigate;
  @override
  State<AdminScheduledTaskDetailPage> createState() =>
      _AdminScheduledTaskDetailPageState();
}

class _AdminScheduledTaskDetailPageState
    extends State<AdminScheduledTaskDetailPage>
    with WidgetsBindingObserver {
  ScheduledTasksController get controller => widget.controller;
  late final session = ScheduledTaskDetailSession(
    controller,
    widget.initial,
    isVisible: () => mounted && ModalRoute.of(context)?.isCurrent == true,
    onOpenSession: widget.onOpenSession,
  );
  ScheduledTaskDetailState get state => session.state;
  List<TaskRun>? get runs => state.history;
  String? get runError => state.error;
  bool get loading => state.loading;
  bool get opening => state.opening;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) session.refresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    session.resumed(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    session.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> refresh() => session.refresh();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final task = state.task;
      final missing = state.missing;
      final toggle = controller.toggleChoice(task);
      final cancel = controller.actionChoice(task, TaskAction.cancel);
      final trigger = controller.actionChoice(task, TaskAction.trigger)!;
      final theme = Theme.of(context);
      return TaskPage(
        title: 'Task details',
        scope: controller.repository.profile.label,
        actions: [
          if (!missing)
            TaskMenu(
              task: task,
              controller: controller,
              onEdit: () => adminPushProfile(
                context,
                controller.repository.profile,
                (context, profile) => AdminTaskRoute(
                  profile: profile,
                  acquireController: controller.acquireLease,
                  title: 'Edit task',
                  taskId: task.id,
                  builder: (controller, selectedTask) =>
                      AdminScheduledTaskEditorPage(
                        controller: controller,
                        original: selectedTask,
                      ),
                ),
              ),
            ),
        ],
        bottom: missing
            ? null
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (controller.busy.contains(task.id))
                    SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                        semanticsLabel: 'Updating task',
                        value: MediaQuery.disableAnimationsOf(context)
                            ? .75
                            : null,
                      ),
                    ),
                  for (final choice in [?toggle, ?cancel, trigger])
                    StudioButtonPress(
                      child: IconButton.filledTonal(
                        tooltip: choice.label,
                        onPressed: choice.enabled
                            ? () => performTaskAction(
                                context,
                                controller,
                                task,
                                choice.kind,
                              )
                            : null,
                        icon: Icon(switch (choice.kind) {
                          TaskAction.pause => Icons.pause_rounded,
                          TaskAction.cancel => Icons.stop_rounded,
                          TaskAction.trigger => Icons.bolt_outlined,
                          _ => Icons.play_arrow_rounded,
                        }),
                      ),
                    ),
                ],
              ),
        child: StudioRefresh(
          available: true,
          label: 'Loading runs',
          onRefresh: refresh,
          child: ListView(
            key: const ValueKey('task-detail-scroll'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text(
                task.title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),
              TaskStatus(
                task,
                confirmed:
                    !missing &&
                    controller.checkedAt != null &&
                    controller.error == null,
              ),
              const SizedBox(height: 24),
              if (missing)
                const TaskMessage(
                  'This task is no longer in the schedule. One-time tasks may be removed after their final run. Recent runs remain below.',
                ),
              if (controller.error != null)
                TaskMessage(controller.error!, error: true),
              if (controller.notice != null) TaskMessage(controller.notice!),
              TaskUncertainty(controller: controller, id: task.id),
              if (!missing)
                TaskSurface(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.nextRunHeading,
                          style: TextStyle(
                            fontSize: 12,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          task.nextRunText ?? taskTime(context, task.nextRun),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          task.scheduleLabel,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 16),
                        const Divider(height: 1),
                        const SizedBox(height: 16),
                        Text(
                          'Run times use your phone’s timezone. Schedule timezone: ${task.timezoneLabel}. Pause changes future runs; Stop cancels the current run.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              if (task.error.isNotEmpty)
                TaskSection(
                  task.needsAttention
                      ? 'Last run needs attention'
                      : 'Last run outcome',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          if (widget.onInvestigate != null &&
                              task.needsAttention)
                            AdminAskHermesButton(
                              label: 'Ask ${task.profileName}',
                              onPressed: () => widget.onInvestigate!(
                                ScheduledTaskInvestigationRequest(
                                  owner: controller.repository.profile.scope,
                                  task: task,
                                ),
                              ),
                            ),
                          ToolDetailCopyButton(
                            label: task.needsAttention
                                ? 'Copy task error'
                                : 'Copy run outcome',
                            text: task.error,
                          ),
                        ],
                      ),
                      TaskMessage(task.error, error: task.needsAttention),
                    ],
                  ),
                ),
              TaskSection(
                'Task',
                child: viewportSelection(
                  SelectableText(task.instructionsDisplay),
                ),
              ),
              TaskSection(
                'Details',
                child: TaskSurface(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _fact('Results', task.destinationsDisplay),
                        _fact('Model', task.modelDisplay),
                        _fact('Missed runs', task.catchUpLabel),
                        if (task.schedule['kind'] == 'cron')
                          _fact('Late-run window', task.graceLabel),
                        if (task.latestExecution case final execution?)
                          _fact(
                            'Latest attempt',
                            '${execution.label}${execution.reason.isEmpty ? '' : ': ${execution.reason}'}',
                          ),
                        _fact(
                          'Last run',
                          task.lastRun == null
                              ? 'No recorded run'
                              : taskTime(context, task.lastRun),
                        ),
                        if (task.text('script').isNotEmpty)
                          _fact('Server script', task.text('script')),
                        if (task.skills.isNotEmpty)
                          _fact('Skills', task.skills.join(', ')),
                        if (task.contextFrom.isNotEmpty)
                          _fact('Context from', task.contextFrom.join(', ')),
                      ],
                    ),
                  ),
                ),
              ),
              TaskSection(
                'Recent runs',
                description:
                    'Open conversation runs to read the chat. Script runs show their recorded status and output preview here.',
                child: StudioLoadingRegion(
                  available: state.history != null,
                  busy: loading,
                  label: 'Loading runs',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (runError != null)
                        TaskMessage(
                          runError!,
                          error: true,
                          action: StudioButtonPress(
                            child: TextButton(
                              onPressed: loading ? null : refresh,
                              child: const Text('Refresh runs'),
                            ),
                          ),
                        ),
                      if (runs?.isEmpty == true)
                        Text(
                          'No recorded runs yet.',
                          style: theme.textTheme.bodySmall,
                        ),
                      if (runs?.isNotEmpty == true)
                        TaskSurface(
                          child: Column(
                            children: [
                              for (var i = 0; i < runs!.length; i++) ...[
                                if (i > 0) const Divider(height: 1),
                                _runTile(runs![i]),
                              ],
                            ],
                          ),
                        ),
                      if (state.canShowMore)
                        StudioButtonPress(
                          child: TextButton(
                            onPressed: loading ? null : session.showMore,
                            child: const Text('Show more runs'),
                          ),
                        ),
                      if (state.atLimit)
                        const Text('Showing the latest 100 runs.'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  Widget _runTile(TaskRun run) => StudioButtonPress(
    child: ListTile(
      key: ValueKey('task-run-${run.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: Icon(
        run.isConversation
            ? run.active
                  ? Icons.play_arrow_rounded
                  : Icons.chat_bubble_outline
            : Icons.description_outlined,
        size: 20,
      ),
      title: Text(
        run.title.isNotEmpty
            ? run.title
            : run.isConversation
            ? 'Task conversation'
            : run.isScriptOutput
            ? 'Script run'
            : 'Run record',
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${run.isConversation
                ? 'Conversation'
                : run.isScriptOutput
                ? 'Script output'
                : 'Run record'} · ${taskTime(context, run.started)}${run.active ? ' · Active' : ''}',
          ),
          if (run.preview.isNotEmpty && !run.title.contains(run.preview)) ...[
            const SizedBox(height: 4),
            viewportSelection(SelectableText(run.preview)),
          ],
        ],
      ),
      trailing: run.isConversation
          ? const Icon(Icons.chevron_right, size: 18)
          : null,
      onTap: run.isConversation && !opening ? () => session.open(run) : null,
    ),
  );
  Widget _fact(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        viewportSelection(SelectableText(value)),
      ],
    ),
  );
}
