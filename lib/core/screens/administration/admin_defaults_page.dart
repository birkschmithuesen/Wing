import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';

import '../../models/profile_model_defaults.dart';
import '../../models/settings_edit.dart';
import '../../models/provider_access.dart';
import '../../services/administration_repository.dart';
import '../../services/profile_model_defaults_session.dart';
import '../../widgets/admin_model_picker.dart';
import '../../widgets/profile_default_model_sheet.dart';
import '../../widgets/read_recovery.dart';
import 'admin_fallback_page.dart';
import 'provider_recovery_routes.dart';
import 'admin_providers_page.dart';
import 'admin_settings_page.dart';
import 'admin_widgets.dart';
import 'admin_delegation_model_page.dart';

class AdminDefaultsPage extends StatefulWidget {
  final ProfileAdministration profile;
  const AdminDefaultsPage({super.key, required this.profile});
  @override
  State<AdminDefaultsPage> createState() => _AdminDefaultsPageState();
}

class _AdminDefaultsPageState extends State<AdminDefaultsPage> {
  late final _profile = widget.profile;
  late final _edit = ProfileModelDefaultsSession(_profile);

  @override
  void initState() {
    super.initState();
    _edit.load();
  }

  @override
  void dispose() {
    _edit.dispose();
    super.dispose();
  }

  Future<bool> _confirm(HelperChangeConfirmation confirmation) {
    if (!mounted) return Future.value(false);
    return switch (confirmation.kind) {
      HelperConfirmationKind.reset => adminConfirm(
        context,
        'Reset all helper models?',
        'All helper tasks will choose automatically. Their saved endpoint credentials will be cleared.',
        action: 'Reset all',

        actionIcon: Icons.restart_alt,
        destructive: true,
      ),
      HelperConfirmationKind.expensive => adminConfirm(
        context,
        'Confirm model change',
        confirmation.message,
        action: 'Use model',

        actionIcon: Icons.check,
        destructive: false,
      ),
      HelperConfirmationKind.retry => adminConfirm(
        context,
        'Retry the pending helper change?',
        'Hermes still reports the original settings. The previous result was not confirmed. Apply the pending choice again?',
        action: 'Retry',

        actionIcon: Icons.refresh,
        destructive: false,
      ),
    };
  }

  Future<void> _chooseHelper(String task) async {
    final draft = await _edit.prepareHelper(task);
    if (!mounted || draft == null) return;
    final selection = await chooseAdminModel(
      context,
      draft.choices,
      scopeLabel: 'Helper model for ${task.replaceAll('_', ' ')}',
      onRefresh: () => _edit.catalog(refresh: true),
      initialSelection: draft.initialSelection,
      allowAuto: true,
      actionLabel: 'Set helper model',
    );
    if (!mounted || selection == null) return;
    _savedNotice(await _edit.selectHelper(draft, selection, confirm: _confirm));
  }

  void _savedNotice(HelperSaveOutcome outcome) {
    if (mounted && outcome == HelperSaveOutcome.saved) {
      adminMessage(context, 'Helper defaults saved for ${_profile.name}.');
    }
  }

  Widget _pendingActions(String? task) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      StudioButtonPress(
        child: TextButton(
          onPressed: _edit.busy
              ? null
              : () async => _savedNotice(
                  await _edit.retryHelper(task, confirm: _confirm),
                ),
          child: const Text('Retry'),
        ),
      ),
      StudioButtonPress(
        child: IconButton(
          tooltip: 'Discard pending helper change',
          onPressed: _edit.busy ? null : () => _edit.discardPending(task),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
    ],
  );

  String _helperSummary(HelperRowObservation row) {
    final pending = row.pending?.selection;
    if (pending != null) {
      final choice = pending.choice;
      return choice == null
          ? 'Pending: Automatic'
          : 'Pending: ${choice.provider} / ${choice.model}';
    }
    final assignment = row.assignment;
    if (assignment.provider == 'auto') return 'Automatic';
    return '${assignment.provider} / ${assignment.model}${row.available ? '' : ' · Not in the available model list'}';
  }

  String _accessLabel(ModelProviderAccess access) => switch (access.state) {
    ProviderAccessState.connected => 'Credentials detected',
    ProviderAccessState.expired => 'Access token expired',
    ProviderAccessState.signedOut => 'No sign-in stored',
    ProviderAccessState.external => 'Check external sign-in',
    ProviderAccessState.unknown => 'Status unavailable',
  };

