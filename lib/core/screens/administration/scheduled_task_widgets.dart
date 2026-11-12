import 'package:wing/core/widgets/studio_loading.dart';
import '../../widgets/wing_app_bar.dart';
import 'package:flutter/material.dart';
import '../../services/administration_repository.dart';

import '../../models/scheduled_task.dart';
import '../../services/scheduled_tasks_controller.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/server_connection_label.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/workspace_action_menu.dart';
import 'admin_widgets.dart';

String taskTime(BuildContext context, DateTime? time) {
  if (time == null) return 'Not scheduled';
  final local = time.toLocal();
  final now = DateTime.now();
  final date = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final day = date == today
      ? 'Today'
      : date == today.add(const Duration(days: 1))
      ? 'Tomorrow'
      : MaterialLocalizations.of(context).formatMediumDate(local);
  return '$day, ${TimeOfDay.fromDateTime(local).format(context)}';
}

class TaskPage extends StatelessWidget {
  const TaskPage({
    super.key,
    required this.title,
    required this.scope,
    required this.child,
    this.actions = const [],
    this.bottom,
  });
  final String title, scope;
  final Widget child;
  final List<Widget> actions;
  final Widget? bottom;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: WingAppBar(
        context: context,

        title: Text(title, maxLines: 6),
        actions: actions,
      ),
      bottomNavigationBar: bottom == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  12 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: bottom,
              ),
            ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: ServerConnectionScope.of(context) == null
                ? Text(scope, style: Theme.of(context).textTheme.bodySmall)
                : ServerConnectionLabel(
                    label: scope,
                    includeProfiles:
                        scope != ServerConnectionScope.of(context)?.label,
                    status: ServerConnectionScope.of(context),
                  ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class TaskSection extends StatelessWidget {
  const TaskSection(
    this.title, {
    super.key,
    required this.child,
    this.description,
  });
  final String title;
  final String? description;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(description!, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
}

class TaskSurface extends StatelessWidget {
  const TaskSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Material(
    color: WingTokens.of(context).raised,
    shape: RoundedRectangleBorder(
      borderRadius: WingRadius.card,
      side: BorderSide(color: WingTokens.of(context).border),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class TaskStatus extends StatelessWidget {
  const TaskStatus(this.task, {super.key, required this.confirmed});
  final bool confirmed;
  final ScheduledTask task;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = task.needsAttention
        ? colors.error
        : task.paused || !task.enabled
        ? colors.onSurfaceVariant
        : colors.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (confirmed && task.running)
          StudioWorkingIndicator.independent(
            label: 'Scheduled task running',
            size: 15,
            color: color,
          )
        else
          Icon(
            task.running
                ? Icons.play_arrow_rounded
                : task.paused
                ? Icons.pause_rounded
                : task.needsAttention
                ? Icons.error_outline
                : Icons.schedule_outlined,
            size: 15,
            color: color,
          ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            task.needsAttention && task.state != 'error'
                ? '${task.statusLabel} · Last run failed'
                : task.statusLabel,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class TaskMessage extends StatelessWidget {
  const TaskMessage(this.text, {super.key, this.error = false, this.action});
  final String text;
  final bool error;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (error)
          StudioError(text)
        else
          Text(text, style: Theme.of(context).textTheme.bodySmall),
        ?action,
      ],
    ),
  );
}

Future<void> performTaskAction(
  BuildContext context,
  ScheduledTasksController controller,
  ScheduledTask task,
  TaskAction action,
) async {
  final choice = controller.actionChoice(task, action);
  if (choice?.enabled != true) return;
  final prompt = choice!.confirmation;
  if (prompt != null &&
      !await adminConfirm(
        context,
        prompt.title,
        prompt.message,
        action: prompt.buttonLabel,

        actionIcon: action == TaskAction.remove
            ? Icons.delete_outline
            : Icons.play_arrow_outlined,
        destructive: action == TaskAction.remove,
      )) {
    return;
  }
  if (!context.mounted) return;
  try {
    await controller.perform(task, action);
  } catch (_) {
    /* The retained owner publishes the result. */
  }
}

class TaskStopProgress extends StatelessWidget {
  const TaskStopProgress({super.key});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 18,
    child: CircularProgressIndicator(
      strokeWidth: 2,
      semanticsLabel: 'Stopping run',
      value: MediaQuery.disableAnimationsOf(context) ? .75 : null,
    ),
  );
}

class TaskMenu extends StatelessWidget {
  const TaskMenu({
    super.key,
    required this.task,
    required this.controller,
    required this.onEdit,
    this.showStopProgress = true,
  });
  final ScheduledTask task;
  final ScheduledTasksController controller;
  final VoidCallback onEdit;
  final bool showStopProgress;
  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => StudioButtonPress(
      child: IconButton(
        tooltip: 'Actions for ${task.title}',
        icon: showStopProgress && controller.stopping(task.id)
            ? const TaskStopProgress()
            : const Icon(Icons.more_horiz),
        onPressed: !controller.actions(task).any((choice) => choice.enabled)
            ? null
            : () async {
                final result = await showWorkspaceActionMenu(
                  anchor,
                  task.title,
                  controller.repository.profile.label,
                  [
                    for (final choice in controller.actions(task))
                      (
                        choice.kind.name,
                        choice.label,
                        switch (choice.kind) {
                          TaskAction.edit => Icons.edit_outlined,
                          TaskAction.pause => Icons.pause_rounded,
                          TaskAction.resume => Icons.play_arrow_rounded,
                          TaskAction.trigger => Icons.bolt_outlined,
                          TaskAction.cancel => Icons.stop_rounded,
                          TaskAction.remove => Icons.delete_outline,
                        },
                        choice.enabled,
                      ),
                  ],
                  keyPrefix: 'task',
                );
                if (!context.mounted || result == null) return;
                if (result == 'edit') {
                  onEdit();
                } else {
                  await performTaskAction(
                    context,
                    controller,
                    task,
                    TaskAction.values.singleWhere(
                      (action) => action.name == result,
                    ),
                  );
                }
              },
      ),
    ),
  );
}

class TaskUncertainty extends StatelessWidget {
  const TaskUncertainty({
    super.key,
    required this.controller,
    required this.id,
  });
  final ScheduledTasksController controller;
  final String id;
  @override
  Widget build(BuildContext context) {
    final notice = controller.pendingNotice(id);
    if (notice == null) return const SizedBox.shrink();
    return TaskMessage(
      notice,
      error: true,
      action: StudioButtonPress(
        child: TextButton(
          child: const Text('Review request'),
          onPressed: () async {
            final prompt = await controller.reviewPrompt(id);
            if (!context.mounted || prompt == null) return;
            final acknowledged = await adminConfirm(
              context,
              prompt.title,
              prompt.message,
              action: prompt.buttonLabel,

              actionIcon: Icons.rule,
              destructive: false,
            );
            if (acknowledged) {
              try {
                await controller.acknowledgeUncertainty(id);
              } catch (e) {
                if (context.mounted) {
                  adminMessage(context, taskFailure(e), isError: true);
                }
              }
            }
          },
        ),
      ),
    );
  }
}

/// Lease the selected profile independently of the page beneath this route.
/// Existing tasks must be resolved in that profile before showing any actions.
class AdminTaskRoute extends StatefulWidget {
  const AdminTaskRoute({
    super.key,
    required this.profile,
    required this.acquireController,
    required this.title,
    required this.builder,
    this.taskId,
  });
  final ProfileAdministration profile;
  final ScheduledTasksController Function() acquireController;
  final String title;
  final String? taskId;
  final Widget Function(ScheduledTasksController, ScheduledTask?) builder;
  @override
  State<AdminTaskRoute> createState() => _AdminTaskRouteState();
}

class _AdminTaskRouteState extends State<AdminTaskRoute> {
  late final controller = widget.acquireController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !controller.loading) controller.refresh();
    });
  }

  @override
  void dispose() {
    controller.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final task = widget.taskId == null
          ? null
          : controller.task(widget.taskId!);
      if (widget.taskId == null || task != null) {
        return widget.builder(controller, task);
      }
      return TaskPage(
        title: widget.title,
        scope: widget.profile.label,
        actions: [
          if (controller.stopping(widget.taskId!))
            const Padding(
              padding: EdgeInsets.all(12),
              child: TaskStopProgress(),
            ),
        ],
        child: controller.loading
            ? StudioPageLoading.waiting(label: 'Loading task history')
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TaskUncertainty(controller: controller, id: widget.taskId!),
                  if (controller.error case final error?)
                    AdminNotice.error(error)
                  else
                    const AdminNotice(
                      'This task is not available in this profile.',
                    ),
                  StudioButtonPress(
                    child: TextButton(
                      onPressed: controller.refresh,
                      child: const Text('Refresh'),
                    ),
                  ),
                ],
              ),
      );
    },
  );
}
