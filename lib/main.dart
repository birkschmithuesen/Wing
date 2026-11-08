import 'dart:convert';
import 'core/services/live_voice_session.dart';
import 'core/services/live_voice_transport.dart';
import 'core/widgets/live_voice_scope.dart';
import 'core/models/bots.dart';
import 'core/services/health_alert_incident_store.dart';
import 'core/models/scheduled_task.dart';
import 'core/theme/project_icon_glyphs.dart';
import 'core/theme/wing_icons.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'core/services/connection_diagnostics.dart';
import 'core/services/bots_connection_source.dart';
import 'core/services/bots_session.dart';
import 'core/models/profile_session_key.dart';
import 'core/widgets/chat_notice_activity_scope.dart';
import 'core/screens/health_alert_health_screen.dart';
import 'core/models/health_alert.dart';
import 'core/services/health_alert_settings_store.dart';
import 'core/services/health_alert_settings_session.dart';
import 'core/services/health_alerts_coordinator.dart';
import 'core/widgets/health_alerts/health_alerts_scope.dart';
import 'core/widgets/health_alerts/health_alert_notice.dart';
import 'core/widgets/wing_app_bar.dart';
import 'core/services/shared_draft_session.dart';
import 'core/services/android_voice.dart';
import 'core/services/voice_preferences_session.dart';
import 'core/widgets/notification_approval_review.dart';
import 'core/widgets/server_connection_label.dart';
import 'core/widgets/connection_icon_picker.dart';
import 'core/services/network_availability.dart';
import 'core/screens/connection_setup_screen.dart';
import 'core/services/connection_setup_session.dart';
import 'core/services/connection_setup_probe.dart';
import 'core/services/hermes_cloud.dart';
import 'core/widgets/studio_error.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'core/services/application_startup.dart';
import 'core/services/android_launch_intent_service.dart';
import 'core/services/android_share_intent_service.dart';
import 'core/models/config_backup_operation.dart';
import 'core/services/backup_session.dart';
import 'core/services/config_backup_io.dart';
import 'core/services/config_backup_service.dart';
import 'core/services/connection_manager.dart';
import 'core/services/app_preferences.dart';
import 'core/theme/app_preferences_rendering.dart';
import 'core/screens/profile_workspace_screen.dart';
import 'core/screens/shared_draft_review.dart';
import 'core/services/profile_workspace_controller.dart';
import 'core/services/profile_connection_identity.dart';
import 'core/services/profile_workspace_registry.dart';
import 'core/services/workspace_entry_session.dart';
import 'core/services/profile_gateway.dart';
import 'core/models/hermes_profile.dart';
import 'core/services/microphone_permission.dart';
import 'core/services/background_monitoring_service.dart';
import 'core/services/notification_delivery_ledger.dart';
import 'core/services/native_notification_sink.dart';
import 'core/services/chat_notification_coordinator.dart';
import 'core/theme/wing_theme.dart';
import 'core/theme/profile_workspace_theme.dart';
import 'core/widgets/app_drawer.dart';
import 'core/widgets/wing_welcome.dart';
import 'core/screens/app_settings_content.dart';
import 'core/widgets/config_backup_card.dart';
import 'core/widgets/config_backup_actions.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ProjectIconGlyphs.registerLicense();
  WingIcons.registerLicense();
  final dependencies = await createApplicationDependencies();
  final shareIntents = AndroidShareIntentService();
  final launchIntents = AndroidLaunchIntentService();
  await Future.wait([shareIntents.initialize(), launchIntents.initialize()]);
  runApp(
    WingApp(
      connManager: dependencies.connectionManager,
      appPreferences: dependencies.appPreferences,
      shareIntents: shareIntents,
      launchIntents: launchIntents,
    ),
  );
}

/// All app entry routes compose the same workspace capabilities here.
ProfileWorkspaceScreen _buildWorkspaceScreen({
  GlobalKey<ProfileWorkspaceScreenState>? key,
  required ProfileWorkspaceController controller,
  required ConnectionManager connectionManager,
  required AndroidShareIntentService? shareIntents,
  required BotsSession Function()? createBotsSession,
  required Future<void> Function(ProfileSessionKey, bool Function())?
  onOpenBotChat,
  required Future<void> Function()? enableNotifications,
  required ValueListenable<BackgroundMonitoringState>?
  backgroundMonitoringState,
  required Future<void> Function()? openMonitoringBatterySettings,
  required VoidCallback onConnections,
  required Widget Function(BuildContext, VoidCallback) configurationActions,
  required Future<void> Function(SavedConnection, AppDestination)
  onSelectConnection,
  required VoidCallback? onPreferencesChanged,
  required AppDestination destination,
  ProfileSessionKey? initialBotSession,
  BotGroup? initialGroup,
  ScheduledTaskInvestigationRequest? initialInvestigation,
  bool initialQuickChat = false,
  bool initialSearchChats = false,
}) => ProfileWorkspaceScreen(
  key: key,
  controller: controller,
  createBotsSession: createBotsSession,
  onOpenBotChat: onOpenBotChat,
  initialBotSession: initialBotSession,
  initialGroup: initialGroup,
  initialInvestigation: initialInvestigation,
  initialDestination: destination,
  initialQuickChat: initialQuickChat,
  initialSearchChats: initialSearchChats,
  enableNotifications: enableNotifications,
  backgroundMonitoringState: backgroundMonitoringState,
  openMonitoringBatterySettings: openMonitoringBatterySettings,
  onConnections: onConnections,
  configurationActions: configurationActions,
  savedConnections: connectionManager.getConnections,
  onSelectConnection: onSelectConnection,
  onPreferencesChanged: onPreferencesChanged,
  onCaptureGroupPhoto: shareIntents == null
      ? null
      : (group) => shareIntents.capturePhoto({
          'connection': group.scope.connectionId,
          'connection_identity': group.scope.connectionIdentity,
          'room': group.id,
        }),
  onCapturePhoto: shareIntents == null
      ? null
      : (target) => shareIntents.capturePhoto(target.toJson()),
);

