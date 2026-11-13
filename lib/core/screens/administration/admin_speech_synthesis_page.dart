import '../../widgets/selection_viewport.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../controllers/profile_voice_controller.dart';
import '../../models/profile_voice.dart';
import '../../models/profile_tool_setup.dart';
import '../../services/administration_operation_session.dart';
import '../../widgets/studio_selection_tile.dart';
import '../../widgets/studio_select.dart';
import 'admin_widgets.dart';

class AdminSpeechSynthesisPage extends StatefulWidget {
  const AdminSpeechSynthesisPage({
    super.key,
    required this.createSession,
    required this.onCredential,
    required this.onResult,
  });
  final ProfileVoiceController Function() createSession;
  final Future<void> Function(BuildContext, ToolSetupCredential) onCredential;
  final Future<void> Function(BuildContext, AdministrationOperationSession)
  onResult;
  @override
  State<AdminSpeechSynthesisPage> createState() =>
      _AdminSpeechSynthesisPageState();
}

class _AdminSpeechSynthesisPageState extends State<AdminSpeechSynthesisPage>
    with WidgetsBindingObserver {
  late final _session = widget.createSession();
  final _custom = TextEditingController();
  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_session.stopPreview());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_changed);
    _session.dispose();
    _custom.dispose();
    super.dispose();
  }

  void _select(String? voice) {
    if (voice == null) return;
    _custom.clear();
    unawaited(_session.select(voice));
  }

  void _customVoice() {
    unawaited(_session.selectCustom(_custom.text));
  }

  Future<void> _refresh() {
    _custom.clear();
    return _session.load();
  }

  Future<void> _selectProvider(String? name) async {
    if (name == null) return;
    _custom.clear();
    await _session.selectProvider(name);
  }

  Future<void> _setup(String key) => _session.setup(
    key,
    confirm: () => adminConfirm(
      context,
      'Install setup requirements?',
      'Hermes may download and install dependencies on the server. Other profiles can share those dependencies.',
      action: 'Run setup',

      actionIcon: Icons.build_outlined,
      destructive: false,
    ),
    openResult: (operation) => widget.onResult(context, operation),
  );
  Future<void> _secret(ToolSetupCredential field) => _session.reviewCredentials(
    field,
    () => widget.onCredential(context, field),
  );

  Future<void> _pickVoice(List<ProfileVoiceChoice> choices) async {
    await _session.stopPreview();
    if (!mounted) return;
    var search = '';
    final value = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final filtered = choices.where((v) => v.matches(search)).toList();
          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .65,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _session.state.suggestedVoices
                        ? 'Suggested voices'
                        : 'Voices',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  if (choices.length > 8) ...[
                    viewportSelection(
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Search voices',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (value) => update(() => search = value),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Expanded(
                    child: RadioGroup<String>(
                      groupValue: _session.state.selected,
                      onChanged: (value) => Navigator.pop(context, value),
                      child: filtered.isEmpty
                          ? const Center(child: Text('No matching voices.'))
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final voice = filtered[index];
                                return StudioRadioTile<String>(
                                  value: voice.id,
                                  title: Text(voice.name),
                                  subtitle: voice.detail.isEmpty
                                      ? null
                                      : Text(voice.detail),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted && value != null) _select(value);
  }

  @override
  Widget build(BuildContext context) {
    final state = _session.state;
    final settings = state.settings;
    final provider = state.provider;
    final ready = state.ready;
    final rows = state.displayChoices;
    final playing = state.playing;
    final play = StudioButtonPress(
      child: TextButton.icon(
        onPressed: state.canPlay ? _session.play : null,
        icon: Icon(playing ? Icons.stop : Icons.play_arrow),
        label: Text(playing ? 'Stop' : 'Play'),
      ),
    );
    final voice = Semantics(
      button: true,
      child: StudioButtonPress(
        child: InkWell(
          onTap: state.canPickVoice ? () => _pickVoice(rows) : null,
          borderRadius: BorderRadius.circular(6),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Voice',
              enabled: state.canEnterVoice,
              suffixIcon: const Icon(Icons.expand_more),
            ),
            child: Text(state.selectedName),
          ),
        ),
      ),
    );
    return AdminPage(
      title: 'Speech synthesis',
      scope: _session.scopeLabel,
      actions: [
        StudioButtonPress(
          child: IconButton(
            tooltip: 'Refresh speech settings',
            onPressed: state.canRefresh ? _refresh : null,
            icon: const Icon(Icons.refresh),
          ),
        ),
      ],
      child: StudioLoadingRegion(
        available: state.readiness != null,
        busy: state.showProgress,
        label: 'Loading speech settings',
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (state.error != null)
              AdminNotice.error(state.error!, retry: _refresh),
            if (state.readiness?.providers.isNotEmpty == true) ...[
              StudioSelect<String>(
                label: 'Provider',
                value: provider?.name,
                options: [
                  for (final row in state.readiness!.providers)
                    (value: row.name, label: row.name),
                ],
                onChanged: state.enabled ? _selectProvider : null,
              ),
              const SizedBox(height: 20),
            ] else if (!state.busy && state.error == null)
              const AdminNotice('No speech providers are available.'),
            if (provider != null && !ready) ...[
              AdminNotice(state.readinessNotice!),
              ..._credentials(provider),
              if (provider.setupKey != null)
                StudioButtonPress(
                  child: TextButton(
                    onPressed: !state.enabled
                        ? null
                        : () => _setup(provider.setupKey!),
                    child: const Text('Setup requirements'),
                  ),
                ),
            ],
            if (ready && settings != null) ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  if (MediaQuery.textScalerOf(context).scale(16) > 24) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        voice,
                        const SizedBox(height: 8),
                        Align(alignment: Alignment.centerLeft, child: play),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: voice),
                      const SizedBox(width: 8),
                      play,
                    ],
                  );
                },
              ),
              if (state.saving)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Saving…'),
                ),
              if (state.preparing)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Preparing audio…'),
                ),
              if (state.playbackError != null)
                AdminNotice.error(state.playbackError!),
              if (state.catalogueError != null)
                AdminNotice.error(state.catalogueError!, retry: _refresh),
            ],
            if (provider != null) ...[
              const SizedBox(height: 16),
              ExpansionTile(
                title: const Text('Advanced'),
                tilePadding: EdgeInsets.zero,
                children: [
                  if (ready && settings?.key != null)
                    Focus(
                      onFocusChange: (focused) {
                        if (!focused && state.canEnterVoice) _customVoice();
                      },
                      child: viewportSelection(
                        TextField(
                          controller: _custom,
                          enabled: state.canEnterVoice,
                          maxLength: 256,
                          decoration: const InputDecoration(
                            labelText: 'Voice ID',
                          ),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _customVoice(),
                        ),
                      ),
                    ),
                  if (ready) ..._credentials(provider),
                  if (ready && provider.setupKey != null)
                    StudioButtonPress(
                      child: TextButton(
                        onPressed: !state.enabled
                            ? null
                            : () => _setup(provider.setupKey!),
                        child: const Text('Setup requirements'),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _credentials(ToolSetupProvider provider) => [
    for (final field in provider.credentials)
      StudioButtonPress(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(field.prompt),
          subtitle: Text(field.isSet ? 'Configured' : 'Not configured'),
          trailing: const Icon(Icons.key_outlined),
          onTap: _session.state.canReviewCredentials
              ? () => _secret(field)
              : null,
        ),
      ),
  ];
}
