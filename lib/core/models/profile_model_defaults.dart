import 'package:wing/core/models/model_catalog.dart';
import 'model_choice.dart';
import 'provider_access.dart';

/// Values read from stock model defaults, without Flutter or transport ownership.
enum ModelDefaultSettingKind { reasoning, serviceTier }

class ModelDefaultSetting {
  ModelDefaultSetting(this.kind, this.key, List<String> choices)
    : choices = List.unmodifiable(choices);
  final ModelDefaultSettingKind kind;
  final String key;
  final List<String> choices;
  bool get modelCapability => kind == ModelDefaultSettingKind.reasoning;
}

class HelperModelAssignment {
  const HelperModelAssignment({
    required this.task,
    required this.provider,
    required this.model,
    required this.baseUrl,
    required this.reasoningEffort,
  });
  final String task, provider, model, baseUrl;
  final String? reasoningEffort;

  static List<HelperModelAssignment> fromResponse(
    Map<String, dynamic> response,
  ) {
    final rows = response['tasks'];
    if (rows is! List || rows.isEmpty) {
      throw const FormatException('Expected stock auxiliary task records');
    }
    final tasks = <String>{};
    return List.unmodifiable(
      rows.map((row) {
        if (row is! Map ||
            row['task'] is! String ||
            (row['task'] as String).isEmpty ||
            !tasks.add(row['task'] as String) ||
            row['provider'] is! String ||
            (row['provider'] as String).isEmpty ||
            row['model'] is! String ||
            row['base_url'] is! String ||
            !row.containsKey('reasoning_effort') ||
            (row['reasoning_effort'] != null &&
                row['reasoning_effort'] is! String)) {
          throw const FormatException('Invalid stock auxiliary task record');
        }
        return HelperModelAssignment(
          task: row['task'] as String,
          provider: row['provider'] as String,
          model: row['model'] as String,
          baseUrl: row['base_url'] as String,
          reasoningEffort: row['reasoning_effort'] as String?,
        );
      }),
    );
  }

  ModelSelection get selection => provider == 'auto'
      ? const ModelSelection.special(ModelSpecialChoice.automatic)
      : ModelSelection.model(ModelChoice(provider: provider, model: model));

  HelperModelAssignment selecting(ModelSelection selection) {
    if (selection.special != null &&
        selection.special != ModelSpecialChoice.automatic) {
      throw ArgumentError(
        'Only automatic is a helper-model inheritance choice',
      );
    }
    final provider = selection.choice?.provider ?? 'auto';
    final model = selection.choice?.model ?? '';
    // Verified stock model/set policy: a provider change clears the task's
    // endpoint, except a bare custom route. Reasoning omitted from a pick stays.
    final preservesEndpoint =
        provider.trim().toLowerCase() == this.provider.trim().toLowerCase() ||
        provider.trim().toLowerCase() == 'custom';
    return HelperModelAssignment(
      task: task,
      provider: provider,
      model: model,
      baseUrl: preservesEndpoint ? baseUrl : '',
      reasoningEffort: reasoningEffort,
    );
  }

  HelperModelAssignment get automaticReset => HelperModelAssignment(
    task: task,
    provider: 'auto',
    model: '',
    baseUrl: '',
    reasoningEffort: null,
  );

  @override
  bool operator ==(Object other) =>
      other is HelperModelAssignment &&
      task == other.task &&
      provider == other.provider &&
      model == other.model &&
      baseUrl == other.baseUrl &&
      reasoningEffort == other.reasoningEffort;
  @override
  int get hashCode =>
      Object.hash(task, provider, model, baseUrl, reasoningEffort);
}

class ModelDefaultsObservation {
  ModelDefaultsObservation({
    required this.model,
    required List<ModelChoice> choices,
    required List<HelperModelAssignment> helpers,
    required List<ModelDefaultSetting> settings,
  }) : choices = List.unmodifiable(choices),
       helpers = List.unmodifiable(helpers),
       settings = List.unmodifiable(settings);
  final ConfiguredModel model;
  final List<ModelChoice> choices;
  final List<HelperModelAssignment> helpers;
  final List<ModelDefaultSetting> settings;

  static ModelDefaultsObservation fromResponses(
    Map<String, dynamic> info,
    ModelCatalog catalog,
    Map<String, dynamic> auxiliary,
  ) {
    final model = ConfiguredModel.fromInfo(info);
    final choices = catalog.choices;
    final controls = catalog.choice(model.provider, model.model)?.controls;
    return ModelDefaultsObservation(
      model: model,
      choices: choices,
      helpers: HelperModelAssignment.fromResponse(auxiliary),
      settings: [
        if (controls?.reasoning == true)
          ModelDefaultSetting(
            ModelDefaultSettingKind.reasoning,
            'agent.reasoning_effort',
            [
              '',
              if (controls?.canDisableReasoning == true) 'none',
              'minimal',
              'low',
              'medium',
              'high',
              'xhigh',
              'max',
              'ultra',
            ],
          ),
        if (controls?.fast == true)
          ModelDefaultSetting(
            ModelDefaultSettingKind.serviceTier,
            'agent.service_tier',
            ['', 'normal', 'fast'],
          ),
      ],
    );
  }

  ModelDefaultsObservation withChoices(List<ModelChoice> next) =>
      ModelDefaultsObservation(
        model: model,
        choices: next,
        helpers: helpers,
        settings: settings,
      );
  ModelDefaultsObservation withHelpers(List<HelperModelAssignment> next) =>
      ModelDefaultsObservation(
        model: model,
        choices: choices,
        helpers: next,
        settings: settings,
      );
}

class ModelProviderAccess {
  const ModelProviderAccess({
    required this.providerId,
    required this.state,
    required this.sourceLabel,
  });
  final String? providerId;
  final ProviderAccessState state;
  final String sourceLabel;
  static ModelProviderAccess fromResponse(
    Map<String, dynamic> response,
    ConfiguredModel model,
  ) {
    final rows = response['providers'];
    if (rows is! List || rows.any((row) => row is! Map)) {
      throw const FormatException('Invalid provider access inventory');
    }
    final row = rows
        .whereType<Map>()
        .where((row) => row['id'] == model.provider)
        .firstOrNull;
    if (row == null || model.provider.isEmpty) {
      return const ModelProviderAccess(
        providerId: null,
        state: ProviderAccessState.unknown,
        sourceLabel: 'Source unavailable',
      );
    }
    final access = ProviderAccess(Map<String, dynamic>.from(row));
    final source = access.status['source_label'];
    return ModelProviderAccess(
      providerId: model.provider,
      state: access.state,
      sourceLabel: source is String && source.isNotEmpty
          ? source
          : 'Source unavailable',
    );
  }
}
