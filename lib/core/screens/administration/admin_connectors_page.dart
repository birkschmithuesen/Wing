import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/profile_connectors.dart';
import '../../services/profile_connectors_session.dart';
import '../../services/mcp_oauth.dart';
import '../../services/mcp_setup.dart';
import '../../widgets/read_recovery.dart';
import '../../widgets/studio_action_label.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/compact_switch.dart';
import '../../theme/wing_theme.dart';
import 'admin_widgets.dart';

class AdminConnectorsPage extends StatefulWidget {
  const AdminConnectorsPage({
    super.key,
    required this.createSession,
    required this.pushDetail,
    required this.pushSetup,
    this.failedConnectorNames = const {},
  });
  final ProfileConnectorsSession Function() createSession;
  final Set<String> failedConnectorNames;
  final Future<void> Function(
    BuildContext,
    String,
    ConnectorDetailRoute Function(String),
  )
  pushDetail;
  final Future<(String, ProfileConnector)?> Function(
    BuildContext,
    McpSetupSession Function(String),
  )
  pushSetup;
  @override
  State<AdminConnectorsPage> createState() => _AdminConnectorsPageState();
}

class _AdminConnectorsPageState extends State<AdminConnectorsPage> {
  late final _session = widget.createSession();
  @override
  void initState() {
    super.initState();
    _session.refresh();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _open(
    String name, {
    required String profileName,
    required bool signInOnOpen,
  }) async {
    await widget.pushDetail(
      context,
      profileName,
      (selected) => _session.detailForProfile(
        name,
        profileName: selected,
        signInOnOpen: signInOnOpen && selected == profileName,
      ),
    );
    await _session.refresh();
  }

  Future<void> _add() async {
    final created = await widget.pushSetup(context, _session.setupForProfile);
    await _session.refresh();
    if (mounted && created != null) {
      await _open(
        created.$2.name,
        profileName: created.$1,
        signInOnOpen: created.$2.canSignIn,
      );
    }
  }

  Future<void> _toggle(ProfileConnector row, bool value) async {
    await _session.toggle(row, value);
    if (!mounted) return;
    final state = _session.state;
    if (state.error == null && state.notice != null) {
      adminMessage(context, state.notice!);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'MCP connectors',
    scope: _session.scopeLabel,
    child: ReadRecovery(
      shouldRetry: () => _session.canRecoverRead,
      retry: _session.refresh,
      child: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          final state = _session.state;
          return StudioPageLoading(
            active:
                state.phase == ConnectorPhase.reading ||
                state.phase == ConnectorPhase.reconnecting,
            label: state.phase == ConnectorPhase.reconnecting
                ? 'Reconnecting MCP tools'
                : 'Loading connectors',
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state.error case final error?)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            constraints.maxHeight * (state.checked ? .45 : 1),
                      ),
                      child: SingleChildScrollView(
                        primary: false,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: AdminNotice.error(
                          error,
                          retry:
                              state.busy ||
                                  state.failureScope !=
                                      ConnectorFailureScope.read
                              ? null
                              : _session.refresh,
                        ),
                      ),
                    ),
                  if (state.checked)
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          const AdminNotice(
                            'Manage the external tools available to this profile.',
                          ),
                          if (state.runtimeError case final error?)
                            AdminNotice.error(error),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              StudioButtonPress(
                                child: IconButton.filled(
                                  tooltip: 'Add connector',
                                  onPressed: state.canMutate ? _add : null,
                                  icon: const Icon(Icons.add),
                                ),
                              ),
                              StudioButtonPress(
                                child: IconButton(
                                  tooltip: 'Refresh connectors',
                                  onPressed: state.busy
                                      ? null
                                      : _session.refresh,
                                  icon: const Icon(Icons.refresh),
                                ),
                              ),
                            ],
                          ),
                          if (state.connectors.isEmpty)
                            const AdminNotice(
                              'No MCP connectors configured for this profile.',
                            ),
                          AdminGroup(
                            children: [
                              for (final row in state.connectors)
                                _connectorRow(row, state),
                            ],
                          ),
                          const SizedBox(height: 24),
                          const Divider(height: 1),
                          const SizedBox(height: 16),
                          Text(
                            'Apply connector changes or retry connections for all profiles on this server.',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 12),
                          AdminReloadConnectorsButton(session: _session),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _connectorRow(ProfileConnector row, ProfileConnectorsState state) {
    final failed = widget.failedConnectorNames.contains(row.name);
    final tile = StudioButtonPress(
      child: ListTile(
        minTileHeight: 56,
        minVerticalPadding: failed ? 12 : 4,
        horizontalTitleGap: 12,
        title: failed
            ? StudioError(
                row.name,
                detail: 'Failed health check · ${row.transport}',
                framed: false,
              )
            : Text(row.name),
        subtitle: failed
            ? null
            : Text(
                [
                  row.transport,
                  if (state.runtime?.forConnector(row) case final runtime?)
                    'Cached: ${runtime.label}',
                ].join(' · '),
              ),
        trailing: CompactSwitch(
          semanticLabel: 'Enable ${row.name}',
          value: row.enabled,
          onChanged: state.canMutate && row.canConfigure
              ? (value) => _toggle(row, value)
              : null,
        ),
        onTap: state.canMutate
            ? () => _open(
                row.name,
                profileName: _session.profileName,
                signInOnOpen: false,
              )
            : null,
      ),
    );
    return failed ? StudioErrorFrame(child: tile) : tile;
  }
}

