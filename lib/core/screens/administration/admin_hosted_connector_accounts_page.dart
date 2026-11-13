import '../../widgets/studio_error.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/hosted_connector_accounts.dart';
import '../../theme/wing_theme.dart';
import '../../services/administration_repository.dart';
import '../../services/hosted_connector_accounts_session.dart';
import '../../widgets/studio_form_actions.dart';
import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_loading.dart';
import 'admin_widgets.dart';
import 'admin_providers_page.dart';

class AdminHostedConnectorAccountsPage extends StatefulWidget {
  const AdminHostedConnectorAccountsPage({
    super.key,
    required this.profile,
    this.suggested = const [],
  });
  final ProfileAdministration profile;
  final List<String> suggested;
  @override
  State<AdminHostedConnectorAccountsPage> createState() =>
      _HostedAccountsState();
}

class _HostedAccountsState extends State<AdminHostedConnectorAccountsPage>
    with WidgetsBindingObserver {
  late final _session = HostedConnectorAccountsSession(widget.profile);
  String _query = '';
  bool _openingAuthorization = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session.setActive(
      (ModalRoute.isCurrentOf(context) ?? true) &&
          (WidgetsBinding.instance.lifecycleState == null ||
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _session.setActive(
        state == AppLifecycleState.resumed &&
            (ModalRoute.isCurrentOf(context) ?? true),
      );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.dispose();
    super.dispose();
  }

  Future<void> _nameAccount(
    HostedConnector connector, {
    HostedConnectorAccount? account,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _HostedAccountNameForm(
      session: _session,
      connector: connector,
      account: account,
    ),
  );

  Future<void> _remove(HostedConnectorAccount account) async {
    if (!await adminConfirm(
      context,
      'Remove ${account.title}?',
      'Hermes will lose access through this account. You can connect it again.',
      action: 'Remove account',
      actionIcon: Icons.delete_outline,
      destructive: true,
    )) {
      return;
    }
    await _session.remove(account);
  }

  Future<void> _openAuthorization(BuildContext anchor, Uri url) async {
    if (_openingAuthorization) return;
    final key = ('open-hosted-authorization', url);
    dismissTransientError(anchor, errorKey: key);
    setState(() => _openingAuthorization = true);
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw StateError('Could not open authorization');
      }
    } catch (_) {
      if (anchor.mounted) {
        showTransientError(
          anchor,
          'Could not open the sign-in page. Try again.',
          errorKey: key,
          icon: Icons.open_in_new,
        );
      }
    } finally {
      if (mounted) setState(() => _openingAuthorization = false);
    }
  }

  Widget _action(String label, IconData icon, VoidCallback? action) =>
      StudioButtonPress(
        child: IconButton(tooltip: label, onPressed: action, icon: Icon(icon)),
      );

  Iterable<HostedConnector> get _visibleConnectors {
    final matches = _session.catalog.where((row) => row.matches(_query));
    if (widget.suggested.isEmpty) return matches;
    final bySlug = {for (final row in matches) row.slug: row};
    return [
      for (final slug in widget.suggested) ?bySlug.remove(slug),
      ...bySlug.values,
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) => AdminPage(
      title: 'Connected apps',
      scope: _session.scopeLabel,
      actions: [
        _action(
          'Profile sign-in',
          Icons.account_circle_outlined,
          () => adminPushProfile(
            context,
            widget.profile,
            (_, profile) => AdminProvidersPage(profile: profile),
          ),
        ),
        _action(
          'Refresh connected apps',
          Icons.refresh,
          _session.loading || _session.busy ? null : _session.refresh,
        ),
      ],
      child: StudioPageLoading(
        active: _session.loading || _session.busy || _openingAuthorization,
        label: 'Updating connected apps',
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Hosted app accounts for this profile. Connect work and personal accounts with separate names.',
            ),
            const SizedBox(height: 12),
            viewportSelection(
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Find an app',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            if (_session.error != null)
              AdminNotice.error(
                _session.error!,
                retry: _session.loading || _session.busy
                    ? null
                    : _session.refresh,
              ),
            if (_session.operation case final operation?) ...[
              const SizedBox(height: 16),
              for (final target in operation.targets)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    target.alias == null
                        ? target.name
                        : '${target.name} · ${target.alias}',
                  ),
                  subtitle: Text(
                    target.detail ?? target.state.replaceAll('_', ' '),
                  ),
                  trailing: target.needsAuthorization && !operation.settled
                      ? Builder(
                          builder: (anchor) => _action(
                            'Authorize ${target.name}',
                            Icons.open_in_new,
                            _openingAuthorization
                                ? null
                                : () => _openAuthorization(
                                    anchor,
                                    target.connectUrl!,
                                  ),
                          ),
                        )
                      : null,
                ),
              if (!operation.settled)
                Align(
                  alignment: Alignment.centerRight,
                  child: _action(
                    'Check authorization',
                    Icons.refresh,
                    _session.loading || _session.busy
                        ? null
                        : _session.checkAuthorization,
                  ),
                ),
            ],
            for (final connector in _visibleConnectors) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      connector.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  _action(
                    'Connect ${connector.name} account',
                    Icons.add_link,
                    _session.canMutate ? () => _nameAccount(connector) : null,
                  ),
                ],
              ),
              Text(
                connector.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              for (final account in _session.accounts.where(
                (row) => row.connector == connector.slug,
              ))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(account.title),
                      Text(
                        account.statusLabel,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (account.statusReason?.isNotEmpty == true)
                        Text(account.statusReason!),
                      Wrap(
                        alignment: WrapAlignment.end,
                        children: [
                          _action(
                            'Rename ${account.title}',
                            Icons.edit_outlined,
                            _session.canMutate
                                ? () =>
                                      _nameAccount(connector, account: account)
                                : null,
                          ),
                          if (!account.disabled)
                            _action(
                              'Reconnect ${account.title}',
                              Icons.link,
                              _session.canMutate
                                  ? () => _session.connect(
                                      connector,
                                      reconnect: account,
                                    )
                                  : null,
                            ),
                          _action(
                            'Remove ${account.title}',
                            Icons.delete_outline,
                            _session.canMutate ? () => _remove(account) : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
            if (!_session.loading &&
                _session.hasObservation &&
                _session.catalog.isEmpty)
              const AdminNotice(
                'No hosted apps are available for this profile.',
              ),
            if (_session.catalog.isNotEmpty &&
                !_session.catalog.any((row) => row.matches(_query)))
              const AdminNotice('No apps match this search.'),
          ],
        ),
      ),
    ),
  );
}

