import 'model_choice.dart';

enum ToolWebCapability { search, extract }

enum ToolSetupPhase {
  idle,
  loadingReadiness,
  loadingModels,
  confirming,
  saving,
  reviewingResult,
}

enum ToolSetupWriteKind { provider, model, setup }

/// A confirmed write is independent of subsequent readiness observations.
class ToolSetupAcknowledgement {
  const ToolSetupAcknowledgement.provider({required this.needsAccount})
    : kind = ToolSetupWriteKind.provider;

  const ToolSetupAcknowledgement.model()
    : kind = ToolSetupWriteKind.model,
      needsAccount = false;

  const ToolSetupAcknowledgement.setup()
    : kind = ToolSetupWriteKind.setup,
      needsAccount = false;

  final ToolSetupWriteKind kind;
  final bool needsAccount;

  String get notice => switch (kind) {
    ToolSetupWriteKind.provider =>
      needsAccount
          ? 'Selection saved. This provider still needs account access.'
          : 'Provider selection saved.',
    ToolSetupWriteKind.model => 'Model selection saved.',
    ToolSetupWriteKind.setup =>
      'Setup started. Review its result to see what completed.',
  };
}

class ToolSetupCredential {
  const ToolSetupCredential({
    required this.key,
    required this.prompt,
    required this.isSet,
  });

  final String key, prompt;
  final bool isSet;
}

/// Stock picker identity and metadata. It contains no credential values.
class ToolSetupProvider {
  ToolSetupProvider({
    required this.name,
    required this.status,
    required this.requiresAccount,
    required this.setupKey,
    required this.webBackend,
    required this.speechProvider,
    required Iterable<ToolWebCapability> capabilities,
    required Iterable<ToolSetupCredential> credentials,
    required this.selectedLabel,
  }) : capabilities = List.unmodifiable(capabilities),
       credentials = List.unmodifiable(credentials);

  final String name, status;
  final bool requiresAccount;
  final String? setupKey, webBackend, speechProvider, selectedLabel;
  final List<ToolWebCapability> capabilities;
  final List<ToolSetupCredential> credentials;
  bool get selected => selectedLabel != null;
}

class ToolSetupReadiness {
  ToolSetupReadiness({
    required this.tool,
    required Iterable<ToolSetupProvider> providers,
  }) : providers = List.unmodifiable(providers);

  final String tool;
  final List<ToolSetupProvider> providers;

  /// These stock categories write provider/backend choices. Other categories
  /// expose credential/setup flows without a provider-selection control.
  bool get canSelectProvider => const {
    'web',
    'stt',
    'tts',
    'image_gen',
    'video_gen',
    'browser',
    'computer_use',
  }.contains(tool);
  bool get offersProviderSelection => canSelectProvider && tool != 'web';
  bool get hasModelCatalog => tool == 'image_gen' || tool == 'video_gen';

  ToolSetupProvider? provider(String name) =>
      providers.where((row) => row.name == name).firstOrNull;

  static ToolSetupReadiness decode(Map<String, dynamic> response, String tool) {
    if (response['name'] != tool ||
        response['has_category'] is! bool ||
        response['providers'] is! List ||
        !response.containsKey('active_provider') ||
        (tool == 'web' &&
            (!response.containsKey('active_search_backend') ||
                !response.containsKey('active_extract_backend')))) {
      throw const FormatException('Invalid tool setup observation');
    }
    final active = _text(response, 'active_provider');
    final search = _text(response, 'active_search_backend');
    final extract = _text(response, 'active_extract_backend');
    final names = <String>{};
    final rows = <ToolSetupProvider>[];
    for (final value in response['providers'] as List) {
      if (value is! Map ||
          value['is_active'] is! bool ||
          value['requires_nous_auth'] is! bool ||
          value['env_vars'] is! List) {
        throw const FormatException('Invalid tool setup provider');
      }
      final name = _requiredText(value, 'name');
      if (!names.add(name)) {
        throw const FormatException('Duplicate tool setup provider');
      }
      final backend = _text(value, 'web_backend');
      final rawCapabilities = value['capabilities'];
      final capabilities = <ToolWebCapability>[];
      if (rawCapabilities != null) {
        if (tool != 'web' || backend == null || rawCapabilities is! List) {
          throw const FormatException('Invalid web capabilities');
        }
        for (final capability in rawCapabilities) {
          final parsed = switch (capability) {
            'search' => ToolWebCapability.search,
            'extract' => ToolWebCapability.extract,
            _ => throw const FormatException('Invalid web capability'),
          };
          if (capabilities.contains(parsed)) {
            throw const FormatException('Duplicate web capability');
          }
          capabilities.add(parsed);
        }
      }
      if (tool == 'web' && backend != null && rawCapabilities == null) {
        throw const FormatException('Missing web capabilities');
      }
      final credentials = <ToolSetupCredential>[];
      final keys = <String>{};
      for (final env in value['env_vars'] as List) {
        if (env is! Map || env['is_set'] is! bool) {
          throw const FormatException('Invalid tool credential metadata');
        }
        final key = _requiredText(env, 'key');
        if (!keys.add(key)) {
          throw const FormatException('Duplicate tool credential');
        }
        // Check the stock metadata without retaining unused display values.
        _text(env, 'url');
        _text(env, 'default');
        credentials.add(
          ToolSetupCredential(
            key: key,
            prompt: _requiredText(env, 'prompt'),
            isSet: env['is_set'] as bool,
          ),
        );
      }
      final selectedCapabilities = <String>[
        if (backend != null && search == backend) 'search',
        if (backend != null && extract == backend) 'extract',
      ];
      _requiredText(value, 'badge', allowEmpty: true);
      _requiredText(value, 'tag', allowEmpty: true);
      rows.add(
        ToolSetupProvider(
          name: name,
          status: _requiredText(value, 'status'),
          requiresAccount: value['requires_nous_auth'] as bool,
          setupKey: _text(value, 'post_setup'),
          webBackend: backend,
          speechProvider: _text(value, 'tts_provider'),
          capabilities: capabilities,
          credentials: credentials,
          selectedLabel: tool == 'web'
              ? selectedCapabilities.isEmpty
                    ? null
                    : 'Selected for ${selectedCapabilities.join(' and ')}'
              : value['is_active'] == true || active == name
              ? 'Selected'
              : null,
        ),
      );
    }
    if (response['has_category'] == false && rows.isNotEmpty) {
      throw const FormatException('Unexpected tool setup providers');
    }
    return ToolSetupReadiness(
      tool: tool,
      providers: [
        ...rows.where((row) => row.selected),
        ...rows.where((row) => !row.selected),
      ],
    );
  }
}

