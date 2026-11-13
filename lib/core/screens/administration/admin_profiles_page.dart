import '../../widgets/selection_viewport.dart' show viewportSelection;
import '../../widgets/studio_error.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/profiles_management_session.dart';
import 'admin_widgets.dart';

enum ProfileManagementEntry { rename, delete }

class AdminProfilesPage extends StatefulWidget {
  const AdminProfilesPage({
    super.key,
    required this.createSession,
    this.initialProfile,
    this.initialAction,
  });
  final ProfilesManagementSession Function() createSession;
  final String? initialProfile;
  final ProfileManagementEntry? initialAction;
  @override
  State<AdminProfilesPage> createState() => _AdminProfilesPageState();
}

class _AdminProfilesPageState extends State<AdminProfilesPage> {
  late final ProfilesManagementSession _session;
  int? _announced;

  @override
  void initState() {
    super.initState();
    _session = widget.createSession();
    _session.addListener(_changed);
    unawaited(_enter());
  }

  Future<void> _enter() async {
    await _session.reload();
    if (!mounted || widget.initialProfile == null) return;
    final intent = switch (widget.initialAction) {
      ProfileManagementEntry.rename => _session.beginRename(
        widget.initialProfile!,
      ),
      ProfileManagementEntry.delete => _session.beginDelete(
        widget.initialProfile!,
      ),
      null => null,
    };
    if (intent != null) await _edit(intent);
  }

  void _changed() {
    if (!mounted) return;
    final outcome = _session.state.outcome;
    if (outcome != null &&
        outcome.announcesSuccess &&
        outcome.sequence != _announced) {
      _announced = outcome.sequence;
      adminMessage(context, outcome.message);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _session.dispose();
    super.dispose();
  }

  Future<void> _edit(ProfilesManagementIntent? intent) async {
    if (intent == null) return;
    var draft = _session.state.draft;
    if (draft == null) return;
    if (draft.needsName) {
      final continued = await showDialog<bool>(
        context: context,
        builder: (_) => _ProfileNameDialog(session: _session, intent: intent),
      );
      if (!mounted) return;
      if (continued != true) _session.cancel(intent);
      return;
    }
    draft = _session.state.draft;
    if (draft == null) return;
    if (draft.needsConfirmation) {
      final confirmed = await adminConfirm(
        context,
        draft.confirmationTitle,
        draft.confirmationDetail,
        action: draft.confirmationAction,

        actionIcon: draft.needsName ? Icons.check : Icons.delete_outline,
        destructive: !draft.needsName,
      );
      if (!mounted) return;
      if (!confirmed) {
        _session.cancel(intent);
        return;
      }
    }
    await _session.submit(intent);
  }

  Future<void> _open(String name) async {
    final opened = await _session.open(name);
    if (mounted && opened) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final state = _session.state;
    final pending = _session.pendingIntent;
    return AdminPage(
      title: 'Profiles',
      scope: state.scope,
      child: StudioLoadingRegion(
        available: state.hasObservation,
        busy: state.loading || state.busy,
        label: 'Loading profiles',
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (state.error != null) AdminNotice.error(state.error!),
            for (final settlement in state.settlements) ...[
              AdminNotice(settlement.message),
              viewportSelection(SelectableText(settlement.manualGuidance!)),
              const SizedBox(height: 12),
            ],
            if (!state.busy &&
                state.error != null &&
                pending != null &&
                state.draft != null)
              Wrap(
                spacing: 8,
                children: [
                  if (state.draft!.canSubmit)
                    StudioButtonPress(
                      child: TextButton(
                        onPressed: () => unawaited(_session.submit(pending)),
                        child: const Text('Try again'),
                      ),
                    ),
                  if (state.draft!.canCancel)
                    StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Cancel profile change',
                        onPressed: () => _session.cancel(pending),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                ],
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: StudioButtonPress(
                child: IconButton.filled(
                  tooltip: 'Create profile',
                  onPressed: state.canCreate
                      ? () => unawaited(_edit(_session.beginCreate()))
                      : null,
                  icon: const Icon(Icons.add),
                ),
              ),
            ),
            const SizedBox(height: 16),
            AdminGroup(
              children: [
                for (final row in state.rows)
                  StudioButtonPress(
                    child: ListTile(
                      title: Text(row.title),
                      subtitle: Text(row.subtitle),
                      onTap: state.canOpen
                          ? () => unawaited(_open(row.name))
                          : null,
                      trailing: StudioButtonPress(
                        child: PopupMenuButton<String>(
                          enabled:
                              row.canClone || row.canRename || row.canDelete,
                          tooltip: 'Manage ${row.title}',
                          itemBuilder: (_) => [
                            if (row.canClone)
                              const StudioPopupMenuItem(
                                value: 'clone',
                                child: Text('Clone configuration'),
                              ),
                            if (row.canRename)
                              const StudioPopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                            if (row.canDelete)
                              const StudioPopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                          ],
                          onSelected: (action) => unawaited(
                            _edit(switch (action) {
                              'clone' => _session.beginClone(row.name),
                              'rename' => _session.beginRename(row.name),
                              'delete' => _session.beginDelete(row.name),
                              _ => null,
                            }),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            StudioButtonPress(
              child: TextButton(
                onPressed: state.canRefresh
                    ? () => unawaited(_session.reload())
                    : null,
                child: const Text('Refresh'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileNameDialog extends StatefulWidget {
  const _ProfileNameDialog({required this.session, required this.intent});
  final ProfilesManagementSession session;
  final ProfilesManagementIntent intent;
  @override
  State<_ProfileNameDialog> createState() => _ProfileNameDialogState();
}

class _ProfileNameDialogState extends State<_ProfileNameDialog> {
  late final _openingTitle = widget.session.state.draft!.title;
  late final _name = TextEditingController(
    text: widget.session.state.draft!.initialName,
  );
  bool _pending = false;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_pending) return;
    final draft = widget.session.state.draft;
    if (draft == null || !draft.canSubmit) return;
    if (draft.needsConfirmation) {
      final confirmed = await adminConfirm(
        context,
        draft.confirmationTitle,
        draft.confirmationDetail,
        action: draft.confirmationAction,
        actionIcon: Icons.check,
        destructive: false,
      );
      if (!mounted || !confirmed) return;
    }
    setState(() => _pending = true);
    final outcome = await widget.session.submit(widget.intent);
    if (!mounted) return;
    setState(() => _pending = false);
    if (outcome?.announcesSuccess == true) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.session,
    builder: (context, _) {
      final state = widget.session.state;
      final draft = state.draft;
      final busy = _pending || state.busy;
      return PopScope(
        canPop: !busy,
        child: StudioDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Text(_openingTitle),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                viewportSelection(
                  TextFormField(
                    controller: _name,
                    enabled: !busy && draft?.canCancel == true,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      helperMaxLines: 4,
                      helperText: draft?.help,
                      errorText: draft?.validationError,
                    ),
                    onChanged: (value) =>
                        widget.session.updateName(widget.intent, value),
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
              confirmKey: const ValueKey('profile-name-save'),
              onCancel: busy ? null : () => Navigator.pop(context, false),
              cancelLabel: draft?.canCancel == false
                  ? 'Close editor'
                  : 'Cancel',
              onConfirm: !busy && draft?.canSubmit == true ? _save : null,
              confirmLabel: draft?.needsConfirmation == true
                  ? 'Save profile name'
                  : draft?.title ?? 'Save profile',
              busy: busy,
              progressLabel: 'Saving profile',
            ),
          ],
        ),
      );
    },
  );
}
