import '../widgets/selection_viewport.dart';
import '../widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../widgets/wing_app_bar.dart';
import '../services/shared_draft_session.dart';
import '../widgets/studio_selection_tile.dart';
import '../widgets/studio_select.dart';
import '../widgets/studio_error.dart';
import 'package:flutter/material.dart';

Future<bool> reviewSharedDraft(
  BuildContext context, {
  required SharedDraftSession session,
  required SharedDraftOffer offer,
}) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _SharedDraftReview(session: session, offer: offer),
      ),
    ) ??
    false;

class _SharedDraftReview extends StatefulWidget {
  const _SharedDraftReview({required this.session, required this.offer});
  final SharedDraftSession session;
  final SharedDraftOffer offer;
  @override
  State<_SharedDraftReview> createState() => _SharedDraftReviewState();
}

class _SharedDraftReviewState extends State<_SharedDraftReview> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _commit() async {
    final added = await widget.session.add(widget.offer);
    if (mounted && added) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.session.review(widget.offer);
    return PopScope(
      canPop: !state.working,
      child: Scaffold(
        appBar: WingAppBar(
          context: context,
          title: const Text(
            'Add shared content',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: SafeArea(
          child: StudioLoadingRegion(
            available: !state.working,
            busy: state.working,
            label: 'Saving shared draft',
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        'Review',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (state.text case final String text
                                  when text.isNotEmpty) ...[
                                viewportSelection(SelectableText(text)),
                                if (state.files.isNotEmpty)
                                  const Divider(height: 24),
                              ],
                              for (final file in state.files)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    file.isImage
                                        ? Icons.image_outlined
                                        : Icons.insert_drive_file_outlined,
                                  ),
                                  title: Text(
                                    file.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(_size(file.byteLength)),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (state.destinationNotice case final notice?) ...[
                        Text(notice),
                        const SizedBox(height: 12),
                      ],
                      if (state.recovery case final recovery?) ...[
                        Text(
                          'Choose “New chat with recovered draft” in the ${recovery.profileName} profile to keep your saved text and attachments with this content. Review before sending. Queued messages will stay paused.',
                        ),
                        if (recovery.text.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              recovery.text,
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        Text(
                          '${recovery.attachmentCount} attachments · ${recovery.queuedCount} queued messages',
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        'Destination',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text('Connection: ${state.connectionLabel}'),
                      const SizedBox(height: 12),
                      StudioSelect<String>(
                        key: ValueKey('share-profile-${state.profileName}'),
                        value: state.profileName,
                        label: 'Profile',
                        options: [
                          for (final profile in state.profiles)
                            (value: profile.name, label: profile.label),
                        ],
                        onChanged: state.working
                            ? null
                            : (name) => widget.session.chooseProfile(
                                widget.offer,
                                name,
                              ),
                      ),
                      const SizedBox(height: 12),
                      RadioGroup<String>(
                        groupValue: state.destination,
                        onChanged: (value) {
                          if (value != null) {
                            widget.session.chooseDestination(
                              widget.offer,
                              state.destinations.singleWhere(
                                (d) => d.id == value,
                              ),
                            );
                          }
                        },
                        child: Column(
                          children: [
                            for (final destination in state.destinations)
                              StudioRadioTile<String>(
                                minTileHeight: 48,
                                minVerticalPadding: 8,
                                key: ValueKey(destination.presentationId),
                                value: destination.id,
                                enabled: !state.working,
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  destination.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (state.canLoadMore) ...[
                        const SizedBox(height: 4),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            StudioButtonPress(
                              child: TextButton.icon(
                                key: const Key('share-load-more'),
                                onPressed: state.working || state.loadingMore
                                    ? null
                                    : () =>
                                          widget.session.loadMore(widget.offer),
                                icon: const Icon(Icons.expand_more),
                                label: Text(state.loadMoreLabel),
                              ),
                            ),
                            if (state.pageError case final error?)
                              StudioError(
                                error,
                                key: const Key('share-review-error'),
                                icon: Icons.expand_more,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: StudioError(
                      state.error!,
                      key: const Key('share-review-error'),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: StudioFormActions(
                      onCancel: state.working
                          ? null
                          : () => Navigator.maybePop(context),
                      onConfirm: state.working ? null : _commit,
                      confirmKey: const Key('share-add-to-draft'),
                      confirmLabel: state.addLabel,
                      busy: state.working,
                      progressLabel: 'Saving shared draft',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}
