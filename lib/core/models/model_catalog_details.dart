/// Optional route prices or direct API-equivalent rates. Absence stays absent.
class ModelPrices {
  const ModelPrices({this.input, this.output, this.cache, required this.free})
    : _apiInput = null,
      _apiOutput = null,
      _apiCache = null,
      apiEquivalent = false;
  final String? input;
  final String? output;
  final String? cache;
  final bool free;
  final double? _apiInput;
  final double? _apiOutput;
  final double? _apiCache;
  final bool apiEquivalent;

  ModelPrices.api({
    required double input,
    required double output,
    double? cache,
  }) : input = _apiLabel(input),
       output = _apiLabel(output),
       cache = cache == null ? null : _apiLabel(cache),
       free = input == 0 && output == 0 && cache == 0,
       _apiInput = input,
       _apiOutput = output,
       _apiCache = cache,
       apiEquivalent = true;

  static String _apiLabel(double value) {
    final exact = value.toString();
    final fraction = exact.split('.').last;
    return '\$${!exact.contains('e') && fraction.length <= 2 ? value.toStringAsFixed(2) : exact}';
  }

  String get units =>
      apiEquivalent ? 'API equivalent · per 1M tokens' : 'Per 1M tokens';

  /// Stock model/options prices are USD per million tokens, formatted as
  /// "$2.50" or "free". Unknown/missing prices are never guessed.
  double? get inputUsdPerMillion =>
      apiEquivalent ? _apiInput : _usdPerMillion(input);
  double? get outputUsdPerMillion =>
      apiEquivalent ? _apiOutput : _usdPerMillion(output);
  double? get cacheUsdPerMillion =>
      apiEquivalent ? _apiCache : _usdPerMillion(cache);

  static ModelPrices fromJson(Map<dynamic, dynamic> price) => ModelPrices(
    input: _text(price['input']),
    output: _text(price['output']),
    cache: _text(price['cache']),
    free: price['free'] == true,
  );

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static double? _usdPerMillion(String? value) {
    if (value == 'free') return 0;
    if (value == null || !RegExp(r'^\$\d+(?:\.\d+)?$').hasMatch(value)) {
      return null;
    }
    final amount = double.tryParse(value.substring(1));
    return amount != null && amount.isFinite && amount >= 0 ? amount : null;
  }
}

/// Picker control availability, not inferred model capabilities.
class ModelControls {
  const ModelControls({
    required this.reasoning,
    required this.fast,
    required this.ultrafast,
    required this.canDisableReasoning,
  });
  final bool reasoning;
  final bool fast;
  final bool ultrafast;
  final bool canDisableReasoning;
}

class AccountUsageWindow {
  const AccountUsageWindow({
    required this.label,
    required this.usedPercent,
    required this.scope,
    this.resetsAt,
  });
  final String label;
  final double usedPercent;
  final String scope;
  final DateTime? resetsAt;
}

enum AccountUsageState { ready, limited, unknown, unavailable }

class SubscriptionAccount {
  SubscriptionAccount({
    required this.id,
    required this.label,
    required this.state,
    required Iterable<AccountUsageWindow> windows,
    this.resetsAt,
  }) : windows = List.unmodifiable(windows);
  final String id;
  final String label;
  final AccountUsageState state;
  final List<AccountUsageWindow> windows;
  final DateTime? resetsAt;
}

/// Single-account windows and pooled accounts are distinct observations.
/// No cross-account percentage or recovery time is manufactured.
class ProviderAccountUsage {
  ProviderAccountUsage({
    required Iterable<AccountUsageWindow> windows,
    required Iterable<SubscriptionAccount> accounts,
  }) : windows = List.unmodifiable(windows),
       accounts = List.unmodifiable(accounts);
  final List<AccountUsageWindow> windows;
  final List<SubscriptionAccount> accounts;
}

class ModelProvider {
  const ModelProvider({
    required this.slug,
    required this.name,
    this.authType,
    this.authenticated,
    this.warning,
    this.usage,
    this.planUsage,
    this.usageLevels = const {},
  });
  final String slug;
  final String name;
  final String? authType;
  final bool? authenticated;
  final String? warning;
  final ProviderAccountUsage? usage;
  final PlanUsage? planUsage;
  final Map<String, String> usageLevels;
}

