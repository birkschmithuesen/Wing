import '../widgets/selection_viewport.dart';
import '../widgets/studio_form_actions.dart';
import '../widgets/wing_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/hermes_cloud.dart';
import '../widgets/studio_selection_tile.dart';

import '../models/connection_setup.dart';
import '../services/connection_setup_session.dart';
import '../models/connection.dart';
import '../services/connection_setup_probe.dart';
import '../theme/wing_theme.dart';
import '../widgets/compact_switch.dart';
import '../widgets/connection_icon_picker.dart';
import '../widgets/gateway_headers_editor.dart';
import '../widgets/playful_portrait.dart';
import '../widgets/studio_action_label.dart';
import '../widgets/studio_error.dart';
import '../widgets/wing_wordmark.dart';
import 'connection_guide_screen.dart';

/// One gateway Webapp address, an explicit sign-in, and a provisional access check.
class ConnectionSetupScreen extends StatefulWidget {
  const ConnectionSetupScreen({required this.createSession, super.key});

  final ConnectionSetupSession Function() createSession;

  @override
  State<ConnectionSetupScreen> createState() => _ConnectionSetupScreenState();
}

class _ConnectionSetupScreenState extends State<ConnectionSetupScreen> {
  final _addressForm = GlobalKey<FormState>();
  final _signInForm = GlobalKey<FormState>();
  final _nameForm = GlobalKey<FormState>();
  final _scroll = ScrollController();
  final _checkResults = GlobalKey();
  double _swipeDistance = 0;
  late final TextEditingController _address;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _name;
  late final ConnectionSetupSession _session;
  ConnectionSetupState get _state => _session.value;
  ConnectionSetupCheck get _probe => _state.check;
  ConnectionSetupAccess get _access => _state.draft.access;
  ConnectionIcon get _icon => _state.draft.icon;
  ConnectionSetupStep get _step => _state.step;
  CloudDiscovery? get _discovery => _state.discovery;
  List<CloudOrganization> get _organizations => _state.organizations;
  CloudInstance? get _instance => _state.instance;
  String? get _organization => _state.organization;
  String? get _cloudError => _state.cloudError;
  String? get _saveError => _state.saveError;
  SavedConnection? get _alreadySaved => _state.alreadySaved;
  bool get _cloudBusy => _state.cloudBusy;
  bool get _cloudRoute => _state.cloudRoute;
  bool get _saving => _state.saving;
  bool get _leaving => _state.leaving;
  bool get _editing => _state.editing;
  bool _revealPassword = false;
  bool _confirmingExit = false;
  bool _popScheduled = false;

