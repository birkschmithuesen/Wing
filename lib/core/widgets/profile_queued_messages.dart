import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';
import '../theme/wing_icons.dart';

import '../models/composer_work.dart';
import 'studio_error.dart';
import 'anchored_expansion_tile.dart';

/// Unsent work stays immediately above the composer, outside chat scrolling.
class ProfileQueuedMessages extends StatefulWidget {
  const ProfileQueuedMessages({
    super.key,
    required this.work,
    required this.onOpenActions,
    this.steerErrorFor,
    required this.onDelete,
  });

  final ComposerObservation work;
  final ValueChanged<ComposerQueueObservation> onOpenActions;
  final String? Function(ComposerQueueId)? steerErrorFor;
  final ValueChanged<ComposerQueueObservation>? onDelete;

  @override
  State<ProfileQueuedMessages> createState() => _ProfileQueuedMessagesState();
}

class _ProfileQueuedMessagesState extends State<ProfileQueuedMessages> {
  bool _expanded = false;

  @override
  void didUpdateWidget(ProfileQueuedMessages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.work.queue.isEmpty) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final work = widget.work;
    if (work.queue.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall!.copyWith(
      fontSize: 12,
      fontStyle: FontStyle.italic,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final review = work.queue
        .where(
          (row) =>
              row.unknownOutcome ||
              row.submissionUncertain ||
              widget.steerErrorFor?.call(row.id) != null,
        )
        .toList();
    final rows = _expanded ? work.queue : review;
    final paused = work.paused && work.queue.any((row) => !row.serverOwned);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnchoredExpansionTile(
              // Empty queues remove this tile, so the next queue starts closed.
              anchorExpansion: false,
              minTileHeight: 48,
              tilePadding: EdgeInsets.zero,
              shape: const Border(),
              collapsedShape: const Border(),
              leading: Icon(
                WingIcons.queue,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(
                '${work.queue.length} queued',
                style: theme.textTheme.bodySmall,
              ),
              subtitle: paused || review.isNotEmpty
                  ? Text(
                      [
                        if (paused) 'Paused',
                        if (review.isNotEmpty) '${review.length} to review',
                      ].join(' · '),
                      style: style.copyWith(fontStyle: FontStyle.normal),
                    )
                  : null,
              onExpansionChanged: (value) => setState(() => _expanded = value),
            ),
            if (rows.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .20,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final prompt in rows)
                      Semantics(
                        label: identical(prompt.id, work.editing)
                            ? 'Editing queued message'
                            : prompt.pendingSteering
                            ? 'Steering the current turn'
                            : prompt.unknownOutcome
                            ? 'Unknown execution outcome'
                            : prompt.submissionUncertain
                            ? 'Delivery unconfirmed'
                            : prompt.serverOwned
                            ? 'Queued on Hermes'
                            : paused
                            ? 'Queued message, paused'
                            : 'Queued message',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Material(
                              color: identical(prompt.id, work.editing)
                                  ? theme.colorScheme.surfaceContainerHighest
                                  : Colors.transparent,
                              borderRadius: WingRadius.card,
                              child: StudioButtonPress(
                                child: InkWell(
                                  onTap: () => widget.onOpenActions(prompt),
                                  onLongPress: () =>
                                      widget.onOpenActions(prompt),
                                  borderRadius: WingRadius.card,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minHeight: 48,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        8,
                                        4,
                                        0,
                                        4,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (prompt.unknownOutcome ||
                                              prompt.submissionUncertain) ...[
                                            Icon(
                                              Icons.error_outline,
                                              size: 16,
                                              color: theme.colorScheme.error,
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          Expanded(
                                            child: Text(
                                              [
                                                    if (prompt.pendingSteering)
                                                      'Steering',
                                                    if (prompt.unknownOutcome)
                                                      'Outcome unknown',
                                                    if (prompt
                                                        .submissionUncertain)
                                                      'Delivery unconfirmed',
                                                    prompt.text,
                                                    prompt.attachments
                                                        .map(
                                                          (file) => file.name,
                                                        )
                                                        .join(', '),
                                                  ]
                                                  .where(
                                                    (part) => part.isNotEmpty,
                                                  )
                                                  .join(' · '),
                                              style: style.copyWith(
                                                fontStyle: FontStyle.normal,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (identical(
                                            prompt.id,
                                            work.editing,
                                          ))
                                            StudioButtonPress(
                                              child: IconButton(
                                                tooltip:
                                                    'Delete queued message',
                                                onPressed:
                                                    widget.onDelete == null
                                                    ? null
                                                    : () => widget.onDelete!(
                                                        prompt,
                                                      ),
                                                icon: const Icon(
                                                  Icons.close,
                                                  size: 18,
                                                ),
                                                color: theme.colorScheme.error,
                                                constraints:
                                                    const BoxConstraints(
                                                      minWidth: 48,
                                                      minHeight: 48,
                                                    ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (widget.steerErrorFor?.call(prompt.id)
                                case final error?)
                              StudioError(
                                error,
                                framed: false,
                                icon: WingIcons.steer,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
