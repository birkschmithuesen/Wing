import 'model_catalog_details.dart';

/// Direct OpenAI API base rates, independent of the currently selectable models.
/// Exact registry IDs only: subscription and reseller entries are not API rates.
class ModelsDevPrices {
  ModelsDevPrices(Map<String, ModelPrices> models, {this.unavailable = false})
    : models = Map.unmodifiable(models);
  final Map<String, ModelPrices> models;

  /// A failed download may retain cached rates, but cannot certify freshness.
  final bool unavailable;

  factory ModelsDevPrices.fromJson(Map<dynamic, dynamic> data) {
    final provider = data['openai'];
    final models = provider is Map ? provider['models'] : null;
    if (models is! Map) {
      throw const FormatException('Missing models.dev OpenAI API models');
    }
    final prices = <String, ModelPrices>{};
    for (final entry in models.entries) {
      final row = entry.value;
      final cost = row is Map ? row['cost'] : null;
      if (entry.key is! String || cost is! Map) continue;
      double? rate(Object? value) =>
          value is num && value.isFinite && value >= 0
          ? value.toDouble()
          : null;
      final input = rate(cost['input']);
      final output = rate(cost['output']);
      final cache = rate(cost['cache_read']);
      if (input == null || output == null) continue;
      prices[entry.key as String] = ModelPrices.api(
        input: input,
        output: output,
        cache: cache,
      );
    }
    if (prices.isEmpty) {
      throw const FormatException('No valid models.dev OpenAI API rates');
    }
    return ModelsDevPrices(prices);
  }

  /// Persist only the consumed provider/rate fields, not the multi-MB registry.
  Map<String, dynamic> encode() => {
    'openai': {
      'models': {
        for (final entry in models.entries)
          entry.key: {
            'cost': {
              'input': entry.value.inputUsdPerMillion,
              'output': entry.value.outputUsdPerMillion,
              if (entry.value.cacheUsdPerMillion != null)
                'cache_read': entry.value.cacheUsdPerMillion,
            },
          },
      },
    },
  };
}