  Widget _content(BuildContext context, ModelDefaultsObservation data) {
    final fields = [
      for (final setting in data.settings)
        AdminField(
          setting.key,
          switch (setting.kind) {
            ModelDefaultSettingKind.reasoning => 'Reasoning effort',
            ModelDefaultSettingKind.serviceTier => 'Service tier',
          },
          AdminFieldKind.choice,
          choices: setting.choices,
          modelCapability: setting.modelCapability,
        ),
    ];
    final access = _edit.access;
    return StudioLoadingRegion(
      available: true,
      busy: _edit.accessLoading,
      label: 'Loading defaults',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'New-chat defaults · Existing chats keep their model choices.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          AdminGroup(
            children: [
              AdminRow(
                title: 'Default model',
                subtitle: data.model.hasModel
                    ? '${data.model.provider.isEmpty ? 'Automatic provider' : data.model.provider} / ${data.model.model}'
                    : 'No model selected',
                icon: Icons.auto_awesome_outlined,
                onTap: _edit.busy
                    ? null
                    : () async {
                        await showProfileDefaultModelSheet(
                          context,
                          gateway: _profile.gateway,
                          connectionLabel: _profile.server.connectionLabel,
                        );
                        if (mounted) await _edit.load();
                      },
              ),
              if (fields.isNotEmpty)
                AdminRow(
                  title: 'Reasoning and speed',
                  subtitle: 'Defaults supported by this model',
                  icon: Icons.speed,
                  onTap: () => adminPushProfile(
                    context,
                    _profile,
                    (context, profile) => AdminSettingsPage(
                      profile: profile,
                      title: 'Reasoning and speed',
                      fields: fields,
                      expectedModel: data.model,
                    ),
                  ),
                ),
              AdminRow(
                title: 'Fallback models',
                subtitle: 'Ordered alternatives when a model is unavailable',
                icon: Icons.alt_route,
                onTap: () => adminPushProfile(
                  context,
                  _profile,
                  (context, profile) => AdminFallbackPage(profile: profile),
                ),
              ),
            ],
          ),
          if (_edit.accessError != null)
            AdminNotice.error(_edit.accessError!, retry: _edit.refreshAccess),
          AdminRow(
            title: 'Account access',
            icon: Icons.key_outlined,
            subtitle: access?.providerId == null
                ? 'Source unavailable · Review provider access'
                : '${_accessLabel(access!)} · ${access.sourceLabel}',
            onTap: () async {
              final providerId = access?.providerId;
              await adminPushProfile(
                context,
                _profile,
                (context, profile) => providerId == null
                    ? AdminProvidersPage(profile: profile)
                    : providerRecoveryPage(
                        profile: profile,
                        providerId: providerId,
                      ),
              );
              if (mounted) await _edit.refreshAccess();
            },
          ),
          if (fields.isEmpty)
            const AdminNotice(
              'Reasoning and speed capabilities were not reported for this model.',
            ),
          const SizedBox(height: 24),
          AdminGroup(
            children: [
              AdminRow(
                title: 'Subagent model',
                subtitle: 'Model and provider for delegated work',
                icon: Icons.account_tree_outlined,
                onTap: () => adminPushProfile(
                  context,
                  _profile,
                  (_, profile) => AdminDelegationModelPage(profile: profile),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Helper models', style: Theme.of(context).textTheme.titleMedium),
          const AdminNotice(
            'Automatic tasks choose through Hermes. Named assignments keep their own provider.',
          ),
          AdminGroup(
            children: [
              for (final row in _edit.helperRows)
                StudioButtonPress(
                  child: ListTile(
                    title: Text(row.assignment.task.replaceAll('_', ' ')),
                    subtitle: Text(_helperSummary(row)),
                    trailing: row.pending == null
                        ? const Icon(Icons.chevron_right)
                        : _pendingActions(row.assignment.task),
                    onTap: row.canChoose
                        ? () => _chooseHelper(row.assignment.task)
                        : null,
                  ),
                ),
            ],
          ),
          if (_edit.pendingFor(null) != null)
            ListTile(
              title: const Text('Pending helper reset'),
              trailing: _pendingActions(null),
            ),
          StudioButtonPress(
            child: TextButton(
              onPressed: _edit.canReset
                  ? () async => _savedNotice(
                      await _edit.resetHelpers(confirm: _confirm),
                    )
                  : null,
              child: const Text('Reset all helper models'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Models and reasoning',
    scope: _profile.label,
    child: ListenableBuilder(
      listenable: _edit,
      builder: (context, _) => ReadRecovery(
        shouldRetry: () => _edit.canRecoverRead,
        retry: _edit.load,
        child: StudioLoadingRegion(
          available: _edit.observation != null,
          busy: _edit.loading || _edit.working,
          label: 'Loading defaults',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_edit.error != null)
                Flexible(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: AdminNotice.error(
                        '${_edit.checkedAt == null ? '' : 'Last checked ${TimeOfDay.fromDateTime(_edit.checkedAt!).format(context)}. '}${_edit.error}',
                        retry: _edit.busy || _edit.loading ? null : _edit.load,
                      ),
                    ),
                  ),
                ),
              if (_edit.observation case final data?)
                Expanded(child: _content(context, data)),
            ],
          ),
        ),
      ),
    ),
  );
}
