/// One server-estimated component of the session's context window.
class ContextCategory {
  const ContextCategory({
    required this.id,
    required this.label,
    required this.tokens,
  });

  final String id;
  final String label;
  final int tokens;

  static ContextCategory? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final label = value['label'];
    final tokens = value['tokens'];
    if (id is! String ||
        id.trim().isEmpty ||
        label is! String ||
        label.trim().isEmpty ||
        tokens is! num ||
        !tokens.isFinite ||
        tokens < 0) {
      return null;
    }
    return ContextCategory(id: id, label: label, tokens: tokens.round());
  }
}

/// Server-reported occupancy and estimated composition for one session.
class ContextOccupancy {
  final int used;
  final int max;
  final double percent;
  final bool estimated;
  final int? configuredMax;
  bool get pinned => configuredMax != null && configuredMax == max;
  final List<ContextCategory> categories;

  ContextOccupancy({
    required this.used,
    required this.max,
    required this.percent,
    this.estimated = false,
    this.configuredMax,
    Iterable<ContextCategory> categories = const [],
  }) : categories = List.unmodifiable(categories);

  /// Composition is a separate server estimate, never a replacement for the
  /// latest reported occupancy.
  ContextOccupancy withCategories(Iterable<ContextCategory> categories) =>
      ContextOccupancy(
        used: used,
        max: max,
        percent: percent,
        estimated: estimated,
        configuredMax: configuredMax,
        categories: categories,
      );

  ContextOccupancy withoutCategories() => withCategories(const []);

  /// Parses only authoritative server values. Missing or unusable limits make
  /// occupancy unknown rather than encouraging a phone-owned estimate.
  static ContextOccupancy? fromJson(Map<String, dynamic>? value) {
    if (value == null) return null;
    final used = _finiteNum(value['context_used']);
    final max = _finiteNum(value['context_max']);
    final percent = _finiteNum(value['context_percent']);
    if (used == null ||
        max == null ||
        percent == null ||
        max <= 0 ||
        used < 0) {
      return null;
    }
    return ContextOccupancy(
      used: used.round(),
      max: max.round(),
      percent: percent.clamp(0, 100).toDouble(),
      estimated: value['context_estimated'] == true,
      configuredMax: switch (value['config_context_length']) {
        final int length when length > 0 => length,
        _ => null,
      },
      categories: value['categories'] is List
          ? (value['categories'] as List)
                .map(ContextCategory.fromJson)
                .whereType<ContextCategory>()
          : const [],
    );
  }

  static double? _finiteNum(Object? value) {
    if (value is! num || !value.isFinite) return null;
    return value.toDouble();
  }
}