class WingApp extends StatefulWidget {
  final ConnectionManager connManager;

  /// The app owns this one injected preference owner for its full lifetime.
  final AppPreferences appPreferences;
  final AndroidShareIntentService? shareIntents;
  final AndroidLaunchIntentService? launchIntents;
  final Future<void>? startupExternalNavigationReady;

  /// When supplied, this app owns and disposes the registry.
  final ProfileWorkspaceRegistry? profileControllers;
  final ProfileGateway Function(SavedConnection, WorkspaceScope)?
  gatewayFactory;
  const WingApp({
    required this.connManager,
    required this.appPreferences,
    this.shareIntents,
    this.launchIntents,
    this.startupExternalNavigationReady,
    this.profileControllers,
    this.gatewayFactory,
    super.key,
  });

  @override
  State<WingApp> createState() => WingAppState();
}

class WingAppState extends State<WingApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _homeKey = GlobalKey<HomeScreenState>();
  final _notificationRoutes =
      <
        ProfileWorkspaceController,
        ({Route<void> route, GlobalKey<ProfileWorkspaceScreenState> screenKey})
      >{};
  late final AppPreferences _appPreferences;
  late final ProfileWorkspaceRegistry _profileControllers;
  final _liveVoice = LiveVoiceSession(
    createTransport: WebRtcLiveVoiceTransport.new,
    background: AndroidLiveVoiceBackground(),
  );
  late final NativeNotificationSink _profileNotifications;
  late final ChatNotificationCoordinator _chatNotices;
  late final Future<void> _notificationsReady;
  late final BackgroundMonitoringService _backgroundMonitoring;
  bool _startupPermissionsComplete = false;
  late final HealthAlertSettingsSession _healthAlertSettings;
  late final HealthAlertsCoordinator _healthAlerts;
  String? _deferredShareId;
  bool _disposed = false;
  final _networkAvailability = NetworkAvailability();

  Future<ProfileWorkspaceController> profileController(
    SavedConnection connection,
  ) async {
    return _profileControllers.forSavedConnection(
      widget.connManager,
      connection.id,
      canUse: () => !_disposed,
    );
  }

  Future<void> enableProfileNotifications() =>
      _chatNotices.enableNotifications();

  Future<void> openProfileNotification(String payload) =>
      _chatNotices.openPayload(payload);

  void _deferPendingShareForNotification() {
    final pendingShareId = widget.shareIntents?.pendingShare.value?.id;
    if (pendingShareId == null) return;
    _deferredShareId = pendingShareId;
    _homeKey.currentState?.deferPendingShareAutoOpen(pendingShareId);
  }

  ProfileWorkspaceScreen _workspaceScreen(
    ProfileWorkspaceController controller, {
    GlobalKey<ProfileWorkspaceScreenState>? key,
    required AppDestination destination,
    ScheduledTaskInvestigationRequest? initialInvestigation,
  }) => _buildWorkspaceScreen(
    key: key,
    controller: controller,
    connectionManager: widget.connManager,
    shareIntents: widget.shareIntents,
    createBotsSession: () =>
        savedBotsSession(widget.connManager, _profileControllers),
    onOpenBotChat: (key, canUse) async =>
        _homeKey.currentState?.selectBotChat(key, canUse),
    destination: destination,
    initialInvestigation: initialInvestigation,
    enableNotifications: enableProfileNotifications,
    backgroundMonitoringState: _backgroundMonitoring.state,
    openMonitoringBatterySettings: _backgroundMonitoring.openBatterySettings,
    onConnections: openConnections,
    configurationActions: (context, onRestored) =>
        _homeKey.currentState!.buildConfigurationActions(context, onRestored),
    onSelectConnection: (connection, destination) async {
      await _homeKey.currentState?.selectWorkspaceConnection(
        connection,
        destination,
      );
    },
    onPreferencesChanged: refreshPreferences,
  );

  Future<void> _showNotificationChat(NotificationChatRoute request) async {
    if (!mounted || !request.current) return;
    final controller = request.controller;
    final previous = request.previousController;
    if (previous != null && previous != controller) {
      final previousRoute = _notificationRoutes.remove(previous)?.route;
      if (previousRoute != null && previousRoute.isActive) {
        _navigatorKey.currentState?.removeRoute(previousRoute);
      }
    }
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      throw StateError('Notification navigation is unavailable');
    }
    final existingRoute = _notificationRoutes[controller];
    if (existingRoute != null && existingRoute.route.isCurrent) {
      existingRoute.screenKey.currentState?.showNotificationChat();
      return;
    }
    // An administration editor may guard its route against popping while
    // unsaved changes remain. Open the chat above it instead of removing it.
    final screenKey = GlobalKey<ProfileWorkspaceScreenState>();
    final route = MaterialPageRoute<void>(
      builder: (_) => _workspaceScreen(
        controller,
        key: screenKey,
        destination: AppDestination.chats,
      ),
    );
    _notificationRoutes[controller] = (route: route, screenKey: screenKey);
    unawaited(
      route.popped.then((_) {
        if (identical(_notificationRoutes[controller]?.route, route)) {
          _notificationRoutes.remove(controller);
          request.closed();
        }
      }),
    );
    navigator.push(route);
  }

  Future<void> _showNotificationGroup(NotificationGroupRoute request) async {
    if (!mounted || !request.current) return;
    final controller = request.controller;
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      throw StateError('Notification navigation is unavailable');
    }
    var existing = _notificationRoutes[controller];
    if (existing == null || !existing.route.isActive) {
      final screenKey = GlobalKey<ProfileWorkspaceScreenState>();
      final route = MaterialPageRoute<void>(
        builder: (_) => _workspaceScreen(
          controller,
          key: screenKey,
          destination: AppDestination.bots,
        ),
      );
      existing = (route: route, screenKey: screenKey);
      _notificationRoutes[controller] = existing;
      unawaited(
        route.popped.then((_) {
          if (identical(_notificationRoutes[controller]?.route, route)) {
            _notificationRoutes.remove(controller);
          }
        }),
      );
      navigator.push(route);
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || !request.current) return;
    final screen = existing.screenKey.currentState;
    if (screen == null) {
      throw StateError('Group notification route is unavailable');
    }
    await screen.showNotificationGroup(
      request.target,
      () => mounted && request.current,
    );
  }

  Future<void> _reviewNotificationApproval(
    NotificationApprovalReviewIntent review,
  ) async {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted || !review.pending) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NotificationApprovalReview(
        request: review.request,
        choice: review.choice,
        changes: review.changes,
        offline: () => review.offline,
        pending: () => review.pending,
        submit: review.submit,
      ),
    );
  }

  void _showNotificationOpenError() {
    final context = _navigatorKey.currentContext;
    if (context != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: StudioError(
            'This chat is unavailable on its original host or profile.',
          ),
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appPreferences = widget.appPreferences;
    _profileNotifications = NativeNotificationSink(
      onInteraction: (value) => _chatNotices.receiveInteraction(value),
    );
    _chatNotices = ChatNotificationCoordinator(
      widget.connManager.prefs,
      _profileNotifications,
      appPreferences: _appPreferences,
    );
    _backgroundMonitoring = BackgroundMonitoringService(
      preferences: _appPreferences,
      hasActiveChats: () => _profileControllers.hasActiveChats,
      summary: () => _profileControllers.monitoringSummary,
      notificationsEnabled: _profileNotifications.notificationsEnabled,
    );
    _notificationsReady =
        widget.startupExternalNavigationReady ??
        _profileNotifications.initialize().catchError((Object _) {});
    unawaited(
      WidgetsBinding.instance.endOfFrame.then((_) async {
        if (!mounted) return;
        await _chatNotices.requestStartupPermission();
        if (!mounted) return;
        await requestStartupMicrophonePermission(widget.connManager.prefs);
        if (!mounted) return;
        _startupPermissionsComplete = true;
        await _requestStartupBatteryExemption();
        if (mounted) await _chatNotices.syncMonitoring();
      }),
    );
    _profileControllers =
        widget.profileControllers ??
        ProfileWorkspaceRegistry(
          identities: ProfileConnectionIdentity(),
          create: (connection, identity) => ProfileWorkspaceController(
            access: widget.connManager.accessFor(connection),
            connectionIdentity: identity,
            preferences: widget.connManager.prefs,
            appPreferences: _appPreferences,
            gatewayFactory: widget.gatewayFactory == null
                ? null
                : (scope) => widget.gatewayFactory!(connection, scope),
            onAttention: _chatNotices.receiveNotice,
            onNotificationInputs: _chatNotices.receiveInputs,
            notificationResultFor: _chatNotices.focusFor,
            notificationInputsFor: _chatNotices.pendingInputsFor,
            onNotificationRead: _chatNotices.readTarget,
            onGroupAnswer: _chatNotices.receiveGroupAnswer,
            onGroupInputs: _chatNotices.receiveGroupInputs,
            onGroupAnswerRead: _chatNotices.readGroupAnswer,
          ),
        );
    _healthAlertSettings = HealthAlertSettingsSession(
      HealthAlertSettingsStore(widget.connManager.prefs),
    );
    _healthAlerts = HealthAlertsCoordinator(
      registry: _profileControllers,
      settings: _healthAlertSettings,
      monitoring: _backgroundMonitoring.state,
      incidents: HealthAlertIncidentStore(widget.connManager.prefs),
    );
    _healthAlerts.setForeground(
      WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    _chatNotices.bindApplication(
      manager: widget.connManager,
      registry: _profileControllers,
      native: _profileNotifications,
      deliveries: NotificationDeliveryLedger(widget.connManager.prefs),
      ready: _notificationsReady,
      monitoring: _backgroundMonitoring,
      showChat: _showNotificationChat,
      showGroup: _showNotificationGroup,
      reviewApproval: _reviewNotificationApproval,
      deferShare: _deferPendingShareForNotification,
      showOpenError: _showNotificationOpenError,
      beforeNavigation: () => WidgetsBinding.instance.endOfFrame,
    );
    _appPreferences.state.addListener(_preferencesChanged);
    _networkAvailability.start(
      _profileControllers.recoverConnections,
      _profileControllers.networkUnavailable,
    );
  }

  void _preferencesChanged() {
    if (mounted) setState(() {});
  }

  void refreshPreferences() {
    unawaited(_appPreferences.reload().catchError((Object _) {}));
  }

  Future<void> _requestStartupBatteryExemption() =>
      _backgroundMonitoring.requestStartupBatteryExemption(
        canRequest: () =>
            mounted &&
            _startupPermissionsComplete &&
            (WidgetsBinding.instance.lifecycleState == null ||
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.resumed),
      );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _profileControllers.setForeground(state == AppLifecycleState.resumed);
    logConnectionDiagnostic('app.lifecycle', details: {'state': state.name});
    if (state == AppLifecycleState.resumed) {
      // Admit recovery before alerts inspect failures retained during suspension.
      _profileControllers.resumeConnections();
    }
    _healthAlerts.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      unawaited(_chatNotices.applicationResumed());
      if (_startupPermissionsComplete) {
        unawaited(_requestStartupBatteryExemption());
      }
    }
  }

  Future<void> _openAlertHealth(HealthAlert alert) async {
    final controller = _healthAlerts.ownerFor(alert);
    if (controller == null || !mounted) return;
    try {
      await _navigatorKey.currentState?.push<void>(
        MaterialPageRoute(
          builder: (_) => HealthAlertHealthScreen(
            controller: controller,
            alert: alert,
            onConnections: openConnections,
            onInvestigate: (request) {
              if (!mounted) return;
              unawaited(
                _navigatorKey.currentState?.push<void>(
                  MaterialPageRoute(
                    builder: (_) => _workspaceScreen(
                      controller,
                      destination: AppDestination.chats,
                      initialInvestigation: request,
                    ),
                  ),
                ),
              );
            },
            onOpenSession: (key) async {
              await controller.openSession(key, propagateHistoryFailure: true);
              if (mounted) {
                await _navigatorKey.currentState?.push<void>(
                  MaterialPageRoute(
                    builder: (_) => _workspaceScreen(
                      controller,
                      destination: AppDestination.chats,
                    ),
                  ),
                );
              }
            },
          ),
        ),
      );
    } catch (_) {
      final context = _navigatorKey.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open this issue’s settings. Retry from the bell.',
            ),
          ),
        );
      }
    }
  }

  void openConnections() {
    _homeKey.currentState?.showConnections();
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  void _openPreferenceRepair() {
    _navigatorKey.currentState?.push<void>(
      MaterialPageRoute(
        builder: (routeContext) => Scaffold(
          appBar: WingAppBar(
            context: routeContext,
            title: const Text('App settings'),
          ),
          body: AppSettingsContent(
            pluginServer: null,
            preferences: _appPreferences,
            createVoiceSession: () => VoicePreferencesSession(
              preferences: _appPreferences,
              device: AndroidVoice.instance,
              hermesProfileLabel: null,
              openHermesSettings: null,
            ),
            onChanged: refreshPreferences,
            enableNotifications: enableProfileNotifications,
            backgroundMonitoringState: _backgroundMonitoring.state,
            openMonitoringBatterySettings:
                _backgroundMonitoring.openBatterySettings,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preferences = _appPreferences.current;
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Wing',
      themeMode: preferences.values.theme?.themeMode ?? ThemeMode.system,
      theme: profileWorkspaceTheme(
        wingTheme(Brightness.light),
        accent: preferences.values.accent?.appearance ?? WorkspaceAccent.teal,
      ),
      darkTheme: profileWorkspaceTheme(
        wingTheme(Brightness.dark),
        accent: preferences.values.accent?.appearance ?? WorkspaceAccent.teal,
      ),
      builder: (context, child) {
        final systemMediaQuery = MediaQuery.of(context);
        final preference = preferences.values.textSize;
        return LiveVoiceScope(
          session: _liveVoice,
          openChat: (key) => openProfileNotification(jsonEncode(key.toJson())),
          child: ChatNoticeActivityScope(
            activity: _chatNotices.activity,
            child: HealthAlertsScope(
              alerts: _healthAlerts,
              openAlert: _openAlertHealth,
              child: MediaQuery(
                data: systemMediaQuery.copyWith(
                  textScaler: preference == null
                      ? systemMediaQuery.textScaler
                      : preference.applyTo(systemMediaQuery.textScaler),
                ),
                child: HealthAlertNotice(
                  navigatorKey: _navigatorKey,
                  child: Column(
                    children: [
                      if (preferences.needsAppearanceRepair)
                        Material(
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'Saved appearance settings need repair. Temporary appearance is shown.',
                                    ),
                                  ),
                                  StudioButtonPress(
                                    child: TextButton(
                                      key: const ValueKey(
                                        'app-preference-repair',
                                      ),
                                      onPressed: _openPreferenceRepair,
                                      child: const Text('Repair'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      Expanded(child: LiveVoiceLayout(child: child!)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      home: HomeScreen(
        key: _homeKey,
        createBotsSession: () =>
            savedBotsSession(widget.connManager, _profileControllers),
        createEntrySession: () => WorkspaceEntrySession(
          connectionManager: widget.connManager,
          appPreferences: _appPreferences,
          registry: _profileControllers,
          launchIntents: widget.launchIntents,
        ),
        createSharedDraftSession: (entry) => SharedDraftSession(
          connectionManager: widget.connManager,
          entrySession: entry,
          shareIntents: widget.shareIntents,
          createBotsSession: () =>
              savedBotsSession(widget.connManager, _profileControllers),
        ),
        enableProfileNotifications: enableProfileNotifications,
        connManager: widget.connManager,
        appPreferences: _appPreferences,
        createBackupSession: () => BackupSession(
          configuration: ConfigBackupService(
            connectionManager: widget.connManager,
            appPreferences: _appPreferences,
          ),
          io: ConfigBackupIo(),
        ),
        onPreferencesChanged: refreshPreferences,
        onConfigurationChanged: () {
          unawaited(
            _profileControllers.reconcileConnections(
              widget.connManager.getConnections(),
            ),
          );
          if (mounted) unawaited(_chatNotices.syncMonitoring());
        },
        backgroundMonitoringState: _backgroundMonitoring.state,
        openMonitoringBatterySettings:
            _backgroundMonitoring.openBatterySettings,
        shareIntents: widget.shareIntents,
        launchIntents: widget.launchIntents,
        startupExternalNavigationReady: _notificationsReady,
        deferredShareId: _deferredShareId,
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _networkAvailability.dispose();
    _chatNotices.closeApplication();
    _healthAlerts.dispose();
    _healthAlertSettings.dispose();
    _backgroundMonitoring.dispose();
    _liveVoice.dispose();
    _profileControllers.dispose();
    _appPreferences.state.removeListener(_preferencesChanged);
    _appPreferences.dispose();
    super.dispose();
  }
}

class HomeScreen extends StatefulWidget {
  final BotsSession Function()? createBotsSession;
  final WorkspaceEntrySession Function() createEntrySession;
  final SharedDraftSession Function(WorkspaceEntrySession)
  createSharedDraftSession;
  final Future<void> Function()? enableProfileNotifications;
  final ConnectionManager connManager;
  final AppPreferences appPreferences;
  final VoidCallback? onPreferencesChanged;
  final VoidCallback? onConfigurationChanged;
  final ValueListenable<BackgroundMonitoringState>? backgroundMonitoringState;
  final Future<void> Function()? openMonitoringBatterySettings;
  final AndroidShareIntentService? shareIntents;
  final AndroidLaunchIntentService? launchIntents;
  final Future<void>? startupExternalNavigationReady;
  final String? deferredShareId;
  final BackupSession Function() createBackupSession;

  const HomeScreen({
    this.createBotsSession,
    required this.createEntrySession,
    required this.createSharedDraftSession,
    this.enableProfileNotifications,
    required this.connManager,
    required this.appPreferences,
    this.onPreferencesChanged,
    this.onConfigurationChanged,
    this.backgroundMonitoringState,
    this.openMonitoringBatterySettings,
    this.shareIntents,
    this.launchIntents,
    this.startupExternalNavigationReady,
    this.deferredShareId,
    required this.createBackupSession,
    super.key,
  });

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  List<SavedConnection> _connections = [];
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _opening = false;
  late final BackupSession _backupSession;
  late final WorkspaceEntrySession _entrySession;
  late final SharedDraftSession _sharedDraft;
  bool _settingUpConnection = false;

  AppDestination _destination = AppDestination.connections;
  String? _shownEntryError;

  void _refresh() {
    final connections = widget.connManager.getConnections();
    _connectionOwners.removeWhere(
      (connection, _) => !connections.contains(connection),
    );
    setState(() => _connections = connections);
    widget.onConfigurationChanged?.call();
  }

  /// Public only so the import flow and its widget test can refresh Home after
  /// restoring connections without restarting the process.
  void refreshConnections() => _refresh();

  Future<void> selectWorkspaceConnection(
    SavedConnection connection,
    AppDestination destination,
  ) => _navigateToWorkspace(
    connection,
    destination: destination,
    replaceWorkspace: true,
  );

  Future<void> selectBotChat(
    ProfileSessionKey key,
    bool Function() canUse,
  ) async {
    if (!canUse()) return;
    final connections = await widget.connManager.loadConnectionsWithSecrets();
    if (!mounted || !canUse()) return;
    final connection = connections
        .where((c) => c.id == key.workspace.connectionId)
        .firstOrNull;
    if (connection == null) throw StateError('Bot instance is no longer saved');
    await _navigateToWorkspace(
      connection,
      destination: AppDestination.bots,
      replaceWorkspace: true,
      botChat: key,
      canUse: canUse,
    );
  }

  void showConnections() {
    if (mounted) setState(() => _destination = AppDestination.connections);
  }

  Widget buildConfigurationActions(
    BuildContext context, [
    VoidCallback? onRestored,
  ]) => ConfigBackupActions(
    onBackup: () => _showBackupConfig(context),
    onRestore: () => _showRestoreConfig(context, onRestored: onRestored),
  );

  Future<void> _showBackupConfig(BuildContext context) async {
    final attempt = _backupSession.beginExport();
    if (attempt == null) return;
    try {
      final choice = await showModalBottomSheet<BackupExportIntent>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const ExportPassphraseSheet(),
      );
      if (choice == null || !mounted || !context.mounted) return;
      await _backupSession.export(attempt, choice);
      if (mounted && context.mounted) _showBackupOutcome(context);
    } finally {
      _backupSession.cancel(attempt);
    }
  }

  Future<void> _showRestoreConfig(
    BuildContext context, {
    VoidCallback? onRestored,
  }) async {
    final offer = await _backupSession.prepareImport();
    if (offer == null) {
      if (mounted && context.mounted) _showBackupOutcome(context);
      return;
    }
    try {
      if (!mounted || !context.mounted) return;
      final choice = await showModalBottomSheet<BackupImportIntent>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const ImportOptionsSheet(),
      );
      if (choice == null || !mounted || !context.mounted) return;
      final result = await _backupSession.restore(offer, choice);
      if (!mounted || !context.mounted) return;
      if (result != null) {
        _refresh();
        onRestored?.call();
      }
      _showBackupOutcome(context);
    } finally {
      _backupSession.cancel(offer);
    }
  }

  void _showBackupOutcome(BuildContext context) {
    final state = _backupSession.presentation.value;
    final message = state.error ?? state.notice;
    if (message == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: state.error == null ? Text(message) : StudioError(message),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _backupSession = widget.createBackupSession();
    _entrySession = widget.createEntrySession();
    _entrySession.addListener(_entryChanged);
    _sharedDraft = widget.createSharedDraftSession(_entrySession);
    _sharedDraft.addListener(_shareChanged);
    _sharedDraft.start(
      startupReady: widget.startupExternalNavigationReady,
      deferredShareId: widget.deferredShareId,
    );
    _refresh();
    widget.launchIntents?.pendingAction.addListener(_onLauncherAction);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _presentShareNotice();
      _onLauncherAction();
      _presentEntryError();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSharedText());
  }

  void deferPendingShareAutoOpen(String id) => _sharedDraft.deferAutoReview(id);

  void _entryChanged() {
    if (!mounted) return;
    setState(() {});
    final error = _entrySession.state.error;
    if (error == null) _shownEntryError = null;
    if (error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _presentEntryError());
    }
  }

  void _presentEntryError() {
    if (!mounted) return;
    final error = _entrySession.state.error;
    if (error == null || error == _shownEntryError) return;
    _shownEntryError = error;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: StudioError(error)));
  }

  SavedConnection? _connectionForExternalAction() =>
      _entrySession.externalConnection();

  void _shareChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _presentShareNotice();
      _onSharedText();
    });
  }

  void _presentShareNotice() {
    if (!mounted) return;
    final notice = _sharedDraft.takeNotice();
    if (notice == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: notice.error
            ? StudioError(notice.message)
            : Text(notice.message),
      ),
    );
  }

  void _onSharedText() => _openSharedText(explicit: false);
  void _reviewPendingShare() => _openSharedText(explicit: true);
  void _openSharedText({required bool explicit}) {
    if (!mounted) return;
    final offer = _sharedDraft.claim(
      explicit: explicit,
      presentationBlocked: _settingUpConnection || _opening,
    );
    if (offer != null) unawaited(_reviewIncomingShare(offer));
  }

  Future<void> _discardIncomingShare() => _sharedDraft.discard();

  Future<void> _reviewIncomingShare(SharedDraftOffer offer) async {
    try {
      final connection =
          offer.preferredConnection ??
          await showModalBottomSheet<SavedConnection>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(
                    title: Text(
                      'Choose a Hermes instance for this shared draft',
                    ),
                  ),
                  for (final connection in offer.connections)
                    StudioButtonPress(
                      child: ListTile(
                        horizontalTitleGap: 0,
                        leading: _serverIndicator(connection),
                        title: Text(connection.label),
                        onTap: () => Navigator.pop(context, connection),
                      ),
                    ),
                ],
              ),
            ),
          );
      if (connection == null || !mounted) return;
      final needsReview = await _sharedDraft.prepare(
        offer,
        connection,
        reviewDestination: null,
      );
      if (!mounted) return;
      if (needsReview &&
          !await reviewSharedDraft(
            context,
            session: _sharedDraft,
            offer: offer,
          )) {
        return;
      }
      if (!mounted) return;
      final navigation = _sharedDraft.navigation(offer);
      if (navigation != null) {
        await _navigateToWorkspace(
          navigation.entry.controller.connection,
          incomingSharedDraft: navigation,
        );
      }
    } catch (_) {
      // The owner retains intake and publishes the workflow outcome.
      if (mounted) _presentShareNotice();
    } finally {
      _sharedDraft.finish(offer);
      if (mounted) _presentShareNotice();
    }
  }

  void _onLauncherAction() {
    if (!mounted ||
        _settingUpConnection ||
        widget.launchIntents?.pendingAction.value == null) {
      return;
    }
    final connection = _connectionForExternalAction();
    if (connection == null) return;
    _entrySession.suppressStartupRestore();
    _navigateToWorkspace(connection);
  }

  @override
  void dispose() {
    _sharedDraft.removeListener(_shareChanged);
    _sharedDraft.dispose();
    _entrySession.removeListener(_entryChanged);
    _entrySession.dispose();
    _backupSession.close();
    widget.launchIntents?.pendingAction.removeListener(_onLauncherAction);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final connection = _entrySession.startupConnection(
      hasPendingShare: _sharedDraft.state.hasPending,
    );
    if (connection != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _navigateToWorkspace(connection);
      });
    }
  }

  Future<void> _navigateToWorkspace(
    SavedConnection conn, {
    AppDestination destination = AppDestination.chats,
    SharedDraftNavigation? incomingSharedDraft,
    bool replaceWorkspace = false,
    ProfileSessionKey? botChat,
    bool Function()? canUse,
  }) async {
    if (canUse != null && !canUse()) return;
    if (_opening ||
        _entrySession.state.opening ||
        (_sharedDraft.state.reviewing && incomingSharedDraft == null)) {
      return;
    }
    final plan =
        incomingSharedDraft?.entry ?? await _entrySession.prepare(conn);
    if (!mounted) return;
    if (plan == null || !_entrySession.isCurrent(plan)) return;
    if (canUse != null && !canUse()) return;
    final controller = plan.controller;
    if (botChat != null && !controller.owns(botChat)) {
      throw StateError(
        'Bot instance changed. Reload Bots before opening its chat.',
      );
    }
    final launchAction = incomingSharedDraft == null
        ? _entrySession.takeLaunchAction(plan)
        : null;
    if (!_entrySession.isCurrent(plan)) return;
    final initialQuickChat = launchAction == AndroidLaunchAction.quickChat;
    if (launchAction != null || replaceWorkspace) {
      final departingRoutes = <Future<dynamic>>[];
      setState(() => _opening = true);
      Navigator.of(context).popUntil((route) {
        if (route.isFirst) return true;
        if (route is TransitionRoute) departingRoutes.add(route.completed);
        return false;
      });
      // Let the previous screen release the shared controller before the new
      // screen claims its visibility and search focus.
      await Future.wait(departingRoutes);
      if (!mounted || !_entrySession.isCurrent(plan)) return;
      setState(() => _opening = false);
    } else if (incomingSharedDraft?.returnToHome == true) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _buildWorkspaceScreen(
          controller: controller,
          connectionManager: widget.connManager,
          shareIntents: widget.shareIntents,
          createBotsSession: widget.createBotsSession,
          onOpenBotChat: selectBotChat,
          initialBotSession: botChat,
          initialGroup: incomingSharedDraft?.group,
          onSelectConnection: selectWorkspaceConnection,
          configurationActions: buildConfigurationActions,
          enableNotifications: widget.enableProfileNotifications,
          backgroundMonitoringState: widget.backgroundMonitoringState,
          openMonitoringBatterySettings: widget.openMonitoringBatterySettings,
          destination: switch (launchAction) {
            AndroidLaunchAction.activity => AppDestination.activity,
            AndroidLaunchAction.quickChat ||
            AndroidLaunchAction.searchChats => AppDestination.chats,
            null =>
              incomingSharedDraft != null ? AppDestination.chats : destination,
          },
          onConnections: () {
            if (mounted) {
              setState(() => _destination = AppDestination.connections);
            }
            Navigator.of(context).popUntil((route) => route.isFirst);
          },
          onPreferencesChanged: widget.onPreferencesChanged,
          initialQuickChat: initialQuickChat,
          initialSearchChats: launchAction == AndroidLaunchAction.searchChats,
        ),
      ),
    );
    _onLauncherAction();
  }

  void _addConnection() => _setupConnection();

  void _editConnection(SavedConnection connection) {
    _setupConnection(existing: connection);
  }

  Future<void> _setupConnection({SavedConnection? existing}) async {
    if (_settingUpConnection) return;
    _settingUpConnection = true;
    final saved = await Navigator.of(context).push<SavedConnection>(
      MaterialPageRoute(
        builder: (_) => ConnectionSetupScreen(
          createSession: () => ConnectionSetupSession(
            initialAccess: existing == null
                ? null
                : widget.connManager.accessFor(existing),
            cloud: HermesCloud(),
            createProbe: DashboardConnectionProbe.new,
            savedConnections: widget.connManager.getConnections,
            onSaveIcon: existing == null
                ? null
                : (icon) => _saveConnectionIcon(existing, icon),
            onSave: (candidate) async {
              if (existing == null) {
                return widget.connManager.saveConnection(
                  candidate.label,
                  candidate.baseUrl,
                  candidate.port,
                  '',
                  icon: candidate.icon,
                  dashboardPrefix: candidate.dashboardPrefix,
                  dashboardProxied: candidate.dashboardProxied,
                  desktopGatewayUrl: candidate.desktopGatewayUrl,
                  dashboardPort: candidate.dashboardPort,
                  dashboardUsername: candidate.dashboardUsername,
                  dashboardPassword: candidate.dashboardPassword,
                  dashboardGrant: candidate.dashboardGrant,
                  cloudInstanceId: candidate.cloudInstanceId,
                  cloudOrganization: candidate.cloudOrganization,
                  gatewayHeaders: candidate.gatewayHeaders,
                );
              }
              await widget.connManager.updateConnection(
                existing.id,
                candidate.label,
                candidate.baseUrl,
                candidate.port,
                '',
                icon: candidate.icon,
                gatewayPrefix: '',
                dashboardPrefix: candidate.dashboardPrefix ?? '',
                dashboardProxied: candidate.dashboardProxied,
                desktopGatewayUrl: candidate.desktopGatewayUrl ?? '',
                dashboardPort: candidate.dashboardPort,
                dashboardUsername: candidate.dashboardUsername ?? '',
                dashboardPassword: candidate.dashboardPassword ?? '',
                dashboardGrant: candidate.dashboardGrant,
                cloudInstanceId: candidate.cloudInstanceId,
                cloudOrganization: candidate.cloudOrganization,
                gatewayHeaders: candidate.gatewayHeaders,
              );
              return widget.connManager.getConnections().firstWhere(
                (c) => c.id == existing.id,
              );
            },
          ),
        ),
      ),
    );
    _settingUpConnection = false;
    if (!mounted) return;
    if (saved != null) {
      _entrySession.suppressStartupRestore();
      _refresh();
      if (existing == null) {
        await _navigateToWorkspace(saved);
      }
    }
    _onSharedText();
    _onLauncherAction();
  }

  final _connectionOwners =
      <SavedConnection, Future<ProfileWorkspaceController>>{};

  Future<void> _saveConnectionIcon(
    SavedConnection connection,
    ConnectionIcon icon,
  ) async {
    await widget.connManager.updateConnectionIcon(connection.id, icon);
    if (mounted) _refresh();
  }

  Future<void> _pickConnectionIcon(SavedConnection connection) =>
      showConnectionIconPicker(
        context,
        connectionName: connection.label,
        initialIcon: connection.icon,
        onSave: (icon) => _saveConnectionIcon(connection, icon),
      );

  Widget _serverIndicator(SavedConnection connection) =>
      FutureBuilder<ProfileWorkspaceController>(
        key: ValueKey(connection),
        future: _connectionOwners.putIfAbsent(
          connection,
          () => _entrySession.controllerFor(connection),
        ),
        builder: (context, snapshot) => ServerConnectionIndicator(
          label: connection.label,
          icon: connection.icon,
          onIconPressed: () => _pickConnectionIcon(connection),
          status: snapshot.data?.connectionStatus,
        ),
      );

  Widget _buildConnectionCard(SavedConnection conn) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: StudioButtonPress(
        child: ListTile(
          horizontalTitleGap: 0,
          leading: _serverIndicator(conn),
          title: Text(conn.label),
          subtitle: Text(
            '${conn.host}:${conn.dashboardPort}${conn.dashboardPrefix ?? ''}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: StudioButtonPress(
            child: PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'delete') {
                  try {
                    await widget.connManager.deleteConnection(conn.id);
                    if (mounted) _refresh();
                  } on CredentialStorageException {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: StudioError(
                          'The saved instance could not be removed safely.',
                        ),
                      ),
                    );
                  }
                } else if (v == 'edit') {
                  _editConnection(conn);
                }
              },
              itemBuilder: (_) => [
                const StudioPopupMenuItem(
                  value: 'edit',
                  child: Text('Edit instance'),
                ),
                StudioPopupMenuItem(
                  value: 'delete',
                  child: Text(
                    'Remove instance',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
          onTap: _opening || _entrySession.state.opening
              ? null
              : () => _navigateToWorkspace(conn),
        ),
      ),
    );
  }

  void _selectDestination(AppDestination destination) {
    if (destination == AppDestination.connections ||
        destination == AppDestination.settings) {
      setState(() => _destination = destination);
      return;
    }
    final connection = _connectionForExternalAction();
    if (connection != null) {
      _navigateToWorkspace(connection, destination: destination);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = _connectionForExternalAction();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_scaffoldKey.currentState?.isDrawerOpen == true) {
            unawaited(SystemNavigator.pop());
          } else {
            _scaffoldKey.currentState?.openDrawer();
          }
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: FutureBuilder<ProfileWorkspaceController>(
          key: ValueKey(connection),
          future: connection == null
              ? null
              : _connectionOwners.putIfAbsent(
                  connection,
                  () => _entrySession.controllerFor(connection),
                ),
          builder: (context, snapshot) => AppDrawer(
            selected: _destination,
            access: connection == null
                ? null
                : widget.connManager.accessFor(connection),
            connectionStatus: snapshot.data?.connectionStatus,
            hasConnection: connection != null,
            onSelected: _selectDestination,
          ),
        ),
        appBar: WingAppBar(
          context: context,

          title:
              _connections.isEmpty && _destination == AppDestination.connections
              ? null
              : Text(_destination.label, maxLines: 6, softWrap: true),
          actions: [
            if (_destination == AppDestination.settings)
              buildConfigurationActions(context),
          ],
        ),
        body: _destination == AppDestination.settings
            ? AppSettingsContent(
                pluginServer: null,
                preferences: widget.appPreferences,
                createVoiceSession: () => VoicePreferencesSession(
                  preferences: widget.appPreferences,
                  device: AndroidVoice.instance,
                  hermesProfileLabel: null,
                  openHermesSettings: null,
                ),
                enableNotifications: widget.enableProfileNotifications,
                backgroundMonitoringState: widget.backgroundMonitoringState,
                openMonitoringBatterySettings:
                    widget.openMonitoringBatterySettings,
                onChanged: () {
                  setState(() {});
                  widget.onPreferencesChanged?.call();
                },
              )
            : StudioLoadingRegion(
                available: true,
                busy: _opening || _entrySession.state.opening,
                label: 'Opening workspace',
                child: Column(
                  children: [
                    if (_sharedDraft.state.hasPending)
                      ListTile(
                        title: const Text('Shared draft ready'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Choose where to add it before sending.',
                            ),
                            Wrap(
                              children: [
                                StudioButtonPress(
                                  child: TextButton(
                                    onPressed: !_sharedDraft.state.canReview
                                        ? null
                                        : _reviewPendingShare,
                                    child: const Text('Review'),
                                  ),
                                ),
                                StudioButtonPress(
                                  child: TextButton(
                                    onPressed:
                                        _sharedDraft.state.reviewing ||
                                            _sharedDraft.state.discarding
                                        ? null
                                        : _discardIncomingShare,
                                    child: const Text('Discard'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: _connections.isEmpty
                          ? WingWelcome(
                              onConnect: _addConnection,
                              onRestore: () => _showRestoreConfig(context),
                            )
                          : Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 720,
                                ),
                                child: ListView.builder(
                                  padding: const EdgeInsets.only(
                                    top: 12,
                                    bottom: 96,
                                  ),
                                  itemCount: _connections.length,
                                  itemBuilder: (_, i) =>
                                      _buildConnectionCard(_connections[i]),
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
        floatingActionButton:
            _destination == AppDestination.connections &&
                _connections.isNotEmpty
            ? StudioButtonPress(
                child: FloatingActionButton(
                  tooltip: 'Add instance',
                  onPressed: _addConnection,
                  child: const Icon(Icons.add),
                ),
              )
            : null,
      ),
    );
  }
}
