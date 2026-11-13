import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../theme/usage_selection_color.dart';
import '../../models/usage_analytics.dart';
import '../../theme/wing_theme.dart';

String compactUsage(num? value) {
  if (value == null) return 'Unavailable';
  for (final (size, suffix) in [
    (1e12, 'T'),
    (1e9, 'B'),
    (1e6, 'M'),
    (1e3, 'K'),
  ]) {
    if (value >= size) {
      return '${(value / size).toStringAsFixed(value / size >= 100 ? 0 : 1)}$suffix';
    }
  }
  return value.toStringAsFixed(0);
}

List<Color> usageColors(BuildContext context) {
  final tokens = WingTokens.of(context);
  final dark = tokens.brightness == Brightness.dark;
  return [
    tokens.accent,
    dark ? const Color(0xFF8BA9C2) : const Color(0xFF69819A),
    dark ? const Color(0xFFE9B96E) : const Color(0xFFA46C20),
    dark ? const Color(0xFF91ADF1) : const Color(0xFF526FAF),
    dark ? const Color(0xFFC997B8) : const Color(0xFF986783),
    dark ? const Color(0xFFAFC489) : const Color(0xFF71823E),
  ];
}

class UsageSegment {
  final String id;
  final String label;
  final double? value;
  final Color color;
  final bool partial;
  const UsageSegment({
    required this.id,
    required this.label,
    required this.value,
    required this.color,
    this.partial = false,
  });
}

Duration _motion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 300);

