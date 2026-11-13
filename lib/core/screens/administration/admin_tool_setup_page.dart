import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../../widgets/read_recovery.dart';
import '../../models/profile_tool_setup.dart';
import '../../services/profile_tool_setup_session.dart';
import 'package:flutter/material.dart';
import '../../widgets/model_chooser.dart';
import 'admin_widgets.dart';
import 'admin_operations_page.dart';

class AdminToolSetupPage extends StatefulWidget {
  const AdminToolSetupPage({
    super.key,
    required this.createSession,
    required this.onCredential,
  });
  final ProfileToolSetupSession Function() createSession;
  final Future<void> Function(BuildContext, ToolSetupCredential) onCredential;
  @override
  State<AdminToolSetupPage> createState() => _AdminToolSetupPageState();
}

class _AdminToolSetupPageState extends State<AdminToolSetupPage> {
  late final _session = widget.createSession();
  late final Future<void> Function(BuildContext, ToolSetupCredential)
  _onCredential;

  @override
  void initState() {
    super.initState();
    _onCredential = widget.onCredential;
    _session.refresh();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _models(String provider) async {
    final editor = _session.openModelEditor(provider);
    try {
      await adminPush(
        context,
        (context) => AdminToolModelsPage(session: _session, editor: editor),
      );
    } finally {
      _session.releaseModelEditor(editor);
    }
  }

  Future<void> _setup(String key) => _session.runSetup(
    key,
    confirm: () => adminConfirm(
      context,
      'Install setup requirements?',
      'Hermes may download and install dependencies on the server. Other profiles can share those dependencies.',
      action: 'Run setup',

      actionIcon: Icons.build_outlined,
      destructive: false,
    ),
    showResult: (operation) async {
      if (mounted) {
        await adminPush(
          context,
          (context) => AdminActionPage(
            operation: operation,
            title: 'Tool setup',
            scope: _session.scopeLabel,
          ),
        );
      }
    },
  );

  @override
  Widget build(BuildContext context) => AdminPage(
    title: '${_session.tool} setup',
    scope: _session.scopeLabel,
    child: ReadRecovery(
      shouldRetry: () => _session.canRecoverReadiness,
      retry: _session.refresh,
      child: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          final state = _session.state;
          final data = state.readiness;
          return StudioLoadingRegion(
            available: data != null,
            busy:
                state.busy &&
                !state.saving &&
                state.phase != ToolSetupPhase.confirming,
            label: 'Loading tool settings',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (data == null && state.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: AdminNotice.error(
                      state.error!,
                      retry: state.busy ? null : _session.refresh,
                    ),
                  ),
                if (data != null)
                  Expanded(
                    key: const ValueKey('content'),
                    child: StudioLoadingRegion(
                      available: true,
                      busy: state.saving,
                      label: 'Saving tool settings',
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          if (state.notice case final notice?)
                            AdminNotice(notice),
                          if (state.error case final error?)
                            AdminNotice.error(error),
                          StudioButtonPress(
                            child: TextButton(
                              onPressed: state.busy ? null : _session.refresh,
                              child: const Text('Refresh readiness'),
                            ),
                          ),
                          if (data.providers.isEmpty)
                            const AdminNotice(
                              'No guided provider setup is reported for this toolset.',
                            ),
                          for (final row in data.providers)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: AdminGroup(
                                key: Key('tool-provider-${row.name}'),
                                selected: row.selected,
                                children: [
                                  Semantics(
                                    selected: row.selected,
                                    child: ListTile(
                                      selected: row.selected,
                                      title: Text(row.name),
                                      subtitle: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (row.selectedLabel
                                              case final label?)
                                            Text(
                                              label,
                                              style: TextStyle(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          Text(row.status),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Wrap(
                                      spacing: 8,
                                      children: [
                                        if (row.capabilities.isNotEmpty)
                                          for (final capability
                                              in row.capabilities)
                                            StudioButtonPress(
                                              child: TextButton(
                                                onPressed:
                                                    state.canChooseProvider
                                                    ? () => _session
                                                          .selectProvider(
                                                            row.name,
                                                            capability:
                                                                capability,
                                                          )
                                                    : null,
                                                child: Text(
                                                  'Use for ${capability.name}',
                                                ),
                                              ),
                                            )
                                        else if (data.offersProviderSelection)
                                          StudioButtonPress(
                                            child: TextButton(
                                              onPressed: state.canChooseProvider
                                                  ? () =>
                                                        _session.selectProvider(
                                                          row.name,
                                                          capability: null,
                                                        )
                                                  : null,
                                              child: const Text('Use provider'),
                                            ),
                                          ),
                                        if (data.hasModelCatalog)
                                          StudioButtonPress(
                                            child: TextButton(
                                              onPressed: state.canOpenModels
                                                  ? () => _models(row.name)
                                                  : null,
                                              child: const Text('Models'),
                                            ),
                                          ),
                                        if (row.setupKey case final key?)
                                          StudioButtonPress(
                                            child: TextButton(
                                              onPressed: state.canRunSetup
                                                  ? () => _setup(key)
                                                  : null,
                                              child: const Text(
                                                'Setup requirements',
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  for (final field in row.credentials)
                                    StudioButtonPress(
                                      child: ListTile(
                                        title: Text(field.prompt),
                                        subtitle: Text(
                                          field.isSet
                                              ? 'Available to this profile'
                                              : 'Not available',
                                        ),
                                        trailing: const Icon(
                                          Icons.key_outlined,
                                        ),
                                        onTap: state.canReviewCredentials
                                            ? () => _session.reviewCredentials(
                                                () => _onCredential(
                                                  context,
                                                  field,
                                                ),
                                              )
                                            : null,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class AdminToolModelsPage extends StatefulWidget {
  const AdminToolModelsPage({
    super.key,
    required this.session,
    required this.editor,
  });
  final ProfileToolSetupSession session;
  final ToolModelEditor editor;
  @override
  State<AdminToolModelsPage> createState() => _AdminToolModelsPageState();
}

class _AdminToolModelsPageState extends State<AdminToolModelsPage> {
  late final _session = widget.session;
  late final _editor = widget.editor;

  @override
  void initState() {
    super.initState();
    _session.loadModels(_editor);
  }

  @override
  void dispose() {
    _session.releaseModelEditor(_editor);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: '${_editor.provider} models',
    scope: _session.scopeLabel,
    child: ReadRecovery(
      shouldRetry: () => _session.canRecoverModels(_editor),
      retry: () => _session.loadModels(_editor),
      child: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          final state = _session.state;
          final models = state.models;
          return StudioLoadingRegion(
            available: models != null && !state.saving,
            busy: state.busy,
            label: state.saving ? 'Saving model' : 'Loading models',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.error case final error?)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: AdminNotice.error(
                      error,
                      retry: state.busy
                          ? null
                          : () => _session.loadModels(_editor),
                    ),
                  ),
                if (state.notice case final notice?)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: AdminNotice(notice),
                  ),
                if (models != null && !models.hasModels)
                  const Expanded(
                    child: Center(
                      child: AdminNotice(
                        'This tool provider does not expose a model catalog here.',
                      ),
                    ),
                  )
                else if (models != null)
                  Expanded(
                    key: const ValueKey('content'),
                    child: ModelChooser(
                      choices: models.choices,
                      selected: state.modelSelection,
                      onSelected: (selection) {
                        if (selection.choice case final choice?) {
                          _session.stageModel(_editor, choice);
                        }
                      },
                      onRefresh: () => _session.refreshModelChoices(_editor),
                      scopeLabel: 'Models for ${_editor.provider}',
                      keyPrefix: 'tool-model',
                      groupByProvider: false,
                      promoteSelected: true,
                      selectedStatus: state.modelSelectionStatus,
                      enabled: state.canStageModel,
                    ),
                  ),
                if (models?.hasModels == true)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: StudioFormActions(
                        onCancel: state.saving
                            ? null
                            : () => Navigator.maybePop(context),
                        onConfirm: state.canSaveModel
                            ? () => _session.saveModel(_editor)
                            : null,
                        confirmLabel: 'Save tool model',
                        busy: state.saving,
                        progressLabel: 'Saving tool model',
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
