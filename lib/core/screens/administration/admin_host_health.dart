import 'package:flutter/material.dart';

import '../../models/host_resources.dart';
import '../../services/host_resources_session.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/studio_loading.dart';
import 'admin_widgets.dart';

/// A borrowed connection-owned observation. Refresh only reads host data.
class AdminHostHealth extends StatelessWidget {
  const AdminHostHealth({super.key, required this.resources});
  final HostResourcesSession resources;

  @override
  Widget build(BuildContext context) => _HostResourcesConsumer(
    resources: resources,
    builder: (context, state) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HostHeading(resources: resources, state: state),
        ..._notices(state),
        AdminGroup(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StudioButtonPress(
                  child: InkWell(
                    onTap: () => adminPush(
                      context,
                      (_) => AdminHostDetailsPage(resources: resources),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        child: Row(
                          children: [
                            const Icon(Icons.dns_outlined, size: 22),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    state.stats.value?.hostname ??
                                        'Host resources',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  if (state.stats.value case final stats?)
                                    Text(
                                      '${stats.os} ${stats.osRelease} · ${stats.architecture} · v${stats.hermesVersion}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    )
                                  else if (!state.refreshing)
                                    Text(
                                      'Machine details unavailable',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right, size: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: _HostMeters(state: state),
                ),
                if (state.stats.value case final stats?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Uptime ${_uptime(stats.uptime)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (stats.load case final load?)
                          Text(
                            'Load (1 / 5 / 15) · ${_load(load)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ],
    ),
  );
}

class AdminHostDetailsPage extends StatelessWidget {
  const AdminHostDetailsPage({super.key, required this.resources});
  final HostResourcesSession resources;
  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Host resources',
    scope: resources.scopeLabel,
    child: _HostResourcesConsumer(
      resources: resources,
      builder: (context, state) {
        final stats = state.stats.value;
        final facts = <(String, String)>[
          ('Host', stats?.hostname ?? '—'),
          (
            'Operating system',
            stats == null ? '—' : '${stats.os} ${stats.osRelease}',
          ),
          ('Architecture', stats?.architecture ?? '—'),
          ('Logical CPUs', '${stats?.logicalCpus ?? '—'}'),
          ('Host uptime', _uptime(stats?.uptime)),
          (
            'Load · 1 / 5 / 15 min',
            stats?.load == null ? '—' : _load(stats!.load!),
          ),
          (
            'Memory available',
            stats?.memory == null ? '—' : _bytes(stats!.memory!.availableBytes),
          ),
          (
            'Disk free',
            stats?.disk == null ? '—' : _bytes(stats!.disk!.freeBytes),
          ),
          (
            'Python',
            stats == null
                ? '—'
                : '${stats.pythonImplementation} ${stats.pythonVersion}',
          ),
          ('Hermes', stats == null ? '—' : 'v${stats.hermesVersion}'),
          (
            'API process memory',
            stats?.process == null
                ? '—'
                : _bytes(stats!.process!.residentBytes),
          ),
          ('API process threads', '${stats?.process?.threads ?? '—'}'),
        ];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _HostHeading(resources: resources, state: state),
            ..._notices(state),
            AdminGroup(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: _HostMeters(state: state),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (final (label, value) in facts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final large =
                        MediaQuery.textScalerOf(context).scale(16) >= 24;
                    final labelWidget = Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                    final valueWidget = Text(
                      value,
                      style: Theme.of(context).textTheme.bodyMedium,
                    );
                    return large
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [labelWidget, valueWidget],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: labelWidget),
                              const SizedBox(width: 12),
                              Flexible(child: valueWidget),
                            ],
                          );
                  },
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'Disk is the volume containing Hermes data. Uptime is time since the host booted. API process memory excludes other Hermes processes.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    ),
  );
}

/// Presentation binds visibility and app lifecycle to one independent watch.
class _HostResourcesConsumer extends StatefulWidget {
  const _HostResourcesConsumer({
    required this.resources,
    required this.builder,
  });
  final HostResourcesSession resources;
  final Widget Function(BuildContext, HostResourcesState) builder;
  @override
  State<_HostResourcesConsumer> createState() => _HostResourcesConsumerState();
}

class _HostResourcesConsumerState extends State<_HostResourcesConsumer>
    with WidgetsBindingObserver {
  late HostResourcesWatch _watch;
  bool _visible = false;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _watch = widget.resources.watch(active: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _activateAfterFrame();
  }

  @override
  void didUpdateWidget(_HostResourcesConsumer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.resources, widget.resources)) {
      _watch.close();
      _watch = widget.resources.watch(active: false);
      _activateAfterFrame();
    }
  }

  void _activateAfterFrame() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _watch.setActive(_visible && _foreground);
      });
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _watch.setActive(_visible && _foreground);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watch.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.resources,
    builder: (context, _) => widget.builder(context, widget.resources.state),
  );
}

class _HostHeading extends StatefulWidget {
  const _HostHeading({required this.resources, required this.state});
  final HostResourcesSession resources;
  final HostResourcesState state;
  @override
  State<_HostHeading> createState() => _HostHeadingState();
}

class _HostHeadingState extends State<_HostHeading> {
  Future<void>? _requestedRefresh;

  @override
  void didUpdateWidget(_HostHeading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.resources, widget.resources)) {
      _requestedRefresh = null;
    }
  }

  Future<void> _refresh() async {
    if (_requestedRefresh != null) return;
    final pending = widget.resources.refresh();
    setState(() {
      _requestedRefresh = pending;
    });
    try {
      await pending;
    } finally {
      if (mounted && identical(_requestedRefresh, pending)) {
        setState(() => _requestedRefresh = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final at = state.stats.readAt?.toLocal();
    final now = DateTime.now();
    final time = at == null
        ? null
        : [
            if (at.year != now.year ||
                at.month != now.month ||
                at.day != now.day)
              MaterialLocalizations.of(context).formatShortDate(at),
            TimeOfDay.fromDateTime(at).format(context),
          ].join(', ');
    final label = time == null
        ? 'Not read'
        : state.stats.error != null
        ? 'Last read $time · refresh failed'
        : state.stats.isCurrent(now, const Duration(seconds: 30))
        ? 'Read $time'
        : 'Last read $time';
    return StudioPageLoading(
      active: _requestedRefresh != null,
      label: 'Refreshing host resources',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Host', style: Theme.of(context).textTheme.titleMedium),
                  if (!state.refreshing || state.stats.value != null)
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            StudioButtonPress(
              child: IconButton(
                tooltip: 'Refresh host resources',
                onPressed: state.refreshing || _requestedRefresh != null
                    ? null
                    : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<Widget> _notices(HostResourcesState state) {
  final notices = <Widget>[];
  if (state.stats.error case final error?) {
    notices.add(
      AdminNotice.error(
        state.stats.value == null
            ? error
            : '$error Showing the last resource reading.',
      ),
    );
  } else if (state.stats.value case final stats?) {
    if (stats.cpuPercent == null ||
        stats.memory == null ||
        stats.disk == null) {
      notices.add(
        const AdminNotice(
          'Some resource metrics are not supplied by this server.',
        ),
      );
    }
  }
  if (state.pressure.error != null) {
    notices.add(
      const AdminNotice.error('Resource pressure could not be refreshed.'),
    );
  }
  return notices;
}

class _HostMeters extends StatelessWidget {
  const _HostMeters({required this.state});
  final HostResourcesState state;
  @override
  Widget build(BuildContext context) {
    final stats = state.stats.value;
    final now = DateTime.now();
    final current = state.stats.isCurrent(now, const Duration(seconds: 30));
    final pressure = state.pressure.isCurrent(now, const Duration(seconds: 30))
        ? state.pressure.value
        : null;
    Color color(HostPressure? level) => !current
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : level == HostPressure.critical
        ? WingTokens.of(context).danger
        : level == HostPressure.elevated
        ? WingTokens.of(context).warning
        : Theme.of(context).colorScheme.primary;
    final memory = stats?.memory, disk = stats?.disk;
    return Column(
      children: [
        _HostMetricRow(
          label: 'CPU',
          icon: Icons.memory_outlined,
          value: stats?.cpuPercent == null
              ? '—'
              : '${stats!.cpuPercent!.toStringAsFixed(0)}%',
          percent: stats?.cpuPercent,
          color: color(null),
        ),
        _HostMetricRow(
          label: 'Memory',
          icon: Icons.view_week_outlined,
          value: memory == null
              ? '—'
              : _capacity(memory.usedBytes, memory.totalBytes),
          percent: memory?.usedPercent,
          color: color(pressure?.memoryAt(now)),
          pressure: pressure?.memoryAt(now),
        ),
        _HostMetricRow(
          label: 'Disk',
          icon: Icons.storage_outlined,
          value: disk == null
              ? '—'
              : _capacity(disk.usedBytes, disk.totalBytes),
          percent: disk?.usedPercent,
          color: color(pressure?.disk),
          pressure: pressure?.disk,
        ),
      ],
    );
  }
}

class _HostMetricRow extends StatelessWidget {
  const _HostMetricRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.percent,
    required this.color,
    this.pressure,
  });
  final String label, value;
  final IconData icon;
  final double? percent;
  final Color color;
  final HostPressure? pressure;
  @override
  Widget build(BuildContext context) {
    final status = switch (pressure) {
      HostPressure.critical => 'Critical pressure',
      HostPressure.elevated => 'Elevated pressure',
      _ => null,
    };
    final tokens = WingTokens.of(context);
    return Semantics(
      label: [
        '$label: ${percent == null ? 'unavailable' : value}',
        ?status,
      ].join('. '),
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final theme = Theme.of(context),
                scaler = MediaQuery.textScalerOf(context);
            final labelStyle = theme.textTheme.bodyMedium?.copyWith(
              fontSize: 14,
            );
            final valueStyle = theme.textTheme.bodySmall?.copyWith(
              fontSize: 13,
            );
            final painter = TextPainter(
              text: TextSpan(text: value, style: valueStyle),
              textDirection: Directionality.of(context),
              textScaler: scaler,
            )..layout();
            final wide =
                scaler.scale(14) <= 20 &&
                18 + 24 + 60 + painter.width + 32 < constraints.maxWidth;
            painter.dispose();
            final meter = percent == null
                ? Text('Unavailable', style: theme.textTheme.bodySmall)
                : SizedBox(
                    height: 5,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: ColoredBox(
                        color: WingTokens.of(context).border,
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FractionallySizedBox(
                            widthFactor: (percent! / 100).clamp(0.0, 1.0),
                            child: ColoredBox(
                              color: color,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
            final labelWidget = Text(label, style: labelStyle);
            final valueWidget = Text(value, style: valueStyle);
            return ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: wide
                          ? CrossAxisAlignment.center
                          : CrossAxisAlignment.start,
                      children: [
                        Icon(
                          icon,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        if (wide) ...[
                          SizedBox(width: 60, child: labelWidget),
                          valueWidget,
                          const SizedBox(width: 8),
                          Expanded(child: meter),
                        ] else
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                labelWidget,
                                valueWidget,
                                const SizedBox(height: 4),
                                meter,
                              ],
                            ),
                          ),
                      ],
                    ),
                    if (status != null)
                      Padding(
                        padding: EdgeInsetsDirectional.only(
                          start: wide ? 86 : 26,
                          top: 4,
                        ),
                        child: Text(
                          status,
                          style: valueStyle?.copyWith(
                            color: pressure == HostPressure.critical
                                ? tokens.danger
                                : tokens.warning,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

String _bytes(int value) => value < 1073741824
    ? '${(value / 1048576).toStringAsFixed(0)} MiB'
    : '${(value / 1073741824).toStringAsFixed(1)} GiB';
String _capacity(int used, int total) =>
    '${(used / 1073741824).toStringAsFixed(1)} / ${(total / 1073741824).toStringAsFixed(1)} GiB';
String _load(HostLoadAverage load) =>
    '${load.oneMinute.toStringAsFixed(2)} / ${load.fiveMinutes.toStringAsFixed(2)} / ${load.fifteenMinutes.toStringAsFixed(2)}';
String _uptime(Duration? uptime) {
  if (uptime == null) return '—';
  if (uptime.inDays > 0) return '${uptime.inDays}d ${uptime.inHours % 24}h';
  if (uptime.inHours > 0) return '${uptime.inHours}h ${uptime.inMinutes % 60}m';
  return '${uptime.inMinutes}m';
}
