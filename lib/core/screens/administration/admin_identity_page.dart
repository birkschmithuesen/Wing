import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/profile_identity_edit.dart';
import '../../services/profile_identity_edit_session.dart';
import '../../widgets/server_connection_label.dart';
import 'admin_widgets.dart';

Future<bool> showAdminIdentityEditor(
  BuildContext context, {
  required ProfileIdentityEditSession Function() createSession,
}) async {
  final status = ServerConnectionScope.of(context);
  return await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) {
            final page = AdminIdentityPage(createSession: createSession);
            return status == null
                ? page
                : ServerConnectionScope(status: status, child: page);
          },
        ),
      ) ??
      false;
}

/// Input, focus and navigation for one route-owned identity edit session.
class AdminIdentityPage extends StatefulWidget {
  const AdminIdentityPage({super.key, required this.createSession});
  final ProfileIdentityEditSession Function() createSession;

  @override
  State<AdminIdentityPage> createState() => _AdminIdentityPageState();
}

class _AdminIdentityPageState extends State<AdminIdentityPage> {
  final _noticeAnchor = GlobalKey();
  final _description = TextEditingController();
  final _soul = TextEditingController();
  late final ProfileIdentityEditSession _session;
  bool _syncingText = false, _allowPop = false;
  String? _visibleError;
  ProfileIdentityEditState get _state => _session.state;

  @override
  void initState() {
    super.initState();
    _session = widget.createSession();
    _syncText();
    _description.addListener(_descriptionEdited);
    _soul.addListener(_soulEdited);
    _session.addListener(_changed);
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _session.dispose();
    _description.dispose();
    _soul.dispose();
    super.dispose();
  }

  void _descriptionEdited() {
    if (!_syncingText) {
      _session.edit(ProfileIdentityField.description, _description.text);
    }
  }

  void _soulEdited() {
    if (!_syncingText) {
      _session.edit(ProfileIdentityField.soul, _soul.text);
    }
  }

  void _syncText() {
    _syncingText = true;
    try {
      if (_description.text != _state.description.text) {
        _description.text = _state.description.text;
      }
      if (_soul.text != _state.soul.text) _soul.text = _state.soul.text;
    } finally {
      _syncingText = false;
    }
  }

  void _changed() {
    if (!mounted) return;
    _syncText();
    setState(() {});
    if (_state.error != null && _state.error != _visibleError) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) revealAdminNotice(context, _noticeAnchor);
      });
    }
    _visibleError = _state.error;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final outcome = await _session.save();
    if (mounted && outcome == ProfileIdentitySaveOutcome.confirmed) {
      await _finish(_session.requestClose().result);
    }
  }

  Future<void> _close() async {
    var decision = _session.requestClose();
    if (decision.needsDiscardConfirmation) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => StudioDialog(
          title: const Text('Discard unsaved changes?'),
          content: const Text('Edits that were not saved will be lost.'),
          actions: [
            StudioFormActions(
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
              confirmLabel: 'Discard edits',
              confirmIcon: Icons.delete_outline,
              destructive: true,
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
      decision = _session.requestClose(discard: true);
    }
    if (decision.canClose) await _finish(decision.result);
  }

  Future<void> _finish(bool result) async {
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context, result);
  }

  Widget _comparison(
    ProfileIdentityField field,
    ProfileIdentityFieldState value,
  ) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Current server value: ${value.serverText}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Wrap(
          spacing: 8,
          children: [
            StudioButtonPress(
              child: OutlinedButton(
                onPressed: _state.saving
                    ? null
                    : () => _session.resolve(field, useServer: false),
                child: const Text('Keep my value'),
              ),
            ),
            StudioButtonPress(
              child: TextButton(
                onPressed: _state.saving
                    ? null
                    : () => _session.resolve(field, useServer: true),
                child: const Text('Use server value'),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_close());
    },
    child: AdminPage(
      title: 'Identity',
      scope: _state.scopeLabel,
      bottomNavigationBar: !_state.hasObservation
          ? null
          : AdminEditorActions(
              dirtyCount: _state.dirtyCount,
              saving: _state.saving,
              onClose: _close,
              onSave: _state.canSave ? _save : null,
            ),
      child: _state.loading && !_state.hasObservation
          ? StudioPageLoading.waiting(label: 'Loading profile identity')
          : !_state.hasObservation
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: AdminNotice.error(_state.error!, retry: _session.load),
            )
          : SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Give your agent a point of view',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'A short description helps you recognize this profile. Its SOUL gives the agent instructions about how to work.',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Stored for this profile on ${_state.connectionLabel}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  Column(
                    key: _noticeAnchor,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_state.notice != null) AdminNotice(_state.notice!),
                      if (_state.error != null)
                        AdminNotice.error(_state.error!, retry: _session.load),
                    ],
                  ),
                  viewportSelection(
                    TextField(
                      key: const ValueKey('profile-description-field'),
                      controller: _description,
                      enabled: _state.description.enabled,
                      minLines: 2,
                      maxLines: 6,
                      decoration: InputDecoration(
                        labelText: 'Description',
                        hintText: 'What this profile is for',
                        alignLabelWithHint: true,
                        errorText: _state.description.issue,
                        errorMaxLines: 4,
                      ),
                    ),
                  ),
                  if (_state.description.conflicted)
                    _comparison(
                      ProfileIdentityField.description,
                      _state.description,
                    ),
                  const SizedBox(height: 24),
                  viewportSelection(
                    TextField(
                      key: const ValueKey('profile-soul-field'),
                      controller: _soul,
                      enabled: _state.soul.enabled,
                      minLines: 12,
                      maxLines: null,
                      decoration: InputDecoration(
                        labelText: 'SOUL',
                        hintText: 'Instructions that shape this profile',
                        alignLabelWithHint: true,
                        errorText: _state.soul.issue,
                        errorMaxLines: 4,
                      ),
                    ),
                  ),
                  if (_state.soul.conflicted)
                    _comparison(ProfileIdentityField.soul, _state.soul),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    ),
  );
}
