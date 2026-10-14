import '../models/side_question_delivery.dart';
import '../services/workspace_connection_failure.dart';
import '../widgets/server_connection_label.dart';
import '../widgets/workspace_picker.dart';
import '../widgets/workspace_profile_navigation.dart';
import '../models/connection.dart';
import '../widgets/studio_action_label.dart';
import '../widgets/studio_error.dart';
import '../widgets/workspace_connection_status.dart';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import '../services/background_monitoring_service.dart';
import 'package:flutter/services.dart';

import '../services/profile_workspace_controller.dart';
import '../services/image_clipboard.dart';
import '../widgets/image_paste_menu.dart';
import '../models/composer_action.dart';
import '../widgets/composer_action_button.dart';
import '../widgets/composer_attachment_tile.dart';
import '../services/remote_files_client.dart';
import '../services/remote_file_saver.dart';
import '../widgets/profile_message.dart';
import '../widgets/profile_transcript_disclosure.dart';
import '../widgets/anchored_expansion_tile.dart';
import '../widgets/profile_activity_tabs.dart';
import '../models/gateway_todo.dart';
import '../widgets/profile_queued_messages.dart';
import '../models/queued_prompt_draft.dart';
import '../models/answer_versions.dart';
import '../models/transcript_notice.dart';
import '../models/chat_output.dart';
import '../widgets/answer_actions.dart';
import '../models/gateway_clarify.dart';
import '../models/gateway_approval.dart';
import '../widgets/gateway_approval_panel.dart';
import '../widgets/gateway_sensitive_prompt_panel.dart';
import '../widgets/gateway_clarify_dialog.dart';
import '../widgets/chat_find_sheet.dart';
import '../theme/profile_workspace_theme.dart';
import '../theme/wing_theme.dart';
import '../widgets/profile_activity_status.dart';
import '../widgets/chat_intelligence_picker.dart';
import '../widgets/model_chooser.dart';
import '../widgets/chat_model_confirmation.dart';
import '../widgets/context_ring.dart';
import '../widgets/profile_execution_activity.dart';
import '../widgets/profile_subagent_panel.dart';
import '../widgets/profile_goal_panel.dart';
import '../widgets/profile_background_work_panel.dart';
import '../widgets/project_folder_picker.dart';
import '../widgets/slash_command_suggestions.dart';
import '../widgets/side_question_delivery_card.dart';
import 'profile_workspace_browser.dart';
import 'profile_row_actions.dart';
import 'profile_transcript.dart';
import 'chat_outputs_screen.dart';
import '../widgets/app_drawer.dart';
import 'app_settings_content.dart';
import 'analytics_content.dart';
import 'administration/admin_widgets.dart' show adminToolbarHeight;
import 'workspace_overview_content.dart';
import '../controllers/voice_input_controller.dart';
import '../controllers/voice_output_controller.dart';
import '../services/android_voice.dart';
import '../services/hermes_voice.dart';
import '../services/voice_preferences.dart';
import 'administration/voice_settings_navigation.dart';
import 'administration/provider_access_navigation.dart';
import '../../car_mode/car_mode_bridge.dart';
import '../../car_mode/car_mode_session.dart';
import '../../car_mode/car_mode_state.dart';

enum _AttachmentChoice { camera, photos, files }

/// Phone workspace with profile selection outside the conversation.
/// Network work and drafts belong to the application controller.
class ProfileWorkspaceScreen extends StatefulWidget {
  final ProfileWorkspaceController controller;
  final bool initialQuickChat;
  final bool initialSearchChats;
  final Future<void> Function()? enableNotifications;
  final ValueListenable<BackgroundMonitoringState>? backgroundMonitoringState;
  final Future<void> Function()? openMonitoringBatterySettings;
  final VoidCallback? onConnections;
  final Widget Function(BuildContext, VoidCallback onRestored)?
  configurationActions;
  final List<SavedConnection> Function()? savedConnections;
  final Future<void> Function(SavedConnection, AppDestination)?
  onSelectConnection;
  final VoidCallback? onPreferencesChanged;
  final Future<void> Function(ProfileSessionKey)? onCapturePhoto;
  final AppDestination initialDestination;
  final VoiceDevice? voiceDevice;
  const ProfileWorkspaceScreen({
    super.key,
    required this.controller,
    this.initialQuickChat = false,
    this.initialSearchChats = false,
    this.enableNotifications,
    this.backgroundMonitoringState,
    this.openMonitoringBatterySettings,
    this.onConnections,
    this.configurationActions,
    this.savedConnections,
    this.onSelectConnection,
    this.onPreferencesChanged,
    this.onCapturePhoto,
    this.initialDestination = AppDestination.chats,
    this.voiceDevice,
  });
  @override
  ProfileWorkspaceScreenState createState() => ProfileWorkspaceScreenState();
}

