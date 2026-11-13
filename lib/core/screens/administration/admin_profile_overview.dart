import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/hermes_profile.dart';
import '../../models/profile_overview_summary.dart';
import '../../services/profile_overview_session.dart';
import 'admin_widgets.dart';
import 'scheduled_task_widgets.dart';

class AdminProfileOverview extends StatefulWidget {
  const AdminProfileOverview({
    super.key,
    required this.metadata,
    required this.session,
    required this.selector,
    required this.search,
    this.searchResults,
    required this.destinations,
  });
  final HermesProfile? metadata;
  final ProfileOverviewSession session;
  final Widget selector;
  final Widget search;
  final Widget? searchResults;
  final Map<ProfileOverviewDestination, FutureOr<void> Function()?>
  destinations;

  @override
  State<AdminProfileOverview> createState() => _AdminProfileOverviewState();
}

class _AdminProfileOverviewState extends State<AdminProfileOverview> {
  ProfileOverviewSession get session => widget.session;

  final _scrollController = ScrollController();
  double? _overviewScrollOffset;

  @override
  void didUpdateWidget(AdminProfileOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchResults == null && widget.searchResults != null) {
      _overviewScrollOffset = _scrollController.hasClients
          ? _scrollController.offset
          : null;
    } else if (oldWidget.searchResults != null &&
        widget.searchResults == null) {
      final offset = _overviewScrollOffset;
      _overviewScrollOffset = null;
      if (offset != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          _scrollController.jumpTo(
            offset.clamp(0, _scrollController.position.maxScrollExtent),
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _text(OverviewText text) => text.render(
    integer: MaterialLocalizations.of(context).formatDecimal,
    checkedTime: (time) => TimeOfDay.fromDateTime(time).format(context),
    taskTime: (time) => taskTime(context, time),
  );

  Future<void> _openDestination(ProfileOverviewDestination destination) {
    final openEditor = widget.destinations[destination];
    return openEditor == null
        ? Future.value()
        : session.review(destination, openEditor);
  }

  Widget _modelBrief(BuildContext context, ProfileOverviewSummary summary) {
    final theme = Theme.of(context);
    final model = summary.modelTitle;
    final metadata = _text(summary.modelMetadata);
    final attention = summary.modelAttention;
    return _group([
      StudioButtonPress(
        child: InkWell(
          key: const ValueKey('Models and reasoning'),
          onTap: widget.destinations[ProfileOverviewDestination.models] == null
              ? null
              : () => _openDestination(ProfileOverviewDestination.models),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Models and reasoning',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (widget.destinations[ProfileOverviewDestination
                            .models] !=
                        null)
                      const Icon(Icons.chevron_right, size: 20),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  model,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(metadata, style: theme.textTheme.bodySmall),
                if (attention != null) ...[
                  const SizedBox(height: 4),
                  AdminAttention(attention),
                ],
              ],
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _group(List<Widget> children) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const Divider(height: 1),
          children[index],
        ],
      ],
    ),
  );

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    ),
  );

  Widget _row(ProfileOverviewRow row) => _ProfileOverviewRow(
    key: ValueKey(row.destination.label),
    attention: row.attention,
    detail: row.detail,
    title: row.destination.label,
    subtitle: _text(row.summary),
    onTap: widget.destinations[row.destination] == null
        ? null
        : () => _openDestination(row.destination),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final summary = session.summary;
      return StudioRefresh(
        available: true,
        label: 'Refreshing profile',
        onRefresh: session.refresh,
        child: ListView(
          controller: _scrollController,
          key: PageStorageKey('admin-overview:${session.storageNamespace}'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            widget.selector,
            if (widget.metadata?.description?.trim() case final description?
                when description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            widget.search,
            if (widget.searchResults case final results?)
              results
            else ...[
              const SizedBox(height: 20),
              _modelBrief(context, summary),
              _heading('Agent setup'),
              _group([
                _row(summary.rows[ProfileOverviewDestination.identity]!),
                _row(summary.rows[ProfileOverviewDestination.memory]!),
                _row(summary.rows[ProfileOverviewDestination.behavior]!),
              ]),
              _heading('Capabilities and automation'),
              _group([
                _row(summary.rows[ProfileOverviewDestination.skills]!),
                _row(summary.rows[ProfileOverviewDestination.access]!),
                _row(summary.rows[ProfileOverviewDestination.scheduledTasks]!),
              ]),
            ],
          ],
        ),
      );
    },
  );
}

/// Compact grouped rows keep changed observations visible without moving the
/// destination, and let task details and large text grow naturally.
class _ProfileOverviewRow extends StatefulWidget {
  const _ProfileOverviewRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.attention,
    this.detail,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String? attention;
  final String? detail;
  final VoidCallback? onTap;

  @override
  State<_ProfileOverviewRow> createState() => _ProfileOverviewRowState();
}

class _ProfileOverviewRowState extends State<_ProfileOverviewRow> {
  Timer? _timer;
  bool _changed = false;

  @override
  void didUpdateWidget(_ProfileOverviewRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subtitle != widget.subtitle &&
        !oldWidget.subtitle.toLowerCase().contains('loading') &&
        !oldWidget.subtitle.contains('Schedules unavailable') &&
        !MediaQuery.disableAnimationsOf(context)) {
      _timer?.cancel();
      _changed = true;
      _timer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _changed = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      animationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      color: _changed ? theme.colorScheme.primaryContainer : Colors.transparent,
      child: StudioButtonPress(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          minTileHeight: 56,
          minVerticalPadding: 8,
          title: Text(widget.title, style: theme.textTheme.titleSmall),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.attention case final attention?) ...[
                const SizedBox(height: 4),
                AdminAttention(attention),
                const SizedBox(height: 4),
              ],
              if (widget.detail case final detail?)
                Text(detail, style: theme.textTheme.bodySmall),
              Text(widget.subtitle, style: theme.textTheme.bodySmall),
            ],
          ),
          trailing: widget.onTap == null
              ? null
              : const Icon(Icons.chevron_right, size: 20),
          onTap: widget.onTap,
        ),
      ),
    );
  }
}
