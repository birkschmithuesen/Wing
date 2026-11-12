import '../widgets/activity/activity_detail_actions.dart';
import '../widgets/tool_activity_details.dart';
import '../widgets/email_draft_card.dart';
import '../widgets/live_voice_scope.dart';
import '../widgets/anchored_expansion_tile.dart';
import 'package:url_launcher/url_launcher.dart';
import 'administration/admin_hosted_connector_accounts_page.dart';
import '../widgets/hosted_connection_request_panel.dart';
import '../widgets/conversation_page.dart';
import '../widgets/turn_failure_view.dart';
import '../services/git_review_session.dart';
import 'git_review_screen.dart';
import '../widgets/conversation_composer.dart';
import '../widgets/conversation_reading_scope.dart';
import '../widgets/selection_viewport.dart';
import '../theme/wing_icons.dart';
import '../widgets/profile_subagent_panel.dart';
import 'package:wing/core/models/transcript_presentation.dart';
import '../widgets/conversation_activity.dart';
import '../widgets/studio_form_actions.dart';
import '../widgets/profile_live_work_dock.dart';
import '../models/scheduled_task.dart';
import '../services/scheduled_task_detail_session.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'bots/bot_group_screen.dart';
import '../models/group_notification.dart';
import '../widgets/recent_conversations/group_conversation_switcher.dart';
import '../widgets/recent_conversations/conversation_route_scope.dart';
import 'bots/bots_create_screen.dart';
import '../models/recent_conversation.dart';
import '../models/bots.dart';
import 'bots/bot_screen_view.dart';
import 'bots/bot_settings_screen.dart';
import '../services/recent_conversation_session.dart';
import '../services/workspace_recents_session.dart';
import '../widgets/chat_notice_activity_scope.dart';
import '../widgets/recent_conversations/recent_conversation_switcher.dart';
import '../widgets/recent_conversations/conversation_preview.dart';
import '../widgets/wing_app_bar.dart';
import '../widgets/bot_avatar.dart';
import '../widgets/activity/skill_document_viewer.dart';
import '../presentation/skill_document.dart';
import '../models/slash_command.dart';
import '../services/profile_capabilities_session.dart';
import '../models/chat_intelligence.dart';
import '../models/chat_runtime.dart';
import '../services/profile_supervision_session.dart';
import '../widgets/deleted_chat_recovery_notice.dart';
import '../services/chat_browser_data.dart';
import '../services/completion_diagnostics.dart';
import '../models/transcript_timeline.dart';
import '../models/transcript_message.dart';
import '../models/profile_session_key.dart';
import '../models/hermes_profile.dart';
import 'package:wing/core/models/model_choice.dart';
import '../models/side_question_delivery.dart';
import '../services/workspace_connection_failure.dart';
import '../services/attachment_draft_service.dart';
import '../widgets/server_connection_label.dart';
import '../widgets/workspace_picker.dart';
import '../widgets/workspace_profile_navigation.dart';
import '../models/connection.dart';
import '../widgets/studio_error.dart';
import '../widgets/workspace_connection_status.dart';
import 'dart:async';
import '../widgets/mention_suggestions.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import '../services/background_monitoring_service.dart';
import 'package:flutter/services.dart';

import '../services/profile_workspace_controller.dart';
import '../services/server_connection_status.dart';
import '../models/chat_reading.dart';
import '../services/image_clipboard.dart';
import '../widgets/image_paste_menu.dart';
import '../models/composer_action.dart';
import '../widgets/composer_action_button.dart';
import '../widgets/composer_attachment_tile.dart';
import '../presentation/attachment_preview_image.dart';
import '../services/transcript_resource_session.dart';
import '../widgets/profile_message.dart';
import '../widgets/profile_activity_tabs.dart';
import '../widgets/profile_queued_messages.dart';
import '../models/composer_work.dart';
import '../models/answer_versions.dart';
import '../models/chat_output.dart';
import '../widgets/answer_actions.dart';
import '../widgets/gateway_approval_panel.dart';
import '../widgets/gateway_sensitive_prompt_panel.dart';
import '../widgets/gateway_clarify_dialog.dart';
import '../widgets/chat_find_sheet.dart';
import '../theme/profile_workspace_theme.dart';
import '../theme/app_preferences_rendering.dart';
import '../services/app_preferences.dart';
import '../theme/wing_theme.dart';
import '../widgets/chat_intelligence_picker.dart';
import '../widgets/chat_model_confirmation.dart';
import '../widgets/context_ring.dart';
import '../widgets/profile_goal_panel.dart';
import '../widgets/profile_background_work_panel.dart';
import '../widgets/slash_command_suggestions.dart';
import '../widgets/side_question_delivery_card.dart';
import 'profile_workspace_browser.dart';
import 'profile_project_actions.dart';
import 'profile_row_actions.dart';
import 'profile_transcript.dart';
import 'chat_outputs_screen.dart';
import '../widgets/app_drawer.dart';
import 'bots/bots_content.dart';
import '../services/bots_session.dart';
import '../services/bots_repository.dart';
import 'app_settings_content.dart';
import 'analytics_content.dart';
import 'workspace_overview_content.dart';
import '../controllers/voice_input_controller.dart';
import '../widgets/voice_input_activity.dart';
import '../models/voice_processing_settings.dart';
import '../controllers/voice_output_controller.dart';
import '../services/android_voice.dart';
import '../services/voice_preferences_session.dart';
import 'administration/voice_settings_navigation.dart';
import 'administration/provider_access_navigation.dart';

/// Phone workspace with profile selection outside the conversation.
/// Network work and drafts belong to the application controller.
class ProfileWorkspaceScreen extends StatefulWidget {
  final ProfileWorkspaceController controller;
  final bool initialQuickChat;
  final bool initialSearchChats;
  final Future<void> Function()? enableNotifications;
  final ValueListenable<BackgroundMonitoringState>? backgroundMonitoringState;
  final Future<void> Function()? retryBackgroundMonitoring;
  final Future<void> Function()? openMonitoringBatterySettings;
  final VoidCallback? onConnections;
  final Widget Function(BuildContext, VoidCallback onRestored)?
  configurationActions;
  final List<SavedConnection> Function()? savedConnections;
  final Future<void> Function(SavedConnection, AppDestination)?
  onSelectConnection;
  final VoidCallback? onPreferencesChanged;
  final Future<void> Function(ProfileSessionKey)? onCapturePhoto;
  final Future<void> Function(BotGroup)? onCaptureGroupPhoto;
  final BotGroup? initialGroup;
  final AppDestination initialDestination;
  final VoiceDevice? voiceDevice;
  final BotsSession Function()? createBotsSession;
  final Future<void> Function(ProfileSessionKey, bool Function())?
  onOpenBotChat;
  final ProfileSessionKey? initialBotSession;
  final BotRecord? initialBot;
  final ScheduledTaskInvestigationRequest? initialInvestigation;
  const ProfileWorkspaceScreen({
    super.key,
    required this.controller,
    this.initialQuickChat = false,
    this.initialSearchChats = false,
    this.enableNotifications,
    this.backgroundMonitoringState,
    this.retryBackgroundMonitoring,
    this.openMonitoringBatterySettings,
    this.onConnections,
    this.configurationActions,
    this.savedConnections,
    this.onSelectConnection,
    this.onPreferencesChanged,
    this.onCapturePhoto,
    this.onCaptureGroupPhoto,
    this.initialGroup,
    this.initialDestination = AppDestination.chats,
    this.voiceDevice,
    this.createBotsSession,
    this.onOpenBotChat,
    this.initialBotSession,
    this.initialBot,
    this.initialInvestigation,
  });
  @override
  ProfileWorkspaceScreenState createState() => ProfileWorkspaceScreenState();
}

