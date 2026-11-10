import '../../widgets/selection_viewport.dart';
import '../../models/scheduled_task.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../../widgets/wing_app_bar.dart';
import '../../services/administration_logs_session.dart';
import 'admin_plugins_page.dart';
import '../../services/profile_plugins_session.dart';
import '../../services/profile_skills_session.dart';
import '../../services/profile_tool_setup_session.dart';
import 'admin_provider_credentials.dart';
import '../../services/profile_capabilities_session.dart';
import '../../models/profile_session_key.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'dart:async';
import '../analytics_content.dart';
import '../../models/profile_overview_summary.dart';
import '../../services/profile_overview_session.dart';
import '../../services/scheduled_tasks_controller.dart';
import '../../services/profile_diagnostics_controller.dart';
import '../../widgets/workspace_connection_status.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/server_connection_label.dart';
import '../../widgets/profile_selector.dart';
import '../../theme/wing_theme.dart';
import 'admin_profile_overview.dart';
import 'package:flutter/material.dart';
import '../../services/administration_repository.dart';
import '../../services/profile_workspace_controller.dart';
import '../../services/profiles_management_session.dart';
import '../../services/profile_identity_edit_session.dart';
import 'admin_identity_page.dart';
import 'admin_profiles_page.dart';
import '../profile_capabilities_screen.dart';
import 'admin_widgets.dart';
import 'admin_settings_page.dart';
import 'admin_memory_page.dart';
import 'admin_providers_page.dart';
import 'admin_health_page.dart';
import 'admin_defaults_page.dart';
import 'admin_connector_routes.dart';
import 'admin_tool_setup_page.dart';
import 'admin_voice_routes.dart';
import '../../services/android_voice.dart';
import 'admin_skills_page.dart';
import 'admin_hosted_connector_accounts_page.dart';
import 'admin_logs_page.dart';
import 'admin_scheduled_tasks_page.dart';

class HermesAdministrationContent extends StatefulWidget {
  final ProfileWorkspaceController controller;
  final VoidCallback onOpenMenu;
  final VoidCallback? onConnections;
  final AdministrationRepository? repository;
  final Future<void> Function(ProfileSessionKey) onOpenSession;
  final ValueChanged<ScheduledTaskInvestigationRequest>? onInvestigate;
  final bool healthOnly;
  const HermesAdministrationContent({
    super.key,
    required this.controller,
    required this.onOpenMenu,
    this.onConnections,
    this.repository,
    required this.onOpenSession,
    this.onInvestigate,
    this.healthOnly = false,
  });
  @override
  State<HermesAdministrationContent> createState() =>
      _HermesAdministrationContentState();
}

