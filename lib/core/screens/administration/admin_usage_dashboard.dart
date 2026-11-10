import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/studio_loading.dart';
import '../../models/usage_analytics.dart';
import '../../models/usage_cost.dart';
import '../../services/usage_analytics_session.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/read_recovery.dart';
import 'usage_charts.dart';

class UsageDashboard extends StatefulWidget {
  final UsageAnalyticsSession Function() createSession;
  const UsageDashboard({super.key, required this.createSession});
  @override
  State<UsageDashboard> createState() => _UsageDashboardState();
}

class _UsageDashboardState extends State<UsageDashboard> {
  late final UsageAnalyticsSession _session;
  final _modelColors = <String, int>{};
  String? _selected;
  bool _breakdownModels = true;
  bool _breakdownCost = false;
  bool _trendModels = false;
  bool _trendCost = false;
  bool _refreshing = false;
  bool _opening = true;
  Object? _periodWait;
  int get _days => _session.state.days;

  @override
  void initState() {
    super.initState();
    _session = widget.createSession();
    final cached = _session.state;
    _opening =
        cached.data?.models == null &&
        cached.data?.daily == null &&
        cached.year == null;
    _session.addListener(_changed);
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    try {
      await _session.load();
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _session.dispose();
    super.dispose();
  }

  Future<void> _period(int days) async {
    final wait = Object();
    setState(() {
      _periodWait = wait;
      _selected = null;
      Tooltip.dismissAllToolTips();
    });
    try {
      await _session.selectPeriod(days);
    } finally {
      if (mounted && identical(_periodWait, wait)) {
        setState(() => _periodWait = null);
      }
    }
  }

  Future<void> _refreshUsage() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await _session.refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _number(num? value) => value == null
      ? 'Unavailable'
      : MaterialLocalizations.of(context).formatDecimal(value.toInt());
  String _value(double? value, bool cost) =>
      cost ? formatUsageUsd(value) : compactUsage(value);
  Widget _quiet(String text) =>
      Text(text, style: Theme.of(context).textTheme.bodySmall);

  @override
  Widget build(BuildContext context) => ReadRecovery(
    shouldRetry: () => _session.state.needsRecovery,
    retry: _session.recover,
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final observation = _session.state;
    final data = observation.data;
    final models = data?.models;
    final daily = data?.daily;
    final modelsError = data?.modelsError;
    final dailyError = data?.dailyError;
    final summary = models?.costs;
    final updatedAt = observation.updatedAt?.toLocal();
    final selected = observation.year?.days
        .where((d) => d.id == _selected)
        .firstOrNull;
    final showBreakdown = models != null || selected != null;
    final showTrend = daily != null || _trendModels || _trendCost;
    final costTitle = summary?.isMixed == true
        ? 'Estimated usage value'
        : summary?.hasSubscription == true
        ? 'API-equivalent cost'
        : 'Estimated cost';
    return StudioPageLoading(
      active: _opening || _refreshing || _periodWait != null,
      label: _opening || _periodWait != null || data == null
          ? 'Loading usage'
          : 'Refreshing usage',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final days in usagePeriods)
                _Choice(
                  key: ValueKey('usage-period-$days'),
                  label: '${days}D',
                  selected: _days == days,
                  neutral: true,
                  onPressed: () => _period(days),
                ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final stats = [
                _Stat(
                  key: const ValueKey('usage-token-total'),
                  label: 'Tokens',
                  pending: models == null && observation.periodLoading,
                  value: models == null || models.rows.isEmpty
                      ? models == null
                            ? 'Unavailable'
                            : '0'
                      : compactUsage(models.tokens.total),
                  detail:
                      models?.tokens.total == null &&
                          models != null &&
                          models.rows.isNotEmpty
                      ? 'Some counts unavailable'
                      : 'Across models',
                  exact: _number(models?.tokens.total),
                ),
                _Stat(
                  key: const ValueKey('usage-cost-total'),
                  label: costTitle,
                  pending:
                      models == null && observation.periodLoading ||
                      data?.pricingLoading == true &&
                          models?.rows.any(
                                (row) =>
                                    row.unavailable ==
                                    UsageCostUnavailable.price,
                              ) ==
                              true,
                  value: models?.rows.isEmpty == true
                      ? 'USD 0.00'
                      : formatUsageUsd(summary?.total),
                  detail: summary?.isPartial == true
                      ? 'Partial total'
                      : summary?.hasSubscription == true
                      ? 'Not a bill'
                      : 'Hermes estimate',
                ),
              ];
              if (MediaQuery.textScalerOf(context).scale(16) > 24 ||
                  constraints.maxWidth < 300) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [stats[0], const SizedBox(height: 12), stats[1]],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: stats[0]),
                  const SizedBox(width: 16),
                  Expanded(child: stats[1]),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              Text(
                'Usage by day',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              _quiet('${_days}D selected'),
            ],
          ),
          const SizedBox(height: 8),
          _UsageCalendarSlot(
            daily: observation.year,
            pending: observation.yearLoading,
            error: observation.yearError,
            periodDates: daily?.reportedDates ?? const {},
            selected: _selected,
            onSelected: (day) =>
                setState(() => _selected = _selected == day.id ? null : day.id),
          ),
          if (observation.year != null && observation.yearError != null)
            Padding(
              key: const ValueKey('usage-retained-year-error'),
              padding: const EdgeInsets.only(top: 8),
              child: StudioError(observation.yearError!),
            ),
          const SizedBox(height: 20),
          _ChartHeader(
            section: 'Breakdown',
            models: _breakdownModels,
            cost: _breakdownCost,
            onGroup: () => setState(() => _breakdownModels = !_breakdownModels),
            onCost: (v) => setState(() => _breakdownCost = v),
          ),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              _quiet(
                selected == null
                    ? 'Last $_days ${_days == 1 ? 'day' : 'days'} · all models'
                    : MaterialLocalizations.of(
                        context,
                      ).formatFullDate(selected.date),
              ),
              if (selected != null)
                StudioButtonPress(
                  child: TextButton(
                    onPressed: () => setState(() => _selected = null),
                    child: const Text('Selected period'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _UsageChartSlot(
            identity: 'breakdown',
            height: _breakdownHeight(context),
            pending: models == null && observation.periodLoading,
            child: modelsError != null && !showBreakdown
                ? _periodReadError(modelsError)
                : _breakdown(models, selected),
          ),
          if (modelsError != null && showBreakdown)
            Padding(
              key: const ValueKey('usage-retained-models-error'),
              padding: const EdgeInsets.only(top: 8),
              child: _periodReadError(
                modelsError,
                retainedAt: models == null ? null : data?.loadedAt,
              ),
            ),
          const SizedBox(height: 24),
          _ChartHeader(
            section: 'Trend',
            models: _trendModels,
            cost: _trendCost,
            onGroup: () => setState(() => _trendModels = !_trendModels),
            onCost: (v) => setState(() => _trendCost = v),
          ),
          const SizedBox(height: 8),
          _UsageChartSlot(
            identity: 'trend',
            height: _trendHeight(context),
            pending: daily == null && observation.periodLoading,
            child: dailyError != null && !showTrend
                ? _periodReadError(dailyError)
                : _trend(daily),
          ),
          if (dailyError != null && showTrend)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _periodReadError(
                dailyError,
                retainedAt: daily == null ? null : data?.loadedAt,
              ),
            ),
          const SizedBox(height: 20),
          _about(models),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: updatedAt == null
                    ? const SizedBox.shrink()
                    : _quiet(
                        'Updated ${MaterialLocalizations.of(context).formatShortDate(updatedAt)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(updatedAt))}',
                      ),
              ),
              StudioButtonPress(
                child: IconButton(
                  tooltip: 'Refresh usage',
                  onPressed: _opening || _refreshing ? null : _refreshUsage,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _periodReadError(
    String message, {
    DateTime? retainedAt,
  }) => StudioError(
    message,
    detail: retainedAt == null
        ? 'Use Refresh to retry.'
        : 'Showing retained data where available. Last successful load ${TimeOfDay.fromDateTime(retainedAt.toLocal()).format(context)}. Use Refresh to retry.',
  );

  Widget _breakdown(UsageModels? models, UsageDay? selected) {
    if (selected != null && (_breakdownModels || _breakdownCost)) {
      return _Unavailable(
        message: _breakdownCost
            ? 'Daily API-equivalent costs need model counts that Hermes does not provide by day.'
            : 'Hermes does not provide a model breakdown by day.',
        action: 'Show daily tokens',
        onPressed: () => setState(() {
          _breakdownModels = false;
          _breakdownCost = false;
        }),
      );
    }
    if (selected == null && models == null) {
      return const Text('Period breakdown unavailable.');
    }
    if (selected == null && models!.rows.isEmpty) {
      return const Text('No recorded model usage in this period.');
    }
    final colors = usageColors(context);
    final segments = <UsageSegment>[];
    if (_breakdownModels) {
      // Assign colours before sorting so each model keeps its identity.
      for (final group in models!.groups) {
        segments.add(
          UsageSegment(
            id: group.id,
            label: group.model,
            value: _breakdownCost
                ? group.costs.total
                : group.tokens.total?.toDouble(),
            color:
                colors[_modelColors.putIfAbsent(
                      group.id,
                      () => _modelColors.length,
                    ) %
                    colors.length],
            partial: _breakdownCost && group.costs.isPartial,
          ),
        );
      }
    } else {
      final tokens = selected?.tokens ?? models!.tokens;
      final costs = models?.tokenCosts;
      if (_breakdownCost && costs == null) {
        return const _Unavailable(
          message:
              'Cost per token type is available only when every model has a complete subscription API estimate. Hermes reports other costs as one combined amount.',
        );
      }
      for (var i = 0; i < 3; i++) {
        segments.add(
          UsageSegment(
            id: usageTokenKeys[i],
            label: usageTokenLabels[i],
            value: _breakdownCost ? costs![i] : tokens.values[i]?.toDouble(),
            color: colors[i],
          ),
        );
      }
    }
    // Rank by the selected measure; unknown amounts follow all known values.
    // Stable IDs break ties and keep the animated bar's segment identities.
    segments.sort((a, b) {
      if (a.value == null && b.value == null) return a.id.compareTo(b.id);
      if (a.value == null) return 1;
      if (b.value == null) return -1;
      final amount = b.value!.compareTo(a.value!);
      return amount != 0 ? amount : a.id.compareTo(b.id);
    });
    final partial = segments.any((s) => s.value == null || s.partial);
    final noValues = segments.every((s) => s.value == null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!noValues) UsageComposition(segments: segments),
        if (partial)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _quiet(
              'Partial breakdown · unavailable values are excluded from the bar.',
            ),
          ),
        const SizedBox(height: 8),
        for (final segment in segments)
          Semantics(
            label:
                '${segment.label}: ${_breakdownCost ? formatUsageUsd(segment.value) : '${_number(segment.value)} tokens'}${segment.partial ? ', partial' : ''}',
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: segment.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: MediaQuery.textScalerOf(context).scale(16) > 24
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                segment.label,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              Text(
                                '${_value(segment.value, _breakdownCost)}${segment.partial ? ' · partial' : ''}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  segment.label,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  '${_value(segment.value, _breakdownCost)}${segment.partial ? ' · partial' : ''}',
                                  textAlign: TextAlign.end,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _trend(UsageDaily? daily) {
    if (_trendModels || _trendCost) {
      return _Unavailable(
        message: _trendCost
            ? 'Daily API-equivalent costs are unavailable: daily totals do not identify models.'
            : 'Hermes provides daily tokens by type, but no daily model history.',
        action: 'Show token trend',
        onPressed: () => setState(() {
          _trendModels = false;
          _trendCost = false;
        }),
      );
    }
    if (daily == null) {
      return const Text('Daily usage unavailable.');
    }
    if (daily.days.any((d) => !d.tokens.complete)) {
      return const Text(
        'Some daily token counts are unavailable. Select a date in the grid to inspect its recorded counts.',
      );
    }
    if (daily.days.every((d) => d.tokens.total == 0)) {
      return const Text('No recorded daily tokens in this period.');
    }
    return UsageAreaChart(daily: daily, selected: _selected);
  }

  Widget _about(UsageModels? models) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('About this usage'),
    childrenPadding: const EdgeInsets.only(bottom: 12),
    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _quiet(
        'Daily charts use Hermes’ server-local session-start dates, not the date of each request. Hermes does not report its timezone or the calendar boundaries of the rolling period. The first and last returned date can be partial days.',
      ),
      const SizedBox(height: 8),
      _quiet(
        'Scroll to browse a year ending at the latest returned date. Blank cells outside the year’s recorded date span have no returned year data. The outline marks dates returned for the selected period, not its calendar boundaries. Day tooltips and breakdowns use the year-wide daily counts; the trend and period totals use the selected rolling window.',
      ),
      const SizedBox(height: 8),
      _quiet(
        'Period model totals also include background usage. Daily charts exclude it, so the totals may differ. Output already includes reasoning tokens.',
      ),
      const SizedBox(height: 8),
      _quiet(
        models?.costs.hasSubscription == true
            ? 'Subscription usage uses models.dev OpenAI API rates shared with the model picker, not billed spend. Estimates exclude cache-write charges and long-context or service-tier adjustments.'
            : 'Costs are Hermes estimates, not provider invoices.',
      ),
      if (models?.costs.isMixed == true) ...[
        const SizedBox(height: 8),
        _quiet(
          'Hermes estimates: ${formatUsageUsd(models!.costs.reported)} · Subscription API equivalent: ${formatUsageUsd(models.costs.apiEquivalent)}',
        ),
      ],
    ],
  );
}

class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final bool neutral;
  final VoidCallback onPressed;
  const _Choice({
    required super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.neutral = false,
  });
  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    return Semantics(
      selected: selected,
      child: StudioButtonPress(
        child: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            foregroundColor: neutral ? tokens.onSurface : null,
            backgroundColor: selected
                ? neutral
                      ? tokens.border.withValues(alpha: .35)
                      : Theme.of(context).colorScheme.primaryContainer
                : Colors.transparent,
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
      ),
    );
  }
}

class _ChartHeader extends StatelessWidget {
  final String section;
  final bool models;
  final bool cost;
  final VoidCallback onGroup;
  final ValueChanged<bool> onCost;
  const _ChartHeader({
    required this.section,
    required this.models,
    required this.cost,
    required this.onGroup,
    required this.onCost,
  });
  @override
  Widget build(BuildContext context) {
    final title = Row(
      children: [
        StudioButtonPress(
          child: IconButton(
            key: ValueKey('usage-${section.toLowerCase()}-group'),
            tooltip:
                'Group ${section.toLowerCase()} by ${models ? 'token type' : 'model'}',
            onPressed: onGroup,
            icon: const Icon(Icons.swap_horiz, size: 18),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$section per ${models ? 'model' : 'token type'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ],
    );
    final choices = Wrap(
      alignment: WrapAlignment.end,
      children: [
        _Choice(
          key: ValueKey('usage-${section.toLowerCase()}-tokens'),
          label: 'Tokens',
          selected: !cost,
          onPressed: () => onCost(false),
        ),
        _Choice(
          key: ValueKey('usage-${section.toLowerCase()}-cost'),
          label: 'Cost',
          selected: cost,
          onPressed: () => onCost(true),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 350 ||
            MediaQuery.textScalerOf(context).scale(16) > 20) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              Align(alignment: Alignment.centerRight, child: choices),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            const SizedBox(width: 8),
            choices,
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String detail;
  final String? exact;
  final bool pending;
  const _Stat({
    super.key,
    required this.label,
    required this.pending,
    required this.value,
    required this.detail,
    this.exact,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context).textTheme;
      Widget line(
        String text,
        TextStyle style,
        List<String> samples, {
        bool placeholder = false,
      }) {
        final height = samples
            .map(
              (sample) => _usageTextHeight(
                context,
                sample,
                style,
                constraints.maxWidth,
              ),
            )
            .reduce(math.max);
        return SizedBox(
          height: height,
          width: double.infinity,
          child: pending && placeholder
              ? _UsageSkeleton(height: height, fraction: .65)
              : Text(text, style: style),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cost provenance can arrive later than counts. Reserve the longest
          // supported label/detail at this width and text scale from frame one.
          line(label, theme.bodySmall!, const [
            'Tokens',
            'Estimated usage value',
            'API-equivalent cost',
          ]),
          const SizedBox(height: 4),
          SizedBox(
            height: _usageTextHeight(
              context,
              '0',
              theme.headlineSmall!,
              double.infinity,
            ),
            width: double.infinity,
            child: pending
                ? const _UsageSkeleton(height: double.infinity, fraction: .8)
                : Tooltip(
                    message: exact ?? value,
                    child: Text(
                      value,
                      style: theme.headlineSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ),
          const SizedBox(height: 4),
          line(detail, theme.bodySmall!, const [
            'Some counts unavailable',
            'Across models',
            'Hermes estimate',
          ], placeholder: true),
        ],
      );
    },
  );
}

// Section frames depend on viewport/text geometry, never network completion.
// Unknown model counts scroll inside the reserved breakdown frame.
double _usageTextHeight(
  BuildContext context,
  String text,
  TextStyle style,
  double width,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: width);
  final height = painter.height;
  painter.dispose();
  return height;
}

double _breakdownHeight(BuildContext context) =>
    24 +
    3 *
        math.max(
          48,
          16 +
              (MediaQuery.textScalerOf(context).scale(16) > 24 ? 2 : 1) *
                  _usageTextHeight(
                    context,
                    'Model',
                    Theme.of(context).textTheme.bodyMedium!,
                    double.infinity,
                  ),
        );

double _trendHeight(BuildContext context) =>
    160 +
    26 +
    5 *
        _usageTextHeight(
          context,
          'Tokens',
          Theme.of(context).textTheme.bodySmall!,
          double.infinity,
        );

class _UsageChartSlot extends StatefulWidget {
  const _UsageChartSlot({
    required this.identity,
    required this.height,
    required this.pending,
    required this.child,
  });
  final String identity;
  final double height;
  final bool pending;
  final Widget child;
  @override
  State<_UsageChartSlot> createState() => _UsageChartSlotState();
}

class _UsageChartSlotState extends State<_UsageChartSlot> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: ValueKey('usage-${widget.identity}-slot'),
    height: widget.height,
    child: widget.pending
        ? ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _UsageSkeleton(height: 16, fraction: 1),
                const SizedBox(height: 12),
                if (widget.identity == 'breakdown')
                  for (var i = 0; i < 3; i++)
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _UsageSkeleton(
                          height: 14,
                          fraction: .8 - i * .15,
                        ),
                      ),
                    )
                else
                  const Expanded(
                    child: _UsageSkeleton(height: double.infinity, fraction: 1),
                  ),
              ],
            ),
          )
        : Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              primary: false,
              child: widget.child,
            ),
          ),
  );
}