class UsageComposition extends StatelessWidget {
  final List<UsageSegment> segments;
  const UsageComposition({super.key, required this.segments});
  @override
  Widget build(BuildContext context) {
    final total = segments.fold<double>(0, (sum, s) => sum + (s.value ?? 0));
    return LayoutBuilder(
      builder: (context, constraints) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 16,
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(color: WingTokens.of(context).border),
              ),
              for (var i = 0; i < segments.length; i++)
                AnimatedPositioned(
                  key: ValueKey(segments[i].id),
                  duration: _motion(context),
                  curve: Curves.easeInOutCubic,
                  left: total == 0
                      ? 0
                      : constraints.maxWidth *
                            segments
                                .take(i)
                                .fold<double>(
                                  0,
                                  (sum, s) => sum + (s.value ?? 0),
                                ) /
                            total,
                  width: total == 0
                      ? 0
                      : constraints.maxWidth * (segments[i].value ?? 0) / total,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: segments[i].color),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class UsageCalendar extends StatefulWidget {
  final UsageDaily daily;
  final Set<String> periodDates;
  final String? selected;
  final ValueChanged<UsageDay> onSelected;
  const UsageCalendar({
    super.key,
    required this.daily,
    required this.periodDates,
    required this.selected,
    required this.onSelected,
  });
  @override
  State<UsageCalendar> createState() => _UsageCalendarState();
}

class _UsageCalendarState extends State<UsageCalendar> {
  final _scroll = ScrollController();
  Color? _accent, _canvas;
  late Color _outline;

  @override
  void didUpdateWidget(UsageCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.daily.days.firstOrNull?.date !=
            widget.daily.days.firstOrNull?.date ||
        oldWidget.daily.days.lastOrNull?.date !=
            widget.daily.days.lastOrNull?.date) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
      Tooltip.dismissAllToolTips();
    }
    if (!setEquals(oldWidget.periodDates, widget.periodDates)) {
      Tooltip.dismissAllToolTips();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final canvas = Theme.of(context).scaffoldBackgroundColor;
    if (_accent != tokens.accent || _canvas != canvas) {
      _accent = tokens.accent;
      _canvas = canvas;
      _outline = usageSelectionColor(tokens.accent, canvas);
    }
    return LayoutBuilder(
      builder: (context, constraints) =>
          _calendar(context, constraints.maxWidth),
    );
  }

  Widget _calendar(BuildContext context, double width) {
    final year = widget.daily.calendarDays;
    if (year.isEmpty) {
      return const Text('No recorded daily usage in the past year.');
    }
    // A newer/retained period can extend past the separately loaded year's
    // dates. Keep those dates reachable without presenting period counts as
    // year-wide counts or clipping them to the year snapshot.
    final period = [
      for (final id in widget.periodDates) DateTime.parse('${id}T00:00:00Z'),
    ]..sort();
    final bounds = [year.first.date, year.last.date, ...period]..sort();
    final yearById = {for (final day in year) day.id: day};
    final days = [
      for (
        var date = bounds.first;
        !date.isAfter(bounds.last);
        date = date.add(const Duration(days: 1))
      )
        yearById[date.toIso8601String().substring(0, 10)] ??
            UsageDay(
              date,
              const UsageTokens.unavailable(),
              isPlaceholder: true,
            ),
    ];
    const gap = 3.0, inset = 3.0;
    final offset = days.first.date.weekday % 7;
    final weeks = ((days.length + offset) / 7).ceil();
    // A single band of compact week columns fills the available width.
    final columns = usageCalendarColumns(width);
    final pitch = (width - inset * 2 + gap) / columns;
    final square = pitch - gap;
    final maximum = days.fold<int>(
      0,
      (m, d) => math.max(m, d.tokens.total ?? 0),
    );
    final tokens = WingTokens.of(context);
    final locale = MaterialLocalizations.of(context);
    // Surround the whole returned date span, including days with no usage.
    bool inRange(UsageDay day) =>
        period.isNotEmpty &&
        !day.date.isBefore(period.first) &&
        !day.date.isAfter(period.last);

    Widget cell(UsageDay day) {
      final count = day.tokens.total;
      final selected = day.id == widget.selected;
      final color = day.isPlaceholder
          ? tokens.border.withValues(alpha: .15)
          : count == null
          ? tokens.raised
          : count == 0
          ? tokens.border.withValues(alpha: .45)
          : Color.lerp(
              tokens.raised,
              tokens.accent,
              .25 + .75 * math.sqrt(count / math.max(maximum, 1)),
            )!;
      return Semantics(
        key: ValueKey(day.id),
        label:
            '${locale.formatFullDate(day.date)}, server date: ${day.isPlaceholder
                ? 'no returned year data'
                : count == null
                ? 'tokens unavailable'
                : '${locale.formatDecimal(count)} tokens'}${inRange(day) ? ', in selected period' : ''}',
        button: !day.isPlaceholder,
        selected: selected,
        child: Tooltip(
          message:
              '${locale.formatShortDate(day.date)} · Server date\n${day.isPlaceholder
                  ? 'No returned year data'
                  : count == null
                  ? 'Tokens unavailable'
                  : '${compactUsage(count)} tokens'}',
          excludeFromSemantics: true,
          triggerMode: TooltipTriggerMode.manual,
          preferBelow: false,
          verticalOffset: 10,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          child: Builder(
            builder: (tooltipContext) => Material(
              color: Colors.transparent,
              child: StudioButtonPress(
                child: InkWell(
                  key: ValueKey('usage-day-${day.id}'),
                  borderRadius: BorderRadius.circular(2),
                  onTap: () {
                    Tooltip.dismissAllToolTips();
                    tooltipContext
                        .findAncestorStateOfType<TooltipState>()!
                        .ensureTooltipVisible();
                    if (!day.isPlaceholder) widget.onSelected(day);
                  },
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: AnimatedContainer(
                      duration: _motion(context),
                      width: square,
                      height: square,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(2),
                        border: selected
                            ? Border.all(color: tokens.onSurface, width: 1.5)
                            : null,
                      ),
                      child: count == null && !day.isPlaceholder
                          ? Icon(
                              Icons.question_mark,
                              size: math.min(square, 9),
                              color: tokens.muted,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget band() {
      final contentWidth = weeks * pitch - gap + inset * 2;
      final selectedCells = <int>{};
      for (var i = 0; i < days.length; i++) {
        if (inRange(days[i])) selectedCells.add(i + offset);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedBuilder(
            animation: _scroll,
            builder: (context, _) {
              // Reverse scrolling anchors the latest week at offset zero. Only
              // rebuild this label while dragging; the year and its outline move
              // together in the scroll view without rebuilding every day.
              final pixels = _scroll.hasClients ? _scroll.offset : 0.0;
              final left = (contentWidth - width - pixels).clamp(
                0.0,
                math.max(0.0, contentWidth - width),
              );
              final firstWeek = ((left - inset + gap) / pitch + 1e-9)
                  .floor()
                  .clamp(0, weeks - 1);
              final endWeek = ((left + width - inset) / pitch - 1e-9)
                  .ceil()
                  .clamp(firstWeek + 1, weeks);
              final first = math.max(0, firstWeek * 7 - offset);
              final end = math.min(days.length, endWeek * 7 - offset);
              return SizedBox(
                height: usageCalendarDateHeight(context, width),
                child: Text(
                  '${locale.formatShortDate(days[first].date)} – ${locale.formatShortDate(days[end - 1].date)}',
                  key: const ValueKey('usage-visible-dates'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          SizedBox(
            key: const ValueKey('usage-year-band'),
            height: 7 * pitch - gap + inset * 2,
            child: NotificationListener<ScrollStartNotification>(
              onNotification: (_) {
                Tooltip.dismissAllToolTips();
                return false;
              },
              child: SingleChildScrollView(
                key: const ValueKey('usage-calendar-scroll'),
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: SizedBox(
                  width: contentWidth,
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(inset),
                        child: Column(
                          children: [
                            for (var row = 0; row < 7; row++)
                              SizedBox(
                                height: row == 6 ? square : pitch,
                                child: Row(
                                  children: [
                                    for (var col = 0; col < weeks; col++)
                                      SizedBox(
                                        width: col == weeks - 1
                                            ? square
                                            : pitch,
                                        child:
                                            col * 7 + row - offset >= 0 &&
                                                col * 7 + row - offset <
                                                    days.length
                                            ? cell(days[col * 7 + row - offset])
                                            : null,
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedSwitcher(
                            duration: _motion(context),
                            child: CustomPaint(
                              key: ValueKey(
                                (widget.periodDates.toList()..sort()).join('/'),
                              ),
                              size: Size.infinite,
                              painter: _UsageRangePainter(
                                selectedCells,
                                weeks,
                                pitch,
                                inset,
                                _outline,
                                _canvas!,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      key: const ValueKey('usage-activity-grid'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        band(),
        const SizedBox(height: 8),
        const UsageCalendarLegend(),
      ],
    );
  }
}

// The year always reserves a band of up to 52 visible week columns.
// Shared geometry also sizes the dashboard's loading/empty/error calendar.
int usageCalendarColumns(double width) =>
    math.min(52, math.max(1, ((width - 3) / 15).floor()));

double usageCalendarDateHeight(BuildContext context, double width) {
  final locale = MaterialLocalizations.of(context);
  final sample = locale.formatShortDate(DateTime(2000, 9, 30));
  final painter = TextPainter(
    text: TextSpan(
      text: '$sample – $sample',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: width);
  final height = painter.height;
  painter.dispose();
  return height;
}

class UsageCalendarLegend extends StatelessWidget {
  const UsageCalendarLegend({super.key});
  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(
          'Year view · Server dates',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Less', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(width: 6),
            for (var i = 0; i < 5; i++)
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(
                  color: Color.lerp(
                    tokens.border.withValues(alpha: .45),
                    tokens.accent,
                    i / 4,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 3),
            Text('More', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ],
    );
  }
}

/// Trace only external edges, so adjacent selected dates share one perimeter.
class _UsageRangePainter extends CustomPainter {
  final Set<int> cells;
  final int columns;
  final double pitch, inset;
  final Color outline, canvasColor;
  const _UsageRangePainter(
    this.cells,
    this.columns,
    this.pitch,
    this.inset,
    this.outline,
    this.canvasColor,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    void edge(double x1, double y1, double x2, double y2) {
      path.moveTo(inset - 1.5 + x1 * pitch, inset - 1.5 + y1 * pitch);
      path.lineTo(inset - 1.5 + x2 * pitch, inset - 1.5 + y2 * pitch);
    }

    for (final cell in cells) {
      final col = cell ~/ 7, row = cell % 7;
      final x = col.toDouble(), y = row.toDouble();
      if (col == 0 || !cells.contains(cell - 7)) edge(x, y, x, y + 1);
      if (col == columns - 1 || !cells.contains(cell + 7)) {
        edge(x + 1, y, x + 1, y + 1);
      }
      if (row == 0 || !cells.contains(cell - 1)) edge(x, y, x + 1, y);
      if (row == 6 || !cells.contains(cell + 1)) edge(x, y + 1, x + 1, y + 1);
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      path,
      paint
        ..color = canvasColor
        ..strokeWidth = 3,
    );
    canvas.drawPath(
      path,
      paint
        ..color = outline
        ..strokeWidth = 1.75,
    );
  }

  @override
  bool shouldRepaint(_UsageRangePainter old) =>
      old.pitch != pitch ||
      old.outline != outline ||
      old.canvasColor != canvasColor ||
      old.columns != columns ||
      !setEquals(old.cells, cells);
}

class UsageAreaChart extends StatelessWidget {
  final UsageDaily daily;
  final String? selected;
  const UsageAreaChart({
    super.key,
    required this.daily,
    required this.selected,
  });
  @override
  Widget build(BuildContext context) {
    final days = daily.days;
    final maximum = days.fold<int>(
      0,
      (m, d) => math.max(m, d.tokens.total ?? 0),
    );
    final locale = MaterialLocalizations.of(context);
    final colors = usageColors(context).take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${compactUsage(maximum)} tokens / day',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Semantics(
          label:
              'Stacked daily token chart. Uncached input, cached input and output. Select a date in the usage grid for exact values.',
          image: true,
          child: SizedBox(
            height: 160,
            child: CustomPaint(
              painter: _AreaPainter(
                days,
                selected,
                colors,
                WingTokens.of(context),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          children: [
            Text(
              locale.formatShortMonthDay(days.first.date),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (days.length > 1)
              Text(
                locale.formatShortMonthDay(days.last.date),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (var i = 0; i < 3; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: colors[i],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      usageTokenLabels[i],
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _AreaPainter extends CustomPainter {
  final List<UsageDay> days;
  final String? selected;
  final List<Color> colors;
  final WingTokens tokens;
  _AreaPainter(this.days, this.selected, this.colors, this.tokens);
  @override
  void paint(Canvas canvas, Size size) {
    final maximum = math.max(
      1,
      days.fold<int>(0, (m, d) => math.max(m, d.tokens.total ?? 0)),
    );
    final grid = Paint()
      ..color = tokens.border.withValues(alpha: .6)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    double x(int i) => size.width * i / math.max(1, days.length - 1);
    double y(int i, int count) =>
        size.height *
        (1 -
            days[i].tokens.values
                    .take(count)
                    .fold<int>(0, (sum, n) => sum + n!) /
                maximum);
    for (var type = 0; type < 3; type++) {
      if (days.length == 1) {
        canvas.drawRect(
          Rect.fromLTRB(0, y(0, type + 1), size.width, y(0, type)),
          Paint()..color = colors[type].withValues(alpha: .82),
        );
        continue;
      }
      final path = Path()..moveTo(x(0), y(0, type));
      for (var i = 0; i < days.length; i++) {
        path.lineTo(x(i), y(i, type + 1));
      }
      for (var i = days.length - 1; i >= 0; i--) {
        path.lineTo(x(i), y(i, type));
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = colors[type].withValues(alpha: .82),
      );
    }
    final index = days.indexWhere((day) => day.id == selected);
    if (index >= 0) {
      canvas.drawLine(
        Offset(x(index), 0),
        Offset(x(index), size.height),
        Paint()
          ..color = tokens.onSurface
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_AreaPainter oldDelegate) => true;
}
