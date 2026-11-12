import '../widgets/selection_viewport.dart';
import '../widgets/studio_form_actions.dart';
import '../widgets/studio_error.dart';
import '../theme/wing_theme.dart';
import 'profile_project_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_list_view.dart';
import '../models/browser_actions.dart';
import '../widgets/workspace_action_menu.dart';
import '../services/chat_browser_data.dart';

Future<void> showSavedDraftActions(
  BuildContext context,
  BrowserActionSession session,
  BrowserDraft draft,
  String title,
) async {
  final action =
      await showWorkspaceActionMenu(context, title, session.scope.profileName, [
        ('edit', 'Continue editing', Icons.edit_outlined, true),
        ('delete', 'Discard draft', Icons.delete_outline, true),
      ]);
  if (action == null || !context.mounted) return;
  if (action == 'edit') {
    await session.perform(BrowserAction.editDraft);
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StudioDialog(
      scrollable: true,
      title: const Text('Discard draft?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, maxLines: 3, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 16),
          const Text(
            'This removes the draft and its queued messages. Sent messages stay in the chat.',
          ),
          if (draft.submissionUncertain) ...[
            const SizedBox(height: 12),
            const Text(
              'Delivery was uncertain. Discarding will not cancel a message already received by Hermes.',
            ),
          ],
        ],
      ),
      actions: [
        StudioFormActions(
          onCancel: () => Navigator.pop(context, false),
          onConfirm: () => Navigator.pop(context, true),
          confirmLabel: 'Discard draft',
          confirmIcon: Icons.delete_outline,
          destructive: true,
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (!await session.perform(BrowserAction.delete)) {
    if (session.state.error case final error?) throw StateError(error);
    return;
  }
  if (messenger.mounted) {
    messenger.showSnackBar(const SnackBar(content: Text('Draft discarded')));
  }
}

Future<void> showChatActions(
  BuildContext context,
  BrowserActionSession session,
) async {
  final key = session.entry!.sessionKey;
  final title = session.title;
  final action =
      await showWorkspaceActionMenu(context, title, session.scope.profileName, [
        for (final choice in session.choices)
          (
            choice.action.name,
            choice.label,
            switch (choice.action) {
              BrowserAction.rename => Icons.edit_outlined,
              BrowserAction.pin => Icons.push_pin_outlined,
              BrowserAction.unread => Icons.mark_email_unread_outlined,
              BrowserAction.copy => Icons.copy_outlined,
              BrowserAction.move => Icons.drive_file_move_outlined,
              BrowserAction.archive => Icons.archive_outlined,
              _ => Icons.delete_outline,
            },
            choice.enabled,
          ),
      ]);
  if (action == null || !context.mounted) return;
  if (action == 'copy') {
    await Clipboard.setData(ClipboardData(text: key.sessionId));
    return;
  }
  if (action == 'move') {
    await showChatProjectPicker(context, session);
  } else if (action == 'rename') {
    await showChatRenameDialog(context, session);
  } else if (action == 'delete') {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        scrollable: true,
        title: const Text('Delete chat?'),
        content: Text(
          'Permanently delete "$title" from ${session.scope.profileName}? Its stored history cannot be recovered. Archive it instead to keep the conversation.',
        ),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: 'Delete chat',
            confirmIcon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await _submit(session, BrowserAction.delete);
    }
  } else {
    await _submit(session, BrowserAction.values.byName(action));
  }
}

Future<void> showChatRenameDialog(
  BuildContext context,
  BrowserActionSession session,
) => showDialog<void>(
  context: context,
  builder: (_) => _ChatRenameDialog(session: session),
);

class _ChatRenameDialog extends StatefulWidget {
  const _ChatRenameDialog({required this.session});
  final BrowserActionSession session;

  @override
  State<_ChatRenameDialog> createState() => _ChatRenameDialogState();
}

class _ChatRenameDialogState extends State<_ChatRenameDialog> {
  late final _title = TextEditingController(text: widget.session.title);
  int _editRevision = 0;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    _title.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final revision = _editRevision;
    final title = await widget.session.generateTitle();
    if (!mounted || title == null || revision != _editRevision) return;
    setState(() {
      _title.value = TextEditingValue(
        text: title,
        selection: TextSelection.collapsed(offset: title.length),
      );
    });
  }

  Future<void> _save() async {
    final saved = await widget.session.perform(
      BrowserAction.rename,
      name: _title.text,
    );
    if (saved && mounted) Navigator.pop(context);
  }

  Widget _progress(String label) => SizedBox.square(
    dimension: 20,
    child: CircularProgressIndicator(
      value: MediaQuery.disableAnimationsOf(context) ? 0.75 : null,
      strokeWidth: 2,
      semanticsLabel: label,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = widget.session.state;
    final pending = state.submitting || state.generatingTitle;
    return PopScope(
      canPop: !state.submitting,
      child: StudioDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text('Rename chat'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              viewportSelection(
                TextField(
                  key: const ValueKey('chat-rename-title'),
                  controller: _title,
                  autofocus: true,
                  enabled: !state.submitting,
                  maxLength: 100,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() => _editRevision++),
                  onSubmitted: (_) {
                    if (!pending &&
                        widget.session.available &&
                        _title.text.trim().isNotEmpty) {
                      _save();
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Chat title',
                    suffixIcon: StudioButtonPress(
                      child: IconButton(
                        key: const ValueKey('chat-rename-ai'),
                        tooltip: 'Auto rename',
                        onPressed: pending || !widget.session.available
                            ? null
                            : _generate,
                        icon: state.generatingTitle
                            ? _progress('Generating chat title')
                            : const Icon(Icons.auto_awesome_outlined),
                      ),
                    ),
                  ),
                ),
              ),
              if (state.error case final error?) ...[
                const SizedBox(height: 12),
                StudioError(error),
              ],
            ],
          ),
        ),
        actions: [
          StudioFormActions(
            onCancel: state.submitting ? null : () => Navigator.pop(context),
            onConfirm:
                pending ||
                    !widget.session.available ||
                    _title.text.trim().isEmpty
                ? null
                : _save,
            confirmKey: const ValueKey('chat-rename-save'),
            confirmLabel: 'Save chat title',
            busy: state.submitting,
            progressLabel: 'Saving chat title',
          ),
        ],
      ),
    );
  }
}