/// Server-owned plan allowances. Full gauges remain visible; missing is unknown.
final class PlanUsage {
  PlanUsage({
    required this.kind,
    required this.plan,
    required Iterable<PlanUsageGauge> gauges,
    required Iterable<String> featuredModelIds,
    Iterable<String> topTierModelIds = const [],
    Iterable<String> subscriptionModelIds = const [],
    this.pausedReason,
    this.creditsPay,
  }) : gauges = List.unmodifiable(gauges),
       featuredModelIds = Set.unmodifiable(featuredModelIds),
       topTierModelIds = Set.unmodifiable(topTierModelIds),
       subscriptionModelIds = Set.unmodifiable(subscriptionModelIds);
  final String kind;
  final String? plan;
  final List<PlanUsageGauge> gauges;
  final Set<String> featuredModelIds;
  final Set<String> topTierModelIds;
  final Set<String> subscriptionModelIds;
  final String? pausedReason;
  final bool? creditsPay;
  String? get pauseLabel => switch (pausedReason) {
    null || '' => null,
    'payment_past_due' => 'Plan paused: renewal payment is overdue',
    _ => 'Plan paused',
  };

  static PlanUsage? parse(Object? value) {
    if (value is! Map || value['kind'] != 'usage_window') return null;
    final gauges = value['gauges'];
    final featured = value['featured_model_ids'];
    return PlanUsage(
      kind: value['kind'] as String,
      plan: value['plan'] is String ? value['plan'] as String : null,
      pausedReason: value['paused_reason'] is String
          ? value['paused_reason'] as String
          : null,
      creditsPay: value['credits_pay'] is bool
          ? value['credits_pay'] as bool
          : null,
      featuredModelIds: featured is List
          ? featured.whereType<String>()
          : const [],
      topTierModelIds: value['top_tier_model_ids'] is List
          ? (value['top_tier_model_ids'] as List).whereType<String>()
          : const [],
      subscriptionModelIds: value['subscription_model_ids'] is List
          ? (value['subscription_model_ids'] as List).whereType<String>()
          : const [],
      gauges: [
        if (gauges is List)
          for (final row in gauges)
            if (row is Map &&
                row['label'] is String &&
                row['left_fraction'] is num &&
                (row['left_fraction'] as num).isFinite)
              PlanUsageGauge(
                id: row['label'] as String,
                title: row['title'] is String ? row['title'] as String : '',
                leftFraction: (row['left_fraction'] as num).toDouble().clamp(
                  0,
                  1,
                ),
                scope: row['scope'] is String ? row['scope'] as String : '',
                resetsAt:
                    row['resets_at_ms'] is int &&
                        (row['resets_at_ms'] as int) >= 0 &&
                        (row['resets_at_ms'] as int) <= 8640000000000000
                    ? DateTime.fromMillisecondsSinceEpoch(
                        row['resets_at_ms'] as int,
                        isUtc: true,
                      )
                    : null,
              ),
      ],
    );
  }
}

/// The current task's server-selected allowance; sparse context updates do not
/// replace it. Complete usage observations own its presence or absence.
final class CurrentPlanGauge {
  const CurrentPlanGauge({
    required this.id,
    required this.label,
    required this.usedBasisPoints,
    this.resetsAt,
  });
  final String id, label;
  final int usedBasisPoints;
  final DateTime? resetsAt;
  int get usedPercent => (usedBasisPoints.clamp(0, 10000) / 100).floor();
  String get usedLabel => usedBasisPoints > 0 && usedBasisPoints < 100
      ? '<1% used'
      : '$usedPercent% used';

  static CurrentPlanGauge? parse(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['label'] is! String ||
        value['used_bp'] is! int) {
      return null;
    }
    final reset = value['resets_at_ms'];
    return CurrentPlanGauge(
      id: value['id'] as String,
      label: value['label'] as String,
      usedBasisPoints: value['used_bp'] as int,
      resetsAt: reset is int && reset > 0 && reset <= 8640000000000000
          ? DateTime.fromMillisecondsSinceEpoch(reset, isUtc: true)
          : null,
    );
  }
}

final class PlanUsageGauge {
  const PlanUsageGauge({
    required this.id,
    required this.title,
    required this.leftFraction,
    required this.scope,
    this.resetsAt,
  });
  final String id, title, scope;
  final double leftFraction;
  final DateTime? resetsAt;
  String get remainingLabel => leftFraction > 0 && leftFraction < .01
      ? '<1% left'
      : '${(leftFraction * 100).floor()}% left';
  String get label => switch (id) {
    'day' => 'Daily allowance',
    'week' => 'Weekly allowance',
    'month' => 'Monthly allowance',
    'top_tier' => 'Large models',
    _ => title.isEmpty ? id : title,
  };
}