class AdminConnectorDetail extends StatefulWidget {
  const AdminConnectorDetail({super.key, required this.createRoute});
  final ConnectorDetailRoute Function() createRoute;
  @override
  State<AdminConnectorDetail> createState() => _AdminConnectorDetailState();
}

class _AdminConnectorDetailState extends State<AdminConnectorDetail> {
  late final _session = _route.session;
  late final _route = widget.createRoute();
  bool _didAutoSignIn = false;
  String get _name => _route.name;
  bool get _loading => _session.state.phase == ConnectorPhase.reading;
  bool get _busy => _session.state.busy;
  bool get _testing => _session.state.phase == ConnectorPhase.testing;
  ProfileConnector? get _configuration => _session.connector(_route);
  ConnectorProbe? get _probe => _session.state.probe;
  String? get _error => _session.state.error;
  String? get _testFailure => _probe?.failure;
  @override
  void initState() {
    super.initState();
    final route = _route;
    final session = route.session;
    // The inventory may also be observed by the list beneath this route.
    // Begin its initial refresh after child mounting has finished.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(route, _route) ||
          !identical(session, _session)) {
        return;
      }
      _load();
    });
  }

  @override
  void dispose() {
    _route.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _session.refresh();
    if (mounted &&
        !_didAutoSignIn &&
        _route.signInOnOpen &&
        _session.canSignIn(_route)) {
      _didAutoSignIn = true;
      await _signIn(autoStart: true);
    }
  }

  Future<void> _signIn({bool autoStart = false}) async {
    await adminPush(
      context,
      (_) => AdminMcpSignIn(
        createFlow: () =>
            _session.createSignIn(_route, bindLoopback: McpLoopback.bind),
        autoStart: autoStart,
      ),
    );
    _session.returnedFromSignIn(_route);
  }

  Future<void> _test() => _session.test(
    _route,
    () => adminConfirm(
      context,
      'Test $_name?',
      'This connects to the configured service or starts its server process to inspect capabilities.',
      action: 'Test',

      actionIcon: Icons.network_check,
      destructive: false,
    ),
  );
  Future<void> _remove() async {
    final removed = await _session.remove(
      _route,
      () => adminConfirm(
        context,
        'Remove $_name?',
        'Remove this connector configuration from ${_session.profileName}. Existing sessions may retain their loaded tools.',
        action: 'Remove',

        actionIcon: Icons.delete_outline,
        destructive: true,
      ),
    );
    if (mounted && removed) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      if (_configuration == null) {
        return AdminPage(
          title: _name,
          scope: _session.scopeLabel,
          child: _loading
              ? StudioPageLoading.waiting(label: 'Loading connectors')
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_error case final error?)
                      AdminNotice.error(error)
                    else
                      const AdminNotice(
                        'This connector is not available in this profile.',
                      ),
                    StudioButtonPress(
                      child: TextButton(
                        onPressed: _load,
                        child: const Text('Refresh'),
                      ),
                    ),
                  ],
                ),
        );
      }

      final tokens = WingTokens.of(context);
      final tools = _probe?.tools ?? const <ConnectorTool>[];
      final connected = _probe?.connected == true;
      return AdminPage(
        title: _name,
        scope: _session.scopeLabel,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_configuration case final configuration?) ...[
              if (_session.state.runtime?.forConnector(configuration)
                  case final runtime?)
                AdminNotice(
                  'Cached runtime: ${runtime.label}${runtime.tools > 0 ? ' · ${runtime.tools} tools' : ''}. This is separate from Test connection.',
                ),
              if (_session.state.runtimeError case final error?)
                AdminNotice.error(error),
            ],
            if (_testFailure case final failure?)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: StudioErrorFrame(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: WingSpacing.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: WingSpacing.md),
                          child: StudioError(
                            'Connection failed',
                            framed: false,
                          ),
                        ),
                        ExpansionTile(
                          key: ValueKey(failure),
                          tilePadding: EdgeInsets.zero,
                          title: const Text('Failure details'),
                          expandedCrossAxisAlignment: CrossAxisAlignment.start,
                          childrenPadding: const EdgeInsets.only(
                            bottom: WingSpacing.md,
                          ),
                          children: [Text(failure)],
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      if (_testing)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            semanticsLabel: 'Testing connection',
                          ),
                        )
                      else
                        Icon(
                          connected ? Icons.check : Icons.horizontal_rule,
                          size: 20,
                          color: connected ? tokens.success : tokens.muted,
                        ),
                      if (!_testing) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(connected ? 'Connected' : 'Not tested'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                StudioButtonPress(
                  child: FilledButton(
                    onPressed: _session.state.canMutate ? _test : null,
                    child: const Text('Test connection'),
                  ),
                ),
                if (_configuration?.canSignIn == true)
                  StudioButtonPress(
                    child: OutlinedButton(
                      onPressed: _session.canSignIn(_route) ? _signIn : null,
                      child: const Text('Sign in'),
                    ),
                  ),
              ],
            ),
            if (_probe?.connected == true)
              ExpansionTile(
                key: ObjectKey(_probe),
                tilePadding: EdgeInsets.zero,
                title: Text('Available tools (${tools.length})'),
                children: [
                  if (tools.isEmpty)
                    const AdminNotice('This connection returned no tools.'),
                  for (final tool in tools)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tool.name),
                      subtitle: tool.description.isEmpty
                          ? null
                          : Text(tool.description),
                    ),
                ],
              ),
            if (_error != null)
              AdminNotice.error(_error!, retry: _busy ? null : _load),
            const SizedBox(height: 16),
            StudioButtonPress(
              child: TextButton(
                onPressed: _session.canConfigure(_route) ? _remove : null,
                child: const Text('Remove connector'),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class AdminMcpSignIn extends StatefulWidget {
  final McpOAuth Function() createFlow;
  final bool autoStart;
  final Future<bool> Function(Uri) openBrowser;
  const AdminMcpSignIn({
    super.key,
    required this.createFlow,
    this.autoStart = false,
    this.openBrowser = _launchMcpBrowser,
  });
  @override
  State<AdminMcpSignIn> createState() => _AdminMcpSignInState();
}

class _AdminMcpSignInState extends State<AdminMcpSignIn> {
  late final _flow = widget.createFlow();
  final _callback = TextEditingController();
  bool _leave = false;
  String? _browserError;

  @override
  void initState() {
    super.initState();
    _flow.addListener(_changed);
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }
  }

  Future<void> _start() async {
    setState(() => _browserError = null);
    await _flow.start();
    if (mounted && _flow.authUrl != null && _flow.pending) await _openBrowser();
  }

  void _changed() {
    if (!mounted) return;
    if (_flow.callbackAccepted || !_flow.pending) _callback.clear();
    setState(() {});
  }

  @override
  void dispose() {
    _flow.removeListener(_changed);
    _flow.dispose();
    _callback.dispose();
    super.dispose();
  }

  Future<void> _openBrowser() async {
    final url = _flow.authUrl;
    if (url == null) return;
    setState(() => _browserError = null);
    try {
      if (await widget.openBrowser(url)) return;
    } catch (_) {
      // Never include the authorization URL in diagnostics.
    }
    if (mounted) {
      setState(
        () => _browserError = 'Could not open the sign-in page. Try again.',
      );
    }
  }

  Future<void> _submit() async {
    final callback = _callback.text;
    _callback.clear();
    FocusScope.of(context).unfocus();
    await _flow.submitCallback(callback);
  }

  Future<void> _close() async {
    if (_flow.busy) return;
    if (!await _flow.cancel() || !mounted) return;
    setState(() => _leave = true);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ReadRecovery(
    shouldRetry: () => !_leave && _flow.canRecoverPoll,
    retry: _flow.poll,
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) => PopScope(
    canPop: _leave || (!_flow.pending && !_flow.busy),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: AdminPage(
      title: 'Sign in to ${_flow.name}',
      scope: _flow.scopeLabel,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_flow.pending && _flow.status != 'approved') ...[
            const AdminNotice(
              'Sign in through your browser. Your account access is saved on Hermes for this profile.',
            ),
            StudioButtonPress(
              child: FilledButton(
                onPressed: _flow.busy ? null : _start,
                child: StudioActionLabel('Start sign-in', busy: _flow.busy),
              ),
            ),
          ],
          if (_flow.error != null) AdminNotice.error(_flow.error!),
          if (_browserError != null) AdminNotice.error(_browserError!),
          if (_flow.status == 'approved')
            const AdminNotice(
              'Signed in. Test the connection, then reconnect MCP tools to use this sign-in in existing chats.',
            ),
          if (_flow.pending) ...[
            if (_flow.authUrl != null && !_flow.callbackAccepted) ...[
              StudioButtonPress(
                child: FilledButton(
                  onPressed: _flow.busy ? null : _openBrowser,
                  child: const Text('Open sign-in page'),
                ),
              ),
              AdminNotice(
                _flow.manualOnly
                    ? 'This connector uses its registered callback address. After approving access, copy the full address from your browser and paste it below, even if the page does not load.'
                    : 'Return to Wing after approval. If your browser stops at a localhost page, paste its full address below.',
              ),
              viewportSelection(
                TextField(
                  controller: _callback,
                  enabled: !_flow.busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(labelText: 'Callback URL'),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 12),
              StudioButtonPress(
                child: OutlinedButton(
                  onPressed: _flow.busy ? null : _submit,
                  child: StudioActionLabel(
                    'Complete sign-in',
                    busy: _flow.busy,
                  ),
                ),
              ),
            ],
            if (_flow.callbackAccepted)
              const AdminNotice(
                'Authorization received. Waiting for Hermes to finish sign-in.',
              ),
            StudioButtonPress(
              child: TextButton(
                onPressed: _flow.busy ? null : _flow.poll,
                child: const Text('Check status'),
              ),
            ),
          ],
          if (!_flow.pending && _flow.status != 'approved')
            ExpansionTile(
              initiallyExpanded: _flow.terminalRequired,
              key: ValueKey(_flow.terminalRequired),
              tilePadding: EdgeInsets.zero,
              title: const Text('Other sign-in methods'),
              children: [
                const AdminNotice(
                  'Device-code sign-in and providers requiring a client metadata document need a terminal on your Hermes server. Run the command for this profile, then return here to test the connector.',
                ),
                viewportSelection(SelectableText(_flow.terminalCommand)),
                const SizedBox(height: 12),
                const AdminNotice(
                  'For device-code sign-in, add --flow device. The provider must support it.',
                ),
              ],
            ),
          StudioButtonPress(
            child: IconButton(
              tooltip: _flow.pending ? 'Cancel sign-in' : 'Close',
              onPressed: _flow.busy ? null : _close,
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    ),
  );
}

class AdminReloadConnectorsButton extends StatelessWidget {
  const AdminReloadConnectorsButton({super.key, required this.session});
  final ProfileConnectorsSession session;
  Future<bool> _confirmReconnect(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => StudioDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          scrollable: true,
          title: Text(
            'Reconnect MCP tools?',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          content: const Text(
            'Reconnect tools for all profiles on this server using the latest settings and sign-ins.\n\nExisting chats may use more tokens on their next message as their history is resent.',
          ),
          actions: [
            StudioFormActions(
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
              confirmLabel: 'Reconnect tools',
              confirmIcon: Icons.sync,
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => StudioButtonPress(
      child: IconButton.outlined(
        tooltip: 'Reconnect MCP tools',
        onPressed: session.state.busy
            ? null
            : () async {
                await session.reconnect(() => _confirmReconnect(context));
                if (!context.mounted) return;
                final state = session.state;
                if (state.error == null && state.notice != null) {
                  adminMessage(context, state.notice!);
                }
              },
        icon: const Icon(Icons.refresh),
      ),
    ),
  );
}

Future<bool> _launchMcpBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);
