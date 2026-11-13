import 'package:flutter/material.dart';

import '../../models/model_choice.dart';
import '../../theme/wing_theme.dart';
import '../../services/administration_repository.dart';
import '../../services/delegation_model_session.dart';
import '../../widgets/model_chooser.dart';
import '../../widgets/studio_form_actions.dart';
import '../../widgets/studio_loading.dart';
import 'admin_widgets.dart';

class AdminDelegationModelPage extends StatefulWidget {
  const AdminDelegationModelPage({super.key, required this.profile});
  final ProfileAdministration profile;
  @override
  State<AdminDelegationModelPage> createState() =>
      _AdminDelegationModelPageState();
}

class _AdminDelegationModelPageState extends State<AdminDelegationModelPage> {
  late final _session = DelegationModelSession(widget.profile);
  bool _leaving = false;
  @override
  void initState() {
    super.initState();
    _session.load();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_session.edit.saving) return;
    if (_session.edit.dirtyCount > 0 &&
        !await adminConfirm(
          context,
          'Discard subagent model changes?',
          'Your unsaved route will be discarded.',
          action: 'Discard',
          actionIcon: Icons.delete_outline,
          destructive: true,
        )) {
      return;
    }
    if (mounted) {
      setState(() => _leaving = true);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      final state = _session.edit;
      return PopScope(
        canPop: _leaving || (!state.saving && state.dirtyCount == 0),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: AdminPage(
          title: 'Subagent model',
          scope: widget.profile.label,
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: StudioFormActions(
                onCancel: state.saving ? null : _close,
                onConfirm: state.canSave
                    ? () async {
                        await _session.save();
                      }
                    : null,
                confirmLabel: 'Save subagent model',
                busy: state.saving,
                progressLabel: 'Saving subagent model',
              ),
            ),
          ),
          child: StudioPageLoading(
            active: _session.loading,
            label: 'Loading subagent model',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          state.hasObservation ? _session.routeLabel : ' ',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (_session.hasDirectEndpoint) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'A new route clears this direct endpoint, key and protocol when saved.',
                          ),
                        ],
                        if (_session.error != null)
                          AdminNotice.error(
                            _session.error!,
                            retry: state.saving
                                ? null
                                : state.uncertain
                                ? _session.reviewUncertain
                                : _session.load,
                          ),
                        if (state.fields.any((field) => field.conflicted))
                          Wrap(
                            spacing: 8,
                            children: [
                              StudioButtonPress(
                                child: TextButton(
                                  onPressed: () =>
                                      _session.resolve(useServer: true),
                                  child: const Text('Use current route'),
                                ),
                              ),
                              StudioButtonPress(
                                child: TextButton(
                                  onPressed: () =>
                                      _session.resolve(useServer: false),
                                  child: const Text('Keep my choice'),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                if (!state.hasObservation ||
                    _session.loading && _session.choices.isEmpty)
                  const Expanded(child: SizedBox.shrink())
                else
                  Expanded(
                    flex: 3,
                    child: IgnorePointer(
                      ignoring: !_session.canChoose,
                      child: ModelChooser(
                        enabled: _session.canChoose,
                        choices: _session.choices,
                        selected: _session.selection,
                        onSelected: _session.choose,
                        onRefresh: () => _session.catalog(refresh: true),
                        specialOptions: const [
                          ModelSpecialOption(
                            ModelSpecialChoice.automatic,
                            'Inherit parent model',
                            description:
                                'Use the parent agent’s provider and model',
                          ),
                        ],
                        scopeLabel: 'Subagents · ${widget.profile.name}',
                        keyPrefix: 'delegation-model',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