class _UsageSkeleton extends StatelessWidget {
  const _UsageSkeleton({required this.height, required this.fraction});
  final double height, fraction;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: WingTokens.of(context).border.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    ),
  );
}

class _UsageCalendarSlot extends StatelessWidget {
  const _UsageCalendarSlot({
    required this.daily,
    required this.pending,
    required this.error,
    required this.periodDates,
    required this.selected,
    required this.onSelected,
  });
  final UsageDaily? daily;
  final bool pending;
  final String? error;
  final Set<String> periodDates;
  final String? selected;
  final ValueChanged<UsageDay> onSelected;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = usageCalendarColumns(width);
      final pitch = (width - 3) / columns;
      final textHeight = usageCalendarDateHeight(context, width);
      // The calendar footer can wrap at enlarged text; use its real legend
      // layout to reserve the same space in every state.
      return Column(
        key: const ValueKey('usage-calendar-slot'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (daily?.days.isNotEmpty == true)
            UsageCalendar(
              daily: daily!,
              periodDates: periodDates,
              selected: selected,
              onSelected: onSelected,
            )
          else if (!pending && error != null && daily == null)
            StudioError(error!)
          else ...[
            SizedBox(
              height: textHeight,
              child: pending
                  ? _UsageSkeleton(height: textHeight * .65, fraction: .7)
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 7 * pitch + 3,
              child: pending
                  ? ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Column(
                          children: [
                            for (var row = 0; row < 7; row++)
                              SizedBox(
                                height: row == 6 ? pitch - 3 : pitch,
                                child: Row(
                                  children: [
                                    for (var col = 0; col < columns; col++)
                                      SizedBox(
                                        width: col == columns - 1
                                            ? pitch - 3
                                            : pitch,
                                        child: Align(
                                          alignment: Alignment.topLeft,
                                          child: Container(
                                            width: pitch - 3,
                                            height: pitch - 3,
                                            decoration: BoxDecoration(
                                              color: WingTokens.of(
                                                context,
                                              ).border.withValues(alpha: .45),
                                              borderRadius:
                                                  BorderRadius.circular(2),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      primary: false,
                      child: Text(
                        daily == null
                            ? 'Activity year unavailable. Period totals may still be available.'
                            : 'No recorded daily usage in the past year.',
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            const UsageCalendarLegend(),
          ],
        ],
      );
    },
  );
}

class _Unavailable extends StatelessWidget {
  final String message;
  final String? action;
  final VoidCallback? onPressed;
  const _Unavailable({required this.message, this.action, this.onPressed});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: WingTokens.of(context).raised,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message, style: Theme.of(context).textTheme.bodySmall),
        if (action != null)
          Align(
            alignment: Alignment.centerLeft,
            child: StudioButtonPress(
              child: TextButton(onPressed: onPressed, child: Text(action!)),
            ),
          ),
      ],
    ),
  );
}
