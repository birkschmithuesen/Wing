import 'usage_cost.dart';
import 'models_dev_prices.dart';

const usagePeriods = [1, 7, 30, 90, 365];
const usageTokenKeys = ['input_tokens', 'cache_read_tokens', 'output_tokens'];
const usageTokenLabels = ['Uncached input', 'Cached input', 'Output'];

/// Null counters stay unknown. Reasoning is already included in output.
class UsageTokens {
  final List<int?> values;
  UsageTokens.fromJson(Map<String, dynamic> row)
    : values = List.unmodifiable([
        for (final key in usageTokenKeys) usageTokenCount(row[key]),
      ]);
  const UsageTokens.zero() : values = const [0, 0, 0];
  const UsageTokens.unavailable() : values = const [null, null, null];
  UsageTokens.fromCost(ModelUsageCost row) : values = row.tokenCounts;
  UsageTokens.sum(Iterable<UsageTokens> rows)
    : values = List.unmodifiable([
        for (var i = 0; i < 3; i++)
          _completeSum(rows.map((row) => row.values[i])),
      ]);
  int? get total => _completeSum(values);
  bool get complete => total != null;

  static int? _completeSum(Iterable<int?> values) {
    var total = 0;
    for (final value in values) {
      if (value == null) return null;
      total += value;
    }
    return usageTokenCount(total);
  }
}

class UsageDay {
  final DateTime date;
  final UsageTokens tokens;
  final bool isPlaceholder;
  const UsageDay(this.date, this.tokens, {this.isPlaceholder = false});
  String get id => date.toIso8601String().substring(0, 10);
}

class UsageDaily {
  final List<UsageDay> days;
  final Set<String> reportedDates;
  UsageDaily._(Iterable<UsageDay> days, Iterable<String> reportedDates)
    : days = List.unmodifiable(days),
      reportedDates = Set.unmodifiable(reportedDates);

  /// Profiles share the server's date ordinals. An absent date contributes
  /// zero usage; a returned unknown counter keeps that counter unknown.
  factory UsageDaily.sum(Iterable<UsageDaily> profiles) {
    final byDate = <DateTime, List<UsageTokens>>{};
    final reported = <String>{};
    for (final profile in profiles) {
      reported.addAll(profile.reportedDates);
      for (final day in profile.days) {
        (byDate[day.date] ??= []).add(day.tokens);
      }
    }
    final dates = byDate.keys.toList()..sort();
    if (dates.isEmpty) return UsageDaily._(const [], const {});
    return UsageDaily._([
      for (
        var date = dates.first;
        !date.isAfter(dates.last);
        date = date.add(const Duration(days: 1))
      )
        UsageDay(date, UsageTokens.sum(byDate[date] ?? const [])),
    ], reported);
  }

  /// A browsing year ending at the latest returned server date. Earlier
  /// padding is unknown, rather than pretending to know the server's cutoff.
  List<UsageDay> get calendarDays {
    if (days.isEmpty) return const [];
    final yearStart = days.last.date.subtract(const Duration(days: 365));
    final first = days.first.date.isBefore(yearStart)
        ? days.first.date
        : yearStart;
    return [
      for (
        var date = first;
        date.isBefore(days.first.date);
        date = date.add(const Duration(days: 1))
      )
        UsageDay(date, const UsageTokens.unavailable(), isPlaceholder: true),
      ...days,
    ];
  }

  factory UsageDaily.fromJson(
    Map<String, dynamic> data, {
    required int period,
  }) {
    if (!usagePeriods.contains(period) || data['daily'] is! List) {
      throw const FormatException('Daily usage is unavailable.');
    }
    final byDate = <String, UsageTokens>{};
    for (final raw in data['daily'] as List) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Invalid daily usage.');
      }
      final id = raw['day'];
      final date = id is String ? DateTime.tryParse('${id}T00:00:00Z') : null;
      if (date == null ||
          date.toIso8601String().substring(0, 10) != id ||
          byDate.containsKey(id)) {
        throw const FormatException('Invalid usage date.');
      }
      byDate[id as String] = UsageTokens.fromJson(raw);
    }
    // Stock Hermes filters a rolling N*24 hours, then groups session starts by
    // server-local date (per-row DST). It supplies no timezone or date bounds.
    // UTC DateTimes here encode date ordinals only; never convert to phone time.
    final ids = byDate.keys.toList()..sort();
    if (ids.isEmpty) return UsageDaily._(const [], const {});
    final first = DateTime.parse('${ids.first}T00:00:00Z');
    final last = DateTime.parse('${ids.last}T00:00:00Z');
    return UsageDaily._([
      for (var i = 0; i <= last.difference(first).inDays; i++)
        UsageDay(
          first.add(Duration(days: i)),
          byDate[first
                  .add(Duration(days: i))
                  .toIso8601String()
                  .substring(0, 10)] ??
              const UsageTokens.zero(),
        ),
    ], Set.unmodifiable(ids));
  }
}

class UsageModelGroup {
  final String model;
  final List<ModelUsageCost> rows;
  UsageModelGroup(this.model, Iterable<ModelUsageCost> rows)
    : rows = List.unmodifiable(rows);
  String get id => model;
  UsageTokens get tokens =>
      UsageTokens.sum(rows.map((r) => UsageTokens.fromCost(r)));
  UsageCostSummary get costs => UsageCostSummary(rows);
}

class UsageModels {
  final List<ModelUsageCost> rows;
  final List<UsageModelGroup> groups;
  UsageModels._(Iterable<ModelUsageCost> rows, Iterable<UsageModelGroup> groups)
    : rows = List.unmodifiable(rows),
      groups = List.unmodifiable(groups);

  /// Keep each profile/provider's valuation before grouping by model name.
  factory UsageModels.sum(Iterable<UsageModels> profiles) =>
      UsageModels._fromRows(profiles.expand((profile) => profile.rows));
  factory UsageModels.fromJson(
    Map<String, dynamic> data,
    ModelsDevPrices? prices,
  ) {
    if (data['models'] is! List) {
      throw const FormatException('Model usage is unavailable.');
    }
    final rows = <ModelUsageCost>[];
    for (final raw in data['models'] as List) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Invalid model usage.');
      }
      final row = ModelUsageCost.fromUsage(raw, prices);
      rows.add(row);
    }
    return UsageModels._fromRows(rows);
  }

  factory UsageModels._fromRows(Iterable<ModelUsageCost> source) {
    final rows = source.toList();
    final grouped = <String, List<ModelUsageCost>>{};
    for (final row in rows) {
      (grouped[row.model] ??= []).add(row);
    }
    final groups = [
      for (final entry in grouped.entries)
        UsageModelGroup(entry.key, entry.value),
    ]..sort((a, b) => a.id.compareTo(b.id));
    return UsageModels._(rows, groups);
  }

  UsageModels withPrices(ModelsDevPrices? prices) => costs.hasSubscription
      ? UsageModels._fromRows(rows.map((row) => row.withPrices(prices)))
      : this;
  UsageCostSummary get costs => UsageCostSummary(rows);
  UsageTokens get tokens =>
      UsageTokens.sum(rows.map((r) => UsageTokens.fromCost(r)));

  /// Reported provider totals cannot be split into token-type costs.
  List<double>? get tokenCosts {
    if (rows.isEmpty) return [0, 0, 0];
    if (rows.any((r) => !r.isApiEquivalent || r.amount == null)) return null;
    return [
      rows.fold(0, (sum, r) => sum + r.inputCost!),
      rows.fold(0, (sum, r) => sum + r.cachedInputCost!),
      rows.fold(0, (sum, r) => sum + r.outputCost!),
    ];
  }
}
