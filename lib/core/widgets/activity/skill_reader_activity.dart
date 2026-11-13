part of 'skill_document_viewer.dart';

String _skillDate(BuildContext context, DateTime date, {bool exact = false}) {
  final local = date.toLocal(), locale = MaterialLocalizations.of(context);
  return exact
      ? '${locale.formatMediumDate(local)}, ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(local))}'
      : locale.formatShortMonthDay(local);
}

class _SkillActivitySummary extends StatelessWidget {
  const _SkillActivitySummary({required this.observation});
  final SkillReaderObservation? observation;
  @override
  Widget build(BuildContext context) {
    final colors = WingTokens.of(context);
    final received = observation;
    final loading = received == null;
    final available =
        received != null &&
        (received.uses != null ||
            received.patches != null ||
            received.readRequests != null ||
            received.lastPatched != null);
    final date = received?.lastPatched;
    Widget metric(int? count, String label) => Semantics(
      container: true,
      label: '$label: ${loading ? 'loading' : count ?? 'unavailable'}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            alignment: Alignment.centerLeft,
            children: [
              // The real number's line box also owns the placeholder's height.
              Visibility(
                visible: !loading,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Text(
                  count?.toString() ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: colors.typography.title,
                ),
              ),
              if (loading)
                Container(
                  width: MediaQuery.textScalerOf(context).scale(40),
                  height: MediaQuery.textScalerOf(context).scale(18),
                  decoration: BoxDecoration(
                    color: colors.border,
                    borderRadius: WingRadius.control,
                  ),
                ),
            ],
          ),
          Text(
            label,
            style: colors.typography.label.copyWith(color: colors.muted),
          ),
        ],
      ),
    );
    final status = loading
        ? 'Loading activity…'
        : !available
        ? 'Activity unavailable'
        : date != null
        ? 'Last change ${_skillDate(context, date)}'
        : '';
    return _SkillSurface(
      child: Material(
        color: Colors.transparent,
        child: StudioButtonPress(
          child: InkWell(
            onTap: available
                ? () => showDialog<void>(
                    context: context,
                    builder: (_) => _SkillActivityDialog(observation: received),
                  )
                : null,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.insights_outlined,
                        size: 16,
                        color: colors.muted,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text('Activity', style: colors.typography.label),
                      ),
                      Visibility(
                        visible: available,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: metric(received?.uses, 'recorded uses')),
                      Expanded(
                        child: metric(received?.patches, 'patches / edits'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Keep the date/status line even when no date was supplied.
                  // Loading, confirmed zero and unavailable data share geometry.
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (date != null) ...[
                          Icon(Icons.schedule, size: 12, color: colors.muted),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(
                            status.isEmpty ? '\u00a0' : status,
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: colors.typography.label.copyWith(
                              color: colors.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SkillActivityDialog extends StatefulWidget {
  const _SkillActivityDialog({required this.observation});
  final SkillReaderObservation observation;
  @override
  State<_SkillActivityDialog> createState() => _SkillActivityDialogState();
}

class _SkillActivityDialogState extends State<_SkillActivityDialog> {
  bool _requests = false;
  @override
  Widget build(BuildContext context) {
    final observation = widget.observation, colors = WingTokens.of(context);
    final profiles = observation.activity
        .where(
          (p) =>
              p.uses != null ||
              p.patches != null ||
              p.readRequests != null ||
              p.lastPatched != null,
        )
        .toList();
    final palette = <Color>[
      colors.accent,
      const Color(0xff8bb8e8),
      const Color(0xffc5a3e5),
      const Color(0xffe7b66e),
      const Color(0xffe294a3),
      const Color(0xff83c79a),
      const Color(0xffb1b9c8),
    ];
    Color colour(SkillProfileActivity profile) =>
        palette[profiles.indexOf(profile) % palette.length];
    Widget chart(String label, int? Function(SkillProfileActivity) value) =>
        _SkillDonut(
          label: label,
          values: [
            for (final p in profiles)
              if (value(p) case final count?)
                (name: p.profile, count: count, color: colour(p)),
          ],
        );
    return Dialog(
      backgroundColor: colors.raised,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: WingRadius.card,
        side: BorderSide(color: colors.border),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 440,
          maxHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Activity', style: colors.typography.section),
                  ),
                  ActivityDetailAction(
                    label: 'Close activity',
                    icon: Icons.close,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const _SkillRule(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LayoutBuilder(
                      builder: (context, box) {
                        final charts = [
                          if (observation.uses != null)
                            chart('Uses', (p) => p.uses),
                          if (observation.patches != null)
                            chart('Patches / edits', (p) => p.patches),
                        ];
                        return box.maxWidth >=
                                MediaQuery.textScalerOf(context).scale(304)
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final c in charts) Expanded(child: c),
                                ],
                              )
                            : Column(children: charts);
                      },
                    ),
                    const SizedBox(height: 12),
                    for (final profile in profiles) ...[
                      const _SkillRule(),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: colour(profile),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                profile.profile,
                                style: colors.typography.label.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Text(
                      'Recorded skill loads/references and patches or full edits. No date window supplied. ${observation.activity.where((p) => p.uses != null || p.patches != null).length} profile records; missing records are unknown.',
                      style: colors.typography.label.copyWith(
                        color: colors.muted,
                      ),
                    ),
                    if (observation.readRequests case final requests?) ...[
                      const SizedBox(height: 12),
                      const _SkillRule(),
                      StudioButtonPress(
                        child: InkWell(
                          onTap: () => setState(() => _requests = !_requests),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Read requests · ${observation.readPeriodDays} days',
                                    style: colors.typography.label,
                                  ),
                                ),
                                Text(
                                  requests.toString(),
                                  style: colors.typography.label,
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  _requests
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: 16,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (_requests) ...[
                        if (requests > 0)
                          ClipRRect(
                            borderRadius: WingRadius.control,
                            child: SizedBox(
                              height: MediaQuery.textScalerOf(
                                context,
                              ).scale(32),
                              child: Row(
                                children: [
                                  for (final profile in profiles)
                                    if (profile.readRequests case final count?
                                        when count > 0)
                                      Expanded(
                                        flex: count,
                                        child: Semantics(
                                          label:
                                              '${profile.profile}: $count read requests',
                                          child: Container(
                                            color: colour(profile),
                                            alignment: Alignment.center,
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 2,
                                                    ),
                                                child: Text(
                                                  count.toString(),
                                                  style: colors.typography.label
                                                      .copyWith(
                                                        color: _chartInk(
                                                          colour(profile),
                                                        ),
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          'Logged skill-read requests in sessions started within ${observation.readPeriodDays} days, including unsuccessful requests. Missing profile records are unknown.',
                          style: colors.typography.label.copyWith(
                            color: colors.muted,
                          ),
                        ),
                      ],
                    ],
                    if (profiles.any((p) => p.lastPatched != null)) ...[
                      const SizedBox(height: 12),
                      const _SkillRule(),
                      const SizedBox(height: 8),
                      Text(
                        'Last updated',
                        style: colors.typography.label.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final profile in profiles)
                        if (profile.lastPatched case final date?)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                Text(
                                  profile.profile,
                                  style: colors.typography.label.copyWith(
                                    color: colors.muted,
                                  ),
                                ),
                                Text(
                                  _skillDate(context, date, exact: true),
                                  style: colors.typography.label.copyWith(
                                    color: colors.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Color _chartInk(Color colour) =>
    colour.computeLuminance() > .35 ? const Color(0xff101b24) : Colors.white;
typedef _SkillChartValue = ({String name, int count, Color color});

class _SkillDonut extends StatelessWidget {
  const _SkillDonut({required this.label, required this.values});
  final String label;
  final List<_SkillChartValue> values;
  @override
  Widget build(BuildContext context) {
    final colors = WingTokens.of(context),
        total = values.fold<int>(0, (sum, p) => sum + p.count),
        scale = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final size = math.min(box.maxWidth - 8, scale.scale(200));
        final chartHeight = math.max(
          size,
          scale.scale(20) * values.where((p) => p.count > 0).length + 8,
        );
        return Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            children: [
              Text(
                label,
                textAlign: TextAlign.center,
                style: colors.typography.label.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                label:
                    '$label: $total. ${values.map((p) => '${p.name} ${p.count}').join(', ')}',
                child: ExcludeSemantics(
                  child: total == 0
                      ? SizedBox(
                          height: size,
                          child: Center(
                            child: Text('0', style: colors.typography.title),
                          ),
                        )
                      : SizedBox(
                          width: size,
                          height: chartHeight,
                          child: CustomPaint(
                            painter: _SkillDonutPainter(
                              values: values,
                              label: label == 'Uses' ? 'uses' : 'changes',
                              ink: colors.onSurface,
                              scale: scale,
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SkillDonutPainter extends CustomPainter {
  const _SkillDonutPainter({
    required this.values,
    required this.label,
    required this.ink,
    required this.scale,
  });
  final List<_SkillChartValue> values;
  final String label;
  final Color ink;
  final TextScaler scale;
  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (sum, p) => sum + p.count),
        center = size.center(Offset.zero),
        diameter = size.width - scale.scale(40),
        stroke = diameter * .22,
        radius = (diameter - stroke) / 2,
        outerRadius = radius + stroke / 2;
    final outside = <({TextPainter text, Offset anchor, Color color})>[];
    TextPainter text(String value, double font, Color color) => TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontSize: scale.scale(font),
          fontWeight: FontWeight.w500,
          fontFamily: WingTypography.sans,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    void centered(TextPainter painter, Offset at) {
      painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
    }

    var angle = -math.pi / 2;
    for (final value in values) {
      if (value.count == 0) continue;
      final sweep = value.count / total * math.pi * 2;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        angle,
        sweep,
        false,
        Paint()
          ..color = value.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke,
      );
      final middle = angle + sweep / 2,
          direction = Offset(math.cos(middle), math.sin(middle)),
          at = center + direction * radius,
          painter = text(value.count.toString(), 12, _chartInk(value.color)),
          bounds = Rect.fromCenter(
            center: at,
            width: painter.width,
            height: painter.height,
          );
      // A label belongs inside only when all its corners fit the actual slice.
      final fits =
          [
            bounds.topLeft,
            bounds.topRight,
            bounds.bottomLeft,
            bounds.bottomRight,
          ].every((point) {
            final delta = point - center;
            final distance = delta.distance;
            final relative =
                (math.atan2(delta.dy, delta.dx) - middle + math.pi) %
                    (math.pi * 2) -
                math.pi;
            return distance >= radius - stroke / 2 &&
                distance <= outerRadius &&
                relative.abs() <= sweep / 2;
          });
      if (fits) {
        centered(painter, at);
      } else {
        outside.add((
          text: text(value.count.toString(), 12, ink),
          anchor: center + direction * (outerRadius + 1),
          color: value.color,
        ));
      }
      painter.dispose();
      angle += sweep;
    }
    // Order each side by its slice position, then resolve vertical collisions.
    for (final left in [true, false]) {
      final labels =
          outside.where((p) => (p.anchor.dx < center.dx) == left).toList()
            ..sort((a, b) => a.anchor.dy.compareTo(b.anchor.dy));
      final positions = <double>[];
      var edge = 4.0;
      for (final item in labels) {
        final y = math.max(item.anchor.dy, edge + item.text.height / 2);
        positions.add(y);
        edge = y + item.text.height / 2 + scale.scale(4);
      }
      edge = size.height - 4;
      for (var i = labels.length - 1; i >= 0; i--) {
        positions[i] = math.min(positions[i], edge - labels[i].text.height / 2);
        edge = positions[i] - labels[i].text.height / 2 - scale.scale(4);
      }
      for (var i = 0; i < labels.length; i++) {
        final item = labels[i],
            x = left ? 2.0 : size.width - item.text.width - 2,
            end = Offset(left ? x + item.text.width + 3 : x - 3, positions[i]);
        canvas.drawLine(
          item.anchor,
          end,
          Paint()
            ..color = item.color
            ..strokeWidth = 1,
        );
        item.text.paint(canvas, Offset(x, positions[i] - item.text.height / 2));
      }
    }
    // Keep the complete center block inside an inscribed square of the hole.
    final square = (radius - stroke / 2) * math.sqrt2 - 4;
    TextPainter fitCenter(String value, double font, double maxHeight) {
      var painter = text(value, font, ink);
      final factor = math.min(
        1.0,
        math.min(square / painter.width, maxHeight / painter.height),
      );
      if (factor < 1) {
        painter.dispose();
        painter = text(value, font * factor, ink);
      }
      return painter;
    }

    final count = fitCenter(total.toString(), 24, square * .6),
        caption = fitCenter(label, 11, square * .3),
        height =
            count.height +
            caption.height +
            math.min(scale.scale(3), square * .08);
    centered(count, center + Offset(0, (count.height - height) / 2));
    centered(caption, center + Offset(0, (height - caption.height) / 2));
    count.dispose();
    caption.dispose();
    for (final item in outside) {
      item.text.dispose();
    }
  }

  @override
  bool shouldRepaint(_SkillDonutPainter old) =>
      old.values != values ||
      old.label != label ||
      old.ink != ink ||
      old.scale != scale;
}
