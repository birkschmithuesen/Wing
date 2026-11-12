import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/provider_recovery.dart';
import '../../models/provider_inventory.dart';
import '../../services/provider_recovery.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/compact_switch.dart';
import '../../widgets/studio_action_label.dart';
import 'admin_widgets.dart';

class AdminProviderDetail extends StatefulWidget {
  const AdminProviderDetail({
    super.key,
    required this.createSession,
    required this.onDeviceSignIn,
    required this.onKeys,
  });
  final ProviderRecovery Function() createSession;
  final Future<void> Function(BuildContext, ProviderSignInTarget)
  onDeviceSignIn;
  final Future<void> Function(BuildContext) onKeys;
  @override
  State<AdminProviderDetail> createState() => _AdminProviderDetailState();
}

class _AdminProviderDetailState extends State<AdminProviderDetail> {
  late final _recovery = widget.createSession();
  ProviderRecoveryObservation? get _observation => _recovery.state.observation;
  bool get _isBusy => _recovery.state.busy;
  bool get _isRenewing => _recovery.state.renewing;
  String? get _noticeError => _recovery.state.error;
  String? get _notice => _recovery.state.message;
  @override
  void initState() {
    super.initState();
    _recovery.addListener(_changed);
    _check();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _recovery.removeListener(_changed);
    _recovery.dispose();
    super.dispose();
  }