class _HermesAdministrationContentState
    extends State<HermesAdministrationContent> {
  late final _healthSession = widget.controller.healthSession(
    repository: widget.repository,
  );
  late final _server = _healthSession.server;
  String _search = '';
  ProfileOverviewSession? _overviewSession;
  String? _healthProfileName;
  bool _refreshingHealth = false;
  bool get _checkingProfile => _healthSession.checking(_profile?.name);

  void _selectOverviewProfile() {
    if (widget.healthOnly) return;
    final profile = _profile;
    if (_overviewSession?.scope == profile?.scope) return;
    _overviewSession?.removeListener(_overviewChanged);
    _overviewSession?.dispose();
    _overviewSession = profile == null
        ? null
        : ProfileOverviewSession(
            profile,
            widget.controller.preferences,
            refreshWorkspace: widget.controller.refresh,
          );
    final session = _overviewSession;
    if (session != null) {
      session.addListener(_overviewChanged);
      unawaited(session.load());
    }
  }

  void _overviewChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openDestination(_Destination destination) async {
    final openEditor = destination.open;
    if (openEditor == null) return;
    final session = _overviewSession;
    final overviewDestination = destination.overviewDestination;
    if (!widget.healthOnly && session != null && overviewDestination != null) {
      await session.review(overviewDestination, openEditor);
    } else {
      await openEditor();
      if (mounted && widget.healthOnly) await _refreshHealthProfile();
    }
  }

  void _selectHealthProfile() {
    if (!widget.healthOnly) return;
    _healthSession.select(
      _profile == null ? null : widget.controller.current?.gateway,
    );
  }

  Future<void> _refreshHealthProfile() {
    final workspace = widget.controller.current;
    return workspace == null
        ? Future.value()
        : _healthSession.refresh(workspace.gateway);
  }

  Future<void> _checkProfile() => _refreshHealthProfile();

  Future<void> Function(
    Future<void> Function(ProfileAdministration profile) openEditor,
  )?
  _reviewAccessCommand() {
    final workspace = widget.controller.current;
    if (workspace == null || workspace.scope != _profile?.scope) return null;
    return (openEditor) =>
        _healthSession.reviewAccess(workspace.gateway, openEditor);
  }

  @override
  void initState() {
    super.initState();
    if (widget.healthOnly) {
      _healthProfileName = _profile?.name;
    }
    widget.controller.addListener(_workspaceChanged);
    _selectHealthProfile();
    _selectOverviewProfile();
    if (widget.healthOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_healthSession.health.refreshDiagnostics());
        }
      });
    }
  }

  void _workspaceChanged() {
    if (!mounted) return;
    final name = _profile?.name;
    if (widget.healthOnly && name != _healthProfileName) {
      _healthProfileName = name;
      _selectHealthProfile();
    }
    _selectOverviewProfile();
    setState(() {});
  }

  ProfileDiagnosticsController? _checksForCurrentProfile() {
    final workspace = widget.controller.current;
    if (workspace == null || workspace.scope != _profile?.scope) return null;
    return _healthSession.checksFor(workspace.gateway);
  }

  Future<void> _refresh() async {
    if (!widget.healthOnly) {
      final session = _overviewSession;
      if (session != null) {
        await session.refresh();
        if (mounted && identical(session, _overviewSession)) {
          if (session.refreshError case final error?) {
            showStudioError(context, error);
          }
        }
      } else {
        await widget.controller.refresh();
      }
      return;
    }
    if (_refreshingHealth) return;
    setState(() => _refreshingHealth = true);
    try {
      await Future.wait([
        widget.controller.refresh(),
        _refreshHealthProfile(),
        widget.controller
            .hostResources(repository: widget.repository)
            .refresh(),
      ]);
    } catch (error) {
      if (mounted) {
        showStudioError(context, administrationError(error));
      }
    } finally {
      if (mounted) setState(() => _refreshingHealth = false);
    }
  }

  final _searchInput = TextEditingController();
  @override
  void dispose() {
    widget.controller.removeListener(_workspaceChanged);
    _overviewSession?.removeListener(_overviewChanged);
    _overviewSession?.dispose();
    _searchInput.dispose();
    super.dispose();
  }

  ProfileAdministration? get _profile {
    final name = widget.controller.current?.scope.profileName;
    if (name == null || widget.controller.discovery?.named(name) == null) {
      return null;
    }
    return _server.profile(name);
  }

  Future<void> _manageProfiles() async {
    final controller = widget.controller;
    await adminPush(
      context,
      (context) => AdminProfilesPage(
        createSession: () => ProfilesManagementSession(
          server: _server,
          openProfile: controller.switchProfile,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _selector({bool manage = false}) {
    final profiles = widget.controller.discovery?.profiles ?? [];
    final name = _profile?.name;
    final colors = Theme.of(context).colorScheme;
    final manageAction = manage
        ? Tooltip(
            message: 'Manage profiles',
            child: StudioButtonPress(
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 36),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  visualDensity: VisualDensity.standard,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  foregroundColor: colors.onSurfaceVariant,
                  backgroundColor: colors.surfaceContainerLow,
                  side: BorderSide(color: colors.outlineVariant),
                  shape: RoundedRectangleBorder(
                    borderRadius: WingRadius.control,
                  ),
                ),
                onPressed: _manageProfiles,
                child: const Icon(Icons.manage_accounts_outlined),
              ),
            ),
          )
        : null;
    final selector = profiles.isEmpty
        ? const AdminNotice(
            'No available profiles. Runtime health remains accessible.',
          )
        : ProfileSelector(
            profiles: profiles,
            createColors: widget.controller.createProfileColors,
            selectedProfile: name,
            padding: EdgeInsets.zero,
            trailing: manageAction,
            onSelected: widget.controller.switching
                ? null
                : (choice) async {
                    await widget.controller.switchProfile(choice);
                    if (mounted) setState(() {});
                  },
          );
    if (!manage || profiles.isNotEmpty) return selector;
    return Row(
      children: [
        Expanded(child: selector),
        manageAction!,
      ],
    );
  }

  Future<void> _identity(ProfileAdministration profile) async {
    final controller = widget.controller;
    final changed = await showAdminIdentityEditor(
      context,
      createSession: () => ProfileIdentityEditSession(profile),
    );
    if (changed &&
        mounted &&
        identical(controller, widget.controller) &&
        _profile?.scope == profile.scope) {
      await controller.refresh();
    }
  }

  Future<void> _settings(
    ProfileAdministration p,
    String title,
    List<AdminField> fields, {
    String? initialField,
  }) => adminPushProfile(
    context,
    p,
    (context, profile) => AdminSettingsPage(
      profile: profile,
      title: title,
      fields: fields,
      initialField: initialField,
    ),
  );

  Widget _menu(String title, String scope, List<Widget> rows) => AdminPage(
    title: title,
    scope: scope,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [AdminGroup(children: rows)],
    ),
  );

  List<_Destination> _destinations(ProfileAdministration? p) => [
    _Destination(
      'Profile',
      'Models and reasoning',
      'Model, reasoning, helper models and fallbacks',
      Icons.tune,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) => AdminDefaultsPage(profile: profile),
            ),
      overviewDestination: ProfileOverviewDestination.models,
    ),
    _Destination(
      'Profile',
      'Identity',
      'Description and SOUL',
      Icons.person_outline,
      p == null ? null : () => _identity(p),
      overviewDestination: ProfileOverviewDestination.identity,
    ),
    _Destination(
      'Profile',
      'Memory',
      'Retained memories and character budgets',
      Icons.bookmark_border,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) => AdminMemoryPage(profile: profile),
            ),
      overviewDestination: ProfileOverviewDestination.memory,
    ),
    _Destination(
      'Profile',
      'Skills and tools',
      'Instructions, toolsets and setup',
      Icons.extension_outlined,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) => profileCapabilitiesPage(context, profile),
            ),
      overviewDestination: ProfileOverviewDestination.skills,
    ),
    _Destination(
      'Profile',
      'Scheduled tasks',
      'Schedules, runs and results',
      Icons.event_repeat_outlined,
      p == null
          ? null
          : () {
              final root = ModalRoute.of(context);
              final navigator = Navigator.of(context);
              return adminPushProfile(
                context,
                p,
                (context, profile) => AdminScheduledTasksPage(
                  profile: profile,
                  onInvestigate: widget.onInvestigate == null
                      ? null
                      : (request) {
                          widget.onInvestigate!(request);
                          if (navigator.mounted) {
                            navigator.popUntil((route) => route == root);
                          }
                        },
                  acquireController: () => ScheduledTasksController.acquire(
                    profile,
                    widget.controller.preferences,
                  ),
                  onOpenSession: (key) async {
                    await widget.onOpenSession(key);
                    if (navigator.mounted) {
                      navigator.popUntil((route) => route == root);
                    }
                  },
                ),
              );
            },
      overviewDestination: ProfileOverviewDestination.scheduledTasks,
    ),
    _Destination(
      'Profile',
      'Access and connectors',
      'Provider accounts, API keys and profile connectors',
      Icons.link,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) =>
                  _menu('Access and connectors', profile.label, [
                    AdminRow(
                      title: 'Provider access',
                      subtitle: 'Accounts and API keys for this profile',
                      icon: Icons.key_outlined,
                      onTap: () => adminPushProfile(
                        context,
                        profile,
                        (context, profile) =>
                            AdminProvidersPage(profile: profile),
                      ),
                    ),
                    AdminRow(
                      title: 'Connected apps',
                      subtitle: 'Named work and personal app accounts',
                      icon: Icons.apps_outlined,
                      onTap: () => adminPushProfile(
                        context,
                        profile,
                        (_, profile) =>
                            AdminHostedConnectorAccountsPage(profile: profile),
                      ),
                    ),
                    AdminRow(
                      title: 'MCP connectors',
                      subtitle: 'Status, tools, authentication and access',
                      icon: Icons.link,
                      onTap: () => adminPushProfile(
                        context,
                        profile,
                        (context, profile) => profileConnectorsPage(profile),
                      ),
                    ),
                  ]),
            ),
      overviewDestination: ProfileOverviewDestination.access,
    ),
    _Destination(
      'Profile',
      'Behavior',
      'Execution, approval policy, compression and voice',
      Icons.settings_outlined,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) => _menu('Behavior', profile.label, [
                AdminRow(
                  title: 'Execution',
                  subtitle: 'Agent and subagent limits',
                  icon: Icons.rule,
                  onTap: () => _settings(profile, 'Execution', executionFields),
                ),
                AdminRow(
                  title: 'Approval policy',
                  subtitle: 'Approvals and command allowlist',
                  icon: Icons.shield_outlined,
                  onTap: () =>
                      _settings(profile, 'Approval policy', approvalFields),
                ),
                AdminRow(
                  title: 'Compression',
                  subtitle: 'Context thresholds and protected messages',
                  icon: Icons.compress,
                  onTap: () =>
                      _settings(profile, 'Compression', compressionFields),
                ),
                AdminRow(
                  title: 'Reach and recovery',
                  subtitle: 'Private URLs, redaction and checkpoints',
                  icon: Icons.restore,
                  onTap: () =>
                      _settings(profile, 'Reach and recovery', reachFields),
                ),
                AdminRow(
                  title: 'Voice',
                  subtitle: 'Backend speech defaults',
                  icon: Icons.mic_none,
                  onTap: () => adminPushProfile(
                    context,
                    profile,
                    (context, profile) => profileVoicePage(
                      profile,
                      device: AndroidVoice.instance,
                    ),
                  ),
                ),
              ]),
            ),
      overviewDestination: ProfileOverviewDestination.behavior,
    ),
  ];

  List<_Destination> _searchDestinations(ProfileAdministration? p) => [
    ..._destinations(p),
    for (final group in <String, List<AdminField>>{
      'Memory settings': memoryFields,
      'Execution': executionFields,
      'Approval policy': approvalFields,
      'Compression': compressionFields,
      'Reach and recovery': reachFields,
    }.entries)
      for (final field in group.value)
        _Destination(
          'Profile',
          field.label,
          group.key,
          Icons.tune,
          p == null
              ? null
              : () => _settings(
                  p,
                  group.key,
                  group.value,
                  initialField: field.key,
                ),
          overviewDestination: ProfileOverviewDestination.behavior,
        ),
    _Destination(
      'Profile',
      'Helper models',
      'Auxiliary assignments and reset',
      Icons.auto_awesome_outlined,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) => AdminDefaultsPage(profile: profile),
            ),
      overviewDestination: ProfileOverviewDestination.models,
    ),
    _Destination(
      'Profile',
      'Skill Hub',
      'Install, uninstall and update skills',
      Icons.download_outlined,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) => AdminSkillHubPage(
                createSession: () => ProfileSkillsSession.hub(profile),
              ),
            ),
      overviewDestination: ProfileOverviewDestination.skillHub,
    ),
    _Destination(
      'Profile',
      'MCP connectors',
      'Authentication and tool inventory',
      Icons.link,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) => profileConnectorsPage(profile),
            ),
      overviewDestination: ProfileOverviewDestination.connectors,
    ),
    _Destination(
      'Profile',
      'Agent plugins',
      'Plugin inventory and enablement',
      Icons.extension_outlined,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) => AdminPluginsPage(
                createSession: () => ProfilePluginsSession(profile),
              ),
            ),
      overviewDestination: null,
    ),
    _Destination(
      'Analytics',
      'Analytics',
      'Usage, tokens and cost by day and model',
      Icons.bar_chart,
      p == null
          ? null
          : () => adminPushProfile(
              context,
              p,
              (context, profile) => AnalyticsPage(profile: profile),
            ),
      overviewDestination: null,
    ),
    _Destination(
      'Runtime health',
      'Logs',
      'Errors, severity and search',
      Icons.subject,
      () {
        final server = _server;
        return adminPush(
          context,
          (context) => AdminLogsPage(
            createSession: () => AdministrationLogsSession(server),
          ),
        );
      },
      overviewDestination: null,
    ),
  ];

  Widget _searchField() => viewportSelection(
    TextField(
      controller: _searchInput,
      decoration: InputDecoration(
        hintText: MediaQuery.textScalerOf(context).scale(16) >= 24
            ? 'Search'
            : 'Search settings',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _search.isEmpty
            ? null
            : StudioButtonPress(
                child: IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchInput.clear();
                    setState(() => _search = '');
                    FocusScope.of(context).unfocus();
                  },
                ),
              ),
      ),
      onChanged: (value) => setState(() => _search = value),
    ),
  );

  Widget? _searchResults(ProfileAdministration? profile) {
    if (_search.isEmpty) return null;
    final matches = _searchDestinations(
      profile,
    ).where((d) => d.matches(_search)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (matches.isEmpty)
          const AdminNotice(
            'No matching settings. Try a feature name such as memory or providers.',
          ),
        for (final destination in matches)
          AdminRow(
            title: destination.title,
            subtitle:
                '${destination.path}\n${destination.tab.startsWith('Profile') ? '${_server.connectionLabel} / ${profile?.name ?? 'Select a profile'}' : _server.connectionLabel}',
            icon: destination.icon,
            onTap: destination.open == null
                ? null
                : () => _openDestination(destination),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.healthOnly) {
      return ListenableBuilder(
        listenable: Listenable.merge([
          widget.controller,
          _healthSession.health,
          _healthSession,
        ]),
        builder: (context, _) => AdminHealthContent(
          health: _healthSession.health,
          hostResources: widget.controller.hostResources(
            repository: widget.repository,
          ),
          persistenceError: _healthSession.persistenceError,
          profile: _profile,
          chatController: widget.controller,
          onOpenSession: (key) async {
            final root = ModalRoute.of(context);
            final navigator = Navigator.of(context);
            await widget.onOpenSession(key);
            if (navigator.mounted) {
              navigator.popUntil((route) => route == root);
            }
          },
          onCheckProfile: _checkingProfile || widget.controller.switching
              ? null
              : _checkProfile,
          checkingProfile: _checkingProfile,
          profileCheckedAt: _healthSession.checkedAt(_profile?.name),
          accessChecks: _checksForCurrentProfile,
          onReviewAccess: _reviewAccessCommand(),
          onConnections: widget.onConnections,
          onRefresh: _refresh,
          onOpenDestination: (title) async {
            final destination = _destinations(
              _profile,
            ).where((d) => d.title == title).firstOrNull;
            if (destination?.open != null) {
              await _openDestination(destination!);
            }
          },
        ),
      );
    }
    final profile = _profile;
    return Scaffold(
      appBar: WingAppBar(
        context: context,
        leading: StudioButtonPress(
          child: IconButton(
            tooltip: 'Open navigation menu',
            icon: const Icon(Icons.menu),
            onPressed: widget.onOpenMenu,
          ),
        ),
        title: const Text('Administration'),
        contextRow: ServerConnectionLabel(
          label: _server.connectionLabel,
          suffix: profile?.name,
          style: Theme.of(context).textTheme.bodySmall,
          icon: widget.controller.connection.icon,
          status: widget.controller.connectionStatus,
        ),
        actions: [
          StudioButtonPress(
            child: IconButton(
              tooltip: 'Refresh administration',
              icon: const Icon(Icons.refresh),
              onPressed:
                  _overviewSession?.refreshing == true ||
                      widget.controller.switching
                  ? null
                  : _refresh,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StudioLoadingRegion(
        available: true,
        busy: widget.controller.switching,
        label: 'Switching profile',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WorkspaceConnectionStatus(
              status: widget.controller.connectionStatus,
            ),
            if (widget.controller.error != null)
              ListTile(
                title: StudioError(widget.controller.error!),
                trailing: StudioButtonPress(
                  child: TextButton(
                    onPressed: widget.controller.retry,
                    child: const Text('Retry'),
                  ),
                ),
              ),
            Expanded(
              child: profile == null
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _selector(manage: true),
                        const SizedBox(height: 12),
                        _searchField(),
                        ?_searchResults(profile),
                        if (_search.isEmpty)
                          const AdminNotice(
                            'Choose an available profile to manage its settings. Health remains accessible.',
                          ),
                      ],
                    )
                  : AdminProfileOverview(
                      key: ValueKey(profile.scope.storageNamespace),
                      metadata: widget.controller.discovery?.named(
                        profile.name,
                      ),
                      session: _overviewSession!,
                      selector: _selector(manage: true),
                      search: _searchField(),
                      searchResults: _searchResults(profile),
                      destinations: {
                        for (final d in _destinations(profile))
                          ?d.overviewDestination: d.open,
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The dedicated Health destination keeps the same retained observations and
/// profile-scoped actions as Administration without nesting Health there.
class HermesHealthContent extends HermesAdministrationContent {
  const HermesHealthContent({
    super.key,
    required super.controller,
    required super.onOpenMenu,
    super.onConnections,
    super.repository,
    required super.onOpenSession,
    super.onInvestigate,
  }) : super(healthOnly: true);
}

class _Destination {
  final String tab, title, subtitle;
  final IconData icon;
  final FutureOr<void> Function()? open;
  final ProfileOverviewDestination? overviewDestination;
  const _Destination(
    this.tab,
    this.title,
    this.subtitle,
    this.icon,
    this.open, {
    required this.overviewDestination,
  });
  String get path {
    if (tab == 'Profile') {
      if (const {
        'Execution',
        'Approval policy',
        'Compression',
        'Reach and recovery',
      }.contains(subtitle)) {
        return 'Profile › Behavior › $subtitle';
      }
      if (subtitle == 'Memory settings') {
        return 'Profile › Memory › Memory settings';
      }
      return switch (title) {
        'Helper models' => 'Profile › Models and reasoning › Helper models',
        'Skill Hub' => 'Profile › Skills and tools › Discover skills',
        'Agent plugins' => 'Profile › Skills and tools › Agent plugins',
        'MCP connectors' => 'Profile › Access and connectors › MCP connectors',
        _ => 'Profile › $title',
      };
    }
    if (tab == 'Analytics') return 'Hermes analytics › Selected profile';
    if (tab == 'Runtime health') return 'Health › Runtime › $title';
    return '$tab › $title';
  }

  bool matches(String query) {
    final vocabulary = switch (title) {
      'Access and connectors' =>
        'providers API key credentials login sign-in account',
      'Behavior' => 'timeout voice approvals compression limits',
      'Models and reasoning' => 'models intelligence reasoning speed',
      'Run time budget' || 'Subagent timeout' => 'timeout duration seconds',
      'Skill Hub' => 'install discover skills',
      _ => '',
    };
    return '$title $subtitle $vocabulary'.toLowerCase().contains(
      query.trim().toLowerCase(),
    );
  }
}

/// Shared composition for the profile menu and alert recovery.
Widget profileCapabilitiesPage(
  BuildContext context,
  ProfileAdministration profile,
) => ProfileCapabilitiesScreen(
  createSession: () => ProfileCapabilitiesSession(profile.gateway),
  connectionLabel: profile.server.connectionLabel,
  onConnectedApps: () => adminPushProfile(
    context,
    profile,
    (_, profile) => AdminHostedConnectorAccountsPage(profile: profile),
  ),
  onMcpConnectors: () => adminPushProfile(
    context,
    profile,
    (_, profile) => profileConnectorsPage(profile),
  ),
  onToolSetup: (name) => adminPushProfile(
    context,
    profile,
    (context, profile) => name == 'tts'
        ? profileSpeechSynthesisPage(profile, device: AndroidVoice.instance)
        : AdminToolSetupPage(
            createSession: () => ProfileToolSetupSession(profile, tool: name),
            onCredential: (context, field) => adminPushProfile(
              context,
              profile,
              (context, profile) =>
                  AdminSecretPage(profile: profile, name: field.key),
            ),
          ),
  ),
  onLibrary: () => adminPushProfile(
    context,
    profile,
    (context, profile) => AdminSkillLibraryPage(
      createSession: () => ProfileSkillsSession.library(profile),
    ),
  ),
  onHub: () => adminPushProfile(
    context,
    profile,
    (context, profile) => AdminSkillHubPage(
      createSession: () => ProfileSkillsSession.hub(profile),
    ),
  ),
  onPlugins: () => adminPushProfile(
    context,
    profile,
    (context, profile) =>
        AdminPluginsPage(createSession: () => ProfilePluginsSession(profile)),
  ),
);
