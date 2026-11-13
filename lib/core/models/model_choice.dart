import 'model_catalog_details.dart';

/// The canonical stock model/info observation. Empty strings represent an
/// unconfigured model or an automatic provider; they are not guessed routes.
class ConfiguredModel {
  const ConfiguredModel({required this.provider, required this.model});

  final String provider;
  final String model;

  static ConfiguredModel fromInfo(Map<String, dynamic> response) {
    final provider = response['provider'];
    final model = response['model'];
    if (provider is! String || model is! String) {
      throw const FormatException('Invalid stock model observation');
    }
    return ConfiguredModel(provider: provider, model: model);
  }

  bool get hasModel => model.isNotEmpty;
  ModelChoice? get choice => provider.isEmpty || !hasModel
      ? null
      : ModelChoice(provider: provider, model: model);
}

/// A model and its actual provider route. Display text never becomes identity.
class ModelChoice {
  final String provider;
  final String model;
  final String? providerLabel;
  final String? displayName;
  final String? detail;
  final ModelPrices? prices;
  final ModelControls? controls;
  final ModelProvider? providerInfo;

  const ModelChoice({
    required this.provider,
    required this.model,
    this.providerLabel,
    this.displayName,
    this.detail,
    this.prices,
    this.controls,
    this.providerInfo,
  });

  /// A manually entered ID is one identifier, never gateway command syntax.
  static bool isValidEnteredId(String value) {
    final id = value.trim();
    return id.isNotEmpty &&
        !id.startsWith('-') &&
        !RegExp(r'''[\s'"]''').hasMatch(id);
  }

  String get routeLabel => providerLabel?.trim().isNotEmpty == true
      ? providerLabel!.trim()
      : provider;

  String get label =>
      displayName?.trim().isNotEmpty == true ? displayName!.trim() : model;

  bool get _subscriptionBilled =>
      providerInfo?.planUsage?.subscriptionModelIds.contains(model) == true;
  bool get allowanceExempt =>
      providerInfo?.planUsage != null &&
      (_subscriptionBilled || providerInfo?.usageLevels[model] == 'free');

  String? get allowanceLabel =>
      switch (providerInfo?.planUsage == null || _subscriptionBilled
      ? null
      : providerInfo?.usageLevels[model]) {
        'top_tier' => 'Large',
        'free' => 'Free',
        _ => null,
      };
  bool get recommended =>
      providerInfo?.planUsage?.featuredModelIds.contains(model) == true;

  /// Allowances for this exact route, never inferred from the model's name.
  Iterable<PlanUsageGauge> get allowanceGauges {
    final plan = providerInfo?.planUsage;
    if (plan == null || allowanceExempt) return const [];
    final large =
        allowanceLabel == 'Large' || plan.topTierModelIds.contains(model);
    return plan.gauges.where(
      (gauge) => gauge.scope == 'all' || (gauge.scope == 'top_tier' && large),
    );
  }

  String? get planLimitLabel =>
      allowanceGauges.any((gauge) => gauge.leftFraction <= 0)
      ? providerInfo?.planUsage?.creditsPay == true
            ? 'Uses credits'
            : 'Allowance used up'
      : null;
}

enum ModelSpecialChoice { automatic, profileDefault }

/// A typed selection. Inherited choices cannot be mistaken for a model route.
class ModelSelection {
  final ModelChoice? choice;
  final ModelSpecialChoice? special;

  const ModelSelection.model(ModelChoice this.choice) : special = null;
  const ModelSelection.special(ModelSpecialChoice this.special) : choice = null;

  @override
  bool operator ==(Object other) =>
      other is ModelSelection &&
      special == other.special &&
      choice?.provider == other.choice?.provider &&
      choice?.model == other.choice?.model;

  @override
  int get hashCode => Object.hash(special, choice?.provider, choice?.model);
}