class ProfileWorkspaceScreenState extends State<ProfileWorkspaceScreen>
    with WidgetsBindingObserver {
  ProfileWorkspaceController get controller => widget.controller;
  BotsSession? _botsOwner;
  WorkspaceRecentsSession? _recentsOwner;
  BotsViewState _botsView = const BotsViewState();
  final _senderAppearances =
      <(ProfileSessionKey, String), Future<BotRecord?>>{};
  int _conversationNavigation = 0;
  String? _pendingChatTitle;
  WorkspaceScope? _pendingChatScope;
  String _pendingChatLoadingLabel = 'Opening chat';
  BotRecord? _pendingBot;
  String? _pendingChatError;
  Future<void> Function()? _retryChatEntry;
  WorkspaceRecentsSession? get _borrowedRecents => context
      .getInheritedWidgetOfExactType<RecentConversationRouteScope>()
      ?.recents;
  BotsSession get _bots {
    if (_borrowedRecents case final borrowed?) return borrowed.bots;
    if (_botsOwner == null) {
      final bots = _botsOwner =
          widget.createBotsSession?.call() ??
          BotsSession(
            (canUse) async => [
              BotsRepository.forServer(
                controller.healthSession().server,
                groupObservations: controller.groupObservations,
              ),
            ],
          );
      _recentsOwner = WorkspaceRecentsSession(
        controller,
        bots,
        foreground: _appIsActive,
      );
    }
    return _botsOwner!;
  }

  WorkspaceRecentsSession get _recents {
    if (_borrowedRecents case final borrowed?) return borrowed;
    final bots = _bots;
    return _recentsOwner ??= WorkspaceRecentsSession(
      controller,
      bots,
      foreground: _appIsActive,
    );
  }

  Future<void> _openProfileBotChat(String profile) async {
    if (_destination != AppDestination.chats ||
        controller.current?.chat != null) {
      return;
    }
    final scope = WorkspaceScope(
      connectionId: controller.connection.id,
      connectionIdentity: controller.connectionIdentity,
      profileName: profile,
    );
    await _openConversationDestination(
      (current) => _bots.openProfile(scope, canUse: current),
      title: 'Bot Chat',
      label: 'Opening bot chat',
      owner: scope,
      resumeStoredChat: true,
      origin: AppDestination.chats,
    );
  }

  Future<void> _openBotChat(
    ProfileSessionKey key, {
    AppDestination origin = AppDestination.bots,
  }) => _openConversationDestination(
    (_) async => key,
    title: 'Bot Chat',
    label: 'Opening bot chat',
    owner: key.workspace,
    resumeStoredChat: true,
    origin: origin,
  );

  Future<void> _openBot(
    BotRecord bot, {
    AppDestination origin = AppDestination.bots,
  }) => _openConversationDestination(
    (current) => _bots.open(bot, canUse: current),
    title: bot.title,
    label: 'Opening bot chat',
    owner: bot.scope,
    resumeStoredChat: true,
    bot: bot,
    origin: origin,
  );

  /// Admit the chat destination synchronously, before creation/history/send I/O.
  Future<void> openTaskInvestigation(
    ScheduledTaskInvestigationRequest request,
  ) {
    final workspace = controller;
    ScheduledTaskInvestigationSession? investigation;
    return _openConversationDestination(
      (current) => (investigation ??= ScheduledTaskInvestigationSession(
        request,
        workspace,
      )).open(canUse: current),
      title: 'New chat',
      label: 'Opening investigation chat',
      owner: request.owner,
      resumeStoredChat: false,
      origin: _destination,
    );
  }

  Future<void> _openConversationDestination(
    Future<ProfileSessionKey?> Function(bool Function()) resolve, {
    required String title,
    required String label,
    required WorkspaceScope owner,
    required bool resumeStoredChat,
    BotRecord? bot,
    AppDestination origin = AppDestination.bots,
  }) async {
    if (_destination != origin) return;
    final returnTo = _chatOrigin ?? origin;
    // Enter before identity, resume or history I/O. The captured visit owns
    // completion; leaving the loading screen retires that navigation.
    _selectDestination(AppDestination.chats);
    _chatOrigin = returnTo;
    final navigation = ++_conversationNavigation;
    final workspace = controller;
    bool current() =>
        mounted &&
        identical(controller, workspace) &&
        navigation == _conversationNavigation &&
        _destination == AppDestination.chats;
    setState(() {
      _pendingChatTitle = title;
      _pendingChatScope = owner;
      _pendingChatLoadingLabel = label;
      _pendingBot = bot;
      _pendingChatError = null;
      _retryChatEntry = () => _openConversationDestination(
        resolve,
        title: title,
        label: label,
        owner: owner,
        resumeStoredChat: resumeStoredChat,
        bot: bot,
        origin: AppDestination.chats,
      );
    });
    controller.setRouteVisibility(this, _hasChatFocus);
    try {
      final key = await resolve(current);
      if (!current()) return;
      if (key == null) {
        throw StateError(
          bot == null
              ? 'Chat could not be opened'
              : _bots.state.errors.lastOrNull ?? 'Bot chat could not be opened',
        );
      }
      if (!controller.owns(key)) {
        final open = widget.onOpenBotChat;
        if (open == null) {
          throw StateError('Open this bot from its saved instance');
        }
        await open(key, current);
        if (current()) throw StateError('Bot chat could not be opened');
        return;
      }
      // Creation already selected and initialized the fresh chat. Stored Bot
      // entries still require their canonical resume/history admission.
      final chat = resumeStoredChat
          ? await controller.openSessionForReading(
              key,
              isCurrentRequest: current,
              onReadingAvailable: (chat) {
                if (!current()) return;
                setState(() {
                  _pendingChatTitle = null;
                  _pendingChatScope = null;
                  _pendingBot = null;
                  _retryChatEntry = null;
                });
                controller.setRouteVisibility(this, _hasChatFocus);
              },
            )
          : controller.current?.chat;
      if (!current()) return;
      if (chat == null || (!resumeStoredChat && chat.key != key)) {
        throw StateError('Chat could not be opened');
      }
      setState(() {
        _pendingChatTitle = null;
        _pendingChatScope = null;
        _pendingBot = null;
        _retryChatEntry = null;
      });
      controller.setRouteVisibility(this, _hasChatFocus);
    } catch (error) {
      if (!current()) return;
      setState(
        () => _pendingChatError = error is StateError
            ? error.message.toString()
            : conversationOpeningFailureMessage(error),
      );
    }
  }

  (ProfileWorkspaceController, ChatReadingFocus)? _renderedReadingFocus;
  final _composer = SkillComposerController();
  final _profileNavigation = WorkspaceProfileNavigation();
  final _composerFocus = FocusNode();
  final _chatSearchFocus = FocusNode();
  (ProfileSessionKey, ComposerQueueId?, String)? _steerError;
  final _queuedEditErrors = <ProfileSessionKey, String>{};
  final _traceResources = <TranscriptResourceSession>{};
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _settingsRevision = 0;
  String? _analyticsProfileName;
  ProfileSessionKey? _composerKey;
  Future<BotRecord?>? _conversationBot;
  ProfileSessionKey? _loadingIntelligence;
  final _notificationAnchors = <(ProfileSessionKey, String), GlobalKey>{};
  Widget _notificationAnchor(
    ProfileChat chat,
    String kind,
    String id,
    Widget child,
  ) {
    final key = (chat.key, '$kind:$id');
    return KeyedSubtree(
      key: _notificationAnchors.putIfAbsent(key, GlobalKey.new),
      child: child,
    );
  }

  Map<String, GlobalKey> _chatNotificationAnchors(ProfileChat chat) {
    final ids = <String>[
      if (chat.runtime.error != null &&
          chat.reading.notificationReadTarget?.kind == 'status')
        chat.reading.notificationReadTarget!.identity,
      for (final request in chat.runtime.approvals)
        "approval:${request.requestId}",
      if (chat.runtime.pendingQuestion != null)
        "question:${chat.runtime.pendingQuestion!.requestId}",
      if (chat.runtime.secureInput != null)
        'secure:${chat.runtime.secureInput!.requestId}',
      for (final delivery in chat.sideQuestionDeliveries)
        '${delivery.kind == SideQuestionDeliveryKind.backgroundTask ? 'background' : 'side'}:${delivery.taskId ?? ''}',
    ];
    return {
      for (final id in ids)
        id: _notificationAnchors.putIfAbsent((chat.key, id), GlobalKey.new),
    };
  }

  ProfileSupervisionSession? _supervision;
  ProfileChat? _supervisionChat;
  ProfileSupervisionSession _supervisionFor(ProfileChat chat) {
    if (!identical(_supervisionChat, chat) || _supervision?.active != true) {
      _supervision?.dispose();
      _supervisionChat = chat;
      _supervision = ProfileSupervisionSession(
        controller: controller,
        chat: chat,
      );
    }
    return _supervision!;
  }

  void _supervisionWorkspaceChanged() {
    final current = controller.notificationChat ?? controller.current?.chat;
    if (_supervision != null &&
        (!identical(current, _supervisionChat) || !_supervision!.active)) {
      _supervision!.dispose();
      _supervision = null;
      _supervisionChat = null;
    }
  }

  bool _launchingCamera = false;
  late final _voiceInput = VoiceInputController(
    device: widget.voiceDevice ?? AndroidVoice.instance,
  );
  late final _voiceOutput = VoiceOutputController(
    widget.voiceDevice ?? AndroidVoice.instance,
  );

  void _syncVoiceTarget() {
    final target = controller.voiceTarget;
    _voiceInput.retainTarget(target);
    _voiceOutput.retainTarget(target);
  }

  void _cancelVoice() {
    unawaited(_voiceInput.cancel().catchError((Object _) {}));
    unawaited(_voiceOutput.stop().catchError((Object _) {}));
  }

  VoidCallback? _hermesSpeechSettingsLink(BuildContext context) {
    final profile = controller.current?.scope.profileName;
    if (profile == null) return null;
    final target = controller.administration().profile(profile);
    final status = controller.connectionStatus;
    return () => unawaited(
      _run(
        () => openProfileVoiceSettings(
          context,
          profile: target,
          connectionStatus: status,
        ),
      ),
    );
  }

  Future<void> _requestDictation(ProfileChat chat) async {
    if (LiveVoiceScope.maybeOf(context)?.session.active == true) return;
    final capture = controller.captureVoiceDraft(chat);
    final selection = _composer.selection;
    _composerFocus.unfocus();
    await _voiceInput.dictate(
      target: chat.key,
      draft: VoiceDraft(
        text: capture.text,
        selectionStart: selection.start,
        selectionEnd: selection.end,
      ),
      settings: () => controller.appPreferences.current.voiceInputSettings,
      stopPlayback: _voiceOutput.stop,
      admitsTarget: (target) => controller.admitsDictation(chat, target),
      admitPresentation: () => mounted && _destination == AppDestination.chats,
      createRemote: (target) => controller.voiceForChat(chat, target),
      applyDraft: (text) => controller.applyVoiceDraft(chat, capture, text),
      onApplied: (result) {
        _composer.value = TextEditingValue(
          text: result.text,
          selection: TextSelection.collapsed(offset: result.selectionEnd),
        );
      },
      onNotice: (message) => showStudioError(context, message),
    );
  }

  Future<void> _requestReadAloud(
    ProfileChat chat,
    Map<String, dynamic> message,
  ) => _voiceOutput.readAloud(
    reply: controller.voiceReply(chat, message),
    settings: () => controller.appPreferences.current.voiceOutputSettings,
    cancelDictation: _voiceInput.cancel,
    admitsTarget: (target) => controller.admitsVoice(chat, target),
    admitPresentation: () =>
        mounted && LiveVoiceScope.maybeOf(context)?.session.active != true,
    createRemote: (target) => controller.voiceForChat(chat, target),
    onNotice: (notice) => showStudioError(context, notice),
  );

  Widget _voiceActivity() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      VoiceInputActivity(context: context, controller: _voiceInput),
      if (_voiceOutput.owner != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(
                _voiceOutput.preparing ? 'Preparing speech…' : 'Reading aloud',
              ),
              StudioButtonPress(
                child: TextButton(
                  onPressed: _voiceOutput.stop,
                  child: const Text('Stop speech'),
                ),
              ),
            ],
          ),
        ),
      if (_voiceOutput.error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: StudioError(_voiceOutput.error!),
        ),
    ],
  );

  bool _canPasteImage(ProfileChat chat) =>
      controller.canAddAttachment(chat) && !_launchingCamera;
  late AppDestination _destination;
  AppDestination? _chatOrigin;
  bool _routeIsCurrent = true;
  bool _appIsActive = true;
  RecentConversationSession? _recentVisit, _pendingRecentVisit;
  final _recentSwitcher = GlobalKey<RecentConversationSwitcherState>();
  GlobalKey<ProfileLiveWorkDockState> _liveWorkDock = GlobalKey();
  ProfileChat? _recentRenderedChat;
  bool _conversationObscured = false;
  bool _restoreComposerFocus = false;
  final _composerSelections = <ProfileSessionKey, TextSelection>{};

  void _disposeRecentVisit() {
    _pendingRecentVisit?.dispose();
    _pendingRecentVisit = null;
    _recentVisit?.dispose();
    _recentVisit = null;
    _recentRenderedChat = null;
    _conversationObscured = false;
    _restoreComposerFocus = false;
    _composerSelections.clear();
  }

  SavedConnection? _groupConnection(BotGroup group) =>
      group.scope.connectionIdentity == controller.connectionIdentity
      ? controller.connection
      : widget.savedConnections
            ?.call()
            .where((connection) => connection.id == group.scope.connectionId)
            .firstOrNull;

  ServerConnectionStatus? _groupConnectionStatus(BotGroup group) =>
      _bots.repository(group.scope.connectionIdentity).connectionStatus;

  Widget _recentPreview(RecentConversationCard card) {
    final group = card.entry.group;
    return BotAvatarScope(
      session: _bots,
      prepared: true,
      child: ConversationPreview(
        card: card,
        connectionLabel: group?.instance ?? controller.connection.label,
        connectionIcon: group == null
            ? controller.connection.icon
            : _groupConnection(group)?.icon,
        connectionStatus: group == null
            ? controller.connectionStatus
            : _groupConnectionStatus(group),
      ),
    );
  }

  Future<void> _openGroupChatWindow(
    BuildContext groupContext, {
    required AppDestination origin,
    required ValueChanged<AppDestination> onLeave,
    BotRecord? bot,
  }) => Navigator.of(groupContext).push<void>(
    MaterialPageRoute(
      builder: (_) => RecentConversationRouteScope(
        recents: _recents,
        origin: origin,
        onLeave: onLeave,
        child: ProfileWorkspaceScreen(
          controller: controller,
          initialBot: bot,
          enableNotifications: widget.enableNotifications,
          backgroundMonitoringState: widget.backgroundMonitoringState,
          retryBackgroundMonitoring: widget.retryBackgroundMonitoring,
          openMonitoringBatterySettings: widget.openMonitoringBatterySettings,
          onConnections: widget.onConnections,
          configurationActions: widget.configurationActions,
          savedConnections: widget.savedConnections,
          onSelectConnection: widget.onSelectConnection,
          onPreferencesChanged: widget.onPreferencesChanged,
          onCapturePhoto: widget.onCapturePhoto,
          voiceDevice: widget.voiceDevice,
          createBotsSession: widget.createBotsSession,
          onOpenBotChat: widget.onOpenBotChat,
        ),
      ),
    ),
  );

  Future<void> _openGroupBotChat(
    BuildContext groupContext,
    BotRecord bot,
  ) async {
    if (!mounted ||
        !groupContext.mounted ||
        ModalRoute.isCurrentOf(groupContext) != true) {
      return;
    }
    await _openGroupChatWindow(
      groupContext,
      origin: AppDestination.bots,
      onLeave: _leaveConversation,
      bot: bot,
    );
  }

  Future<void> _openGroupEditorBotChat(
    BuildContext editorContext,
    BotRecord bot,
  ) async {
    if (!mounted ||
        !editorContext.mounted ||
        ModalRoute.isCurrentOf(editorContext) != true) {
      return;
    }
    final editorRoute = ModalRoute.of(editorContext);
    await _openGroupChatWindow(
      editorContext,
      origin: AppDestination.bots,
      bot: bot,
      onLeave: (destination) {
        if (destination != AppDestination.bots) {
          _leaveConversation(destination);
          return;
        }
        controller.showList();
        Navigator.of(editorContext).popUntil((route) => route == editorRoute);
      },
    );
  }

  Future<void> _openRecentGroup(
    BotGroup group, {
    AppDestination origin = AppDestination.activity,
    bool notification = false,
  }) {
    final fromRecents =
        origin == AppDestination.activity || _recentVisit?.modeEnabled == true;
    final route = MaterialPageRoute<void>(
      builder: (groupContext) {
        final status = _groupConnectionStatus(group);
        final connection = _groupConnection(group);
        final discussion = BotAvatarScope(
          session: _bots,
          child: GroupConversationSwitcher(
            groupKey: RecentConversationKey.group(group.key),
            onLeave: () => _leaveConversation(origin),
            onLeaveRecents: () => _leaveConversation(AppDestination.activity),
            createSession: () => controller.groupRecentConversationSession(
              group: group,
              fromRecents: fromRecents,
              recents: _recents,
              onOpenGroup: _openRecentGroup,
              activity: () => ChatNoticeActivityScope.of(groupContext),
              onOpenChat: (_) => _openGroupChatWindow(
                groupContext,
                origin: AppDestination.activity,
                onLeave: _leaveConversation,
              ),
            ),
            previewBuilder: _recentPreview,
            child: BotGroupScreen(
              voiceInputSettings: () =>
                  controller.appPreferences.current.voiceInputSettings,
              voiceDevice: widget.voiceDevice,
              stopVoicePlayback: _voiceOutput.stop,
              createSession: () => _bots.openGroup(group),
              onCapturePhoto: widget.onCaptureGroupPhoto == null
                  ? null
                  : () => widget.onCaptureGroupPhoto!(group),
              onEdit: (group) => openGroupEditor(
                groupContext,
                _bots,
                group,
                onOpenMemberChat: _openGroupEditorBotChat,
              ),
              onOpenBotChat: (bot) => _openGroupBotChat(groupContext, bot),
              onOpenBotSettings: (bot) =>
                  _openBotSettings(bot, routeContext: groupContext),
            ),
          ),
        );
        return status == null
            ? discussion
            : ServerConnectionScope(
                status: status,
                icon: connection?.icon,
                onPickWorkspace: (anchor, {required mode}) =>
                    unawaited(_pickWorkspace(anchor, mode: mode)),
                child: discussion,
              );
      },
    );
    if (notification) _notificationGroup = (key: group.key, route: route);
    return Navigator.of(context).push<void>(route).whenComplete(() {
      if (identical(_notificationGroup?.route, route)) {
        _notificationGroup = null;
      }
    });
  }

  ({String key, Route<void> route})? _notificationGroup;
  Future<void> showNotificationGroup(
    GroupNotificationTarget target,
    bool Function() canUse,
  ) async {
    if (!mounted || !canUse()) return;
    if (target.scope.connectionIdentity != controller.connectionIdentity ||
        target.scope.connectionId != controller.connection.id) {
      throw StateError('Group belongs to another connection');
    }
    if (_notificationGroup?.key == target.key &&
        _notificationGroup!.route.isCurrent) {
      return;
    }
    await _bots.refresh();
    if (!mounted || !canUse()) return;
    final group = _bots.groupForKey(target.key);
    if (group == null) throw StateError('The shared group is unavailable');
    unawaited(_openRecentGroup(group, notification: true));
  }

  Future<void> _openRecentConversation(
    ProfileRecentChat item,
    List<WorkspaceRecentItem> displayed,
  ) => _openConversationDestination(
    (current) async {
      final visit = controller.recentConversationSession(
        recents: _recents,
        entries: displayed.map((item) => item.conversation),
        onOpenGroup: _openRecentGroup,
        activity: ChatNoticeActivityScope.of(context),
      );
      _pendingRecentVisit = visit;
      final opened = await visit.select(RecentConversationKey.chat(item.key));
      if (!current() || _pendingRecentVisit != visit) {
        visit.dispose();
        return null;
      }
      _pendingRecentVisit = null;
      if (!opened) {
        final error =
            visit.error ?? 'Could not open this conversation. Try again.';
        visit.dispose();
        throw StateError(error);
      }
      _recentVisit = visit;
      _recentRenderedChat = controller.current?.chat;
      return item.key;
    },
    title: item.title,
    label: 'Opening chat',
    owner: item.key.workspace,
    resumeStoredChat: false,
    origin: AppDestination.activity,
  );

  Widget _withRecentSwitcher(ProfileChat chat, Widget child) {
    if (_recentVisit?.active != true) {
      _recentVisit?.dispose();
      final route = RecentConversationRouteScope.maybeOf(context);
      _recentVisit = route?.origin != AppDestination.activity
          ? controller.chatRecentConversationSession(
              recents: _recents,
              chat: chat,
              onOpenGroup: _openRecentGroup,
              activity: () => ChatNoticeActivityScope.of(context),
            )
          : controller.recentConversationSession(
              recents: route!.recents,
              entries: route.recents.catalog.entries,
              onOpenGroup: _openRecentGroup,
              activity: ChatNoticeActivityScope.of(context),
            );
      _recentRenderedChat = chat;
    }
    final visit = _recentVisit!;
    return RecentConversationSwitcher(
      key: _recentSwitcher,
      session: visit,
      chatKey: RecentConversationKey.chat(chat.key),
      previewBuilder: _recentPreview,
      gesturesEnabled:
          _hasWorkspaceFocus &&
          !_voiceInput.active &&
          _voiceOutput.owner == null &&
          chat.composer.observation.editingEntry == null,
      nudgesEnabled:
          _hasWorkspaceFocus &&
          !_voiceInput.active &&
          _voiceOutput.owner == null,
      onPresentationChanged: (obscured, stack) {
        final wasObscured = _conversationObscured;
        _conversationObscured = obscured;
        if (stack && _composerFocus.hasFocus) {
          // A focused Android field can retain focus after Back hides its
          // keyboard. Preserve the visible editing state when leaving cards.
          _restoreComposerFocus = MediaQuery.viewInsetsOf(context).bottom > 0;
          _composerFocus.unfocus();
        }
        controller.setRouteVisibility(this, _hasChatFocus);
        if (wasObscured && !obscured) {
          // Recheck actual answer visibility once the normal transcript is
          // revealed. Captures and passive cards never acknowledge a read.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _hasChatFocus) setState(() {});
          });
        }
        if (!obscured && _restoreComposerFocus) {
          _restoreComposerFocus = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _hasChatFocus) _composerFocus.requestFocus();
          });
        }
      },
      child: child,
    );
  }

  bool get _hasWorkspaceFocus => _routeIsCurrent && _appIsActive;

  bool get _hasChatFocus =>
      _hasWorkspaceFocus &&
      _pendingChatTitle == null &&
      _destination == AppDestination.chats &&
      !_conversationObscured;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _routeIsCurrent = isCurrent;
    controller.setRouteVisibility(this, _hasChatFocus);
  }

  @override
  void initState() {
    super.initState();
    _destination = widget.initialDestination;
    if (widget.initialInvestigation case final request?) {
      _destination = AppDestination.chats;
      _pendingChatTitle = 'New chat';
      _pendingChatScope = request.owner;
      _pendingChatLoadingLabel = 'Opening investigation chat';
    }
    if (widget.initialGroup case final group?) {
      _destination = AppDestination.chats;
      _pendingChatTitle = group.name;
      _pendingChatScope = group.scope;
      _pendingChatLoadingLabel = 'Opening group';
      _retryChatEntry = () => _openInitialGroup(group);
    }
    if (widget.initialBot case final bot?) {
      _destination = AppDestination.chats;
      _chatOrigin = AppDestination.bots;
      _pendingChatTitle = bot.title;
      _pendingChatScope = bot.scope;
      _pendingChatLoadingLabel = 'Opening bot chat';
      _pendingBot = bot;
    }
    _appIsActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    controller.addListener(_syncVoiceTarget);
    controller.addListener(_supervisionWorkspaceChanged);
    WidgetsBinding.instance.addObserver(this);
    controller.setRouteMounted(this, true);
    controller.setRouteVisibility(this, _hasChatFocus);
    // Shortcut navigation can reuse an owner still observed by the outgoing
    // route. Start its notifications after both routes finish building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _recents.warmUp();
      unawaited(_enter());
    });
  }

  Future<void> _openInitialGroup(BotGroup group) async {
    if (!mounted || _pendingChatTitle == null) return;
    setState(() => _pendingChatError = null);
    try {
      await _bots.refresh();
      if (!mounted || _pendingChatTitle == null) return;
      final current = _bots.groupForKey(group.key);
      if (current == null) {
        throw StateError(
          'The group could not be opened. Refresh and try again.',
        );
      }
      setState(() {
        _pendingChatTitle = null;
        _pendingChatScope = null;
        _retryChatEntry = null;
      });
      await _openRecentGroup(current);
    } catch (error) {
      if (mounted && _pendingChatTitle != null) {
        setState(() => _pendingChatError = workspaceFailureMessage(error));
      }
    }
  }

  Future<void> _enter() async {
    if (widget.initialInvestigation case final request?) {
      await openTaskInvestigation(request);
      return;
    }
    if (!controller.initialized && controller.notificationChat == null) {
      await controller.initialize();
    }
    if (!mounted || controller.current == null) return;
    if (widget.initialGroup case final group?) {
      await _openInitialGroup(group);
      return;
    }
    if (widget.initialBot case final bot?) {
      await _openBot(bot, origin: AppDestination.chats);
      return;
    }
    if (widget.initialBotSession case final key?) {
      await _openBotChat(key);
      return;
    }
    if (_destination == AppDestination.bots) _bots.setVisible(_appIsActive);
    if (_destination == AppDestination.activity) {
      await _recents.refresh();
    }
    if (widget.initialSearchChats) {
      await controller.navigateProfile(controller.current!.scope.profileName);
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _chatSearchFocus.requestFocus();
      });
    }
    if (widget.initialQuickChat) {
      await _run(() async {
        await controller.createChat(canDispatch: () => mounted);
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ({
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    }.contains(state)) {
      _cancelVoice();
    }
    final active = state == AppLifecycleState.resumed;
    _recentsOwner?.setForeground(active);
    _botsOwner?.setVisible(active && _destination == AppDestination.bots);
    _supervision?.setActive(active);
    if (_appIsActive != active) {
      // A notification handoff can render the answer while inactive. Rebuild
      // on resume so the transcript checks its visibility again.
      setState(() => _appIsActive = active);
    }
    controller.setRouteVisibility(this, _hasChatFocus);
  }

  Future<void> _run(
    Future<void> Function() action, {
    void Function(String)? onFailure,
  }) async {
    try {
      await action();
    } catch (e) {
      if (isTemporaryWorkspaceFailure(e)) {
        unawaited(controller.resumeConnection());
        return;
      }
      if (mounted) {
        final message = switch (e) {
          AttachmentDraftException error => error.message,
          StateError error => error.message.toString(),
          FormatException error => error.message,
          _ => workspaceFailureMessage(e),
        };
        if (onFailure == null) {
          showStudioError(context, message);
        } else {
          onFailure(message);
        }
      }
    }
  }

  @override
  void dispose() {
    _disposeRecentVisit();
    _recentsOwner?.dispose();
    _botsOwner?.dispose();
    _conversationBody.dispose();
    if (_renderedReadingFocus case final rendered?) {
      rendered.$1.releaseReadingFocus(rendered.$2);
    }
    for (final files in _traceResources) {
      files.dispose();
    }
    _traceResources.clear();
    controller.removeListener(_syncVoiceTarget);
    controller.removeListener(_supervisionWorkspaceChanged);
    _supervision?.dispose();
    _voiceInput.dispose();
    _voiceOutput.dispose();
    controller.setRouteVisibility(this, false);
    controller.setRouteMounted(this, false);
    WidgetsBinding.instance.removeObserver(this);
    _profileNavigation.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    _chatSearchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      BotAvatarScope(session: _bots, child: _buildWithAvatars(context));

  Widget _buildWithAvatars(BuildContext context) =>
      ValueListenableBuilder<AppPreferencesState>(
        valueListenable: controller.appPreferences.state,
        builder: (context, preferences, _) => Theme(
          data: profileWorkspaceTheme(
            Theme.of(context),
            accent:
                preferences.values.accent?.appearance ?? WorkspaceAccent.teal,
          ),
          child: ServerConnectionScope(
            key: ValueKey(_destination),
            status: controller.connectionStatus,
            icon: controller.connection.icon,
            profileNavigation: _profileNavigation,
            onPickWorkspace: (anchor, {required mode}) =>
                unawaited(_pickWorkspace(anchor, mode: mode)),
            child: Builder(builder: (context) => _buildWorkspace(context)),
          ),
        ),
      );

  Future<void> _pickWorkspace(
    BuildContext anchor, {
    required WorkspacePickerMode mode,
  }) async {
    if (controller.switching) return;
    final choice = await showWorkspacePicker(
      anchor,
      connections: widget.savedConnections?.call() ?? [controller.connection],
      connectionId: controller.connection.id,
      profiles: controller.discovery?.profiles ?? const [],
      profileName: mode == WorkspacePickerMode.analytics
          ? _analyticsProfileName
          : controller.current?.scope.profileName,
      busy: controller.switching,
      mode: mode,
    );
    if (!mounted || !anchor.mounted || choice == null || controller.switching) {
      return;
    }
    if (mode == WorkspacePickerMode.analytics) {
      if (_analyticsProfileName != choice.id) {
        setState(() => _analyticsProfileName = choice.id);
      }
      return;
    }
    if (choice.kind == WorkspaceChoiceKind.connection &&
        choice.id == controller.connection.id) {
      return;
    }
    if (choice.kind == WorkspaceChoiceKind.profile &&
        choice.id == controller.current?.scope.profileName) {
      return;
    }
    if (choice.kind == WorkspaceChoiceKind.profile) {
      final name = choice.id!;
      if (!_profileNavigation.canRequestSwitch) {
        ScaffoldMessenger.of(anchor).showSnackBar(
          const SnackBar(
            content: Text(
              'Finish or discard your edits before switching profiles.',
            ),
          ),
        );
        return;
      }
      await _run(() async {
        var attempted = false;
        final changed = await _profileNavigation.switchTo(name, () {
          attempted = true;
          _cancelVoice();
          FocusManager.instance.primaryFocus?.unfocus();
          controller.cancelNotificationOpen();
          return controller.switchProfile(
            name,
            resetNavigation: _destination == AppDestination.chats,
          );
        });
        if (!changed &&
            attempted &&
            mounted &&
            anchor.mounted &&
            controller.error != null) {
          showStudioError(anchor, controller.error!);
        }
      });
      return;
    }
    // Connection changes leave this workspace; respect editor guards first.
    final navigator = Navigator.of(context);
    final root = ModalRoute.of(context);
    while (mounted) {
      Route<dynamic>? top;
      navigator.popUntil((route) {
        top = route;
        return true;
      });
      if (top == root) break;
      if (top == null || top!.popDisposition != RoutePopDisposition.pop) {
        await navigator.maybePop();
        return;
      }
      navigator.pop();
    }
    if (!mounted) return;
    _cancelVoice();
    FocusManager.instance.primaryFocus?.unfocus();
    final connection = widget.savedConnections
        ?.call()
        .where((connection) => connection.id == choice.id)
        .firstOrNull;
    if (connection != null && widget.onSelectConnection != null) {
      await _run(() => widget.onSelectConnection!(connection, _destination));
    }
  }

  void _syncComposer(ProfileChat? chat) {
    if (_composerKey != chat?.key ||
        _composer.text != (chat?.composer.observation.displayedText ?? '')) {
      final changedChat = _composerKey != chat?.key;
      if (changedChat) {
        _clearConversationRendering();
        _liveWorkDock = GlobalKey();
        _conversationBot = null;
        _senderAppearances.clear();
      }
      if (changedChat && _recentVisit?.active == true && _composerKey != null) {
        _composerSelections[_composerKey!] = _composer.selection;
      }
      _composerKey = chat?.key;
      _composer.setScope(chat?.key);
      final text = chat?.composer.observation.displayedText ?? '';
      final selection = changedChat ? _composerSelections[chat?.key] : null;
      _composer.value = TextEditingValue(
        text: chat?.composer.observation.displayedText ?? '',
        selection:
            selection != null &&
                selection.isValid &&
                selection.end <= text.length
            ? selection
            : TextSelection.collapsed(offset: text.length),
      );
    }
    _composer.observeReferences(
      chat?.composer.observation.references ?? const [],
    );
  }

  ProfileWorkspaceController? _browserOwner;
  ProfileWorkspaceBrowser? _browser;

  Widget _buildWorkspace(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      controller,
      _voiceInput,
      _voiceOutput,
      ?_recentVisit,
    ]),
    builder: (context, _) {
      if (_pendingChatTitle != null) return _chatOpening(context);
      final current = controller.current;
      final selectedChat = controller.notificationChat ?? current?.chat;
      final chat = _recentVisit?.selecting == true
          ? _recentRenderedChat ?? selectedChat
          : selectedChat;
      if (chat != null &&
          _recentVisit?.active == true &&
          _recentVisit?.selecting != true) {
        _recentRenderedChat = chat;
      }
      _syncComposer(chat);
      if (_destination != AppDestination.chats) {
        _browser = null;
        return _secondaryDestination(context);
      }
      if (chat == null) {
        _bots.setSelectedAvatar(null);
        _disposeRecentVisit();
        // Transcript notifications must not recreate the Chats subtree.
        // The list spans profiles. Capturing a menu's target profile keeps the
        // same visit alive; leaving the list or changing its connection does not.
        if (_browser == null || _browserOwner != controller) {
          _browserOwner = controller;
          _browser = ProfileWorkspaceBrowser(
            key: ValueKey(controller),
            createData: () => ChatBrowserData(controller),
            connectionLabel: controller.connection.label,
            connectionIcon: controller.connection.icon,
            connectionStatus: controller.connectionStatus,
            createColors: controller.createProfileColors,
            deletionRecovery: DeletedChatRecoveryNotice(
              presentation: controller.deletedDraftCleanupPresentation,
            ),
            newProject: _projectDialog,
            onOpenBotChat: _openProfileBotChat,
            drawer: _drawer(),
            searchFocusNode: _chatSearchFocus,
          );
        }
        return _browser!;
      }
      _browser = null;
      _conversationBot ??= _bots.botForConversation(chat.key);
      return ListenableBuilder(
        listenable: _bots,
        builder: (context, _) => FutureBuilder<BotRecord?>(
          future: _conversationBot,
          initialData: _bots.cachedAppearance(chat.key),
          builder: (context, snapshot) {
            final candidate = _bots.cachedAppearance(chat.key);
            final bot = candidate?.describesConversation(chat.key) == true
                ? candidate
                : null;
            return _conversationPage(context, chat, bot);
          },
        ),
      );
    },
  );

  Widget _chatOpening(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leaveChat();
    },
    child: Scaffold(
      key: _scaffoldKey,
      drawer: _drawer(),
      appBar: WingAppBar(
        context: context,
        leading: StudioButtonPress(
          child: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: _leaveChat,
          ),
        ),
        title: WingConversationTitle(title: _pendingChatTitle!),
        contextRow: ServerConnectionLabel(
          label: _pendingBot?.instance ?? controller.connection.label,
          suffix: _pendingBot == null ? _pendingChatScope?.profileName : null,
          icon:
              _pendingBot == null ||
                  _pendingBot!.scope.connectionIdentity ==
                      controller.connectionIdentity
              ? controller.connection.icon
              : null,
          status:
              _pendingBot == null ||
                  _pendingBot!.scope.connectionIdentity ==
                      controller.connectionIdentity
              ? controller.connectionStatus
              : _bots
                    .repository(_pendingBot!.scope.connectionIdentity)
                    .connectionStatus,
        ),
      ),
      body: StudioLoadingRegion(
        busy: _pendingChatError == null,
        available: false,
        label: _pendingChatLoadingLabel,
        child: _pendingChatError == null
            ? const SizedBox.expand()
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: StudioError(_pendingChatError!)),
                    StudioButtonPress(
                      child: IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Retry',
                        onPressed: () => unawaited(_retryChatEntry!()),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    ),
  );

  Future<void> _openBotSettings(
    BotRecord bot, {
    BuildContext? routeContext,
  }) async {
    final target = routeContext ?? context;
    if (!mounted || !target.mounted || ModalRoute.isCurrentOf(target) != true) {
      return;
    }
    final bots = _bots;
    final server = bots.repository(bot.scope.connectionIdentity).server;
    if (server == null) return;
    await Navigator.push<void>(
      target,
      MaterialPageRoute(
        builder: (_) => BotSettingsScreen(
          profile: server.profile(bot.profile.name),
          bot: bot,
          session: bots,
        ),
      ),
    );
    if (!mounted) return;
    bots.invalidateAppearances(bot.scope);
    setState(() => _conversationBot = null);
  }

  final _conversationBody = ValueNotifier<Widget>(const SizedBox.shrink());
  Object? _conversationFrameInputs;
  Widget? _conversationFrame;

  Widget _retainedConversationFrame(
    ProfileChat chat,
    WingAppBar header,
    Widget body,
  ) {
    // Publish the changing reading/composer below the stable Scaffold. The
    // frame retains its own keyboard, navigation and inherited-state listeners.
    _conversationBody.value = body;
    final inputs = (
      controller,
      chat,
      header,
      _destination,
      controller.access,
      controller.connectionStatus,
    );
    if (_conversationFrameInputs == inputs) return _conversationFrame!;
    _conversationFrameInputs = inputs;
    return _conversationFrame = ConversationPage(
      scaffoldKey: _scaffoldKey,
      drawer: _drawer(),
      header: header,
      body: ValueListenableBuilder<Widget>(
        valueListenable: _conversationBody,
        builder: (_, content, _) => content,
      ),
    );
  }

  Object? _conversationHeaderInputs;
  WingAppBar? _conversationHeader;
  WingAppBar _retainedConversationHeader(
    BuildContext context,
    ProfileChat chat,
    BotRecord? bot,
  ) {
    final title = BotConversationTitle(
      title: chat.title,
      bot: bot,
      // The conversation status owns work feedback; retain the face's identity motion.
      mood: BotAvatarMood.idle,
    );
    final canOpenBotSettings =
        bot != null &&
        _bots.repository(bot.scope.connectionIdentity).server != null;
    final parentSessionId = controller.parentSessionId(chat);
    final landscape = ConversationReadingScope.compact(context);
    final reading = ConversationReadingScope.maybeOf(context)?.active == true;
    final compactReading = landscape || reading;
    final stackChatScope =
        !compactReading &&
        bot == null &&
        MediaQuery.textScalerOf(context).scale(12) > 18 &&
        MediaQuery.sizeOf(context).width < 480;
    final canMoveProject =
        !chat.runtime.opening &&
        !chat.runtime.offline &&
        !controller.switching &&
        !(controller.current?.mutatingSessions.contains(chat.key.sessionId) ??
            false);
    void openProjectPicker() => unawaited(
      _run(() async {
        final browser = ChatBrowserData(controller);
        try {
          final issued = browser.chatActionsFor(chat.key);
          try {
            if (mounted) await showChatProjectPicker(context, issued);
          } finally {
            issued.dispose();
          }
        } finally {
          browser.dispose();
        }
      }),
    );
    void openRename() => unawaited(
      _run(() async {
        final browser = ChatBrowserData(controller);
        try {
          final issued = browser.chatActionsFor(chat.key);
          try {
            if (mounted) await showChatRenameDialog(context, issued);
          } finally {
            issued.dispose();
          }
        } finally {
          browser.dispose();
        }
      }),
    );
    final inputs = (
      context,
      chat,
      bot,
      chat.title,
      canOpenBotSettings,
      parentSessionId,
      stackChatScope,
      compactReading,
      reading,
      landscape,
      canMoveProject,
      chat.runtime.opening,
      chat.runtime.offline,
      controller.chatProjectLabel(chat),
      controller.chatProject(chat),
      controller.connection.label,
      controller.connection.icon,
      controller.connectionStatus,
      controller.refreshingWorkspace,
      Theme.of(context),
      MediaQuery.sizeOf(context),
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
    );
    if (_conversationHeaderInputs == inputs) return _conversationHeader!;
    _conversationHeaderInputs = inputs;
    return _conversationHeader = WingAppBar(
      context: context,
      inlineContext: compactReading,

      leading: StudioButtonPress(
        child: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Open navigation menu',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
      ),
      title: canOpenBotSettings
          ? Tooltip(
              message: 'Bot settings',
              child: Semantics(
                button: true,
                child: StudioButtonPress(
                  child: InkWell(
                    onTap: () => _openBotSettings(bot),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: title,
                    ),
                  ),
                ),
              ),
            )
          : Tooltip(
              message: 'Rename chat',
              child: Semantics(
                button: true,
                child: StudioButtonPress(
                  child: InkWell(
                    onTap: openRename,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: title,
                    ),
                  ),
                ),
              ),
            ),
      contextHeight: stackChatScope ? 96 : 48,
      contextRow: reading && !landscape
          ? null
          : LayoutBuilder(
              builder: (context, constraints) {
                final scopeStyle = Theme.of(context).textTheme.labelMedium
                    ?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    );
                final server = ServerConnectionLabel(
                  alignment: Alignment.centerLeft,
                  label: controller.connection.label,
                  icon: controller.connection.icon,
                  status: controller.connectionStatus,
                  style: scopeStyle,
                );
                if (bot != null) return server;
                final unknownOpeningProject =
                    chat.projectId == null &&
                    (chat.runtime.opening || chat.runtime.offline);
                final projectLabel = unknownOpeningProject
                    ? chat.key.workspace.profileName
                    : controller.chatProjectLabel(chat);
                final projectAppearance = unknownOpeningProject
                    ? null
                    : controller.chatProject(chat);
                final project = Tooltip(
                  message: 'Move to project: $projectLabel',
                  child: Semantics(
                    button: true,
                    enabled: canMoveProject,
                    focusable: canMoveProject,
                    onTap: canMoveProject ? openProjectPicker : null,
                    label: '$projectLabel. Move to project',
                    excludeSemantics: true,
                    child: StudioButtonPress(
                      child: InkWell(
                        key: const ValueKey('chat-project-picker'),
                        borderRadius: WingRadius.control,
                        onTap: canMoveProject ? openProjectPicker : null,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: 48,
                            minWidth: 48,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: 1,
                            heightFactor: 1,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (projectAppearance != null) ...[
                                  projectAvatar(
                                    context,
                                    projectAppearance,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Flexible(
                                  child: Text(
                                    projectLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: scopeStyle,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                if (stackChatScope) {
                  return Column(
                    key: const ValueKey('chat-scope-stacked'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [server, project],
                  );
                }
                return Row(
                  key: const ValueKey('chat-scope-inline'),
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(width: constraints.maxWidth * .5, child: server),
                    ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text('·', style: scopeStyle),
                      ),
                    ),
                    Expanded(child: project),
                  ],
                );
              },
            ),
      actions: [
        StudioButtonPress(
          child: PopupMenuButton<String>(
            tooltip: 'Chat actions',
            icon: const Icon(Icons.more_vert),
            onSelected: (action) {
              if (action == 'refresh') {
                unawaited(_run(controller.refresh));
              } else if (action == 'find') {
                unawaited(_openFind(chat));
              } else if (action == 'outputs') {
                unawaited(_run(() => _openOutputs(chat)));
              } else if (action == 'git') {
                final review = GitReviewSession(
                  server: controller.administration(),
                  resolveWorkspace: () => controller.reviewWorkspacePath(chat),
                );
                final scope = chat.title;
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          GitReviewScreen(session: review, scope: scope),
                    ),
                  ),
                );
              } else if (action == 'screen') {
                unawaited(_run(() => _openScreen(chat)));
              } else if (action == 'parent') {
                unawaited(_run(() => controller.openParentChat(chat)));
              }
            },
            itemBuilder: (_) => [
              const StudioPopupMenuItem(
                value: 'screen',
                child: Text('View screen'),
              ),
              const StudioPopupMenuItem(
                value: 'outputs',
                child: Text('Outputs'),
              ),
              const StudioPopupMenuItem(
                value: 'find',
                child: Text('Find in chat'),
              ),
              const StudioPopupMenuItem(
                value: 'git',
                child: Text('Git review'),
              ),
              if (parentSessionId != null)
                const StudioPopupMenuItem(
                  value: 'parent',
                  child: Text('Parent chat'),
                ),
              const PopupMenuDivider(),
              StudioPopupMenuItem(
                value: 'refresh',
                enabled: !controller.refreshingWorkspace,
                child: const Text('Refresh workspace'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _conversationPage(
    BuildContext context,
    ProfileChat chat,
    BotRecord? bot,
  ) => ConversationReadingScope(
    key: ValueKey(('reading', chat.key)),
    builder: (context) => _readingConversationPage(context, chat, bot),
  );

  Widget _readingConversationPage(
    BuildContext context,
    ProfileChat chat,
    BotRecord? bot,
  ) {
    _bots.setSelectedAvatar(bot?.scope);
    final conversation = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (ConversationReadingScope.maybeOf(context)?.active == true) {
            ConversationReadingScope.maybeOf(context)!.exit();
          } else if (_scaffoldKey.currentState?.isDrawerOpen == true) {
            _scaffoldKey.currentState?.closeDrawer();
          } else if (_liveWorkDock.currentState?.dismiss() == true) {
            return;
          } else if (_recentSwitcher.currentState?.dismissStack() == true) {
            return;
          } else if (chat.composer.observation.editingEntry != null) {
            unawaited(_run(() => controller.cancelQueuedPromptEdit(chat)));
          } else {
            _leaveChat();
          }
        }
      },
      child: _retainedConversationFrame(
        chat,
        _retainedConversationHeader(context, chat, bot),
        StudioPageLoading(
          active:
              chat.refreshingConversation ||
              controller.refreshingWorkspace ||
              chat.branchingAnswer ||
              chat.changingIntelligence ||
              _loadingIntelligence == chat.key ||
              chat.composer.observation.saving ||
              chat.composer.observation.steering ||
              chat.runtime.approvalResponding,
          label: chat.refreshingConversation
              ? 'Refreshing conversation'
              : controller.refreshingWorkspace
              ? 'Refreshing workspace'
              : chat.branchingAnswer
              ? 'Preparing answer'
              : chat.composer.observation.steering
              ? 'Steering message'
              : chat.composer.observation.saving
              ? 'Saving message'
              : chat.runtime.approvalResponding
              ? 'Sending approval decision'
              : 'Updating model settings',
          child: StudioLoadingRegion(
            busy: controller.switching || chat.refreshingConversation,
            available:
                !chat.runtime.opening || chat.reading.messages.isNotEmpty,
            label: 'Updating conversation',
            child: Column(
              children: [
                WorkspaceConnectionStatus(
                  status: controller.connectionStatus,
                  showHint:
                      chat.runtime.openingError == null &&
                      (!chat.runtime.opening ||
                          chat.reading.messages.isNotEmpty),
                ),
                if (controller.error != null)
                  MaterialBanner(
                    content: StudioError(controller.error!),
                    actions: [
                      StudioButtonPress(
                        child: TextButton(
                          onPressed: () => _run(controller.retry),
                          child: const Text('Retry'),
                        ),
                      ),
                    ],
                  ),
                if (chat.runtime.openingError != null &&
                    chat.reading.messages.isNotEmpty)
                  MaterialBanner(
                    forceActionsBelow: true,
                    content: StudioError(chat.runtime.openingError!),
                    actions: [
                      StudioButtonPress(
                        child: IconButton(
                          tooltip: 'Retry',
                          onPressed:
                              controller.recovering ||
                                  chat.refreshingConversation
                              ? null
                              : () => _run(
                                  () => controller.retryConversation(chat),
                                ),
                          icon: const Icon(Icons.refresh),
                        ),
                      ),
                    ],
                  ),
                Expanded(child: _chat(chat, context, bot)),
              ],
            ),
          ),
        ),
      ),
    );
    return _withRecentSwitcher(
      chat,
      bot == null
          ? conversation
          : BotConversationScope(
              bot: bot,
              name: bot.title,
              onSenderTap: (anchor) =>
                  unawaited(_openBotSettings(bot, routeContext: anchor)),
              child: conversation,
            ),
    );
  }

  Future<void> _openScreen(ProfileChat chat) async {
    final workspace = controller;
    bool current() =>
        mounted &&
        identical(controller, workspace) &&
        !controller.switching &&
        identical(controller.current?.chat, chat) &&
        _destination == AppDestination.chats;
    final session = await _bots.openScreen(chat.key.workspace, canUse: current);
    if (session == null) return;
    if (!mounted || !current()) {
      session.dispose();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BotScreenView(
          createSession: () => session,
          conversation: workspace,
          readConversation: () =>
              [
                    for (final row in [
                      ...chat.reading.messages,
                      ?chat.reading.streamingMessage,
                    ])
                      TranscriptMessage.fromRow(row),
                  ]
                  .where(
                    (message) =>
                        message.kind == TranscriptMessageKind.dialogue &&
                        message.text.isNotEmpty,
                  )
                  .toList(),
          readRequest: () =>
              chat.runtime.pendingQuestion?.question ??
              (chat.runtime.secureInput != null
                  ? 'The agent needs private input. Return to chat to answer securely.'
                  : chat.runtime.approvals.isNotEmpty
                  ? 'The agent needs your approval. Open the conversation to review it.'
                  : null),
          sendMessage: (text) async {
            if (!current()) {
              throw StateError('This conversation is no longer active.');
            }
            await workspace.queueScreenMessage(chat, text);
          },
        ),
      ),
    );
  }

  Future<void> _openFind(ProfileChat chat) async {
    await showChatFindSheet(
      context,
      createSession: () => controller.openReadingSession(chat),
    );
  }

  ChatReadingFocus? _readingFocus(ProfileChat chat) {
    final focus = controller.readingFocus(chat);
    if (focus != null) {
      _renderedReadingFocus = (controller, focus);
    }
    return focus;
  }

  Future<void> _openOutputs(ProfileChat chat) async {
    final files = _retainTraceResources(chat);
    final ownedFiles = files;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatOutputsScreen(
            chatTitle: chat.title,
            createSession: ownedFiles.createOutputsSession,
          ),
        ),
      );
    } finally {
      _releaseTraceResources(files);
    }
  }

  Future<void> _openAnswerOutput(ProfileChat chat, ChatOutput output) async {
    final files = _retainTraceResources(chat);
    final ownedFiles = files;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatOutputsScreen(
            chatTitle: chat.title,
            initialOutput: output,
            createSession: ownedFiles.createOutputsSession,
          ),
        ),
      );
    } finally {
      _releaseTraceResources(files);
    }
  }

  Future<bool> _downloadAnswerOutput(
    ProfileChat chat,
    ChatOutput output,
  ) async {
    final owner = chat.key;
    final files = _retainTraceResources(chat);
    try {
      return await files.files.downloadAndSave(
        output.path!,
        admitPresentation: () =>
            mounted &&
            controller.current?.chat?.key == owner &&
            ModalRoute.of(context)?.isCurrent == true,
      );
    } finally {
      _releaseTraceResources(files);
    }
  }

  Future<void> _shareToolResource(ProfileChat chat, ChatOutput output) async {
    final owner = chat.key;
    final files = _retainTraceResources(chat);
    try {
      await files.files.downloadAndShare(
        output.path!,
        admitPresentation: () =>
            mounted &&
            controller.current?.chat?.key == owner &&
            ModalRoute.of(context)?.isCurrent == true,
      );
    } finally {
      _releaseTraceResources(files);
    }
  }

  Future<Uint8List> _loadAttachmentImage(ProfileChat chat, String path) async {
    final files = _retainTraceResources(chat);
    try {
      return await files.loadImage(path);
    } finally {
      _releaseTraceResources(files);
    }
  }

  TranscriptResourceSession _retainTraceResources(ProfileChat chat) {
    final files = controller.traceResources(chat.key);
    _traceResources.add(files);
    return files;
  }

  void _releaseTraceResources(TranscriptResourceSession files) {
    if (_traceResources.remove(files)) files.dispose();
  }

  ((ProfileSessionKey, String, String), String)? _approvalError;
  ((ProfileSessionKey, String, String), String)? _composerAnswerError;

  Widget _questionPanel(ProfileChat chat) {
    final payload = chat.runtime.questions!;
    final question = payload.pending!;
    final key = (chat.key, chat.runtime.runtimeId, question.requestId);
    final error = _composerAnswerError;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GatewayClarifyDialog(
          key: ValueKey((chat.key, question.requestId)),
          requests: payload.questions,
          answeredIds: payload.answeredIds,
          lockedAnswers: payload.lockedAnswers,
          onSkip: () => controller.skipClarification(chat, payload),
          onRespond: (answers) =>
              controller.clarifySet(chat, answers, expectedRequest: payload),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (error != null && error.$1 == key)
              Expanded(
                child: StudioError(
                  error.$2,
                  icon: Icons.keyboard_return,
                  framed: false,
                ),
              )
            else
              const Spacer(),
            ListenableBuilder(
              listenable: Listenable.merge([
                controller.composerChanges,
                controller,
              ]),
              builder: (context, _) => StudioButtonPress(
                child: IconButton(
                  tooltip: 'Answer with composer text',
                  onPressed: controller.canAnswerWithComposer(chat)
                      ? () {
                          if (_composerAnswerError != null) {
                            setState(() => _composerAnswerError = null);
                          }
                          _run(
                            () => controller.answerWithComposer(chat),
                            onFailure: (message) {
                              if (!_hasChatFocus ||
                                  controller.current?.chat != chat ||
                                  chat.runtime.runtimeId != key.$2 ||
                                  chat.runtime.pendingQuestion?.requestId !=
                                      key.$3) {
                                return;
                              }
                              setState(
                                () => _composerAnswerError = (key, message),
                              );
                            },
                          );
                        }
                      : null,
                  icon: chat.answeringQuestion
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.keyboard_return),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _answer(
    ProfileChat chat,
    TranscriptTimelineEntry entry, {
    required List<Map<String, dynamic>> capturedRows,
    bool showCopyHeader = true,
    bool allowSavedActions = true,
  }) {
    if (entry.suppressed) return const SizedBox.shrink();
    if (entry.message.kind == TranscriptMessageKind.voice) {
      return ProfileMessage(
        key: ValueKey(entry.presentationId),
        message: entry.message,
        loadImages: false,
      );
    }
    final displayedHistory = capturedRows;
    // Resolve only the captured immutable input used by existing runtime commands.
    // The ordinal itself never admits an execution or a replacement chat.
    final message = displayedHistory[entry.sourceIndex];
    if (entry.message.kind == TranscriptMessageKind.botMessage) {
      final handle = entry.message.senderHandle;
      final appearance = handle == null
          ? null
          : _senderAppearances.putIfAbsent((
              chat.key,
              handle,
            ), () => _bots.appearanceForSender(chat.key.workspace, handle));
      return FutureBuilder<BotRecord?>(
        key: ValueKey((chat.key, entry.presentationId, handle)),
        future: appearance,
        builder: (context, snapshot) => ProfileMessage(
          message: entry.message,
          senderAppearance: snapshot.data,
          loadAttachmentImage: (path) => _loadAttachmentImage(chat, path),
          onOpenRemoteFile: (output) => _openAnswerOutput(chat, output),
          onDownloadRemoteFile: (output) => _downloadAnswerOutput(chat, output),
        ),
      );
    }
    final savedPrompt = allowSavedActions && entry.editablePrompt;
    final savedAnswer = allowSavedActions && entry.branchAnswer;
    final enabled =
        chat.readOnlyReason == null &&
        !chat.runtime.opening &&
        !chat.runtime.offline &&
        !controller.recovering &&
        !chat.runtime.blocksTurnAdmission &&
        !chat.runtime.changingAnswer &&
        !chat.branchingAnswer &&
        !chat.changingIntelligence &&
        !chat.runtime.commandRunning &&
        !controller.switching;
    final body = ProfileMessage(
      key: ValueKey(entry.presentationId),
      message: entry.message,
      showCopyHeader: showCopyHeader,
      onReadAloud: entry.message.role == 'assistant'
          ? () => _run(() => _requestReadAloud(chat, message))
          : null,
      showEditAction: savedPrompt,
      showRestoreAction: savedPrompt,
      onRestore: savedPrompt && controller.canRestoreSavedPrompt(chat, message)
          ? () => _restoreSavedMessage(chat, message)
          : null,
      onEdit: savedPrompt && controller.canEditSavedPrompt(chat, message)
          ? () => _editSavedMessage(chat, message)
          : null,
      actions: savedAnswer
          ? _answerActions(
              chat,
              message,
              enabled: enabled,
              messageId: entry.savedMessageId!,
            )
          : null,
      readingAloud:
          _voiceOutput.owner == controller.voiceReplyKey(chat, message),
      loadAttachmentImage: (path) => _loadAttachmentImage(chat, path),
      attachmentImagesAvailable:
          controller.connectionStatus.access ==
              ConnectionAvailability.available &&
          controller.connectionStatus.phase !=
              ServerConnectionPhase.reconnecting,
      onOpenRemoteFile: (output) => _openAnswerOutput(chat, output),
      onShareRemoteFile: (output) => _shareToolResource(chat, output),
      onDownloadRemoteFile: (output) => _downloadAnswerOutput(chat, output),
    );
    if (chat.reading.isVoiceTaskReply(message)) {
      return AnchoredExpansionTile(
        key: ValueKey((chat.key, entry.presentationId, 'voice-task')),
        title: Text(
          'Hermes task details',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        shape: const Border(),
        collapsedShape: const Border(),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [body],
      );
    }
    return body;
  }

  Widget _answerActions(
    ProfileChat chat,
    Map<String, dynamic> message, {
    required bool enabled,
    required int messageId,
  }) {
    return AnswerActions(
      key: ValueKey('answer-actions-$messageId'),
      busy: chat.runtime.changingAnswer,
      onReadAloud: () => _run(() => _requestReadAloud(chat, message)),
      readingAloud:
          _voiceOutput.owner == controller.voiceReplyKey(chat, message),
      branchUnavailableReason:
          controller.branchAnswerRestriction(chat, message: message) ??
          (chat.runtime.commandRunning
              ? 'Wait for the current command to finish before branching.'
              : null),
      onBranch: controller.canBranchAnswer(chat) && !chat.runtime.commandRunning
          ? () => _openConversationDestination(
              (current) async => (await controller.branchAnswer(
                chat,
                chat.reading.messages.indexWhere(
                  (row) => answerMessageId(row) == messageId,
                ),
                isCurrentRequest: current,
              ))?.key,
              title: 'New chat',
              label: 'Forking chat',
              owner: chat.key.workspace,
              resumeStoredChat: false,
              origin: AppDestination.chats,
            )
          : null,
      onRegenerate: enabled
          ? () => _regenerateSavedAnswer(chat, message)
          : null,
    );
  }

  int _laterUserTurns(ProfileChat chat, Map<String, dynamic> message) {
    final index = chat.reading.messages.indexWhere(
      (row) => answerMessageId(row) == answerMessageId(message),
    );
    if (index < 0) return 0;
    return chat.reading.messages
        .skip(index + 1)
        .where(isHumanAnswerPrompt)
        .length;
  }

  String _revisionImpact(int turns) {
    return turns == 0
        ? 'This answer is replaced and the prompt runs again.'
        : 'This removes $turns later user ${turns == 1 ? 'turn' : 'turns'} and their answers, then runs this prompt again.';
  }

  Future<void> _regenerateSavedAnswer(
    ProfileChat chat,
    Map<String, dynamic> message,
  ) async {
    final laterTurns = _laterUserTurns(chat, message);
    if (laterTurns > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StudioDialog(
          title: const Text('Replace this answer and later work?'),
          content: Text(_revisionImpact(laterTurns)),
          actions: [
            StudioButtonPress(
              child: IconButton(
                tooltip: 'Cancel regeneration',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context, false),
              ),
            ),
            StudioButtonPress(
              child: IconButton(
                tooltip: 'Regenerate and remove later turns',
                icon: const Icon(Icons.refresh),
                onPressed: () => Navigator.pop(context, true),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _run(
      () => controller.branchAnswer(
        chat,
        chat.reading.messages.indexWhere(
          (row) => answerMessageId(row) == answerMessageId(message),
        ),
        regenerate: true,
        expectedLaterTurns: laterTurns,
      ),
    );
  }

  Future<void> _restoreSavedMessage(
    ProfileChat chat,
    Map<String, dynamic> message,
  ) async {
    final confirmed = await showDialog<int>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final laterTurns = _laterUserTurns(chat, message);
          return StudioDialog(
            insetPadding: const EdgeInsets.all(WingSpacing.lg),
            titleTextStyle: Theme.of(context).textTheme.titleMedium,
            title: const Text('Restore to this checkpoint?'),
            scrollable: true,
            content: Text(_revisionImpact(laterTurns)),
            actions: [
              StudioButtonPress(
                child: IconButton(
                  key: const ValueKey('restore-message-cancel'),
                  tooltip: 'Cancel restore',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              StudioButtonPress(
                child: IconButton(
                  key: const ValueKey('restore-message-confirm'),
                  tooltip: 'Restore and rerun',
                  onPressed: controller.canRestoreSavedPrompt(chat, message)
                      ? () => Navigator.pop(context, laterTurns)
                      : null,
                  icon: const Icon(Icons.undo),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != null && mounted) {
      await _run(
        () => controller.restoreSavedPrompt(
          chat,
          message,
          expectedLaterTurns: confirmed,
        ),
      );
    }
  }

  Future<void> _editSavedMessage(
    ProfileChat chat,
    Map<String, dynamic> message,
  ) async {
    var input = answerMessageDisplayText(message);
    final originalText = input.trim();
    var submitting = false;
    String? inlineError;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final laterTurns = _laterUserTurns(chat, message);
            final theme = Theme.of(context);
            final tokens = WingTokens.of(context);
            final canSubmit =
                !submitting &&
                controller.canEditSavedPrompt(chat, message) &&
                input.trim().isNotEmpty &&
                input.trim() != originalText;
            return PopScope(
              canPop: !submitting,
              child: StudioDialog(
                key: const ValueKey('saved-message-edit-dialog'),
                title: Semantics(
                  header: true,
                  child: Text(
                    'Edit message',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                content: SizedBox(
                  width: 480,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Resending replaces this message. ${_revisionImpact(laterTurns)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.muted,
                        ),
                      ),
                      const SizedBox(height: WingSpacing.md),
                      Semantics(
                        label: 'Message text',
                        child: viewportSelection(
                          TextFormField(
                            key: const ValueKey('saved-message-edit-input'),
                            initialValue: input,
                            enabled: !submitting,
                            autofocus: true,
                            minLines: 3,
                            maxLines: 8,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            style: theme.textTheme.bodyLarge,
                            decoration: InputDecoration(
                              fillColor: tokens.surface,
                            ),
                            onChanged: (value) => setDialogState(() {
                              input = value;
                              inlineError = null;
                            }),
                          ),
                        ),
                      ),
                      if (inlineError != null) ...[
                        const SizedBox(height: WingSpacing.md),
                        StudioError(
                          inlineError!,
                          key: const ValueKey('edit-message-error'),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  StudioFormActions(
                    onCancel: submitting
                        ? null
                        : () => Navigator.pop(dialogContext),
                    onConfirm: canSubmit
                        ? () async {
                            setDialogState(() {
                              submitting = true;
                              inlineError = null;
                            });
                            var accepted = false;
                            try {
                              accepted = await controller.editSavedPrompt(
                                chat,
                                message,
                                input,
                                expectedLaterTurns: laterTurns,
                              );
                            } catch (_) {}
                            if (!dialogContext.mounted) return;
                            if (accepted) {
                              Navigator.pop(dialogContext);
                              return;
                            }
                            setDialogState(() {
                              submitting = false;
                              inlineError =
                                  chat.runtime.error ??
                                  'Hermes did not accept the edited message.';
                            });
                          }
                        : null,
                    confirmLabel: 'Replace message and resend',
                    confirmIcon: Icons.send_outlined,
                    destructive: true,
                    busy: submitting,
                    progressLabel: 'Replacing message',
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _chat(ProfileChat chat, BuildContext context, BotRecord? bot) {
    final nearby = controller.nearbyReadingMessages(chat);
    final live = nearby == null ? chat.reading.streamingMessage : null;
    final capturedRows = List<Map<String, dynamic>>.unmodifiable([
      ...(nearby ?? chat.reading.messages),
      ?live,
    ]);
    final groupStarted = CompletionDiagnostics.enabled
        ? CompletionDiagnostics.start()
        : 0;
    final liveAnswering = nearby == null && _liveAnswering(chat);
    final projection = ChatTranscriptProjection(
      savedRows: nearby ?? chat.reading.messages,
      requestActivities: chat.reading.requestActivities,
      readingWindow: nearby != null,
      streamingMessage: live,
      runtime: chat.runtime,
      presentationId: chat.reading.messagePresentationId,
      liveAnswering: liveAnswering,
    );
    final displayRows = projection.rows;
    final voice = LiveVoiceScope.maybeOf(context)?.session;
    final timeline = nearby == null && voice != null
        ? projection.timeline.withVoiceTurns(voice.transcript(chat.key))
        : projection.timeline;
    // Put the following reply's Copy beside its own Activity disclosure. The
    // immutable section identity keeps normal, paged and Find views consistent.
    final activityReplies = <Object, TranscriptTimelineEntry>{};
    for (var i = 0; i + 1 < timeline.sections.length; i++) {
      final section = timeline.sections[i];
      final next = timeline.sections[i + 1];
      final reply = next.messages.last;
      if (section.isActivity &&
          !section.hasLatestReview &&
          !next.isActivity &&
          reply.role == 'assistant' &&
          reply.message.kind == TranscriptMessageKind.dialogue) {
        activityReplies[section.presentationIds.last] = reply;
      }
    }
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.finish(
        'transcript.group_sync',
        groupStarted,
        values: {
          'rows': capturedRows.length,
          'sections': timeline.sections.length,
        },
      );
    }
    final activity = _conversationActivity(
      chat,
      entries: projection.activity,
      beforeMessagePresentationId:
          projection.retainedActivityBeforePresentationId,
    );
    final focus = _readingFocus(chat);
    final content = SkillReaderScope(
      createReader: (document) => controller.skillReader(
        document.readerTarget,
        chat.key.workspace.profileName,
      ),
      child: ConversationLayout(
        needsInput: chat.runtime.needsInput,
        transcript: ProfileTranscript(
          key: ValueKey((
            chat.key,
            _readingFocus(chat)?.offset,
            _readingFocus(chat)?.rowId,
          )),
          presentation: TranscriptPresentation.capture(
            identity: chat.key,
            reader: chat.reading,
            timeline: timeline,
            needsInput: chat.runtime.needsInput,
            turnAdmissionBlocked: chat.runtime.blocksTurnAdmission,
          ),
          openingContent: chat.runtime.opening
              ? ProfileTranscriptOpening(
                  status: controller.connectionStatus,
                  error: chat.runtime.openingError,
                  onRetry: () => controller.retryConversation(chat),
                )
              : null,
          notificationReading: chat.reading,
          onReadThrough: (id) => controller.acknowledgeVisibleReading(chat, id),
          onAnswerRead: (target) =>
              controller.notificationAnswerRead(chat, target),
          onRefreshHistory: () => controller.refreshHistory(chat),
          onLoadOlder: () => controller.loadOlderMessages(chat),
          activityTrailingBuilder: (section) {
            if (bot != null) return null;
            final reply = activityReplies[section.presentationIds.last];
            if (reply == null) return null;
            return reply.streaming
                ? const SizedBox(width: 44, height: 48)
                : ProfileMessage.copyAction(context, reply.message);
          },
          messageBuilder: (entry) => _answer(
            chat,
            entry,
            capturedRows: displayRows,
            showCopyHeader: !activityReplies.values.any(
              (reply) => reply.presentationId == entry.presentationId,
            ),
            allowSavedActions: nearby == null,
          ),
          focusedMessageId: focus?.rowId,
          notificationAnchors: _chatNotificationAnchors(chat),
          onBackToLatest: _readingFocus(chat) == null
              ? null
              : () => controller.backToLatest(chat),
          loadImage: (path) => _loadAttachmentImage(chat, path),
          onOpenResource: (output) => _openAnswerOutput(chat, output),
          onShareResource: (output) => _shareToolResource(chat, output),
          activity: activity,
          additionalActivityTabs: liveAnswering
              ? const []
              : [
                  if (chat.sessionControl?.goal != null ||
                      chat.sessionControl?.loop != null ||
                      chat.sessionControl?.heartbeat != null)
                    ProfileActivityTab(
                      id: 'work',
                      label: 'Work',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (chat.sessionControl?.goal != null)
                            ProfileGoalPanel(
                              key: ValueKey(('goal', chat.key)),
                              session: _supervisionFor(chat),
                            ),
                          if (chat.sessionControl?.loop != null ||
                              chat.sessionControl?.heartbeat != null)
                            ProfileBackgroundWorkPanel(
                              key: ValueKey(('background', chat.key)),
                              session: _supervisionFor(chat),
                            ),
                        ],
                      ),
                    ),
                ],
          tail: [
            if (liveAnswering && chat.sessionControl?.goal != null)
              ProfileGoalPanel(
                key: ValueKey(('goal', chat.key)),
                session: _supervisionFor(chat),
              ),
            if (liveAnswering &&
                (chat.sessionControl?.loop != null ||
                    chat.sessionControl?.heartbeat != null))
              ProfileBackgroundWorkPanel(
                key: ValueKey(('background', chat.key)),
                session: _supervisionFor(chat),
              ),
            if (chat.composer.observation.error case final error?
                when error != chat.runtime.error)
              StudioError(error),
            if (chat.runtime.error != null)
              chat.reading.notificationReadTarget?.kind == 'status'
                  ? _notificationAnchor(
                      chat,
                      'status',
                      chat.reading.notificationReadTarget!.id,
                      _failureView(chat),
                    )
                  : _failureView(chat),
            if (chat.connectionOperation case final operation?)
              HostedConnectionRequestPanel(
                key: ValueKey((chat.key, chat.runtime.runtimeId, operation.id)),
                operation: operation,
                canContinue: controller.canContinueConnectionOperation(
                  chat,
                  operation,
                ),
                canRefresh: controller.canRefreshConnectionOperation(
                  chat,
                  operation,
                ),
                working: chat.connectionOperationWorking,
                onContinue: () =>
                    controller.continueConnectionOperation(chat, operation),
                onRefresh: () =>
                    controller.refreshConnectionOperation(chat, operation),
                onRespond: (target, {required skip, required credentials}) =>
                    controller.respondToConnectionTarget(
                      chat,
                      operation,
                      target,
                      skip: skip,
                      credentials: credentials,
                    ),
                onAuthorize: (target) async {
                  if (!controller.canContinueConnectionOperation(
                        chat,
                        operation,
                      ) ||
                      !target.needsAuthorization) {
                    throw StateError('This connection request has changed.');
                  }
                  if (!await launchUrl(
                    target.connectUrl!,
                    mode: LaunchMode.externalApplication,
                  )) {
                    throw StateError('Authorization could not open.');
                  }
                },
                onOpenAccounts: () {
                  if (!controller.canContinueConnectionOperation(
                    chat,
                    operation,
                  )) {
                    return;
                  }
                  final profile = controller.administration().profile(
                    chat.key.workspace.profileName,
                  );
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => AdminHostedConnectorAccountsPage(
                        profile: profile,
                        suggested: operation.suggested,
                      ),
                    ),
                  );
                },
              ),
            if (chat.runtime.approval != null)
              Builder(
                builder: (context) {
                  final request = chat.runtime.approval!;
                  final key = (
                    chat.key,
                    chat.runtime.runtimeId,
                    request.requestId,
                  );
                  final error = _approvalError;
                  return _notificationAnchor(
                    chat,
                    'approval',
                    request.requestId,
                    GatewayApprovalPanel(
                      key: ValueKey((chat.key, request.requestId)),
                      request: request.request,
                      position: chat.runtime.approvalPosition,
                      total: chat.runtime.approvalTotal,
                      enabled:
                          !chat.runtime.approvalResponding &&
                          !chat.runtime.reconnecting,
                      error: error != null && error.$1 == key ? error.$2 : null,
                      onRespond: (choice) {
                        if (_approvalError != null) {
                          setState(() => _approvalError = null);
                        }
                        _run(
                          () => controller.approve(
                            chat,
                            choice.wireValue,
                            requestId: request.requestId,
                          ),
                          onFailure: (message) {
                            if (!_hasChatFocus ||
                                controller.current?.chat != chat ||
                                chat.runtime.runtimeId != key.$2 ||
                                chat.runtime.approval?.requestId != key.$3) {
                              return;
                            }
                            setState(() => _approvalError = (key, message));
                          },
                        );
                      },
                    ),
                  );
                },
              ),
            if (chat.runtime.secureInput != null)
              Builder(
                builder: (context) {
                  final request = chat.runtime.secureInput!;
                  return _notificationAnchor(
                    chat,
                    'secure',
                    request.requestId,
                    GatewaySensitivePromptPanel(
                      key: ValueKey((
                        chat.key,
                        request.kind,
                        request.requestId,
                      )),
                      request: request,
                      enabled:
                          !chat.runtime.secureResponding &&
                          !chat.runtime.reconnecting,
                      onRespond: (value) => controller.respondSensitivePrompt(
                        chat,
                        value,
                        expectedRequest: request,
                      ),
                    ),
                  );
                },
              ),
            for (final delivery in chat.sideQuestionDeliveries)
              _notificationAnchor(
                chat,
                delivery.kind == SideQuestionDeliveryKind.backgroundTask
                    ? 'background'
                    : 'side',
                delivery.taskId ?? '',
                SideQuestionDeliveryCard(
                  key: ValueKey((
                    chat.key,
                    delivery.kind,
                    delivery.taskId,
                    delivery.state,
                  )),
                  delivery: delivery,
                ),
              ),
            if (chat.runtime.pendingQuestion != null)
              _notificationAnchor(
                chat,
                'question',
                chat.runtime.pendingQuestion!.requestId,
                _questionPanel(chat),
              ),
          ],
        ),
        footerBuilder: (context, constraints) =>
            _composerPanel(chat, constraints),
      ),
    );
    return LiveVoiceChatLocation(
      conversation: RecentConversationKey.chat(chat.key),
      enabled: _hasChatFocus,
      child: EmailDraftScope(
        owner: chat.key,
        read: (reference) => controller.readEmailDraft(chat, reference),
        child: content,
      ),
    );
  }

  Future<void> _inspectSkill(ProfileChat chat, SlashCommand skill) async {
    final resource = controller.current;
    if (!skill.isSkill || resource == null || resource.chat != chat) return;
    final session = ProfileCapabilitiesSession(resource.gateway);
    try {
      final instructions = await session.instructions(skill.text.substring(1));
      if (!mounted ||
          controller.current != resource ||
          resource.chat != chat ||
          instructions == null) {
        return;
      }
      final document = SkillDocument.fromReceived(
        name: instructions.name,
        content: instructions.content,
        sourcePath: instructions.sourcePath,
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SkillDocumentViewer(
            document: document,
            createReader: () => session.reader(document.readerTarget),
          ),
        ),
      );
    } finally {
      session.dispose();
    }
  }

  bool _liveAnswering(ProfileChat chat) =>
      _readingFocus(chat) == null &&
      (chat.runtime.executionActive || chat.runtime.needsInput);

  ConversationActivity _conversationActivity(
    ProfileChat chat, {
    List<ChatActivityEntry>? entries,
    Object? beforeMessagePresentationId,
  }) => ConversationActivity(
    runtime: chat.runtime,
    entries: entries ?? chat.runtime.activityEntries,
    beforeMessagePresentationId: beforeMessagePresentationId,
    todos: chat.currentTodos,
    inspection: _supervisionFor(chat),
    agentsBuilder: () => ProfileSubagentPanel(
      session: _supervisionFor(chat),
      createResources: controller.traceResources,
      embedded: true,
    ),
    live: _liveAnswering(chat),
    taskCount: chat.todoRevision == null ? null : chat.currentTodos.length,
    agentCount: chat.subagentsAvailable ? chat.currentSubagents.length : null,
    processCount:
        chat.currentProcesses.isNotEmpty || chat.processesError != null
        ? chat.currentProcesses.length
        : null,
    processes: ProfileProcessPanel(session: _supervisionFor(chat)),
    processSummary: ListenableBuilder(
      listenable: _supervisionFor(chat),
      builder: (context, _) => ActivityDetailFacts(
        facts: [_supervisionFor(chat).state.processSummary],
      ),
    ),
    onProcessesSelected: _supervisionFor(chat).refreshProcesses,
  );

  bool _showLiveWorkDock(ProfileChat chat) =>
      _conversationActivity(chat).hasDock;

  void _clearConversationRendering() {
    _conversationFrameInputs = _conversationFrame = null;
    _conversationBody.value = const SizedBox.shrink();
    _conversationHeaderInputs = _conversationHeader = null;
    _workDockInputs = _workDock = null;
    _contextRingInputs = _contextRing = null;
    _intelligenceButtonInputs = _intelligenceButton = null;
    _composerFieldInputs = _composerField = null;
    _actionButtonInputs = _actionButton = null;
  }

  Object? _workDockInputs;
  Widget? _workDock;
  Widget _composerWorkDock(ProfileChat chat) {
    final session = _supervisionFor(chat);
    final inputs = (chat, chat.workRevision, session, _liveWorkDock);
    if (_workDockInputs == inputs) return _workDock!;
    _workDockInputs = inputs;
    return _workDock = _conversationActivity(chat).dock(key: _liveWorkDock);
  }

  Object? _contextRingInputs;
  Widget? _contextRing;
  Widget _composerContextRing(ProfileChat chat) {
    final inputs = (
      chat,
      chat.context,
      chat.contextCompressions,
      chat.contextRefreshPending,
      chat.contextError,
    );
    if (_contextRingInputs == inputs) return _contextRing!;
    _contextRingInputs = inputs;
    return _contextRing = ContextRing(
      key: ValueKey(('context-ring', chat.key)),
      occupancy: chat.context,
      compressions: chat.contextCompressions,
      loading: chat.contextRefreshPending,
      error: chat.contextError,
      onRefresh: () =>
          unawaited(controller.refreshContext(chat, userInitiated: true)),
    );
  }

  Object? _intelligenceButtonInputs;
  Widget? _intelligenceButton;
  Widget _composerIntelligenceButton(BuildContext context, ProfileChat chat) {
    final runtime = chat.runtime;
    final enabled =
        !runtime.opening &&
        !runtime.offline &&
        !controller.recovering &&
        !runtime.reconnecting &&
        chat.readOnlyReason == null &&
        !runtime.changingAnswer &&
        !runtime.commandRunning &&
        !controller.switching &&
        !chat.changingIntelligence &&
        _loadingIntelligence == null;
    final observation = controller.modelObservation(chat);
    final inputs = (
      context,
      chat,
      chat.model,
      observation,
      chat.fastMode,
      chat.reasoningEffort,
      chat.pendingIntelligence,
      enabled,
    );
    if (_intelligenceButtonInputs == inputs) return _intelligenceButton!;
    _intelligenceButtonInputs = inputs;
    final controls = ChatIntelligenceButton(
      key: ValueKey(('chat-intelligence', chat.key)),
      model: chat.model ?? 'Model',
      observation: observation,
      fastMode: chat.fastMode,
      onReasoningChanged: (effort) =>
          _run(() => _changeModelControls(chat, reasoning: effort)),
      onFastChanged: (anchor, mode) {
        final errorKey = ('change-chat-fast-mode', chat.key);
        dismissTransientError(anchor, errorKey: errorKey);
        _run(
          () => _changeModelControls(chat, fast: mode),
          onFailure: (message) => showTransientError(
            anchor,
            message,
            errorKey: errorKey,
            icon: Icons.bolt_outlined,
          ),
        );
      },
      reasoningEffort: chat.reasoningEffort ?? 'default',
      onPressed: enabled
          ? () => _run(() => _chooseIntelligence(chat, context))
          : null,
    );
    final pending = chat.pendingIntelligence;
    return _intelligenceButton = pending == null
        ? controls
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              controls,
              Text(
                'Next turn: ${pending.choice.model} · ${pending.reasoningEffort}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          );
  }

  Object? _composerFieldInputs;
  Widget? _composerField;

  Widget _composerTextField(BuildContext context, ProfileChat chat) {
    final scope = LiveVoiceScope.maybeOf(context);
    final compact = ConversationReadingScope.compact(context);
    final keyboard = ConversationReadingScope.compactKeyboard(context);
    final inputs = (
      compact,
      keyboard,
      context,
      chat,
      !_voiceInput.active && chat.composer.actions().canEditText,
      chat.composer.observation.editingEntry != null,
      chat.runtime.blocksTurnAdmission,
      _canPasteImage(chat),
      _voiceInput.canDictate(controller.canDictate(chat)),
      scope?.session,
      scope?.session.active,
      chat.runtime.offline,
      chat.readOnlyReason,
    );
    if (_composerFieldInputs == inputs) return _composerField!;
    _composerFieldInputs = inputs;
    // Native editing listens to its controller. Answer growth does not change
    // field chrome; keep its subtree until an actual field capability changes.
    final field = ConversationComposerField(
      fieldKey: const Key('profile-message-composer'),
      controller: _composer,
      focusNode: _composerFocus,
      enabled: !_voiceInput.active && chat.composer.actions().canEditText,
      contentInsertionConfiguration: _canPasteImage(chat)
          ? ContentInsertionConfiguration(
              allowedMimeTypes: ImageClipboard.mimeTypes,
              onContentInserted: (content) => _run(() async {
                if (!_canPasteImage(chat)) {
                  throw StateError('Wait before adding another image.');
                }
                await controller.addPastedImage(
                  chat,
                  () => ImageClipboard.keyboardImage(content),
                );
              }),
            )
          : null,
      contextMenuBuilder: (context, editableText) {
        if (!_canPasteImage(chat)) {
          return AdaptiveTextSelectionToolbar.editableText(
            editableTextState: editableText,
          );
        }
        return ImagePasteMenu(
          editableText: editableText,
          onPasteImage: () => _run(() async {
            if (!_canPasteImage(chat)) {
              throw StateError('Wait before adding another image.');
            }
            await controller.addPastedImage(chat, ImageClipboard.readImage);
          }),
        );
      },
      onChanged: (value) {
        if (chat.composer.observation.editingEntry != null) {
          _queuedEditErrors.remove(chat.key);
          controller.updateQueuedPromptEdit(chat, value);
          return;
        }
        unawaited(_saveComposerDraft(chat, value));
      },
      microphone: chat.composer.observation.editingEntry == null
          ? _dictationButton(chat)
          : null,
      hintText: chat.composer.observation.editingEntry != null
          ? 'Edit queued message'
          : chat.runtime.blocksTurnAdmission
          ? 'Draft your next message'
          : 'Message Hermes or type /',
    );
    return _composerField = Row(
      children: [
        Expanded(child: field),
        if (chat.composer.observation.editingEntry == null && scope != null)
          StudioButtonPress(
            child: IconButton(
              tooltip: 'Start voice conversation',
              icon: const Icon(Icons.graphic_eq),
              onPressed:
                  scope.session.active ||
                      chat.runtime.offline ||
                      chat.readOnlyReason != null
                  ? null
                  : () => _run(() async {
                      await scope.session.start(
                        controller.liveVoiceConversation(chat),
                        prepare: () async {
                          await _voiceInput.cancel();
                          await _voiceOutput.stop();
                        },
                      );
                    }),
            ),
          ),
      ],
    );
  }

  int _composerSaveRevision = 0;
  ProfileSessionKey? _composerSaveFailedFor;

  Future<void> _saveComposerDraft(ProfileChat chat, String text) async {
    final revision = ++_composerSaveRevision;
    var failed = false;
    try {
      await controller.updateDraft(chat, text);
    } catch (_) {
      failed = true;
    }
    if (!mounted || revision != _composerSaveRevision) return;
    final failure = failed ? chat.key : null;
    if (_composerSaveFailedFor != failure) {
      setState(() => _composerSaveFailedFor = failure);
    }
  }

  Widget _composerPanel(
    ProfileChat chat,
    BoxConstraints constraints,
  ) => ListenableBuilder(
    listenable: controller.composerChanges,
    builder: (context, _) {
      _syncComposer(chat);
      final referenceEdit = chat.composer.observation.editing;
      final composerObservation = chat.composer.observation;
      final composerAttachments =
          composerObservation.editingEntry?.attachments ??
          composerObservation.attachments;
      final attachmentPreparation = composerObservation.attachmentPreparation;
      return ConversationFooter(
        constraints: constraints,
        controller: _composer,
        suggestions: Stack(
          children: [
            if (!chat.runtime.opening &&
                !chat.runtime.offline &&
                !chat.runtime.reconnecting &&
                !chat.runtime.commandRunning &&
                chat.composer.observation.editingEntry == null)
              SingleChildScrollView(
                child: SlashCommandSuggestions(
                  key: ValueKey(chat.key),
                  loadCompletion: (query) =>
                      controller.completeCommand(chat, query),
                  refreshCommands: () => controller.refreshCommandCatalog(chat),
                  saveDraft: (text) => _saveComposerDraft(chat, text),
                  inspectSkill: (skill) => _inspectSkill(chat, skill),
                  composer: _composer,
                ),
              ),
            if (!chat.runtime.commandRunning)
              MentionSuggestions(
                key: ValueKey(('references', chat.key, referenceEdit)),
                composer: _composer,
                composerFocus: _composerFocus,
                load: (query, directory, canRead) => controller.completeMention(
                  chat,
                  query,
                  directory: directory,
                  bots: _bots,
                  canRead: canRead,
                ),
                select: (text, reference) async {
                  if (chat.composer.observation.editing != referenceEdit) {
                    throw StateError('The edited message changed.');
                  }
                  if (referenceEdit != null) {
                    controller.updateQueuedPromptEdit(
                      chat,
                      text,
                      reference: reference,
                    );
                  } else {
                    await controller.updateDraft(
                      chat,
                      text,
                      reference: reference,
                    );
                  }
                },
              ),
          ],
        ),
        child: StudioLoadingRegion(
          busy: chat.runtime.commandRunning,
          available: true,
          label: 'Updating conversation',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _conversationActivity(chat).status(
                key: const ValueKey('profile-activity-status'),
                saving: chat.composer.observation.saving,
              ),
              ProfileQueuedMessages(
                key: ValueKey(('queued-messages', chat.key)),
                work: chat.composer.observation,
                steerErrorFor: (id) {
                  final failure = _steerError;
                  return failure != null &&
                          failure.$1 == chat.key &&
                          failure.$2 == id
                      ? failure.$3
                      : null;
                },
                onOpenActions: (prompt) => _showQueuedActions(chat, prompt),
                onDelete: !chat.composer.actions().canEditQueue
                    ? null
                    : (prompt) => _deleteQueuedPrompt(chat, prompt),
              ),
              ConversationComposer(
                dock: _showLiveWorkDock(chat) ? _composerWorkDock(chat) : null,
                beforeField: [
                  if (chat.planGauge case final gauge?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                      child: Tooltip(
                        message: gauge.resetsAt == null
                            ? gauge.label
                            : '${gauge.label} · Resets ${MaterialLocalizations.of(context).formatShortDate(gauge.resetsAt!.toLocal())} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(gauge.resetsAt!.toLocal()))}',
                        child: Text(
                          '${gauge.label} · ${gauge.usedLabel}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ),
                  if (chat.composer.observation.editingEntry != null)
                    Row(
                      children: [
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Editing queued message',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                        _composerContextRing(chat),
                      ],
                    ),
                  if (composerAttachments.isNotEmpty ||
                      attachmentPreparation != null)
                    ComposerAttachmentStrip(
                      key: ValueKey(('composer-attachments', chat.key)),
                      preparing: attachmentPreparation != null,
                      children: [
                        for (final (index, file) in composerAttachments.indexed)
                          ComposerAttachmentSlot(
                            key: ValueKey(('composer-attachment-slot', index)),
                            child: ComposerAttachmentTile(
                              key: ValueKey(file.id),
                              name: file.name,
                              kind: file.kind,
                              error: file.error,
                              previewImage: file.isImage
                                  ? AttachmentPreviewImage(
                                      chat.composer.preview(file.id),
                                    )
                                  : null,
                              readPreview: file.isImage
                                  ? chat.composer.preview(file.id).readBytes
                                  : null,
                              onRemove:
                                  !controller.canRemoveAttachment(chat, file.id)
                                  ? null
                                  : () => _run(
                                      () => controller.removeAttachment(
                                        chat,
                                        file.id,
                                      ),
                                    ),
                            ),
                          ),
                        if (attachmentPreparation != null)
                          ComposerAttachmentSlot(
                            key: ValueKey((
                              'composer-attachment-slot',
                              composerAttachments.length,
                            )),
                            child: ComposerPendingAttachmentTile(
                              key: const ValueKey(
                                'composer-pending-attachment',
                              ),
                              preparation: attachmentPreparation,
                            ),
                          ),
                      ],
                    ),
                  _voiceActivity(),
                  if (_steerError case (
                    final key,
                    null,
                    final error,
                  ) when key == chat.key)
                    StudioError(error, icon: WingIcons.steer),
                  if (_composerSaveFailedFor == chat.key)
                    const StudioError(
                      'Could not save draft',
                      detail: 'Edit your draft to try again.',
                      icon: Icons.save_outlined,
                    ),
                ],
                field: _composerTextField(context, chat),
                focusNode: _composerFocus,
                primaryAction: _composerActionButton(chat),
                editing: chat.composer.observation.editingEntry != null,
                canCapturePhoto: widget.onCapturePhoto != null,
                onAttach: !controller.canAddAttachment(chat) || _launchingCamera
                    ? null
                    : (choice) => _run(() async {
                        final target = chat.key;
                        if (choice == ComposerAttachmentSource.camera) {
                          if (_launchingCamera) {
                            return;
                          }
                          setState(() => _launchingCamera = true);
                          try {
                            await widget.onCapturePhoto!(target);
                          } finally {
                            if (mounted) {
                              setState(() => _launchingCamera = false);
                            }
                          }
                          return;
                        }
                        final type = choice == ComposerAttachmentSource.photos
                            ? FileType.image
                            : FileType.any;
                        final files = await FilePicker.pickFiles(type: type);
                        if (files.isEmpty) {
                          return;
                        }
                        if (files.any((file) => file.path == null)) {
                          throw const AttachmentDraftException(
                            'A selected file could not be opened. Select the files again.',
                          );
                        }
                        await controller.addAttachments(chat, [
                          for (final file in files)
                            (path: file.path!, name: file.name),
                        ]);
                      }),
                controls: chat.composer.observation.editingEntry != null
                    ? [Expanded(child: _queuedEditActions(chat))]
                    : [
                        _composerContextRing(chat),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _composerIntelligenceButton(context, chat),
                          ),
                        ),
                      ],
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _failureView(ProfileChat chat) {
    final failure = chat.runtime.failure;
    if (failure == null) return StudioError(chat.runtime.error!);
    return TurnFailureView(
      key: ValueKey(('failure', chat.key, failure)),
      failure: failure,
      onContinue: () => controller.continueFailedTurn(chat, failure),
      onChooseModel: () => _chooseIntelligence(chat, context),
      onReviewProvider: () => openProfileProviderAccess(
        context,
        profile: controller.administration().profile(
          chat.key.workspace.profileName,
        ),
        connectionStatus: controller.connectionStatus,
      ),
      onSelectModel: chat.fastMode == null || chat.reasoningEffort == null
          ? null
          : (suggestion) async {
              if (controller.current?.chat != chat ||
                  !identical(chat.runtime.failure, failure)) {
                throw StateError(
                  'This failure belongs to another turn. Review the current chat.',
                );
              }
              return controller.setIntelligence(
                chat,
                ChatIntelligenceSelection(
                  choice: ModelChoice(
                    provider: suggestion.provider,
                    model: suggestion.model,
                  ),
                  reasoningEffort: chat.reasoningEffort!,
                  fastMode: chat.fastMode!,
                ),
                confirmModelChange: (message) async => mounted
                    ? showChatModelConfirmation(context, message: message)
                    : false,
              );
            },
    );
  }

  Future<void> _chooseIntelligence(
    ProfileChat chat,
    BuildContext context,
  ) async {
    setState(() => _loadingIntelligence = chat.key);
    try {
      final options = await controller.loadIntelligence(chat);
      if (!mounted ||
          !context.mounted ||
          controller.current?.chat != chat ||
          controller.switching) {
        return;
      }
      setState(() => _loadingIntelligence = null);
      final choice = options.choices
          .where(
            (choice) =>
                choice.model == chat.model &&
                (chat.provider == null || choice.provider == chat.provider),
          )
          .firstOrNull;
      // Keep an existing model visible even if it is absent from today's catalog.
      final initial =
          choice ??
          ModelChoice(
            provider: chat.provider ?? options.defaultProvider ?? '',
            model: chat.model ?? options.defaultModel,
          );
      await showChatIntelligencePicker(
        context: context,
        choices: options.choices,
        initialChoice: chat.pendingIntelligence?.choice ?? initial,
        initialReasoningEffort:
            chat.pendingIntelligence?.reasoningEffort ??
            chat.reasoningEffort ??
            'medium',
        initialFastMode: chat.fastMode!,
        defaultModel: options.defaultModel,
        defaultProvider: options.defaultProvider,
        profileName: chat.key.workspace.profileName,
        refreshModels: () => controller.refreshModelChoices(chat),
        reviewProviderAccess: () => openProfileProviderAccess(
          context,
          profile: controller.administration().profile(
            chat.key.workspace.profileName,
          ),
          connectionStatus: controller.connectionStatus,
        ),
        onCommit: (selection) async {
          return controller.setIntelligence(
            chat,
            selection,
            confirmModelChange: (message) async {
              if (!mounted || !context.mounted) return false;
              return showChatModelConfirmation(context, message: message);
            },
          );
        },
      );
    } finally {
      if (mounted) setState(() => _loadingIntelligence = null);
    }
  }

  Future<void> _changeModelControls(
    ProfileChat chat, {
    String? reasoning,
    ChatFastMode? fast,
  }) async {
    final choice = controller.modelObservation(chat);
    final mode = chat.fastMode;
    final effort = chat.reasoningEffort;
    if (choice == null || mode == null || effort == null) return;
    await controller.setIntelligence(
      chat,
      ChatIntelligenceSelection(
        choice: choice,
        reasoningEffort: reasoning ?? effort,
        fastMode: fast ?? mode,
      ),
      confirmModelChange: (message) async => mounted
          ? showChatModelConfirmation(context, message: message)
          : false,
    );
  }

  Map<ComposerAction, String?> _composerActionLabels(ProfileChat chat) {
    if (chat.readOnlyReason != null) {
      return {
        for (final action in ComposerAction.values)
          action: 'This history is read-only. Start a new chat to continue.',
      };
    }
    return _voiceInput
        .composerAvailability(chat.composer.actions())
        .map(
          (action, reason) => MapEntry(action, switch (reason) {
            null => null,
            ComposerUnavailableReason.dictation =>
              'Finish or cancel dictation first',
            ComposerUnavailableReason.reconnect =>
              'Reconnect to use this action',
            ComposerUnavailableReason.saving =>
              'Wait for this draft to finish saving',
            ComposerUnavailableReason.preparingAttachment =>
              'Wait for the attachment to finish preparing',
            ComposerUnavailableReason.empty =>
              'Type a message or add an attachment',
            ComposerUnavailableReason.disconnectedCommand =>
              'Reconnect before running a command',
            ComposerUnavailableReason.currentTurn =>
              'Wait for the current turn',
            ComposerUnavailableReason.steering => 'Wait before steering',
            ComposerUnavailableReason.needsRunningTurn =>
              action == ComposerAction.stop
                  ? 'No running turn to stop'
                  : 'Steer needs a running turn',
            ComposerUnavailableReason.textOnly => 'Steer supports text only',
            ComposerUnavailableReason.textRequired => 'Type a message to steer',
            ComposerUnavailableReason.sending =>
              'Wait for the current message to finish sending',
            ComposerUnavailableReason.queueDuringTurn =>
              'Queue a draft during a running turn',
          }),
        );
  }

  Widget _dictationButton(ProfileChat chat) => VoiceInputButton(
    controller: _voiceInput,
    enabled:
        LiveVoiceScope.maybeOf(context)?.session.active != true &&
        _voiceInput.canDictate(controller.canDictate(chat)),
    onPressed: () => _run(() => _requestDictation(chat)),
  );

  Object? _actionButtonInputs;
  Widget? _actionButton;
  Widget _composerActionButton(ProfileChat chat) {
    final actions = chat.composer.actions();
    final primary = actions.primaryAction(
      controller.appPreferences.current.preferredRunningAction,
    );
    final resting = actions.prefersStopAction
        ? ComposerAction.stop
        : primary == null
        ? null
        : ComposerAction.send;
    final unavailable = _composerActionLabels(chat);
    final inputs = (
      chat,
      primary,
      resting,
      unavailable[ComposerAction.send],
      unavailable[ComposerAction.steer],
      unavailable[ComposerAction.stop],
      unavailable[ComposerAction.queue],
    );
    if (_actionButtonInputs == inputs) return _actionButton!;
    _actionButtonInputs = inputs;
    return _actionButton = ComposerActionButton(
      key: ValueKey(chat.key),
      primary: primary,
      resting: resting,
      unavailable: unavailable,
      onSelected: (action) => _performComposerAction(chat, action),
    );
  }

  Future<void> _performComposerAction(
    ProfileChat chat,
    ComposerAction action,
  ) async {
    if (controller.current?.chat != chat ||
        _composerActionLabels(chat)[action] != null) {
      return;
    }
    final text = chat.composer.observation.text.trim();
    switch (action) {
      case ComposerAction.send:
        final notification = await _runValue(() => controller.send(chat));
        if (notification != null &&
            mounted &&
            controller.current?.chat == chat &&
            _destination == AppDestination.chats) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(notification),
                duration: const Duration(seconds: 5),
              ),
            );
        }
      case ComposerAction.stop:
        await _run(() => controller.stop(chat));
      case ComposerAction.queue:
        await _run(() => controller.queuePrompt(chat, text));
      case ComposerAction.steer:
        await _steer(chat, () => controller.steer(chat, text));
    }
  }

  Future<void> _beginQueuedEdit(
    ProfileChat chat,
    ComposerQueueObservation prompt,
  ) => _run(() async {
    _queuedEditErrors.remove(chat.key);
    await controller.beginQueuedPromptEdit(chat, prompt.id);
    if (mounted && controller.current?.chat == chat) {
      _composerFocus.requestFocus();
    }
  });

  Future<void> _runQueuedEdit(
    ProfileChat chat,
    Future<void> Function() action,
  ) async {
    setState(() => _queuedEditErrors.remove(chat.key));
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _queuedEditErrors[chat.key] = switch (error) {
            StateError error => error.message.toString(),
            FormatException error => error.message,
            _ => error.toString(),
          },
        );
      }
    }
  }

  Widget _queuedActionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    String? unavailableReason,
  }) {
    final button = StudioButtonPress(
      child: IconButton(
        tooltip: unavailableReason == null ? label : null,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
    if (unavailableReason == null) return button;
    return Semantics(
      label: label,
      enabled: false,
      child: Tooltip(
        message: unavailableReason,
        triggerMode: TooltipTriggerMode.tap,
        preferBelow: false,
        showDuration: const Duration(seconds: 3),
        margin: const EdgeInsets.symmetric(horizontal: WingSpacing.md),
        child: button,
      ),
    );
  }

  Widget _queuedEditActions(ProfileChat chat) {
    final prompt = chat.composer.observation.editingEntry!;
    final saving = chat.composer.actions().editingBusy;
    final actions = chat.composer.actions();
    final valid = actions.canSaveQueueEdit;
    final queuedActions = chat.composer.queueActions(prompt.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_queuedEditErrors[chat.key] case final error?)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: StudioError(error),
            ),
          if (prompt.serverOwned)
            const Text(
              'Saving a replacement moves it to the end of the queue.',
            ),
          StudioFormActions(
            busy: saving,
            onCancel: () => _run(() => controller.cancelQueuedPromptEdit(chat)),
            cancelLabel: 'Cancel queued message editing',
            onConfirm: !valid
                ? null
                : () => _runQueuedEdit(
                    chat,
                    () => controller.saveQueuedPromptEdit(chat),
                  ),
            confirmLabel: 'Save queued message',
            progressLabel: 'Saving queued message',
            leadingActions: [
              if (queuedActions.supportsSteer)
                _queuedActionButton(
                  label: 'Steer queued message',
                  icon: WingIcons.steer,
                  unavailableReason: queuedActions.steerUnavailableReason,
                  onPressed: saving || !queuedActions.canSteer
                      ? null
                      : () => _runQueuedEdit(chat, () async {
                          final accepted = await controller
                              .steerQueuedPromptEdit(chat);
                          if (!accepted) {
                            throw StateError(
                              'Hermes rejected the steering message.',
                            );
                          }
                        }),
                ),
              if (queuedActions.supportsSteer)
                const SizedBox(width: WingSpacing.sm),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _deleteQueuedPrompt(
    ProfileChat chat,
    ComposerQueueObservation prompt,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StudioDialog(
        title: Text(
          prompt.unknownOutcome
              ? 'Acknowledge unknown outcome?'
              : 'Delete queued instruction?',
        ),
        scrollable: true,
        content: Text(
          [
            prompt.unknownOutcome
                ? 'Hermes cannot determine whether this ran. Acknowledging it releases the queue without running it again.'
                : prompt.serverOwned
                ? 'Cancel delivery of this message to Hermes? It will be removed from the queue.'
                : 'Remove this unsent message from the queue?',
            prompt.text,
            ...prompt.attachments.map((attachment) => attachment.name),
          ].where((part) => part.isNotEmpty).join('\n\n'),
        ),
        actions: [
          StudioFormActions(
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
            confirmLabel: prompt.unknownOutcome
                ? 'Acknowledge unknown outcome'
                : 'Delete queued message',
            confirmIcon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(() => controller.removeQueuedPrompt(chat, prompt.id));
    }
  }

  Future<void> _showQueuedActions(
    ProfileChat chat,
    ComposerQueueObservation prompt,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      requestFocus: false,
      builder: (sheetContext) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final actions = chat.composer.queueActions(prompt.id);
          final current = chat.composer.observation.queue
              .where((row) => identical(row.id, prompt.id))
              .firstOrNull;
          final selected = current ?? prompt;
          final media = MediaQuery.of(context);
          return Padding(
            padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (media.size.height - media.viewInsets.bottom - 24)
                      .clamp(0.0, media.size.height),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Queued message',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          if (selected.text.isNotEmpty)
                            ToolDetailCopyButton(
                              label: 'Copy queued message',
                              text: selected.text,
                            ),
                          StudioButtonPress(
                            child: IconButton(
                              tooltip: 'Close queued message actions',
                              onPressed: () => Navigator.pop(sheetContext),
                              icon: const Icon(Icons.close),
                            ),
                          ),
                        ],
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (current == null)
                                const Text(
                                  'This message is no longer in the queue.',
                                ),
                              if (selected.unknownOutcome)
                                const Text(
                                  'Hermes cannot determine whether this message ran. Acknowledge the outcome to release the queue without running it again.',
                                ),
                              if (selected.submissionUncertain)
                                const Text(
                                  'Delivery is unconfirmed. Check conversation history before retrying.',
                                ),
                              if (selected.text.isNotEmpty)
                                viewportSelection(SelectableText(selected.text)),
                              if (selected.attachments.isNotEmpty)
                                Text(
                                  selected.attachments
                                      .map((file) => file.name)
                                      .join(', '),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (actions.supportsEdit)
                            _queuedActionButton(
                              label: 'Edit queued message',
                              icon: Icons.edit_outlined,
                              unavailableReason: actions.editUnavailableReason,
                              onPressed: actions.canEdit
                                  ? () => Navigator.pop(sheetContext, 'edit')
                                  : null,
                            ),
                          if (actions.supportsSteer)
                            _queuedActionButton(
                              label: 'Steer queued message',
                              icon: WingIcons.steer,
                              unavailableReason: actions.steerUnavailableReason,
                              onPressed: actions.canSteer
                                  ? () => Navigator.pop(sheetContext, 'steer')
                                  : null,
                            ),
                          if (actions.supportsDelete)
                            _queuedActionButton(
                              label: selected.unknownOutcome
                                  ? 'Acknowledge unknown outcome'
                                  : 'Delete queued message',
                              icon: selected.unknownOutcome
                                  ? Icons.check
                                  : Icons.delete_outline,
                              unavailableReason:
                                  actions.deleteUnavailableReason,
                              onPressed: actions.canDelete
                                  ? () => Navigator.pop(sheetContext, 'delete')
                                  : null,
                            ),
                          if (chat.composer.observation.paused)
                            StudioButtonPress(
                              child: IconButton(
                                tooltip: 'Resume queued messages',
                                onPressed:
                                    chat.composer.actions().canResumeQueue
                                    ? () =>
                                          Navigator.pop(sheetContext, 'resume')
                                    : null,
                                icon: const Icon(Icons.play_arrow),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || action == null || controller.current?.chat != chat) return;
    switch (action) {
      case 'edit':
        await _beginQueuedEdit(chat, prompt);
      case 'steer':
        await _steer(
          chat,
          () => controller.steerQueuedPrompt(chat, prompt.id),
          queued: prompt.id,
        );
      case 'delete':
        await _deleteQueuedPrompt(chat, prompt);
      case 'resume':
        await _run(() => controller.resumeQueue(chat));
    }
  }

  Future<void> _steer(
    ProfileChat chat,
    Future<bool> Function() submit, {
    ComposerQueueId? queued,
  }) async {
    if (_steerError != null) setState(() => _steerError = null);
    String? error;
    try {
      if (!await submit()) error = 'Hermes rejected the steering message.';
    } catch (failure) {
      error = switch (failure) {
        StateError error => error.message.toString(),
        _ => workspaceFailureMessage(failure),
      };
    }
    if (error != null && mounted && controller.current?.chat == chat) {
      final message = error;
      setState(() => _steerError = (chat.key, queued, message));
    }
  }

  Future<T?> _runValue<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      if (mounted) {
        showStudioError(context, e.toString());
      }
      return null;
    }
  }

  void _handleBack() {
    if (_scaffoldKey.currentState?.isDrawerOpen == true) {
      unawaited(SystemNavigator.pop());
    } else {
      _scaffoldKey.currentState?.openDrawer();
    }
  }

  Widget _drawer() => AppDrawer(
    selected: _destination,
    access: controller.access,
    connectionStatus: controller.connectionStatus,
    onSelected: (destination) {
      if (destination == AppDestination.chats) {
        _leaveConversation(AppDestination.chats);
      } else {
        _selectDestination(destination);
      }
    },
  );

  void _leaveChat() {
    if (_recentSwitcher.currentState?.dismissStack() == true) return;
    final origin =
        _chatOrigin ??
        RecentConversationRouteScope.maybeOf(context)?.origin ??
        AppDestination.chats;
    _leaveConversation(
      _recentVisit?.modeEnabled == true ? AppDestination.activity : origin,
    );
  }

  void _leaveConversation(AppDestination destination) {
    final borrowed = RecentConversationRouteScope.maybeOf(context);
    if (borrowed != null) {
      _conversationNavigation++;
      _disposeRecentVisit();
      borrowed.onLeave(destination);
      return;
    }
    final workspaceRoute = ModalRoute.of(context);
    _disposeRecentVisit();
    controller.showList();
    _selectDestination(destination);
    Navigator.of(context).popUntil((route) => route == workspaceRoute);
  }

  void _selectDestination(AppDestination destination) {
    _conversationNavigation++;
    _pendingChatTitle = null;
    _pendingChatScope = null;
    _pendingBot = null;
    _pendingChatError = null;
    _retryChatEntry = null;
    _conversationBot = null;
    _disposeRecentVisit();
    _chatOrigin = null;
    _cancelVoice();
    FocusManager.instance.primaryFocus?.unfocus();
    if (destination == AppDestination.connections) {
      if (widget.onConnections != null) {
        widget.onConnections!();
      } else {
        Navigator.of(context).maybePop();
      }
      return;
    }
    setState(() => _destination = destination);
    if (destination == AppDestination.bots) {
      _bots.setVisible(_appIsActive);
    } else {
      _botsOwner?.setVisible(false);
    }
    controller.setRouteVisibility(this, _hasChatFocus);
    if (destination == AppDestination.activity) {
      unawaited(_run(_recents.refresh));
    }
  }

  /// Bring a reused workspace route back to its chat after a notification tap.
  void showNotificationChat() {
    _disposeRecentVisit();
    _chatOrigin = null;
    setState(() {});
    if (_destination != AppDestination.chats) {
      _selectDestination(AppDestination.chats);
    }
    controller.setRouteVisibility(this, _hasChatFocus);
  }

  Widget _instanceHeader() => Align(
    alignment: Alignment.centerLeft,
    child: ServerConnectionLabel(
      label: controller.connection.label,
      icon: controller.connection.icon,
      status: controller.connectionStatus,
    ),
  );

  Widget _secondaryDestination(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _handleBack();
    },
    child: Scaffold(
      key: _scaffoldKey,
      drawer: _drawer(),
      appBar:
          _destination == AppDestination.administration ||
              _destination == AppDestination.bots
          ? null
          : WingAppBar(
              context: context,

              title: Text(_destination.label, maxLines: 6, softWrap: true),
              contextRow: _destination == AppDestination.analytics
                  ? Row(
                      children: [
                        Flexible(child: _instanceHeader()),
                        const SizedBox(width: 16),
                        Flexible(
                          child: WorkspaceProfilePicker(
                            label: _analyticsProfileName == null
                                ? 'All'
                                : controller.discovery
                                          ?.named(_analyticsProfileName!)
                                          ?.label ??
                                      _analyticsProfileName!,
                            onPressed: (anchor) => unawaited(
                              _pickWorkspace(
                                anchor,
                                mode: WorkspacePickerMode.analytics,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _destination == AppDestination.activity ||
                        _destination == AppDestination.health
                  ? ServerConnectionLabel(
                      label: controller.connection.label,
                      icon: controller.connection.icon,
                      suffix: _destination == AppDestination.activity
                          ? null
                          : controller.current?.scope.profileName,
                      status: controller.connectionStatus,
                    )
                  : null,
              actions: [
                if (_destination == AppDestination.settings &&
                    widget.configurationActions != null)
                  widget.configurationActions!(context, () {
                    if (mounted) setState(() => _settingsRevision++);
                  }),
              ],
            ),
      body: StudioLoadingRegion(
        available: true,
        busy:
            controller.switching &&
            _destination != AppDestination.bots &&
            _destination != AppDestination.settings &&
            _destination != AppDestination.administration,
        label: 'Updating conversation',
        child: Column(
          children: [
            if (_destination != AppDestination.bots &&
                _destination != AppDestination.settings &&
                _destination != AppDestination.administration)
              WorkspaceConnectionStatus(status: controller.connectionStatus),
            if (controller.error != null &&
                _destination != AppDestination.bots &&
                _destination != AppDestination.settings &&
                _destination != AppDestination.administration)
              ListTile(
                title: StudioError(controller.error!),
                trailing: StudioButtonPress(
                  child: TextButton(
                    onPressed: () => _run(controller.retry),
                    child: const Text('Retry'),
                  ),
                ),
              ),
            Expanded(
              child: switch (_destination) {
                AppDestination.bots => BotsContent(
                  session: _bots,
                  instanceHeader: _instanceHeader(),
                  viewState: _botsView,
                  onViewChanged: (view) => setState(() => _botsView = view),
                  onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
                  onOpenChat: _openBot,
                  onOpenGroupMemberChat: _openGroupEditorBotChat,
                  onOpenGroup: (group) =>
                      _openRecentGroup(group, origin: AppDestination.bots),
                ),
                AppDestination.analytics => HermesAnalyticsContent(
                  key: ValueKey(controller.connectionIdentity),
                  controller: controller,
                  profileName: _analyticsProfileName,
                ),
                AppDestination.settings => AppSettingsContent(
                  pluginServer: controller.administration(),
                  key: ValueKey(_settingsRevision),
                  preferences: controller.appPreferences,
                  createVoiceSession: () => VoicePreferencesSession(
                    preferences: controller.appPreferences,
                    device: AndroidVoice.instance,
                    hermesProfileLabel: controller.current?.scope.profileName,
                    openHermesSettings: _hermesSpeechSettingsLink(context),
                  ),
                  enableNotifications: widget.enableNotifications,
                  backgroundMonitoringState: widget.backgroundMonitoringState,
                  retryBackgroundMonitoring: widget.retryBackgroundMonitoring,
                  openMonitoringBatterySettings:
                      widget.openMonitoringBatterySettings,
                  onChanged: () {
                    setState(() {});
                    widget.onPreferencesChanged?.call();
                  },
                ),
                AppDestination.activity => WorkspaceActivityContent(
                  recents: _recents,
                  visible: _appIsActive && _routeIsCurrent,
                  onOpenGroup: _openRecentGroup,
                  onOpen: (item, displayed) => unawaited(
                    _run(() => _openRecentConversation(item, displayed)),
                  ),
                ),
                AppDestination.health => HermesHealthContent(
                  onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
                  key: ValueKey(controller.connectionIdentity),
                  controller: controller,
                  onInvestigate: (request) =>
                      unawaited(openTaskInvestigation(request)),
                  onOpenSession: (key) async {
                    await controller.openSession(
                      key,
                      propagateHistoryFailure: true,
                    );
                    if (mounted) _selectDestination(AppDestination.chats);
                  },
                  onConnections: () =>
                      _selectDestination(AppDestination.connections),
                ),
                _ => HermesAdministrationContent(
                  onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
                  key: ValueKey(controller.connectionIdentity),
                  controller: controller,
                  onInvestigate: (request) =>
                      unawaited(openTaskInvestigation(request)),
                  onOpenSession: (key) async {
                    await controller.openSession(
                      key,
                      propagateHistoryFailure: true,
                    );
                    if (mounted) _selectDestination(AppDestination.chats);
                  },
                  onConnections: () =>
                      _selectDestination(AppDestination.connections),
                ),
              },
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _projectDialog(ChatBrowserData browser) => browser.createProject(
    showEditor: (createFolders, loadDefaultFolder, create) {
      if (!mounted) return Future.value();
      return showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ProjectEditorDialog.create(
          loadDefaultFolder: loadDefaultFolder,
          createFolders: createFolders,
          save: create,
        ),
      );
    },
  );
}