  @override
  void initState() {
    super.initState();
    _session = widget.createSession();
    _address = TextEditingController(text: _state.draft.address);
    _username = TextEditingController(text: _state.draft.username);
    _password = TextEditingController(text: _state.draft.password);
    _name = TextEditingController(text: _state.draft.name);
    _session.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    final previousStep = _renderedStep;
    for (final entry in [
      (_address, _state.draft.address),
      (_username, _state.draft.username),
      (_password, _state.draft.password),
      (_name, _state.draft.name),
    ]) {
      if (entry.$1.text != entry.$2) entry.$1.text = entry.$2;
    }
    setState(() {});
    if (previousStep != _step) {
      FocusManager.instance.primaryFocus?.unfocus();
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    if (_leaving && !_popScheduled) {
      _popScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(_state.result);
      });
    }
  }

  ConnectionSetupStep? _renderedStep;
  void _continue() {
    if (_addressForm.currentState!.validate()) _session.continueAddress();
  }

  void _swipeEnd(DragEndDetails details) {
    if (_swipeDistance.abs() < 64 || _saving || _cloudBusy) return;
    if (_swipeDistance > 0) {
      if (_step == ConnectionSetupStep.signIn ||
          _step == ConnectionSetupStep.review) {
        _back();
      }
    } else if (_step == ConnectionSetupStep.address) {
      _continue();
    } else if (_step == ConnectionSetupStep.signIn ||
        _step == ConnectionSetupStep.check) {
      _session.continueVerified();
    }
  }

  Future<void> _check() async {
    if (!_cloudRoute &&
        _step == ConnectionSetupStep.signIn &&
        !_signInForm.currentState!.validate()) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final checking = _session.check();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _checkResults.currentContext;
      if (mounted && context != null) Scrollable.ensureVisible(context);
    });
    await checking;
  }

  Future<void> _save() async {
    if (_nameForm.currentState!.validate()) await _session.save();
  }

  Future<void> _customSetup() async {
    final edit = _session.beginAccessEdit();
    final result = await Navigator.of(context).push<ConnectionSetupAccessInput>(
      MaterialPageRoute(
        builder: (_) => _CustomSetupScreen(
          initial: edit.initial,
          validateAddress: _session.validateAddress,
        ),
      ),
    );
    if (result != null && mounted) {
      _session.applyAccess(result, edit: edit);
    }
  }

  Future<void> _back() async {
    if (_confirmingExit) return;
    final result = await _session.back();
    if (!mounted || result != ConnectionSetupBack.discard) return;
    _confirmingExit = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        title: const Text('Discard connection setup?'),
        content: const Text('This connection has not been saved.'),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            cancelLabel: 'Keep editing',
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: 'Discard connection setup',
            confirmIcon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
    );
    _confirmingExit = false;
    if (discard == true && mounted) _session.discard();
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _session.dispose();
    for (final controller in [_address, _username, _password, _name]) {
      controller.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _renderedStep = _step;
    final step = switch (_step) {
      ConnectionSetupStep.choose ||
      ConnectionSetupStep.address ||
      ConnectionSetupStep.cloud => 1,
      ConnectionSetupStep.signIn => 2,
      ConnectionSetupStep.check || ConnectionSetupStep.review => 3,
    };
    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: WingAppBar(
          context: context,
          leading: StudioButtonPress(
            child: BackButton(onPressed: _saving ? null : _back),
          ),
          title: Text(
            _editing ? 'Edit instance' : 'Add instance',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (_step != ConnectionSetupStep.review)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(
                    '$step of 3',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
          ],
        ),
        bottomNavigationBar: _step == ConnectionSetupStep.review
            ? SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    16 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: _footer(),
                ),
              )
            : null,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => _swipeDistance = 0,
          onHorizontalDragUpdate: (details) =>
              _swipeDistance += details.primaryDelta ?? 0,
          onHorizontalDragEnd: _swipeEnd,
          child: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    controller: _scroll,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Semantics(
                                  label: 'Connection setup, step $step of 3',
                                  child: Row(
                                    children: [
                                      for (var index = 0; index < 3; index++)
                                        Expanded(
                                          child: Padding(
                                            padding: EdgeInsets.only(
                                              right: index == 2 ? 0 : 6,
                                            ),
                                            child: ColoredBox(
                                              color: index < step
                                                  ? Theme.of(
                                                      context,
                                                    ).colorScheme.primary
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .outlineVariant,
                                              child: const SizedBox(height: 3),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 24),
                                switch (_step) {
                                  ConnectionSetupStep.choose => _chooseStep(),
                                  ConnectionSetupStep.cloud => _cloudStep(),
                                  ConnectionSetupStep.address => _addressStep(),
                                  ConnectionSetupStep.signIn => _signInStep(),
                                  ConnectionSetupStep.check => _checkStep(),
                                  ConnectionSetupStep.review => _reviewStep(),
                                },
                              ],
                            ),
                            if (_step != ConnectionSetupStep.review)
                              Padding(
                                padding: const EdgeInsets.only(top: 24),
                                child: _footer(),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _heading(String title, [String? subtitle]) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 12),
        Text(
          subtitle,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
      const SizedBox(height: 24),
    ],
  );

  Widget _artwork() => const Padding(
    padding: EdgeInsets.only(bottom: 24),
    child: Center(
      child: SizedBox(
        width: 220,
        height: 128,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.bottomCenter,
              child: PlayfulPortrait(size: 112, circular: true),
            ),
            Positioned(right: 6, top: 0, child: WingFeathers(width: 58)),
          ],
        ),
      ),
    ),
  );

  Widget _chooseStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _artwork(),
      _heading('Connect your agent', 'Choose how to find your Hermes.'),
      for (final cloud in [true, false]) ...[
        _panel(
          Material(
            color: Colors.transparent,
            child: StudioButtonPress(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(cloud ? Icons.cloud_outlined : Icons.link),
                title: Text(cloud ? 'Hermes Cloud' : 'Use an address'),
                subtitle: Text(
                  cloud
                      ? 'Find your instances with Nous Portal'
                      : 'Use your gateway’s Webapp address',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _session.chooseSource(cloud: cloud),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    ],
  );

  Future<void> _discoverCloud({bool switchAccount = false}) =>
      _session.refreshCloud(switchAccount: switchAccount);
  Future<void> _continueCloud() => _session.continueCloud();

  Future<void> _openPortal() async {
    try {
      if (await launchUrl(
        Uri.parse(HermesCloud.portal),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      /* Show an actionable error without platform details. */
    }
    if (mounted) {
      _session.portalOpenFailed();
    }
  }

  Widget _cloudStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _artwork(),
      _heading(
        'Where’s your Hermes?',
        _discovery == null
            ? 'Find your Cloud instances with Nous Portal.'
            : _discovery!.organizations.isNotEmpty
            ? 'Choose the organization that owns your Hermes.'
            : 'Choose the Cloud instance you want to connect.',
      ),
      if (_cloudBusy) ...[
        Semantics(
          liveRegion: true,
          child: Text('Connecting with Nous Portal…'),
        ),
        const SizedBox(height: 16),
      ],
      if (_cloudError case final message?) ...[
        StudioError(message),
        const SizedBox(height: 16),
        StudioButtonPress(
          child: TextButton(
            onPressed: _cloudBusy ? null : () => _discoverCloud(),
            child: const Text('Refresh instances'),
          ),
        ),
        StudioButtonPress(
          child: TextButton(
            onPressed: _cloudBusy
                ? null
                : () => _discoverCloud(switchAccount: true),
            child: const Text('Sign in again'),
          ),
        ),
      ],
      if (_discovery == null)
        _panel(
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sign in with Nous Portal'),
              SizedBox(height: 12),
              Text(
                'Continue to sign in securely, then choose your Hermes instance.',
              ),
            ],
          ),
        )
      else if (_discovery!.organizations.isNotEmpty)
        RadioGroup<String>(
          groupValue: _organization,
          onChanged: _cloudBusy ? (_) {} : _session.selectOrganization,
          child: Column(
            children: [
              for (final org in _discovery!.organizations)
                StudioRadioTile(
                  value: org.id,
                  title: Text(org.name),
                  enabled: !_cloudBusy,
                ),
            ],
          ),
        )
      else if (_discovery!.instances.isEmpty)
        _panel(
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('No Cloud instances yet'),
              SizedBox(height: 12),
              Text(
                'Create an instance in Nous Portal, then come back and refresh.',
              ),
            ],
          ),
        )
      else
        RadioGroup<String>(
          groupValue: _instance?.id,
          onChanged: _session.selectInstance,
          child: Column(
            children: [
              for (final instance in _discovery!.instances)
                StudioRadioTile(
                  value: instance.id,
                  title: Text(instance.name),
                  subtitle: Text(
                    [
                      instance.statusLabel,
                      if (instance.dashboardUrl != null)
                        Uri.parse(instance.dashboardUrl!).host,
                    ].join(' · '),
                  ),
                  enabled: !_cloudBusy && instance.canConnect,
                ),
            ],
          ),
        ),
      if (_alreadySaved != null) ...[
        const SizedBox(height: 12),
        Text('Already saved as ${_alreadySaved!.label}.'),
      ],
      if (_discovery != null) ...[
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            StudioButtonPress(
              child: TextButton(
                onPressed: _cloudBusy ? null : () => _discoverCloud(),
                child: const Text('Refresh'),
              ),
            ),
            if (_organizations.length > 1 && _discovery!.organizations.isEmpty)
              StudioButtonPress(
                child: TextButton(
                  onPressed: _cloudBusy ? null : _session.changeOrganization,
                  child: const Text('Change organization'),
                ),
              ),
            StudioButtonPress(
              child: TextButton(
                onPressed: _cloudBusy ? null : _openPortal,
                child: const Text('Open Nous Portal'),
              ),
            ),
            StudioButtonPress(
              child: TextButton(
                onPressed: _cloudBusy
                    ? null
                    : () => _discoverCloud(switchAccount: true),
                child: const Text('Switch account'),
              ),
            ),
          ],
        ),
        if (_discovery!.instances.any((instance) => !instance.canConnect))
          Text(
            'Start or manage unavailable instances in Nous Portal, then refresh.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    ],
  );

  Widget _addressStep() => Form(
    key: _addressForm,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (MediaQuery.viewInsetsOf(context).bottom == 0) _artwork(),
        _heading(
          'Where’s your Hermes?',
          'Use your Hermes gateway’s Webapp address. A standalone Dashboard address cannot open chats.',
        ),
        viewportSelection(
          TextFormField(
            key: const Key('connection-address'),
            controller: _address,
            decoration: const InputDecoration(
              labelText: 'Gateway Webapp address',
              hintText: 'https://hermes.example.com',
              helperText: 'Include the port and any path in this one address.',
              helperMaxLines: 4,
              errorMaxLines: 5,
            ),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: _session.editAddress,
            onFieldSubmitted: (_) => _continue(),
            validator: _session.validateAddress,
          ),
        ),
        const SizedBox(height: 24),
        _panel(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'One address for your agent',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              const _CapabilityRow(Icons.tune, 'Profiles & settings'),
              const SizedBox(height: 8),
              _CapabilityRow(
                Icons.forum_outlined,
                _access.chatUrl.isEmpty
                    ? 'Live chat · same address'
                    : 'Live chat · custom address',
              ),
            ],
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: StudioButtonPress(
            child: IconButton(
              onPressed: _findAddress,
              icon: const Icon(Icons.help_outline, size: 18),
              tooltip: 'Find my address',
            ),
          ),
        ),
      ],
    ),
  );

  void _findAddress() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const ConnectionGuideScreen()),
  );

  Future<void> _pickIcon() => showConnectionIconPicker(
    context,
    connectionName: _name.text.trim(),
    initialIcon: _icon,
    onSave: _session.setIcon,
  );

  Widget _destination() => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConnectionIconButton(
                icon: _icon,
                onPressed: _saving ? null : _pickIcon,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_cloudRoute) ...[
                        Text(
                          _instance!.name,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        _address.text,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_access.chatUrl.isNotEmpty) ...[
            const Divider(),
            Text(
              'Live chat: ${_access.chatUrl}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    ),
  );

  Widget _signInStep() => Form(
    key: _signInForm,
    child: AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            _access.proxied
                ? 'Connect through your proxy'
                : 'Sign in to Hermes',
          ),
          _destination(),
          if (_access.proxied)
            const Text(
              'Your access proxy handles sign-in. Wing will check that it allows profiles, live chat and history.',
            )
          else ...[
            viewportSelection(
              TextFormField(
                key: const Key('connection-username'),
                controller: _username,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  errorMaxLines: 3,
                ),
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: _session.editUsername,
                validator: _session.validateUsername,
              ),
            ),
            const SizedBox(height: 20),
            viewportSelection(
              TextFormField(
                key: const Key('connection-password'),
                controller: _password,
                obscureText: !_revealPassword,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Password',
                  errorMaxLines: 3,
                  suffixIcon: StudioButtonPress(
                    child: IconButton(
                      tooltip: _revealPassword
                          ? 'Hide password'
                          : 'Show password',
                      onPressed: () =>
                          setState(() => _revealPassword = !_revealPassword),
                      icon: Icon(
                        _revealPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                ),
                onChanged: _session.editPassword,
                onFieldSubmitted: (_) => _check(),
                validator: _session.validatePassword,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Use your dashboard login. Model-provider keys stay on Hermes.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_state.unencrypted) ...[
            const SizedBox(height: 16),
            Text(
              'HTTP does not encrypt this connection. Use a trusted private network or an HTTPS address.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 24),
          StudioButtonPress(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Custom setup'),
              subtitle: Text(_accessDescription(_access)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _customSetup,
            ),
          ),
          if (_access.chatUrl.isNotEmpty)
            Text(
              'Your dashboard authentication and access headers will also be sent to the chat address shown above.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          StudioButtonPress(
            child: OutlinedButton(
              onPressed: _probe.checking ? null : _check,
              child: const Text('Check connection'),
            ),
          ),
          if (_probe.checking || _probe.checkedAt != null) ...[
            const SizedBox(height: 16),
            _checkResultsPanel(),
          ],
        ],
      ),
    ),
  );

  Widget _checkStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading(
        _probe.error == null
            ? 'Let’s check the connection'
            : 'One part needs attention',
      ),
      _destination(),
      _checkResultsPanel(),
    ],
  );

  Widget _checkResultsPanel() => Column(
    key: _checkResults,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _panel(
        Column(
          children: [
            for (final stage in ConnectionCheck.values) ...[
              if (stage != ConnectionCheck.profiles) const Divider(height: 28),
              _checkRow(stage),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (_probe.error case final message?) ...[
        StudioError(message),
        if (_probe.failedStage == ConnectionCheck.chat &&
            !_probe.chatEndpointUnsupported) ...[
          const SizedBox(height: 12),
          Text(
            'If you use a reverse proxy, check WebSocket forwarding for ${_state.chatPath}/api/ws.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Connection details'),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: viewportSelection(
                SelectableText(
                  [
                    'Gateway: ${_address.text}',
                    'Live chat: ${_state.chatSocketUrl}',
                    if (_probe.httpStatus != null) 'HTTP ${_probe.httpStatus}',
                    if (_probe.checkedAt != null)
                      'Checked: ${_probe.checkedAt!.toLocal()}',
                  ].join('\n'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
        StudioButtonPress(
          child: IconButton(
            onPressed:
                _probe.chatEndpointUnsupported &&
                    !_cloudRoute &&
                    _access.chatUrl.isEmpty
                ? _session.reviewAddress
                : _session.editSignIn,
            icon: const Icon(Icons.edit_outlined),
            tooltip: _cloudRoute
                ? 'Sign in to Hermes Cloud again'
                : _probe.chatEndpointUnsupported && _access.chatUrl.isEmpty
                ? 'Edit gateway address'
                : 'Edit sign-in or custom setup',
          ),
        ),
      ] else
        Text(
          _probe.verified
              ? 'Connection verified. Select Next to name and save this instance.'
              : 'Checking access to your Hermes. No message will be sent.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ],
  );

  Widget _checkRow(ConnectionCheck stage) {
    final status = _probe.statuses[stage]!;
    final failed = status == ConnectionCheckStatus.failed;
    final available = status == ConnectionCheckStatus.available;
    final pending = status == ConnectionCheckStatus.checking;
    final colors = Theme.of(context).colorScheme;
    final color = failed
        ? colors.error
        : available || pending
        ? colors.primary
        : colors.onSurfaceVariant;
    final label = switch (stage) {
      ConnectionCheck.profiles => 'Profiles & access',
      ConnectionCheck.chat => 'Live chat',
      ConnectionCheck.history => 'Chat history',
    };
    final detail = switch (status) {
      ConnectionCheckStatus.waiting =>
        _probe.error == null ? 'Waiting' : 'Not checked',
      ConnectionCheckStatus.checking => 'Checking…',
      ConnectionCheckStatus.available => 'Available',
      ConnectionCheckStatus.failed => 'Couldn’t connect',
    };
    return Semantics(
      liveRegion: true,
      label: '$label, $detail',
      child: ExcludeSemantics(
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: pending && !MediaQuery.disableAnimationsOf(context)
                  ? CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                      semanticsLabel: 'Checking connection',
                    )
                  : Icon(
                      failed
                          ? Icons.error_outline
                          : available
                          ? Icons.link
                          : Icons.more_horiz,
                      color: color,
                    ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleSmall),
                  if (!pending)
                    Text(
                      detail,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: color),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reviewStep() => Form(
    key: _nameForm,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _artwork(),
        _heading(
          'Connection verified',
          'Give this Hermes a name you’ll recognize.',
        ),
        _destination(),
        viewportSelection(
          TextFormField(
            key: const Key('connection-name'),
            controller: _name,
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: 'Instance name',
              hintText: 'Home',
              errorMaxLines: 3,
            ),
            textInputAction: TextInputAction.done,
            onChanged: _session.editName,
            onFieldSubmitted: (_) => _save(),
            validator: _session.validateName,
          ),
        ),
        const SizedBox(height: 24),
        StudioButtonPress(
          child: ListTile(
            key: const Key('connection-appearance'),
            contentPadding: EdgeInsets.zero,
            leading: ConnectionIconBadge(icon: _icon),
            title: const Text('Instance icon'),
            subtitle: Text(_icon.label),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_saving,
            onTap: _saving ? null : _pickIcon,
          ),
        ),
        const SizedBox(height: 16),
        if (!_editing)
          Text(
            'Opens with profile ${_probe.preferredProfileLabel!}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        const SizedBox(height: 16),
        const _CapabilityRow(
          Icons.link,
          'Profiles, live chat & history available',
        ),
        const SizedBox(height: 8),
        Text(
          'Access verified · no message sent',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_saveError != null) ...[
          const SizedBox(height: 20),
          StudioError(_saveError!),
        ],
      ],
    ),
  );

  Widget _footer() {
    if (_step == ConnectionSetupStep.choose) return const SizedBox.shrink();
    final (label, action) = switch (_step) {
      ConnectionSetupStep.choose => ('Next', _continue),
      ConnectionSetupStep.cloud => (
        _alreadySaved == null ? 'Next' : 'Open instance',
        _continueCloud,
      ),
      ConnectionSetupStep.address => ('Next', _continue),
      ConnectionSetupStep.signIn ||
      ConnectionSetupStep.check => ('Next', _session.continueVerified),
      ConnectionSetupStep.review => (
        _editing ? 'Save changes' : 'Save and open',
        _save,
      ),
    };
    if (_step == ConnectionSetupStep.review) {
      return StudioFormActions(
        onCancel: _saving ? null : _back,
        cancelLabel: 'Back to connection settings',
        onConfirm: _state.canAdvance ? action : null,
        confirmKey: const Key('connection-primary'),
        confirmLabel: label,
        busy: _saving,
        progressLabel: 'Saving connection',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_step == ConnectionSetupStep.check)
          TextButton(
            onPressed: _probe.checking ? _session.editSignIn : _check,
            child: Text(_probe.checking ? 'Cancel check' : 'Check connection'),
          ),
        StudioButtonPress(
          child: FilledButton(
            key: const Key('connection-primary'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: _state.canAdvance ? action : null,
            child: StudioActionLabel(label, busy: _saving || _cloudBusy),
          ),
        ),
      ],
    );
  }

  Widget _panel(Widget child) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: WingRadius.card,
    ),
    child: child,
  );
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      ExcludeSemantics(
        child: Icon(
          icon,
          size: 20,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ),
    ],
  );
}

String _accessDescription(ConnectionSetupAccess access) {
  final configured = [
    if (access.proxied) 'Proxy sign-in',
    if (access.chatUrl.isNotEmpty) 'Separate chat address',
    if (access.headers.isNotEmpty)
      '${access.headers.length} access ${access.headers.length == 1 ? 'header' : 'headers'}',
  ];
  return configured.isEmpty
      ? 'Only if your administrator gave you extra settings'
      : configured.join(' · ');
}

class _CustomSetupScreen extends StatefulWidget {
  const _CustomSetupScreen({
    required this.initial,
    required this.validateAddress,
  });
  final ConnectionSetupAccess initial;
  final String? Function(String?) validateAddress;

  @override
  State<_CustomSetupScreen> createState() => _CustomSetupScreenState();
}

class _CustomSetupScreenState extends State<_CustomSetupScreen> {
  final _form = GlobalKey<FormState>();
  late final _chat = TextEditingController(text: widget.initial.chatUrl);
  late bool _separate = widget.initial.chatUrl.isNotEmpty;
  late bool _proxied = widget.initial.proxied;
  late GatewayHeaderEdit _headers = GatewayHeaderEdit.retaining(
    widget.initial.headers.keys,
  );
  late bool _showHeaders = widget.initial.headers.isNotEmpty;

  @override
  void dispose() {
    _chat.dispose();
    super.dispose();
  }

  void _done() {
    if (!_form.currentState!.validate()) {
      setState(() => _showHeaders = true);
      return;
    }
    Navigator.pop(
      context,
      ConnectionSetupAccessInput(
        proxied: _proxied,
        separateChat: _separate,
        chatAddress: _chat.text,
        headerEdits: _headers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: WingAppBar(context: context, title: const Text('Custom setup')),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: StudioFormActions(
          onCancel: () => Navigator.pop(context),
          onConfirm: _done,
          confirmLabel: 'Use connection settings',
        ),
      ),
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Most connections don’t need anything here. Use only the settings supplied by your administrator.',
                ),
                const SizedBox(height: 24),
                CompactSwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('My access proxy handles sign-in'),
                  subtitle: const Text(
                    'For a proxy that authenticates Wing’s requests. HTTPS alone does not do this.',
                  ),
                  value: _proxied,
                  onChanged: (value) => setState(() => _proxied = value),
                ),
                const Divider(height: 32),
                CompactSwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use a separate chat address'),
                  subtitle: const Text(
                    'Normally, live chat uses your gateway Webapp address.',
                  ),
                  value: _separate,
                  onChanged: (value) => setState(() => _separate = value),
                ),
                if (_separate) ...[
                  const SizedBox(height: 16),
                  if (MediaQuery.textScalerOf(context).scale(16) >= 24) ...[
                    Text(
                      'Chat gateway base address',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 8),
                  ],
                  Semantics(
                    label: MediaQuery.textScalerOf(context).scale(16) >= 24
                        ? 'Chat gateway base address'
                        : null,
                    child: viewportSelection(
                      TextFormField(
                        key: const Key('connection-chat-address'),
                        controller: _chat,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText:
                              MediaQuery.textScalerOf(context).scale(16) >= 24
                              ? null
                              : 'Chat gateway base address',
                          helperText:
                              'Use an http(s) base address. Wing adds /api/ws.',
                          helperMaxLines: 4,
                          errorMaxLines: 5,
                        ),
                        validator: widget.validateAddress,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Your dashboard authentication and access headers will also be sent to this address.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const Divider(height: 32),
                StudioButtonPress(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Access headers'),
                    subtitle: const Text(
                      'Extra credentials required by some access proxies',
                    ),
                    trailing: Icon(
                      _showHeaders ? Icons.expand_less : Icons.expand_more,
                    ),
                    onTap: () => setState(() => _showHeaders = !_showHeaders),
                  ),
                ),
                Visibility(
                  visible: _showHeaders,
                  maintainState: true,
                  child: GatewayHeadersEditor(
                    savedNames: widget.initial.headers.keys.toSet(),
                    onChanged: (values) => _headers = values,
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
