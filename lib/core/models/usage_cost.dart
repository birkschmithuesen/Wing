import 'model_catalog.dart';
import 'models_dev_prices.dart';

double? usageAmount(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

int? usageTokenCount(Object? value) =>
    value is num &&
        value.isFinite &&
        value >= 0 &&
        value <= 9007199254740991 &&
        value == value.truncateToDouble()
    ? value.toInt()
    : null;

enum UsageCostUnavailable { price, tokens, reportedCost }

/// Hermes analytics input is already uncached; output already includes reasoning.
/// These estimates intentionally exclude cache writes and request-level surcharges.
class ModelUsageCost {
  static bool isSubscriptionUsage(Map<dynamic, dynamic> usage) =>
      ModelCatalog.isSubscriptionProvider(usage['provider']);

  final String model;
  final bool isApiEquivalent;
  final List<int?> tokenCounts;
  final double? inputCost;
  final double? cachedInputCost;
  final double? outputCost;
  final double? amount;
  final UsageCostUnavailable? unavailable;

  ModelUsageCost._(
    Map<String, dynamic> usage,
    this.inputCost,
    this.cachedInputCost,
    this.outputCost,
    this.amount,
    this.unavailable,
  ) : model = usage['model'] is String
          ? usage['model'] as String
          : 'Unknown model',
      isApiEquivalent = isSubscriptionUsage(usage),
      tokenCounts = List.unmodifiable([
        usageTokenCount(usage['input_tokens']),
        usageTokenCount(usage['cache_read_tokens']),
        usageTokenCount(usage['output_tokens']),
      ]);

  factory ModelUsageCost.fromUsage(
    Map<String, dynamic> usage,
    ModelsDevPrices? prices,
  ) {
    if (!isSubscriptionUsage(usage)) {
      final amount = usageAmount(usage['estimated_cost']);
      return ModelUsageCost._(
        usage,
        null,
        null,
        null,
        amount,
        amount == null ? UsageCostUnavailable.reportedCost : null,
      );
    }
    final price = prices?.models['${usage['model']}'];
    final inputRate = price?.inputUsdPerMillion;
    final cachedRate = price?.cacheUsdPerMillion;
    final outputRate = price?.outputUsdPerMillion;
    if (inputRate == null || cachedRate == null || outputRate == null) {
      return ModelUsageCost._(
        usage,
        null,
        null,
        null,
        null,
        UsageCostUnavailable.price,
      );
    }
    final input = usageTokenCount(usage['input_tokens']);
    final cached = usageTokenCount(usage['cache_read_tokens']);
    final output = usageTokenCount(usage['output_tokens']);
    if (input == null || cached == null || output == null) {
      return ModelUsageCost._(
        usage,
        null,
        null,
        null,
        null,
        UsageCostUnavailable.tokens,
      );
    }
    final inputCost = input / 1000000 * inputRate;
    final cachedCost = cached / 1000000 * cachedRate;
    final outputCost = output / 1000000 * outputRate;
    final amount = usageAmount(inputCost + cachedCost + outputCost);
    return ModelUsageCost._(
      usage,
      inputCost,
      cachedCost,
      outputCost,
      amount,
      amount == null ? UsageCostUnavailable.tokens : null,
    );
  }

  /// Revalue cached token facts using the shared exact-ID rate observation.
  ModelUsageCost withPrices(ModelsDevPrices? prices) => !isApiEquivalent
      ? this
      : ModelUsageCost.fromUsage({
          'model': model,
          'provider': 'openai-codex',
          for (var i = 0; i < 3; i++)
            ['input_tokens', 'cache_read_tokens', 'output_tokens'][i]:
                tokenCounts[i],
        }, prices);
}

class UsageCostSummary {
  final List<ModelUsageCost> models;
  UsageCostSummary(Iterable<ModelUsageCost> models)
    : models = List.unmodifiable(models);

  bool get hasSubscription => models.any((model) => model.isApiEquivalent);
  bool get hasReported => models.any((model) => !model.isApiEquivalent);
  bool get isMixed => hasSubscription && hasReported;
  int get pricedCount => models.where((model) => model.amount != null).length;
  bool get isPartial => pricedCount < models.length;
  double? get total => _sum(models);
  double? get apiEquivalent =>
      _sum(models.where((model) => model.isApiEquivalent));
  double? get reported => _sum(models.where((model) => !model.isApiEquivalent));

  static double? _sum(Iterable<ModelUsageCost> models) {
    final amounts = models.map((model) => model.amount).whereType<double>();
    return amounts.isEmpty
        ? null
        : usageAmount(amounts.fold<double>(0, (a, b) => a + b));
  }
}

String formatUsageUsd(double? amount) {
  if (amount == null || !amount.isFinite || amount < 0) return 'Unavailable';
  if (amount > 0 && amount < 0.01) return '< USD 0.01';
  return 'USD ${amount.toStringAsFixed(2)}';
}
