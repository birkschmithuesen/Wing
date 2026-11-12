import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/fallback_model.dart';
import '../../models/model_choice.dart';
import '../../services/administration_repository.dart';
import '../../services/profile_fallback_edit_session.dart';
import '../../widgets/admin_model_picker.dart';
import 'admin_widgets.dart';

class AdminFallbackPage extends StatefulWidget {
  final ProfileAdministration profile;
  const AdminFallbackPage({super.key, required this.profile});
  @override
  State<AdminFallbackPage> createState() => _AdminFallbackPageState();
}

class _AdminFallbackPageState extends State<AdminFallbackPage> {
  late final ProfileFallbackEditSession _edit;
  List<FallbackModel>? get _rows => _edit.rows;
  List<FallbackModel>? get _pendingRows => _edit.pending;
  bool get _busy => _edit.busy;
  bool get _conflict => _edit.conflict;
  String? get _error => _edit.error;

  @override
  void initState() {
    super.initState();
    _edit = ProfileFallbackEditSession(widget.profile)..addListener(_changed);
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

  String _summary(List<FallbackModel> rows) => rows.isEmpty
      ? 'None'
      : rows.map((row) => '${row.provider} / ${row.model}').join('\n');

  Future<void> _reviewPending() async {
    final review = await _edit.reviewPending();
    if (!mounted || review == null) return;
    final accepted = await adminConfirm(
      context,
      'Review fallback changes',
      'Current list:\n${_summary(review.current)}\n\n'
          'Your pending list:\n${_summary(review.pending)}',
      action: 'Apply pending list',

      actionIcon: Icons.check,
      destructive: false,
    );
    if (!mounted || !accepted) return;
    await _edit.applyReviewed(review);
  }

  Future<void> _pickFallback({int? index}) async {
    final draft = await _edit.prepareSelection(index: index);
    if (!mounted || draft == null) return;
    final row = draft.current;
    final selected = await chooseAdminModel(
      context,
      draft.choices,
      scopeLabel: 'Fallback model for ${widget.profile.name}',
      onRefresh: () => _edit.catalog(refresh: true),
      initialSelection: row == null
          ? null
          : ModelSelection.model(
              ModelChoice(provider: row.provider, model: row.model),
            ),
      actionLabel: index == null ? 'Add fallback' : 'Save fallback',
    );
    final choice = selected?.choice;
    if (choice == null || !mounted) return;
    await _edit.select(choice, draft: draft);
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Fallback models',
    scope: widget.profile.label,
    child: StudioLoadingRegion(
      available: _rows != null,
      busy: _rows == null && _error == null,
      label: 'Loading fallback models',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const AdminNotice(
            'Hermes tries these models in order. Changes are saved individually.',
          ),
          if (_error != null) AdminNotice.error(_error!, retry: _edit.load),
          if (_pendingRows != null)
            StudioButtonPress(
              child: TextButton(
                onPressed: _busy
                    ? null
                    : _conflict
                    ? _reviewPending
                    : _edit.retry,
                child: Text(
                  _conflict
                      ? 'Review pending fallback change'
                      : 'Retry pending fallback change',
                ),
              ),
            ),
          if (_rows != null) ...[
            if (_rows!.isEmpty)
              const AdminNotice('No fallback models configured.'),
            for (final entry in _rows!.indexed)
              StudioButtonPress(
                child: ListTile(
                  title: Text(entry.$2.model),
                  subtitle: Text(entry.$2.provider),
                  onTap: _busy ? null : () => _pickFallback(index: entry.$1),
                  trailing: StudioButtonPress(
                    child: PopupMenuButton<String>(
                      tooltip: 'Manage fallback ${entry.$1 + 1}',
                      enabled: !_busy,
                      itemBuilder: (_) => [
                        if (entry.$1 > 0)
                          const StudioPopupMenuItem(
                            value: 'up',
                            child: Text('Move up'),
                          ),
                        if (entry.$1 < _rows!.length - 1)
                          const StudioPopupMenuItem(
                            value: 'down',
                            child: Text('Move down'),
                          ),
                        const StudioPopupMenuItem(
                          value: 'remove',
                          child: Text('Remove'),
                        ),
                      ],
                      onSelected: (action) {
                        if (action == 'remove') {
                          unawaited(_edit.remove(entry.$1));
                        } else {
                          unawaited(_edit.move(entry.$1, up: action == 'up'));
                        }
                      },
                    ),
                  ),
                ),
              ),
            StudioButtonPress(
              child: IconButton.filled(
                tooltip: 'Add fallback',
                onPressed: _busy ? null : () => _pickFallback(),
                icon: const Icon(Icons.add),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