/// The tool catalog reports an effective current choice, including its default.
/// It does not expose whether that choice was explicitly stored in config.
class ToolModelsObservation {
  ToolModelsObservation({
    required this.provider,
    required this.plugin,
    required this.current,
    required this.hasModels,
    required Iterable<ModelChoice> choices,
  }) : choices = List.unmodifiable(choices);

  final String provider;
  final String? plugin, current;
  final bool hasModels;
  final List<ModelChoice> choices;

  static ToolModelsObservation decode(
    Map<String, dynamic> response,
    String tool,
    String provider,
  ) {
    if (response['name'] != tool ||
        response['has_models'] is! bool ||
        response['models'] is! List) {
      throw const FormatException('Invalid tool model catalog');
    }
    final hasModels = response['has_models'] as bool;
    final plugin = _text(response, 'plugin');
    if (hasModels &&
        (response['provider'] != provider ||
            plugin == null ||
            plugin.isEmpty)) {
      throw const FormatException(
        'Tool model catalog belongs to another provider',
      );
    }
    final current = _text(response, 'current');
    final defaultModel = _text(response, 'default');
    final ids = <String>{};
    final choices = <ModelChoice>[];
    for (final row in response['models'] as List) {
      if (row is! Map) {
        throw const FormatException('Invalid tool model');
      }
      final id = _requiredText(row, 'id');
      if (!ids.add(id)) {
        throw const FormatException('Duplicate tool model');
      }
      choices.add(
        ModelChoice(
          provider: provider,
          model: id,
          displayName: _requiredText(row, 'display', allowEmpty: true),
          detail: [
            _requiredText(row, 'strengths', allowEmpty: true),
            _requiredText(row, 'speed', allowEmpty: true),
            _requiredText(row, 'price', allowEmpty: true),
          ].where((text) => text.isNotEmpty).join(' · '),
        ),
      );
    }
    if (hasModels != choices.isNotEmpty ||
        (current != null && !ids.contains(current)) ||
        (!hasModels && (current != null || defaultModel != null))) {
      throw const FormatException('Invalid current tool model');
    }
    return ToolModelsObservation(
      provider: provider,
      plugin: plugin,
      current: current,
      hasModels: hasModels,
      choices: choices,
    );
  }
}

/// Issued by the parent owner; its identity scopes one borrowed model route.
final class ToolModelEditor {
  ToolModelEditor(this.provider);
  final String provider;
}

class ProfileToolSetupState {
  const ProfileToolSetupState({
    required this.readiness,
    required this.models,
    required this.pendingModel,
    required this.phase,
    required this.readinessVerified,
    required this.modelsVerified,
    required this.reviewRequired,
    required this.acknowledgement,
    required this.error,
  });

  final ToolSetupReadiness? readiness;
  final ToolModelsObservation? models;
  final String? pendingModel;
  final ToolSetupPhase phase;
  final bool readinessVerified, modelsVerified, reviewRequired;
  final ToolSetupAcknowledgement? acknowledgement;
  final String? error;
  bool get busy => phase != ToolSetupPhase.idle;
  bool get saving => phase == ToolSetupPhase.saving;
  bool get canChooseProvider =>
      !busy &&
      readinessVerified &&
      !reviewRequired &&
      readiness?.canSelectProvider == true;
  bool get canStageModel =>
      !busy && modelsVerified && !reviewRequired && models?.hasModels == true;
  bool get canSaveModel =>
      canStageModel && pendingModel != null && pendingModel != models?.current;
  bool get canOpenModels =>
      !busy &&
      readinessVerified &&
      !reviewRequired &&
      readiness?.hasModelCatalog == true;
  bool get canRunSetup => !busy && readinessVerified && !reviewRequired;
  bool get canReviewCredentials => !busy;
  ModelSelection? get modelSelection {
    final provider = models?.provider;
    final selected = pendingModel ?? models?.current;
    return provider == null || selected == null
        ? null
        : ModelSelection.model(
            ModelChoice(provider: provider, model: selected),
          );
  }

  String get modelSelectionStatus =>
      pendingModel != null && pendingModel != models?.current
      ? 'Pending selection · Use model to apply'
      : 'Selected';
  String? get notice => acknowledgement?.notice;
}

String? _text(Map value, String key) {
  final text = value[key];
  if (text != null && text is! String) {
    throw const FormatException('Invalid tool setup metadata');
  }
  return text as String?;
}

String _requiredText(Map value, String key, {bool allowEmpty = false}) {
  final text = value[key];
  if (text is! String || (!allowEmpty && text.isEmpty)) {
    throw const FormatException('Invalid tool setup text');
  }
  return text;
}