  Future<void> _check() => _recovery.refresh();
  Future<void> _renew() => _recovery.renewAccess(
    choose: (entries) => showDialog<ProviderCredential>(
      context: context,
      builder: (context) => StudioDialog(
        title: const Text('Choose a saved sign-in'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in entries)
              StudioButtonPress(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  minTileHeight: 48,
                  onTap: () => Navigator.pop(context, entry),
                  title: Text('${entry.label}\n${entry.source} · ${entry.id}'),
                ),
              ),
          ],
        ),
      ),
    ),
    confirmShared: (description) => adminConfirm(
      context,
      'Renew shared sign-in?',
      description,
      action: 'Renew access',

      actionIcon: Icons.refresh,
      destructive: false,
    ),
  );
  Future<void> _remove() => _recovery.removeAccess(
    confirm: (description) => adminConfirm(
      context,
      'Remove saved sign-in?',
      description,
      action: 'Remove sign-in',

      actionIcon: Icons.delete_outline,
      destructive: true,
    ),
  );
  Future<void> _signIn() => _recovery.openSignIn(
    deviceSignIn: (target) => widget.onDeviceSignIn(context, target),
    externalSignIn: (instructions) => adminPush(
      context,
      (context) => AdminProviderInstructions(instructions: instructions),
    ),
  );
  Future<void> _fileRemoval() => _recovery.visit(
    () => adminPush(
      context,
      (context) =>
          AdminProviderFileRemoval(createSession: _recovery.createFileReview),
    ),
  );
  Future<void> _keys() => _recovery.visit(() => widget.onKeys(context));
  @override
  Widget build(BuildContext context) {
    final access = _observation;
    final tokens = WingTokens.of(context);
    final canRenew = access?.canRenew == true;
    final key = access?.managesKeys == true;
    final expired = access?.expired == true;
    return PopScope(
      canPop: !_isBusy,
      child: AdminPage(
        title: access?.name ?? 'Provider account',
        scope: _recovery.scopeLabel,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_noticeError != null) AdminNotice.error(_noticeError!),
            if (_notice != null)
              Semantics(liveRegion: true, child: AdminNotice(_notice!)),
            if (access == null && _isBusy)
              StudioPageLoading.waiting(label: 'Loading provider'),
            if (access != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    expired
                        ? Icons.schedule
                        : access.hasCredential
                        ? Icons.key
                        : Icons.info_outline,
                    size: 20,
                    color: expired ? tokens.warning : tokens.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      access.statusLabel,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: expired ? tokens.warning : null,
                      ),
                    ),
                  ),
                ],
              ),
              if (access.expiresAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _providerExpiryLabel(context, access),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              Text(access.detail, style: TextStyle(color: tokens.muted)),
              const SizedBox(height: 24),
              if (canRenew) ...[
                StudioButtonPress(
                  child: FilledButton(
                    onPressed: _isBusy ? null : _renew,
                    child: StudioActionLabel('Renew access', busy: _isRenewing),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (key)
                StudioButtonPress(
                  child: FilledButton(
                    onPressed: _isBusy ? null : _keys,
                    child: const Text('Manage API keys'),
                  ),
                )
              else if (!canRenew)
                StudioButtonPress(
                  child: FilledButton(
                    onPressed: _isBusy ? null : _signIn,
                    child: Text(access.signInLabel),
                  ),
                )
              else
                StudioButtonPress(
                  child: OutlinedButton(
                    onPressed: _isBusy ? null : _signIn,
                    child: Text(access.signInLabel),
                  ),
                ),
              const SizedBox(height: 8),
              StudioButtonPress(
                child: TextButton(
                  onPressed: _isBusy ? null : _check,
                  child: const Text('Check status'),
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              if (access.canRemove)
                StudioButtonPress(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Remove saved sign-in',
                      style: TextStyle(color: tokens.danger),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _isBusy ? null : _remove,
                  ),
                )
              else if (access.canReviewFile)
                StudioButtonPress(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Delete saved credentials'),
                    subtitle: const Text('Shared file on the server'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _isBusy ? null : _fileRemoval,
                  ),
                )
              else if (access.hasRemovalInstructions)
                StudioButtonPress(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Removal options'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _isBusy
                        ? null
                        : () => adminPush(
                            context,
                            (context) => AdminProviderInstructions(
                              instructions: _recovery.instructions(
                                removal: true,
                              ),
                            ),
                          ),
                  ),
                ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Credential details'),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Source: ${access.sourceLabel}'),
                  if (access.external)
                    const Text(
                      'External credentials may be used by other profiles or tools.',
                    ),
                  if (access.canRefresh)
                    const Text(
                      'A refresh token is stored. Renewal may still require signing in again.',
                    ),
                  Text(
                    'Checked ${TimeOfDay.fromDateTime(access.checkedAt).format(context)}',
                  ),
                  if (access.reportedName != access.name)
                    Text('${access.reportedName}'),
                  const SizedBox(height: 12),
                ],
              ),
            ] else if (!_isBusy)
              StudioButtonPress(
                child: TextButton(
                  onPressed: _check,
                  child: const Text('Check status'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AdminProviderInstructions extends StatelessWidget {
  const AdminProviderInstructions({super.key, required this.instructions});
  final ProviderRecoveryInstructions instructions;
  @override
  Widget build(BuildContext context) {
    final claude = instructions.claude;
    final removal = instructions.removal;
    final command = instructions.command;
    return AdminPage(
      title: removal ? 'Removal options' : 'Sign-in options',
      scope: instructions.scope,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            instructions.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Text(instructions.description),
          if (removal)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Removing an external sign-in can affect other profiles and tools using it.',
              ),
            ),
          if (command != null) ...[
            const SizedBox(height: 24),
            const Text('Instructions supplied by Hermes'),
            const SizedBox(height: 8),
            viewportSelection(
              SelectableText(
                command,
                style: WingTokens.of(context).typography.mono,
              ),
            ),
            if (claude && !removal)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'setup-token prints a token; it does not update the credential file shown in Wing. Use /login to replace the stored Claude Code sign-in.',
                ),
              ),
            StudioButtonPress(
              child: IconButton(
                tooltip: 'Copy command',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: command)),
                icon: const Icon(Icons.copy, size: 18),
              ),
            ),
          ],
          if (instructions.hint != null) Text(instructions.hint!),
          const SizedBox(height: 24),
          StudioButtonPress(
            child: FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Return to check status'),
            ),
          ),
        ],
      ),
    );
  }
}

