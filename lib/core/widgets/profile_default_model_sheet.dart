import 'studio_form_actions.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/models/model_choice.dart';
import 'studio_action_label.dart';
import 'studio_error.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/profile_gateway.dart';
import '../services/profile_model_edit_session.dart';
import '../theme/wing_theme.dart';
import 'model_chooser.dart';

Future<bool> showProfileDefaultModelSheet(
  BuildContext context, {
  required ProfileGateway gateway,
  required String connectionLabel,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => ProfileDefaultModelSheet(
        gateway: gateway,
        connectionLabel: connectionLabel,
      ),
    ) ??
    false;

class ProfileDefaultModelSheet extends StatefulWidget {
  final ProfileGateway gateway;
  final String connectionLabel;

  const ProfileDefaultModelSheet({
    super.key,
    required this.gateway,
    required this.connectionLabel,
  });

  @override
  State<ProfileDefaultModelSheet> createState() =>
      _ProfileDefaultModelSheetState();
}

class _ProfileDefaultModelSheetState extends State<ProfileDefaultModelSheet> {
  late final ProfileModelEditSession _edit;
  late final String _connectionLabel;
  bool _allowPop = false;

  bool get _dirty => _edit.dirty;
  bool get _loading => _edit.loading;
  bool get _saving => _edit.saving;
  String? get _error => _edit.error;
  String? get _notice => _edit.notice;
  String get _profileName => _edit.profileName;
  List<ModelChoice> get _choices => _edit.choices;
  ModelChoice? get _selected => _edit.selected;

  @override
  void initState() {
    super.initState();
    _connectionLabel = widget.connectionLabel;
    _edit = ProfileModelEditSession(widget.gateway)..addListener(_changed);
    unawaited(_edit.load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _edit.removeListener(_changed);
    _edit.dispose();
    super.dispose();
  }

  Future<void> _load() => _edit.load();
  Future<List<ModelChoice>> _refreshChoices() => _edit.refreshChoices();

  Future<bool> _confirm(String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => StudioDialog(
          title: const Text('Confirm model change'),
          content: Text(message),
          actions: [
            StudioFormActions(
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
              confirmLabel: 'Confirm model change',
              cancelKey: const Key('profile-model-confirm-cancel'),
              confirmKey: const Key('profile-model-confirm-accept'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _reviewChanges() async {
    final review = await _edit.reviewPending();
    if (!mounted || review == null) return;
    final decision = await showDialog<ProfileModelReviewDecision>(
      context: context,
      builder: (context) => StudioDialog(
        title: const Text('Review model change'),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Current server model'),
            Text(review.currentLabel),
            const SizedBox(height: WingSpacing.md),
            const Text('Your selection'),
            Text(review.wantedLabel),
            const SizedBox(height: WingSpacing.md),
            const Text(
              'Keep mine prepares your selection for Save default. Use server replaces your pending choice.',
            ),
          ],
        ),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context),
            onConfirm: () =>
                Navigator.pop(context, ProfileModelReviewDecision.keepMine),
            confirmLabel: 'Keep my model selection',
            leadingActions: [
              StudioButtonPress(
                child: IconButton(
                  tooltip: 'Use server model',
                  onPressed: () => Navigator.pop(
                    context,
                    ProfileModelReviewDecision.useServer,
                  ),
                  icon: const Icon(Icons.dns_outlined),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (decision == null) {
      _edit.cancelReview(review);
    } else {
      _edit.applyReviewed(review, decision);
    }
  }

  Future<void> _save() async {
    final outcome = await _edit.save(confirm: _confirm);
    if (!mounted || outcome != ProfileModelSaveOutcome.saved) return;
    _allowPop = true;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final height = (MediaQuery.sizeOf(context).height - keyboard - 24).clamp(
      0.0,
      MediaQuery.sizeOf(context).height * 0.82,
    );
    return StudioLoadingFrame(
      child: PopScope(
        canPop: !_saving || _allowPop,
        child: AnimatedPadding(
          duration: WingMotion.standard,
          curve: WingMotion.curve,
          padding: EdgeInsets.only(bottom: keyboard),
          child: SizedBox(
            height: height,
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  title: Text(
                    'Profile default model',
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '$_profileName on $_connectionLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [const StudioLoadingSlot()],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WingSpacing.lg,
                  ),
                  child: Text(
                    'For new chats only',
                    style: tokens.typography.body.copyWith(color: tokens.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: WingSpacing.lg,
                    ),
                    child: StudioError(
                      _error!,
                      key: const Key('profile-model-error'),
                    ),
                  ),
                if (_edit.canReview || _edit.reviewing)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: WingSpacing.lg,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: StudioButtonPress(
                        child: TextButton(
                          onPressed: _edit.canReview ? _reviewChanges : null,
                          child: StudioActionLabel(
                            'Review changes',
                            busy: _edit.reviewing,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: WingSpacing.lg,
                    ),
                    child: Text(
                      _notice!,
                      key: const Key('profile-model-notice'),
                    ),
                  ),
                Expanded(
                  child: _loading
                      ? const StudioPageLoading.waiting(label: 'Loading models')
                      : _error != null && _choices.isEmpty
                      ? Center(
                          child: StudioButtonPress(
                            child: TextButton(
                              key: const Key('profile-model-retry'),
                              onPressed: _load,
                              child: const Text('Retry'),
                            ),
                          ),
                        )
                      : ModelChooser(
                          choices: _choices,
                          selected: _selected == null
                              ? null
                              : ModelSelection.model(_selected!),
                          onSelected: (selection) {
                            final choice = selection.choice;
                            if (_saving || choice == null) return;
                            _edit.select(choice);
                          },
                          onRefresh: _refreshChoices,
                          scopeLabel: 'Models for $_profileName',
                          keyPrefix: 'profile-model',
                          enabled: !_saving,
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    WingSpacing.lg,
                    WingSpacing.sm,
                    WingSpacing.lg,
                    WingSpacing.md,
                  ),
                  child: StudioFormActions(
                    onCancel: _saving
                        ? null
                        : () => Navigator.pop(context, false),
                    onConfirm: _dirty && !_saving && !_edit.reviewing
                        ? _save
                        : null,
                    confirmLabel: 'Save default',
                    confirmKey: const Key('profile-model-save'),
                    busy: _saving,
                    progressLabel: 'Saving default model',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
