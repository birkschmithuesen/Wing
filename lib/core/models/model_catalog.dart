import 'model_choice.dart';
import 'models_dev_prices.dart';
import 'model_catalog_details.dart';

/// Immutable profile catalog, with one canonical decoder for stock observations.
class ModelCatalog {
  ModelCatalog({
    required Iterable<ModelProvider> providers,
    required Iterable<ModelChoice> choices,
    ModelsDevPrices? apiPrices,
  }) : providers = List.unmodifiable(providers),
       choices = List.unmodifiable(choices),
       apiPrices = apiPrices ?? ModelsDevPrices({});
  final ModelsDevPrices apiPrices;
  static bool isSubscriptionProvider(Object? provider) =>
      provider == 'openai-codex';
  final List<ModelProvider> providers;
  final List<ModelChoice> choices;

  ModelProvider? provider(String slug) =>
      providers.where((p) => p.slug == slug).firstOrNull;
  ModelChoice? choice(String provider, String model) => choices
      .where((c) => c.provider == provider && c.model == model)
      .firstOrNull;

  static ModelPrices? _prices(
    String provider,
    String model,
    Object? backend,
    ModelsDevPrices? api,
  ) {
    if (isSubscriptionProvider(provider) || provider == 'openai-api') {
      return api?.models[model];
    }
    return backend is Map ? ModelPrices.fromJson(backend) : null;
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
  static List<AccountUsageWindow> _windows(Object? value) {
    if (value is! List) return const [];
    return [
      for (final w in value)
        if (w is Map &&
            w['label'] is String &&
            w['scope'] is String &&
            w['used_percent'] is num &&
            (w['used_percent'] as num).isFinite)
          AccountUsageWindow(
            label: w['label'] as String,
            usedPercent: (w['used_percent'] as num).toDouble(),
            scope: w['scope'] as String,
            resetsAt: _date(w['resets_at']),
          ),
    ];
  }

  static ProviderAccountUsage? _usage(Object? value) {
    if (value is! Map) return null;
    final raw = value['accounts'];
    return ProviderAccountUsage(
      windows: _windows(value['windows']),
      accounts: [
        if (raw is List)
          for (final a in raw)
            if (a is Map && a['id'] is String && a['state'] is String)
              SubscriptionAccount(
                id: a['id'] as String,
                label: _text(a['label']) ?? '',
                state:
                    AccountUsageState.values
                        .where((s) => s.name == a['state'])
                        .firstOrNull ??
                    AccountUsageState.unknown,
                windows: _windows(a['windows']),
                resetsAt: _date(a['resets_at']),
              ),
      ],
    );
  }

  static ModelCatalog fromOptions(
    Map<String, dynamic> response, {
    ModelsDevPrices? apiPrices,
  }) {
    final rows = response['providers'];
    if (rows is! List) {
      throw const FormatException('Expected a list of provider records');
    }
    final providers = <ModelProvider>[];
    final choices = <ModelChoice>[];
    for (final row in rows) {
      if (row is! Map ||
          _text(row['slug']) == null ||
          row['name'] is! String ||
          row['models'] is! List) {
        throw const FormatException('Expected a model-options provider record');
      }
      final slug = _text(row['slug'])!;
      final provider = ModelProvider(
        slug: slug,
        name: _text(row['name']) ?? slug,
        authType: _text(row['auth_type']),
        authenticated: row['authenticated'] is bool
            ? row['authenticated'] as bool
            : null,
        warning: _text(row['warning']),
        usage: _usage(row['usage']),
        planUsage: PlanUsage.parse(row['plan_usage']),
        usageLevels: Map.unmodifiable({
          if (row['usage_levels'] case final Map levels)
            for (final entry in levels.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
        }),
      );
      providers.add(provider);
      final pricing = row['pricing'];
      final capabilities = row['capabilities'];
      final listed = row['models'] as List;
      final featured = provider.planUsage?.featuredModelIds ?? const <String>{};
      final ordered = [
        ...featured.where(listed.contains),
        ...listed.where((id) => !featured.contains(id)),
      ];
      for (final id in ordered) {
        if (id is! String || id.trim().isEmpty) {
          throw const FormatException('Expected a nonempty string model ID');
        }
        final model = id.trim();
        final price = pricing is Map ? pricing[model] : null;
        final control = capabilities is Map ? capabilities[model] : null;
        choices.add(
          ModelChoice(
            provider: slug,
            model: model,
            providerLabel: provider.name,
            providerInfo: provider,
            prices: _prices(slug, model, price, apiPrices),
            controls: control is Map
                ? ModelControls(
                    reasoning: control['reasoning'] == true,
                    fast: control['fast'] == true,
                    ultrafast: control['ultrafast'] == true,
                    canDisableReasoning:
                        control['can_disable_reasoning'] != false,
                  )
                : null,
          ),
        );
      }
    }
    return ModelCatalog(
      providers: providers,
      choices: choices,
      apiPrices: apiPrices,
    );
  }
}
