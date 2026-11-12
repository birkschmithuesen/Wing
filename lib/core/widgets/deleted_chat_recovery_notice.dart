import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/profile_workspace_controller.dart'
    show DeletedDraftCleanupPresentation, DeletedDraftCleanupEntry;
import '../theme/wing_theme.dart';
import 'studio_error.dart';

/// Renders the owner's recovery facts without interpreting deletion receipts.
/// Commands capture their own target and publish failures through [presentation].
class DeletedChatRecoveryNotice extends StatelessWidget {
  const DeletedChatRecoveryNotice({super.key, required this.presentation});

  final ValueListenable<DeletedDraftCleanupPresentation> presentation;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<DeletedDraftCleanupPresentation>(
        valueListenable: presentation,
        builder: (context, value, _) {
          final summary = value.summary;
          if (summary == null) return const SizedBox.shrink();
          final largeText = MediaQuery.textScalerOf(context).scale(16) > 20;
          final message = Semantics(
            liveRegion: true,
            child: Text(summary, style: Theme.of(context).textTheme.bodySmall),
          );
          final review = StudioButtonPress(
            child: TextButton(
              key: const ValueKey('deleted-chat-review'),
              onPressed: () => _review(context),
              child: const Text('Review'),
            ),
          );
          return Padding(
            key: const ValueKey('deleted-chat-recovery-notice'),
            padding: const EdgeInsets.symmetric(
              horizontal: WingSpacing.lg,
              vertical: WingSpacing.xs,
            ),
            child: largeText
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      message,
                      Align(alignment: Alignment.centerRight, child: review),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: message),
                      const SizedBox(width: WingSpacing.md),
                      review,
                    ],
                  ),
          );
        },
      );

  void _review(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => DeletedChatRecoverySheet(presentation: presentation),
    );
  }
}

/// The scrolling surface stays mounted while captured owner commands settle.
/// Closing this sheet does not cancel or repeat any recovery operation.
class DeletedChatRecoverySheet extends StatelessWidget {
  const DeletedChatRecoverySheet({super.key, required this.presentation});

  final ValueListenable<DeletedDraftCleanupPresentation> presentation;

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height * 0.82)
        .clamp(0.0, 720.0)
        .toDouble();
    return StudioLoadingFrame(
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  WingSpacing.lg,
                  0,
                  WingSpacing.sm,
                  WingSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Chat deletion',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    const StudioLoadingSlot(),
                    StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Close chat recovery',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ValueListenableBuilder<DeletedDraftCleanupPresentation>(
                  valueListenable: presentation,
                  builder: (context, value, _) => CustomScrollView(
                    key: const ValueKey('deleted-chat-recovery-list'),
                    slivers: [
                      if (value.entries.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(WingSpacing.lg),
                            child: Text('No chat deletions need attention.'),
                          ),
                        ),
                      SliverList.builder(
                        itemCount: value.entries.length,
                        itemBuilder: (context, index) => _RecoveryEntry(
                          key: ValueKey(value.entries[index].key),
                          entry: value.entries[index],
                        ),
                      ),
                      const SliverToBoxAdapter(
                        child: SizedBox(height: WingSpacing.lg),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecoveryEntry extends StatelessWidget {
  const _RecoveryEntry({super.key, required this.entry});

  final DeletedDraftCleanupEntry entry;

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(WingSpacing.lg),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tokens.border)),
      ),
      child: StudioLoadingRegion(
        available: !entry.busy,
        busy: entry.busy,
        label: 'Recovering conversation',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label: entry.identification,
              child: Tooltip(
                message: entry.identification,
                excludeFromSemantics: true,
                child: Text(
                  entry.title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
            const SizedBox(height: WingSpacing.xs),
            Text(
              entry.profile,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.muted),
            ),
            const SizedBox(height: WingSpacing.sm),
            Semantics(liveRegion: true, child: Text(entry.detail)),

            if (entry.error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: WingSpacing.sm),
                child: StudioError(error),
              ),
            if (entry.actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: WingSpacing.xs),
                child: Wrap(
                  spacing: WingSpacing.sm,
                  runSpacing: WingSpacing.xs,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final action in entry.actions)
                      StudioButtonPress(
                        child: TextButton(
                          onPressed: action.invoke,
                          child: Text(action.label),
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
