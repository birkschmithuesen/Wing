import 'selection_viewport.dart';
import 'studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'wing_app_bar.dart';
import 'package:flutter/material.dart';

import '../models/app_preferences.dart';
import '../services/app_preferences.dart';
import '../services/voice_preferences_session.dart';
import 'studio_error.dart';
import 'studio_select.dart';

class VoicePreferencesPage extends StatelessWidget {
  const VoicePreferencesPage({super.key, required this.createSession});
  final VoicePreferencesSession Function() createSession;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: WingAppBar(context: context, title: const Text('Voice')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: VoicePreferencesCard(createSession: createSession),
          ),
        ),
      ),
    ),
  );
}

class VoicePreferencesCard extends StatefulWidget {
  const VoicePreferencesCard({super.key, required this.createSession});
  final VoicePreferencesSession Function() createSession;
  @override
  State<VoicePreferencesCard> createState() => _VoicePreferencesCardState();
}

class _VoicePreferencesCardState extends State<VoicePreferencesCard>
    with WidgetsBindingObserver {
  late final _session = widget.createSession();
  final _language = TextEditingController();
  String? _displayedLanguage;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.state.addListener(_changed);
    _syncLanguage();
  }

  void _syncLanguage() {
    final observed = _session.current.language.selected;
    if (_displayedLanguage != observed) {
      _displayedLanguage = observed;
      _language.text = observed ?? '';
    }
  }

  void _changed() {
    _syncLanguage();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _session.lifecycle(state);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.state.removeListener(_changed);
    _session.dispose();
    _language.dispose();
    super.dispose();
  }

  Widget _select<T>(
    String title,
    AppPreferenceControl<T> control,
    List<({T value, String label})> options,
    String key,
  ) => StudioLoadingRegion(
    available: !control.busy,
    busy: control.busy,
    label: 'Saving voice settings',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudioSelect<T>(
          key: ValueKey('$key-${control.selected}'),
          label: title,
          value: control.selected,
          options: options,
          onChanged: control.choose == null
              ? null
              : (value) {
                  if (value != null) control.choose!(value);
                },
        ),

        if (control.notice case final notice?) Text(notice),
        if (control.error case final error?) StudioError(error),
      ],
    ),
  );

  static const _engines = [
    (value: AppVoiceProcessing.local, label: 'Local · Android'),
    (value: AppVoiceProcessing.hermes, label: 'Hermes · server profile'),
  ];

  Widget _languageChoice(VoicePreferencesPresentation state) {
    if (!state.manualLanguage) {
      return _select(
        'Recognition language',
        state.language,
        state.languages,
        'voice-language',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        viewportSelection(
          TextField(
            controller: _language,
            enabled: state.saveManualLanguage != null,
            decoration: const InputDecoration(
              labelText: 'Recognition language',
              hintText: 'Device language',
              helperText:
                  'Language tag, e.g. en-US. Empty uses the device language.',
              helperMaxLines: 3,
            ),
          ),
        ),
        const Text(
          'Android does not report installed recognition languages on this device. Unsupported choices will show an error when recording.',
        ),
        if (state.language.notice case final notice?) Text(notice),
        if (state.language.error case final error?) StudioError(error),
        StudioFormActions(
          onCancel: state.language.busy
              ? null
              : () => setState(
                  () => _language.text = state.language.selected ?? '',
                ),
          cancelLabel: 'Cancel language change',
          onConfirm: state.saveManualLanguage == null
              ? null
              : () => state.saveManualLanguage!(_language.text),
          confirmLabel: 'Save recognition language',
          busy: state.language.busy,
          progressLabel: 'Saving recognition language',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _session.current;
    return StudioLoadingRegion(
      available: state.input.selected != null && state.output.selected != null,
      busy: state.loading,
      label: 'Loading voice settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Saved on this phone',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          _select('Live conversation', state.liveMode, const [
            (value: LiveVoiceMode.subscription, label: 'ChatGPT subscription'),
            (value: LiveVoiceMode.api, label: 'OpenAI API'),
          ], 'voice.live_mode'),
          const SizedBox(height: 12),
          Text(
            state.liveMode.selected == LiveVoiceMode.api
                ? 'Uses the Hermes profile’s OpenAI API key. Voice usage is billed to that API account.'
                : 'Uses the Hermes profile’s ChatGPT sign-in and subscription voice limits.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Requires the Wing plugin enabled in this Hermes profile. Changes apply to your next call.',
          ),
          if (state.liveVoice case final voice?) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _select(
                    'GPT-Live voice',
                    voice,
                    state.liveVoices,
                    'voice.live_voice',
                  ),
                ),
                const SizedBox(width: 8),
                StudioButtonPress(
                  child: IconButton(
                    tooltip: state.livePreviewActive
                        ? 'Stop GPT-Live preview'
                        : 'Preview GPT-Live voice',
                    onPressed: state.livePreview,
                    icon: state.livePreviewPreparing
                        ? const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(
                              semanticsLabel: 'Preparing voice preview',
                              strokeWidth: 2,
                            ),
                          )
                        : Icon(
                            state.livePreviewActive
                                ? Icons.stop
                                : Icons.volume_up_outlined,
                          ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              state.liveMode.selected == LiveVoiceMode.api
                  ? 'API voice previews are not available yet.'
                  : 'Preview plays a saved sample offline.',
            ),
            if (state.livePreviewError case final error?) StudioError(error),
          ],
          const SizedBox(height: 24),
          _select('Voice input', state.input, _engines, 'voice.input'),
          const SizedBox(height: 12),
          if (state.inputDescription case final description?) Text(description),
          if (state.languageUnavailableNotice case final notice?) ...[
            const SizedBox(height: 12),
            Text(notice),
          ],
          if (state.showLanguage) ...[
            const SizedBox(height: 12),
            _languageChoice(state),
          ],
          const SizedBox(height: 24),
          _select('Voice output', state.output, _engines, 'voice.output'),
          const SizedBox(height: 12),
          if (state.outputDescription case final description?)
            Text(description),
          if (state.showLocalOutput) ...[
            const SizedBox(height: 12),
            _select(
              'Android voice',
              state.voice,
              state.voices,
              'android-voice',
            ),
            if (state.noVoicesNotice case final notice?) Text(notice),
            const SizedBox(height: 12),
            _select('Speaking speed', state.rate, const [
              (value: AppVoiceRate.slower, label: 'Slower'),
              (value: AppVoiceRate.normal, label: 'Normal'),
              (value: AppVoiceRate.faster, label: 'Faster'),
            ], 'voice-rate'),
            Align(
              alignment: Alignment.centerLeft,
              child: StudioButtonPress(
                child: TextButton.icon(
                  onPressed: state.preview,
                  icon: Icon(
                    state.previewActive ? Icons.stop : Icons.volume_up_outlined,
                  ),
                  label: Text(
                    state.previewActive
                        ? 'Stop preview'
                        : 'Preview Android voice',
                  ),
                ),
              ),
            ),
            if (state.previewError case final error?) StudioError(error),
          ],
          if (state.hermesDescription case final description?) ...[
            const SizedBox(height: 12),
            Text(description),
            if (state.openHermesSettings case final open?)
              Align(
                alignment: Alignment.centerLeft,
                child: StudioButtonPress(
                  child: TextButton(
                    onPressed: open,
                    child: const Text('Open speech synthesis'),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Input and output are independent. Wing never switches processing engines automatically.',
          ),

          if (state.capabilityError case final error?) StudioError(error),
          if (state.operationError case final error?) StudioError(error),
          Align(
            alignment: Alignment.centerLeft,
            child: StudioButtonPress(
              child: TextButton(
                onPressed: state.refresh,
                child: const Text('Refresh Android voices and languages'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