Future<void> _submit(
  BrowserActionSession session,
  BrowserAction action, {
  String name = '',
}) async {
  if (!await session.perform(action, name: name)) {
    if (session.state.error case final error?) throw StateError(error);
  }
}

Future<void> showChatProjectPicker(
  BuildContext context,
  BrowserActionSession session,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final message = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => _ChatProjectSheet(session: session),
  );
  if (message != null && messenger.mounted) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ChatProjectSheet extends StatefulWidget {
  const _ChatProjectSheet({required this.session});
  final BrowserActionSession session;
  @override
  State<_ChatProjectSheet> createState() => _ChatProjectSheetState();
}

class _ChatProjectSheetState extends State<_ChatProjectSheet> {
  final search = TextEditingController();
  bool get _moving => widget.session.state.submitting;
  String? get _failure => widget.session.state.error;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    search.dispose();
    super.dispose();
  }

  Future<void> move(BrowserProject? project) async {
    FocusScope.of(context).unfocus();
    final destination = project == null
        ? 'the default project of ${widget.session.scope.profileName}'
        : '"${project.name}" in ${widget.session.scope.profileName}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        title: const Text('Move chat?'),
        content: Text(
          'Move this chat to $destination? Its messages will be kept.',
        ),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: 'Move chat',
            confirmIcon: Icons.drive_file_move_outlined,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final moved = await widget.session.perform(
      BrowserAction.move,
      target: project,
    );
    if (moved && mounted) {
      Navigator.pop(
        context,
        project == null
            ? 'Moved to the default project of ${widget.session.scope.profileName}'
            : 'Moved to ${project.name}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = search.text.trim().toLowerCase();
    final projects = widget.session.projects
        .where(
          (project) =>
              project.name.toLowerCase().contains(query) ||
              project.directory.toLowerCase().contains(query),
        )
        .toList();
    final current = widget.session.currentProject;
    return PopScope(
      canPop: !_moving,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  MediaQuery.sizeOf(context).height * .85 -
                  MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Padding(
              key: const ValueKey('chat-project-sheet'),
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Move to project',
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Projects in ${widget.session.scope.profileName}',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 16),
                          Semantics(
                            selected: true,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: WingRadius.card,
                              ),
                              child: Row(
                                children: [
                                  if (current != null)
                                    projectAvatar(context, current, size: 32)
                                  else
                                    const Icon(
                                      Icons.folder_open_outlined,
                                      size: 24,
                                    ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Current project',
                                          style: theme.textTheme.labelSmall,
                                        ),
                                        Text(
                                          current?.name ?? 'Unassigned',
                                          style: theme.textTheme.titleSmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (widget.session.canRemoveProject) ...[
                                    const SizedBox(width: 8),
                                    StudioButtonPress(
                                      child: IconButton(
                                        tooltip: 'Remove from project',
                                        onPressed: _moving
                                            ? null
                                            : () => move(null),
                                        icon: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            const Icon(Icons.close),
                                            if (_moving &&
                                                widget.session.state.moving ==
                                                    null)
                                              SizedBox.square(
                                                dimension: 32,
                                                child: CircularProgressIndicator(
                                                  value:
                                                      MediaQuery.disableAnimationsOf(
                                                        context,
                                                      )
                                                      ? .75
                                                      : null,
                                                  strokeWidth: 2,
                                                  semanticsLabel: 'Moving chat',
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Choose a project to change this chat’s working folder.',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 16),
                          if (widget.session.projects.isNotEmpty) ...[
                            viewportSelection(
                              TextField(
                                key: const ValueKey('project-picker-search'),
                                controller: search,
                                enabled: !_moving,
                                onChanged: (_) => setState(() {}),
                                decoration: InputDecoration(
                                  hintText: 'Find a project',
                                  prefixIcon: const Icon(Icons.search),
                                  suffixIcon: search.text.isEmpty
                                      ? null
                                      : StudioButtonPress(
                                          child: IconButton(
                                            tooltip: 'Clear search',
                                            onPressed: !_moving
                                                ? () {
                                                    search.clear();
                                                    setState(() {});
                                                  }
                                                : null,
                                            icon: const Icon(Icons.close),
                                          ),
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (_failure != null) ...[
                            Semantics(
                              liveRegion: true,
                              child: StudioError(_failure!),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (projects.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Text(
                                widget.session.projects.isEmpty
                                    ? 'No other projects with a working folder are available.'
                                    : 'No matching projects. Try another name or folder.',
                              ),
                            )
                          else
                            Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant,
                                ),
                                borderRadius: WingRadius.card,
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: [
                                  for (var i = 0; i < projects.length; i++) ...[
                                    if (i > 0) const Divider(height: 1),
                                    StudioButtonPress(
                                      child: ListTile(
                                        key: ValueKey(
                                          'move-project-${projects[i].id}',
                                        ),
                                        enabled: !_moving,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 4,
                                            ),
                                        minTileHeight: 64,
                                        leading: projectAvatar(
                                          context,
                                          projects[i],
                                          size: 32,
                                        ),
                                        title: Text(projects[i].name),
                                        subtitle: Text(
                                          projects[i].directory,
                                          style: theme.textTheme.bodySmall,
                                        ),
                                        trailing:
                                            widget.session.state.moving ==
                                                projects[i]
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      semanticsLabel:
                                                          'Moving chat',
                                                    ),
                                              )
                                            : null,
                                        onTap: !_moving
                                            ? () => move(projects[i])
                                            : null,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Cancel project selection',
                        onPressed: !_moving
                            ? () => Navigator.pop(context)
                            : null,
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