class ProfileWorkspaceScreenState extends State<ProfileWorkspaceScreen>
    with WidgetsBindingObserver {
  ProfileWorkspaceController get controller => widget.controller;
  final _composer = TextEditingController();
  final _profileNavigation = WorkspaceProfileNavigation();
  final _composerFocus = FocusNode();
  final _chatSearchFocus = FocusNode();
  final _queuedEditErrors = <ProfileSessionKey, String>{};
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _settingsRevision = 0;
  ProfileSessionKey? _composerKey;
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
      if (chat.error != null && chat.notificationReadTarget?.kind == 'status')
        chat.notificationReadTarget!.identity,
      for (final request in chat.approvals.requests)
        "approval:${request['request_id']}",
      if (chat.pendingQuestion != null)
        "question:${chat.pendingQuestion!['request_id']}",
      if (chat.sensitivePrompt != null)
        'secure:${chat.sensitivePrompt!.requestId}',
      for (final delivery in chat.sideQuestionDeliveries)
        '${delivery.kind == SideQuestionDeliveryKind.backgroundTask ? 'background' : 'side'}:${delivery.taskId ?? ''}',
    ];
    return {
      for (final id in ids)
        id: _notificationAnchors.putIfAbsent((chat.key, id), GlobalKey.new),
    };
  }

  ChatFindResult? _findResult;
  ProfileSessionKey? _findOwner;
  int? _findHistoryGeneration;
  int _findRequestGeneration = 0;
  bool _launchingCamera = false;
  ProfileSessionKey? _voiceOwner;
  late final _voiceInput = VoiceInputController(
    device: widget.voiceDevice ?? AndroidVoice.instance,
    createRemote: () => HermesVoice.forConnection(
      controller.connection,
      _voiceOwner!.workspace.profileName,
    ),
  );
  late final _voiceOutput = VoiceOutputController(
    widget.voiceDevice ?? AndroidVoice.instance,
  );
  VoiceDevice get _voiceDevice => widget.voiceDevice ?? AndroidVoice.instance;
  StreamSubscription<Map<String, dynamic>>? _voiceDeviceEvents;

  /// Car mode (docs/CAR_MODE.md). [_carSend] makes the next transcript count
  /// as hands-free, so the big button sends on every input route.
  bool _carSend = false;
  late final _car = CarModeSession(
    device: _voiceDevice,
    bridge: CarModeBridge(
      changes: Listenable.merge([controller, controller.connectionStatus, _voiceInput, _voiceOutput]),
      read: () => carSnapshotOf(controller, _voiceInput, _voiceOutput),
      preferences: controller.preferences,
      talk: () async {
        final chat = controller.notificationChat ?? controller.current?.chat;
        if (chat != null) await _run(() => _dictate(chat));
      },
      sendNow: () {
        _carSend = true;
        return _voiceInput.stopHandsFree();
      },
      stopSpeech: _voiceOutput.stop,
      retry: () => _run(controller.resumeConnection),
      sendHeld: () async {
        final chat = controller.notificationChat ?? controller.current?.chat;
        if (chat == null) return;
        _conversation = chat.key;
        await _run(() => _sendConversationTurn(chat));
      },
      leave: _cancelVoice,
    ),
  );

  void _voiceWorkspaceChanged() {
    final current = controller.notificationChat ?? controller.current?.chat;
    if (_voiceOwner != null &&
        (_voiceOwner != current?.key ||
            controller.switching ||
            current?.editingQueuedPrompt != null)) {
      _cancelVoice();
    }
    final loop = _conversation;
    if (loop != null &&
        (current == null ||
            current.key != loop ||
            _needsUserInput(current) ||
            (_conversationAwaitingReply &&
                {
                  ProfileTurnStatus.failed,
                  ProfileTurnStatus.cancelled,
                }.contains(current.status)))) {
      _conversation = null;
    }
  }

  /// Approvals, clarify questions and secure prompts need the user's hands or
  /// eyes, so they end a hands-free conversation.
  bool _needsUserInput(ProfileChat chat) =>
      chat.approval != null ||
      chat.clarification != null ||
      chat.sensitivePrompt != null;

  /// Chat of the running hands-free conversation (Conversation mode). Set when
  /// the user starts dictating with the mode on; cleared by anything that ends
  /// the loop. The microphone only reopens while this still names the chat.
  ProfileSessionKey? _conversationKey;
  ProfileSessionKey? get _conversation => _conversationKey;

  /// Keeps the display on while a hands-free conversation runs: a screen
  /// timeout would pause the activity and end any capture.
  set _conversation(ProfileSessionKey? value) {
    if ((_conversationKey == null) != (value == null)) {
      VoiceSwitchHolders.screenOn(_voiceDevice).set(this, value != null);
    }
    _conversationKey = value;
  }

  /// True from the conversation's auto-send until its reply arrived. Only
  /// that reply may reopen the microphone, never a later or queued turn.
  bool _conversationAwaitingReply = false;

  void _voiceInputChanged() {
    // Silence, no speech or a recognizer error ends the conversation.
    if (!_voiceInput.active && _voiceInput.error != null) _conversation = null;
  }

  StreamSubscription<({ProfileChat chat, String text})>? _autoSpeak;

  /// Hands-free voice chat: read a finished reply aloud when the user enabled
  /// "Spoken replies" or "Conversation mode", the chat is on screen and nobody
  /// is dictating. In a conversation the microphone reopens afterwards.
  void _speakCompletedReply(({ProfileChat chat, String text}) reply) {
    if (!mounted || !_hasWorkspaceFocus || _destination != AppDestination.chats) {
      _conversation = null;
      return;
    }
    final settings = VoicePreferences.read(controller.preferences);
    if (!settings.conversation) _conversation = null;
    if (!(settings.autoSpeak || settings.conversation || _car.active) ||
        _voiceInput.active) {
      return;
    }
    final chat = reply.chat;
    if ((controller.notificationChat ?? controller.current?.chat) != chat) {
      return;
    }
    if (!_conversationAwaitingReply) _conversation = null;
    _conversationAwaitingReply = false;
    _voiceOwner = chat.key;
    final connection = controller.connection;
    final profile = chat.key.workspace.profileName;
    unawaited(() async {
      final finished = await _voiceOutput.speak(
        (chat.key, 'auto-reply'),
        reply.text,
        settings,
        () => HermesVoice.forConnection(connection, profile),
      );
      if (!finished) {
        // Stop speech, a newer playback or a failure ends the conversation,
        // unless the user already tapped the microphone again.
        if (!_voiceInput.active) _conversation = null;
        return;
      }
      if (_canContinueConversation(chat)) {
        await _run(() => _dictate(chat, resume: true));
      }
    }());
  }

  /// The microphone never reopens unasked: only for the conversation's own
  /// chat, on screen, idle, with nothing waiting for the user's input.
  bool _canContinueConversation(ProfileChat chat) {
    final ok =
        mounted &&
        _conversation == chat.key &&
        _hasChatFocus &&
        (controller.notificationChat ?? controller.current?.chat) == chat &&
        !controller.switching &&
        !chat.busy &&
        !chat.opening &&
        !chat.commandRunning &&
        !chat.changingAnswer &&
        chat.editingQueuedPrompt == null &&
        !_needsUserInput(chat) &&
        !_voiceInput.active &&
        _voiceOutput.owner == null &&
        VoicePreferences.read(controller.preferences).conversation;
    if (!ok) _conversation = null;
    return ok;
  }

  /// Conversation mode: send a dictation the recognizer ended on its own.
  /// A running turn gets the text steered in instead of losing it, a down
  /// connection queues it for once the connection returns; anything else
  /// that blocks a normal send ends the conversation instead.
  Future<void> _sendConversationTurn(ProfileChat chat) async {
    final text = chat.draft.trim();
    // Car mode: offline, the draft waits on the device (spec §4.4).
    if (_conversation == chat.key && text.isNotEmpty && _car.holdForConnection()) {
      return;
    }
    // Car mode: speech while Hermes works steers the running turn (spec §6.4).
    // Barge-in (t_7e81e040) replaces this block with its decideDelivery hook;
    // keep the _car.logDelivery call when it does.
    if (_car.active &&
        mounted &&
        chat.busy &&
        _conversation == chat.key &&
        text.isNotEmpty &&
        !text.startsWith('/')) {
      final actions = _composerActions(chat);
      final delivery = carDeliveryFor(
        working: true,
        steerAvailable: actions[ComposerAction.steer] == null,
        queueAvailable: actions[ComposerAction.queue] == null,
      );
      _car.logDelivery(delivery);
      if (delivery != CarDelivery.end) {
        _conversationAwaitingReply = true;
        await _performComposerAction(
          chat,
          delivery == CarDelivery.steer ? ComposerAction.steer : ComposerAction.queue,
          conversation: true,
        );
        return;
      }
    }
    if (!mounted ||
        _conversation != chat.key ||
        controller.current?.chat != chat ||
        _destination != AppDestination.chats ||
        text.isEmpty ||
        text.startsWith('/')) {
      _conversation = null;
      return;
    }
    if (controller.recovering || chat.opening || chat.offlineSnapshot) {
      _conversationAwaitingReply = true;
      await controller.queuePrompt(chat, text);
      return;
    }
    final actions = _composerActions(chat);
    if (chat.busy) {
      if (actions[ComposerAction.steer] != null) {
        _conversation = null;
        return;
      }
      _conversationAwaitingReply = true;
      final accepted = await controller.steer(chat, text);
      if (accepted && chat.draft.trim() == text) {
        await controller.updateDraft(chat, '');
      }
      return;
    }
    if (actions[ComposerAction.send] != null) {
      _conversation = null;
      return;
    }
    _car.logDelivery(CarDelivery.send);
    _conversationAwaitingReply = true;
    await _performComposerAction(
      chat,
      ComposerAction.send,
      conversation: true,
    );
    if (!chat.busy && !_voiceInput.active && _voiceOutput.owner == null) {
      _conversation = null;
    }
  }

  void _cancelVoice() {
    _conversation = null;
    _voiceOwner = null;
    unawaited(_voiceInput.cancel().catchError((Object _) {}));
    unawaited(_voiceOutput.stop().catchError((Object _) {}));
  }

  /// Route vad: preload the phone model. Media keys are captured only while
  /// this workspace is the focused chat on the vad route (spec: foreground).
  void _syncVadRoute() {
    final vad = _vadRoute();
    if (vad == null) return;
    _syncMediaKeys();
    if (vad) unawaited(_voiceDevice.prepareVad().catchError((Object _) {}));
  }

  bool? _vadRoute() {
    try {
      return VoicePreferences.read(controller.preferences).input ==
          VoiceInputRoute.vad;
    } on FormatException {
      return null;
    }
  }

  void _syncMediaKeys() {
    final want = (_vadRoute() ?? false) && _hasChatFocus;
    if (want == _mediaKeysOn) return;
    _mediaKeysOn = want;
    VoiceSwitchHolders.mediaKeys(_voiceDevice).set(this, want);
  }

  /// Car mode entry/exit changes [_hasWorkspaceFocus] without a dependency
  /// change the route system would notify on its own; resync here instead.
  void _carActiveChanged() {
    controller.setRouteVisibility(this, _hasChatFocus);
    _syncMediaKeys();
  }

  void _voiceDeviceEvent(Map<String, dynamic> event) {
    if (event['mediaKey'] != 'playPause' || !mounted || !_hasChatFocus) return;
    if (_vadRoute() != true) {
      return;
    }
    if (_voiceInput.phase == VoiceInputPhase.recording) {
      unawaited(_voiceInput.stopHandsFree());
      return;
    }
    if (_voiceInput.active) return;
    final chat = controller.notificationChat ?? controller.current?.chat;
    if (chat == null || controller.switching || _needsUserInput(chat)) return;
    unawaited(_run(() => _dictate(chat)));
  }

  VoidCallback? _hermesSpeechSettingsLink(BuildContext context) {
    final profile = controller.current?.scope.profileName;
    if (profile == null) return null;
    final connection = controller.connection;
    final identity = controller.connectionIdentity;
    final status = controller.connectionStatus;
    return () => unawaited(
      _run(
        () => openProfileVoiceSettings(
          context,
          connection: connection,
          connectionIdentity: identity,
          connectionStatus: status,
          profileName: profile,
        ),
      ),
    );
  }

  /// [resume] reopens the microphone for a running conversation and gives up
  /// if anything ended the loop in the meantime.
  Future<void> _dictate(ProfileChat chat, {bool resume = false}) async {
    await _voiceOutput.stop();
    _carSend = false;
    if (!mounted ||
        (controller.notificationChat ?? controller.current?.chat) != chat ||
        controller.switching ||
        (resume && !_canContinueConversation(chat))) {
      if (resume) _conversation = null;
      return;
    }
    final settings = _car.roundSettings(
      VoicePreferences.read(controller.preferences),
    );
    _conversation = settings.conversation || _car.active ? chat.key : null;
    _conversationAwaitingReply = false;
    _voiceOwner = chat.key;
    final original = _composer.value;
    _composerFocus.unfocus();
    await _voiceInput.start(settings, original, (result) {
      final current = controller.notificationChat ?? controller.current?.chat;
      // Only a dictation the recognizer ended itself continues the loop;
      // Stop, the recording limit or a server transcription do not.
      final send =
          _conversation == chat.key && (_voiceInput.finishedOnItsOwn || _carSend);
      if (!send) _conversation = null;
      if (!mounted ||
          _voiceOwner != chat.key ||
          current != chat ||
          _destination != AppDestination.chats) {
        _conversation = null;
        return;
      }
      if (_composer.text != original.text) {
        _conversation = null;
        showStudioError(
          context,
          'The draft changed while recording. Please dictate again.',
        );
        return;
      }
      _composer.value = result;
      unawaited(
        _run(() async {
          await controller.updateDraft(chat, result.text);
          if (send) await _sendConversationTurn(chat);
        }),
      );
    });
  }

  Future<void> _readAloud(
    ProfileChat chat,
    Map<String, dynamic> message,
  ) async {
    _conversation = null;
    final owner = (chat.key, answerMessageId(message) ?? message);
    if (_voiceOutput.owner == owner) {
      await _voiceOutput.stop();
      return;
    }
    await _voiceInput.cancel();
    if (!mounted ||
        (controller.notificationChat ?? controller.current?.chat) != chat) {
      return;
    }
    _voiceOwner = chat.key;
    final connection = controller.connection;
    final profile = chat.key.workspace.profileName;
    await _voiceOutput.speak(
      owner,
      answerMessageText(message),
      VoicePreferences.read(controller.preferences),
      () => HermesVoice.forConnection(connection, profile),
    );
  }

  Widget _voiceActivity() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_voiceInput.active)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(switch (_voiceInput.phase) {
                  VoiceInputPhase.starting => 'Opening microphone…',
                  VoiceInputPhase.recording =>
                    'Recording · ${_voiceInput.seconds}s / ${_voiceInput.maxSeconds}s',
                  VoiceInputPhase.transcribing => 'Transcribing…',
                  VoiceInputPhase.idle => '',
                }),
              ),
              if (_voiceInput.partial.isNotEmpty)
                Text(
                  _voiceInput.partial,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              Wrap(
                spacing: 8,
                children: [
                  if (_voiceInput.phase == VoiceInputPhase.recording)
                    TextButton(
                      onPressed: _voiceInput.stop,
                      child: const Text('Stop recording'),
                    ),
                  TextButton(
                    onPressed: () {
                      _conversation = null;
                      unawaited(_voiceInput.cancel());
                    },
                    child: const Text('Cancel recording'),
                  ),
                ],
              ),
            ],
          ),
        ),
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
              TextButton(
                onPressed: () {
                  _conversation = null;
                  unawaited(_voiceOutput.stop());
                },
                child: const Text('Stop speech'),
              ),
            ],
          ),
        ),
      if (_voiceInput.error != null || _voiceOutput.error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: StudioError(_voiceInput.error ?? _voiceOutput.error!),
        ),
    ],
  );

  bool _canPasteImage(ProfileChat chat) =>
      controller.canAddAttachment(chat) &&
      chat.editingQueuedPrompt == null &&
      !chat.changingAnswer &&
      !chat.commandRunning &&
      !controller.switching &&
      !_launchingCamera;
  late AppDestination _destination;
  AppDestination? _chatOrigin;
  WorkspaceActivityFilter _recentFilter = WorkspaceActivityFilter.all;
  bool _routeIsCurrent = true;
  bool _appIsActive = true;
  bool _mediaKeysOn = false;
  static int _liveWorkspaces = 0;

  // Read fresh: a route pushed before car mode was entered (e.g. the "Chat
  // actions" menu) can leave [_routeIsCurrent] stuck false with no further
  // dependency change to correct it (spec: car mode keeps the chat's focus).
  bool get _hasWorkspaceFocus => (_routeIsCurrent || _car.active) && _appIsActive;

  bool get _hasChatFocus =>
      _hasWorkspaceFocus && _destination == AppDestination.chats;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _routeIsCurrent = isCurrent || _car.active;
    controller.setRouteVisibility(this, _hasChatFocus);
    _syncMediaKeys();
  }

  @override
  void initState() {
    super.initState();
    _liveWorkspaces++;
    _destination = widget.initialDestination;
    _appIsActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    controller.addListener(_voiceWorkspaceChanged);
    _autoSpeak = controller.completedReplies.listen(_speakCompletedReply);
    _voiceInput.addListener(_voiceInputChanged);
    _voiceDeviceEvents = _voiceDevice.events.listen(_voiceDeviceEvent);
    _car.addListener(_carActiveChanged);
    _syncVadRoute();
    WidgetsBinding.instance.addObserver(this);
    controller.setRouteVisibility(this, _hasChatFocus);
    // Shortcut navigation can reuse an owner still observed by the outgoing
    // route. Start its notifications after both routes finish building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_enter());
    });
  }

  Future<void> _enter() async {
    if (!controller.initialized && controller.notificationChat == null) {
      await controller.initialize();
    }
    if (!mounted || controller.current == null) return;
    if (_destination == AppDestination.activity) {
      await controller.refreshRecents();
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
        await controller.createChat();
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
    _appIsActive = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _syncVadRoute();
    } else {
      _syncMediaKeys();
    }
    controller.setRouteVisibility(this, _hasChatFocus);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (isTemporaryWorkspaceFailure(e)) {
        unawaited(controller.resumeConnection());
        return;
      }
      if (mounted) {
        final message = switch (e) {
          StateError error => error.message.toString(),
          FormatException error => error.message,
          _ => workspaceFailureMessage(e),
        };
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: StudioError(message)));
      }
    }
  }

  @override
  void dispose() {
    _car.removeListener(_carActiveChanged);
    _car.dispose();
    controller.removeListener(_voiceWorkspaceChanged);
    unawaited(_autoSpeak?.cancel());
    unawaited(_voiceDeviceEvents?.cancel());
    if (_conversationKey != null) {
      VoiceSwitchHolders.screenOn(_voiceDevice).set(this, false);
    }
    _voiceInput.removeListener(_voiceInputChanged);
    _voiceInput.dispose();
    _voiceOutput.dispose();
    controller.setRouteVisibility(this, false);
    if (_mediaKeysOn) {
      _mediaKeysOn = false;
      VoiceSwitchHolders.mediaKeys(_voiceDevice).set(this, false);
    }
    // A replacement workspace may already hold the model; release it only
    // when the last workspace goes away.
    if (--_liveWorkspaces <= 0 && _vadRoute() == true) {
      unawaited(_voiceDevice.releaseVad().catchError((Object _) {}));
    }
    WidgetsBinding.instance.removeObserver(this);
    _profileNavigation.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    _chatSearchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: profileWorkspaceTheme(
      Theme.of(context),
      accent: WorkspaceAccent.fromName(
        controller.preferences.getString(WorkspaceAccent.preferenceKey),
      ),
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
      profileName: controller.current?.scope.profileName,
      busy: controller.switching,
      mode: mode,
    );
    if (!mounted || !anchor.mounted || choice == null || controller.switching) {
      return;
    }
    if (choice.isConnection && choice.id == controller.connection.id) return;
    if (!choice.isConnection &&
        choice.id == controller.current?.scope.profileName) {
      return;
    }
    if (!choice.isConnection) {
      if (!_profileNavigation.canSwitch) {
        ScaffoldMessenger.of(anchor).showSnackBar(
          const SnackBar(
            content: Text(
              'Finish or discard your edits before switching profiles.',
            ),
          ),
        );
        return;
      }
      _cancelVoice();
      FocusManager.instance.primaryFocus?.unfocus();
      controller.cancelNotificationOpen();
      await _run(() async {
        final changed = await _profileNavigation.switchTo(
          choice.id,
          () => controller.switchProfile(
            choice.id,
            resetNavigation: _destination == AppDestination.chats,
          ),
        );
        if (!changed && mounted && anchor.mounted && controller.error != null) {
          ScaffoldMessenger.of(
            anchor,
          ).showSnackBar(SnackBar(content: StudioError(controller.error!)));
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
        _composer.text != (chat?.composerText ?? '')) {
      _composerKey = chat?.key;
      _composer.value = TextEditingValue(
        text: chat?.composerText ?? '',
        selection: TextSelection.collapsed(
          offset: chat?.composerText.length ?? 0,
        ),
      );
    }
  }

  ProfileWorkspaceBrowser? _browser;

  Widget _buildWorkspace(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, _voiceInput, _voiceOutput]),
    builder: (context, _) {
      final current = controller.current;
      final chat = controller.notificationChat ?? current?.chat;
      _syncComposer(chat);
      if (_destination != AppDestination.chats) {
        _browser = null;
        return _secondaryDestination(context);
      }
      if (chat == null) {
        // Transcript notifications must not recreate the Chats subtree.
        // Leaving the list or changing its owner starts a fresh visit.
        if (_browser?.key != ValueKey(current?.scope) ||
            _browser?.controller != controller) {
          _browser = ProfileWorkspaceBrowser(
            key: ValueKey(current?.scope),
            controller: controller,
            newProject: _projectDialog,
            drawer: _drawer(),
            searchFocusNode: _chatSearchFocus,
          );
        }
        return _browser!;
      }
      _browser = null;
      final parentSessionId = controller.parentSessionId(chat);
      final stackChatScope =
          MediaQuery.textScalerOf(context).scale(12) > 18 &&
          MediaQuery.sizeOf(context).width < 480;
      final canMoveProject =
          !chat.opening &&
          !chat.offlineSnapshot &&
          !controller.switching &&
          !(current?.mutatingSessions.contains(chat.key.sessionId) ?? false);
      void openProjectPicker() => unawaited(
        _run(
          () => showChatProjectPicker(
            context,
            controller,
            chat.key,
            currentProjectId: chat.projectId,
          ),
        ),
      );
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            if (_scaffoldKey.currentState?.isDrawerOpen == true) {
              unawaited(SystemNavigator.pop());
            } else if (chat.editingQueuedPrompt != null) {
              unawaited(_run(() => controller.cancelQueuedPromptEdit(chat)));
            } else {
              _leaveChat();
            }
          }
        },
        child: Scaffold(
          key: _scaffoldKey,
          drawer: _drawer(),
          appBar: AppBar(
            toolbarHeight:
                72 +
                (MediaQuery.textScalerOf(context).scale(24) - 24) +
                (stackChatScope ? 48 : 0),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: _chatOrigin == AppDestination.activity
                  ? 'Back to Recents'
                  : 'Back to sessions',
              onPressed: _leaveChat,
            ),
            // Share the project action across title and scope so the title
            // doesn't need another empty 48 dp row above the scope controls.
            title: Tooltip(
              message: 'Move to project',
              child: InkWell(
                borderRadius: WingRadius.card,
                onTap: canMoveProject ? openProjectPicker : null,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final scopeStyle = Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w400,
                            );
                        final projectLabel =
                            chat.opening || chat.offlineSnapshot
                            ? chat.key.workspace.profileName
                            : controller.chatProjectLabel(chat);
                        final server = ServerConnectionLabel(
                          alignment: Alignment.centerLeft,
                          label: controller.connection.label,
                          icon: controller.connection.icon,
                          status: controller.connectionStatus,
                          style: scopeStyle,
                        );
                        final project = Tooltip(
                          message: 'Move to project: $projectLabel',
                          child: Semantics(
                            button: true,
                            enabled: canMoveProject,
                            focusable: canMoveProject,
                            onTap: canMoveProject ? openProjectPicker : null,
                            label: '$projectLabel. Move to project',
                            excludeSemantics: true,
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
                                  child: Text(
                                    projectLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: scopeStyle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                        if (stackChatScope) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [server, project],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth * .5,
                              ),
                              child: server,
                            ),
                            ExcludeSemantics(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Text('·', style: scopeStyle),
                              ),
                            ),
                            Expanded(child: project),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              Builder(
                builder: (context) => IconButton(
                  tooltip: 'Open navigation menu',
                  icon: const Icon(Icons.menu),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Chat actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  if (action == 'refresh') {
                    unawaited(_run(controller.refresh));
                  } else if (action == 'find') {
                    unawaited(_openFind(chat));
                  } else if (action == 'outputs') {
                    unawaited(_run(() => _openOutputs(chat)));
                  } else if (action == 'subagents') {
                    unawaited(
                      _openWorkDetails(
                        ProfileSubagentPanel(
                          controller: controller,
                          chat: chat,
                          initiallyExpanded: true,
                        ),
                      ),
                    );
                  } else if (action == 'goal') {
                    unawaited(
                      _openWorkDetails(
                        ProfileGoalPanel(
                          controller: controller,
                          chat: chat,
                          initiallyExpanded: true,
                        ),
                      ),
                    );
                  } else if (action == 'background') {
                    unawaited(
                      _openWorkDetails(
                        ProfileBackgroundWorkPanel(
                          controller: controller,
                          chat: chat,
                          initiallyExpanded: true,
                        ),
                      ),
                    );
                  } else if (action == 'car') {
                    unawaited(_car.enter(context));
                  } else if (action == 'parent') {
                    unawaited(_run(() => controller.openParentChat(chat)));
                  }
                },
                itemBuilder: (_) => [
                  if (parentSessionId != null)
                    const PopupMenuItem(
                      value: 'parent',
                      child: Text('Parent chat'),
                    ),
                  const PopupMenuItem(value: 'outputs', child: Text('Outputs')),
                  const PopupMenuItem(
                    value: 'subagents',
                    child: Text('Subagents'),
                  ),
                  const PopupMenuItem(value: 'goal', child: Text('Goal')),
                  const PopupMenuItem(
                    value: 'background',
                    child: Text('Background work'),
                  ),
                  const PopupMenuItem(
                    value: 'find',
                    child: Text('Find in chat'),
                  ),
                  const PopupMenuItem(value: 'car', child: Text('Car mode')),
                  const PopupMenuItem(
                    value: 'refresh',
                    child: Text('Refresh workspace'),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (controller.switching) const LinearProgressIndicator(),
              WorkspaceConnectionStatus(
                status: controller.connectionStatus,
                showHint:
                    chat.openingError == null &&
                    (!chat.opening || chat.messages.isNotEmpty),
              ),
              if (controller.error != null)
                MaterialBanner(
                  content: StudioError(controller.error!),
                  actions: [
                    TextButton(
                      onPressed: () => _run(controller.retry),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              if (chat.openingError != null && chat.messages.isNotEmpty)
                MaterialBanner(
                  forceActionsBelow: true,
                  content: StudioError(chat.openingError!),
                  actions: [
                    TextButton(
                      onPressed: () => _run(controller.resumeConnection),
                      child: const Text('Retry connection'),
                    ),
                  ],
                ),
              Expanded(child: _chat(chat, context)),
            ],
          ),
        ),
      );
    },
  );

  Future<void> _openWorkDetails(Widget panel) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.75,
        child: ListView(children: [panel]),
      ),
    ),
  );

  Future<void> _openFind(ProfileChat chat) async {
    final owner = chat.key;
    final historyGeneration = chat.historyGeneration;
    final requestGeneration = ++_findRequestGeneration;
    final result = await showChatFindSheet(
      context,
      loadHistory: (offset) =>
          controller.savedHistoryPage(chat, offset: offset),
    );
    if (!mounted ||
        result == null ||
        requestGeneration != _findRequestGeneration ||
        controller.current?.chat != chat ||
        chat.key != owner ||
        chat.historyGeneration != historyGeneration ||
        result.page.sessionId !=
            (chat.historySessionId ?? chat.key.sessionId)) {
      return;
    }
    setState(() {
      _findResult = result;
      _findOwner = owner;
      _findHistoryGeneration = historyGeneration;
    });
  }

  ChatFindResult? _activeFindResult(ProfileChat chat) {
    if (_findOwner != chat.key ||
        _findHistoryGeneration != chat.historyGeneration) {
      return null;
    }
    return _findResult;
  }

  void _backToLatest() {
    setState(() {
      final owner = _findOwner;
      final chat = controller.current?.chat;
      if (owner != null && chat?.key == owner) {
        chat!.historyScrollOffset = 0;
      }
      _findResult = null;
      _findOwner = null;
      _findHistoryGeneration = null;
    });
  }

  Future<void> _openOutputs(ProfileChat chat) async {
    final files = controller.outputFiles(chat);
    final owner = chat.key;
    final ownedFiles = OwnedRemoteFiles(
      source: files,
      profileName: owner.workspace.profileName,
      storedSessionId: owner.sessionId,
    );
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatOutputsScreen(
            chatTitle: chat.title,
            loadHistory: (offset) =>
                controller.savedHistoryPage(chat, offset: offset),
            download: ownedFiles.download,
            readText: ownedFiles.readText,
          ),
        ),
      );
    } finally {
      files.close();
    }
  }

  Future<void> _openAnswerOutput(ProfileChat chat, ChatOutput output) async {
    final owner = chat.key;
    final files = controller.outputFiles(chat);
    final ownedFiles = OwnedRemoteFiles(
      source: files,
      profileName: owner.workspace.profileName,
      storedSessionId: owner.sessionId,
    );
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatOutputsScreen(
            chatTitle: chat.title,
            initialOutput: output,
            loadHistory: (offset) =>
                controller.savedHistoryPage(chat, offset: offset),
            download: ownedFiles.download,
            readText: ownedFiles.readText,
          ),
        ),
      );
    } finally {
      files.close();
    }
  }

  Future<bool> _downloadAnswerOutput(
    ProfileChat chat,
    ChatOutput output,
  ) async {
    final owner = chat.key;
    final files = controller.outputFiles(chat);
    try {
      final file = await OwnedRemoteFiles(
        source: files,
        profileName: owner.workspace.profileName,
        storedSessionId: owner.sessionId,
      ).download(output.path!);
      // A completed network request must not open a picker over another chat.
      if (!mounted ||
          controller.current?.chat?.key != owner ||
          ModalRoute.of(context)?.isCurrent != true) {
        return false;
      }
      return await saveRemoteFile(file);
    } finally {
      files.close();
    }
  }

  Future<Uint8List> _loadAttachmentImage(ProfileChat chat, String path) async {
    final owner = chat.key;
    final files = controller.outputFiles(chat);
    try {
      return (await files.download(
        path,
        profileName: owner.workspace.profileName,
        storedSessionId: owner.sessionId,
      )).bytes;
    } finally {
      files.close();
    }
  }

  Widget _questionPanel(ProfileChat chat) {
    final payload = chat.clarification!;
    final questions = GatewayClarifyRequest.fromEventDataList(payload);
    final pending = chat.pendingQuestion!;
    final index = questions.indexWhere(
      (q) => q.questionId == pending['question_id'],
    );
    if (index < 0) {
      return const Text(
        'This question could not be displayed. Refresh to try again.',
      );
    }
    final question = questions[index];
    return GatewayClarifyDialog(
      key: ValueKey((chat.key, question.requestId, question.questionId)),
      inline: true,
      request: question,
      number: index + 1,
      total: questions.length,
      onRespond: (answer) =>
          controller.clarify(chat, answer, expectedRequest: payload),
    );
  }

  Widget _answer(
    ProfileChat chat,
    Map<String, dynamic> message, {
    bool allowSavedActions = true,
  }) {
    if (isHiddenAnswerMessage(message)) return const SizedBox.shrink();
    final reasoning = profileMessageReasoning(message);
    final displayedHistory =
        _activeFindResult(chat)?.page.rows ?? chat.messages;
    final sender = interAgentReplySender(
      displayedHistory,
      displayedHistory.indexOf(message),
    );
    if (sender != null) {
      return AnchoredExpansionTile(
        key: ValueKey(('agent-reply', answerMessageId(message))),
        title: Text(
          'Replied to $sender',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        subtitle: const Text('Show reply'),
        shape: const Border(),
        children: [
          if (reasoning.isNotEmpty) ProfileReasoningDisclosure(text: reasoning),
          ProfileMessage(
            message: message,
            loadAttachmentImage: (path) => _loadAttachmentImage(chat, path),
            onOpenRemoteFile: (output) => _openAnswerOutput(chat, output),
            onDownloadRemoteFile: (output) =>
                _downloadAnswerOutput(chat, output),
          ),
        ],
      );
    }
    final savedPrompt =
        allowSavedActions &&
        isHumanAnswerPrompt(message) &&
        answerMessageId(message) != null;
    final index = displayedHistory.indexOf(message);
    final previous = index > 0 ? displayedHistory[index - 1] : null;
    final next = index >= 0 && index + 1 < displayedHistory.length
        ? displayedHistory[index + 1]
        : null;
    final sharesPreviousActions =
        allowSavedActions &&
        transcriptNoticeKind(message) == 'async_delegation_complete' &&
        previous != null &&
        _hasAnswerActions(displayedHistory, previous);
    final sharesNextNotice =
        next != null &&
        transcriptNoticeKind(next) == 'async_delegation_complete';
    final savedAnswer =
        allowSavedActions && _hasAnswerActions(displayedHistory, message);
    final enabled =
        !chat.opening &&
        !chat.offlineSnapshot &&
        !controller.recovering &&
        !chat.busy &&
        !chat.changingAnswer &&
        !chat.changingIntelligence &&
        !chat.commandRunning &&
        !controller.switching;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reasoning.isNotEmpty) ProfileReasoningDisclosure(text: reasoning),
        if (savedPrompt)
          Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 40),
                child: ProfileMessage(
                  message: message,
                  loadAttachmentImage: (path) =>
                      _loadAttachmentImage(chat, path),
                  onOpenRemoteFile: (output) => _openAnswerOutput(chat, output),
                  onDownloadRemoteFile: (output) =>
                      _downloadAnswerOutput(chat, output),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 12,
                child: IconButton(
                  key: ValueKey('edit-message-${answerMessageId(message)}'),
                  tooltip: 'Edit message',
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  onPressed: enabled
                      ? () => _editSavedMessage(chat, message)
                      : null,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
              ),
            ],
          )
        else
          ProfileMessage(
            message: message,
            onReadAloud: message['role'] == 'assistant'
                ? () => _run(() => _readAloud(chat, message))
                : null,
            actions: sharesPreviousActions
                ? _answerActions(chat, previous, enabled: enabled)
                : savedAnswer && !sharesNextNotice
                ? _answerActions(chat, message, enabled: enabled)
                : null,
            readingAloud:
                _voiceOutput.owner ==
                (chat.key, answerMessageId(message) ?? message),
            loadAttachmentImage: (path) => _loadAttachmentImage(chat, path),
            onOpenRemoteFile: (output) => _openAnswerOutput(chat, output),
            onDownloadRemoteFile: (output) =>
                _downloadAnswerOutput(chat, output),
          ),
      ],
    );
  }

  bool _hasAnswerActions(
    List<Map<String, dynamic>> history,
    Map<String, dynamic> message,
  ) =>
      message['role'] == 'assistant' &&
      answerMessageId(message) != null &&
      isBranchMessage(message) &&
      interAgentReplySender(history, history.indexOf(message)) == null;

  Widget _answerActions(
    ProfileChat chat,
    Map<String, dynamic> message, {
    required bool enabled,
  }) {
    return AnswerActions(
      key: ValueKey('answer-actions-${answerMessageId(message)}'),
      busy: chat.changingAnswer,
      onBranch: enabled
          ? () => _run(() async {
              await controller.branchAnswer(
                chat,
                chat.messages.indexOf(message),
              );
            })
          : null,
      onRegenerate: enabled
          ? () => _run(() async {
              await controller.branchAnswer(
                chat,
                chat.messages.indexOf(message),
                regenerate: true,
              );
            })
          : null,
    );
  }

  Future<void> _editSavedMessage(
    ProfileChat chat,
    Map<String, dynamic> message,
  ) async {
    var input = answerMessageDisplayText(message);
    var submitting = false;
    String? inlineError;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final canSubmit =
              !submitting && !chat.busy && input.trim().isNotEmpty;
          return AlertDialog(
            scrollable: true,
            title: const Text('Edit and resend?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "This replaces this message's turn and all later history in this chat.",
                ),
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: input,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 6,
                  onChanged: (value) => setDialogState(() {
                    input = value;
                    inlineError = null;
                  }),
                ),
                if (inlineError != null) ...[
                  const SizedBox(height: 12),
                  StudioError(
                    inlineError!,
                    key: const ValueKey('edit-message-error'),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: submitting
                    ? null
                    : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: canSubmit
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
                          );
                        } catch (_) {
                          // Keep the correction in place for a deliberate retry.
                        }
                        if (!dialogContext.mounted) return;
                        if (accepted) {
                          Navigator.pop(dialogContext);
                          return;
                        }
                        setDialogState(() {
                          submitting = false;
                          inlineError =
                              chat.error ??
                              'Hermes did not accept the edited message.';
                        });
                      }
                    : null,
                child: StudioActionLabel(
                  'Replace and resend',
                  busy: submitting,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _chat(ProfileChat chat, BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      children: [
        Expanded(
          child: ProfileTranscript(
            key: ValueKey((
              chat.key,
              _activeFindResult(chat)?.page.offset,
              _activeFindResult(chat)?.rowId,
            )),
            chat: chat,
            controller: controller,
            messageBuilder: (message) => _answer(
              chat,
              message,
              allowSavedActions: _activeFindResult(chat) == null,
            ),
            nearbyMessages: _activeFindResult(chat)?.page.rows,
            focusedMessageId: _activeFindResult(chat)?.rowId,
            notificationAnchors: _chatNotificationAnchors(chat),
            onBackToLatest: _activeFindResult(chat) == null
                ? null
                : _backToLatest,
            beforeActivity: [
              if (chat.streaming.isNotEmpty)
                ProfileMessage(
                  message: {'role': 'assistant', 'content': chat.streaming},
                  streaming: true,
                ),
            ],
            liveToolCount: chat.toolActivities.length,
            currentActivity: [
              if (chat.tool != null &&
                  !chat.toolActivities.any((activity) => !activity.isTerminal))
                ProfileTranscriptDisclosure(
                  icon: Icons.terminal_rounded,
                  label: 'Using ${chat.tool!}',
                  children: const [
                    Text('Running on the connected Hermes host'),
                  ],
                ),
              if (chat.toolActivities.isNotEmpty)
                ProfileLiveToolActivity(activities: chat.toolActivities),
            ],
            activityTabs: [
              if (chat.todos.isNotEmpty)
                ProfileActivityTab(
                  id: 'tasks',
                  label:
                      'Tasks ${chat.todos.where((todo) => todo.status == GatewayTodoStatus.completed).length}/${chat.todos.length}',
                  child: ProfileTodoPanel(todos: chat.todos, embedded: true),
                ),
              if (chat.subagents.isNotEmpty)
                ProfileActivityTab(
                  id: 'agents',
                  label:
                      'Agents ${chat.subagents.where((agent) => !agent.isTerminal).length}/${chat.subagents.length}',
                  onSelected: () =>
                      unawaited(controller.refreshSubagents(chat)),
                  child: ProfileSubagentPanel(
                    key: ValueKey(('subagents', chat.key)),
                    controller: controller,
                    chat: chat,
                    embedded: true,
                  ),
                ),
              if (chat.sessionControl?.goal != null ||
                  chat.sessionControl?.loop != null ||
                  chat.sessionControl?.heartbeat != null ||
                  chat.processes.isNotEmpty)
                ProfileActivityTab(
                  id: 'work',
                  label: 'Work',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (chat.sessionControl?.goal != null)
                        ProfileGoalPanel(
                          key: ValueKey(('goal', chat.key)),
                          controller: controller,
                          chat: chat,
                        ),
                      if (chat.sessionControl?.loop != null ||
                          chat.sessionControl?.heartbeat != null ||
                          chat.processes.isNotEmpty)
                        ProfileBackgroundWorkPanel(
                          key: ValueKey(('background', chat.key)),
                          controller: controller,
                          chat: chat,
                        ),
                    ],
                  ),
                ),
            ],
            activityThinking: chat.reasoning.isEmpty
                ? null
                : ProfileReasoningDisclosure(
                    text: chat.reasoning,
                    running: chat.busy,
                  ),
            tail: [
              if (chat.error != null)
                chat.notificationReadTarget?.kind == 'status'
                    ? _notificationAnchor(
                        chat,
                        'status',
                        chat.notificationReadTarget!.id,
                        StudioError(chat.error!),
                      )
                    : StudioError(chat.error!),
              if (chat.approval != null)
                Builder(
                  builder: (context) {
                    final request = chat.approval!;
                    return _notificationAnchor(
                      chat,
                      'approval',
                      request['request_id'] as String,
                      GatewayApprovalPanel(
                        key: ValueKey((chat.key, request['request_id'])),
                        request: GatewayApprovalRequest.fromEventData(request),
                        position: chat.approvals.position,
                        total: chat.approvals.total,
                        enabled:
                            !chat.approvalResponding &&
                            chat.status != ProfileTurnStatus.reconnecting,
                        onRespond: (choice) => _run(
                          () => controller.approve(
                            chat,
                            choice.wireValue,
                            requestId: request['request_id'] as String,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              if (chat.sensitivePrompt != null)
                Builder(
                  builder: (context) {
                    final request = chat.sensitivePrompt!;
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
                            !chat.sensitivePromptResponding &&
                            chat.status != ProfileTurnStatus.reconnecting,
                        onRespond: (value) => controller.respondSensitivePrompt(
                          chat,
                          value,
                          expectedRequest: request,
                        ),
                      ),
                    );
                  },
                ),
              if (chat.markReadFailed)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SelectionArea(
                    child: StudioError(
                      ProfileWorkspaceController.markReadFailureNotice,
                    ),
                  ),
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
              if (chat.pendingQuestion != null)
                _notificationAnchor(
                  chat,
                  'question',
                  chat.pendingQuestion!['request_id'] as String,
                  _questionPanel(chat),
                ),
            ],
          ),
        ),
        _composerPanel(chat, constraints),
      ],
    ),
  );

  Widget _composerPanel(
    ProfileChat chat,
    BoxConstraints constraints,
  ) => ListenableBuilder(
    listenable: controller.composerChanges,
    builder: (context, _) {
      _syncComposer(chat);
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: constraints.maxHeight * .8),
        child: SingleChildScrollView(
          reverse: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!chat.commandRunning && chat.editingQueuedPrompt == null)
                SlashCommandSuggestions(
                  key: ValueKey(chat.key),
                  controller: controller,
                  chat: chat,
                  composer: _composer,
                ),
              if (chat.commandRunning) const LinearProgressIndicator(),
              ProfileActivityStatus(
                key: const ValueKey('profile-activity-status'),
                chat: chat,
              ),
              ProfileQueuedMessages(
                key: ValueKey(('queued-messages', chat.key)),
                chat: chat,
                onOpenActions: _hasMessageActions(chat)
                    ? () => _showBusyActions(chat, context)
                    : null,
                onEdit:
                    chat.queueMutating || chat.queueDraining || chat.steering
                    ? null
                    : (prompt) => _beginQueuedEdit(chat, prompt),
                onDelete: chat.queueMutating || chat.steering
                    ? null
                    : (prompt) => _deleteQueuedPrompt(chat, prompt),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: DecoratedBox(
                    key: const ValueKey('conversation-composer'),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: WingRadius.card,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (chat.editingQueuedPrompt != null)
                                Row(
                                  children: [
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        'Editing queued message',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelMedium,
                                      ),
                                    ),
                                    ContextRing(occupancy: chat.context),
                                    TextButton(
                                      onPressed:
                                          chat.queueMutating || chat.steering
                                          ? null
                                          : () => _run(
                                              () => controller
                                                  .cancelQueuedPromptEdit(chat),
                                            ),
                                      child: const Text('Cancel'),
                                    ),
                                  ],
                                ),
                              if ((chat.editingQueuedPrompt?.attachments ??
                                      chat.attachments)
                                  .isNotEmpty)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        for (final file
                                            in chat
                                                    .editingQueuedPrompt
                                                    ?.attachments ??
                                                chat.attachments)
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                            ),
                                            child: ComposerAttachmentTile(
                                              draft: file,
                                              onRemove:
                                                  chat.editingQueuedPrompt !=
                                                          null ||
                                                      !controller
                                                          .canRemoveAttachment(
                                                            chat,
                                                            file,
                                                          ) ||
                                                      chat.changingAnswer ||
                                                      chat.commandRunning ||
                                                      controller.switching
                                                  ? null
                                                  : () => _run(
                                                      () => controller
                                                          .removeAttachment(
                                                            chat,
                                                            file,
                                                          ),
                                                    ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              _voiceActivity(),
                              TextField(
                                key: const Key('profile-message-composer'),
                                controller: _composer,
                                focusNode: _composerFocus,
                                enabled:
                                    !_voiceInput.active &&
                                    !chat.commandRunning &&
                                    !(chat.editingQueuedPrompt != null &&
                                        (chat.queueMutating || chat.steering)),
                                minLines: 1,
                                maxLines: 5,
                                keyboardType: TextInputType.multiline,
                                textInputAction: TextInputAction.newline,
                                contentInsertionConfiguration:
                                    _canPasteImage(chat)
                                    ? ContentInsertionConfiguration(
                                        allowedMimeTypes:
                                            ImageClipboard.mimeTypes,
                                        onContentInserted: (content) => _run(
                                          () async {
                                            if (!_canPasteImage(chat)) {
                                              throw StateError(
                                                'Wait before adding another image.',
                                              );
                                            }
                                            await controller.addPastedImage(
                                              chat,
                                              () =>
                                                  ImageClipboard.keyboardImage(
                                                    content,
                                                  ),
                                            );
                                          },
                                        ),
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
                                        throw StateError(
                                          'Wait before adding another image.',
                                        );
                                      }
                                      await controller.addPastedImage(
                                        chat,
                                        ImageClipboard.readImage,
                                      );
                                    }),
                                  );
                                },
                                onChanged: (value) {
                                  if (chat.editingQueuedPrompt != null) {
                                    _queuedEditErrors.remove(chat.key);
                                    controller.updateQueuedPromptEdit(
                                      chat,
                                      value,
                                    );
                                    return;
                                  }
                                  unawaited(
                                    controller.updateDraft(chat, value).catchError((
                                      _,
                                    ) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: StudioError(
                                              'This draft could not be saved on the device.',
                                            ),
                                          ),
                                        );
                                      }
                                    }),
                                  );
                                },
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintMaxLines: 1,
                                  hintText: chat.editingQueuedPrompt != null
                                      ? 'Edit queued message'
                                      : chat.busy
                                      ? 'Draft your next message'
                                      : 'Message Hermes or type /',
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 12,
                                  ),
                                ),
                              ),
                              if (chat.editingQueuedPrompt != null)
                                _queuedEditActions(chat)
                              else
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    IconButton(
                                      tooltip: 'Attach file',
                                      style: IconButton.styleFrom(
                                        minimumSize: const Size(48, 48),
                                      ),
                                      icon: const Icon(Icons.add),
                                      onPressed:
                                          !controller.canAddAttachment(chat) ||
                                              chat.changingAnswer ||
                                              chat.commandRunning ||
                                              controller.switching ||
                                              _launchingCamera
                                          ? null
                                          : () => _run(() async {
                                              final target = chat.key;
                                              final choice = await showModalBottomSheet<_AttachmentChoice>(
                                                context: context,
                                                showDragHandle: true,
                                                builder: (context) => SafeArea(
                                                  child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      ListTile(
                                                        leading: const Icon(
                                                          Icons
                                                              .camera_alt_outlined,
                                                        ),
                                                        title: const Text(
                                                          'Camera',
                                                        ),
                                                        enabled:
                                                            widget
                                                                .onCapturePhoto !=
                                                            null,
                                                        onTap:
                                                            widget.onCapturePhoto ==
                                                                null
                                                            ? null
                                                            : () => Navigator.pop(
                                                                context,
                                                                _AttachmentChoice
                                                                    .camera,
                                                              ),
                                                      ),
                                                      ListTile(
                                                        leading: const Icon(
                                                          Icons
                                                              .photo_library_outlined,
                                                        ),
                                                        title: const Text(
                                                          'Photos',
                                                        ),
                                                        onTap: () =>
                                                            Navigator.pop(
                                                              context,
                                                              _AttachmentChoice
                                                                  .photos,
                                                            ),
                                                      ),
                                                      ListTile(
                                                        leading: const Icon(
                                                          Icons
                                                              .insert_drive_file_outlined,
                                                        ),
                                                        title: const Text(
                                                          'Files',
                                                        ),
                                                        onTap: () =>
                                                            Navigator.pop(
                                                              context,
                                                              _AttachmentChoice
                                                                  .files,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              );
                                              if (choice == null) {
                                                return;
                                              }
                                              if (choice ==
                                                  _AttachmentChoice.camera) {
                                                if (_launchingCamera) {
                                                  return;
                                                }
                                                setState(
                                                  () => _launchingCamera = true,
                                                );
                                                try {
                                                  await widget.onCapturePhoto!(
                                                    target,
                                                  );
                                                } finally {
                                                  if (mounted) {
                                                    setState(
                                                      () => _launchingCamera =
                                                          false,
                                                    );
                                                  }
                                                }
                                                return;
                                              }
                                              final type =
                                                  choice ==
                                                      _AttachmentChoice.photos
                                                  ? FileType.image
                                                  : FileType.any;
                                              final file =
                                                  await FilePicker.pickFile(
                                                    type: type,
                                                  );
                                              if (file?.path != null) {
                                                await controller.addAttachment(
                                                  chat,
                                                  file!.path!,
                                                  file.name,
                                                );
                                              }
                                            }),
                                    ),
                                    ContextRing(occupancy: chat.context),
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: ChatIntelligenceButton(
                                          model: chat.model ?? 'Model',
                                          reasoningEffort:
                                              chat.reasoningEffort ?? 'default',
                                          loading:
                                              _loadingIntelligence ==
                                                  chat.key ||
                                              chat.changingIntelligence,
                                          onPressed:
                                              chat.opening ||
                                                  chat.offlineSnapshot ||
                                                  controller.recovering ||
                                                  chat.busy ||
                                                  chat.changingAnswer ||
                                                  chat.commandRunning ||
                                                  controller.switching ||
                                                  chat.changingIntelligence ||
                                                  _loadingIntelligence != null
                                              ? null
                                              : () => _run(
                                                  () => _chooseIntelligence(
                                                    chat,
                                                    context,
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Dictate message',
                                      icon: const Icon(Icons.mic_none),
                                      onPressed:
                                          _voiceInput.active ||
                                              controller.switching ||
                                              chat.opening ||
                                              chat.commandRunning ||
                                              chat.changingAnswer
                                          ? null
                                          : () => _run(() => _dictate(chat)),
                                    ),
                                    const SizedBox(width: 8),
                                    _composerActionButton(chat),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

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
        initialChoice: initial,
        initialReasoningEffort: chat.reasoningEffort ?? 'medium',
        defaultModel: options.defaultModel,
        defaultProvider: options.defaultProvider,
        profileName: chat.key.workspace.profileName,
        refreshModels: () => controller.refreshModelChoices(chat),
        reviewProviderAccess: () => openProfileProviderAccess(
          context,
          connection: controller.connection,
          connectionIdentity: controller.connectionIdentity,
          connectionStatus: controller.connectionStatus,
          profileName: chat.key.workspace.profileName,
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

  bool _canForkDraft(ProfileChat chat) =>
      !chat.busy &&
      !chat.queueDraining &&
      chat.draft.trim().isNotEmpty &&
      !chat.draft.trimLeft().startsWith('/') &&
      chat.attachments.isEmpty &&
      chat.messages.any(
        (message) =>
            message['role'] == 'assistant' &&
            answerMessageId(message) != null &&
            isBranchMessage(message),
      );

  Map<ComposerAction, String?> _composerActions(ProfileChat chat) {
    if (_voiceInput.active) {
      return {
        for (final action in ComposerAction.values)
          action: 'Finish or cancel dictation first',
      };
    }
    if (controller.recovering || chat.opening || chat.offlineSnapshot) {
      return {
        for (final action in ComposerAction.values)
          action: 'Reconnecting · Your draft is kept',
      };
    }
    final text = chat.draft.trim();
    final blocked =
        controller.switching ||
        chat.changingAnswer ||
        chat.commandRunning ||
        chat.changingIntelligence ||
        chat.editingQueuedPrompt != null;
    final hasDraft = text.isNotEmpty || chat.attachments.isNotEmpty;
    final slash = text.startsWith('/');
    return {
      ComposerAction.send:
          !blocked && !chat.sendingPrompt && hasDraft && (!chat.busy || slash)
          ? null
          : 'Wait for the current turn',
      ComposerAction.steer: blocked || chat.steering
          ? 'Wait before steering'
          : !{
              ProfileTurnStatus.running,
              ProfileTurnStatus.attention,
            }.contains(chat.status)
          ? 'Steer needs a running turn'
          : chat.attachments.isNotEmpty
          ? 'Steer supports text only'
          : text.isEmpty || slash
          ? 'Type a message to steer'
          : null,
      ComposerAction.stop: !blocked && chat.busy
          ? null
          : 'No running turn to stop',
      ComposerAction.queue: chat.sendingPrompt
          ? 'Wait for the current message to finish sending'
          : !blocked &&
                chat.busy &&
                hasDraft &&
                !slash &&
                !chat.queueMutating &&
                !chat.queueDraining
          ? null
          : 'Queue a draft during a running turn',
      ComposerAction.fork: !blocked && _canForkDraft(chat)
          ? null
          : 'Fork needs a completed saved answer and text',
    };
  }

  Widget _composerActionButton(ProfileChat chat) => ComposerActionButton(
    key: ValueKey(chat.key),
    primary: chat.busy && !chat.draft.trimLeft().startsWith('/')
        ? ComposerAction.fromPreference(
            controller.preferences.getString(ComposerAction.preferenceKey),
          )
        : ComposerAction.send,
    unavailable: _composerActions(chat),
    onSelected: (action) => _performComposerAction(chat, action),
  );

  Future<void> _performComposerAction(
    ProfileChat chat,
    ComposerAction action, {
    bool conversation = false,
  }) async {
    // Any manual composer action, including Stop response, ends the loop.
    if (!conversation) _conversation = null;
    if (controller.current?.chat != chat ||
        _composerActions(chat)[action] != null) {
      return;
    }
    final text = chat.draft.trim();
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
      case ComposerAction.fork:
        await _run(() async {
          await controller.forkPrompt(chat, text);
        });
      case ComposerAction.steer:
        final accepted = await _runValue(() => controller.steer(chat, text));
        if (accepted == true && mounted && chat.draft.trim() == text) {
          await _run(() => controller.updateDraft(chat, ''));
        } else if (accepted == false && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: StudioError('Hermes rejected the steering message.'),
            ),
          );
        }
    }
  }

  bool _hasMessageActions(ProfileChat chat) =>
      chat.editingQueuedPrompt == null &&
      !controller.switching &&
      !chat.commandRunning &&
      !chat.changingAnswer &&
      !chat.changingIntelligence &&
      !chat.queueMutating &&
      (_canForkDraft(chat) ||
          chat.queuedPrompts.isNotEmpty ||
          (chat.busy &&
              (chat.draft.trim().isNotEmpty || chat.attachments.isNotEmpty) &&
              !chat.draft.trimLeft().startsWith('/')));

  Future<void> _beginQueuedEdit(ProfileChat chat, QueuedPromptDraft prompt) =>
      _run(() async {
        _queuedEditErrors.remove(chat.key);
        await controller.beginQueuedPromptEdit(chat, prompt);
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

  Widget _queuedEditActions(ProfileChat chat) {
    final text = chat.queuedEditText.trim();
    final prompt = chat.editingQueuedPrompt!;
    final saving = chat.queueMutating || chat.steering || controller.switching;
    final valid =
        !text.startsWith('/') &&
        (text.isNotEmpty || prompt.attachments.isNotEmpty);
    final canSteer =
        valid &&
        text.isNotEmpty &&
        prompt.attachments.isEmpty &&
        {
          ProfileTurnStatus.running,
          ProfileTurnStatus.attention,
        }.contains(chat.status);
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
          if (prompt.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'Steer supports text only.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: saving || !canSteer
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
                  icon: const Icon(Icons.explore_outlined, size: 18),
                  label: const Text('Steer'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: saving || !valid
                      ? null
                      : () => _runQueuedEdit(
                          chat,
                          () => controller.saveQueuedPromptEdit(chat),
                        ),
                  icon: const Icon(Icons.keyboard_return, size: 18),
                  label: Text(saving ? 'Saving...' : 'Queue'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _deleteQueuedPrompt(
    ProfileChat chat,
    QueuedPromptDraft prompt,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete queued instruction?'),
        scrollable: true,
        content: Text(
          [
            'Are you sure you want to delete this instruction?',
            prompt.text,
            ...prompt.attachments.map((attachment) => attachment.name),
          ].where((part) => part.isNotEmpty).join('\n\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(
        () => controller.removeQueuedPrompt(
          chat,
          chat.queuedPrompts.indexOf(prompt),
          expectedPrompt: prompt,
        ),
      );
    }
  }

  Future<void> _showBusyActions(ProfileChat chat, BuildContext context) async {
    if (!_hasMessageActions(chat)) return;
    final text = chat.draft.trim();
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .55,
            child: ListView(
              children: [
                if (_canForkDraft(chat))
                  ListTile(
                    leading: const Icon(Icons.fork_right),
                    title: const Text('Fork into a new chat'),
                    subtitle: const Text(
                      'Branch at the latest saved answer and send this message',
                    ),
                    onTap: () => Navigator.pop(sheetContext, 'fork'),
                  ),
                if (text.isNotEmpty &&
                    !text.startsWith('/') &&
                    chat.busy &&
                    chat.attachments.isEmpty) ...[
                  ListTile(
                    leading: const Icon(Icons.explore_outlined),
                    title: const Text('Steer this turn'),
                    subtitle: const Text(
                      'Send this text into the running turn',
                    ),
                    onTap:
                        !chat.steering &&
                            {
                              ProfileTurnStatus.running,
                              ProfileTurnStatus.attention,
                            }.contains(chat.status)
                        ? () => Navigator.pop(sheetContext, 'steer')
                        : null,
                  ),
                ],
                if ((text.isNotEmpty || chat.attachments.isNotEmpty) &&
                    !text.startsWith('/') &&
                    chat.busy)
                  ListTile(
                    leading: const Icon(Icons.queue),
                    title: const Text('Queue for the next turn'),
                    subtitle: Text(
                      chat.attachments.isEmpty
                          ? 'Keep this message for when Hermes is idle'
                          : 'Keep this message and ${chat.attachments.length} attachment${chat.attachments.length == 1 ? '' : 's'} for when Hermes is idle',
                    ),
                    onTap: chat.queueMutating || chat.queueDraining
                        ? null
                        : () => Navigator.pop(sheetContext, 'queue'),
                  ),
                if (chat.queuePaused)
                  ListTile(
                    leading: const Icon(Icons.pause_circle_outline),
                    title: const Text('Queued messages are paused'),
                    subtitle: const Text(
                      'Check history before resuming; a previous send may have reached Hermes.',
                    ),
                    onTap: chat.queueDraining || chat.queueMutating
                        ? null
                        : () async {
                            await _run(() => controller.resumeQueue(chat));
                            if (sheetContext.mounted) {
                              Navigator.pop(sheetContext);
                            }
                          },
                    trailing: const Icon(Icons.play_arrow),
                  ),
                if (chat.queuedPrompts.isNotEmpty)
                  ...chat.queuedPrompts.asMap().entries.map(
                    (entry) => ListTile(
                      leading: const Icon(Icons.keyboard_return),
                      title: Text(
                        'Queued: ${entry.value.text.isEmpty ? 'Attachment' : entry.value.text}',
                      ),
                      subtitle: entry.value.attachments.isEmpty
                          ? null
                          : Text(
                              '${entry.value.attachments.length} attachment${entry.value.attachments.length == 1 ? '' : 's'}: ${entry.value.attachments.map((draft) => draft.name).join(', ')}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: chat.queueDraining || chat.queueMutating
                          ? null
                          : () async {
                              Navigator.pop(sheetContext);
                              await _beginQueuedEdit(chat, entry.value);
                            },
                    ),
                  ),
                if (chat.busy)
                  ListTile(
                    leading: const Icon(Icons.stop),
                    title: const Text('Stop'),
                    onTap: () => Navigator.pop(sheetContext, 'stop'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    await _performComposerAction(chat, ComposerAction.values.byName(action));
  }

  Future<T?> _runValue<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: StudioError(e.toString())));
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
    connection: controller.connection,
    connectionStatus: controller.connectionStatus,
    onSelected: _selectDestination,
  );

  void _leaveChat() {
    final origin = _chatOrigin;
    controller.showList();
    if (origin != null) _selectDestination(origin);
  }

  void _selectDestination(AppDestination destination) {
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
    controller.setRouteVisibility(this, _hasChatFocus);
    _syncMediaKeys();
    if (destination == AppDestination.activity) {
      unawaited(_run(controller.refreshRecents));
    }
  }

  /// Bring a reused workspace route back to its chat after a notification tap.
  void showNotificationChat() {
    if (_destination != AppDestination.chats) {
      _selectDestination(AppDestination.chats);
    }
  }

  Widget _secondaryDestination(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _handleBack();
    },
    child: Scaffold(
      key: _scaffoldKey,
      drawer: _drawer(),
      appBar: _destination == AppDestination.administration
          ? null
          : AppBar(
              toolbarHeight: adminToolbarHeight(
                context,
                _destination.label,
                actions:
                    _destination == AppDestination.settings &&
                        widget.configurationActions != null
                    ? 2
                    : _destination == AppDestination.activity
                    ? 1
                    : 0,
              ),
              title: Text(_destination.label, maxLines: 6, softWrap: true),
              actions: [
                if (_destination == AppDestination.settings &&
                    widget.configurationActions != null)
                  widget.configurationActions!(context, () {
                    if (mounted) setState(() => _settingsRevision++);
                  }),
                if (_destination == AppDestination.activity)
                  IconButton(
                    tooltip: 'Refresh recents',
                    icon: const Icon(Icons.refresh),
                    onPressed: controller.switching || controller.recentsLoading
                        ? null
                        : () => _run(controller.refreshRecents),
                  ),
              ],
            ),
      body: Column(
        children: [
          if (controller.switching &&
              _destination != AppDestination.settings &&
              _destination != AppDestination.administration)
            const LinearProgressIndicator(),
          if (_destination == AppDestination.activity ||
              _destination == AppDestination.health ||
              _destination == AppDestination.analytics)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ServerConnectionLabel(
                  label: controller.connection.label,
                  icon: controller.connection.icon,
                  pickerMode: _destination == AppDestination.analytics
                      ? WorkspacePickerMode.profiles
                      : null,
                  suffix:
                      _destination == AppDestination.health ||
                          _destination == AppDestination.analytics
                      ? controller.current?.scope.profileName
                      : null,
                  status: controller.connectionStatus,
                ),
              ),
            ),
          if (_destination != AppDestination.settings &&
              _destination != AppDestination.administration)
            WorkspaceConnectionStatus(status: controller.connectionStatus),
          if (controller.error != null &&
              _destination != AppDestination.settings &&
              _destination != AppDestination.administration)
            ListTile(
              title: StudioError(controller.error!),
              trailing: TextButton(
                onPressed: () => _run(controller.retry),
                child: const Text('Retry'),
              ),
            ),
          Expanded(
            child: switch (_destination) {
              AppDestination.analytics => HermesAnalyticsContent(
                key: ValueKey(controller.connectionIdentity),
                controller: controller,
              ),
              AppDestination.settings => AppSettingsContent(
                key: ValueKey(_settingsRevision),
                preferences: controller.preferences,
                hermesVoiceProfileLabel: controller.current?.scope.profileName,
                openHermesVoiceSettings: _hermesSpeechSettingsLink(context),
                enableNotifications: widget.enableNotifications,
                backgroundMonitoringState: widget.backgroundMonitoringState,
                openMonitoringBatterySettings:
                    widget.openMonitoringBatterySettings,
                onChanged: () {
                  setState(() {});
                  widget.onPreferencesChanged?.call();
                },
              ),
              AppDestination.activity => WorkspaceActivityContent(
                controller: controller,
                filter: _recentFilter,
                onFilterChanged: (filter) => _recentFilter = filter,
                onOpen: (item) => _run(() async {
                  final opened = await controller.openSession(item.key);
                  if (mounted &&
                      opened != null &&
                      _destination == AppDestination.activity) {
                    _selectDestination(AppDestination.chats);
                    _chatOrigin = AppDestination.activity;
                  }
                }),
              ),
              AppDestination.health => HermesHealthContent(
                onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
                key: ValueKey(controller.connectionIdentity),
                controller: controller,
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
  );

  Future<String?> _textDialog(String title, String label) async {
    var input = '';
    // Let the field own its controller through the dialog's exit animation.
    // showDialog resolves before the route's widgets have finished unmounting.
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          onChanged: (value) => input = value,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, input.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<void> _projectDialog() async {
    final owner = controller.current;
    if (owner == null) return;
    final name = await _textDialog('New project', 'Project name');
    if (!mounted) return;
    if (!identical(controller.current, owner)) {
      throw StateError('Profile changed. Open Projects and try again.');
    }
    if (name == null || name.isEmpty) return;
    final path = await showDialog<String>(
      context: context,
      builder: (_) => ProjectFolderPickerDialog(
        discover: owner.gateway.discoverProjectFolders,
      ),
    );
    if (!mounted) return;
    if (!identical(controller.current, owner)) {
      throw StateError('Profile changed. Open Projects and try again.');
    }
    if (path == null || path.isEmpty) return;
    await controller.createProject(name, path);
  }
}
