import 'profile_tool_setup.dart';
import 'settings_edit.dart';

final class ProfileVoiceChoice {
  const ProfileVoiceChoice(this.id, this.name, [this.detail = '']);
  final String id, name, detail;
  bool matches(String query) =>
      '$id $name $detail'.toLowerCase().contains(query.trim().toLowerCase());
}

// Suggestions from stock Desktop, not a claim of a live Edge catalog.
const edgeVoiceSuggestions = [
  ProfileVoiceChoice('en-US-AriaNeural', 'Aria', 'English · United States'),
  ProfileVoiceChoice('en-US-JennyNeural', 'Jenny', 'English · United States'),
  ProfileVoiceChoice('en-US-AndrewNeural', 'Andrew', 'English · United States'),
  ProfileVoiceChoice('en-US-BrianNeural', 'Brian', 'English · United States'),
  ProfileVoiceChoice('en-US-GuyNeural', 'Guy', 'English · United States'),
  ProfileVoiceChoice('en-GB-SoniaNeural', 'Sonia', 'English · United Kingdom'),
];

final class ProfileVoiceSettings {
  const ProfileVoiceSettings(this.provider, this.key, this.voice);
  final String provider;
  final String? key, voice;
}

final class ProfileVoiceConfiguration {
  ProfileVoiceConfiguration(this.speech, Iterable<AdminField> defaults)
    : defaults = List.unmodifiable(defaults);
  final ProfileVoiceSettings speech;
  final List<AdminField> defaults;

  static ProfileVoiceConfiguration decode(
    Map<String, dynamic> config,
    Map<String, dynamic> schema,
  ) {
    final fields = schema['fields'];
    final provider = setting(config, 'tts.provider');
    if (fields is! Map ||
        fields.keys.any((key) => key is! String) ||
        fields.values.any((field) => field is! Map) ||
        provider is! String ||
        provider.isEmpty) {
      throw const FormatException('Missing speech settings');
    }
    final route = provider == 'nous' ? 'openai' : provider;
    String? voiceKey, voice;
    for (final suffix in ['voice', 'voice_id']) {
      final key = 'tts.$route.$suffix';
      if (!fields.containsKey(key)) continue;
      final value = setting(config, key);
      if (value != null && value is! String) {
        throw const FormatException('Invalid saved voice');
      }
      voiceKey = key;
      voice = value as String?;
      break;
    }
    final defaults = <AdminField>[
      ...voiceFields.where((field) => field.key != 'tts.provider'),
    ];
    for (final key in fields.keys.cast<String>()) {
      for (final kind in ['stt', 'tts']) {
        final current = setting(config, '$kind.provider');
        if (current is String &&
            key.startsWith('$kind.$current.') &&
            RegExp(
              r'\.(model|model_id|language|language_code)$',
            ).hasMatch(key)) {
          defaults.add(
            AdminField(
              key,
              key.split('.').skip(1).join(' '),
              AdminFieldKind.text,
            ),
          );
          break;
        }
      }
    }
    return ProfileVoiceConfiguration(
      ProfileVoiceSettings(provider, voiceKey, voice),
      defaults,
    );
  }
}

enum ProfileVoicePhase {
  idle,
  loading,
  savingVoice,
  changingProvider,
  confirmingSetup,
  runningSetup,
  reviewingCredentials,
}

final class ProfileVoiceState {
  ProfileVoiceState({
    required this.settings,
    required this.selected,
    required Iterable<ProfileVoiceChoice> choices,
    required Iterable<AdminField> defaults,
    required this.readiness,
    required this.phase,
    required this.fresh,
    required this.error,
    required this.catalogueError,
    required this.voiceAcknowledged,
    required this.playing,
    required this.preparing,
    required this.playbackError,
  }) : choices = List.unmodifiable(choices),
       defaults = List.unmodifiable(defaults);
  final ProfileVoiceSettings? settings;
  final String? selected;
  final List<ProfileVoiceChoice> choices;
  final List<AdminField> defaults;
  final ToolSetupReadiness? readiness;
  final ProfileVoicePhase phase;
  final bool fresh, playing, preparing;
  final String? error, catalogueError, playbackError, voiceAcknowledged;
  bool get loading => phase == ProfileVoicePhase.loading;
  bool get saving => phase == ProfileVoicePhase.savingVoice;
  bool get busy => phase != ProfileVoicePhase.idle;
  bool get showProgress =>
      busy && !saving && phase != ProfileVoicePhase.confirmingSetup;
  ToolSetupProvider? get provider => readiness?.providers
      .where(
        (row) =>
            (row.requiresAccount ? 'nous' : row.speechProvider) ==
            settings?.provider,
      )
      .firstOrNull;
  bool get ready => provider?.status == 'ready';
  bool get enabled => fresh && !busy;
  bool get canSelectVoice =>
      fresh &&
      !loading &&
      (phase == ProfileVoicePhase.idle || saving) &&
      settings?.key != null;
  bool get canPickVoice => canSelectVoice && ready && displayChoices.isNotEmpty;
  bool get canEnterVoice => canSelectVoice && ready;
  bool get canPlay => playing || enabled && ready;
  bool get canRefresh => !busy;
  bool get canReviewCredentials => !busy;
  String? get readinessNotice => switch (provider?.status) {
    null || 'ready' => null,
    'needs_keys' => 'Add the provider credentials to use its voices.',
    'needs_auth' => 'Sign in to this provider on Hermes, then refresh.',
    'needs_setup' => 'Complete provider setup to use its voices.',
    _ => 'Provider readiness is unavailable. Refresh to check again.',
  };
  List<ProfileVoiceChoice> get displayChoices {
    final rows = [...choices];
    for (final id in {settings?.voice, selected}) {
      if (id != null && id.isNotEmpty && !rows.any((row) => row.id == id)) {
        rows.insert(0, ProfileVoiceChoice(id, id));
      }
    }
    return List.unmodifiable(rows);
  }

  String get selectedName =>
      displayChoices.where((row) => row.id == selected).firstOrNull?.name ??
      'Provider default';
  bool get suggestedVoices => settings?.provider == 'edge';
}