class AdminProviderFileRemoval extends StatefulWidget {
  const AdminProviderFileRemoval({super.key, required this.createSession});
  final ProviderRecovery Function() createSession;
  @override
  State<AdminProviderFileRemoval> createState() =>
      _AdminProviderFileRemovalState();
}

class _AdminProviderFileRemovalState extends State<AdminProviderFileRemoval> {
  late final _recovery = widget.createSession();
  late final _path = TextEditingController(text: _recovery.state.filePath);
  ProviderRecoveryState get _state => _recovery.state;
  ProviderCredentialFile? get _reviewedFile => _state.file;
  bool get _locationConfirmed => _state.fileConfirmed;
  bool get _isBusy => _state.busy;
  bool get _isDeleted => _state.deleted;
  String? get _noticeError => _state.error;
  String? get _outcomeNotice => _state.message;
  @override
  void initState() {
    super.initState();
    _recovery.addListener(_changed);
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _recovery.removeListener(_changed);
    _recovery.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _inspect() => _recovery.checkFile();
  Future<void> _delete() => _recovery.deleteReviewedFile(
    confirm: (description) => adminConfirm(
      context,
      'Delete saved Claude Code credentials?',
      description,
      action: 'Delete credentials',

      actionIcon: Icons.delete_outline,
      destructive: true,
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_isBusy,
    child: AdminPage(
      title: 'Delete saved credentials',
      scope: '${_recovery.connectionLabel} / Shared credential file',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_noticeError != null) AdminNotice.error(_noticeError!),
          if (_outcomeNotice != null) AdminNotice(_outcomeNotice!),
          if (!_isDeleted) ...[
            const Text(
              'Confirm where Claude Code stores this sign-in. Hermes reports a default path even when a custom location or system keychain is used.',
            ),
            const SizedBox(height: 16),
            viewportSelection(
              TextField(
                controller: _path,
                enabled: !_isBusy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Credential file on server',
                ),
                onChanged: _recovery.changeFilePath,
              ),
            ),
            const SizedBox(height: 12),
            CompactSwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _locationConfirmed,
              onChanged: _isBusy ? null : _recovery.confirmFileLocation,
              title: const Text(
                'This is the file used by this Claude Code sign-in',
              ),
            ),
            const Text(
              'If the sign-in uses a system keychain, remove it using Claude Code on the server instead.',
            ),
            const SizedBox(height: 16),
            StudioButtonPress(
              child: OutlinedButton(
                onPressed: !_state.canInspectFile ? null : _inspect,
                child: StudioActionLabel(
                  'Check file',
                  busy: _state.inspectingFile,
                ),
              ),
            ),
            if (_reviewedFile != null) ...[
              const SizedBox(height: 16),
              viewportSelection(
                SelectableText(
                  _reviewedFile!.path,
                  style: WingTokens.of(context).typography.mono,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'File found. Deletion affects every profile and tool using this file.',
              ),
              const SizedBox(height: 16),
              StudioButtonPress(
                child: FilledButton(
                  onPressed: !_state.canDeleteFile ? null : _delete,
                  child: const Text('Delete credentials'),
                ),
              ),
            ],
          ],
          StudioButtonPress(
            child: TextButton(
              onPressed: _isBusy ? null : () => Navigator.pop(context),
              child: Text(_isDeleted ? 'Done' : 'Cancel'),
            ),
          ),
        ],
      ),
    ),
  );
}

String _providerExpiryLabel(
  BuildContext context,
  ProviderRecoveryObservation access,
) {
  final expiry = access.expiresAt?.toLocal();
  if (expiry == null) {
    return 'Expiry not reported';
  }
  final date = MaterialLocalizations.of(context).formatMediumDate(expiry);
  final time = TimeOfDay.fromDateTime(expiry).format(context);
  return '${access.expiryPrefix} $date · $time';
}
