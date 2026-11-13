import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/provider_inventory.dart';
import '../../models/provider_device_sign_in.dart';
import '../../services/administration_repository.dart';
import '../../services/provider_inventory_session.dart';
import '../../services/provider_credential_edit_session.dart';
import '../../services/provider_device_sign_in_session.dart';
import '../../widgets/read_recovery.dart';
import '../../widgets/studio_action_label.dart';
import '../../widgets/studio_error.dart';
import 'admin_widgets.dart';

class AdminServiceKeyCatalog extends StatefulWidget {
  const AdminServiceKeyCatalog({super.key, required this.profile});
  final ProfileAdministration profile;
  @override
  State<AdminServiceKeyCatalog> createState() => _AdminServiceKeyCatalogState();
}

class _AdminServiceKeyCatalogState extends State<AdminServiceKeyCatalog> {
  late final session = ProviderInventorySession(
    widget.profile,
    scope: ProviderInventoryScope.catalog,
  );
  @override
  void initState() {
    super.initState();
    session.refresh();
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  Future<void> _open(ProviderEnvironmentField field) async {
    await adminPushProfile(
      context,
      session.profile,
      (context, profile) => AdminSecretPage(profile: profile, name: field.key),
    );
    await session.refresh();
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Add service key',
    scope: session.profile.label,
    child: ProviderInventoryBody(
      session: session,
      builder: (data) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          viewportSelection(
            TextField(
              decoration: const InputDecoration(
                labelText: 'Find a service',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: session.search,
            ),
          ),
          const SizedBox(height: 16),
          if (session.keys.isEmpty)
            const AdminNotice('No services match this search.'),
          AdminGroup(
            children: [
              for (final field in session.keys)
                StudioButtonPress(
                  child: ListTile(
                    title: Text(field.label),
                    subtitle: Text(
                      '${field.key}${field.isSet ? ' · Key stored' : ''}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(field),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Presents passive load/error facts; read ordering and retention belong to the owner.
class ProviderInventoryBody extends StatelessWidget {
  const ProviderInventoryBody({
    super.key,
    required this.session,
    required this.builder,
  });
  final ProviderInventorySession session;
  final Widget Function(ProviderInventory) builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => ReadRecovery(
      shouldRetry: () => session.canRecover,
      retry: session.refresh,
      child: StudioLoadingRegion(
        available: session.observation != null,
        busy: session.loading,
        label: 'Loading credentials',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (session.error != null)
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: AdminNotice.error(
                      '${session.observation == null ? '' : 'Last checked ${TimeOfDay.fromDateTime(session.observation!.checkedAt).format(context)}. '}${session.error}',
                      retry: session.loading ? null : session.refresh,
                    ),
                  ),
                ),
              ),
            if (session.observation case final data?)
              Expanded(key: const ValueKey('content'), child: builder(data)),
          ],
        ),
      ),
    ),
  );
}

/// Prepares the selected owner's metadata before admitting a credential draft.
/// Callers supply identity, never a baseline captured from another inventory.
class AdminSecretPage extends StatefulWidget {
  const AdminSecretPage({super.key, required this.profile, required this.name});
  final ProfileAdministration profile;
  final String name;
  @override
  State<AdminSecretPage> createState() => _AdminSecretPageState();
}

class _AdminSecretPageState extends State<AdminSecretPage> {
  late ProviderInventorySession _inventory;

  void _prepare() {
    _inventory = ProviderInventorySession(
      widget.profile,
      scope: ProviderInventoryScope.catalog,
    )..refresh();
  }

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(AdminSecretPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.profile.server, widget.profile.server) ||
        oldWidget.profile.name != widget.profile.name ||
        oldWidget.name != widget.name) {
      _inventory.dispose();
      _prepare();
    }
  }

  @override
  void dispose() {
    _inventory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _inventory,
    builder: (context, _) {
      final field = _inventory.observation?.keys
          .where((field) => field.key == widget.name)
          .firstOrNull;
      if (!_inventory.loading &&
          _inventory.error == null &&
          field != null &&
          field.editable) {
        return _CredentialEditor(
          key: ValueKey((
            widget.profile.server,
            widget.profile.name,
            widget.name,
          )),
          profile: widget.profile,
          name: field.key,
          isSet: field.isSet,
        );
      }
      return AdminPage(
        title: widget.name,
        scope: widget.profile.label,
        child: ReadRecovery(
          key: ObjectKey(_inventory),
          shouldRetry: () => _inventory.canRecover,
          retry: _inventory.refresh,
          child: StudioPageLoading(
            active: _inventory.loading,
            label: 'Loading credential',
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!_inventory.loading)
                  AdminNotice.error(
                    _inventory.error ?? 'This credential is unavailable.',
                    retry: _inventory.refresh,
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _CredentialEditor extends StatefulWidget {
  const _CredentialEditor({
    super.key,
    required this.profile,
    required this.name,
    required this.isSet,
  });
  final ProfileAdministration profile;
  final String name;
  final bool isSet;
  @override
  State<_CredentialEditor> createState() => _CredentialEditorState();
}

class _CredentialEditorState extends State<_CredentialEditor> {
  final _input = TextEditingController();
  late final session = ProviderCredentialEditSession(
    widget.profile,
    key: widget.name,
    isSet: widget.isSet,
  );
  bool _leave = false;
  @override
  void dispose() {
    _input.dispose();
    session.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (session.busy) {
      return;
    }
    if (session.dirty &&
        !await adminConfirm(
          context,
          'Discard key?',
          'The new credential has not been confirmed as saved.',
          action: 'Discard',

          actionIcon: Icons.delete_outline,
          destructive: true,
        )) {
      return;
    }
    if (mounted) {
      setState(() => _leave = true);
      Navigator.pop(context);
    }
  }

  Future<void> _save({required bool remove}) async {
    if (remove &&
        !await adminConfirm(
          context,
          'Remove saved key?',
          'This removes the saved key from ${session.profile.name}. Other credential sources may still be available. The key is not revoked at its provider.',
          action: 'Remove',

          actionIcon: Icons.delete_outline,
          destructive: true,
        )) {
      return;
    }
    final outcome = await session.save(remove: remove);
    if (!mounted) {
      return;
    }
    if (outcome == ProviderCredentialOutcome.saved ||
        outcome == ProviderCredentialOutcome.removed) {
      _input.clear();
      setState(() => _leave = true);
      adminMessage(
        context,
        outcome == ProviderCredentialOutcome.removed
            ? 'Credential removed from this owner.'
            : 'Credential saved. Refresh provider readiness to check access.',
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => PopScope(
      canPop: _leave || (!session.busy && !session.dirty),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _close();
        }
      },
      child: AdminPage(
        title: session.key,
        scope: session.profile.label,
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: StudioFormActions(
              onCancel: session.busy ? null : _close,
              onConfirm: session.canSave ? () => _save(remove: false) : null,
              confirmLabel: 'Save credential',
              busy: session.busy,
              progressLabel: 'Saving credential',
            ),
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const AdminNotice(
              'Enter a new credential. Existing secret values are never loaded into this form.',
            ),
            if (session.error case final error?) AdminNotice.error(error),
            if (session.reviewRequired)
              StudioButtonPress(
                child: TextButton(
                  onPressed: session.busy ? null : session.review,
                  child: const Text('Refresh and review'),
                ),
              ),
            viewportSelection(
              TextField(
                controller: _input,
                obscureText: true,
                enabled: !session.busy,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'New credential'),
                onChanged: session.setDraft,
              ),
            ),
            const SizedBox(height: 16),
            if (session.isSet)
              StudioButtonPress(
                child: TextButton(
                  onPressed: session.canRemove
                      ? () => _save(remove: true)
                      : null,
                  child: const Text('Remove stored credential'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class AdminProviderSignIn extends StatefulWidget {
  const AdminProviderSignIn({
    super.key,
    required this.profile,
    required this.target,
  });
  final ProfileAdministration profile;
  final ProviderSignInTarget target;
  @override
  State<AdminProviderSignIn> createState() => _AdminProviderSignInState();
}

class _AdminProviderSignInState extends State<AdminProviderSignIn> {
  late final session = ProviderDeviceSignInSession(
    widget.profile,
    widget.target,
  );
  bool _leave = false;
  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (await session.cancel() && mounted) {
      setState(() => _leave = true);
      Navigator.pop(context);
    }
  }

  Future<void> _openBrowser() async {
    final url = session.session?.verificationUrl;
    if (url == null) {
      return;
    }
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        session.browserUnavailable();
      }
    } catch (_) {
      session.browserUnavailable();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => ReadRecovery(
      shouldRetry: () => session.canRecover,
      retry: session.poll,
      child: PopScope(
        canPop: _leave || (!session.pending && !session.busy),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _close();
          }
        },
        child: AdminPage(
          title: 'Sign in to ${session.target.name}',
          scope: session.profile.label,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              AdminNotice(
                'Save this sign-in for ${session.profile.name} on ${session.profile.server.connectionLabel}.',
              ),
              if (session.error case final error?) AdminNotice.error(error),
              if (session.showStart)
                StudioButtonPress(
                  child: FilledButton(
                    onPressed: session.canStart ? session.start : null,
                    child: StudioActionLabel(
                      session.session == null ? 'Start sign-in' : 'Start again',
                      busy: session.busy,
                    ),
                  ),
                ),
              if (session.session case final attempt?) ...[
                if (session.statusIsError)
                  StudioError('Status: ${session.statusLabel}')
                else
                  Text(
                    session.status == ProviderDeviceStatus.approved
                        ? 'Sign-in saved. Return to check credential status.'
                        : 'Status: ${session.statusLabel}',
                  ),
                if (session.pending) ...[
                  const SizedBox(height: 16),
                  viewportSelection(
                    SelectableText(
                      attempt.userCode,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Copy code',
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: attempt.userCode),
                      ),
                      icon: const Icon(Icons.copy, size: 18),
                    ),
                  ),
                  if (session.error != null)
                    viewportSelection(
                      SelectableText(attempt.verificationUrl.toString()),
                    ),
                  StudioButtonPress(
                    child: FilledButton(
                      onPressed: _openBrowser,
                      child: const Text('Open sign-in page'),
                    ),
                  ),
                  StudioButtonPress(
                    child: TextButton(
                      onPressed: session.busy ? null : session.poll,
                      child: const Text('Check status'),
                    ),
                  ),
                ],
              ],
              StudioButtonPress(
                child: IconButton(
                  tooltip: session.pending ? 'Cancel sign-in' : 'Close',
                  onPressed: session.canClose ? _close : null,
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