/// The form owns its text controller through the sheet's closing animation.
class _HostedAccountNameForm extends StatefulWidget {
  const _HostedAccountNameForm({
    required this.session,
    required this.connector,
    required this.account,
  });
  final HostedConnectorAccountsSession session;
  final HostedConnector connector;
  final HostedConnectorAccount? account;
  @override
  State<_HostedAccountNameForm> createState() => _HostedAccountNameFormState();
}

class _HostedAccountNameFormState extends State<_HostedAccountNameForm> {
  late final _input = TextEditingController(text: widget.account?.alias ?? '');
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StudioLoadingFrame(
    child: ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) => PopScope(
        canPop: !widget.session.busy,
        child: StudioPageLoading(
          active: widget.session.loading,
          label: 'Refreshing connected apps',
          child: StatefulBuilder(
            builder: (context, update) => StudioFormSheet(
              actions: StudioFormActions(
                onCancel: widget.session.busy
                    ? null
                    : () => Navigator.pop(context),
                onConfirm:
                    !widget.session.canMutate ||
                        !validHostedAccountAlias(_input.text)
                    ? null
                    : () async {
                        final current = widget.account == null
                            ? null
                            : widget.session.accounts
                                  .where((row) => row.id == widget.account!.id)
                                  .firstOrNull;
                        final currentConnector = widget.session.catalog
                            .where((row) => row.slug == widget.connector.slug)
                            .firstOrNull;
                        final success = widget.account == null
                            ? currentConnector == null
                                  ? false
                                  : await widget.session.connect(
                                      currentConnector,
                                      alias: _input.text,
                                    )
                            : current == null
                            ? false
                            : await widget.session.rename(current, _input.text);
                        if (success && context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                confirmLabel: widget.account == null
                    ? 'Connect account'
                    : 'Save account name',
                busy: widget.session.busy,
                progressLabel: widget.account == null
                    ? 'Connecting account'
                    : 'Saving account name',
              ),
              children: [
                StudioFormHeader(
                  title: Text(
                    widget.account == null
                        ? 'Connect ${widget.connector.name}'
                        : 'Name ${widget.connector.name} account',
                  ),
                ),
                const SizedBox(height: 12),
                viewportSelection(
                  TextField(
                    controller: _input,
                    autofocus: true,
                    enabled: !widget.session.busy,
                    decoration: const InputDecoration(
                      labelText: 'Account name',
                      helperText:
                          'Lowercase letters, numbers and hyphens; up to 32 characters.',
                      helperMaxLines: 3,
                    ),
                    onChanged: (_) => update(() {}),
                  ),
                ),
                if (widget.session.error != null)
                  AdminNotice.error(
                    widget.session.error!,
                    retry: widget.session.busy ? null : widget.session.refresh,
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
