import '../models/email_draft.dart';
import '../models/model_catalog_details.dart';
import '../models/canonical_session.dart';
import 'package:uuid/uuid.dart';
import '../models/turn_failure.dart';
import '../models/hosted_connector_accounts.dart';
import 'chat_transcript_events.dart';
import 'hermes_question_history.dart';
import 'subagent_timeline_session.dart';
import '../models/operational_error.dart';
import 'transcript_resource_session.dart';
import 'group_observations.dart';
import '../models/server_reference.dart';
import '../models/composer_reference.dart';
import 'composer_reference_repository.dart';
import 'composer_reference_preparation.dart';
import '../models/recent_conversation.dart';
import '../models/transcript_message.dart';
import 'recent_conversation_session.dart';
import 'bots_session.dart';
import 'group_notification_session.dart';
import '../models/group_notification.dart';
import 'workspace_recents_cache.dart';
import 'recent_conversation_snapshots.dart';
import '../models/bots.dart';
import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/chat_intelligence.dart';
import 'package:wing/core/models/model_choice.dart';
import 'dart:async';
import 'conversation_reading_memory.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'administration_health_session.dart';
import 'host_resources_session.dart';
import 'administration_repository.dart';
import 'skill_reader_session.dart';
import '../models/skill_reader.dart';
import 'app_preferences.dart';
import 'connection_diagnostics.dart';
import 'profile_colors_session.dart';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/deleted_draft_cleanup.dart';
import '../models/chat_list_status.dart';
import '../models/chat_list_view.dart';
import '../models/profile_session_key.dart';
import '../models/browser_mutation.dart';
import '../models/context_occupancy.dart';
import '../models/chat_notification_content.dart';
import '../models/session_visibility.dart';
import '../models/answer_versions.dart';
import '../models/transcript_notice.dart';
import '../models/hermes_profile.dart';
import '../models/gateway_insight.dart';
import '../models/gateway_process.dart';
import '../models/gateway_todo.dart';
import '../models/profile_live_activity.dart';
import '../models/detached_work.dart';
import '../models/composer_work.dart';
import 'composer_session.dart';
import '../models/transcript_reading.dart';
import '../models/review_notice.dart';
import 'transcript_reading.dart';
import '../models/chat_reading.dart';
import 'chat_reading_session.dart';
import '../models/session_control.dart';
import '../models/profile_supervision.dart';
import '../models/side_question_delivery.dart';
import '../models/slash_command.dart';
import 'attachment_draft_service.dart';
import 'composer_draft_store.dart';
import 'deleted_draft_cleanup_store.dart';
import 'completion_diagnostics.dart';
import 'remote_files_client.dart';
import 'owned_remote_files.dart';
import 'hermes_voice.dart';
import 'live_voice_session.dart';
import '../models/app_preferences.dart' show LiveVoiceMode;
import '../models/voice_processing_settings.dart';
import 'connection_manager.dart';
import 'connection_access.dart';
import 'profile_gateway.dart';
import '../models/chat_runtime.dart';
import 'chat_runtime.dart' as execution;
import '../models/profile_selection.dart';
import 'profiles_repository.dart';
import 'ws_client.dart';
import 'workspace_connection_failure.dart';
import 'server_connection_status.dart';
import 'workspace_snapshot_store.dart';
import '../models/gateway_sensitive_prompt.dart';
import 'android_share_intent_service.dart';
import '../models/notification_focus.dart';
import '../models/notification_input.dart';

part 'profile_workspace_references.dart';
part 'profile_workspace_live_voice.dart';
part 'profile_workspace_notifications.dart';
part 'profile_workspace_recents.dart';
part 'profile_workspace_deleted_drafts.dart';

class ProfileChat {
  ContextOccupancy? _context;
  int _contextGeneration = 0;
  int _contextUsageRevision = 0;
  int? _contextCompressions;
  bool _contextLoading = false;
  bool _contextExplicitRefresh = false;
  String? _contextError;
  ProfileSessionKey _key;
  String _title;
  String _source;
  String? _cwd;
  String? _terminalBackend;
  String? _parentSessionId;
  double _lastActive = DateTime.now().millisecondsSinceEpoch / 1000;
  String? _projectId;
  bool _projectLoading = false;
  bool _projectLookupFailed = false;
  String? _model;
  String? _provider;
  String? _reasoningEffort;
  ChatFastMode? _fastMode;
  bool? _yolo;
  bool _changingIntelligence = false;
  ChatIntelligenceSelection? _pendingIntelligence;
  CurrentPlanGauge? _planGauge;
  CurrentPlanGauge? get planGauge => _planGauge;
  String? _readOnlyReason;
  bool _attachmentRefused = false;

  /// Foreground attachment and explicit refusal cannot admit composer work.
  /// Background network recovery can still accept an offline queued message.
  bool get attachmentBlocked =>
      _attachmentRefused ||
      refreshingConversation && runtime.opening && runtime.openingError == null;
  HostedConnectionOperation? _connectionOperation;
  Object? _connectionOperationAction;
  bool _answeringQuestion = false;
  bool _branchingAnswer = false;
  String? _intelligenceRuntime;
  int _intelligenceReadGeneration = 0;
  int _intelligenceRevision = 0;
  final execution.ChatRuntime _runtime;
  ChatRuntimeObservation get runtime => _runtime.observation;
  ComposerSession _composer;
  ComposerSession get composer => _composer;
  final TranscriptReading reading;
  Object? _readingRefresh;
  bool get refreshingConversation => _readingRefresh != null;

  final List<({GatewayNotice notice, String identity})> _reviewNotices = [];
  GatewayTodoState _taskState = GatewayTodoState();
  List<GatewaySubagentActivity> _subagents = [];
  final Map<String, int> _subagentCompletionTurns = {};
  final Set<String> _unconfirmedSubagentIds = {};
  int _subagentsRevision = 0;
  bool _subagentsLoading = false;
  String? _subagentsError;
  int _subagentsLoadGeneration = 0;
  List<GatewayProcessActivity> _processes = [];
  final Map<String, int> _processCompletionTurns = {};
  bool _processesLoading = false;
  final _processReads = <String, int>{};
  (String, Future<bool>)? _automaticProcessRead;
  String? _processesError;
  bool _passiveProcessFailure = false, _explicitAutomaticProcessRead = false;
  final Set<String> _dismissedProcessIds = {};
  final Set<String> _stoppingProcessIds = {};
  int _processesReadGeneration = 0;
  SessionControlSnapshot? _sessionControl;
  bool _sessionControlLoading = false;
  bool _sessionControlWorking = false;
  String? _sessionControlError;
  String? _sessionControlNotice;
  int _sessionControlGeneration = 0;
  int _sessionControlEventRevision = 0;
  bool _sessionControlReadAttempted = false;
  bool _markReadFailed = false;
  String? _commandNotification;

  final List<SideQuestionDelivery> _sideQuestionDeliveries = [];
  String? _notificationInputFingerprint;
  bool _notificationInputsQuiet = false;
  bool _notificationTargetRestored = false;
  bool _archived = false;
  bool? _hidden;
  bool _replaceableUnsubmittedRuntime = false;
  bool _replacingExpiredRuntime = false;
  Completer<void>? _replacementCompletion;

  // Canonical facts are written only by this containing workspace library.
  ContextOccupancy? get context => _context;
  int? get contextCompressions => _contextCompressions;
  bool get contextLoading => _contextLoading;
  bool get contextRefreshPending => _contextLoading && _contextExplicitRefresh;
  String? get contextError => _contextError;
  ProfileSessionKey get key => _key;
  String get title => _title;
  String get source => _source;
  String? get parentSessionId => _parentSessionId;
  double get lastActive => _lastActive;
  String? get projectId => _projectId;
  bool get projectLoading => _projectLoading;
  bool get projectLookupFailed => _projectLookupFailed;
  String? get model => _model;
  String? get provider => _provider;
  String? get reasoningEffort => _reasoningEffort;
  ChatFastMode? get fastMode => _fastMode;
  bool? get yolo => _yolo;
  bool get changingIntelligence => _changingIntelligence;
  ChatIntelligenceSelection? get pendingIntelligence => _pendingIntelligence;
  String? get readOnlyReason => _readOnlyReason;
  HostedConnectionOperation? get connectionOperation => _connectionOperation;
  bool get connectionOperationWorking => _connectionOperationAction != null;
  bool get answeringQuestion => _answeringQuestion;
  bool get branchingAnswer => _branchingAnswer;
  String? get intelligenceRuntime => _intelligenceRuntime;
  List<GatewayNotice> get reviewNotices =>
      List.unmodifiable(_reviewNotices.map((receipt) => receipt.notice));
  List<GatewayTodo> get todos => _taskState.todos;
  int? get todoRevision => _taskState.revision;
  List<GatewayTodo> get currentTodos => _taskState.current(
    active: runtime.executionActive,
    turn: _runtime.turnRevision,
  );
  Object? _workInputs;
  Object _workRevision = Object();

  /// Opaque invalidation for supervision, independent of growing answer text.
  /// Compare canonical facts here rather than cloning detached work snapshots
  /// merely to decide whether a borrower needs to render them again.
  Object get workRevision {
    final inputs = (
      runtime.runtimeId,
      _runtime.turnRevision,
      runtime.executionActive,
      _taskState.todos,
      _taskState.revision,
      _subagentsRevision,
      _subagentsLoadGeneration,
      _subagentsLoading,
      _subagentsError,
      _sessionControl,
      _sessionControlLoading,
      _sessionControlWorking,
      _sessionControlError,
      _sessionControlNotice,
      _processes,
      _processesLoading,
      _processesError,
      _passiveProcessFailure,
    );
    if (_workInputs != inputs) {
      _workInputs = inputs;
      _workRevision = Object();
    }
    return _workRevision;
  }

  List<GatewaySubagentActivity> get subagents =>
      List.unmodifiable(_subagents.map(copySupervisedSubagent));

  /// Unfinished work and terminal observations from the still-active round.
  /// Keep older canonical records for open details and duplicate-event merging;
  /// their saved results belong to historical Activity, outside the live dock.
  List<GatewaySubagentActivity> get currentSubagents => List.unmodifiable(
    _subagents
        .where(
          (item) =>
              !item.isTerminal ||
              runtime.executionActive &&
                  _subagentCompletionTurns[item.id] == _runtime.turnRevision,
        )
        .map(copySupervisedSubagent),
  );
  Set<String> get unconfirmedSubagentIds =>
      Set.unmodifiable(_unconfirmedSubagentIds);
  bool get subagentsLoading => _subagentsLoading;
  bool get subagentsAvailable =>
      _subagentsRevision > 0 || _subagents.isNotEmpty;
  String? get subagentsError => _subagentsError;
  List<GatewayProcessActivity> get processes => List.unmodifiable(_processes);

  /// Running work survives its parent; exited rows belong only to their round.
  List<GatewayProcessActivity> get currentProcesses => List.unmodifiable(
    _processes.where(
      (process) =>
          process.isRunning ||
          runtime.executionActive &&
              _processCompletionTurns[process.id] == _runtime.turnRevision,
    ),
  );
  bool get processesLoading => _processesLoading;
  String? get processesError => _processesError;
  String? get inlineProcessesError =>
      _passiveProcessFailure ? null : _processesError;
  SessionControlSnapshot? get sessionControl =>
      copySupervisedControl(_sessionControl);
  bool get sessionControlLoading => _sessionControlLoading;
  bool get sessionControlWorking => _sessionControlWorking;
  String? get sessionControlError => _sessionControlError;
  String? get sessionControlNotice => _sessionControlNotice;
  bool get markReadFailed => _markReadFailed;
  List<SideQuestionDelivery> get sideQuestionDeliveries =>
      List.unmodifiable(_sideQuestionDeliveries);
  bool get archived => _archived;
  bool? get hidden => _hidden;

  ProfileChat({
    required ProfileSessionKey key,
    required this._runtime,
    required this._title,
    this._source = '',
    this._parentSessionId,
    this._projectId,
    required ComposerSession composer,
    required this.reading,
  }) : _key = key,
       _composer = composer {
    if (composer.key != key) {
      throw ArgumentError('Composer and chat must share the exact owner.');
    }
    if (reading.scope != key.workspace) {
      throw ArgumentError('Reading and chat must share the exact workspace.');
    }
  }

  ChatListRuntimeObservation get listObservation => (
    needsInput: runtime.needsInput,
    working:
        runtime.activity(
          backgroundWorking: _subagents.any((item) => !item.isTerminal),
        ) ==
        ProfileLiveActivityState.running,
    hasMessages: reading.messages.isNotEmpty,
  );
}

class ProfileWorkspaceData {
  Future<SlashCatalog>? _commandCatalog;
  final ProfileGateway gateway;
  List<Map<String, dynamic>> _sessions = const [];
  int? _nextSessionOffset;
  bool _sessionsLoadingMore = false;
  String? _sessionsPageError;
  int _sessionGeneration = 0;
  bool _archivedOnly = false;
  final Set<String> _mutatingSessions = {};
  final Set<String> _deletedSessions = {};
  final Set<String> _quarantinedSessions = {};
  bool blocksSession(String id) =>
      _deletedSessions.contains(id) || _quarantinedSessions.contains(id);
  final _deletedDraftCleanup =
      <String, ({List<DeletedDraftFile> files, Future<void>? writes})>{};
  List<Map<String, dynamic>> _projects = const [];
  bool _creatingProject = false;
  String? _projectsError;
  Map<String, String?>? _projectMembership;
  Map<String, String> _projectMembershipLabels = {};
  Future<void>? _projectMembershipRead;
  int _projectMembershipGeneration = 0;
  int _projectMembershipLimit = 0;
  bool _projectMembershipCoverageChecked = false;
  final Map<String, ProfileChat> _chats = {};
  String? _selectedSession;
  Map<String, dynamic>? _selectedProject;
  List<Map<String, dynamic>> _projectSessions = const [];
  String? _projectSessionsError;
  bool _projectSessionsLoading = false;
  int _projectGeneration = 0;
  int _reconnectAttempt = 0;
  Timer? _retry;
  bool _reconnecting = false;
  Future<void>? _reconnectFuture;
  bool _restartReconnect = false;
  bool _recovering = false;
  bool _loaded = false;
  bool _offlineSnapshot = false;
  String? _reconnectError;

  List<Map<String, dynamic>> get sessions => _sessions;
  int? get nextSessionOffset => _nextSessionOffset;
  bool get sessionsLoadingMore => _sessionsLoadingMore;
  String? get sessionsPageError => _sessionsPageError;
  int get sessionGeneration => _sessionGeneration;
  bool get archivedOnly => _archivedOnly;
  Set<String> get mutatingSessions => Set.unmodifiable(_mutatingSessions);
  Set<String> get deletedSessions => Set.unmodifiable(_deletedSessions);
  Set<String> get quarantinedSessions => Set.unmodifiable(_quarantinedSessions);
  List<Map<String, dynamic>> get projects => _projects;
  bool get creatingProject => _creatingProject;
  String? get projectsError => _projectsError;
  Map<String, ProfileChat> get chats => Map.unmodifiable(_chats);
  String? get selectedSession => _selectedSession;
  Map<String, dynamic>? get selectedProject => _selectedProject;
  List<Map<String, dynamic>> get projectSessions => _projectSessions;
  String? get projectSessionsError => _projectSessionsError;
  bool get projectSessionsLoading => _projectSessionsLoading;
  int get projectGeneration => _projectGeneration;
  int get reconnectAttempt => _reconnectAttempt;
  bool get recovering => _recovering;
  bool get loaded => _loaded;
  bool get offlineSnapshot => _offlineSnapshot;
  String? get reconnectError => _reconnectError;
  bool get reconnectScheduled => _retry != null;

  ProfileWorkspaceData(this.gateway);
  WorkspaceScope get scope => gateway.scope;
  ProfileChat? get chat => _chats[_selectedSession];
  List<Map<String, dynamic>> get visibleSessions =>
      _selectedProject == null ? _sessions : _projectSessions;
}

enum _NotificationActivity { running, waiting, idle }

class _NotificationSession {
  final ProfileChat chat;
  final _NotificationActivity activity;

  const _NotificationSession(this.chat, this.activity);
}

/// A chat with recent messages, optionally enriched with current live work.
class ProfileRecentChat {
  final ProfileSessionKey key;
  final String title;
  final String? source;
  final double lastActive;
  final ProfileLiveActivity? activity;
  final bool unread;
  final BrowserProject? project;
  final String messagePreview;

  const ProfileRecentChat({
    required this.key,
    required this.title,
    required this.source,
    required this.lastActive,
    this.activity,
    this.unread = false,
    this.project,
    this.messagePreview = '',
  });

  ProfileLiveActivityState? get state => activity?.state;
  int get sideTasksRunning => activity?.sideTasksRunning ?? 0;
}

typedef ProfileGatewayFactory = ProfileGateway Function(WorkspaceScope scope);

/// Runtime composition captures both the durable owner and the admitted live ID.
typedef ProfileChatRuntimeFactory =
    execution.ChatRuntime Function(ProfileSessionKey key, String runtimeId);

class ProfileNotification {
  final ProfileSessionKey key;
  final String title;
  final String connectionLabel;
  final ChatNotificationContent content;
  final String? eventId;
  final NotificationFocus? focus;
  final bool alert;

  const ProfileNotification({
    required this.key,
    required this.title,
    required this.connectionLabel,
    required this.content,
    this.eventId,
    this.focus,
    this.alert = true,
  });
}

typedef ProfileAttention =
    Future<void> Function(ProfileNotification notification);

/// Owned by the application, not the workspace/chat widgets. A foreground
/// switch never closes a socket, changes a chat owner, or cancels a turn.
class ProfileWorkspaceController extends ChangeNotifier {
  // Draft text affects the composer, not saved history, notification inputs or
  // background monitoring. Keep keystrokes off the workspace-wide update path.
  final _composerChanges = ChangeNotifier();
  Listenable get composerChanges => _composerChanges;
  Timer? _streamPresentationTimer;
  final _pendingStreamChats = <ProfileSessionKey>{};
  final _retentionChanges = ChangeNotifier();
  Listenable get retentionChanges => _retentionChanges;

  // Runtime events invalidate one browser row. A null chat means saved lists,
  // discovery, navigation or other workspace state may have changed.
  final _browserChanges =
      ValueNotifier<({int revision, ProfileSessionKey? chat})>((
        revision: 0,
        chat: null,
      ));
  ValueListenable<({int revision, ProfileSessionKey? chat})>
  get browserChanges => _browserChanges;

  final _browserMutations = ValueNotifier<BrowserMutation?>(null);
  ValueListenable<BrowserMutation?> get browserMutations => _browserMutations;

  void _browserMutated(BrowserMutation mutation) {
    if (_closed) return;
    _browserMutations.value = mutation;
    _changed();
  }

  ProfileLiveActivityState? reportedActivityFor(ProfileSessionKey key) =>
      _liveActivity
          .where(
            (item) =>
                item.workspace == key.workspace &&
                item.sessionId == key.sessionId,
          )
          .firstOrNull
          ?.state ??
      _detachedActivity[key]?.state;

  /// Unsorted identities whose live state can affect the browser. Saved chats
  /// without a runtime do not need to be visited on an activity notification.
  Iterable<ProfileSessionKey> get browserRuntimeKeys sync* {
    yield* _detachedActivity.keys;
    for (final item in _liveActivity) {
      yield ProfileSessionKey(item.workspace, item.sessionId);
    }
    for (final resource in _resources.values) {
      for (final chat in resource._chats.values) {
        yield chat._key;
      }
    }
  }

  static const _maxReviewNotices = 20;

  /// App-owned failure; distinguish it from opaque command output in the UI.
  static const markReadFailureNotice =
      'The viewed answer could not be marked as read. '
      'Return to Chats and choose Mark as read.';

  final ConnectionAccess access;
  late SavedConnection _connection = access.connection;
  SavedConnection get connection => _connection;

  /// Saved presentation can change without retargeting this workspace's clients.
  void observeConnectionLabel(String label) {
    if (_connection.label == label) return;
    _connection = _connection.copyWith(label: label);
    notifyListeners();
  }

  final String connectionIdentity;
  final SharedPreferences preferences;
  final AppPreferences appPreferences;
  ProfileColorsSession createProfileColors() => ProfileColorsSession(
    preferences: appPreferences,
    connectionIdentity: connectionIdentity,
  );
  AdministrationHealthSession? _healthSession;
  HostResourcesSession? _hostResources;

  /// Routes borrow the captured connection's server adapter. Its authentication
  /// and pool survive screen re-entry; only the workspace retires the adapter.
  /// Constructing the health owner does not dispatch diagnostics.
  AdministrationRepository administration() => healthSession().server;

  /// One host-data owner per captured connection, shared by all surfaces.
  HostResourcesSession hostResources({AdministrationRepository? repository}) =>
      _hostResources ??= HostResourcesSession(
        healthSession(repository: repository).server,
      );
  SkillReaderSession skillReader(SkillReaderTarget document, String profile) =>
      healthSession().server.skillReader(document, profile);
  AdministrationHealthSession healthSession({
    AdministrationRepository? repository,
  }) => _healthSession ??= AdministrationHealthSession(
    repository ??
        AdministrationRepository.forConnection(
          access,
          connectionIdentity,
          connectionStatus: connectionStatus,
        ),
    preferences,
    connectionStatus: connectionStatus,
    ownsServer: repository == null,
  );
  late final ProfileGatewayFactory _factory;
  final ProfileChatRuntimeFactory _runtimeFactory;
  final ProfileGatewayConnection _gatewayConnection;
  final AttachmentDraftService attachments;
  late final ComposerDraftStore _drafts;
  late final DeletedDraftCleanupStore _deletedDrafts;
  final _deletedDraftCleanupPresentation =
      ValueNotifier<DeletedDraftCleanupPresentation>(
        const DeletedDraftCleanupPresentation.empty(),
      );
  final _deletedDraftPresence = <ProfileSessionKey, SessionPresence>{};
  final _deletedDraftRecoveryErrors = <ProfileSessionKey, String>{};
  Map<(String, String), _DeletedDraftCleanupPublicationInput>
  _publishedDeletedDraftInputs = const {};
  final ProfileAttention? onAttention;
  final OperationalErrorReporter? _onOperationalError;
  final Future<void> Function(ProfileInputNotification)? onNotificationInputs;
  final Future<void> Function(ProfileSessionKey, String)? onNotificationRead;
  final NotificationFocus? Function(ProfileSessionKey)? notificationResultFor;
  final List<NotificationInput> Function(ProfileSessionKey)?
  _notificationInputsFor;
  final Map<WorkspaceScope, ProfileWorkspaceData> _resources = {};
  final Map<ProfileSessionKey, ProfileChat> _recoveredDraftTargets = {};
  final Set<ProfileSessionKey> _recoveringStoredDrafts = {};
  final Set<ProfileSessionKey> _unrestoredPending = {};
  bool _pendingOwnersSeeded = false;
  ProfileDiscovery? _discovery;
  ProfileDiscovery? get discovery => _discovery;
  ProfileWorkspaceData? _current;
  ProfileWorkspaceData? get current => _current;
  Future<void>? _workspaceRefreshFuture;
  bool get refreshingWorkspace => _workspaceRefreshFuture != null;
  int _readingRequestGeneration = 0;
  _ChatReadingWindow? _activeReadingWindow;
  String? _pendingProfile;
  String? _error;
  String? _failedSwitchProfile;
  String? _failedSwitchError;
  String? get error => _error ?? _current?._reconnectError;
  final Set<Object> _visibleRoutes = {};
  final Map<Object, ProfileSessionKey?> _mountedRoutes = {};
  bool get visible => _visibleRoutes.isNotEmpty;
  bool get hasMountedRoutes => _mountedRoutes.isNotEmpty;

  /// Visibility controls read acknowledgements; mounted routes own state even
  /// while covered by another route or while the activity is backgrounded.
  void setRouteMounted(Object route, bool mounted) {
    if (_closed) return;
    if (mounted) {
      _mountedRoutes.putIfAbsent(route, () => _current?.chat?._key);
    } else {
      _mountedRoutes.remove(route);
      _visibleRoutes.remove(route);
    }
    _scheduleRetention();
    _syncProcessWatch();
  }

  /// A covered or disposed route releases only its own visibility claim. The
  /// same retained controller can also be displayed by a notification route.
  void setRouteVisibility(Object route, bool isVisible) {
    if (isVisible) {
      _visibleRoutes.add(route);
      if (_mountedRoutes.containsKey(route)) {
        _mountedRoutes[route] = _current?.chat?._key;
      }
    } else {
      _visibleRoutes.remove(route);
    }
    _syncProcessWatch();
  }

  int _generation = 0;
  int _navigationGeneration = 0;
  bool _closed = false;
  bool _initialized = false;
  bool get initialized => _initialized;
  Object? _initializationFailure;
  bool _profileSelectionRepairRequired = false;
  late final ServerConnectionStatus connectionStatus;
  late final WorkspaceSnapshotStore _snapshots;
  final _savedToolDurationRevisions = Expando<(ProfileSessionKey, int)>();
  DateTime? _lastSnapshot;
  bool _readingSnapshotDirty = false;
  ProfileSessionKey? _notificationTarget;
  ProfileChat? get notificationChat =>
      _resources[_notificationTarget?.workspace]?._chats[_notificationTarget
          ?.sessionId];
  Timer? _notificationRetry;
  Future<void>? _notificationOpening;
  Future<void>? _notificationResume;
  int _notificationAttempts = 0;
  int _notificationGeneration = 0;
  bool Function()? _notificationIsCurrent;

  Future<void>? _initializing;
  Timer? _initializationRetry;
  int _initializationAttempt = 0;
  bool _recoveringInitialization = false;
  bool get recovering =>
      _recoveringInitialization || (_current?._recovering ?? false);
  bool get recoveryInProgress =>
      _initializing != null || (_current?._reconnecting ?? false);
  bool _openingSavedDraft = false;
  Future<void> _journalQueue = Future.value();
  List<ProfileLiveActivity> _liveActivity = const [];
  Map<ProfileSessionKey, ProfileLiveActivity> _detachedActivity = const {};
  final _uncertainDetachedWork = <ProfileSessionKey>{};
  Map<String, String> _detachedWorkErrors = const {};
  Future<void>? _detachedWorkRefresh;
  int _detachedWorkGeneration = 0;
  Map<String, String> _activityProfileErrors = const {};
  bool _activityLoading = false;
  bool get activityLoading => _activityLoading;
  int _activityGeneration = 0;
  Map<String, _NotificationSession>? _notificationSnapshot;
  Map<String, ProfileSessionKey> _backgroundChats = const {};
  final _uncertainNotificationRuntimes = <String>{};
  int _pendingNotifications = 0;
  int _pendingCompletions = 0;
  int _pendingPrivateCompletions = 0;
  int _pendingWorkspaceOperations = 0;
  bool _retentionScheduled = false;
  static const settledChatLimit = 20;

  final _liveVoiceChats = <ProfileChat, Set<_WorkspaceLiveVoiceConversation>>{};

  bool _chatOwnsWork(ProfileWorkspaceData resource, ProfileChat chat) =>
      _liveVoiceChats.containsKey(chat) ||
      chat.runtime.blocksTurnAdmission ||
      chat.runtime.activity(
            backgroundWorking: chat._subagents.any((item) => !item.isTerminal),
          ) !=
          null ||
      chat._unconfirmedSubagentIds.isNotEmpty ||
      chat._sideQuestionDeliveries.any(
        (delivery) => delivery.state == SideQuestionDeliveryState.pending,
      ) ||
      chat.runtime.opening ||
      (!chat.composer.observation.restored && !chat.runtime.offline) ||
      chat.reading.historyLoading ||
      chat._projectLoading ||
      chat.composer.observation.text.isNotEmpty ||
      chat.composer.observation.submissionUncertain ||
      chat.composer.observation.sending ||
      chat.composer.observation.attachments.isNotEmpty ||
      chat.composer.observation.queue.isNotEmpty ||
      chat.composer.observation.editing != null ||
      chat.composer.observation.editText.isNotEmpty ||
      chat.composer.observation.saving ||
      chat.composer.observation.draining ||
      chat.composer.observation.steering ||
      chat.runtime.approval != null ||
      chat.runtime.questions != null ||
      chat.runtime.secureInput != null ||
      chat.runtime.approvalResponding ||
      chat.runtime.secureResponding ||
      chat.runtime.commandRunning ||
      chat._runtime.commandDispatchPending ||
      chat.runtime.changingAnswer ||
      chat._changingIntelligence ||
      chat._sessionControlLoading ||
      chat._sessionControlWorking ||
      chat._subagentsLoading ||
      chat._processesLoading ||
      chat._processes.any((process) => process.isRunning) ||
      chat._stoppingProcessIds.isNotEmpty ||
      (chat.composer.observation.preparing ? 1 : 0) > 0 ||
      chat._replacingExpiredRuntime ||
      chat._replacementCompletion != null ||
      chat.composer.admittedWrites != null ||
      chat.reading.notificationReadTarget != null ||
      resource._mutatingSessions.contains(chat._key.sessionId) ||
      _unrestoredPending.contains(chat._key) ||
      reportedActivityFor(chat._key) != null;

  /// Current saved owners are retained by the registry. Obsolete owners may
  /// retire only once all mounted, async, recovery and delivery leases settle.
  bool get hasRetentionObligations =>
      _mountedRoutes.isNotEmpty ||
      switching ||
      recoveryInProgress ||
      _activityLoading ||
      _openingSavedDraft ||
      _notificationTarget != null ||
      _notificationOpening != null ||
      _notificationReconciliation != null ||
      _detachedWorkRefresh != null ||
      _pendingWorkspaceOperations > 0 ||
      _unrestoredPending.isNotEmpty ||
      _liveActivity.isNotEmpty ||
      _detachedActivity.isNotEmpty ||
      hasActiveChats ||
      _resources.values.any(
        (resource) =>
            resource._mutatingSessions.isNotEmpty ||
            resource._deletedDraftCleanup.isNotEmpty ||
            resource._projectMembershipRead != null ||
            resource._sessionsLoadingMore ||
            resource._projectSessionsLoading ||
            resource._reconnecting ||
            resource._chats.values.any((chat) => _chatOwnsWork(resource, chat)),
      );

  @visibleForTesting
  int get retainedChatCount => _resources.values.fold(
    0,
    (count, resource) => count + resource._chats.length,
  );

  void _scheduleRetention() {
    if (_closed || _retentionScheduled) return;
    _retentionScheduled = true;
    scheduleMicrotask(() {
      _retentionScheduled = false;
      if (_closed) return;
      pruneSettledState();
      // Route release and composer changes can settle leases without changing
      // the monitoring fingerprint. The registry must still see that release.
      _retentionChanges.notifyListeners();
    });
  }

  void pruneSettledState() {
    if (_closed || _pendingNotifications > 0 || _pendingCompletions > 0) return;
    final settled = <(ProfileWorkspaceData, ProfileChat)>[];
    for (final resource in _resources.values) {
      for (final chat in resource._chats.values) {
        if (identical(resource, _current) &&
                resource._selectedSession == chat._key.sessionId ||
            _mountedRoutes.containsValue(chat._key) ||
            _chatOwnsWork(resource, chat)) {
          continue;
        }
        settled.add((resource, chat));
      }
    }
    settled.sort((a, b) => b.$2.lastActive.compareTo(a.$2.lastActive));
    var removed = false;
    for (final entry in settled.skip(settledChatLimit)) {
      _cancelImagePreparation(entry.$2);
      entry.$1._chats.remove(entry.$2._key.sessionId);
      entry.$2._runtime.dispose();
      entry.$2.reading.dispose();
      _recoveredDraftTargets.removeWhere(
        (_, chat) => identical(chat, entry.$2),
      );
      removed = true;
    }
    if (removed) _changed();
  }

  Future<T> _retainWorkspaceOperation<T>(Future<T> Function() operation) async {
    _pendingWorkspaceOperations++;
    try {
      return await operation();
    } finally {
      _pendingWorkspaceOperations--;
      _scheduleRetention();
    }
  }

  /// Retain live work until its final state and notification have been saved.
  /// Failed snapshot reads do not prove previously active chats have finished.
  bool get hasActiveChats =>
      _groupNotifications.hasActiveGroups ||
      _detachedActivity.values.any((item) => item.source != 'bot_room') ||
      _pendingNotifications > 0 ||
      _pendingCompletions > _pendingPrivateCompletions ||
      _resources.values.any(
        (resource) => resource._chats.values.any((chat) {
          if (chat.source == 'bot_room') return false;
          final waiting =
              chat.runtime.needsInput ||
              chat.runtime.reconnecting &&
                  (chat.runtime.approval != null ||
                      chat.runtime.questions != null ||
                      chat.runtime.secureInput != null);
          return (!waiting &&
                  (chat.runtime.blocksTurnAdmission ||
                      chat.runtime.commandRunning)) ||
              chat.composer.observation.draining ||
              chat._subagents.any((task) => !task.isTerminal);
        }),
      ) ||
      _backgroundChats.entries.any(
        (entry) =>
            _notificationSnapshot?[entry.key]?.chat.source != 'bot_room' &&
            !_hasLoadedNotificationChat(entry.key, entry.value.sessionId),
      );

  GroupObservations get groupObservations => _groupObservations;
  late final GroupObservations _groupObservations = GroupObservations(
    WorkspaceScope(
      connectionId: connection.id,
      connectionIdentity: connectionIdentity,
      profileName: 'default',
    ),
  );
  late final GroupNotificationSession _groupNotifications;
  late final bool _groupNotificationsEnabled;
  Future<void> activateGroupNotifications() => _groupNotificationsEnabled
      ? _groupNotifications.activate()
      : Future.value();

  /// Views and composition issue commands; the retained watcher stays private.
  Future<void> refreshGroupNotifications() => _groupNotificationsEnabled
      ? _groupNotifications.refresh()
      : Future.value();
  Future<bool> approveGroupNotification(
    GroupNotificationTarget target,
    String focus,
    String choice,
    String? command,
  ) {
    if (_closed ||
        target.scope.connectionId != connection.id ||
        target.scope.connectionIdentity != connectionIdentity) {
      throw StateError('The original connection is unavailable');
    }
    return _groupNotifications.resolveApproval(
      target.roomId,
      focus,
      choice,
      command,
    );
  }

  void setGroupNotificationsForeground(bool foreground) =>
      _groupNotifications.setForeground(foreground);
  void _requireGroupOwner(BotGroup group) {
    if (group.scope.connectionId != connection.id ||
        group.scope.connectionIdentity != connectionIdentity) {
      throw StateError('Group belongs to another connection');
    }
  }

  Future<void> beginGroupSend(BotGroup group, String eventId) async {
    _requireGroupOwner(group);
    if (!_groupNotificationsEnabled || _closed) return;
    await _groupNotifications.beginSend(group.id, group.name, eventId);
    await _groupNotifications.activate();
  }

  Future<void> finishGroupSend(
    BotGroup group,
    String eventId, {
    required bool dispatched,
    int? sequence,
  }) {
    _requireGroupOwner(group);
    if (!_groupNotificationsEnabled || _closed) return Future.value();
    return _groupNotifications.endSend(
      group.id,
      eventId,
      dispatched: dispatched,
      sequence: sequence,
    );
  }

  Future<void> acknowledgeGroupAnswer(BotGroup group, int sequence) {
    _requireGroupOwner(group);
    if (!_groupNotificationsEnabled || _closed) return Future.value();
    return _groupNotifications.acknowledge(group.id, sequence);
  }

  Future<void>? _notificationReconciliation;
  bool _notificationReconcileAgain = false;
  late AppPreferenceControl<SessionVisibility> _lastVisibilityPresentation;
  late final ValueListenable<ProfileSelectionFact> _profileSelection;
  String? _selectionError;
  bool get requiresProfileSelectionRepair =>
      !_initialized &&
      (_profileSelectionRepairRequired ||
          _initializationFailure is ProfileSelectionRepairRequired ||
          switch (_profileSelection.value.validity) {
            ProfileSelectionValidity.invalid ||
            ProfileSelectionValidity.unavailable ||
            ProfileSelectionValidity.unverified => true,
            _ => false,
          });
  bool get profileSelectionRepairBusy =>
      switching || _profileSelection.value.busy;
  Future<void>? _visibilityRefresh;
  SessionVisibility? get sessionVisibility => visibilityControl.selected;
  AppPreferenceControl<SessionVisibility> get visibilityControl =>
      appPreferences.visibilityFor(connection.id);
  bool includesSession(String? source, {bool hidden = false}) =>
      sessionVisibility?.includes(source, hidden: hidden) == true;
  SessionVisibility _requiredSessionVisibility() =>
      sessionVisibility ??
      (throw StateError('Repair the saved chat filter before loading chats.'));

  ProfileWorkspaceController({
    required this.access,
    required this.connectionIdentity,
    required this.preferences,
    required this.appPreferences,
    ProfileGatewayFactory? gatewayFactory,
    ProfileChatRuntimeFactory? runtimeFactory,
    AttachmentDraftService? attachmentService,
    ComposerDraftStore? draftStore,
    this.onAttention,
    OperationalErrorReporter? onOperationalError,
    this.onNotificationInputs,
    this.onNotificationRead,
    this.notificationResultFor,
    Future<void> Function(GroupAnswerNotification)? onGroupAnswer,
    Future<void> Function(GroupInputNotification)? onGroupInputs,
    Future<void> Function(GroupNotificationTarget, int)? onGroupAnswerRead,
    List<NotificationInput> Function(ProfileSessionKey)? notificationInputsFor,
    // Keep injected callbacks private behind the workspace boundary.
    // ignore: prefer_initializing_formals
  }) : _notificationInputsFor = notificationInputsFor,
       // ignore: prefer_initializing_formals
       _onOperationalError = onOperationalError,
       _gatewayConnection = ProfileGatewayConnection(access),
       _runtimeFactory = runtimeFactory ?? _createRuntime,
       attachments = attachmentService ?? AttachmentDraftService() {
    _factory = gatewayFactory ?? _gatewayConnection.create;
    if (connectionIdentity.isEmpty) {
      throw ArgumentError('A verified connection identity is required');
    }
    _lastVisibilityPresentation = visibilityControl;
    _drafts =
        draftStore ??
        ComposerDraftStore(preferences, connectionIdentity: connectionIdentity);
    connectionStatus = ServerConnectionStatus(connection.label);
    _groupNotificationsEnabled =
        onAttention != null || onGroupAnswer != null || onGroupInputs != null;
    _groupNotifications = GroupNotificationSession(
      observations: groupObservations,
      scope: WorkspaceScope(
        connectionId: connection.id,
        connectionIdentity: connectionIdentity,
        profileName: 'default',
      ),
      instance: connection.label,
      preferences: preferences,
      read: (method, params) async {
        final gateway = _resource('default').gateway;
        await gateway.connect();
        return gateway.call(method, params);
      },
      command: (method, params) async {
        final gateway = _resource('default').gateway;
        await gateway.connect();
        if (_closed) throw StateError('Connection retired');
        return gateway.call(method, params);
      },
      publishInputs: (inputs) async {
        if (onGroupInputs == null) {
          if (inputs.inputs.isNotEmpty) {
            throw StateError('Group approval delivery unavailable');
          }
          return;
        }
        await onGroupInputs(inputs);
      },
      publish: (answer) async {
        if (onGroupAnswer == null) {
          throw StateError('Group notification delivery is unavailable');
        }
        await onGroupAnswer(answer);
      },
      clearRead: (target, sequence) async =>
          onGroupAnswerRead?.call(target, sequence),
    );
    _groupNotifications.addListener(_changed);
    connectionStatus.retry = resumeConnection;
    connectionStatus.onInterruption = () {
      final resource = _current;
      if (!_closed &&
          _initialized &&
          _notificationTarget == null &&
          resource != null) {
        _scheduleReconnect(resource);
        _changed();
      }
    };
    _deletedDrafts = DeletedDraftCleanupStore(
      preferences,
      connectionId: connection.id,
      connectionIdentity: connectionIdentity,
    );
    _snapshots = WorkspaceSnapshotStore(preferences, connectionIdentity);
    _restoreReadingSnapshot();
    appPreferences.state.addListener(_visibilityChanged);
    _profileSelection = appPreferences.profileSelectionFor(connectionIdentity);
    _profileSelection.addListener(_selectionChanged);
  }

  void _selectionChanged() {
    if (_closed) return;
    final fact = _profileSelection.value;
    if (fact.error != null || error == _selectionError) _error = fact.error;
    _selectionError = fact.error;
    _changed();
    if (_profileSelectionRepairRequired && !_initialized && !fact.busy) {
      final generation = _generation;
      scheduleMicrotask(() async {
        try {
          await _finishInitialization(generation);
          if (!_closed && generation == _generation) _changed();
        } catch (failure) {
          if (!_closed && generation == _generation) {
            _initializationFailed(failure);
            _changed();
          }
        }
      });
    }
  }

  Future<void> setSessionVisibility(SessionVisibility value) async {
    if (_closed || switching) return;
    await appPreferences.setConnectionVisibility(connection.id, value);
    await _visibilityRefresh;
  }

  Future<void> toggleSessionVisibility() => setSessionVisibility(
    _requiredSessionVisibility() == SessionVisibility.all
        ? SessionVisibility.chats
        : SessionVisibility.all,
  );

  void _visibilityChanged() {
    if (_closed) return;
    final next = visibilityControl;
    final previous = _lastVisibilityPresentation;
    final modeChanged = next.selected != previous.selected;
    _lastVisibilityPresentation = next;
    if (modeChanged) {
      for (final data in _resources.values) {
        _invalidateSessionLoad(data);
        data._sessions = _readonlyWorkspaceRows([]);
        data._nextSessionOffset = 0;
        data._sessionsPageError = null;
      }
      if (next.selected != null && (_current != null || _discovery != null)) {
        _visibilityRefresh = _reloadVisibility(next.selected!);
      }
    }
    if (modeChanged ||
        next.busy != previous.busy ||
        next.notice != previous.notice ||
        next.error != previous.error) {
      _changed();
    }
  }

  Future<void> _reloadVisibility(SessionVisibility value) async {
    final resource = _current;
    if (resource == null) {
      if (!_closed && sessionVisibility == value) await initialize();
      return;
    }
    try {
      await _refreshSessions(resource);
    } catch (_) {
      if (!_closed && _current == resource && sessionVisibility == value) {
        resource._sessionsPageError = 'Chats could not be loaded. Retry.';
        _changed();
      }
    }
    if (!_closed && _current == resource && sessionVisibility == value) {
      _changed();
    }
  }

  Iterable<ProfileChat> get activity => _resources.values
      .expand((r) => r._chats.values)
      .where(
        (chat) =>
            chat.runtime.execution != ChatExecution.idle ||
            chat.runtime.needsInput ||
            chat.runtime.reconnecting,
      );
  List<ProfileLiveActivity> get liveActivity {
    // Live events can report work before the global active-session snapshot.
    // Merge by the owned chat identity so both sources produce one row.
    final items = {
      ..._detachedActivity,
      for (final item in _liveActivity)
        ProfileSessionKey(item.workspace, item.sessionId): item,
    };
    for (final resource in _resources.values) {
      for (final chat in resource._chats.values) {
        final state = chat.runtime.activity(
          backgroundWorking: chat._subagents.any((item) => !item.isTerminal),
        );
        if (state == null) continue;
        final reported = items[chat._key];
        items[chat._key] = ProfileLiveActivity(
          workspace: chat._key.workspace,
          runtimeId: chat.runtime.runtimeId,
          sessionId: chat._key.sessionId,
          title: chat._title,
          source: chat._source,
          lastActive: chat._lastActive,
          state: state,
          sideTasksRunning: reported?.sideTasksRunning ?? 0,
        );
      }
    }
    return List.unmodifiable(
      items.values
          .where(
            (item) =>
                !(_resources[item.workspace]?.blocksSession(item.sessionId) ??
                    false),
          )
          .toList()
        ..sort((a, b) => b.lastActive.compareTo(a.lastActive)),
    );
  }

  List<ProfileRecentChat> _savedRecents = const [];
  final _recentSessionRows = <ProfileSessionKey, Map<String, dynamic>>{};
  final _recentMessageTimes = <ProfileSessionKey, double>{};
  final _recentMessagePreviews = <ProfileSessionKey, String>{};
  // TranscriptReading replaces its immutable rows on every history edit.
  // Weak keys reuse unchanged excerpts without retaining evicted histories.
  final _recentReadingSummaries = Expando<({double? time, String preview})>();

  ({double? time, String preview}) _recentReadingSummary(
    List<Map<String, dynamic>> messages,
  ) {
    if (_recentReadingSummaries[messages] case final cached?) return cached;
    final started = CompletionDiagnostics.start();
    final summary = (
      time: _latestMessageTime(messages),
      preview: recentChatMessagePreview(messages) ?? '',
    );
    CompletionDiagnostics.finish('recents.reading_summary', started);
    return _recentReadingSummaries[messages] = summary;
  }

  bool _recentsLoading = false;
  Future<void>? _recentsRefresh;
  bool get recentsLoading => _recentsLoading;
  bool _recentsLoaded = false;
  bool get recentsLoaded => _recentsLoaded;
  int _recentsAvailableProfiles = 0;
  int get recentsAvailableProfiles => _recentsAvailableProfiles;
  int _recentsGeneration = 0;
  Map<String, String> _recentsProfileErrors = const {};

  Map<String, String> get recentsProfileErrors =>
      Map.unmodifiable({..._recentsProfileErrors, ...activityProfileErrors});

  static double? _latestMessageTime(List<Map<String, dynamic>> messages) {
    double? latest;
    for (final message in messages) {
      final time = message['timestamp'];
      if (time is num && time.isFinite && (latest == null || time > latest)) {
        latest = time.toDouble();
      }
    }
    return latest;
  }

  /// Null means an older page is needed to find an answer or reach the read
  /// watermark. Tool execution, hidden context and outgoing prompts are not
  /// answers, even though stock session activity can mark them unread.
  static bool? _recentUnreadAnswer(
    List<Map<String, dynamic>> messages,
    num? lastRead, {
    int? readThrough,
  }) {
    for (final row in messages.reversed) {
      final message = TranscriptMessage.fromRow(row);
      final calls = row['tool_calls'];
      final time = row['timestamp'];
      if (message.role != 'assistant' ||
          message.kind != TranscriptMessageKind.dialogue ||
          message.text.trim().isEmpty ||
          (calls is List && calls.isNotEmpty)) {
        continue;
      }
      final id = row['id'];
      if (readThrough != null && id is int) return id > readThrough;
      if (time is! num || !time.isFinite) continue;
      return lastRead == null || time > lastRead;
    }
    final time = _latestMessageTime(messages);
    return lastRead != null && time != null && time <= lastRead ? false : null;
  }

  final _readAcknowledgements = Expando<int>();
  final _readingAcknowledgementsPending = <ProfileChat>{};

  /// Called with the message reached by the shared viewport's user-scroll rule.
  /// Stock Hermes accepts a timestamp acknowledgement, not a message ID. The
  /// in-memory watermark remains authoritative for detecting newer unseen IDs.
  Future<void> acknowledgeVisibleReading(
    ProfileChat chat,
    int messageId,
  ) async {
    bool admitted() =>
        !_closed &&
        visible &&
        identical(_current?.chat, chat) &&
        !chat.runtime.opening &&
        !chat.runtime.offline &&
        !chat.reading.historyLoading &&
        chat.reading.historyError == null;
    if (!admitted() ||
        _readingAcknowledgementsPending.contains(chat) ||
        (_readAcknowledgements[chat] ?? -1) >= messageId) {
      return;
    }
    final latestAnswer = chat.reading.messages.reversed.where((row) {
      final message = TranscriptMessage.fromRow(row);
      final calls = row['tool_calls'];
      return row['id'] is int &&
          message.role == 'assistant' &&
          message.kind == TranscriptMessageKind.dialogue &&
          message.text.trim().isNotEmpty &&
          !(calls is List && calls.isNotEmpty);
    }).firstOrNull;
    final latestAnswerId = latestAnswer?['id'];
    if (latestAnswerId is! int || latestAnswerId > messageId) return;
    final generation = chat.reading.historyGeneration;
    final key = chat.key;
    _readingAcknowledgementsPending.add(chat);
    try {
      await mutateSession(
        key,
        changes: const {'unread': false},
        observedReadThrough: messageId,
        canDispatch: () =>
            admitted() &&
            chat.key == key &&
            chat.reading.historyGeneration == generation,
      );
      if (!_closed) _readAcknowledgements[chat] = messageId;
    } catch (failure, stack) {
      logConnectionDiagnostic(
        'reading.acknowledgement_failed',
        details: {
          'connection': key.workspace.connectionId,
          'profile': key.workspace.profileName,
          ...workspaceFailureDiagnostic(failure),
        },
        error: failure,
        stackTrace: stack,
      );
      if (admitted() && chat.reading.historyGeneration == generation) {
        chat._markReadFailed = true;
        _changed();
      }
    } finally {
      _readingAcknowledgementsPending.remove(chat);
      final newer = chat.reading.readingPosition.readThrough;
      if (admitted() && newer != null && newer > messageId) {
        unawaited(acknowledgeVisibleReading(chat, newer));
      }
    }
  }

  bool _recentChatUnread(ProfileSessionKey key) {
    final resource = _resources[key.workspace];
    final row =
        _recentSessionRows[key] ??
        resource?._sessions
            .where((row) => row['id'] == key.sessionId)
            .firstOrNull;
    final observedAt = _recentMessageTimes[key];
    final chat = resource?._chats[key.sessionId];
    final localRead = ConversationReadingRegistry(
      preferences,
    ).chat(key).position.readThrough;
    if (localRead != null &&
        chat != null &&
        _recentUnreadAnswer(
              chat.reading.messages,
              null,
              readThrough: localRead,
            ) ==
            true) {
      return true;
    }
    if (observedAt != null && chat != null) {
      final lastRead = row?['last_read_at'];
      final watermark =
          lastRead is num && lastRead.isFinite && lastRead > observedAt
          ? lastRead
          : observedAt;
      // A newer delivered answer supersedes the cached list's unread flag.
      // Prompts/tools cannot promote unread, and partial/older reading cannot
      // clear a server-confirmed unread answer.
      if (_recentUnreadAnswer(chat.reading.messages, watermark) == true) {
        return true;
      }
    }
    return row?['unread'] == true;
  }

  /// Freshness, excerpt and answer eligibility share stock history reads.
  /// Paging stops once the excerpt and unread answer are known, without ever
  /// acknowledging a chat during a passive refresh.
  Future<({double? time, String preview, bool unread})>
  _recentMessageObservation(
    ProfileWorkspaceData resource,
    String id,
    int generation, {
    bool checkUnread = false,
    Object? lastRead,
  }) async {
    var page = await resource.gateway.history(
      id,
      limit: 1,
      inlineImages: false,
    );
    final time = _latestMessageTime(page.rows);
    var preview = recentChatMessagePreview(page.rows);
    final watermark = lastRead is num && lastRead.isFinite ? lastRead : null;
    // Stock zero is an explicit unread choice, independent of local progress.
    final localRead = checkUnread && watermark == 0
        ? null
        : ConversationReadingRegistry(
            preferences,
          ).chat(ProfileSessionKey(resource.scope, id)).position.readThrough;
    bool? unread = checkUnread || watermark != null || localRead != null
        ? _recentUnreadAnswer(page.rows, watermark, readThrough: localRead)
        : false;
    while ((preview == null || unread == null) &&
        page.nextOffset != null &&
        !_closed &&
        generation == _recentsGeneration) {
      page = await resource.gateway.history(
        id,
        offset: page.nextOffset!,
        limit: 20,
        inlineImages: false,
      );
      preview ??= recentChatMessagePreview(page.rows);
      unread ??= _recentUnreadAnswer(
        page.rows,
        watermark,
        readThrough: localRead,
      );
    }
    return (time: time, preview: preview ?? '', unread: unread ?? false);
  }

  /// Recency is independent of live status: completed and idle chats stay here.
  /// Technical sessions stay hidden regardless of the chat browser preference.
  List<ProfileRecentChat> recentChats({DateTime? now}) {
    final cutoff =
        (now ?? DateTime.now()).millisecondsSinceEpoch / 1000 - 86400;
    final items = <ProfileSessionKey, ProfileRecentChat>{};
    for (final item in [
      ..._savedRecents,
      for (final resource in _resources.values)
        for (final chat in resource._chats.values)
          if (_recentReadingSummary(chat.reading.messages) case (
            time: final time?,
            preview: final preview,
          ))
            ProfileRecentChat(
              key: chat._key,
              title: chat._title,
              source: chat._source,
              lastActive: time,
              messagePreview: preview,
            ),
    ]) {
      if (!SessionVisibility.chats.includes(item.source) ||
          item.lastActive < cutoff ||
          (_resources[item.key.workspace]?.blocksSession(item.key.sessionId) ??
              false)) {
        continue;
      }
      final previous = items[item.key];
      if (previous == null || item.lastActive > previous.lastActive) {
        items[item.key] = item;
      }
    }
    for (final live in liveActivity) {
      if (!SessionVisibility.chats.includes(live.source)) continue;
      final key = ProfileSessionKey(live.workspace, live.sessionId);
      final previous = items[key];
      items[key] = ProfileRecentChat(
        key: key,
        title: live.title,
        source: live.source,
        lastActive: previous?.lastActive ?? _recentMessageTimes[key] ?? 0,
        activity: live,
        messagePreview:
            previous?.messagePreview ?? _recentMessagePreviews[key] ?? '',
      );
    }
    return [
      for (final item in items.values)
        ProfileRecentChat(
          key: item.key,
          title:
              _resources[item.key.workspace]
                  ?._chats[item.key.sessionId]
                  ?.title ??
              item.title,
          source: item.source,
          lastActive: item.lastActive,
          activity: item.activity,
          unread: _recentChatUnread(item.key),
          project: _recentProject(item.key),
          messagePreview: item.messagePreview,
        ),
    ]..sort((a, b) => b.lastActive.compareTo(a.lastActive));
  }

  BrowserProject? _recentProject(ProfileSessionKey key) {
    final resource = _resources[key.workspace];
    final projectId =
        resource?._chats[key.sessionId]?._projectId ??
        resource?._projectMembership?[key.sessionId];
    final row = resource?._projects
        .where((p) => p['id'] == projectId)
        .firstOrNull;
    return row == null ? null : BrowserProject.fromWire(row);
  }

  RecentConversationSession recentConversationSession({
    required Iterable<RecentConversationEntry> entries,
    required WorkspaceRecentsCache recents,
    required Future<void> Function(BotGroup) onOpenGroup,
    required ValueListenable<ChatNoticeActivity?> activity,
  }) => RecentConversationSession.fromRecents(
    entries: entries,
    source: _WorkspaceRecentConversationSource(
      this,
      recents,
      onOpenGroup,
      routeOrigin: null,
      onOpenChat: null,
    ),
    activity: activity,
  );

  RecentConversationSession chatRecentConversationSession({
    required ProfileChat chat,
    required WorkspaceRecentsCache recents,
    required Future<void> Function(BotGroup) onOpenGroup,
    required ValueListenable<ChatNoticeActivity?> Function() activity,
  }) => RecentConversationSession.fromChat(
    chat: RecentConversationEntry.chat(
      key: chat.key,
      title: chat.title,
      unread: false,
    ),
    source: _WorkspaceRecentConversationSource(
      this,
      recents,
      onOpenGroup,
      routeOrigin: null,
      onOpenChat: null,
    ),
    activity: activity,
  );

  RecentConversationSession groupRecentConversationSession({
    required BotGroup group,
    required bool fromRecents,
    required WorkspaceRecentsCache recents,
    required Future<void> Function(BotGroup) onOpenGroup,
    required Future<void> Function(RecentConversationKey) onOpenChat,
    required ValueListenable<ChatNoticeActivity?> Function() activity,
  }) {
    final entry = RecentConversationEntry.group(
      group,
      unread: recents.bots.groupReads.unread(group),
    );
    final source = _WorkspaceRecentConversationSource(
      this,
      recents,
      onOpenGroup,
      routeOrigin: RecentConversationKey.group(group.key),
      onOpenChat: onOpenChat,
    );
    return fromRecents
        ? RecentConversationSession.fromRecents(
            entries: [
              ...recents.catalog.entries,
              if (!recents.catalog.entries.any((item) => item.key == entry.key))
                entry,
            ],
            source: source,
            activity: activity(),
          )
        : RecentConversationSession.fromChat(
            chat: entry,
            source: source,
            activity: activity,
          );
  }

  Future<void> refreshRecents() {
    if (_recentsRefresh case final pending?) return pending;
    final completion = Completer<void>();
    // Install the shared operation before publishing Loading to observers.
    _recentsRefresh = completion.future;
    unawaited(() async {
      try {
        await _refreshRecents();
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      } finally {
        _recentsRefresh = null;
      }
    }());
    return completion.future;
  }

  Future<void> _refreshRecents() async {
    final generation = ++_recentsGeneration;
    _recentsLoading = true;
    _changed();
    final liveRefresh = refreshActivity();
    try {
      final profiles = await _resource('default').gateway.discover();
      final cutoff = DateTime.now().millisecondsSinceEpoch / 1000 - 86400;
      final results = await Future.wait(
        profiles.profiles.map((profile) async {
          final resource = _resource(profile.name);
          final items = <ProfileSessionKey, ProfileRecentChat>{};
          final rows = <ProfileSessionKey, Map<String, dynamic>>{};
          final checkedSessions = <String>{};
          String? profileError;
          try {
            try {
              final projects = await browserProjects(
                profile.name,
                sessionLimit: ProfileGateway.projectSessionScanLimit,
                canRead: () => !_closed && generation == _recentsGeneration,
              );
              if (!_closed && generation == _recentsGeneration) {
                resource._projects = _readonlyWorkspaceRows(projects);
              }
            } catch (_) {
              // Project context is optional; keep independently readable chats.
            }
            int? offset = 0;
            while (offset != null) {
              final page = await resource.gateway.sessions(
                offset: offset,
                limit: 100,
                includeArchived: true,
              );
              if (_closed || generation != _recentsGeneration) break;
              var hasRecent = false;
              final candidates = <Map<String, dynamic>>[];
              for (final row in page.rows) {
                final time = row['last_active'];
                if (time is! num || !time.isFinite || time < cutoff) continue;
                hasRecent = true;
                if (!SessionVisibility.chats.includes(
                  row['source'] as String?,
                )) {
                  continue;
                }
                if (checkedSessions.add(row['id'] as String)) {
                  candidates.add(row);
                }
              }
              // Session activity includes heartbeats and creation. Check actual
              // message timestamps with bounded, read-only history requests.
              for (var start = 0; start < candidates.length; start += 4) {
                final batch = candidates.skip(start).take(4);
                final messages = await Future.wait(
                  batch.map((row) async {
                    final message = await _recentMessageObservation(
                      resource,
                      row['id'] as String,
                      generation,
                      checkUnread: row['unread'] == true,
                      lastRead: row['last_read_at'],
                    );
                    return (
                      row: row,
                      time: message.time,
                      preview: message.preview,
                      unread: message.unread,
                    );
                  }),
                );
                if (_closed || generation != _recentsGeneration) {
                  return (
                    profile: profile.name,
                    items: <ProfileRecentChat>[],
                    rows: <ProfileSessionKey, Map<String, dynamic>>{},
                    error: null as String?,
                  );
                }
                for (final result in messages) {
                  final time = result.time;
                  if (time == null || time < cutoff) continue;
                  final row = result.row;
                  final key = ProfileSessionKey(
                    resource.scope,
                    row['id'] as String,
                  );
                  rows[key] = {...row, 'unread': result.unread};
                  _recentMessageTimes[key] = time;
                  _recentMessagePreviews[key] = result.preview;
                  final title = row['title'] as String?;
                  items[key] = ProfileRecentChat(
                    key: key,
                    title: title == null || title.trim().isEmpty
                        ? 'Chat'
                        : title.trim(),
                    source: row['source'] as String?,
                    lastActive: time,
                    messagePreview: result.preview,
                  );
                }
              }
              offset = hasRecent ? page.nextOffset : null;
            }
            // Stock session lists omit hidden canonical Bot Chats. Their
            // retained transcript is not a read receipt: fetch the exact owner
            // and compare its watermark with current saved message freshness.
            final unlisted = resource._chats.values
                .where(
                  (chat) =>
                      SessionVisibility.chats.includes(chat.source) &&
                      !resource.blocksSession(chat.key.sessionId) &&
                      !checkedSessions.contains(chat.key.sessionId),
                )
                .map((chat) => chat.key)
                .toList();
            for (var start = 0; start < unlisted.length; start += 4) {
              final observations = await Future.wait(
                unlisted.skip(start).take(4).map((key) async {
                  final row = await resource.gateway.sessionMetadata(
                    key.sessionId,
                  );
                  if (row == null) return null;
                  final message = await _recentMessageObservation(
                    resource,
                    key.sessionId,
                    generation,
                    checkUnread: true,
                    lastRead: row['last_read_at'],
                  );
                  return (
                    key: key,
                    row: row,
                    time: message.time,
                    preview: message.preview,
                    unread: message.unread,
                  );
                }),
              );
              if (_closed || generation != _recentsGeneration) break;
              for (final observation in observations) {
                if (observation == null) continue;
                final time = observation.time;
                if (time == null || time < cutoff) continue;
                final row = observation.row;
                if (!SessionVisibility.chats.includes(
                  row['source'] as String?,
                )) {
                  continue;
                }
                rows[observation.key] = {...row, 'unread': observation.unread};
                _recentMessageTimes[observation.key] = time;
                _recentMessagePreviews[observation.key] = observation.preview;
                items[observation.key] = ProfileRecentChat(
                  key: observation.key,
                  title: row['title'] as String? ?? 'Chat',
                  source: row['source'] as String?,
                  lastActive: time,
                  messagePreview: observation.preview,
                );
              }
            }
          } catch (_) {
            profileError = 'Recent chats unavailable for ${profile.label}.';
          }
          return (
            profile: profile.name,
            items: items.values.toList(),
            rows: rows,
            error: profileError,
          );
        }),
      );
      if (_closed || generation != _recentsGeneration) return;
      final previousRows = Map.of(_recentSessionRows);
      final previousChats = _savedRecents;
      _recentSessionRows.clear();
      final retained = <ProfileSessionKey, ProfileRecentChat>{};
      for (final result in results) {
        if (result.error != null) {
          for (final chat in previousChats) {
            if (chat.key.workspace.profileName != result.profile) continue;
            retained[chat.key] = chat;
            if (previousRows[chat.key] case final row?) {
              _recentSessionRows[chat.key] = row;
            }
          }
        }
        for (final chat in result.items) {
          retained[chat.key] = chat;
        }
        _recentSessionRows.addAll(result.rows);
      }
      _savedRecents = List.unmodifiable(retained.values);
      _recentsProfileErrors = {
        for (final result in results)
          if (result.error != null) result.profile: result.error!,
      };
      _recentsAvailableProfiles = results
          .where((result) => result.error == null)
          .length;
    } catch (_) {
      if (_closed || generation != _recentsGeneration) return;
      _recentsProfileErrors = {'recents': 'Recent chats could not be loaded.'};
      _recentsAvailableProfiles = 0;
    } finally {
      await liveRefresh;
      if (!_closed && generation == _recentsGeneration) {
        for (final live in liveActivity) {
          final key = ProfileSessionKey(live.workspace, live.sessionId);
          if (!SessionVisibility.chats.includes(live.source) ||
              _recentMessageTimes.containsKey(key)) {
            continue;
          }
          try {
            final message = await _recentMessageObservation(
              _resource(live.workspace.profileName),
              live.sessionId,
              generation,
            );
            if (_closed || generation != _recentsGeneration) return;
            final time = message.time;
            if (time != null) {
              _recentMessageTimes[key] = time;
              _recentMessagePreviews[key] = message.preview;
            }
          } catch (_) {
            /* Unknown message age stays unknown, never a runtime age. */
          }
        }
      }
      if (!_closed && generation == _recentsGeneration) {
        _recentsLoaded = true;
        _recentsLoading = false;
        _changed();
      }
    }
  }

  Map<String, String> get activityProfileErrors =>
      Map.unmodifiable({..._activityProfileErrors, ..._detachedWorkErrors});
  bool get switching => _pendingProfile != null;
  String get _journalKey => 'profile_pending_v2_$connectionIdentity';

  bool owns(ProfileSessionKey key) =>
      key.workspace.connectionId == connection.id &&
      key.workspace.connectionIdentity == connectionIdentity;

  /// Forward observations from readers owned by this live connection.
  void reportOperationalError(OperationalErrorObservation observation) {
    if (_closed || observation.connectionIdentity != connectionIdentity) return;
    _onOperationalError?.call(observation);
  }

  Future<ComposerSavedWork?> savedDraft(ProfileSessionKey key) async {
    if (!owns(key)) {
      throw ArgumentError('Wrong connection settings or host');
    }
    if (_deletedDrafts.blocks(key.workspace.profileName, key.sessionId)) {
      return Future.value(null);
    }
    final value = await _drafts.read(
      profileName: key.workspace.profileName,
      sessionId: key.sessionId,
    );
    return value == null ? null : ComposerSession.savedObservation(value);
  }

  int get savedDraftRevision => _drafts.revision;

  List<ComposerDraftSummary> savedDrafts(WorkspaceScope owner) {
    if (!owns(ProfileSessionKey(owner, 'draft'))) {
      throw ArgumentError('Wrong connection settings or host');
    }
    return _drafts
        .summaries(profileName: owner.profileName)
        .where(
          (draft) => !_deletedDrafts.blocks(owner.profileName, draft.sessionId),
        )
        .toList();
  }

  Future<void> openSavedDraft(WorkspaceScope owner, String sessionId) async {
    final key = ProfileSessionKey(owner, sessionId);
    if (!owns(key)) {
      throw ArgumentError('Wrong connection settings or host');
    }
    if (sessionId.isEmpty || switching || _current?.scope != owner) {
      throw StateError('Profile changed. Open the draft again.');
    }
    if (_openingSavedDraft) {
      throw StateError('Wait for the saved draft to open.');
    }
    _openingSavedDraft = true;
    try {
      if (await savedDraft(key) == null) {
        throw StateError('The saved draft is no longer available.');
      }
      if (_closed || switching || _current?.scope != owner) {
        throw StateError('Profile changed. Open the draft again.');
      }
      try {
        final opened = await openSession(key);
        if (opened == null) {
          throw StateError('The saved draft could not be opened.');
        }
        return;
      } on JsonRpcError catch (error) {
        if (!_isMissingSessionResume(error)) rethrow;
      }
      if (_closed || switching || _current?.scope != owner) {
        throw StateError('Profile changed. Open the draft again.');
      }
      if (await savedDraft(key) == null) {
        throw StateError('The saved draft is no longer available.');
      }
      final destination = await createChat(
        owner: owner,
        canDispatch: () => !_closed && !switching && current?.scope == owner,
      );
      await recoverDraft(key, destination);
    } finally {
      _openingSavedDraft = false;
    }
  }

  Future<void> discardSavedDraft(
    WorkspaceScope owner,
    ComposerDraftSummary draft,
  ) async {
    final key = ProfileSessionKey(owner, draft.sessionId);
    if (!owns(key)) throw ArgumentError('Wrong connection settings or host');
    if (_openingSavedDraft) {
      throw StateError('Wait for the saved draft action to finish.');
    }
    if (_deletedDrafts.blocks(owner.profileName, draft.sessionId)) {
      throw StateError('Chat deletion is pending. Local work is kept.');
    }
    final chat = _resources[owner]?._chats[draft.sessionId];
    void checkAvailable() {
      if (_closed || switching || _current?.scope != owner) {
        throw StateError('Profile changed. Open the draft actions again.');
      }
      if (chat != null &&
          (chat.runtime.blocksTurnAdmission ||
              chat == _current?.chat ||
              chat.composer.observation.saving ||
              chat.composer.observation.draining ||
              (chat.composer.observation.preparing ? 1 : 0) > 0 ||
              chat._replacingExpiredRuntime ||
              chat.composer.observation.sending)) {
        throw StateError('This draft is in use. Close the chat and try again.');
      }
    }

    checkAvailable();
    _openingSavedDraft = true;
    try {
      await chat?.composer.admittedWrites;
      checkAvailable();
      final currentDraft = _drafts
          .summaries(profileName: owner.profileName)
          .where((value) => value.sessionId == draft.sessionId)
          .firstOrNull;
      if (currentDraft == null) return;
      if (currentDraft != draft) {
        throw StateError(
          'The draft changed. Open its actions again to review it.',
        );
      }
      if (chat == null) {
        await _clearStoredDraft(owner, draft.sessionId);
      } else {
        await chat.composer.discard();
      }
      _changed();
    } finally {
      _openingSavedDraft = false;
    }
  }

  void _changed({ProfileSessionKey? browserChat, bool saveReading = true}) {
    if (_closed) return;
    _syncProcessWatch();
    _publishDeletedDraftCleanupPresentation();
    if (_closed) return;
    // Every general update already exposes the latest ingested text. Cancel
    // deferred presentation, including other chats' browser row invalidations.
    if (_pendingStreamChats.any((key) => key != browserChat)) {
      browserChat = null;
    }
    _streamPresentationTimer?.cancel();
    _streamPresentationTimer = null;
    _pendingStreamChats.clear();
    for (final route in _visibleRoutes) {
      if (_mountedRoutes.containsKey(route)) {
        _mountedRoutes[route] = _current?.chat?._key;
      }
    }
    _scheduleRetention();
    if (saveReading) _readingSnapshotDirty = true;
    // Later stream presentation can flush a recent durable change, but never
    // makes unchanged history dirty or needs its own persistence timer.
    if (_readingSnapshotDirty &&
        (_lastSnapshot == null ||
            DateTime.now().difference(_lastSnapshot!).inSeconds >= 1)) {
      unawaited(_saveReadingSnapshot());
    }
    for (final chat in notificationChats) {
      if (!chat._notificationTargetRestored) {
        chat._notificationTargetRestored = true;
        chat.reading.restoreNotificationReadTarget(
          notificationResultFor?.call(chat._key),
        );
      }
      _publishNotificationInputs(chat);
    }
    _browserChanges.value = (
      revision: _browserChanges.value.revision + 1,
      chat: browserChat,
    );
    notifyListeners();
  }

  void _streamChanged(ProfileChat chat, {required bool immediate}) {
    if (immediate || _streamPresentationTimer == null) {
      // Live text and reasoning are not part of the reading cache. Saving the
      // unchanged history here repeats preparation throughout a long response.
      _changed(browserChat: chat._key, saveReading: false);
      _startStreamPresentationWindow();
    } else {
      _pendingStreamChats.add(chat._key);
    }
  }

  void _startStreamPresentationWindow() {
    if (_closed) return;
    // Growing Markdown reparses and lays out its entire live body. Ingest every
    // chunk immediately, but bound those presentation updates to ten per second.
    _streamPresentationTimer = Timer(const Duration(milliseconds: 100), () {
      _streamPresentationTimer = null;
      if (_closed || _pendingStreamChats.isEmpty) return;
      final chat = _pendingStreamChats.length == 1
          ? _pendingStreamChats.single
          : null;
      _changed(browserChat: chat, saveReading: false);
      _startStreamPresentationWindow();
    });
  }

  List<Map<String, dynamic>> _snapshotRecords(Object? value) => value is List
      ? value
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList()
      : [];

  void _restoreReadingSnapshot() {
    final snapshot = _snapshots.read();
    for (final saved in _snapshotRecords(snapshot['profiles'])) {
      final name = saved['name'];
      if (name is! String) continue;
      final resource = _resource(name).._offlineSnapshot = true;
      resource._archivedOnly = saved['archived'] == true;
      resource._sessions = _readonlyWorkspaceRows(
        _snapshotRecords(saved['sessions'])
            .where(
              (row) =>
                  row['id'] is String &&
                  !resource.blocksSession(row['id'] as String),
            )
            .toList(),
      );
      resource._projects = _readonlyWorkspaceRows(
        _snapshotRecords(saved['projects']),
      );
      for (final row in _snapshotRecords(saved['chats'])) {
        final id = row['id'];
        if (id is! String || resource.blocksSession(id)) continue;
        resource._chats[id] =
            _createChatRecord(
                key: ProfileSessionKey(resource.scope, id),
                runtimeId: id,
                title: row['title'] is String ? row['title'] as String : 'Chat',
                source: row['source'] is String ? row['source'] as String : '',
                projectId: row['project'] is String
                    ? row['project'] as String
                    : null,
              )
              .._runtime.installOfflineReading()
              .._archived = row['archived'] == true
              ..reading.installSnapshot(
                TranscriptReadingSnapshot(
                  messages: _snapshotRecords(row['messages']),
                  historySessionId: row['history_session'] is String
                      ? row['history_session'] as String
                      : null,
                ),
              );
        final chat = resource._chats[id]!;
        for (final message in chat.reading.messages.where(
          isLocalReviewMessage,
        )) {
          final text = reviewMessageText(message);
          if (text == null) continue;
          final notice = GatewayNotice.fromGatewayEvent('review.summary', {
            'text': text,
          });
          final identity = message['_review_notice'] as String;
          if (notice != null &&
              !chat._reviewNotices.any(
                (existing) => existing.identity == identity,
              )) {
            chat._reviewNotices.add((notice: notice, identity: identity));
          }
        }
      }
      if (snapshot['selected'] == name) _current = resource;
    }
  }

  Future<void> _saveReadingSnapshot() async {
    _readingSnapshotDirty = false;
    _lastSnapshot = DateTime.now();
    try {
      for (final resource in _resources.values.toList()) {
        for (final chat in resource._chats.values.toList()) {
          final key = chat._key;
          if (resource.blocksSession(key.sessionId)) continue;
          final revision = chat.reading.toolDurationRevision;
          final saved = (key, revision);
          if (_savedToolDurationRevisions[chat] == saved) continue;
          await _snapshots.writeToolDurations(
            resource.scope.profileName,
            key.sessionId,
            chat.reading.captureToolDurations(),
          );
          _savedToolDurationRevisions[chat] = saved;
        }
      }
      await _snapshots.write({
        'selected': _current?.scope.profileName,
        'profiles': [
          for (final resource
              in _resources.values
                  .where(
                    (r) => r.loaded || r.offlineSnapshot || r._chats.isNotEmpty,
                  )
                  .take(12))
            {
              'name': resource.scope.profileName,
              'archived': resource._archivedOnly,
              'sessions': resource._sessions.take(200).toList(),
              'projects': resource._projects.take(100).toList(),
              'chats': [
                for (final chat
                    in (resource._chats.values.toList()..sort(
                          (a, b) => b.lastActive.compareTo(a.lastActive),
                        ))
                        .take(10))
                  {
                    'id': chat._key.sessionId,
                    'title': chat._title,
                    'history_session': chat.reading.historySessionId,
                    'source': chat._source,
                    'project': chat._projectId,
                    'archived': chat._archived,
                    'messages': chat.reading.captureSnapshot().messages,
                  },
              ],
            },
        ],
      });
    } catch (_) {
      /* Reading snapshots must never block the live workspace. */
      if (!_closed) _readingSnapshotDirty = true;
    }
  }

  /// Establish the destination synchronously, before any network operation.
  Future<void> openNotification(
    ProfileSessionKey key, {
    String? title,
    bool Function()? isCurrent,
  }) {
    if (!owns(key)) throw ArgumentError('Wrong connection settings or host');
    cancelNotificationOpen();
    _notificationTarget = key;
    _notificationIsCurrent = isCurrent;
    _notificationAttempts = 0;
    final resource = _resource(key.workspace.profileName);
    // A chat destination supersedes older profile-list publication immediately.
    // Its connection and history load are owned by this opening, not the browser.
    ++_generation;
    _cancelOlderLoads();
    if (_current != null) _invalidateSessionLoad(_current!);
    if (_current != resource) _invalidateSessionLoad(resource);
    _pendingProfile = null;
    final row = resource._sessions
        .where((r) => r['id'] == key.sessionId)
        .firstOrNull;
    final chat = resource._chats.putIfAbsent(
      key.sessionId,
      () => _createChatRecord(
        key: key,
        runtimeId: key.sessionId,
        title: title ?? row?['title'] as String? ?? 'Chat',
      ).._runtime.installOfflineReading(),
    );
    if (title != null) chat._title = title;
    chat._runtime.beginOpening();
    connectionStatus.beginRecovery('notification');
    _changed();
    return _retryNotification();
  }

  Future<void> _resumeNotification() {
    if (_notificationResume case final pending?) return pending;
    final generation = _notificationGeneration;
    // Keep the connection status recovering while an older opening settles and
    // the fresh attempt starts. Concurrent resumes share this recovery.
    connectionStatus.beginRecovery('notification-resume');
    return _notificationResume = _resumeNotificationAfterOpening(generation)
        .whenComplete(() {
          if (generation == _notificationGeneration) {
            _notificationResume = null;
            connectionStatus.endRecovery('notification-resume');
          }
        });
  }

  Future<void> _resumeNotificationAfterOpening(int generation) async {
    await _notificationOpening;
    if (_closed ||
        generation != _notificationGeneration ||
        _notificationTarget == null) {
      return;
    }
    _notificationAttempts = 0;
    notificationChat?._runtime.beginOpening();
    await _retryNotification();
  }

  Future<void> _retryNotification() {
    if (_notificationOpening != null) return _notificationOpening!;
    _notificationRetry?.cancel();
    _notificationRetry = null;
    final generation = _notificationGeneration;
    return _notificationOpening = _openNotificationAttempt(generation)
        .whenComplete(() {
          if (generation == _notificationGeneration) {
            _notificationOpening = null;
          }
        });
  }

  Future<void> _openNotificationAttempt(int generation) async {
    final key = _notificationTarget;
    bool valid() =>
        !_closed &&
        generation == _notificationGeneration &&
        key == _notificationTarget &&
        (_notificationIsCurrent?.call() ?? true);
    if (key == null || !valid()) return;
    final chat = notificationChat!;
    connectionStatus.beginRecovery('notification');
    try {
      await _restoreDraft(chat);
      if (!valid()) return;
      if (!_initialized) await initialize();
      if (!valid()) return;
      if (!_initialized) {
        throw _initializationFailure ?? TimeoutException('Connecting');
      }
      await _resource(key.workspace.profileName).gateway.connect();
      if (!valid()) return;
      final opened = await openSession(
        key,
        propagateHistoryFailure: true,
        isCurrentRequest: valid,
      );
      if (!valid()) return;
      if (opened == null) {
        throw _initializationFailure ?? TimeoutException('Connecting');
      }
      chat._runtime.recovered();
      _resource(key.workspace.profileName)._offlineSnapshot = false;
      final row = _resource(
        key.workspace.profileName,
      ).sessions.where((row) => row['id'] == key.sessionId).firstOrNull;
      if (row?['title'] is String) chat._title = row!['title'] as String;
      _notificationTarget = null;
      connectionStatus.endRecovery('notification');
      // Clearing the target makes valid() false, so the finally block cannot
      // publish this transition. Notify now to release the composer immediately.
      _changed();
      await _drainQueuedPrompts(chat);
    } catch (failure) {
      if (!valid()) return;
      if (isTemporaryWorkspaceFailure(failure)) {
        _error = null;
        // Keep recovering a waking network without requiring another tap.
        // Never replay a submitted prompt.
        final delay = _recoveryDelay(_notificationAttempts);
        _notificationAttempts++;
        connectionStatus.waitForRecovery('notification');
        _notificationRetry = Timer(delay, () {
          if (valid()) unawaited(_retryNotification());
        });
      } else {
        _error = null;
        if (isConversationAttachmentRefused(failure)) {
          chat._attachmentRefused = true;
        }
        chat._runtime.finishOpening(
          error: _isMissingSessionFailure(failure)
              ? 'This conversation is no longer available.'
              : conversationOpeningFailureMessage(failure),
        );
        connectionStatus.failRecovery(
          'notification',
          chat.runtime.openingError!,
        );
      }
    } finally {
      if (valid()) _changed();
    }
  }

  bool _isMissingSessionFailure(Object failure) =>
      failure is JsonRpcError && _isMissingSessionResume(failure) ||
      failure is DashboardHttpException && failure.statusCode == 404;

  void cancelNotificationOpen() {
    notificationChat?._runtime.cancelOpening();
    _notificationTarget = null;
    _notificationGeneration++;
    _notificationRetry?.cancel();
    _notificationOpening = null;
    _notificationResume = null;
    _navigationGeneration++;
    connectionStatus.endRecovery('notification');
    connectionStatus.endRecovery('notification-resume');
  }

  /// Read access for the connection-wide browser; this never changes navigation.
  ProfileWorkspaceData browserResource(String name) {
    if (_discovery?.named(name) == null) {
      throw StateError('Profile is no longer available');
    }
    return _resource(name);
  }

  /// Observe one retained runtime by its captured identity. Streaming row
  /// invalidation must not reopen or scan the connection-wide browser index.
  ProfileChat? browserChat(ProfileSessionKey key) {
    if (!owns(key)) throw ArgumentError('Wrong connection settings or host');
    return _resources[key.workspace]?._chats[key.sessionId];
  }

  /// Canonical browsing uses a connected reader, never an unopened chat socket.
  Future<ProfileCanonicalBotChat?> browserCanonicalBotChat(
    String name, {
    required bool Function() canRead,
  }) async {
    if (_closed || !canRead()) throw StateError('Browser is closed');
    final reader = _factory(browserResource(name).scope);
    try {
      await reader.connect();
      if (_closed || !canRead()) throw StateError('Browser is closed');
      return await reader.canonicalBotChat();
    } finally {
      reader.close();
    }
  }

  /// Project browsing uses short-lived readers, never the conversation socket.
  /// Bound the caller's concurrency instead of retaining a socket per profile.
  Future<List<Map<String, dynamic>>> browserProjects(
    String name, {
    required int sessionLimit,
    required bool Function() canRead,
  }) async {
    if (_closed || !canRead()) throw StateError('Browser is closed');
    final resource = browserResource(name);
    final generation = resource._projectMembershipGeneration;
    final reader = _factory(browserResource(name).scope);
    try {
      await reader.connect();
      if (_closed || !canRead()) throw StateError('Browser is closed');
      final result = await reader.call('projects.tree', {
        'preview_limit': 3,
        'session_limit': sessionLimit,
      });
      if (result['projects'] is! List) {
        throw const FormatException('Missing project tree');
      }
      final projects = ProfileGateway.records(result['projects']).map((
        project,
      ) {
        if (project['id'] is! String ||
            project['label'] is! String ||
            project['sessionIds'] is! List ||
            (project['sessionIds'] as List).any(
              (id) => id is! String || id.isEmpty,
            )) {
          throw const FormatException('Invalid project membership');
        }
        return {
          ...project,
          'name': project['label'],
          'primary_path': project['path'],
        };
      }).toList();
      if (!_closed &&
          canRead() &&
          generation == resource._projectMembershipGeneration) {
        resource._projectMembershipCoverageChecked =
            resource._projectMembershipCoverageChecked &&
            sessionLimit >= resource._projectMembershipLimit;
        resource._projectMembershipLimit = sessionLimit;
        resource._projectMembershipLabels = {
          for (final project in projects)
            if (ProfileGateway.isSavedProject(project))
              project['id'] as String: project['label'] as String,
        };
        resource._projectMembership = {
          for (final project in projects)
            for (final id in project['sessionIds'] as List)
              if (id is String)
                id: ProfileGateway.isSavedProject(project)
                    ? project['id'] as String
                    : null,
        };
        for (final chat in resource._chats.values) {
          if (resource._projectMembership!.containsKey(chat.key.sessionId)) {
            chat._projectId = resource._projectMembership![chat.key.sessionId];
            chat._projectLookupFailed = false;
          }
        }
      }
      return projects.where(ProfileGateway.isSavedProject).toList();
    } finally {
      reader.close();
    }
  }

  void _invalidateProjectMembership(ProfileWorkspaceData resource) {
    resource._projectMembershipGeneration++;
    // Stale membership is still the last confirmed display observation.
    // Retain it through pending/failed reads; resetting coverage forces a read.
    resource._projectMembershipLabels = {};
    resource._projectMembershipRead = null;
    resource._projectMembershipLimit = 0;
    resource._projectMembershipCoverageChecked = false;
  }

  Future<void> _readProjectMembership(ProfileWorkspaceData resource) {
    if (resource._projectMembership != null &&
        resource._projectMembershipCoverageChecked) {
      return Future.value();
    }
    if (resource._projectMembershipRead != null) {
      return resource._projectMembershipRead!;
    }
    late final Future<void> pending;
    final generation = resource._projectMembershipGeneration;
    pending =
        () async {
          // The tree is capped and filters archived, child and non-chat sessions.
          // Use the complete list's count to cover large histories. Only explicit
          // Home or automatic-folder membership proves no saved project; an
          // absent key remains unknown.
          final page = await resource.gateway.sessions(
            visibility: SessionVisibility.all,
            limit: 1,
          );
          if (_closed || generation != resource._projectMembershipGeneration) {
            return;
          }
          final limit = math.max(
            ProfileGateway.projectSessionScanLimit,
            page.total,
          );
          if (resource._projectMembership == null ||
              resource._projectMembershipLimit < limit) {
            await browserProjects(
              resource.scope.profileName,
              sessionLimit: limit,
              canRead: () =>
                  !_closed && identical(_resources[resource.scope], resource),
            );
          }
          if (!_closed && generation == resource._projectMembershipGeneration) {
            resource._projectMembershipCoverageChecked = true;
          }
        }().whenComplete(() {
          if (identical(resource._projectMembershipRead, pending)) {
            resource._projectMembershipRead = null;
          }
        });
    return resource._projectMembershipRead = pending;
  }

  // Live transports may be opened for Activity or restored pending input
  // without loading that profile's chat list. Every observation contributing
  // to the connection label must remain eligible for recovery.
  bool _needsLiveRecovery(ProfileWorkspaceData resource) =>
      resource._loaded ||
      resource._chats.values.any(
        (chat) =>
            chat.runtime.blocksTurnAdmission ||
            chat.composer.observation.queue.isNotEmpty,
      ) ||
      connectionStatus.hasLiveObservation(resource.scope.profileName);

  ProfileWorkspaceData _resource(String name) {
    final scope = WorkspaceScope(
      connectionId: connection.id,
      connectionIdentity: connectionIdentity,
      profileName: name,
    );
    return _resources.putIfAbsent(scope, () {
      final resource = ProfileWorkspaceData(_factory(scope));
      for (final receipt in _deletedDrafts.receipts.where(
        (r) => r.profile == name,
      )) {
        if (receipt.confirmed) {
          resource._deletedSessions.add(receipt.session);
          if (receipt.phase != DeletedDraftCleanupPhase.completed) {
            resource._deletedDraftCleanup[receipt.session] = (
              files: receipt.files,
              writes: null,
            );
          }
        } else {
          resource._quarantinedSessions.add(receipt.session);
        }
      }
      resource.gateway.connectionStatus = connectionStatus;
      resource.gateway.onEvent = (event) => _event(resource, event);
      resource.gateway.onConnectionChanged = (connected) {
        if (!connected && !_closed) {
          _invalidateProjectMembership(resource);
          // Losing transport does not erase work already verified as unfinished.
          _uncertainNotificationRuntimes.addAll(_backgroundChats.keys);
          _detachedWorkGeneration++;
          _uncertainDetachedWork.addAll(_detachedActivity.keys);
          for (final chat in resource._chats.values.where(
            (c) => c.runtime.blocksTurnAdmission,
          )) {
            chat._runtime.beginRecovery();
          }
          if (_needsLiveRecovery(resource)) {
            connectionStatus.liveChanged(scope.profileName, false);
            if (_notificationTarget == null) _scheduleReconnect(resource);
          }
          _changed();
        }
      };
      return resource;
    });
  }

  Future<void> initialize() {
    if (_closed) return Future.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
      _changed();
    });
  }

  Future<void> _initialize() async {
    connectionStatus.beginRecovery('initialization');
    logConnectionDiagnostic(
      'workspace.initialization_started',
      details: {
        'connection': connection.id,
        'attempt': _initializationAttempt,
        'generation': _generation,
      },
    );
    _initializationFailure = null;
    final generation = _generation;
    _initializationRetry?.cancel();
    _initializationRetry = null;
    _error = null;
    try {
      // Unresolved durable owners survive unrelated journal writes even when
      // discovery or the saved restart selection prevents opening a profile.
      _seedPendingOwners();
      // This temporary owner is used only for host-level discovery, not data.
      final profiles = await _resource('default').gateway.discover();
      if (_closed || generation != _generation) return;
      _adoptDiscovery(profiles);
      await _recoverDeletedDrafts();
      if (_closed || generation != _generation) return;
      final initial = appPreferences.initialProfileSelection(
        connectionIdentity,
        availableNames: _discovery!.profiles.map((profile) => profile.name),
        preferredName: _discovery!.serverPreferred.name,
      );
      if (!await switchProfile(initial)) return;
    } catch (e, stack) {
      if (_closed || generation != _generation) return;
      _initializationFailed(e, stack);
      _changed();
    }
  }

  Future<void> _finishInitialization(int generation) async {
    if (_closed || generation != _generation || _initialized) return;
    if (_profileSelectionRepairRequired) {
      final selection = _profileSelection.value;
      if (selection.busy ||
          selection.validity != ProfileSelectionValidity.valid ||
          selection.selectedName != _current?.scope.profileName) {
        return;
      }
    }
    // Admit the connection-owned restoration once before any awaited work.
    // A subsequent profile navigation cannot duplicate this initialization.
    _initialized = true;
    logConnectionDiagnostic(
      'workspace.initialized',
      details: {
        'connection': connection.id,
        'profile': _current?.scope.profileName,
        'attempt': _initializationAttempt,
      },
    );
    _initializationFailure = null;
    _profileSelectionRepairRequired = false;
    connectionStatus.endRecovery('initialization');
    _recoveringInitialization = false;
    _initializationAttempt = 0;
    await _restorePending();
    if (_closed) return;
    await _restoreWaitingOutboxes();
    if (_closed) return;
    if (generation == _generation && onAttention != null && _current != null) {
      await _groupNotifications.activate();
      await _scheduleNotificationReconciliation(_current!);
    }
  }

  static Duration _recoveryDelay(int attempt) =>
      Duration(seconds: attempt >= 5 ? 30 : 1 << attempt);

  void _initializationFailed(Object failure, [StackTrace? stack]) {
    _initializationFailure = failure;
    if (failure is ProfileSelectionRepairRequired) {
      _profileSelectionRepairRequired = true;
    }
    _recoveringInitialization = isTemporaryWorkspaceFailure(failure);
    logConnectionDiagnostic(
      'workspace.initialization_failed',
      details: {
        'connection': connection.id,
        'attempt': _initializationAttempt,
        'generation': _generation,
        ...workspaceFailureDiagnostic(failure),
      },
      error: failure,
      stackTrace: stack,
    );
    _error = _recoveringInitialization
        ? null
        : failure is ProfileSelectionRepairRequired
        ? failure.message
        : workspaceFailureMessage(failure);
    if (_recoveringInitialization && !_closed && _notificationTarget == null) {
      logConnectionDiagnostic(
        'workspace.initialization_retry_scheduled',
        details: {
          'connection': connection.id,
          'attempt': _initializationAttempt + 1,
          'delay_ms': _recoveryDelay(_initializationAttempt).inMilliseconds,
        },
      );
      _initializationRetry?.cancel();
      connectionStatus.waitForRecovery('initialization');
      _initializationRetry = Timer(
        _recoveryDelay(_initializationAttempt++),
        () {
          _initializationRetry = null;
          unawaited(initialize());
        },
      );
    } else {
      logConnectionDiagnostic(
        'workspace.initialization_stopped',
        details: {
          'connection': connection.id,
          'attempt': _initializationAttempt,
          'retryable': _recoveringInitialization,
          'notification_opening': _notificationTarget != null,
        },
      );
      if (_notificationTarget != null ||
          failure is ProfileSelectionRepairRequired) {
        // Notification opening owns its outer retry timer; profile-selection
        // repair has its own presentation and is not a connection failure.
        connectionStatus.endRecovery('initialization');
      } else {
        connectionStatus.failRecovery(
          'initialization',
          workspaceFailureMessage(failure),
        );
      }
    }
  }

  void networkUnavailable() {
    if (_closed || (!_initialized && !recovering && notificationChat == null)) {
      return;
    }
    connectionStatus.accessFailed(const SocketException('Network unavailable'));
    _detachedWorkGeneration++;
    _uncertainDetachedWork.addAll(_detachedActivity.keys);
    _changed();
    for (final resource in _resources.values.where(_needsLiveRecovery)) {
      resource.gateway.disconnect();
      resource.gateway.onConnectionChanged?.call(false);
    }
  }

  /// Foreground entry also recovers a workspace that never finished loading.
  Future<void> resumeConnection({bool networkChanged = false}) async {
    if (_closed) return;
    logConnectionDiagnostic(
      'workspace.resume',
      details: {
        'connection': connection.id,
        'network_changed': networkChanged,
        'initialized': _initialized,
        'recovering': recovering,
        'notification_opening': _notificationTarget != null,
      },
    );
    if (networkChanged) {
      // A socket associated with the previous mobile route can look connected
      // until its next timeout. Re-open it when Android reports a new route.
      for (final resource in _resources.values) {
        if (connectionStatus.liveAvailable(resource.scope.profileName)) {
          // The shared recovery may already be reading history over the old
          // route. Its borrowers must await a fresh pass on the new socket.
          if (resource._reconnectFuture != null) {
            resource._restartReconnect = true;
          }
          resource.gateway.disconnect();
          resource.gateway.onConnectionChanged?.call(false);
        }
      }
    }
    if (_notificationTarget != null) {
      await _resumeNotification();
    } else if (!_initialized) {
      _initializationAttempt = 0;
      await initialize();
    } else {
      await Future.wait(
        _resources.values
            .where(_needsLiveRecovery)
            .map((resource) => reconnect(resource.scope)),
      );
    }
  }

  void _adoptDiscovery(ProfileDiscovery discovered) {
    final previous = _discovery;
    if (previous != null &&
        previous.currentName == discovered.currentName &&
        previous.activeName == discovered.activeName &&
        listEquals(previous.profiles, discovered.profiles)) {
      return;
    }
    _discovery = ProfileDiscovery(
      profiles: List.unmodifiable(discovered.profiles),
      currentName: discovered.currentName,
      activeName: discovered.activeName,
    );
  }

  Future<bool> switchProfile(
    String name, {
    bool resetNavigation = false,
  }) async {
    final generation = ++_generation;
    final navigating = _current?.scope.profileName != name || resetNavigation;
    _cancelOlderLoads();
    if (_current != null) _invalidateSessionLoad(_current!);
    final target = _resource(name);
    if (target != _current) _invalidateSessionLoad(target);
    final sessionReadGeneration = target._sessionGeneration;
    _pendingProfile = navigating ? name : null;
    _error = null;
    _failedSwitchProfile = null;
    _failedSwitchError = null;
    _changed();
    try {
      final profiles = await target.gateway.discover();
      if (profiles.named(name) == null) {
        throw StateError('Profile $name is no longer available');
      }
      await target.gateway.connect();
      final archivedOnly = resetNavigation ? false : target._archivedOnly;
      final sessions = await target.gateway.sessions(
        visibility: _requiredSessionVisibility(),
        archivedOnly: archivedOnly,
      );
      List<Map<String, dynamic>>? projects;
      String? projectError;
      try {
        projects = await target.gateway.projects();
      } catch (_) {
        projectError = 'Projects are unavailable for $name. Retry to reload.';
      }
      if (_closed || generation != _generation) return false;
      if (sessionReadGeneration != target._sessionGeneration) {
        throw StateError('Chats changed while loading. Refresh to reload.');
      }
      target._archivedOnly = archivedOnly;
      _replaceSessions(target, sessions);
      if (projects != null) {
        target._projects = _readonlyWorkspaceRows(projects);
      }
      _invalidateProjectMembership(target);
      target._projectsError = projectError;
      if (resetNavigation) {
        target._selectedSession = null;
        target._selectedProject = null;
        target._projectGeneration++;
        target._projectSessions = _readonlyWorkspaceRows([]);
        target._projectSessionsLoading = false;
        target._projectSessionsError = null;
      }
      final selectedId = target._selectedProject?['id'];
      if (selectedId != null) {
        final selected = target._projects
            .where((p) => p['id'] == selectedId)
            .firstOrNull;
        if (selected != null) {
          target._selectedProject = _readonlyOptionalWorkspaceRow(selected);
          unawaited(_loadProject(target, selected));
        } else {
          target._projectGeneration++;
          target._projectSessionsLoading = false;
          target._projectSessions = _readonlyWorkspaceRows([]);
          target._projectSessionsError = 'The selected project is unavailable.';
        }
      }
      _adoptDiscovery(profiles);
      _current = target;
      target._loaded = true;
      target._offlineSnapshot = false;
      _pendingProfile = null;
      final admission = appPreferences.admitProfileSelection(
        connectionIdentity,
        name,
      );
      if (!admission.queuedBehindSelection) {
        final settlement = await appPreferences.settleProfileSelection(
          connectionIdentity,
        );
        if (!settlement.confirmed && !_closed && generation == _generation) {
          _error = appPreferences
              .profileSelectionFor(connectionIdentity)
              .value
              .error;
        }
      }
      if (_closed || generation != _generation || _current != target) {
        return false;
      }
      if (_initializing != null || _profileSelectionRepairRequired) {
        await _finishInitialization(generation);
      }
      if (_closed || generation != _generation || _current != target) {
        return false;
      }
      _changed();
      return true;
    } catch (e, stack) {
      if (!_closed && generation == _generation) {
        logConnectionDiagnostic(
          'workspace.profile_open_failed',
          details: {
            'connection': connection.id,
            'profile': name,
            'generation': generation,
            ...workspaceFailureDiagnostic(e),
          },
          error: e,
          stackTrace: stack,
        );
        _pendingProfile = null;
        _initializationFailure = e;
        if (!_initialized) {
          _initializationFailed(e, stack);
        } else if (isTemporaryWorkspaceFailure(e)) {
          _scheduleReconnect(target);
          if (target != _current) {
            _error = workspaceFailureMessage(e);
            _failedSwitchProfile = target.scope.profileName;
            _failedSwitchError = error;
          }
        } else {
          _error = e is StateError
              ? e.message.toString()
              : workspaceFailureMessage(e);
        }
        _changed();
      }
      return false;
    }
  }

  Future<void> refresh() {
    if (_closed) return Future.value();
    final pending = _workspaceRefreshFuture;
    if (pending != null) return pending;
    final request = _refreshWorkspace().whenComplete(() {
      _workspaceRefreshFuture = null;
      _changed();
    });
    _workspaceRefreshFuture = request;
    _changed();
    return request;
  }

  Future<void> _refreshWorkspace() async {
    final resource = _current;
    if (resource == null) {
      await initialize();
      return;
    }
    resource._commandCatalog = null;
    if (await switchProfile(resource.scope.profileName)) {
      await reconnect(resource.scope);
    }
    if (_unrestoredPending.isNotEmpty) await _restorePending();
  }

  Future<void> _refreshDetachedWork(
    ProfileWorkspaceData source, {
    ProfileDiscovery? discovery,
  }) {
    if (_closed) return Future.value();
    return _detachedWorkRefresh ??= _readDetachedWork(source, discovery)
        .whenComplete(() {
          _detachedWorkRefresh = null;
          _changed();
        });
  }

  Future<void> _readDetachedWork(
    ProfileWorkspaceData source,
    ProfileDiscovery? discovery,
  ) async {
    final generation = _detachedWorkGeneration;
    try {
      final profiles = discovery ?? await source.gateway.discover();
      // Borrow the source socket. Passive observation must not open transport
      // or bypass the workspace's recovery backoff. Explicit refresh
      // and recovery establish it; an unavailable socket preserves uncertainty.
      // Target resources below supply scoped metadata, never attachments.
      if (_closed || generation != _detachedWorkGeneration) return;
      final names = profiles.profiles.map((profile) => profile.name).toSet();
      // Catalog retirement is independent of any slow profile's roster read.
      _detachedActivity = Map.unmodifiable({
        for (final entry in _detachedActivity.entries)
          if (names.contains(entry.key.workspace.profileName))
            entry.key: entry.value,
      });
      _uncertainDetachedWork.removeWhere(
        (key) => !names.contains(key.workspace.profileName),
      );
      _detachedWorkErrors = Map.unmodifiable({
        for (final entry in _detachedWorkErrors.entries)
          if (names.contains(entry.key)) entry.key: entry.value,
      });
      _changed();
      await Future.wait(
        profiles.profiles.map((profile) async {
          final resource = _resource(profile.name);
          final scope = resource.scope;
          final prior = {
            for (final entry in _detachedActivity.entries)
              if (entry.key.workspace == scope) entry.key: entry.value,
          };
          final next = <ProfileSessionKey, ProfileLiveActivity>{};
          final uncertain = <ProfileSessionKey>{};
          var failed = false;
          try {
            final rows = DetachedWork.parseRoster(
              await source.gateway.detachedWorkRoster(profile.name),
            );
            final running = rows.where((row) => row.isRunning).toList();
            for (var offset = 0; offset < running.length; offset += 4) {
              await Future.wait(
                running.skip(offset).take(4).map((row) async {
                  final key = ProfileSessionKey(scope, row.sessionId);
                  try {
                    final metadata = await resource.gateway.sessionMetadata(
                      row.sessionId,
                    );
                    if (metadata == null) return;
                    final title = metadata['title'];
                    final sourceName = metadata['source'];
                    final lastActive = metadata['last_active'];
                    final shortId = row.sessionId.length <= 8
                        ? row.sessionId
                        : row.sessionId.substring(row.sessionId.length - 8);
                    next[key] = ProfileLiveActivity(
                      workspace: scope,
                      runtimeId: null,
                      sessionId: row.sessionId,
                      title: title is String && title.trim().isNotEmpty
                          ? title.trim()
                          : 'Hermes session · $shortId',
                      source: sourceName is String ? sourceName : null,
                      lastActive: lastActive is num && lastActive.isFinite
                          ? lastActive.toDouble()
                          : 0,
                      state: ProfileLiveActivityState.running,
                    );
                  } catch (_) {
                    failed = true;
                    final previous = prior[key];
                    if (previous != null) {
                      next[key] = previous;
                      uncertain.add(key);
                    }
                  }
                }),
              );
              if (_closed || generation != _detachedWorkGeneration) return;
            }
          } catch (_) {
            failed = true;
            next.addAll(prior);
            uncertain.addAll(prior.keys);
          }
          if (_closed || generation != _detachedWorkGeneration) return;
          // Publish this profile as soon as it settles. Another profile's
          // roster or metadata cannot delay its presence or retirement.
          _detachedActivity = Map.unmodifiable({
            for (final entry in _detachedActivity.entries)
              if (entry.key.workspace != scope) entry.key: entry.value,
            ...next,
          });
          _uncertainDetachedWork
            ..removeWhere((key) => key.workspace == scope)
            ..addAll(uncertain);
          _detachedWorkErrors = Map.unmodifiable({
            for (final entry in _detachedWorkErrors.entries)
              if (entry.key != profile.name) entry.key: entry.value,
            if (failed)
              profile.name: 'Background work unavailable for ${profile.label}.',
          });
          _changed();
        }),
      );
    } catch (_) {
      if (_closed || generation != _detachedWorkGeneration) return;
      _uncertainDetachedWork.addAll(_detachedActivity.keys);
      _detachedWorkErrors = const {
        'detached': 'Background work could not be loaded.',
      };
    }
  }

  Future<void> refreshActivity() async {
    final generation = ++_activityGeneration;
    Future<void>? detachedRefresh;
    _activityLoading = true;
    _activityProfileErrors = const {};
    _changed();
    try {
      final profiles = await _resource('default').gateway.discover();
      final activeResource = _resource(profiles.serverPreferred.name);
      // Recents can refresh as foreground recovery restores this same profile.
      // Borrow the owned recovery before reading live activity.
      final recovery = activeResource._reconnectFuture;
      if (recovery != null) {
        await recovery;
        if (!connectionStatus.liveAvailable(activeResource.scope.profileName)) {
          throw StateError('Live activity connection was not restored.');
        }
      } else {
        await activeResource.gateway.connect();
      }
      if (_closed || generation != _activityGeneration) return;
      detachedRefresh = _refreshDetachedWork(
        activeResource,
        discovery: profiles,
      );
      final response = await activeResource.gateway.call('session.active_list');
      if (response['sessions'] is! List) {
        throw const FormatException('Missing active sessions');
      }
      final activeRows = <Map<String, dynamic>>[];
      final seenRuntimeSessions = <(String, String)>{};
      for (final row in ProfileGateway.records(response['sessions'])) {
        final runtimeId = row['id'];
        final sessionId = row['session_key'];
        final status = row['status'];
        final lastActive = row['last_active'];
        final reportedSideTasks = row['side_tasks_running'];
        final sideTasksRunning = reportedSideTasks is int
            ? reportedSideTasks
            : 0;
        if (runtimeId is! String ||
            runtimeId.isEmpty ||
            sessionId is! String ||
            sessionId.isEmpty ||
            status is! String ||
            (reportedSideTasks != null && reportedSideTasks is! int) ||
            sideTasksRunning < 0 ||
            (lastActive != null && lastActive is! num)) {
          throw const FormatException('Invalid active session');
        }
        final foregroundState = switch (status) {
          'waiting' => ProfileLiveActivityState.needsInput,
          'working' => ProfileLiveActivityState.running,
          'starting' => ProfileLiveActivityState.running,
          _ => null,
        };
        final state =
            foregroundState ??
            (sideTasksRunning > 0 ? ProfileLiveActivityState.running : null);
        if (state == null || !seenRuntimeSessions.add((runtimeId, sessionId))) {
          continue;
        }
        activeRows.add({...row, '_activity_state': state});
      }

      final sessionIds = activeRows
          .map((row) => row['session_key'] as String)
          .toSet();
      final ownership = await Future.wait(
        profiles.profiles.map((profile) async {
          final resource = _resource(profile.name);
          try {
            final matches = <String, Map<String, dynamic>>{};
            for (final sessionId in sessionIds) {
              final metadata = await resource.gateway.sessionMetadata(
                sessionId,
              );
              if (metadata != null) matches[sessionId] = metadata;
            }
            return (
              profile: profile.name,
              resource: resource,
              matches: matches,
              error: null as String?,
            );
          } catch (_) {
            return (
              profile: profile.name,
              resource: resource,
              matches: <String, Map<String, dynamic>>{},
              error: 'Live status unavailable for ${profile.label}.',
            );
          }
        }),
      );
      if (_closed || generation != _activityGeneration) return;
      final discoveredNames = profiles.profiles.map((p) => p.name).toSet();
      final allProfilesVerified = ownership.every(
        (result) => result.error == null,
      );
      final items = <ProfileLiveActivity>[];
      var hidden = 0;
      for (final row in activeRows) {
        final runtimeId = row['id'] as String;
        final sessionId = row['session_key'] as String;
        final localOwners =
            <({ProfileWorkspaceData resource, ProfileChat chat})>[
              for (final resource in _resources.values)
                if (discoveredNames.contains(resource.scope.profileName))
                  for (final chat in resource._chats.values)
                    if (chat.runtime.runtimeId == runtimeId &&
                        chat._key.sessionId == sessionId)
                      (resource: resource, chat: chat),
            ];
        ProfileWorkspaceData? owner;
        String? title;
        String? source;
        if (localOwners.length == 1) {
          owner = localOwners.single.resource;
          final metadata = ownership
              .where((result) => result.resource == owner)
              .firstOrNull
              ?.matches[sessionId];
          final metadataTitle = metadata?['title'];
          final metadataSource = metadata?['source'];
          if (metadataSource is String) {
            localOwners.single.chat._source = metadataSource;
          }
          source = localOwners.single.chat._source;
          if (metadataTitle is String && metadataTitle.trim().isNotEmpty) {
            localOwners.single.chat._title = metadataTitle.trim();
          }
          title = localOwners.single.chat._title.trim();
        } else if (localOwners.isEmpty && allProfilesVerified) {
          final savedOwners = ownership
              .where((result) => result.matches.containsKey(sessionId))
              .toList();
          if (savedOwners.length == 1) {
            owner = savedOwners.single.resource;
            source =
                savedOwners.single.matches[sessionId]?['source'] as String?;
            final metadataTitle =
                savedOwners.single.matches[sessionId]?['title'];
            if (metadataTitle is String) title = metadataTitle.trim();
          }
        }
        if (owner == null) {
          hidden++;
          continue;
        }
        final shortId = sessionId.length <= 8
            ? sessionId
            : sessionId.substring(0, 8);
        items.add(
          ProfileLiveActivity(
            workspace: owner.scope,
            runtimeId: runtimeId,
            sessionId: sessionId,
            source: source,
            title: title == null || title.isEmpty
                ? 'Hermes session · $shortId'
                : title,
            lastActive: (row['last_active'] as num?)?.toDouble() ?? 0,
            state: row['_activity_state'] as ProfileLiveActivityState,
            sideTasksRunning: row['side_tasks_running'] is int
                ? row['side_tasks_running'] as int
                : 0,
          ),
        );
      }
      items.sort((a, b) => b.lastActive.compareTo(a.lastActive));
      _liveActivity = List.unmodifiable(items);
      _activityProfileErrors = Map.unmodifiable({
        for (final result in ownership)
          if (result.error != null) result.profile: result.error!,
        if (hidden > 0)
          'ownership':
              'Some live sessions were hidden because their profile could not be verified.',
      });
    } catch (_) {
      if (_closed || generation != _activityGeneration) return;
      _liveActivity = const [];
      _activityProfileErrors = const {
        'server': 'Live status could not be loaded.',
      };
    } finally {
      // Publish canonical activity immediately, while the existing explicit
      // refresh feedback remains active until detached reads also settle.
      if (!_closed && generation == _activityGeneration) _changed();
      await detachedRefresh;
      if (!_closed && generation == _activityGeneration) {
        _activityLoading = false;
        _changed();
      }
    }
  }

  Future<void> retry() => resumeConnection();

  /// Profile navigation always enters that profile's root tree, never a stale
  /// project or chat retained from an earlier visit. Running owners are kept.
  Future<void> navigateProfile(String name) async {
    await switchProfile(name, resetNavigation: true);
  }

  void _invalidateSessionLoad(ProfileWorkspaceData resource) {
    resource._sessionGeneration++;
    resource._sessionsLoadingMore = false;
  }

  void _cancelOlderLoads() {
    for (final resource in _resources.values) {
      for (final chat in resource._chats.values) {
        chat.reading.cancelReads();
      }
    }
  }

  /// Read-only transcript hydration, also usable without attaching a runtime.
  Future<void> refreshHistory(
    ProfileChat chat, {
    bool propagateFailure = false,
  }) => _refreshHistory(
    chat,
    propagateFailure: propagateFailure,
    awaitContext: false,
  );

  Future<void> _refreshHistory(
    ProfileChat chat, {
    required bool propagateFailure,
    required bool awaitContext,
  }) async {
    final resource = _owned(chat);
    final key = chat._key;
    final runtimeId = chat.runtime.runtimeId;
    bool currentRead() =>
        !_closed &&
        chat._key == key &&
        chat.runtime.runtimeId == runtimeId &&
        identical(resource._chats[key.sessionId], chat) &&
        !resource.blocksSession(key.sessionId);
    final refreshed = await chat.reading.refresh(
      sessionId: key.sessionId,
      runtimeId: runtimeId,
      canPublish: currentRead,
      onChanged: () {
        if (!currentRead()) return;
        _changed(browserChat: key);
        if (!chat.reading.historyLoading) {
          // Optional replay can settle after refresh's final snapshot flush.
          // Persist its measured facts even inside the general update throttle.
          unawaited(_saveReadingSnapshot());
        }
      },
      propagateFailure: propagateFailure,
    );
    if (refreshed && currentRead()) {
      chat._runtime.reconcileHistoricalActivity();
      final contextRead = refreshContext(chat);
      if (awaitContext) {
        await contextRead;
      } else {
        unawaited(contextRead);
      }
      unawaited(_saveReadingSnapshot());
    }
  }

  /// A Find route captures one actual chat, segment and history revision.
  /// Its observations never become execution or live-input authority.
  ChatReadingSession openReadingSession(ProfileChat chat) => ChatReadingSession(
    _WorkspaceChatReading(
      this,
      _owned(chat),
      chat,
      ++_readingRequestGeneration,
    ),
  );

  _ChatReadingWindow? _readingWindow(ProfileChat chat) {
    final window = _activeReadingWindow;
    if (window != null && !window.source._ownsHistory) {
      _activeReadingWindow = null;
      return null;
    }
    return window != null &&
            identical(window.source.chat, chat) &&
            window.source._sameHistory
        ? window
        : null;
  }

  ChatReadingFocus? readingFocus(ProfileChat chat) {
    final window = _readingWindow(chat);
    return window?.focus;
  }

  /// Existing transcript grouping consumes the reading owner's immutable rows.
  /// Find's observation and selection interface never exposes these maps.
  List<Map<String, dynamic>>? nearbyReadingMessages(ProfileChat chat) =>
      _readingWindow(chat)?.page.rows;

  /// A closing viewport can release only the exact focus it rendered.
  void releaseReadingFocus(ChatReadingFocus focus) {
    if (!identical(_activeReadingWindow?.focus, focus)) {
      return;
    }
    _activeReadingWindow = null;
    if (!_closed) {
      _changed();
    }
  }

  void backToLatest(ProfileChat chat) {
    if (_closed || !identical(_current?.chat, chat)) {
      return;
    }
    if (_readingWindow(chat) == null) {
      return;
    }
    chat.reading.recordReading(null);
    _activeReadingWindow = null;
    _changed();
  }

  Future<ProfileHistoryPage> savedHistoryPage(
    ProfileChat chat, {
    int offset = 0,
  }) {
    _owned(chat);
    return chat.reading.savedPage(
      chat.reading.historySessionId ?? chat._key.sessionId,
      offset: offset,
    );
  }

  Future<EmailDraft> readEmailDraft(
    ProfileChat chat,
    EmailDraftReference reference,
  ) async {
    _owned(chat);
    final profile = chat.key.workspace.profileName;
    final client = _gatewayConnection.createDashboardReadClient();
    try {
      final data = await client.apiGet(
        'plugins/wing/drafts/v1/${reference.id}/versions/${reference.version}',
        queryParameters: {'profile': profile},
      );
      return EmailDraft.fromJson(reference, data);
    } finally {
      client.close();
    }
  }

  TranscriptResourceSession traceResources(ProfileSessionKey key) {
    final resource = _resources[key.workspace];
    if (_closed || !owns(key) || resource == null) {
      throw StateError('This trace workspace is closed.');
    }
    final chat = resource._chats[key.sessionId];
    final files = RemoteFilesClient(
      dashboard: _gatewayConnection.createFileReadClient(),
    );
    return TranscriptResourceSession(
      files: OwnedRemoteFiles(
        source: files,
        profileName: key.workspace.profileName,
        storedSessionId: key.sessionId,
        release: files.close,
      ),
      // Mounted chats retain their authoritative reading workflow, including
      // a live turn whose rows are not durable yet. Child visits stay passive.
      loadHistory: chat == null
          ? (offset) => resource.gateway.history(
              key.sessionId,
              offset: offset,
              inlineImages: false,
            )
          : (offset) => savedHistoryPage(chat, offset: offset),
      createSkillReader: resource.gateway.skillReader,
    );
  }

  Future<void> refreshContext(
    ProfileChat chat, {
    bool userInitiated = false,
  }) async {
    if (_closed || chat.runtime.offline) return;
    final resource = _owned(chat);
    final key = chat._key;
    final gateway = resource.gateway;
    final runtime = chat.runtime.runtimeId;
    final generation = ++chat._contextGeneration;
    final usageRevision = chat._contextUsageRevision;
    chat._contextExplicitRefresh = userInitiated || chat.contextRefreshPending;
    chat._contextLoading = true;
    chat._contextError = null;
    _changed();
    ContextOccupancy? value;
    String? error;
    try {
      final observations = await Future.wait([
        gateway.call('session.context_breakdown', {'session_id': runtime}),
        gateway.call('session.stats', {'session_id': runtime}),
      ]);
      value = ContextOccupancy.fromJson(
        _contextUsage({
          ...observations[0],
          ...observations[1],
          'config_context_length': observations[1]['config_context_length'],
        }),
      );
    } catch (_) {
      error = 'Couldn’t load the context breakdown.';
    }
    if (_closed ||
        chat._key != key ||
        !identical(resource._chats[key.sessionId], chat) ||
        chat.runtime.runtimeId != runtime ||
        chat._contextGeneration != generation) {
      return;
    }
    if (error == null) {
      // Usage streams independently of this read. Accept the category estimate
      // without rolling newer totals back to when the request started.
      chat._context = chat._contextUsageRevision == usageRevision
          ? value
          : chat._context?.withCategories(value?.categories ?? const []);
    }
    chat._contextLoading = false;
    chat._contextError = error;
    _changed();
  }

  Future<void> refreshSubagents(ProfileChat chat) async {
    final resource = _owned(chat);
    final runtime = chat.runtime.runtimeId;
    final turn = chat._runtime.turnRevision;
    final revision = chat._subagentsRevision;
    final before = chat._subagents;
    final loadGeneration = ++chat._subagentsLoadGeneration;
    chat._subagentsLoading = true;
    chat._subagentsError = null;
    _changed();
    try {
      final response = await resource.gateway.call('subagent.list', {
        'session_id': runtime,
      });
      if (!_subagentReadIsCurrent(
        resource,
        chat,
        runtime,
        revision,
        before,
        loadGeneration,
      )) {
        return;
      }
      final raw = response['subagents'];
      if (raw is! List) throw const FormatException('Missing subagent list');
      final snapshot = <GatewaySubagentActivity>[];
      for (final value in raw) {
        if (value is! Map) {
          throw const FormatException('Invalid subagent row');
        }
        final item = GatewaySubagentActivity.fromSnapshot(
          Map<String, dynamic>.from(value),
        );
        if (item == null) {
          throw const FormatException('Invalid subagent row');
        }
        snapshot.add(item);
      }
      final ids = snapshot.map((item) => item.id).toSet();
      // A roster read can omit children still reported by live events. Absence
      // is not a completion event: retain their work and expose uncertainty.
      final next = List<GatewaySubagentActivity>.of(before);
      for (final item in snapshot) {
        final index = next.indexWhere((existing) => existing.id == item.id);
        if (index < 0) {
          next.add(item);
        } else if (!next[index].isTerminal) {
          next[index] = next[index].merge(item, snapshot: true);
        }
        if (item.isTerminal) {
          chat._subagentCompletionTurns.putIfAbsent(item.id, () => turn);
        }
      }
      chat._subagents = next;
      chat._unconfirmedSubagentIds
        ..clear()
        ..addAll(
          before
              .where((item) => !item.isTerminal && !ids.contains(item.id))
              .map((item) => item.id),
        );
      chat._subagentsRevision++;
    } catch (_) {
      if (_subagentReadIsCurrent(
        resource,
        chat,
        runtime,
        revision,
        before,
        loadGeneration,
      )) {
        chat._subagentsError = 'Subagents could not be refreshed.';
      }
    } finally {
      if (!_closed &&
          identical(_resources[chat._key.workspace], resource) &&
          identical(resource._chats[chat._key.sessionId], chat) &&
          chat.runtime.runtimeId == runtime &&
          chat._subagentsLoadGeneration == loadGeneration) {
        chat._subagentsLoading = false;
        _changed();
      }
    }
  }

  Future<GatewaySubagentTail?> loadSubagentTail(
    ProfileChat chat,
    String id,
  ) async {
    final resource = _ownedSubagent(chat, id);
    final runtime = chat.runtime.runtimeId;
    final before = chat._subagents.firstWhere((item) => item.id == id);
    final response = await resource.gateway.call('subagent.tail', {
      'session_id': runtime,
      'subagent_id': id,
    });
    if (!_subagentTailIsCurrent(resource, chat, runtime, before)) {
      return null;
    }
    final tail = GatewaySubagentTail.fromJson(response);
    return tail?.subagentId == id ? tail : null;
  }

  SubagentTimelineSession openSubagentTimeline(ProfileChat chat, String id) {
    final resource = _ownedSubagent(chat, id);
    final child = chat.subagents
        .firstWhere((item) => item.id == id)
        .childSessionId;
    if (child == null) {
      throw StateError('Hermes did not provide a child session.');
    }
    final runtime = chat.runtime.runtimeId;
    bool current() => _subagentTargetIsCurrent(resource, chat, runtime, id);
    return SubagentTimelineSession(
      onOperationalError: reportOperationalError,
      scope: chat.key.workspace,
      sessionId: child,
      isCurrent: current,
      read: (method, params) async {
        if (!current()) throw StateError('Subagent inspection retired');
        return resource.gateway.call(method, params);
      },
      history: (session, offset) async {
        if (!current()) throw StateError('Subagent inspection retired');
        return resource.gateway.history(
          session,
          offset: offset,
          inlineImages: false,
        );
      },
    );
  }

  Future<bool> steerSubagent(
    ProfileChat chat,
    String id,
    String text, {
    required bool Function() canDispatch,
  }) async {
    final message = text.trim();
    if (message.isEmpty) return false;
    final resource = _ownedSubagent(chat, id, active: true);
    final runtime = chat.runtime.runtimeId;
    if (!canDispatch()) return false;
    final response = await resource.gateway.call('subagent.steer', {
      'session_id': runtime,
      'subagent_id': id,
      'text': message,
    });
    if (!_subagentTargetIsCurrent(resource, chat, runtime, id)) {
      return false;
    }
    return response['status'] == 'queued' && response['subagent_id'] == id;
  }

  Future<bool> interruptSubagent(
    ProfileChat chat,
    String id, {
    required bool Function() canDispatch,
  }) async {
    final resource = _ownedSubagent(chat, id, active: true);
    final runtime = chat.runtime.runtimeId;
    if (!canDispatch()) return false;
    final response = await resource.gateway.call('subagent.interrupt', {
      'session_id': runtime,
      'subagent_id': id,
    });
    if (!_subagentTargetIsCurrent(resource, chat, runtime, id)) {
      return false;
    }
    return response['found'] == true && response['subagent_id'] == id;
  }

  ProfileWorkspaceData _ownedSubagent(
    ProfileChat chat,
    String id, {
    bool active = false,
  }) {
    final resource = active ? _commandOwner(chat) : _owned(chat);
    final item = chat._subagents.where((item) => item.id == id).firstOrNull;
    if (id.trim().isEmpty || item == null || (active && item.isTerminal)) {
      throw ArgumentError('Subagent does not belong to this chat');
    }
    return resource;
  }

  bool _subagentReadIsCurrent(
    ProfileWorkspaceData resource,
    ProfileChat chat,
    String runtime,
    int revision,
    List<GatewaySubagentActivity> before,
    int loadGeneration,
  ) =>
      !_closed &&
      identical(_resources[chat._key.workspace], resource) &&
      identical(resource._chats[chat._key.sessionId], chat) &&
      chat.runtime.runtimeId == runtime &&
      chat._subagentsLoadGeneration == loadGeneration &&
      chat._subagentsRevision == revision &&
      identical(chat._subagents, before);

  bool _subagentTargetIsCurrent(
    ProfileWorkspaceData resource,
    ProfileChat chat,
    String runtime,
    String id,
  ) =>
      !_closed &&
      identical(_resources[chat._key.workspace], resource) &&
      identical(resource._chats[chat._key.sessionId], chat) &&
      chat.runtime.runtimeId == runtime &&
      chat._subagents.any((item) => item.id == id);

  bool _subagentTailIsCurrent(
    ProfileWorkspaceData resource,
    ProfileChat chat,
    String runtime,
    GatewaySubagentActivity before,
  ) {
    if (_closed ||
        !identical(_resources[chat._key.workspace], resource) ||
        !identical(resource._chats[chat._key.sessionId], chat) ||
        chat.runtime.runtimeId != runtime) {
      return false;
    }
    final currentActivity = chat._subagents
        .where((item) => item.id == before.id)
        .firstOrNull;
    return currentActivity != null &&
        (before.isTerminal || !currentActivity.isTerminal);
  }

  Timer? _processWatchTimer;
  (ProfileChat, String)? _processWatchTarget;
  Object? _processWatchRead;
  bool _processWatchPending = false;
  bool _processWatchPolling = false;

  void _syncProcessWatch() {
    final chat = notificationChat ?? _current?.chat;
    final target =
        !_closed &&
            visible &&
            chat != null &&
            !chat.runtime.offline &&
            !chat.runtime.opening &&
            !chat.runtime.reconnecting
        ? (chat, chat.runtime.runtimeId)
        : null;
    if (_processWatchPolling &&
        target != null &&
        (target.$1.processesError != null ||
            !target.$1._processes.any((process) => process.isRunning))) {
      _processWatchTimer?.cancel();
      _processWatchTimer = null;
      _processWatchPolling = false;
    }
    if (_processWatchTarget != target) {
      _processWatchTimer?.cancel();
      _processWatchTimer = null;
      _processWatchRead = null;
      _processWatchPending = false;
      _processWatchTarget = target;
      if (target != null) _queueProcessWatch(Duration.zero);
    } else if (target != null &&
        _processWatchRead == null &&
        _processWatchTimer == null &&
        !target.$1.processesLoading &&
        target.$1.processesError == null &&
        target.$1._processes.any((process) => process.isRunning)) {
      _queueProcessWatch(const Duration(seconds: 5), polling: true);
    }
  }

  // The foreground route is the only polling consumer. Events discover new
  // processes even when the current snapshot is empty; a burst costs one read.
  void _processToolSettled(ProfileChat chat) {
    if (_processWatchTarget?.$1 != chat) return;
    if (_processWatchRead != null) {
      _processWatchPending = true;
    } else {
      _processWatchTimer?.cancel();
      _processWatchTimer = null;
      _queueProcessWatch(const Duration(milliseconds: 200));
    }
  }

  void _queueProcessWatch(Duration delay, {bool polling = false}) {
    final target = _processWatchTarget;
    if (target == null || _processWatchTimer != null) return;
    _processWatchPolling = polling;
    _processWatchTimer = Timer(delay, () async {
      _processWatchPolling = false;
      _processWatchTimer = null;
      if (_closed || _processWatchTarget != target) return;
      if ((target.$1._processReads[target.$2] ?? 0) > 0) {
        _queueProcessWatch(const Duration(seconds: 5));
        return;
      }
      final read = _processWatchRead = Object();
      final future = _refreshProcesses(target.$1, quiet: true);
      target.$1._automaticProcessRead = (target.$2, future);
      await future;
      if (target.$1._automaticProcessRead?.$2 == future) {
        target.$1._automaticProcessRead = null;
      }
      if (_closed ||
          _processWatchRead != read ||
          _processWatchTarget != target) {
        return;
      }
      _processWatchRead = null;
      if (_processWatchPending) {
        _processWatchPending = false;
        _queueProcessWatch(const Duration(milliseconds: 200));
      } else {
        _syncProcessWatch();
      }
    });
  }

  Future<void> refreshProcesses(ProfileChat chat) async {
    final automatic = chat._automaticProcessRead;
    if (automatic != null && automatic.$1 == chat.runtime.runtimeId) {
      chat._explicitAutomaticProcessRead = true;
      await automatic.$2;
    } else {
      await _refreshProcesses(chat);
    }
  }

  // A destructive command needs its own accepted read. Ordinary refreshes may
  // be superseded without an error, but cannot prove the list for /stop.
  Future<bool> _refreshProcesses(
    ProfileChat chat, {
    bool requireCurrentRead = false,
    bool quiet = false,
  }) async {
    final resource = _owned(chat);
    final runtime = chat.runtime.runtimeId;
    final before = chat._processes;
    final turn = chat._runtime.turnRevision;
    final generation = ++chat._processesReadGeneration;
    final previousError = chat._processesError;
    final previousInline = chat.inlineProcessesError;
    if (quiet) chat._explicitAutomaticProcessRead = false;
    chat._processReads.update(runtime, (count) => count + 1, ifAbsent: () => 1);
    if (!quiet) {
      chat._processesLoading = true;
      chat._processesError = null;
      _changed(saveReading: false);
    }
    try {
      final response = await resource.gateway.call('process.list', {
        'session_id': runtime,
      });
      if (!_processReadIsCurrent(resource, chat, runtime, before, generation)) {
        return !requireCurrentRead;
      }
      final raw = response['processes'];
      if (raw is! List) throw const FormatException('Missing process list');
      final next = <GatewayProcessActivity>[];
      final reported = <String>{};
      for (final value in raw) {
        if (value is! Map) {
          throw const FormatException('Invalid process row');
        }
        final process = GatewayProcessActivity.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (process == null) {
          throw const FormatException('Invalid process row');
        }
        if (reported.add(process.id)) next.add(process);
      }
      chat._dismissedProcessIds.retainWhere(reported.contains);
      chat._processCompletionTurns.removeWhere(
        (id, _) => !reported.contains(id),
      );
      for (final process in next) {
        if (!process.isRunning) {
          chat._processCompletionTurns.putIfAbsent(
            process.id,
            () => chat.runtime.executionActive ? turn : -1,
          );
        }
      }
      final admitted = next
          .where((process) => !chat._dismissedProcessIds.contains(process.id))
          .toList();
      if (!listEquals(
        before.map((process) => process.observation).toList(),
        admitted.map((process) => process.observation).toList(),
      )) {
        chat._processes = admitted;
      }
      chat._processesError = null;
      reportOperationalError(
        OperationalErrorObservation(
          connectionIdentity: connectionIdentity,
          profileName: chat.key.workspace.profileName,
          operation:
              'processes:${chat.key.workspace.profileName}:${chat.key.sessionId}',
          title: 'Process updates unavailable',
          error: null,
        ),
      );
      return true;
    } catch (_) {
      if (_processReadIsCurrent(resource, chat, runtime, before, generation)) {
        chat._processesError =
            'Background processes could not be refreshed. Retry.';
        chat._passiveProcessFailure =
            quiet &&
            !chat._explicitAutomaticProcessRead &&
            chat.currentProcesses.isNotEmpty;
        if (quiet) {
          reportOperationalError(
            OperationalErrorObservation(
              connectionIdentity: connectionIdentity,
              profileName: chat.key.workspace.profileName,
              operation:
                  'processes:${chat.key.workspace.profileName}:${chat.key.sessionId}',
              title: 'Process updates unavailable',
              error: chat._processesError,
            ),
          );
        }
        return false;
      }
      return !requireCurrentRead;
    } finally {
      final remainingReads = chat._processReads[runtime]! - 1;
      if (remainingReads == 0) {
        chat._processReads.remove(runtime);
      } else {
        chat._processReads[runtime] = remainingReads;
      }
      if (_processOwnerIsCurrent(resource, chat, runtime) &&
          chat._processesReadGeneration == generation) {
        chat._processesLoading = false;
        if (!quiet ||
            !identical(before, chat._processes) ||
            previousError != chat._processesError ||
            previousInline != chat.inlineProcessesError) {
          _changed(browserChat: chat.key, saveReading: false);
        }
      }
    }
  }

  Future<bool> stopProcess(
    ProfileChat chat,
    String id, {
    required bool Function() canDispatch,
  }) async {
    final resource = _commandOwner(chat);
    final runtime = chat.runtime.runtimeId;
    final process = chat._processes.where((item) => item.id == id).firstOrNull;
    if (id.isEmpty ||
        process == null ||
        !process.isRunning ||
        !chat._stoppingProcessIds.add(id)) {
      return false;
    }
    chat._processesError = null;
    chat._passiveProcessFailure = false;
    _changed();
    try {
      _commandOwner(chat);
      if (!canDispatch()) return false;
      final response = await resource.gateway.call('process.kill', {
        'session_id': runtime,
        'process_id': id,
      });
      if (!_processOwnerIsCurrent(resource, chat, runtime)) return false;
      final status = response['status'];
      final responseSessionId = response['session_id'];
      final responseProcessId = response['process_id'];
      final hasConflictingId =
          responseSessionId != null && responseSessionId != id ||
          responseProcessId != null && responseProcessId != id;
      final acknowledged = status == 'killed'
          ? responseSessionId == id && !hasConflictingId
          : status == 'already_exited' && !hasConflictingId;
      if (!acknowledged) {
        chat._processesError =
            'The server did not confirm that the process stopped.';
        _changed();
        return false;
      }
      final refreshed = await _refreshProcesses(chat);
      if (!_processOwnerIsCurrent(resource, chat, runtime)) return false;
      if (!refreshed) {
        chat._processesError =
            'The process stop was acknowledged, but the process list could not be refreshed.';
        _changed();
      }
      return true;
    } catch (_) {
      if (_processOwnerIsCurrent(resource, chat, runtime)) {
        chat._processesError =
            'Stop could not be confirmed. Refresh before trying again.';
        _changed();
      }
      return false;
    } finally {
      chat._stoppingProcessIds.remove(id);
      if (_processOwnerIsCurrent(resource, chat, runtime)) _changed();
    }
  }

  void dismissProcess(ProfileChat chat, String id) {
    _owned(chat);
    final process = chat._processes.where((item) => item.id == id).firstOrNull;
    if (process == null || process.isRunning) return;
    chat._dismissedProcessIds.add(id);
    chat._processes = chat._processes.where((item) => item.id != id).toList();
    chat._processesReadGeneration++;
    chat._processesLoading = false;
    _changed();
  }

  bool _processOwnerIsCurrent(
    ProfileWorkspaceData resource,
    ProfileChat chat,
    String runtime,
  ) =>
      !_closed &&
      identical(_resources[chat._key.workspace], resource) &&
      identical(resource._chats[chat._key.sessionId], chat) &&
      chat.runtime.runtimeId == runtime;

  bool _processReadIsCurrent(
    ProfileWorkspaceData resource,
    ProfileChat chat,
    String runtime,
    List<GatewayProcessActivity> source,
    int generation,
  ) =>
      _processOwnerIsCurrent(resource, chat, runtime) &&
      identical(chat._processes, source) &&
      chat._processesReadGeneration == generation;

  Future<void> refreshSessionControl(ProfileChat chat) async {
    final resource = _owned(chat);
    final runtime = chat.runtime.runtimeId;
    final eventRevision = chat._sessionControlEventRevision;
    final generation = ++chat._sessionControlGeneration;
    chat._sessionControlReadAttempted = true;
    chat._sessionControlLoading = true;
    chat._sessionControlError = null;
    _changed();
    try {
      final response = await resource.gateway.call('session.control.read', {
        'session_id': runtime,
      });
      if (!_sessionControlIsCurrent(resource, chat, runtime) ||
          chat._sessionControlGeneration != generation ||
          chat._sessionControlEventRevision != eventRevision) {
        return;
      }
      final snapshot = SessionControlSnapshot.parse(response);
      if (snapshot == null) {
        throw const FormatException('Invalid session control response');
      }
      chat._sessionControl = snapshot;
    } catch (_) {
      if (_sessionControlIsCurrent(resource, chat, runtime) &&
          chat._sessionControlGeneration == generation &&
          chat._sessionControlEventRevision == eventRevision) {
        chat._sessionControlError =
            'Session controls could not be refreshed. Retry.';
      }
    } finally {
      if (_sessionControlIsCurrent(resource, chat, runtime) &&
          chat._sessionControlGeneration == generation) {
        chat._sessionControlLoading = false;
        _changed();
      }
    }
  }

  Future<bool> controlSession(
    ProfileChat chat,
    SessionControlAction action, {
    required bool Function() canDispatch,
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    final resource = _commandOwner(chat);
    if (chat._sessionControlWorking) return false;
    final requestArgs = Map<String, dynamic>.from(args);
    final runtime = chat.runtime.runtimeId;
    final eventRevision = chat._sessionControlEventRevision;
    chat._sessionControlGeneration++;
    chat._sessionControlLoading = false;
    chat._sessionControlWorking = true;
    chat._sessionControlError = null;
    chat._sessionControlNotice = null;
    _changed();
    try {
      _commandOwner(chat);
      if (!canDispatch()) return false;
      final response = await resource.gateway.call('session.control', {
        'session_id': runtime,
        'action': action.wireValue,
        'args': requestArgs,
      });
      if (!_sessionControlIsCurrent(resource, chat, runtime)) return false;
      final snapshot = SessionControlSnapshot.parse(response);
      final dispatch = _sessionControlDispatch(response['dispatch']);
      if (snapshot == null || dispatch == null) {
        throw const FormatException('Invalid session control action response');
      }
      final eventArrived = chat._sessionControlEventRevision != eventRevision;
      if (eventArrived && chat._sessionControl?.revision != snapshot.revision) {
        chat._sessionControlError =
            'Session control state changed while this action was being confirmed. Refresh before trying again.';
        return false;
      }
      chat._sessionControl = snapshot;
      chat._sessionControlReadAttempted = true;

      if (dispatch.type == 'send') {
        final message = dispatch.message?.trim() ?? '';
        if (message.isEmpty) {
          chat._sessionControlError = _sessionContinuationError;
          return false;
        }
        final accepted = await _sendPrompt(
          chat,
          prompt: message,
          display: dispatch.display,
          preserveComposer: true,
        );
        if (!accepted) {
          if (_sessionControlIsCurrent(resource, chat, runtime)) {
            chat._sessionControlError = _sessionContinuationError;
          }
          return false;
        }
      }
      if (!_sessionControlIsCurrent(resource, chat, runtime)) return false;
      final feedback = dispatch.type == 'exec'
          ? dispatch.output ?? dispatch.notice
          : dispatch.notice;
      chat._sessionControlNotice =
          GatewayNotice.safeLine(feedback, 1000) ?? 'Session controls updated.';
      return true;
    } catch (_) {
      if (_sessionControlIsCurrent(resource, chat, runtime)) {
        chat._sessionControlError =
            chat._sessionControlEventRevision != eventRevision
            ? 'Session controls changed, but the action was not confirmed. Refresh before trying again.'
            : 'Session control failed. Refresh before trying again.';
      }
      return false;
    } finally {
      if (_sessionControlIsCurrent(resource, chat, runtime)) {
        chat._sessionControlWorking = false;
        _changed();
      }
    }
  }

  bool _sessionControlIsCurrent(
    ProfileWorkspaceData resource,
    ProfileChat chat,
    String runtime,
  ) =>
      !_closed &&
      identical(_resources[chat._key.workspace], resource) &&
      identical(resource._chats[chat._key.sessionId], chat) &&
      chat.runtime.runtimeId == runtime;

  ({
    String type,
    String? output,
    String? notice,
    String? message,
    String? display,
  })?
  _sessionControlDispatch(dynamic value) {
    if (value is! Map) return null;
    const fields = {'type', 'output', 'notice', 'message', 'display'};
    if (fields.any((key) => !value.containsKey(key)) ||
        value['type'] != 'exec' && value['type'] != 'send' ||
        [
          value['output'],
          value['notice'],
          value['message'],
          value['display'],
        ].any((field) => field != null && field is! String)) {
      return null;
    }
    return (
      type: value['type'] as String,
      output: value['output'] as String?,
      notice: value['notice'] as String?,
      message: value['message'] as String?,
      display: value['display'] as String?,
    );
  }

  static const _sessionContinuationError =
      'The session changed, but its continuation was not accepted. Check this chat and refresh session controls before trying again.';

  Map<String, dynamic> _contextUsage(Map usage) {
    final used = usage['context_tokens'], maximum = usage['context_length'];
    if (used is num &&
        used.isFinite &&
        used >= 0 &&
        maximum is num &&
        maximum.isFinite &&
        maximum > 0) {
      return {
        ...usage,
        'context_used': used.clamp(0, maximum),
        'context_max': maximum,
        'context_percent': (used / maximum * 100).clamp(0, 100),
        'context_estimated': usage['context_source'] != 'provider_usage',
      };
    }
    return Map<String, dynamic>.from(usage);
  }

  void _updateContext(ProfileChat chat, Map usage) {
    usage = _contextUsage(usage);
    if (usage.containsKey('plan_gauge') || usage.containsKey('calls')) {
      chat._planGauge = CurrentPlanGauge.parse(usage['plan_gauge']);
    }
    final explicitRefresh = chat.contextRefreshPending;
    final compressions = usage['compressions'];
    final compressionChanged =
        compressions is int &&
        compressions >= 0 &&
        chat._contextCompressions != null &&
        chat._contextCompressions != compressions;
    if (compressions is int && compressions >= 0) {
      chat._contextCompressions = compressions;
    }
    if (compressionChanged) _invalidateContextDetails(chat);
    if (!usage.keys.any((key) => key.toString().startsWith('context_'))) {
      if (compressionChanged) {
        unawaited(refreshContext(chat, userInitiated: explicitRefresh));
      }
      return;
    }
    final previous = chat._context;
    chat._contextUsageRevision++;
    chat._context = ContextOccupancy.fromJson({
      if (previous != null) ...{
        'context_used': previous.used,
        'context_max': previous.max,
        'context_percent': previous.percent,
        'context_estimated': previous.estimated,
        'config_context_length': previous.configuredMax,
      },
      ...Map<String, dynamic>.from(usage),
    })?.withCategories(previous?.categories ?? const []);
    if (compressionChanged) {
      unawaited(refreshContext(chat, userInitiated: explicitRefresh));
    }
  }

  void _invalidateContextDetails(ProfileChat chat) {
    chat._contextGeneration++;
    chat._context = chat._context?.withoutCategories();
    chat._contextLoading = false;
    chat._contextError = null;
  }

  Future<void> loadOlderMessages(ProfileChat chat) async {
    final resource = _owned(chat);
    final key = chat._key;
    await chat.reading.loadOlder(
      canPublish: () =>
          !_closed &&
          !switching &&
          identical(_current?.chat, chat) &&
          chat._key == key &&
          identical(resource._chats[key.sessionId], chat) &&
          !resource.blocksSession(key.sessionId),
      onChanged: () {
        if (!_closed) _changed();
      },
    );
  }

  void _replaceSessions(
    ProfileWorkspaceData resource,
    ProfileSessionPage page,
  ) {
    resource._sessions = _readonlyWorkspaceRows(
      _mergeSessionRows(
        [],
        page.rows,
      ).where((row) => !resource.blocksSession(row['id'] as String)).toList(),
    );
    resource._nextSessionOffset = page.nextOffset;
    resource._sessionsPageError = null;
  }

  List<Map<String, dynamic>> _mergeSessionRows(
    List<Map<String, dynamic>> previous,
    List<Map<String, dynamic>> incoming,
  ) => <String, Map<String, dynamic>>{
    for (final row in previous) row['id'] as String: row,
    for (final row in incoming) row['id'] as String: row,
  }.values.toList();

  /// A navigation or refresh invalidates publication, not the owning socket or
  /// any running turn. A failed page keeps its offset and existing rows for retry.
  Future<void> loadMoreSessions() async {
    final resource = _current;
    if (_closed ||
        switching ||
        resource == null ||
        resource._selectedProject != null ||
        resource._sessionsLoadingMore ||
        resource._nextSessionOffset == null) {
      return;
    }
    final generation = resource._sessionGeneration;
    final offset = resource._nextSessionOffset!;
    resource._sessionsLoadingMore = true;
    resource._sessionsPageError = null;
    _changed();
    bool valid() =>
        !_closed &&
        _current == resource &&
        !switching &&
        generation == resource._sessionGeneration;
    try {
      final page = await resource.gateway.sessions(
        visibility: _requiredSessionVisibility(),
        offset: offset,
        archivedOnly: resource._archivedOnly,
      );
      if (!valid()) return;
      resource._sessions = _readonlyWorkspaceRows(
        _mergeSessionRows(resource._sessions, page.rows),
      );
      resource._nextSessionOffset = page.nextOffset;
    } catch (_) {
      if (valid()) {
        resource._sessionsPageError = 'More chats could not be loaded. Retry.';
      }
    } finally {
      if (valid()) {
        resource._sessionsLoadingMore = false;
        _changed();
      }
    }
  }

  Future<void> _refreshSessions(ProfileWorkspaceData resource) async {
    _invalidateSessionLoad(resource);
    final generation = resource._sessionGeneration;
    final page = await resource.gateway.sessions(
      visibility: _requiredSessionVisibility(),
      archivedOnly: resource._archivedOnly,
    );
    if (!_closed && generation == resource._sessionGeneration) {
      _replaceSessions(resource, page);
    }
  }

  ProfileWorkspaceData _writable() {
    if (switching || _current == null) {
      throw StateError('Wait for profile loading');
    }
    return _current!;
  }

  /// New chat needs a validated profile and live transport, not its chat list
  /// or project tree. Those reads remain owned by the connection-wide browser.
  Future<ProfileChat> createBrowserChat({
    required String profileName,
    required bool Function() canDispatch,
    String? initialDraft,
  }) {
    if (_closed || !canDispatch()) {
      throw StateError('Chat creation was cancelled.');
    }
    final resource = browserResource(profileName);
    // This explicit destination supersedes unfinished profile navigation and
    // refresh publication, including a refresh of the same profile.
    final generation = ++_generation;
    _cancelOlderLoads();
    if (_current != null) _invalidateSessionLoad(_current!);
    if (_current != resource) _invalidateSessionLoad(resource);
    _pendingProfile = null;
    return _createChat(
      resource,
      initialDraft: initialDraft,
      browserGeneration: generation,
      canDispatch: canDispatch,
    );
  }

  Future<ProfileChat> createChat({
    required bool Function() canDispatch,
    Map<String, dynamic>? inProject,
    WorkspaceScope? owner,
  }) async {
    final resource = _writable();
    if (owner != null && owner != resource.scope) {
      throw StateError('Profile changed. Open the menu again.');
    }
    final project = inProject ?? resource._selectedProject;
    if (project != null && !resource._projects.contains(project)) {
      throw ArgumentError('Wrong project owner');
    }
    return _createChat(resource, project: project, canDispatch: canDispatch);
  }

  /// Start an independent profile chat with a local, unsent composer draft.
  /// The captured owner also owns the draft if selection changes in flight.
  Future<ProfileChat> createDraftChat({
    required bool Function() canDispatch,
    required WorkspaceScope owner,
    required String text,
  }) async {
    final resource = _writable();
    if (owner != resource.scope) {
      throw StateError('Profile changed. Try again with the selected profile.');
    }
    return _createChat(resource, initialDraft: text, canDispatch: canDispatch);
  }

  Future<ProfileChat> _createChat(
    ProfileWorkspaceData resource, {
    Map<String, dynamic>? project,
    String? initialDraft,
    int? browserGeneration,
    required bool Function() canDispatch,
  }) => _retainWorkspaceOperation(
    () => _createOwnedChat(
      resource,
      project: project,
      initialDraft: initialDraft,
      browserGeneration: browserGeneration,
      canDispatch: canDispatch,
    ),
  );

  Future<ProfileChat> _createOwnedChat(
    ProfileWorkspaceData resource, {
    Map<String, dynamic>? project,
    String? initialDraft,
    int? browserGeneration,
    required bool Function() canDispatch,
  }) async {
    final navigation = ++_navigationGeneration;
    final projectPath = project?['primary_path'];
    if (project != null &&
        (projectPath is! String || projectPath.trim().isEmpty)) {
      throw StateError('The selected project directory is unavailable.');
    }
    final response = await resource.gateway.createSession(
      cwd: projectPath as String?,
      cwdExplicit: project != null,
      canDispatch: () =>
          !_closed &&
          (browserGeneration == null
              ? identical(current, resource)
              : browserGeneration == _generation && !switching) &&
          canDispatch(),
    );
    if (_closed) {
      throw StateError(
        'Chat created in ${resource.scope.profileName}. Reopen the workspace to find it in Chats.',
      );
    }
    _invalidateProjectMembership(resource);
    final id = response['stored_session_id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Missing durable session identity');
    }
    final chat =
        _createChatRecord(
            key: ProfileSessionKey(resource.scope, id),
            runtimeId: response['session_id'] as String,
            title: 'New chat',
            source: 'desktop',
            projectId: project?['id'] as String?,
          )
          .._replaceableUnsubmittedRuntime = true
          .._hidden = false;
    resource._chats[id] = chat;
    _hydrateIntelligence(chat, response);
    unawaited(_observeModelControls(chat));
    _applyTodoSnapshot(chat, response['todo_state']);
    await _restoreDraft(chat);
    if (initialDraft != null) await updateDraft(chat, initialDraft);
    if (browserGeneration != null &&
        browserGeneration == _generation &&
        navigation == _navigationGeneration &&
        !switching &&
        canDispatch()) {
      // Publish the profile and its confirmed new chat together. Publishing
      // the profile earlier would replace the browser and revoke its request
      // while discovery or connection preparation is still in flight.
      _current = resource;
      resource._selectedSession = id;
      resource._offlineSnapshot = false;
      resource._selectedProject = null;
      resource._projectSessions = _readonlyWorkspaceRows([]);
      resource._projectSessionsError = null;
      resource._projectGeneration++;
      resource._projectSessionsLoading = false;
      _error = null;
      _failedSwitchProfile = null;
      _failedSwitchError = null;
      appPreferences.admitProfileSelection(
        connectionIdentity,
        resource.scope.profileName,
      );
      unawaited(appPreferences.settleProfileSelection(connectionIdentity));
    } else if (browserGeneration == null &&
        _current == resource &&
        !switching &&
        navigation == _navigationGeneration) {
      resource._selectedSession = id;
    }
    _browserMutated(
      SessionBrowserMutation(resource.scope, id, projectId: chat._projectId),
    );
    await refreshHistory(chat);
    return chat;
  }

  Future<void> recoverDraft(
    ProfileSessionKey source,
    ProfileChat destination,
  ) async {
    if (!owns(source)) {
      throw ArgumentError('Wrong connection settings or host');
    }
    if (_recoveringStoredDrafts.contains(source)) {
      throw StateError('This saved draft is already being recovered.');
    }
    _commandOwner(destination);
    if (source.workspace != destination._key.workspace) {
      throw ArgumentError('Draft and destination must use the same profile');
    }
    if (_deletedDrafts.blocks(source.workspace.profileName, source.sessionId)) {
      throw StateError('Chat deletion is pending. Local work is kept.');
    }
    final sourceChat = _resources[source.workspace]?._chats[source.sessionId];
    if (sourceChat != null && !sourceChat.runtime.offline ||
        source.sessionId == destination._key.sessionId ||
        !destination._replaceableUnsubmittedRuntime ||
        !destination.composer.observation.restored ||
        destination.runtime.blocksTurnAdmission ||
        destination.composer.observation.text.isNotEmpty ||
        destination.composer.observation.attachments.isNotEmpty ||
        destination.composer.observation.queue.isNotEmpty ||
        destination.composer.observation.saving ||
        destination.composer.observation.draining ||
        destination.runtime.changingAnswer ||
        destination._changingIntelligence ||
        destination.runtime.commandRunning ||
        destination.composer.observation.steering ||
        destination.composer.observation.preparing ||
        destination.composer.admittedWrites != null ||
        destination._replacementCompletion != null) {
      throw StateError('Choose a fresh empty chat for this saved draft.');
    }

    final completion = Completer<void>();
    destination
      .._replacingExpiredRuntime = true
      .._replacementCompletion = completion;
    try {
      if (sourceChat == null) {
        // A source materialized by a concurrent read cannot become a new
        // writer while its existing record is moving to the verified target.
        _recoveringStoredDrafts.add(source);
        await destination.composer.recoverFrom(source);
      } else {
        final transfer = sourceChat.composer.beginTransfer();
        try {
          await sourceChat.composer.moveInto(
            transfer,
            destination.composer,
            forNewSession: true,
          );
        } finally {
          sourceChat.composer.cancelTransfer(transfer);
        }
        if (identical(
          _resources[source.workspace]?._chats[source.sessionId],
          sourceChat,
        )) {
          _resources[source.workspace]?._chats.remove(source.sessionId);
          sourceChat._runtime.dispose();
          sourceChat.reading.dispose();
        }
      }
      _commandOwner(destination);
      _recoveredDraftTargets[source] = destination;
      _changed();
    } finally {
      _recoveringStoredDrafts.remove(source);
      destination._replacingExpiredRuntime = false;
      if (identical(destination._replacementCompletion, completion)) {
        destination._replacementCompletion = null;
      }
      completion.complete();
    }
  }

  /// The browser supplies captured identity and route authority, never a
  /// mutable workspace owner. Recovery policy stays with the connection owner.
  Future<void> openBrowserSession(
    ProfileSessionKey key, {
    String? title,
    required bool Function() isCurrentRequest,
  }) async {
    if (_closed || !isCurrentRequest()) return;
    if (!owns(key)) throw ArgumentError('Wrong connection settings or host');
    // Publish every explicit destination before I/O, including during profile
    // refresh. Browser disposal transfers authority to the opening generation;
    // Back or a newer destination can still cancel its connection/history reads.
    await openNotification(key, title: title);
  }

  /// A saved chat needs a validated profile and transport, not a list/tree.
  /// Keep the existing browser snapshot while the exact destination is opened.
  Future<bool> _selectChatProfile(
    WorkspaceScope scope,
    bool Function()? isCurrentRequest,
  ) async {
    final generation = ++_generation;
    final resource = _resource(scope.profileName);
    _cancelOlderLoads();
    if (_current != null) _invalidateSessionLoad(_current!);
    if (_current != resource) _invalidateSessionLoad(resource);
    _pendingProfile = null;
    bool valid() =>
        !_closed &&
        generation == _generation &&
        (isCurrentRequest?.call() ?? true);
    try {
      final profiles = await resource.gateway.discover();
      if (!valid()) return false;
      if (profiles.named(scope.profileName) == null) {
        throw StateError('Profile ${scope.profileName} is no longer available');
      }
      await resource.gateway.connect();
      if (!valid()) return false;
      _adoptDiscovery(profiles);
      _current = resource;
      _error = null;
      _failedSwitchProfile = null;
      _failedSwitchError = null;
      appPreferences.admitProfileSelection(
        connectionIdentity,
        scope.profileName,
      );
      unawaited(appPreferences.settleProfileSelection(connectionIdentity));
      return true;
    } catch (failure) {
      if (!valid()) return false;
      _initializationFailure = failure;
      _error = failure is StateError
          ? failure.message.toString()
          : workspaceFailureMessage(failure);
      _failedSwitchProfile = scope.profileName;
      _failedSwitchError = _error;
      _changed();
      return false;
    }
  }

  Future<ProfileChat?> openSession(
    ProfileSessionKey key, {
    bool recoverExpiredDraft = false,
    bool propagateHistoryFailure = false,
    bool Function()? isCurrentRequest,
  }) => _openSession(
    key,
    recoverExpiredDraft: recoverExpiredDraft,
    propagateHistoryFailure: propagateHistoryFailure,
    isCurrentRequest: isCurrentRequest,
  );

  /// Reveal owned reading while resume/history reconciliation continues.
  /// The operation retains its resources and reports refresh failures on that
  /// same reading instead of replacing it with an empty opening screen.
  Future<ProfileChat?> openSessionForReading(
    ProfileSessionKey key, {
    required bool Function() isCurrentRequest,
    required void Function(ProfileChat) onReadingAvailable,
  }) => _retainWorkspaceOperation(() async {
    ProfileChat? reading;
    final token = Object();
    bool ownsReading() =>
        reading != null &&
        identical(_resources[key.workspace]?._chats[key.sessionId], reading) &&
        identical(reading!._readingRefresh, token);
    try {
      return await _openSession(
        key,
        isCurrentRequest: isCurrentRequest,
        propagateHistoryFailure: true,
        onReadingAvailable: (chat) {
          if (reading != null || !isCurrentRequest()) return;
          reading = chat;
          chat._readingRefresh = token;
          chat._runtime.beginOpening();
          onReadingAvailable(chat);
          _changed();
        },
      );
    } catch (failure) {
      if (reading == null) rethrow;
      if (ownsReading()) {
        if (isConversationAttachmentRefused(failure)) {
          reading!._attachmentRefused = true;
        }
        reading!._runtime.finishOpening(
          error: _isMissingSessionFailure(failure)
              ? 'This conversation is no longer available. Your saved messages are kept.'
              : failure is JsonRpcError
              ? conversationOpeningFailureMessage(failure)
              : 'Conversation could not be refreshed. Retry to check for new messages.',
        );
      }
      return reading;
    } finally {
      if (ownsReading()) {
        reading!._readingRefresh = null;
        if (reading!.runtime.opening && reading!.runtime.openingError == null) {
          if (reading!.runtime.offline) {
            reading!._runtime.cancelOpening();
          } else {
            reading!._runtime.finishOpening();
          }
        }
        _changed();
      }
    }
  });

  /// Retry this conversation's attachment without treating a refusal as loss of
  /// the whole workspace connection. Saved reading and drafts stay mounted.
  Future<void> retryConversation(ProfileChat chat) async {
    _owned(chat);
    if (chat.refreshingConversation) return;
    if (_notificationTarget == chat.key) {
      final token = Object();
      chat._readingRefresh = token;
      _changed();
      try {
        await _resumeNotification();
      } finally {
        if (identical(chat._readingRefresh, token)) {
          chat._readingRefresh = null;
          _changed();
        }
      }
      return;
    }
    await openSessionForReading(
      chat.key,
      isCurrentRequest: () => !_closed && identical(_current?.chat, chat),
      onReadingAvailable: (_) {},
    );
  }

  /// Camera intake borrows a mounted draft without navigation or server reads.
  /// An absent destination still uses the exact saved-chat recovery workflow.
  Future<({ProfileChat chat, bool retainWorkspace})?> prepareSharedDraftTarget(
    ProfileSessionKey key,
  ) async {
    if (!owns(key)) throw ArgumentError('Wrong connection settings or host');
    if (_closed) return null;
    final retained = _resources[key.workspace]?._chats[key.sessionId];
    final replacement = retained?._replacementCompletion;
    if (replacement != null) await replacement.future;
    if (_closed) return null;
    final chat = _recoveredDraftTarget(key) ?? retained;
    if (chat != null &&
        !switching &&
        hasMountedRoutes &&
        identical(current?.chat, chat)) {
      _commandOwner(chat);
      return (chat: chat, retainWorkspace: true);
    }
    final opened = await openSession(key, recoverExpiredDraft: true);
    return opened == null ? null : (chat: opened, retainWorkspace: false);
  }

  Future<ProfileChat?> _openSession(
    ProfileSessionKey key, {
    bool recoverExpiredDraft = false,
    bool propagateHistoryFailure = false,
    bool Function()? isCurrentRequest,
    void Function(ProfileChat)? onReadingAvailable,
  }) async {
    final navigation = ++_navigationGeneration;
    if (!owns(key)) {
      throw ArgumentError('Wrong connection settings or host');
    }
    if (_closed || isCurrentRequest?.call() == false) return null;
    final retainedResource = _resources[key.workspace];
    final retained = retainedResource?._chats[key.sessionId];
    if (onReadingAvailable != null &&
        _initialized &&
        retainedResource?._offlineSnapshot == false &&
        !retainedResource!.blocksSession(key.sessionId) &&
        retained != null &&
        retained.composer.observation.restored &&
        retained.reading.historySessionId != null) {
      _cancelOlderLoads();
      if (_current != retainedResource || switching) {
        // Browser-list loading is independent of retained conversation reading.
        // Retained profile facts can be selected without rereading discovery,
        // chat lists and projects. Supersede any older profile navigation.
        ++_generation;
        if (_current != null) _invalidateSessionLoad(_current!);
        _invalidateSessionLoad(retainedResource);
        _current = retainedResource;
        _pendingProfile = null;
        _error = null;
        _failedSwitchProfile = null;
        _failedSwitchError = null;
        appPreferences.admitProfileSelection(
          connectionIdentity,
          key.workspace.profileName,
        );
        unawaited(appPreferences.settleProfileSelection(connectionIdentity));
      }
      retainedResource._selectedSession = key.sessionId;
      onReadingAvailable(retained);
      _changed();
    }
    if (recoverExpiredDraft) {
      final replacement = _resources[key.workspace]
          ?._chats[key.sessionId]
          ?._replacementCompletion;
      if (replacement != null) {
        await replacement.future;
        if (_recoveredDraftTarget(key) == null) {
          throw StateError('The draft could not be reconnected.');
        }
      }
    }
    final recovered = recoverExpiredDraft ? _recoveredDraftTarget(key) : null;
    if (recovered != null) {
      key = recovered._key;
    }
    // A newer selection must supersede an unfinished switch even when the
    // user chooses a chat in the profile that is still on screen.
    if ((_current?.scope != key.workspace || switching) &&
        !await _selectChatProfile(key.workspace, isCurrentRequest)) {
      return null;
    }
    if (isCurrentRequest?.call() == false) return null;
    final resource = _resource(key.workspace.profileName);
    if (resource.blocksSession(key.sessionId)) {
      throw StateError(
        resource._quarantinedSessions.contains(key.sessionId)
            ? 'Chat deletion is uncertain. Local work is kept until an owned absence can be verified.'
            : 'Chat was deleted',
      );
    }
    _cancelOlderLoads();
    var chat = resource._chats[key.sessionId];
    var replacedExpiredDraft = false;
    var resumedOnCreation = false;
    if (chat == null) {
      // A UI visit reads saved history independently of runtime attachment.
      // Non-view callers still require a canonical receipt before proceeding.
      final response = onReadingAvailable == null
          ? await resource.gateway.resume(key.sessionId)
          : null;
      if (_closed ||
          !identical(_resources[key.workspace], resource) ||
          resource.blocksSession(key.sessionId)) {
        return null;
      }
      final concurrent = resource._chats[key.sessionId];
      if (concurrent != null) {
        chat = concurrent;
      } else {
        var sessionRow = <Map<String, dynamic>>[
          ?_recentSessionRows[key],
          ...resource.visibleSessions,
          ...resource._sessions,
        ].where((row) => row['id'] == key.sessionId).firstOrNull;
        if (sessionRow == null) {
          try {
            sessionRow = await resource.gateway.sessionMetadata(key.sessionId);
          } catch (_) {
            // Keep the conversation readable; unverified local membership
            // cannot reveal a potentially hidden chat in the default list.
          }
          if (_closed ||
              resource.blocksSession(key.sessionId) ||
              !identical(_resources[key.workspace], resource)) {
            return null;
          }
        }
        if (response?.containsKey('parent_session_id') == true) {
          _applyServerParentRows(
            resource,
            key.sessionId,
            response!['parent_session_id'],
          );
        }
        chat = _createChatRecord(
          key: key,
          runtimeId: response?['session_id'] as String? ?? key.sessionId,
          source: sessionRow?['source']?.toString() ?? '',
          title: sessionRow?['title']?.toString() ?? 'Chat',
          parentSessionId: _serverParent(
            response?.containsKey('parent_session_id') == true
                ? response!['parent_session_id']
                : sessionRow?['parent_session_id'],
            key.sessionId,
          ),
        );
        resource._chats[key.sessionId] = chat;
        chat._hidden = sessionRow == null
            ? null
            : sessionRow['hidden'] == true || sessionRow['hidden'] == 1;
        chat._archived =
            sessionRow?['archived'] == true ||
            sessionRow?['archived'] == 1 ||
            resource._archivedOnly;
        if (resource.blocksSession(key.sessionId)) {
          _cancelImagePreparation(chat);
          resource._chats.remove(key.sessionId);
          chat._runtime.dispose();
          chat.reading.dispose();
          return null;
        }
        if (response != null) {
          _hydrate(chat, response);
          resumedOnCreation = true;
        } else {
          // The durable ID locates saved rows; it grants no runtime authority.
          chat._runtime.installOfflineReading();
        }
        await _restoreDraft(chat);
      }
    }
    if (chat.runtime.offline) {
      if (_closed || isCurrentRequest?.call() == false) return null;
      if (_current == resource &&
          !switching &&
          navigation == _navigationGeneration) {
        resource._selectedSession = key.sessionId;
      }
      await refreshHistory(
        chat,
        propagateFailure: onReadingAvailable != null || propagateHistoryFailure,
      );
      if (_closed ||
          isCurrentRequest?.call() == false ||
          navigation != _navigationGeneration ||
          !identical(resource._chats[key.sessionId], chat)) {
        return null;
      }
      onReadingAvailable?.call(chat);
      _changed();
      if (isCurrentRequest?.call() == false ||
          navigation != _navigationGeneration) {
        return null;
      }
    }
    if (!resumedOnCreation &&
        chat.runtime.execution != ChatExecution.submitting &&
        !chat.composer.observation.sending) {
      chat._runtime.invalidateResume();
      final read = _captureResume(resource, chat);
      // A chat opened elsewhere may have progressed while this view was away.
      // Keep an in-flight local submission intact until its acknowledgement.
      Map<String, dynamic>? response;
      try {
        response = await resource.gateway.resume(key.sessionId);
      } on JsonRpcError catch (error) {
        if (!read.owned()) return null;
        if (!read.current()) return chat;
        if (!recoverExpiredDraft || !_isMissingSessionResume(error)) rethrow;
        var recovered = _recoveredDraftTarget(key);
        final replacement = chat._replacementCompletion;
        if (recovered == null && replacement != null) {
          await replacement.future;
          recovered = _recoveredDraftTarget(key);
          if (recovered == null) rethrow;
        }
        if (recovered != null) {
          chat = recovered;
          key = recovered._key;
        } else {
          if (!_isDefinitivelyExpiredDraft(chat, error)) rethrow;
          await _replaceExpiredDraftRuntime(resource, chat);
          key = chat._key;
        }
        replacedExpiredDraft = true;
      } catch (_) {
        if (!read.owned()) return null;
        if (!read.current()) return chat;
        rethrow;
      }
      if (_closed || resource.blocksSession(key.sessionId)) {
        return null;
      }
      if (!replacedExpiredDraft && !read.owned()) return null;
      if (response != null && read.current()) {
        _hydrate(chat, response);
        chat._parentSessionId = response.containsKey('parent_session_id')
            ? _serverParent(response['parent_session_id'], key.sessionId)
            : parentSessionId(chat);
        if (response.containsKey('parent_session_id')) {
          _applyServerParentRows(
            resource,
            key.sessionId,
            response['parent_session_id'],
          );
        }
        await _restoreDraft(chat);
      }
    }
    if (_closed || !identical(resource._chats[chat._key.sessionId], chat)) {
      return null;
    }
    // The user may have navigated again while resume was in flight.
    if (isCurrentRequest?.call() == false) return null;
    if (_current == resource &&
        !switching &&
        navigation == _navigationGeneration) {
      resource._selectedSession = chat._key.sessionId;
    }
    _changed();
    if (_current?.chat == chat) {
      unawaited(refreshSessionControl(chat));
      unawaited(refreshSubagents(chat));
      unawaited(_loadChatProject(resource, chat));
      await refreshHistory(chat, propagateFailure: propagateHistoryFailure);
      chat._runtime.recovered();
      if (!_closed &&
          _current?.chat == chat &&
          navigation == _navigationGeneration &&
          isCurrentRequest?.call() != false &&
          chat.reading.historyError == null) {
        onReadingAvailable?.call(chat);
      }
      if (!_closed &&
          _current?.chat == chat &&
          navigation == _navigationGeneration &&
          isCurrentRequest?.call() != false &&
          !chat.reading.historyLoading &&
          chat.reading.historyError == null) {
        // Direct Bot/Activity opens can select a restored profile without a
        // browser refresh. Resume and fresh history restore its send authority.
        resource._offlineSnapshot = false;
      }
      if (!chat.runtime.blocksTurnAdmission &&
          chat.reading.historyError == null) {
        chat.reading.updateStreaming('');
      }
      if (!replacedExpiredDraft) await _drainQueuedPrompts(chat);
    }
    return _current == resource && identical(_current?.chat, chat)
        ? chat
        : null;
  }

  ProfileChat? _recoveredDraftTarget(ProfileSessionKey key) {
    final recovered = _recoveredDraftTargets[key];
    return recovered != null &&
            identical(
              _resources[key.workspace]?._chats[recovered._key.sessionId],
              recovered,
            )
        ? recovered
        : null;
  }

  bool _isDefinitivelyExpiredDraft(ProfileChat chat, JsonRpcError error) {
    return chat._replaceableUnsubmittedRuntime &&
        !chat._replacingExpiredRuntime &&
        (chat.composer.observation.preparing ? 1 : 0) == 0 &&
        !chat.runtime.blocksTurnAdmission &&
        !chat.runtime.changingAnswer &&
        !chat._changingIntelligence &&
        !chat.runtime.commandRunning &&
        !chat.composer.observation.saving &&
        !chat.composer.observation.draining &&
        !chat.composer.observation.steering &&
        !chat.runtime.approvalResponding &&
        !chat.runtime.secureResponding &&
        _isMissingSessionResume(error);
  }

  bool _isMissingSessionResume(JsonRpcError error) =>
      error.method == 'session.resume' && error.reason == 'not_found';

  Future<void> _replaceExpiredDraftRuntime(
    ProfileWorkspaceData resource,
    ProfileChat chat,
  ) async {
    final oldKey = chat._key;
    final oldRuntime = chat.runtime.runtimeId;
    if (chat._replacingExpiredRuntime ||
        !identical(resource._chats[oldKey.sessionId], chat)) {
      throw StateError('The draft changed while its chat was reconnecting.');
    }
    final oldComposer = chat.composer;
    final transfer = oldComposer.beginTransfer();
    final replacementCompletion = Completer<void>();
    chat
      .._replacingExpiredRuntime = true
      .._replacementCompletion = replacementCompletion;
    bool unchanged() =>
        !_closed &&
        identical(resource._chats[oldKey.sessionId], chat) &&
        chat._key == oldKey &&
        chat.runtime.runtimeId == oldRuntime &&
        chat._replaceableUnsubmittedRuntime &&
        oldComposer.ownsTransfer(transfer);

    try {
      await chat.composer.saveWork();
      if (!unchanged()) {
        throw StateError('The draft changed while its chat was reconnecting.');
      }
      String? cwd;
      if (chat._projectId != null) {
        final project = resource._projects
            .where((candidate) => candidate['id'] == chat._projectId)
            .firstOrNull;
        final projectPath = project?['primary_path'];
        if (projectPath is! String || projectPath.isEmpty) {
          throw StateError(
            'The original project destination is unavailable. The draft was not moved.',
          );
        }
        cwd = projectPath;
      }
      final created = await resource.gateway.createSession(
        cwd: cwd,
        cwdExplicit: chat._projectId != null,
        canDispatch: unchanged,
      );
      if (!unchanged()) {
        throw StateError('The draft changed while its chat was reconnecting.');
      }
      final newSessionId = created['stored_session_id'];
      final newRuntime = created['session_id'];
      if (newSessionId is! String ||
          newSessionId.isEmpty ||
          newRuntime is! String ||
          newRuntime.isEmpty ||
          newSessionId == oldKey.sessionId ||
          resource._chats.containsKey(newSessionId)) {
        throw const FormatException('Missing replacement session identity');
      }

      final preserveIntelligence = chat._intelligenceRuntime == oldRuntime;
      if (preserveIntelligence &&
          chat._model != null &&
          chat._provider != null) {
        final modelResult = await resource.gateway
            .mutateSession(newRuntime, 'model', {
              'model': chat._model!,
              'provider': chat._provider!,
              if (chat._reasoningEffort != null)
                'reasoning': chat._reasoningEffort!,
            });
        if (modelResult['status'] == 'confirmation_required') {
          throw StateError(
            modelResult['confirm_message']?.toString() ??
                'Model needs confirmation.',
          );
        }
      }
      if (preserveIntelligence && chat._fastMode != null) {
        final fastResult = await resource.gateway.call('config.set', {
          'session_id': newRuntime,
          'key': 'fast',
          'value': chat._fastMode!.name,
        });
        if (ChatFastMode.fromValue(fastResult['value']) != chat._fastMode) {
          throw StateError(
            'Fast mode could not be restored for the replacement chat.',
          );
        }
      }
      if (chat._yolo != null) {
        await resource.gateway.call('config.set', {
          'session_id': newRuntime,
          'key': 'yolo',
          'value': chat._yolo! ? '1' : '0',
        });
      }
      if (!unchanged()) {
        throw StateError('The draft changed while its chat was reconnecting.');
      }

      final replacementComposer = _createComposer(
        ProfileSessionKey(resource.scope, newSessionId),
        () => chat,
      );
      await oldComposer.moveInto(transfer, replacementComposer);
      if (_closed ||
          !identical(resource._chats[oldKey.sessionId], chat) ||
          chat._key != oldKey ||
          chat.runtime.runtimeId != oldRuntime) {
        replacementComposer.dispose();
        throw StateError('The draft changed while its chat was reconnecting.');
      }
      chat._composer = replacementComposer;

      final wasPending = _unrestoredPending.remove(oldKey);
      _cancelImagePreparation(chat);
      resource._chats.remove(oldKey.sessionId);
      chat._intelligenceRevision++;
      chat
        .._key = ProfileSessionKey(resource.scope, newSessionId)
        .._intelligenceRuntime = preserveIntelligence ? newRuntime : null
        ..reading.resetHistorySegment()
        .._runtime.replaceRuntime(newRuntime);
      resource._chats[newSessionId] = chat;
      _recoveredDraftTargets[oldKey] = chat;
      if (resource._selectedSession == oldKey.sessionId) {
        resource._selectedSession = newSessionId;
      }
      if (wasPending) _unrestoredPending.add(chat._key);
      resource._retry?.cancel();
      resource._retry = null;
      resource._reconnectAttempt = 0;
      resource._reconnectError = null;
    } finally {
      oldComposer.cancelTransfer(transfer);
      chat._replacingExpiredRuntime = false;
      if (identical(chat._replacementCompletion, replacementCompletion)) {
        chat._replacementCompletion = null;
      }
      replacementCompletion.complete();
    }
  }

  BrowserProject? chatProject(ProfileChat chat) {
    final project = _owned(chat)._projects
        .where((project) => project['id'] == chat._projectId)
        .firstOrNull;
    return project == null ? null : BrowserProject.fromWire(project);
  }

  String chatProjectLabel(ProfileChat chat) {
    final resource = _owned(chat);
    if (chat._projectId != null) {
      return resource._projectMembershipLabels[chat._projectId] ??
          resource._projects
                  .where((project) => project['id'] == chat._projectId)
                  .firstOrNull?['name']
              as String? ??
          'Project unavailable';
    }
    if (chat._projectLoading) return 'Loading project';
    if (chat._projectLookupFailed) return 'Project unavailable';
    return 'Unassigned';
  }

  Future<void> _loadChatProject(
    ProfileWorkspaceData resource,
    ProfileChat chat,
  ) async {
    if (chat._projectLoading) return;
    chat._projectLoading = true;
    chat._projectLookupFailed = false;
    _changed();
    try {
      if (resource._projectsError != null) {
        throw StateError('Projects unavailable');
      }
      if (resource._projectMembershipLimit == 0 ||
          resource._projectMembership?.containsKey(chat._key.sessionId) !=
              true) {
        await _readProjectMembership(resource);
      }
      if (_closed) return;
      final membership = resource._projectMembership;
      if (membership == null || !membership.containsKey(chat._key.sessionId)) {
        chat._projectLookupFailed = true;
      } else {
        chat._projectId = membership[chat._key.sessionId];
      }
    } catch (_) {
      chat._projectLookupFailed = true;
    } finally {
      chat._projectLoading = false;
      _changed();
    }
  }

  void showList() {
    cancelNotificationOpen();
    _navigationGeneration++;
    _cancelOlderLoads();
    _current?._selectedSession = null;
    _changed();
  }

  Future<void> mutateSession(
    ProfileSessionKey key, {
    Map<String, dynamic> changes = const {},
    bool delete = false,
    int? observedReadThrough,
    required bool Function() canDispatch,
  }) => _retainWorkspaceOperation(
    () => _mutateSession(
      key,
      changes: changes,
      delete: delete,
      observedReadThrough: observedReadThrough,
      canDispatch: canDispatch,
    ),
  );

  Future<void> _mutateSession(
    ProfileSessionKey key, {
    required Map<String, dynamic> changes,
    required bool delete,
    required int? observedReadThrough,
    required bool Function() canDispatch,
  }) async {
    if (_closed || !canDispatch()) throw StateError('Workspace is closed');
    final resource = _writable();
    if (!owns(key) || resource.scope != key.workspace) {
      throw StateError('Profile changed. Open the menu again.');
    }
    final id = key.sessionId;
    if (resource._mutatingSessions.contains(id)) return;
    final chat = resource._chats[id];
    final viewedAt = changes['unread'] == false && chat != null
        ? _latestMessageTime(chat.reading.messages)
        : null;
    if ((delete || changes.containsKey('archived')) &&
        chat?.runtime.blocksTurnAdmission == true) {
      throw StateError(
        'Wait for this chat to finish before archiving or deleting.',
      );
    }
    resource._mutatingSessions.add(id);
    DeletedDraftCleanupReceipt? prepared;
    _changed();
    try {
      if (resource.blocksSession(id)) {
        if (!delete) {
          throw StateError('Chat deletion is pending; local work is kept.');
        }
        if (resource._quarantinedSessions.contains(id)) {
          await _reconcileDeletedDraft(resource, id);
          if (resource._quarantinedSessions.contains(id)) {
            throw StateError(
              'Chat deletion is uncertain. Local work is kept; no delete was repeated.',
            );
          }
        }
        await _cleanupDeletedDraft(resource, id);
        return;
      }
      final storedDraft = delete && chat == null
          ? await _drafts.read(
              profileName: resource.scope.profileName,
              sessionId: id,
            )
          : null;
      int? markedThrough;
      if (!delete &&
          changes['unread'] == false &&
          observedReadThrough == null) {
        final latest = await resource.gateway.history(
          id,
          limit: 1,
          inlineImages: false,
        );
        markedThrough = latest.rows.lastOrNull?['id'] as int?;
      }
      Map<String, dynamic> updated = changes;
      if (delete) {
        final files = [
          ...?chat?.composer.deletionFiles(),
          ...?storedDraft?.attachments.map(DeletedDraftFile.capture),
          ...?storedDraft?.queuedPrompts
              .expand((v) => v.attachments)
              .map(DeletedDraftFile.capture),
        ];
        resource._quarantinedSessions.add(id);
        prepared = await _deletedDrafts.prepare(
          profile: resource.scope.profileName,
          session: id,
          files: files,
        );
        if (_closed) {
          throw StateError('Workspace closed before deletion was sent');
        }
        await resource.gateway.deleteSession(
          id,
          canDispatch: () =>
              !_closed && identical(current, resource) && canDispatch(),
        );
      } else if (changes.length == 1 &&
          changes.containsKey('title') &&
          chat?._replaceableUnsubmittedRuntime == true) {
        if (!identical(current, resource) || !canDispatch()) {
          throw StateError('Profile changed. Open the chat editor again.');
        }
        final result = await resource.gateway.mutateSession(
          chat!.runtime.runtimeId,
          'rename',
          {'title': changes['title']},
        );
        if (result['session_id'] != chat.runtime.runtimeId ||
            result['title'] is! String) {
          throw const FormatException('Invalid chat title acknowledgement');
        }
        updated = {'title': result['title']};
      } else {
        final result = await resource.gateway.updateSession(
          id,
          changes,
          canDispatch: () =>
              !_closed && identical(current, resource) && canDispatch(),
        );
        updated = {
          ...changes,
          if (changes.containsKey('title')) 'title': result['title'],
          if (changes['unread'] == true) 'last_read_at': 0.0,
        };
      }
      if (_closed && !delete) return;
      if (delete) {
        _recentSessionRows.remove(key);
        _recentMessageTimes.remove(key);
      } else if (_recentSessionRows[key] case final row?) {
        _recentSessionRows[key] = {...row, ...updated};
      }
      if (changes.containsKey('unread') && observedReadThrough == null) {
        if (changes['unread'] == false) {
          ConversationReadingRegistry(
            preferences,
          ).chat(key).record(null, readThrough: markedThrough);
        }
        if (chat != null) _readAcknowledgements[chat] = null;
      }
      _invalidateSessionLoad(resource);
      if (delete || changes.containsKey('archived')) {
        _invalidateProjectMembership(resource);
        resource._nextSessionOffset = 0;
      }
      resource._projectGeneration++;
      resource._projectSessionsLoading = false;
      List<Map<String, dynamic>> apply(List<Map<String, dynamic>> rows) => [
        for (final row in rows)
          if (!(row['id'] == id &&
              (delete ||
                  (changes.containsKey('archived') &&
                      changes['archived'] != resource._archivedOnly))))
            row['id'] == id ? {...row, ...updated} : row,
      ];
      resource._sessions = _readonlyWorkspaceRows(apply(resource._sessions));
      resource._projectSessions = _readonlyWorkspaceRows(
        apply(resource._projectSessions),
      );
      if (delete) {
        final cachedAttachments = chat == null
            ? [
                ...?storedDraft?.attachments.map(DeletedDraftFile.capture),
                ...?storedDraft?.queuedPrompts
                    .expand((v) => v.attachments)
                    .map(DeletedDraftFile.capture),
              ]
            : chat.composer.deletionFiles();
        resource._deletedDraftCleanup[id] = (
          files: cachedAttachments,
          writes: chat?.composer.retireAcknowledgedDeletion(),
        );
        resource._quarantinedSessions.remove(id);
        resource._deletedSessions.add(id);
        if (chat != null) {
          _cancelImagePreparation(chat);
          chat._runtime.dispose();
          chat.reading.dispose();
        }
        resource._chats.remove(id);
      } else if (chat != null) {
        if (updated['title'] is String) {
          chat._title = updated['title'] as String;
        }
        if (updated['archived'] is bool) {
          chat._archived = updated['archived'] as bool;
        }
        if (updated['unread'] == false) {
          chat._markReadFailed = false;
          // The successful explicit read acknowledges the delivered history.
          // Keep that boundary with the existing Recents message observation so
          // the same retained answer cannot reassert unread on the next frame.
          if (viewedAt != null && viewedAt > (_recentMessageTimes[key] ?? 0)) {
            _recentMessageTimes[key] = viewedAt;
          }
        }
      }
      if (resource._selectedSession == id &&
          (delete || changes['archived'] == true)) {
        resource._selectedSession = null;
      }
      _browserMutated(
        SessionBrowserMutation(
          resource.scope,
          id,
          changes: updated,
          deleted: delete,
        ),
      );
      if (delete) await _cleanupDeletedDraft(resource, id);
    } catch (failure) {
      if (!_closed &&
          failure is DashboardRequestNotSentException &&
          prepared != null) {
        try {
          await _deletedDrafts.retirePrepared(prepared);
        } catch (_) {
          // An unacknowledged local journal retirement keeps quarantine.
        }
      }
      if (delete &&
          _deletedDrafts.receipt(resource.scope.profileName, id) == null) {
        resource._quarantinedSessions.remove(id);
      }
      if (resource._quarantinedSessions.contains(id) &&
          resource._selectedSession == id) {
        resource._selectedSession = null;
      }
      rethrow;
    } finally {
      resource._mutatingSessions.remove(id);
      _changed();
    }
  }

  Future<void> _recoverDeletedDrafts() async {
    for (final receipt in _deletedDrafts.receipts) {
      if (_closed) return;
      final resource = _resource(receipt.profile);
      try {
        if (!receipt.confirmed) {
          await _reconcileDeletedDraft(resource, receipt.session);
        }
        if (_closed) return;
        if (resource._deletedSessions.contains(receipt.session)) {
          await _cleanupDeletedDraft(resource, receipt.session);
        }
      } catch (_) {
        _error = resource._quarantinedSessions.contains(receipt.session)
            ? 'A chat deletion is uncertain. Local work is kept.'
            : 'Chat deleted. Local draft cleanup is pending; retry cleans only local copies.';
      }
    }
  }

  Future<void> _reconcileDeletedDraft(
    ProfileWorkspaceData resource,
    String id,
  ) async {
    final presence = await resource.gateway.verifyDeletedSession(id);
    if (_closed) return;
    _deletedDraftPresence[ProfileSessionKey(resource.scope, id)] = presence;
    if (presence != SessionPresence.absent) return;
    // This is a scoped observation, not an atomic revision or a replayed DELETE.
    resource._quarantinedSessions.remove(id);
    resource._deletedSessions.add(id);
    final chat = resource._chats.remove(id);
    if (chat != null) {
      _cancelImagePreparation(chat);
      chat._runtime.dispose();
      chat.reading.dispose();
    }
    if (resource._selectedSession == id) resource._selectedSession = null;
    resource._deletedDraftCleanup[id] = (
      files: chat?.composer.deletionFiles() ?? const [],
      writes: chat?.composer.retireAcknowledgedDeletion(),
    );
    _browserMutated(SessionBrowserMutation(resource.scope, id, deleted: true));
  }

  Future<void> _cleanupDeletedDraft(
    ProfileWorkspaceData resource,
    String id,
  ) async {
    final receipt = _deletedDrafts.receipt(resource.scope.profileName, id);
    if (receipt == null ||
        receipt.phase == DeletedDraftCleanupPhase.completed) {
      return;
    }
    if (!resource._deletedSessions.contains(id)) return;
    final cleanup = resource._deletedDraftCleanup[id];
    try {
      // ACK publication already detached the chat. Captured older writes must
      // finish before the final metadata read and destructive local cleanup.
      await cleanup?.writes;
      final stored = await _drafts.read(
        profileName: resource.scope.profileName,
        sessionId: id,
      );
      final confirmed = receipt.acknowledged([
        ...?cleanup?.files,
        ...?stored?.attachments.map(DeletedDraftFile.capture),
        ...?stored?.queuedPrompts
            .expand((p) => p.attachments)
            .map(DeletedDraftFile.capture),
      ]);
      // Persist every file before clearing work. A failed ACK write leaves the
      // earlier prepared receipt durable and conservatively quarantined on boot.
      await _deletedDrafts.acknowledge(
        profile: resource.scope.profileName,
        session: id,
        files: confirmed.files,
      );
      final batch = await attachments.validateDeletedDraftCleanup(
        confirmed.files.map((f) => f.attachment()),
      );
      await _clearStoredDraft(resource.scope, id);
      await attachments.removeDeletedDraftCleanup(batch);
      await _snapshots.deleteToolDurations(resource.scope.profileName, id);
      await _deletedDrafts.complete(resource.scope.profileName, id);
      resource._deletedDraftCleanup.remove(id);
      _scheduleRetention();
    } catch (_) {
      throw StateError(
        'Chat deleted. Local draft cleanup failed; retry only cleans local copies.',
      );
    }
  }

  /// A null project returns the chat to its captured profile's default folder.
  Future<bool> moveSessionToProject(
    ProfileSessionKey key,
    Map<String, dynamic>? project, {
    required bool Function() canDispatch,
  }) => _retainWorkspaceOperation(
    () => _moveSessionToProject(key, project, canDispatch: canDispatch),
  );

  Future<bool> _moveSessionToProject(
    ProfileSessionKey key,
    Map<String, dynamic>? project, {
    required bool Function() canDispatch,
  }) async {
    final resource = _writable();
    if (!owns(key) || resource.scope != key.workspace) {
      throw StateError('Profile changed. Open the menu again.');
    }
    if (project != null &&
        (!resource._projects.contains(project) ||
            project['isNoProject'] == true ||
            ProfileGateway.projectDirectory(project).isEmpty)) {
      throw StateError('Project is unavailable. Open the menu again.');
    }
    final id = key.sessionId;
    if (resource._mutatingSessions.contains(id)) return false;
    if (resource._chats[id]?.runtime.blocksTurnAdmission == true) {
      throw StateError('Wait for this chat to finish before moving.');
    }
    resource._mutatingSessions.add(id);
    _changed();
    try {
      final directory = project == null
          ? await resource.gateway.files.defaultDirectory()
          : ProfileGateway.projectDirectory(project);
      final updated = await resource.gateway.moveSession(
        id,
        directory,
        canDispatch: () =>
            !_closed && identical(current, resource) && canDispatch(),
      );
      if (_closed) return true;
      _invalidateSessionLoad(resource);
      resource._projectGeneration++;
      resource._projectSessionsLoading = false;
      List<Map<String, dynamic>> moved(List<Map<String, dynamic>> rows) => [
        for (final row in rows) row['id'] == id ? {...row, ...updated} : row,
      ];
      resource._sessions = _readonlyWorkspaceRows(moved(resource._sessions));
      resource._projectSessions = _readonlyWorkspaceRows(
        moved(resource._projectSessions),
      );
      _invalidateProjectMembership(resource);
      (resource._projectMembership ??= {})[id] = project?['id'] as String?;
      resource._chats[id]?._projectId = project?['id'] as String?;
      // Do not leave a moved row in its old folder while the tree reloads.
      if (project == null ||
          resource._selectedProject?['id'] != project['id']) {
        resource._projectSessions = _readonlyWorkspaceRows([
          for (final row in resource._projectSessions)
            if (row['id'] != id) row,
        ]);
      }
      _browserMutated(
        SessionBrowserMutation(
          resource.scope,
          id,
          changes: updated,
          projectId: project?['id'] as String?,
        ),
      );
      return true;
    } finally {
      resource._mutatingSessions.remove(id);
      _changed();
    }
  }

  Future<void> selectProject(Map<String, dynamic>? project) {
    _navigationGeneration++;
    final resource = _writable();
    if (project != null && !resource._projects.contains(project)) {
      throw ArgumentError('Wrong project owner');
    }
    _invalidateSessionLoad(resource);
    resource._selectedProject = _readonlyOptionalWorkspaceRow(project);
    resource._selectedSession = null;
    resource._projectSessions = _readonlyWorkspaceRows([]);
    resource._projectSessionsError = null;
    resource._projectGeneration++;
    resource._projectSessionsLoading = false;
    _changed();
    return project == null ? Future.value() : _loadProject(resource, project);
  }

  Future<void> _loadProject(
    ProfileWorkspaceData resource,
    Map<String, dynamic> project,
  ) async {
    final generation = ++resource._projectGeneration;
    resource._projectSessionsLoading = true;
    _changed();
    try {
      final rows = await resource.gateway.projectSessions(
        project['id'] as String,
      );
      if (_closed || generation != resource._projectGeneration) return;
      resource._projectSessions = _readonlyWorkspaceRows(rows);
      resource._projectSessionsError = null;
    } catch (e) {
      if (_closed || generation != resource._projectGeneration) return;
      resource._projectSessions = _readonlyWorkspaceRows([]);
      resource._projectSessionsError = e.toString();
    } finally {
      if (!_closed && generation == resource._projectGeneration) {
        resource._projectSessionsLoading = false;
        _changed();
      }
    }
  }

  Future<void> createProject(
    String name,
    String path, {
    required String color,
    required String icon,
    required bool Function() canDispatch,
  }) => _retainWorkspaceOperation(() async {
    final resource = _writable();
    if (resource._creatingProject) {
      throw StateError(
        'A project is already being created. Wait for it to finish.',
      );
    }
    resource._creatingProject = true;
    _changed();
    try {
      final project = _savedProject(
        await resource.gateway.createProject(
          name,
          path,
          color: color,
          icon: icon,
          canDispatch: () =>
              !_closed && identical(_current, resource) && canDispatch(),
        ),
      );
      if (_closed) return;
      _applyProjects(resource, [...resource._projects, project]);
      _browserMutated(
        ProjectBrowserMutation(
          resource.scope,
          project['id'] as String,
          project,
        ),
      );
    } finally {
      resource._creatingProject = false;
      _changed();
    }
  });

  Map<String, dynamic> _savedProject(Map<String, dynamic> project) {
    if (project['id'] is! String || project['name'] is! String) {
      throw const FormatException('Invalid confirmed project');
    }
    return {
      ...project,
      'label': project['name'],
      'path': project['primary_path'],
    };
  }

  ProfileWorkspaceData _projectMutationOwner(
    WorkspaceScope owner,
    String projectId,
  ) {
    final resource = _writable();
    if (resource.scope != owner) {
      throw StateError('Profile changed. Open the project menu again.');
    }
    if (!resource._projects.any((project) => project['id'] == projectId)) {
      throw StateError('Project is unavailable. Refresh and try again.');
    }
    return resource;
  }

  void _applyProjects(
    ProfileWorkspaceData resource,
    List<Map<String, dynamic>> projects, {
    String? deletedId,
    String? selectedSessionAtMutation,
  }) {
    resource._projects = _readonlyWorkspaceRows(projects);
    _invalidateProjectMembership(resource);
    resource._projectsError = null;
    if (deletedId != null) {
      for (final chat in resource._chats.values) {
        if (chat._projectId == deletedId) {
          chat._projectId = null;
          chat._projectLoading = false;
          chat._projectLookupFailed = false;
        }
      }
    }
    final selectedId = resource._selectedProject?['id'];
    if (deletedId != null && selectedId == deletedId) {
      resource._selectedProject = null;
      if (resource._selectedSession == selectedSessionAtMutation) {
        resource._selectedSession = null;
      }
      resource._projectGeneration++;
      resource._projectSessions = _readonlyWorkspaceRows([]);
      resource._projectSessionsLoading = false;
      resource._projectSessionsError = null;
    } else if (selectedId != null) {
      resource._selectedProject = _readonlyOptionalWorkspaceRow(
        resource._projects
                .where((project) => project['id'] == selectedId)
                .firstOrNull ??
            resource._selectedProject,
      );
    }
  }

  Future<void> updateProject(
    WorkspaceScope owner,
    String id, {
    String? name,
    String? color,
    String? icon,
    String? path,
    required bool Function() canDispatch,
  }) => _retainWorkspaceOperation(() async {
    final resource = _projectMutationOwner(owner, id);
    if (name != null && name.trim().isEmpty ||
        path != null && path.trim().isEmpty) {
      throw ArgumentError('A project name and folder must not be empty');
    }
    bool admitted() =>
        !_closed && identical(current, resource) && canDispatch();
    void publish(Map<String, dynamic> confirmed) {
      if (_closed) return;
      final project = _savedProject(confirmed);
      _applyProjects(resource, [
        for (final existing in resource._projects)
          if (existing['id'] == id) project else existing,
      ]);
      _browserMutated(ProjectBrowserMutation(resource.scope, id, project));
    }

    var folderSaved = false;
    if (path != null) {
      publish(
        await resource.gateway.replaceProjectFolder(
          id,
          path,
          canDispatch: admitted,
          onConfirmed: (confirmed) {
            folderSaved = true;
            publish(confirmed);
          },
        ),
      );
    }
    if (name != null || color != null || icon != null) {
      try {
        publish(
          await resource.gateway.updateProject(
            id,
            name: name,
            color: color,
            icon: icon,
            canDispatch: admitted,
          ),
        );
      } catch (_) {
        if (folderSaved) {
          throw StateError(
            "Folder saved. Other changes weren't confirmed. Try saving again.",
          );
        }
        rethrow;
      }
    } else if (path == null) {
      throw ArgumentError('No project changes supplied');
    }
  });

  Future<void> deleteProject(
    WorkspaceScope owner,
    String id, {
    required bool Function() canDispatch,
  }) => _retainWorkspaceOperation(() async {
    final resource = _projectMutationOwner(owner, id);
    final selectedSession = resource._selectedSession;
    await resource.gateway.deleteProject(
      id,
      canDispatch: () =>
          !_closed && identical(_current, resource) && canDispatch(),
    );
    if (_closed) return;
    _applyProjects(
      resource,
      resource._projects.where((project) => project['id'] != id).toList(),
      deletedId: id,
      selectedSessionAtMutation: selectedSession,
    );
    _browserMutated(ProjectBrowserMutation(resource.scope, id, null));
  });

  void _cancelImagePreparation(ProfileChat chat) =>
      chat.composer.cancelPreparation();

  Future<void> addAttachments(
    ProfileChat chat,
    List<({String path, String name})> files,
  ) async {
    _commandOwner(chat);
    if (!canAddAttachment(chat)) throw StateError('Wait for the current turn');
    await chat.composer.addFiles(files);
    await _drainQueuedPrompts(chat);
  }

  Future<void> addPastedImage(
    ProfileChat chat,
    Future<Uint8List> Function() readImage,
  ) async {
    _commandOwner(chat);
    if (!canAddAttachment(chat)) throw StateError('Wait for the current turn');
    await chat.composer.pasteImage(readImage);
    await _drainQueuedPrompts(chat);
  }

  Future<void> removeAttachment(ProfileChat chat, String id) async {
    _commandOwner(chat);
    if (!canRemoveAttachment(chat, id)) return;
    // Uploads are staging-only: dropping the draft revokes its reference.
    await chat.composer.removeAttachment(id);
  }

  bool canAddAttachment(ProfileChat chat) {
    final resource = _resources[chat._key.workspace];
    return !_closed &&
        identical(resource?._chats[chat._key.sessionId], chat) &&
        !resource!.blocksSession(chat._key.sessionId) &&
        !resource._mutatingSessions.contains(chat._key.sessionId) &&
        !chat._replacingExpiredRuntime &&
        chat.composer.canAddAttachment;
  }

  bool canRemoveAttachment(ProfileChat chat, String id) =>
      canAddAttachment(chat) && chat.composer.canRemoveAttachment(id);

  ProfileSessionKey? get voiceTarget {
    final chat = notificationChat ?? current?.chat;
    return _closed ||
            switching ||
            chat?.composer.observation.editingEntry != null
        ? null
        : chat?.key;
  }

  bool admitsVoice(ProfileChat chat, ProfileSessionKey target) =>
      voiceTarget == target &&
      chat.key == target &&
      identical(notificationChat ?? current?.chat, chat);

  bool admitsDictation(ProfileChat chat, ProfileSessionKey target) =>
      admitsVoice(chat, target) &&
      !chat.runtime.opening &&
      !chat.runtime.commandRunning &&
      !chat.runtime.changingAnswer;

  bool canDictate(ProfileChat chat) => admitsDictation(chat, chat.key);

  VoiceReplyKey voiceReplyKey(ProfileChat chat, Map<String, dynamic> message) =>
      VoiceReplyKey(chat.key, answerMessageId(message) ?? message);

  VoiceReply voiceReply(ProfileChat chat, Map<String, dynamic> message) =>
      VoiceReply(
        key: voiceReplyKey(chat, message),
        text: answerMessageText(message),
      );

  RemoteVoice voiceForChat(ProfileChat chat, ProfileSessionKey target) {
    _owned(chat);
    if (!admitsVoice(chat, target)) {
      throw StateError('This voice target is no longer available.');
    }
    return HermesVoice.forConnection(access, target.workspace.profileName);
  }

  ComposerVoiceDraft captureVoiceDraft(ProfileChat chat) {
    _commandOwner(chat);
    if (!canDictate(chat)) {
      throw StateError('This chat is not available for dictation.');
    }
    return chat.composer.captureVoiceDraft();
  }

  Future<void> applyVoiceDraft(
    ProfileChat chat,
    ComposerVoiceDraft capture,
    String text,
  ) {
    _commandOwner(chat);
    if (!admitsVoice(chat, capture.key)) {
      throw StateError('This chat is not available for dictation.');
    }
    return chat.composer.applyVoiceDraft(capture, text);
  }

  Future<void> updateDraft(
    ProfileChat chat,
    String text, {
    ComposerReference? reference,
  }) {
    _commandOwner(chat);
    final replacement = chat._replacementCompletion;
    if (replacement != null) {
      return replacement.future.then(
        (_) => updateDraft(chat, text, reference: reference),
      );
    }
    return chat.composer.editText(text, reference: reference);
  }

  Future<void> stageSharedDraft(
    ProfileChat chat,
    AndroidSharePayload payload,
  ) async {
    _commandOwner(chat);
    if (!canAddAttachment(chat)) throw StateError('Wait for the current turn');
    await chat.composer.stageShared(payload);
    await _drainQueuedPrompts(chat);
  }

  Future<void> _restoreDraft(ProfileChat chat) => chat.composer.restore();

  Future<void> _restoreWaitingOutboxes() async {
    for (final profile in _discovery!.profiles) {
      final waiting = _drafts
          .summaries(profileName: profile.name)
          .where((draft) => draft.queuedCount > 0)
          .toList();
      if (waiting.isEmpty || _closed) continue;
      final resource = _resource(profile.name);
      for (final draft in waiting) {
        if (resource.blocksSession(draft.sessionId)) continue;
        final chat = resource._chats.putIfAbsent(
          draft.sessionId,
          () => _createChatRecord(
            key: ProfileSessionKey(resource.scope, draft.sessionId),
            runtimeId: draft.sessionId,
            title: 'Chat',
          ).._runtime.installOfflineReading(),
        );
        await _restoreDraft(chat);
      }
      if (!_closed) await _reconnect(resource);
    }
  }

  Future<void> _clearStoredDraft(WorkspaceScope scope, String sessionId) {
    return _drafts.write(
      profileName: scope.profileName,
      sessionId: sessionId,
      text: '',
      attachments: const [],
    );
  }

  static execution.ChatRuntime _createRuntime(
    ProfileSessionKey key,
    String runtimeId,
  ) => execution.ChatRuntime(runtimeId: runtimeId);

  ProfileChat _createChatRecord({
    required ProfileSessionKey key,
    required String runtimeId,
    required String title,
    String source = '',
    String? parentSessionId,
    String? projectId,
  }) {
    final runtime = _runtimeFactory(key, runtimeId);
    if (runtime.observation.runtimeId != runtimeId) {
      runtime.dispose();
      throw StateError(
        'The composed runtime must retain the captured live identity.',
      );
    }
    late final ProfileChat chat;
    final composer = _createComposer(key, () => chat);
    chat = ProfileChat(
      key: key,
      runtime: runtime,
      title: title,
      source: source,
      parentSessionId: parentSessionId,
      projectId: projectId,
      composer: composer,
      reading:
          TranscriptReading(
            readingMemory: ConversationReadingRegistry(preferences).chat(key),
            gateway: _resource(key.workspace.profileName).gateway,
          )..restoreToolDurations(
            _snapshots.readToolDurations(
              key.workspace.profileName,
              key.sessionId,
            ),
          ),
    );
    final questions = HermesQuestionHistory(
      preferences,
      jsonEncode([
        'chat',
        key.workspace.connectionIdentity,
        key.workspace.profileName,
        key.sessionId,
      ]),
    );
    chat.reading.questionHistory = questions;
    runtime.onQuestion = (question) => chat.reading.observeQuestion(
      question,
      afterTool: runtime.observation.activityEntries
          .whereType<ChatToolEntry>()
          .lastOrNull
          ?.activity
          .toolId,
    );
    runtime.onQuestionReconciliation = (kind, active) =>
        questions.reconcile(active, kind: kind);
    runtime.publishQuestionHistory();
    _savedToolDurationRevisions[chat] = (
      key,
      chat.reading.toolDurationRevision,
    );
    return chat;
  }

  ComposerSession _createComposer(
    ProfileSessionKey key,
    ProfileChat Function() chat,
  ) {
    return ComposerSession(
      key: key,
      store: _drafts,
      attachments: attachments,
      ensureAvailable: () {
        _commandOwner(chat());
      },
      acknowledgedDeletion: () =>
          _resources[key.workspace]?.deletedSessions.contains(key.sessionId) ==
              true ||
          _deletedDrafts
                  .receipt(key.workspace.profileName, key.sessionId)
                  ?.confirmed ==
              true,
      runtime: () => _composerRuntime(chat()),
      onChanged: (change) {
        if (_closed) return;
        switch (change) {
          case ComposerChange.text:
            _composerChanges.notifyListeners();
          case ComposerChange.work:
          case ComposerChange.status:
            _changed();
          case ComposerChange.retention:
            _scheduleRetention();
        }
      },
    );
  }

  ComposerRuntimeObservation _composerRuntime(ProfileChat chat) {
    final resource = _resources[chat._key.workspace];
    return ComposerRuntimeObservation(
      runtimeId: chat.runtime.runtimeId,
      working: chat.runtime.blocksTurnAdmission,
      canSteer: chat.runtime.canSteer,
      attachmentBlocked: chat.attachmentBlocked,
      connected:
          !_closed &&
          !chat.runtime.opening &&
          !chat.runtime.offline &&
          resource?._recovering == false &&
          resource?._offlineSnapshot == false &&
          connectionStatus.access != ConnectionAvailability.unavailable &&
          (!connectionStatus.hasLiveObservation(
                chat._key.workspace.profileName,
              ) ||
              connectionStatus.liveAvailable(chat._key.workspace.profileName)),
      automaticDrainAvailable:
          !_closed &&
          !chat.runtime.opening &&
          !chat.runtime.offline &&
          resource?._recovering == false &&
          resource?._offlineSnapshot == false &&
          connectionStatus.access == ConnectionAvailability.available &&
          connectionStatus.liveAvailable(chat._key.workspace.profileName),
      switching: switching,
      changingAnswer: chat.runtime.changingAnswer,
      commandRunning: chat.runtime.commandRunning,
      changingIntelligence: chat._changingIntelligence,
      failedOrCancelled: {
        ChatExecution.failed,
        ChatExecution.cancelled,
      }.contains(chat.runtime.execution),
      historyAvailable: chat.reading.historyError == null,
    );
  }

  ProfileWorkspaceData _owned(ProfileChat chat) {
    final resource = _resources[chat._key.workspace];
    if (resource == null ||
        !identical(resource._chats[chat._key.sessionId], chat)) {
      throw ArgumentError('Chat does not belong to this controller');
    }
    return resource;
  }

  ProfileWorkspaceData _commandOwner(ProfileChat chat) {
    final resource = _owned(chat);
    if (_recoveringStoredDrafts.contains(chat._key)) {
      throw StateError(
        'This saved draft is moving to its new chat. Local work is kept.',
      );
    }
    if (_closed ||
        resource.blocksSession(chat._key.sessionId) ||
        _deletedDrafts.blocks(
          chat._key.workspace.profileName,
          chat._key.sessionId,
        )) {
      throw StateError(
        'Chat deletion is pending or the workspace closed. Local work is kept.',
      );
    }
    return resource;
  }

  /// A resume read can replace only the facts it still owns. Live events and
  /// newer reads take precedence, even when they leave the status unchanged.
  ({bool Function() owned, bool Function() current}) _captureResume(
    ProfileWorkspaceData resource,
    ProfileChat chat, {
    bool startRead = true,
  }) {
    final key = chat._key;
    final capture = chat._runtime.captureRead(startRead: startRead);
    final runtime = capture.runtimeId;
    bool owned() =>
        !_closed &&
        identical(_resources[key.workspace], resource) &&
        !resource.blocksSession(key.sessionId) &&
        chat._key == key &&
        identical(resource._chats[key.sessionId], chat) &&
        chat.runtime.runtimeId == runtime;
    bool currentRead() => owned() && capture.current;
    return (owned: owned, current: currentRead);
  }

  String? _serverParent(Object? value, String sessionId) {
    if (value is! String || value.trim().isEmpty || value == sessionId) {
      return null;
    }
    return value;
  }

  void _applyServerParentRows(
    ProfileWorkspaceData resource,
    String sessionId,
    Object? value,
  ) {
    final parent = _serverParent(value, sessionId);
    List<Map<String, dynamic>> updated(List<Map<String, dynamic>> rows) => [
      for (final row in rows)
        row['id'] == sessionId ? {...row, 'parent_session_id': parent} : row,
    ];
    resource._sessions = _readonlyWorkspaceRows(updated(resource._sessions));
    resource._projectSessions = _readonlyWorkspaceRows(
      updated(resource._projectSessions),
    );
  }

  String? parentSessionId(ProfileChat chat) {
    final resource = _owned(chat);
    final rows = <Map<String, dynamic>>[
      ...resource.visibleSessions,
      ...resource._sessions,
    ];
    for (final row in rows.where((row) => row['id'] == chat._key.sessionId)) {
      if (row.containsKey('parent_session_id')) {
        return _serverParent(row['parent_session_id'], chat._key.sessionId);
      }
    }
    return chat._parentSessionId;
  }

  Future<void> openParentChat(ProfileChat chat) async {
    final resource = _commandOwner(chat);
    final parent = parentSessionId(chat);
    if (parent == null) throw StateError('This chat has no server parent');
    await openSession(ProfileSessionKey(resource.scope, parent));
  }

  /// Canonical branch preparation and commit both require an idle source.
  bool canBranchAnswer(ProfileChat chat) =>
      branchAnswerRestriction(chat) == null;

  /// The same admission decision supplies the saved-answer control's feedback.
  String? branchAnswerRestriction(
    ProfileChat chat, {
    Map<String, dynamic>? message,
  }) {
    if (message != null) {
      final reason = answerBranchRestriction(message);
      if (reason != null) return reason;
    }
    if (_closed || switching) {
      return 'Wait for this chat to finish opening before branching.';
    }
    if (chat.readOnlyReason != null) {
      return 'This chat is read-only. Branching is unavailable.';
    }
    if (chat.runtime.opening) {
      return 'Wait for this chat to finish opening before branching.';
    }
    if (recovering || chat.runtime.reconnecting) {
      return 'Wait for this chat to reconnect before branching.';
    }
    if (chat.runtime.offline) {
      return 'Reconnect before branching this chat.';
    }
    if (chat.runtime.blocksTurnAdmission) {
      return 'Wait for this turn to finish, or stop it, before branching.';
    }
    if (chat.runtime.changingAnswer || chat.branchingAnswer) {
      return 'Wait for the current answer action to finish before branching.';
    }
    if (chat.changingIntelligence) {
      return 'Wait for the model settings to finish changing before branching.';
    }
    return null;
  }

  /// Branches an answer, or regenerates it in place to match Desktop rewind.
  Future<ProfileChat?> branchAnswer(
    ProfileChat source,
    int messageIndex, {
    bool regenerate = false,
    int? expectedLaterTurns,
    bool Function()? isCurrentRequest,
  }) async {
    final resource = _commandOwner(source);
    if ((regenerate
            ? source.runtime.blocksTurnAdmission
            : !canBranchAnswer(source)) ||
        source.runtime.changingAnswer ||
        source.branchingAnswer ||
        source._changingIntelligence ||
        switching) {
      return null;
    }
    if (messageIndex < 0 || messageIndex >= source.reading.messages.length) {
      throw ArgumentError('Unknown answer');
    }
    final selected = source.reading.messages[messageIndex];
    final restriction = regenerate ? null : answerBranchRestriction(selected);
    if (restriction != null) throw StateError(restriction);
    final selectedId = answerMessageId(selected);
    if (selectedId == null) {
      throw StateError('Wait for this answer to be saved');
    }
    final navigation = _navigationGeneration;
    final profileGeneration = _generation;
    if (regenerate) {
      source._runtime.beginAnswerChange(submitting: false);
    } else {
      source._branchingAnswer = true;
    }
    _changed();
    try {
      // Address the saved row, even when only the newest history page is visible.
      final history = regenerate
          ? await resource.gateway.fullHistory(source.runtime.runtimeId)
          : await resource.gateway.branchHistory(
              source._key.sessionId,
              throughRowId: selectedId,
            );
      final targetIndex = history.indexWhere(
        (m) => answerMessageId(m) == selectedId,
      );
      final target = AnswerTarget.at(history, targetIndex);
      if (target == null ||
          answerMessageText(history[targetIndex]) !=
              answerMessageText(selected)) {
        throw StateError(
          'History changed. Reconnect to reload before branching.',
        );
      }
      if (regenerate && target.userOrdinal < 0) {
        throw StateError('This answer has no saved prompt to regenerate');
      }
      if (regenerate) {
        if (!await _regenerate(
          source,
          target,
          expectedLaterTurns: expectedLaterTurns,
        )) {
          throw StateError(source.runtime.error ?? 'Regeneration failed');
        }
        return source;
      }
      final expected = history
          .take(targetIndex + 1)
          .where(isBranchMessage)
          .toList();
      final result = await resource.gateway.branch(
        source.runtime.runtimeId,
        selectedId,
      );
      final id = result['stored_session_id'];
      if (id is! String ||
          id.isEmpty ||
          id == source._key.sessionId ||
          resource._chats.containsKey(id)) {
        throw const FormatException(
          'Branch has no new durable session identity',
        );
      }
      final parent = source._key.sessionId;
      final child = _createChatRecord(
        key: ProfileSessionKey(resource.scope, id),
        runtimeId: result['session_id'] as String,
        source: source._source,
        parentSessionId: parent,
        projectId: source._projectId,
        title: result['title']?.toString() ?? '${source.title} branch',
      );
      // Hydration observes model controls through the canonical chat owner.
      // Register the durable child before any owner-checked observations.
      resource._chats[id] = child;
      _hydrate(child, result);
      child.reading.installSavedHistory(
        answerHistoryRows(ProfileGateway.records(result['messages'])),
      );
      // Retain the returned child even on validation failure, so it is reachable.
      resource._sessions = _readonlyWorkspaceRows([
        {
          'id': id,
          'title': child._title,
          'source': child._source,
          'profile': resource.scope.profileName,
          'parent_session_id': parent,
        },
        ...resource._sessions,
      ]);
      final copied = await resource.gateway.branchHistory(id);
      child.reading.installSavedHistory(answerHistoryRows(copied));
      if (copied.length != expected.length ||
          List.generate(expected.length, (i) => i).any(
            (i) =>
                copied[i]['role'] != expected[i]['role'] ||
                answerMessageText(copied[i]) != answerMessageText(expected[i]),
          )) {
        throw StateError(
          'The fork was created, but its saved history does not match the selected answer. '
          'It is available in Chats. The original is unchanged.',
        );
      }
      if (_current == resource &&
          resource.chat == source &&
          (isCurrentRequest?.call() ?? true) &&
          navigation == _navigationGeneration &&
          profileGeneration == _generation &&
          !switching) {
        resource._selectedSession = id;
      }
      _changed();
      await refreshHistory(child);
      return child;
    } finally {
      if (regenerate) {
        source._runtime.finishAnswerChange();
      } else {
        source._branchingAnswer = false;
      }
      _changed();
    }
  }

  Future<String> reviewWorkspacePath(ProfileChat chat) async {
    final resource = _owned(chat), key = chat.key;
    void requireCurrent() {
      if (_closed || chat.key != key || !identical(_owned(chat), resource)) {
        throw StateError('This conversation changed. Reopen Git review.');
      }
    }

    requireCurrent();
    final path = await _referenceCwd(chat, requireCurrent);
    requireCurrent();
    if (path == null) {
      throw StateError(
        'Git review requires a local terminal workspace reported by this conversation.',
      );
    }
    return path;
  }

  bool _isDestructiveMutationRefusal(Object error) =>
      error is JsonRpcError &&
      error.method == 'session.mutate' &&
      const {
        'invalid_params',
        'revision_conflict',
        'stale_generation',
        'session_busy',
        'unknown_execution',
        'permission_denied',
        'session_read_only',
        'session_superseded',
        'not_found',
        'profile_mismatch',
      }.contains(error.reason);

  Future<void> continueFailedTurn(
    ProfileChat chat,
    TurnFailure expected,
  ) async {
    final gateway = _commandOwner(chat).gateway;
    if (!identical(chat.runtime.failure, expected) ||
        !expected.canContinue ||
        gateway.canonical.session(chat.runtime.runtimeId)?.pending.isNotEmpty ==
            true ||
        chat.runtime.blocksTurnAdmission ||
        chat.composer.observation.sending ||
        chat.composer.observation.preparing ||
        _current?.chat != chat) {
      throw StateError('Review the current conversation before continuing.');
    }
    await _submitRevisionPrompt(chat, 'continue');
    if (identical(chat.runtime.failure, expected) &&
        gateway.canonical
                .session(chat.runtime.runtimeId)
                ?.pending
                .any((row) => !row.queued) ==
            true) {
      chat._runtime.beginTurn(submitting: false);
      _changed();
    }
  }

  Future<void> _submitRevisionPrompt(ProfileChat chat, String text) async {
    final gateway = _commandOwner(chat).gateway;
    final runtime = chat.runtime.runtimeId;
    final ticket = await chat.composer.beginSubmission(
      prompt: text,
      preserveComposer: true,
    );
    var dispatched = false;
    try {
      final payload = <String, dynamic>{
        'session_id': runtime,
        'submission_id': ticket.submissionId,
        'text': text,
        if (gateway.canonicalClarifyBatch) 'clarify_batch': true,
      };
      await chat.composer.prepareDispatch(ticket, payload: payload);
      _commandOwner(chat);
      if (chat.runtime.runtimeId != runtime) {
        throw StateError('Conversation changed before replay.');
      }
      final observedSequence = gateway.canonical.session(runtime)!.sequence;
      dispatched = true;
      final receipt = CanonicalAdmission.fromJson(
        await gateway.call('prompt.submit', payload),
      );
      if (receipt.sessionId != runtime) {
        throw const FormatException(
          'Replay receipt belongs to another conversation',
        );
      }
      gateway.canonical.admission(
        receipt,
        inputId: ticket.submissionId,
        text: ticket.text,
        observedSequence: observedSequence,
      );
      _observeCanonicalPending(chat);
      try {
        await chat.composer.settle(ticket, ComposerDelivery.accepted);
      } finally {
        // The server owns accepted work even if local journal cleanup fails.
        await _refreshCanonicalPending(chat);
      }
    } catch (_) {
      await chat.composer.settle(
        ticket,
        dispatched
            ? ComposerDelivery.uncertain
            : ComposerDelivery.definitelyUnsent,
      );
      rethrow;
    }
  }

  void _requireRevisionDepth(
    List<Map<String, dynamic>> history,
    int index,
    int? expected,
  ) {
    if (expected != null &&
        history.skip(index + 1).where(isHumanAnswerPrompt).length != expected) {
      throw const FormatException(
        'Later work changed. Review the affected turns before revising this message.',
      );
    }
  }

  Future<bool> _regenerate(
    ProfileChat chat,
    AnswerTarget target, {
    int? expectedLaterTurns,
  }) async {
    final resource = _commandOwner(chat);
    final originalReading = chat.reading.captureBranch();
    final runtimeChange = chat._runtime.beginAnswerChange(submitting: true);
    _changed();
    var submitted = false;
    var rejected = false;
    try {
      _commandOwner(chat);
      await resource.gateway.requireProfile();
      final fence = resource.gateway.canonical.session(chat.runtime.runtimeId)!;
      final history = await resource.gateway.fullHistory(
        chat.runtime.runtimeId,
      );
      final users = history.where(isAnswerPrompt).toList();
      if (target.userRowId == null ||
          target.userRowId! <= 0 ||
          target.userOrdinal >= users.length ||
          users[target.userOrdinal]['row_id'] != target.userRowId ||
          answerMessageText(users[target.userOrdinal]) != target.prompt) {
        throw StateError(
          'Could not locate the original prompt in this conversation',
        );
      }
      final prompt = users[target.userOrdinal];
      _requireRevisionDepth(
        history,
        history.indexOf(prompt),
        expectedLaterTurns,
      );
      if (!isHumanAnswerPrompt(prompt)) {
        throw StateError('An internal delivery cannot be replayed as a prompt');
      }
      final rowId = prompt['row_id'];
      if (rowId is! int || rowId <= 0) {
        throw StateError(
          'The gateway did not return a saved prompt address for regeneration',
        );
      }
      _commandOwner(chat);
      final wireText = await _prepareReferences(
        chat,
        answerMessageDisplayText(prompt),
        selected: _savedReferences(prompt),
      );
      await _journal();
      _commandOwner(chat);
      chat.reading.stageRegeneration(history, history.indexOf(prompt));
      chat._runtime.acceptTurn();
      _changed();
      _commandOwner(chat);
      submitted = true;
      await resource.gateway.mutateSession(chat.runtime.runtimeId, 'rewind', {
        'target_message_id': rowId,
      }, expected: fence);
      await _submitRevisionPrompt(chat, wireText);
    } catch (e) {
      _observeCanonicalPending(chat);
      if (!submitted || _isDestructiveMutationRefusal(e)) {
        rejected = true;
        chat.reading.restoreBranch(
          originalReading,
          restoreStreaming: !submitted,
        );
        chat._runtime.rejectRegeneration(
          runtimeChange,
          dispatched: submitted,
          error: e is FormatException && !submitted
              ? e.message.toString()
              : 'Hermes did not accept the regeneration. The conversation is unchanged.',
        );
      } else {
        chat._runtime.deliveryUncertain(
          'Regeneration status is uncertain. Reconnect to check history.',
        );
        _scheduleReconnect(resource);
      }
    }
    await _journal();
    chat._runtime.finishAnswerChange();
    _changed();
    return !rejected;
  }

  /// Admission for the durable prompt edit command, shared by its UI entry points.
  bool canEditSavedPrompt(ProfileChat chat, Map<String, dynamic> selected) =>
      _canReplaceSavedPrompt(chat, selected, restore: false);

  bool canRestoreSavedPrompt(ProfileChat chat, Map<String, dynamic> selected) =>
      _canReplaceSavedPrompt(chat, selected, restore: true) &&
      answerMessageDisplayText(selected).trim().isNotEmpty;

  bool _canReplaceSavedPrompt(
    ProfileChat chat,
    Map<String, dynamic> selected, {
    required bool restore,
  }) =>
      !_closed &&
      chat.readOnlyReason == null &&
      !chat.runtime.opening &&
      !chat.runtime.offline &&
      !recovering &&
      (restore
          ? !chat.runtime.reconnecting &&
                chat.runtime.execution != ChatExecution.submitting
          : !chat.runtime.blocksTurnAdmission) &&
      !chat.runtime.changingAnswer &&
      !chat.branchingAnswer &&
      !chat._changingIntelligence &&
      !chat.runtime.commandRunning &&
      !chat.composer.observation.draining &&
      !switching &&
      isHumanAnswerPrompt(selected) &&
      (answerMessageId(selected) ?? 0) > 0;

  /// Replaces one saved user turn and everything after it in this session.
  Future<bool> editSavedPrompt(
    ProfileChat chat,
    Map<String, dynamic> selected,
    String rawText, {
    int? expectedLaterTurns,
  }) => _replaceSavedPrompt(
    chat,
    selected,
    rawText,
    restore: false,
    expectedLaterTurns: expectedLaterTurns,
  );

  /// Desktop checkpoint restore: cut this prompt and its tail, then rerun it.
  Future<bool> restoreSavedPrompt(
    ProfileChat chat,
    Map<String, dynamic> selected, {
    int? expectedLaterTurns,
  }) => _replaceSavedPrompt(
    chat,
    selected,
    answerMessageDisplayText(selected),
    restore: true,
    expectedLaterTurns: expectedLaterTurns,
  );

  Future<Map<String, dynamic>> _waitForRevisionIdle(
    ProfileChat chat,
    ProfileGateway gateway,
    CanonicalSessionObservation stopped,
    void Function() requireOwner,
  ) async {
    final elapsed = Stopwatch()..start();
    const limit = Duration(seconds: 10);
    while (elapsed.elapsed < limit) {
      requireOwner();
      final snapshot = await gateway
          .resume(chat._key.sessionId)
          .timeout(
            limit - elapsed.elapsed,
            onTimeout: () => throw const FormatException(
              'Hermes is still stopping. Wait for the turn to finish before restoring this prompt.',
            ),
          );
      requireOwner();
      final current = gateway.canonical.session(stopped.sessionId);
      if (snapshot['session_id'] != stopped.sessionId ||
          current == null ||
          current.generation != stopped.generation ||
          current.authorityEpoch != stopped.authorityEpoch ||
          current.replayEpoch != stopped.replayEpoch) {
        throw const FormatException(
          'The running turn changed. Review the conversation before restoring this prompt.',
        );
      }
      if (current.pending.any((row) => row.queued || row.unknown)) {
        throw const FormatException(
          'Queued or uncertain messages still belong to this conversation. Resolve them before restoring this prompt.',
        );
      }
      if (snapshot['running'] == false &&
          current.pending.every((row) => row.status == 'terminal')) {
        return snapshot;
      }
      if (snapshot['running'] is! bool) {
        throw const FormatException(
          'Hermes did not confirm whether the turn has stopped.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw const FormatException(
      'Hermes is still stopping. Wait for the turn to finish before restoring this prompt.',
    );
  }

  Future<bool> _replaceSavedPrompt(
    ProfileChat chat,
    Map<String, dynamic> selected,
    String rawText, {
    required bool restore,
    int? expectedLaterTurns,
  }) async {
    final resource = _commandOwner(chat);
    final runtimeId = chat.runtime.runtimeId;
    final key = chat._key;
    void requireOwner() {
      if (!identical(_commandOwner(chat), resource) ||
          chat._key != key ||
          chat.runtime.runtimeId != runtimeId) {
        throw StateError('The conversation changed during the request');
      }
    }

    final text = rawText.trim();
    final selectedId = answerMessageId(selected);
    if (text.isEmpty ||
        (!restore && text == answerMessageDisplayText(selected).trim())) {
      return false;
    }
    if (!isHumanAnswerPrompt(selected) || selectedId == null) {
      throw StateError('Wait for this message to be saved');
    }
    if (!_canReplaceSavedPrompt(chat, selected, restore: restore)) return false;
    final interruptFirst = restore && chat.runtime.blocksTurnAdmission;
    final originalReading = chat.reading.captureBranch();
    var runtimeChange = chat._runtime.beginAnswerChange(submitting: true);
    _changed();
    ComposerPauseCapture? queuePause;
    var submitted = false;
    var acknowledged = false;
    try {
      queuePause = await chat.composer.pauseForAnswerEdit();
      requireOwner();
      await resource.gateway.requireProfile();
      if (interruptFirst) {
        requireOwner();
        final stopped = resource.gateway.canonical.session(runtimeId)!;
        await resource.gateway.call('session.interrupt', {
          'session_id': runtimeId,
        });
        final idle = await _waitForRevisionIdle(
          chat,
          resource.gateway,
          stopped,
          requireOwner,
        );
        chat._runtime.installResume(idle);
        runtimeChange = chat._runtime.beginAnswerChange(submitting: true);
      }
      final fence = resource.gateway.canonical.session(runtimeId)!;
      final history = await resource.gateway.fullHistory(runtimeId);
      final targetIndex = history.indexWhere(
        (message) => answerMessageId(message) == selectedId,
      );
      if (targetIndex < 0 ||
          !isHumanAnswerPrompt(history[targetIndex]) ||
          answerMessageText(history[targetIndex]) !=
              answerMessageText(selected)) {
        throw StateError(
          'History changed. Reconnect to reload before replacing this prompt.',
        );
      }
      _requireRevisionDepth(history, targetIndex, expectedLaterTurns);
      final rowId = history[targetIndex]['row_id'];
      if (rowId is! int || rowId <= 0) {
        throw StateError('The gateway did not return a saved message address');
      }
      _commandOwner(chat);
      final wireText = await _prepareReferences(
        chat,
        text,
        selected: _savedReferences(selected),
      );
      requireOwner();
      await _journal();
      _commandOwner(chat);
      chat.reading.stageSavedPromptEdit(history, targetIndex, text);
      chat._runtime.acceptTurn();
      _changed();
      requireOwner();
      submitted = true;
      await resource.gateway.mutateSession(runtimeId, 'rewind', {
        'target_message_id': rowId,
      }, expected: fence);
      await _submitRevisionPrompt(chat, wireText);
      acknowledged = true;
    } catch (e) {
      _observeCanonicalPending(chat);
      if (!submitted || _isDestructiveMutationRefusal(e)) {
        chat.reading.restoreBranch(
          originalReading,
          restoreStreaming: !submitted,
        );
        var queueRestored = true;
        if (!submitted) {
          if (queuePause != null) {
            try {
              await chat.composer.finishAnswerEditPause(
                queuePause,
                definitelyUnsent: true,
              );
            } catch (_) {
              queueRestored = false;
            }
          }
        }
        chat._runtime.rejectSavedPromptEdit(
          runtimeChange,
          dispatched: submitted,
          error: e is FormatException && !submitted && queueRestored
              ? e.message.toString()
              : queueRestored
              ? restore
                    ? 'Hermes did not accept the restore. The conversation is unchanged.'
                    : 'Hermes did not accept the edited message.'
              : 'The message was not sent. Local queue recovery could not be saved.',
        );
      } else {
        chat._runtime.deliveryUncertain(
          '${restore ? 'Restore' : 'Edit'} status is uncertain. Reconnect to check history.',
        );
        _scheduleReconnect(resource);
      }
    } finally {
      if (queuePause != null) {
        await chat.composer.finishAnswerEditPause(
          queuePause,
          definitelyUnsent: false,
        );
      }
      chat._runtime.finishAnswerChange();
      await _journal();
      _changed();
    }
    return acknowledged;
  }

  void _hydrateIntelligence(ProfileChat chat, Map<String, dynamic> response) {
    final info = response['info'];
    if (info is Map) {
      if (const [
        'model',
        'provider',
        'reasoning_effort',
      ].any(info.containsKey)) {
        chat._intelligenceRevision++;
      }
      if (!info.containsKey('stored_session_id') ||
          info['stored_session_id'] == chat._key.sessionId) {
        _hydrateTitle(chat, info['title']);
      }
      chat._model = info['model']?.toString() ?? chat._model;
      chat._provider = info['provider']?.toString() ?? chat._provider;
      chat._reasoningEffort =
          info['reasoning_effort']?.toString() ?? chat._reasoningEffort;
      if (info['yolo'] is bool) chat._yolo = info['yolo'] as bool;
      final pending = chat._pendingIntelligence;
      if (pending != null &&
          chat.model == pending.choice.model &&
          (pending.useProfileDefault ||
              chat.provider == pending.choice.provider) &&
          chat.reasoningEffort == pending.reasoningEffort) {
        chat._pendingIntelligence = null;
      }
    }
  }

  void _hydrateTitle(ProfileChat chat, Object? title) {
    if (title is String && title.trim().isNotEmpty) chat._title = title.trim();
  }

  ModelChoice? modelObservation(ProfileChat chat) {
    final catalog = _owned(chat).gateway.modelCatalog.snapshot;
    return catalog?.choice(chat.provider ?? '', chat.model ?? '');
  }

  Future<void> _observeModelControls(ProfileChat chat) async {
    final resource = _owned(chat);
    final runtime = chat.runtime.runtimeId;
    final revision = chat._intelligenceRevision;
    final read = chat._intelligenceReadGeneration;
    try {
      final results = await Future.wait<Object>([
        resource.gateway.modelCatalog.load(),
        resource.gateway.call('config.get', {
          'session_id': runtime,
          'key': 'fast',
        }),
        resource.gateway.call('config.get', {
          'session_id': runtime,
          'key': 'reasoning',
        }),
      ]);
      if (_closed ||
          chat.runtime.runtimeId != runtime ||
          chat._intelligenceRevision != revision ||
          chat._intelligenceReadGeneration != read ||
          chat._changingIntelligence ||
          !identical(_resources[chat.key.workspace], resource)) {
        return;
      }
      chat._fastMode = ChatFastMode.fromValue(
        (results[1] as Map<String, dynamic>)['value'],
      );
      chat._reasoningEffort = WsClient.normalizeReasoningEffort(
        (results[2] as Map<String, dynamic>)['value'],
      );
      chat._intelligenceRevision++;
      _changed();
    } catch (_) {
      // Optional controls wait for a successful read. Opening the picker can retry.
    }
  }

  /// Reads and writes always use this chat's immutable profile owner and live ID.
  Future<
    ({List<ModelChoice> choices, String defaultModel, String? defaultProvider})
  >
  loadIntelligence(ProfileChat chat) async {
    final resource = _commandOwner(chat);
    final gateway = resource.gateway;
    final key = chat._key;
    final runtime = chat.runtime.runtimeId;
    final read = ++chat._intelligenceReadGeneration;
    final revision = chat._intelligenceRevision;
    void requireCurrentRead() {
      if (_closed ||
          chat._key != key ||
          !identical(_resources[key.workspace], resource) ||
          !identical(resource._chats[key.sessionId], chat) ||
          chat.runtime.runtimeId != runtime ||
          read != chat._intelligenceReadGeneration ||
          revision != chat._intelligenceRevision ||
          chat._changingIntelligence) {
        throw StateError('Chat changed. Choose the model again.');
      }
      _commandOwner(chat);
    }

    requireCurrentRead();
    final results = await Future.wait<Object>([
      gateway.read('model/info'),
      gateway.modelCatalog.load(),
      gateway.call('config.get', {'session_id': runtime, 'key': 'reasoning'}),
      gateway.call('config.get', {'session_id': runtime, 'key': 'fast'}),
    ]);
    requireCurrentRead();
    final defaults = results[0] as Map<String, dynamic>;
    final choices = (results[1] as ModelCatalog).choices;
    if (choices.isEmpty) {
      throw StateError('This profile returned no selectable models.');
    }
    chat._intelligenceRevision++;
    chat._model ??= defaults['model']?.toString();
    chat._provider ??= defaults['provider']?.toString();
    chat._reasoningEffort = WsClient.normalizeReasoningEffort(
      (results[2] as Map<String, dynamic>)['value'],
    );
    chat._fastMode = ChatFastMode.fromValue(
      (results[3] as Map<String, dynamic>)['value'],
    );
    _changed();
    return (
      choices: choices,
      defaultModel: defaults['model']?.toString() ?? 'Default',
      defaultProvider: defaults['provider']?.toString(),
    );
  }

  Future<List<ModelChoice>> refreshModelChoices(ProfileChat chat) async {
    final gateway = _owned(chat).gateway;
    final catalog = await gateway.modelCatalog.load(refresh: true);
    _owned(chat);
    _changed();
    return catalog.choices;
  }

  Future<bool> _writeIntelligence(
    ProfileChat chat,
    ChatIntelligenceSelection selection, {
    required Future<bool> Function(String message) confirmModelChange,
  }) async {
    final gateway = _commandOwner(chat).gateway;
    if (!WsClient.validReasoningEfforts.contains(selection.reasoningEffort)) {
      throw ArgumentError('Unsupported reasoning effort');
    }
    final runtime = chat.runtime.runtimeId;
    void requireCurrent() {
      _commandOwner(chat);
      if (_closed ||
          switching ||
          _current?.chat != chat ||
          chat.runtime.runtimeId != runtime ||
          chat.runtime.opening ||
          chat.runtime.reconnecting ||
          chat.runtime.commandRunning ||
          chat.runtime.changingAnswer) {
        throw StateError('Chat changed. Choose the model again.');
      }
    }

    await gateway.requireProfile();
    requireCurrent();
    if (selection.useProfileDefault) {
      final result = await gateway.mutateSession(runtime, 'model', {
        'model': 'reset',
      });
      requireCurrent();
      if (result['status'] == 'deferred') {
        final model = result['model'];
        if (model is! String || model.isEmpty) {
          throw const FormatException('Missing deferred profile model');
        }
        chat._pendingIntelligence = ChatIntelligenceSelection(
          choice: ModelChoice(provider: '', model: model),
          reasoningEffort: chat.reasoningEffort ?? selection.reasoningEffort,
          fastMode: chat.fastMode ?? selection.fastMode,
          useProfileDefault: true,
        );
      } else {
        // Read the resolved session policy; never paint the literal reset token
        // or assume the profile catalog is still current.
        final observed = await gateway.resume(runtime);
        requireCurrent();
        chat._pendingIntelligence = null;
        _hydrateIntelligence(chat, observed);
      }
      chat._intelligenceRevision++;
      chat._intelligenceRuntime = runtime;
      return true;
    }
    final pending = chat.pendingIntelligence;
    final routeChanged =
        (pending?.choice.model ?? chat.model) != selection.choice.model ||
        (pending?.choice.provider ?? chat.provider) !=
            selection.choice.provider;
    var modelChangeAccepted = false;
    if (routeChanged ||
        (pending?.reasoningEffort ?? chat.reasoningEffort) !=
            selection.reasoningEffort) {
      final operation = routeChanged ? 'model' : 'reasoning';
      final payload = <String, dynamic>{
        if (routeChanged) ...{
          'model': selection.choice.model,
          'provider': selection.choice.provider,
          'reasoning': selection.reasoningEffort,
        } else
          'effort': selection.reasoningEffort,
      };
      var result = await gateway.mutateSession(runtime, operation, payload);
      requireCurrent();
      if (result['status'] == 'confirmation_required') {
        final token = result['confirm'];
        if (token is! String || token.isEmpty) {
          throw const FormatException('Missing model confirmation');
        }
        final message = result['confirm_message']?.toString().trim() ?? '';
        if (!await confirmModelChange(
          message.isEmpty
              ? 'Hermes requires confirmation before using this model.'
              : message,
        )) {
          return false;
        }
        requireCurrent();
        result = await gateway.mutateSession(runtime, operation, {
          ...payload,
          'confirm': token,
        });
        requireCurrent();
        if (result['status'] == 'confirmation_required') {
          throw StateError(
            'The model confirmation expired. Choose the model again.',
          );
        }
      }
      if (result['status'] == 'deferred') {
        chat._pendingIntelligence = selection;
      } else {
        chat._pendingIntelligence = null;
        chat._model = selection.choice.model;
        chat._provider = selection.choice.provider;
        chat._reasoningEffort = selection.reasoningEffort;
      }
      chat._intelligenceRevision++;
      modelChangeAccepted = true;
    }
    if (chat.fastMode != selection.fastMode) {
      final Map<String, dynamic> fast;
      try {
        fast = await gateway.call('config.set', {
          'session_id': runtime,
          'key': 'fast',
          'value': selection.fastMode.name,
        });
      } catch (error) {
        final refusal = SettingsWriteRejected.fromFailure(error);
        if (refusal != null) {
          throw StateError(
            '${modelChangeAccepted ? 'The model and reasoning choice was accepted. ' : ''}'
            'Fast mode was refused. ${refusal.message}',
          );
        }
        throw StateError('Fast mode could not be confirmed. Try again.');
      }
      requireCurrent();
      chat._fastMode = ChatFastMode.fromValue(fast['value']);
      if (chat.fastMode != selection.fastMode) {
        throw StateError(
          'Hermes did not confirm fast mode. The model choice was accepted.',
        );
      }
    }
    chat._intelligenceRuntime = runtime;
    return true;
  }

  Future<bool> setIntelligence(
    ProfileChat chat,
    ChatIntelligenceSelection selection, {
    required Future<bool> Function(String message) confirmModelChange,
  }) async {
    _commandOwner(chat);
    if (_closed ||
        chat._replacingExpiredRuntime ||
        chat.runtime.opening ||
        chat.runtime.commandRunning ||
        chat.runtime.reconnecting ||
        chat.readOnlyReason != null ||
        chat.runtime.changingAnswer ||
        chat._changingIntelligence ||
        switching ||
        _current?.chat != chat) {
      throw StateError(
        'Wait for this chat to be ready before changing its model.',
      );
    }
    chat._intelligenceRevision++;
    chat._changingIntelligence = true;
    final previousModel = chat.model;
    final previousProvider = chat.provider;
    _changed();
    try {
      final applied = await _writeIntelligence(
        chat,
        selection,
        confirmModelChange: confirmModelChange,
      );
      if (!applied) return false;
      if (chat.model != previousModel || chat.provider != previousProvider) {
        chat._context = null;
        _invalidateContextDetails(chat);
        unawaited(refreshContext(chat));
      }
      return true;
    } on JsonRpcError catch (error) {
      final refusal = SettingsWriteRejected.fromFailure(error);
      if (refusal != null) throw StateError(refusal.message);
      rethrow;
    } finally {
      _observeCanonicalPending(chat);
      chat._changingIntelligence = false;
      _changed();
    }
  }

  Future<SlashCatalog> commandCatalog(ProfileChat chat) {
    final resource = _owned(chat);
    return resource._commandCatalog ??= (() async {
      try {
        return SlashCatalog.fromJson(
          await resource.gateway.call('commands.catalog', {
            'session_id': chat.runtime.runtimeId,
          }),
        );
      } catch (_) {
        resource._commandCatalog = null;
        rethrow;
      }
    })();
  }

  /// Rescan Hermes first; a failed reload leaves Wing's confirmed catalog intact.
  Future<void> refreshCommandCatalog(ProfileChat chat) async {
    final resource = _owned(chat);
    final runtimeId = chat.runtime.runtimeId;
    void requireCaptured() {
      if (_closed ||
          !identical(_owned(chat), resource) ||
          chat.runtime.runtimeId != runtimeId) {
        throw StateError('The command refresh owner is no longer current');
      }
    }

    requireCaptured();
    final result = await resource.gateway.call('skills.reload', {
      'session_id': runtimeId,
    });
    requireCaptured();
    if (result['output'] is! String || result['result'] is! Map) {
      throw const FormatException('Invalid skills reload response');
    }
    resource._commandCatalog = null;
    await commandCatalog(chat);
    requireCaptured();
  }

  Future<MentionCompletion> completeMention(
    ProfileChat chat,
    MentionQuery query, {
    required BotsSession bots,
    required bool Function() canRead,
    String? directory,
  }) => _completeMention(
    chat,
    query,
    bots: bots,
    canRead: canRead,
    directory: directory,
  );

  Future<SlashCompletion> completeCommand(ProfileChat chat, String text) async {
    final resource = _owned(chat);
    final runtimeId = chat.runtime.runtimeId;
    void requireCaptured() {
      if (_closed ||
          !identical(_owned(chat), resource) ||
          chat.runtime.runtimeId != runtimeId) {
        throw StateError('The command completion owner is no longer current');
      }
    }

    requireCaptured();
    final catalog = await commandCatalog(chat);
    requireCaptured();
    if (SlashCompletion.usesCatalog(text)) {
      return SlashCompletion.fromCatalog(text, catalog);
    }
    final result = await resource.gateway.completeSlash(
      sessionId: runtimeId,
      text: text,
    );
    requireCaptured();
    return SlashCompletion.fromJson(text, result, warning: catalog.warning);
  }

  Future<String?> send(ProfileChat chat) async {
    final resource = _commandOwner(chat);
    if (chat.attachmentBlocked ||
        chat._replacingExpiredRuntime ||
        chat.composer.observation.preparing ||
        chat.runtime.commandRunning ||
        chat._changingIntelligence ||
        switching) {
      return null;
    }
    if (chat.composer.observation.text.trimLeft().startsWith('/')) {
      if (chat.runtime.opening ||
          chat.runtime.offline ||
          resource._recovering) {
        return null;
      }
      await _sendCommand(chat);
      final notification = chat._commandNotification;
      chat._commandNotification = null;
      return notification;
    }
    if (chat.composer.observation.text.trim().isEmpty &&
        chat.composer.observation.attachments.isEmpty) {
      return null;
    }
    await _enqueuePrompt(chat, chat.composer.observation.text, fromSend: true);
    return null;
  }

  Future<void> _sendCommand(ProfileChat chat) async {
    if (chat.runtime.changingAnswer) return;
    final invocation = SlashInvocation.parse(chat.composer.observation.text);
    if (invocation == null) {
      chat._runtime.reportCommandError(
        'Choose a command or enter its name after /.',
      );
      _changed();
      return;
    }
    final resource = _commandOwner(chat);
    final original = chat.composer.observation.text;
    final draftRevision = chat.composer.observation.revision;
    final commandRuntime = chat.runtime.runtimeId;
    chat._commandNotification = null;
    chat._runtime.beginCommand();
    _changed();
    try {
      await chat.composer.saveWork();
      _commandOwner(chat);
      await resource.gateway.requireProfile();
      final catalog = await commandCatalog(chat);
      _commandOwner(chat);
      var name = catalog.resolve(invocation.name);
      var argument = invocation.argument;
      final visited = <String>{};
      while (true) {
        if (!visited.add(name) || visited.length > 16) {
          throw StateError('Command alias cycle');
        }
        if (name == 'compress' || name == 'compact') {
          final unavailable = catalog.unavailable(name);
          if (unavailable != null) throw StateError(unavailable);
          await _compressCommand(chat, resource, commandRuntime, argument);
          await chat.composer.finishCommand(draftRevision);
          break;
        }
        // Session navigation belongs to the phone; slash workers own a different
        // CLI session and must never create, rename or select it on our behalf.
        if (await _localCommand(chat, name, argument)) {
          await chat.composer.finishCommand(draftRevision);
          break;
        }
        final unavailable = catalog.unavailable(name);
        if (unavailable != null) throw StateError(unavailable);
        if (chat.runtime.blocksTurnAdmission &&
            !chat._runtime.canContinueCommandPrompt) {
          throw StateError(
            'Wait for the current turn or stop it before running /$name.',
          );
        }
        Map<String, dynamic> result;
        final runtimeId = chat.runtime.runtimeId;
        chat._runtime.beginCommandDispatch();
        try {
          result = await resource.gateway.dispatchCommand(
            sessionId: runtimeId,
            name: name,
            argument: argument,
            canDispatch: () {
              try {
                return identical(_commandOwner(chat), resource) &&
                    chat.runtime.runtimeId == runtimeId;
              } on StateError {
                return false;
              }
            },
          );
        } finally {
          chat._runtime.finishCommandDispatch();
        }
        final type = result['type'];
        if (type == 'alias') {
          final target = result['target'] as String? ?? '';
          final alias = SlashInvocation.parse(
            '${target.startsWith('/') ? '' : '/'}$target',
          );
          if (alias == null) {
            throw const FormatException('Invalid command alias');
          }
          name = catalog.resolve(alias.name);
          argument = [
            alias.argument,
            argument,
          ].where((s) => s.isNotEmpty).join(' ');
          continue;
        }
        for (final key in ['notice', 'warning', 'output']) {
          final line = result[key];
          if (line is String && line.isNotEmpty) {
            chat.reading.appendCommandNotice(line, command: '/$name');
          }
        }
        if (type == 'skill' || type == 'send' || type == 'prefill') {
          var message = result['message'];
          if (message is! String || message.isEmpty) {
            throw const FormatException('Command returned an empty prompt');
          }
          if (type == 'prefill') {
            await chat.composer.finishCommand(draftRevision, prefill: message);
            // /undo changes server history. Read through the runtime owner.
            await refreshHistory(chat);
          } else {
            if (type == 'skill') {
              final extraSkills = await _expandInlineSkills(
                chat,
                original,
                excluding: {'/$name'},
              );
              if (extraSkills != null) message = '$message\n\n$extraSkills';
            }
            await _sendPrompt(
              chat,
              prompt: message,
              display: result['display'] as String? ?? original,
              commandPrompt: chat._runtime.captureCommandPrompt(),
            );
          }
        } else if ((type == null || type == 'exec' || type == 'plugin') &&
            result['output'] is String) {
          if (chat.composer.observation.attachments.isNotEmpty) {
            chat.reading.appendCommandNotice(
              'Attachments remain in the composer for your next message.',
            );
          }
          await chat.composer.finishCommand(draftRevision);
          try {
            await refreshHistory(chat);
            await _refreshSessions(resource);
          } catch (_) {
            chat.reading.appendCommandNotice(
              'Command finished. Refresh to reload history.',
            );
          }
        } else {
          throw FormatException('Unsupported command response: $type');
        }
        break;
      }
    } catch (e) {
      final uncertain = switch (e) {
        TimeoutException() => true,
        JsonRpcError(reason: 'request_timeout' || 'connection_closed') => true,
        JsonRpcError(
          method: 'slash.exec',
          code: 5030,
          message: 'slash worker timed out',
        ) =>
          true,
        _ => false,
      };
      chat._runtime.reportCommandError(
        uncertain
            ? 'Command status is uncertain. It was not retried. Check the session before running it again.'
            : e is FormatException
            ? e.message.toString()
            : e is StateError
            ? e.message.toString()
            : e.toString(),
      );
    } finally {
      chat._runtime.finishCommand();
      await chat.composer.saveWork();
      _changed();
    }
  }

  /// Canonical compression owns its parser and history mutation. The ordinary
  /// command lifetime owns pending feedback, draft revision and uncertain errors.
  Future<void> _compressCommand(
    ProfileChat chat,
    ProfileWorkspaceData resource,
    String runtime,
    String argument,
  ) async {
    void requireCaptured() {
      if (!identical(_commandOwner(chat), resource) ||
          !identical(current, resource) ||
          !identical(resource.chat, chat) ||
          switching ||
          chat.runtime.runtimeId != runtime) {
        throw StateError(
          'Chat changed. Check its compression result before running the command again.',
        );
      }
    }

    requireCaptured();
    await resource.gateway.connect();
    requireCaptured();
    if (chat.readOnlyReason != null ||
        !chat._runtime.canContinueCommandPrompt) {
      throw StateError(
        'Wait for this chat to be writable and idle before compressing.',
      );
    }
    chat._runtime.beginCommandDispatch();
    final Map<String, dynamic> result;
    try {
      result = await resource.gateway.mutateSession(runtime, 'compress', {
        'focus': argument,
      });
    } finally {
      chat._runtime.finishCommandDispatch();
    }
    requireCaptured();
    if (result['session_id'] != runtime || result['operation'] != 'compress') {
      throw const FormatException(
        'Hermes did not confirm this compression request.',
      );
    }
    final status = result['status'];
    final List<String> lines;
    if (status == 'preview') {
      final report = result['lines'];
      if (report is! List ||
          report.isEmpty ||
          report.any((line) => line is! String)) {
        throw const FormatException(
          'Hermes returned an invalid compression preview.',
        );
      }
      lines = report.cast<String>();
    } else {
      final summary = result['summary'];
      if ((status != null && status != 'noop') ||
          summary is! Map ||
          summary['headline'] is! String ||
          (summary['headline'] as String).trim().isEmpty ||
          (status != 'noop' &&
              (result['revision'] is! int ||
                  result['execution_generation'] is! int))) {
        throw const FormatException(
          'Hermes did not return a confirmed compression result.',
        );
      }
      lines = [
        summary['headline'] as String,
        for (final key in ['token_line', 'note'])
          if (summary[key] case final String line when line.isNotEmpty) line,
      ];
    }
    if (status == 'preview' || status == 'noop') {
      chat.reading.appendCommandNotice(lines.join('\n'), command: '/compress');
      return;
    }
    _invalidateContextDetails(chat);
    var refreshFailed = false;
    try {
      await _refreshHistory(chat, propagateFailure: true, awaitContext: true);
      requireCaptured();
    } catch (_) {
      requireCaptured();
      refreshFailed = true;
    }
    // Compression can replace every saved row ID. Publish its receipt after
    // readback so retaining old local notices cannot move this result to the top.
    chat.reading.appendCommandNotice(lines.join('\n'), command: '/compress');
    if (refreshFailed) {
      chat.reading.appendCommandNotice(
        'Compression finished. Refresh to reload history and context.',
      );
    }
  }

  Future<bool> _localCommand(
    ProfileChat chat,
    String name,
    String argument,
  ) async {
    final resource = _commandOwner(chat);
    switch (name) {
      case 'new':
      case 'reset':
        if (_current != resource || _current?.chat != chat || switching) {
          throw StateError('Return to this chat to create a session.');
        }
        await createChat(
          canDispatch: () =>
              !_closed &&
              !switching &&
              identical(current, resource) &&
              identical(resource.chat, chat),
        );
      case 'profile':
        if (argument.isEmpty) {
          chat.reading.appendCommandNotice(
            'Profile: ${resource.scope.profileName}',
          );
        } else if (_current == resource &&
            _current?.chat == chat &&
            !switching) {
          if (!await switchProfile(argument)) {
            throw StateError(error ?? 'Profile switch failed');
          }
        } else {
          throw StateError('Return to this chat to switch profiles.');
        }
      case 'sessions':
      case 'resume':
      case 'switch':
        if (_current != resource || _current?.chat != chat || switching) {
          throw StateError('Return to this chat to select a session.');
        }
        if (argument.isEmpty) {
          showList();
        } else {
          final matches = resource._sessions
              .where((s) => s['id'] == argument || s['title'] == argument)
              .toList();
          if (matches.length != 1) {
            throw StateError(
              'Choose a session from Chats, or use its exact ID or title.',
            );
          }
          await openSession(
            ProfileSessionKey(resource.scope, matches.single['id'] as String),
          );
        }
      case 'title':
        if (argument.isEmpty) {
          chat.reading.appendCommandNotice(chat._title);
          break;
        }
        _commandOwner(chat);
        final result = await resource.gateway.mutateSession(
          chat.runtime.runtimeId,
          'rename',
          {'title': argument},
        );
        chat._title = result['title'] as String? ?? argument;
        chat.reading.appendCommandNotice('Session title: ${chat.title}');
      case 'branch':
      case 'fork':
        final index = chat.reading.messages.lastIndexWhere(
          (m) =>
              m['role'] == 'assistant' &&
              isBranchMessage(m) &&
              answerMessageId(m) != null,
        );
        if (index < 0) {
          throw StateError('Send a message before branching this chat.');
        }
        final child = await branchAnswer(chat, index);
        if (child == null) throw StateError('Could not branch this chat.');
        if (argument.isNotEmpty) {
          _commandOwner(chat);
          final result = await resource.gateway.mutateSession(
            child.runtime.runtimeId,
            'rename',
            {'title': argument},
          );
          child._title = result['title'] as String? ?? argument;
        }
      case 'save':
        _commandOwner(chat);
        final result = await resource.gateway.call('session.save', {
          'session_id': chat.runtime.runtimeId,
        });
        final file = result['file'];
        if (file is! String || file.isEmpty) {
          throw const FormatException(
            'The server did not return the saved file path.',
          );
        }
        chat.reading.appendCommandNotice('Saved on the Hermes host: $file');
      case 'status':
        _commandOwner(chat);
        final result = await resource.gateway.call('slash.exec', {
          'session_id': chat.runtime.runtimeId,
          'command': argument.isEmpty ? '/status' : '/status $argument',
        });
        if (result['type'] != 'exec' || result['output'] is! String) {
          throw const FormatException(
            'Hermes did not return the session status.',
          );
        }
        chat.reading.appendCommandNotice(result['output'] as String);
      case 'yolo':
        if (argument.isNotEmpty) throw StateError('Usage: /yolo');
        if (chat._yolo == null) {
          final read = _captureResume(resource, chat);
          _commandOwner(chat);
          final response = await resource.gateway.resume(chat._key.sessionId);
          if (!read.owned()) {
            throw StateError('Chat changed while reconnecting.');
          }
          if (read.current()) _hydrate(chat, response);
        }
        final currentValue = chat._yolo;
        if (currentValue == null) {
          throw const FormatException(
            'The server did not report this session\'s YOLO state. '
            'Reconnect and try again.',
          );
        }
        final runtime = chat.runtime.runtimeId;
        _commandOwner(chat);
        final result = await resource.gateway.call('config.set', {
          'session_id': runtime,
          'key': 'yolo',
          'value': currentValue ? '0' : '1',
        });
        if (chat.runtime.runtimeId != runtime) {
          throw StateError('Chat reconnected. Check YOLO before trying again.');
        }
        final effectiveValue = result['value']?.toString();
        if (effectiveValue != '0' && effectiveValue != '1') {
          throw const FormatException(
            'The server did not confirm this session\'s YOLO state.',
          );
        }
        chat._yolo = effectiveValue == '1';
        final feedback = chat._yolo!
            ? 'YOLO enabled for this session.'
            : 'YOLO disabled for this session.';
        if (chat._replaceableUnsubmittedRuntime &&
            chat.reading.messages.isEmpty &&
            !chat.runtime.blocksTurnAdmission) {
          chat._commandNotification = feedback;
        } else {
          chat.reading.appendCommandNotice(feedback);
        }
      case 'history':
        await refreshHistory(chat);
        chat.reading.appendCommandNotice('Conversation history refreshed.');
      case 'bg':
      case 'background':
        if (argument.isEmpty) throw StateError('Usage: /$name <message>');
        await _startTaskDelivery(
          chat,
          resource,
          kind: SideQuestionDeliveryKind.backgroundTask,
          method: 'prompt.background',
          prompt: argument,
        );
        chat.reading.appendCommandNotice('Started /$name on the Hermes host.');
      case 'btw':
        if (argument.isEmpty) throw StateError('Usage: /btw <message>');
        await _startTaskDelivery(
          chat,
          resource,
          kind: SideQuestionDeliveryKind.sideQuestion,
          method: 'prompt.btw',
          prompt: argument,
        );
        chat.reading.appendCommandNotice('Started /btw on the Hermes host.');
      case 'stop':
      case 'interrupt':
        final runtime = chat.runtime.runtimeId;
        await stop(chat);
        chat.reading.appendCommandNotice('Interrupt requested.');
        if (name == 'stop') {
          // Stock process.stop kills the entire server registry. A chat-local
          // command must use the session-owned list and individual kill RPCs.
          if (chat.runtime.runtimeId != runtime ||
              !await _refreshProcesses(chat, requireCurrentRead: true) ||
              !_processOwnerIsCurrent(resource, chat, runtime)) {
            throw StateError(
              'Background processes could not be confirmed. Refresh before trying again.',
            );
          }
          final running = chat._processes.where((p) => p.isRunning).toList();
          var stopped = 0;
          for (final process in running) {
            if (chat.runtime.runtimeId != runtime ||
                !await stopProcess(
                  chat,
                  process.id,
                  canDispatch: () =>
                      _processOwnerIsCurrent(resource, chat, runtime),
                )) {
              throw StateError(
                'Background process stop could not be confirmed. Refresh before trying again.',
              );
            }
            stopped++;
          }
          chat.reading.appendCommandNotice(
            'Background processes stopped: $stopped',
          );
        }
      case 'skills':
        if (argument.isNotEmpty && argument != 'list') return false;
        final catalog = await commandCatalog(chat);
        chat.reading.appendCommandNotice(
          catalog.commands
              .where((c) => c.category.toLowerCase().contains('skill'))
              .map((c) => '${c.text}  ${c.description}')
              .join('\n'),
        );
        if (catalog.warning.isNotEmpty) {
          chat.reading.appendCommandNotice(catalog.warning);
        }
      case 'help':
      case 'commands':
        final catalog = await commandCatalog(chat);
        chat.reading.appendCommandNotice(
          catalog.commands.map((c) => '${c.text}  ${c.description}').join('\n'),
        );
        if (catalog.warning.isNotEmpty) {
          chat.reading.appendCommandNotice(catalog.warning);
        }
      case 'steer':
        if (argument.isEmpty) throw StateError('Usage: /steer <message>');
        if (!await steer(chat, argument)) {
          throw StateError('Hermes rejected the steering message.');
        }
      default:
        return false;
    }
    return true;
  }

  Future<void> _startTaskDelivery(
    ProfileChat chat,
    ProfileWorkspaceData resource, {
    required SideQuestionDeliveryKind kind,
    required String method,
    required String prompt,
  }) async {
    chat._replaceableUnsubmittedRuntime = false;
    _commandOwner(chat);
    final runtime = chat.runtime.runtimeId;
    final wireText = await _prepareReferences(
      chat,
      prompt,
      selected: chat.composer.observation.references,
    );
    _commandOwner(chat);
    if (chat.runtime.runtimeId != runtime) {
      throw StateError('The conversation changed before sending.');
    }
    final result = await resource.gateway.call(method, {
      'session_id': runtime,
      'text': wireText,
    });
    final rawTaskId = result['task_id'];
    if (rawTaskId is! String || rawTaskId.trim().isEmpty) {
      final task = kind == SideQuestionDeliveryKind.sideQuestion
          ? 'side question'
          : 'background task';
      throw FormatException(
        'Hermes did not confirm the $task. '
        'Check whether it started before sending this draft again.',
      );
    }
    final taskId = rawTaskId.trim();
    final index = chat._sideQuestionDeliveries.indexWhere(
      (delivery) => delivery.kind == kind && delivery.taskId == taskId,
    );
    if (index < 0) {
      chat._sideQuestionDeliveries.add(
        SideQuestionDelivery(
          kind: kind,
          taskId: taskId,
          question: prompt,
          state: SideQuestionDeliveryState.pending,
        ),
      );
      return;
    }
    final delivery = chat._sideQuestionDeliveries[index];
    if (delivery.question.isEmpty &&
        delivery.state == SideQuestionDeliveryState.completed) {
      chat._sideQuestionDeliveries[index] = delivery.complete(
        result: delivery.result,
        question: prompt,
      );
    }
  }

  void _completeTaskDelivery(
    ProfileChat chat,
    SideQuestionDeliveryKind kind,
    Map<String, dynamic> data, {
    bool skipBlankResult = false,
  }) {
    final response = data['text']?.toString().trim() ?? '';
    if (response.isEmpty && skipBlankResult) return;
    final result = response.isEmpty
        ? 'No response text was returned.'
        : response;
    final rawTaskId = data['task_id'];
    final taskId = rawTaskId is String && rawTaskId.trim().isNotEmpty
        ? rawTaskId.trim()
        : null;
    final questionWire = data['question']?.toString().trim() ?? '';
    final question =
        PreparedComposerMessage.parse(questionWire)?.message ?? questionWire;
    final index = taskId == null
        ? -1
        : chat._sideQuestionDeliveries.indexWhere(
            (delivery) => delivery.kind == kind && delivery.taskId == taskId,
          );
    if (index >= 0) {
      chat._sideQuestionDeliveries[index] = chat._sideQuestionDeliveries[index]
          .complete(result: result, question: question);
    } else {
      chat._sideQuestionDeliveries.add(
        SideQuestionDelivery(
          kind: kind,
          taskId: taskId,
          question: question,
          state: SideQuestionDeliveryState.completed,
          result: result,
        ),
      );
    }
    _notify(
      chat,
      ChatNotificationContent.reply(response),
      focus: taskId == null
          ? null
          : NotificationFocus(
              kind == SideQuestionDeliveryKind.backgroundTask
                  ? 'background'
                  : 'side',
              taskId,
            ),
      eventId: _notificationEventId(data),
    );
  }

  Future<bool> _sendPrompt(
    ProfileChat chat, {
    String? prompt,
    String? display,
    bool preserveComposer = false,
    ComposerQueueId? queuedPrompt,
    execution.ChatRuntimeCommandPrompt? commandPrompt,
  }) async {
    final resource = _commandOwner(chat);
    final work = chat.composer.observation;
    final admittingQueue =
        queuedPrompt != null && chat.runtime.blocksTurnAdmission;
    if (chat._readOnlyReason != null ||
        chat._replacingExpiredRuntime ||
        (commandPrompt == null
            ? (!admittingQueue && chat.runtime.blocksTurnAdmission)
            : !commandPrompt.current) ||
        work.sending ||
        work.saving ||
        work.preparing ||
        chat.runtime.changingAnswer ||
        chat._changingIntelligence ||
        ((prompt ?? work.text).trim().isEmpty &&
            work.attachments.isEmpty &&
            queuedPrompt == null)) {
      return false;
    }
    if (commandPrompt == null && !admittingQueue) {
      chat._runtime.beginTurn(submitting: true);
    } else if (commandPrompt != null) {
      chat._runtime.beginCommandPrompt(commandPrompt);
    }
    chat.reading.cancelReads();
    chat._lastActive = DateTime.now().millisecondsSinceEpoch / 1000;
    ComposerSubmission? ticket;
    var submitted = false, acknowledged = false;
    try {
      ticket = await chat.composer.beginSubmission(
        prompt: prompt,
        preserveComposer: preserveComposer,
        queued: queuedPrompt,
      );
      _changed();
      _commandOwner(chat);
      if (commandPrompt != null && !commandPrompt.current) {
        throw StateError('The command continuation has changed.');
      }
      await resource.gateway.requireProfile();
      await _journal();
      final runtime = chat.runtime.runtimeId;
      final refs = await chat.composer.upload(
        ticket,
        runtimeId: runtime,
        upload: (file) async {
          _commandOwner(chat);
          if (commandPrompt != null && !commandPrompt.current) {
            throw StateError('The command continuation has changed.');
          }
          if (chat.runtime.runtimeId != runtime) {
            throw StateError('Chat reconnected while uploading.');
          }
          final result = await resource.gateway
              .call(file.isImage ? 'image.attach_bytes' : 'file.attach', {
                'session_id': runtime,
                if (file.isImage) 'filename': file.name else 'name': file.name,
                if (file.isImage)
                  'content_base64': file.dataUrl.substring(
                    file.dataUrl.indexOf(',') + 1,
                  )
                else
                  'data_url': file.dataUrl,
              });
          chat._replaceableUnsubmittedRuntime = false;
          if (file.isImage) {
            final path = result['path'];
            if (result['attached'] != true || path is! String || path.isEmpty) {
              throw AttachmentDraftException(
                result['message'] as String? ??
                    'Could not attach ${file.name}.',
              );
            }
            return AttachmentUploadReceipt(
              imagePath: path,
              attachedSessionId: runtime,
            );
          }
          final ref = result['ref_text'];
          if (result['attached'] != true || ref is! String || ref.isEmpty) {
            throw const FormatException('Missing attachment reference');
          }
          return AttachmentUploadReceipt(refText: ref);
        },
      );
      _commandOwner(chat);
      if (commandPrompt != null && !commandPrompt.current) {
        throw StateError('The command continuation has changed.');
      }
      await resource.gateway.requireProfile();
      _commandOwner(chat);
      if (commandPrompt != null && !commandPrompt.current) {
        throw StateError('The command continuation has changed.');
      }
      if (chat.runtime.runtimeId != runtime) {
        throw StateError('Chat reconnected while preparing this prompt.');
      }
      final draftText = ticket.text.trim();
      final expanded = commandPrompt == null && display == null
          ? await _expandInlineSkills(chat, draftText, excluding: const {})
          : null;
      final text = expanded ?? draftText;
      final displayText = display ?? (text == draftText ? null : draftText);
      final authoredPrompt = [
        refs.join('\n'),
        text,
      ].where((v) => v.isNotEmpty).join('\n\n');
      final promptText = await _prepareReferences(
        chat,
        authoredPrompt,
        selected: ticket.references,
      );
      final uploaded = chat.composer.submittedAttachments(ticket);
      final images = <Map<String, dynamic>>[
        for (var index = 0; index < uploaded.length; index++)
          if (uploaded[index].isImage)
            {
              'path': uploaded[index].target,
              'mime': ticket.attachments[index].mediaType,
            },
      ];
      final submittedText = promptText.isEmpty && images.isNotEmpty
          ? 'What do you see in this image?'
          : promptText;
      final payload = <String, dynamic>{
        'session_id': runtime,
        'submission_id': ticket.submissionId,
        if (admittingQueue) 'queued': true,
        'text': submittedText,
        if (ticket.voiceContext != null) ...{
          'surface': 'voice-live',
          'voice_context': ticket.voiceContext,
        },
        if (resource.gateway.canonicalClarifyBatch) 'clarify_batch': true,
        if (images.isNotEmpty) 'attachments': images,
      };
      await chat.composer.prepareDispatch(ticket, payload: payload);
      if (commandPrompt != null && !commandPrompt.current) {
        throw StateError('The command continuation has changed.');
      }
      chat._replaceableUnsubmittedRuntime = false;
      if (!admittingQueue) {
        chat.reading.appendSubmittedPrompt(
          inputId: ticket.submissionId,
          text: text,
          displayText: displayText,
          attachments: chat.composer.submittedAttachments(ticket),
        );
        chat.reading.updateStreaming('');
        chat._runtime.acceptTurn();
      }
      if (chat._title == 'New chat') {
        chat._title = displayText ?? (text.isEmpty ? 'Attachment' : text);
      }
      _changed();
      _commandOwner(chat);
      if (commandPrompt != null && !commandPrompt.current) {
        throw StateError('The command continuation has changed.');
      }
      if (chat.runtime.runtimeId != runtime) {
        throw StateError('Chat reconnected before sending this prompt.');
      }
      if (resource.gateway.canonical.session(runtime) == null ||
          resource.gateway.canonical.needsSnapshot(runtime)) {
        await _refreshCanonicalPending(chat);
        _commandOwner(chat);
        if (chat.runtime.runtimeId != runtime ||
            commandPrompt != null && !commandPrompt.current) {
          throw StateError('The conversation changed before sending.');
        }
      }
      final authority = resource.gateway.canonical.session(runtime);
      if (authority == null) {
        throw StateError(
          'Reconnect to attach this conversation before sending.',
        );
      }
      final observedSequence = authority.sequence;
      submitted = true;
      final receipt = CanonicalAdmission.fromJson(
        await resource.gateway.call('prompt.submit', payload),
      );
      if (receipt.sessionId != runtime) {
        throw const FormatException(
          'Submission receipt belongs to another conversation',
        );
      }
      if (receipt.status == 'unknown') {
        throw StateError(
          'Hermes recovered an unknown outcome. Review this submission before continuing.',
        );
      }
      acknowledged = true;
      _observeVoiceAdmission(chat, receipt);
      resource.gateway.canonical.admission(
        receipt,
        inputId: ticket.submissionId,
        text: submittedText,
        observedSequence: observedSequence,
      );
      _observeCanonicalPending(chat);
      // The receipt and live pending events already establish acceptance.
      // Resuming here races those events with an older snapshot and can turn
      // successful delivery into a false local-save failure.
      await chat.composer.settle(ticket, ComposerDelivery.accepted);
    } catch (error) {
      final rejected =
          error is JsonRpcError &&
          const {
            'invalid_params',
            'permission_denied',
            'session_read_only',
            'session_superseded',
            'not_found',
            'profile_mismatch',
            'admission_conflict',
          }.contains(error.reason);
      final uncertain = submitted && !rejected;
      _observeCanonicalPending(chat);
      chat._runtime.reportError(
        acknowledged
            ? 'The message was accepted. Remaining unsent work could not be saved.'
            : uncertain
            ? 'Delivery or completion is uncertain. Reconnect to check the original submission.'
            : error.toString(),
      );
      if (!acknowledged) {
        if (uncertain) {
          chat._runtime.beginRecovery();
        } else if (!admittingQueue) {
          chat._runtime.completeTurn(
            failed: true,
            cancelled: false,
            error: chat.runtime.error,
          );
        }
      }
      if (ticket != null) {
        await chat.composer.settle(
          ticket,
          acknowledged
              ? ComposerDelivery.accepted
              : uncertain
              ? ComposerDelivery.uncertain
              : ComposerDelivery.definitelyUnsent,
          error: chat.runtime.error,
        );
      }
      if (acknowledged) await chat.composer.pause();
      if (uncertain && !acknowledged) _scheduleReconnect(resource);
    } finally {
      _changed();
    }
    await _journal();
    _changed();
    if (acknowledged && !chat.runtime.blocksTurnAdmission) {
      unawaited(_drainQueuedPrompts(chat));
    }
    return acknowledged;
  }

  Future<void> stop(ProfileChat chat) async {
    final gateway = _commandOwner(chat).gateway;
    if (chat.composer.observation.queue.isNotEmpty) await chat.composer.pause();
    _commandOwner(chat);
    await gateway.call('session.interrupt', {
      'session_id': chat.runtime.runtimeId,
    });
  }

  void _appendAcceptedSteer(ProfileChat chat, String text) {
    chat.reading.splitReplyForSteering(
      turnGeneration: chat._runtime.turnRevision,
    );
    chat._runtime.finishSegment();
    chat.reading.appendPrompt(
      text: PreparedComposerMessage.parse(text)?.message ?? text,
      steering: true,
    );
  }

  Future<bool> _steerRuntime(
    ProfileChat chat,
    String text, {
    required Iterable<ComposerReference> selected,
  }) async {
    final resource = _commandOwner(chat);
    final runtime = chat.runtime.runtimeId;
    final authority = resource.gateway.canonical.session(runtime);
    if (authority == null ||
        resource.gateway.canonical.needsSnapshot(runtime)) {
      throw StateError(
        'Reconnect to refresh the running turn before steering.',
      );
    }
    final prepared = await _prepareReferences(chat, text, selected: selected);
    final current = resource.gateway.canonical.session(runtime);
    if (!identical(_commandOwner(chat), resource) ||
        chat.runtime.runtimeId != runtime ||
        current == null ||
        current.generation != authority.generation ||
        current.authorityEpoch != authority.authorityEpoch ||
        current.replayEpoch != authority.replayEpoch ||
        resource.gateway.canonical.needsSnapshot(runtime) ||
        current.readOnlyReason != null) {
      throw StateError('The running turn changed. Review it before steering.');
    }
    final result = await resource.gateway.call('session.steer', {
      'session_id': runtime,
      'execution_generation': authority.generation,
      'text': prepared,
    });
    if (chat.runtime.runtimeId != runtime) {
      throw StateError(
        'Chat reconnected while steering. Check its history before trying again.',
      );
    }
    final status = result['status']?.toString();
    if (status == 'queued') {
      _appendAcceptedSteer(chat, text);
      _changed();
      return true;
    }
    if (status == 'rejected') return false;
    throw const FormatException('Unsupported steering response.');
  }

  Future<bool> steer(ProfileChat chat, String rawText) async {
    _commandOwner(chat);
    // Consumption belongs to the captured composer revision, including ABA edits.
    return chat.composer.steerText(
      rawText,
      (text) => _steerRuntime(
        chat,
        text,
        selected: chat.composer.observation.references,
      ),
    );
  }

  void _observeCanonicalPending(ProfileChat chat, {bool notify = true}) {
    final state = _owned(
      chat,
    ).gateway.canonical.session(chat.runtime.runtimeId);
    if (state == null) return;
    for (final receipt in state.pending) {
      _observeVoiceAdmission(chat, receipt);
    }
    chat.reading.observePendingReplyAdmissions(
      state.pending.where((row) => !row.queued).map((row) => row.id),
    );
    chat._readOnlyReason = state.readOnlyReason;
    chat.composer.observePending(state.pending, notify: notify);
  }

  Future<void> _refreshCanonicalPending(ProfileChat chat) async {
    final resource = _commandOwner(chat);
    final runtime = chat.runtime.runtimeId;
    await resource.gateway.resume(runtime);
    if (chat.runtime.runtimeId == runtime) _observeCanonicalPending(chat);
  }

  final _submissionRecoveries = <ProfileChat>{};
  Future<void> _reconcileCanonicalSubmissions(ProfileChat chat) async {
    if (!chat.composer.hasRecoverableSubmissions ||
        !_submissionRecoveries.add(chat)) {
      return;
    }
    try {
      final gateway = _commandOwner(chat).gateway;
      await chat.composer.reconcileSubmissions(
        (payload) async => CanonicalAdmission.fromJson(
          await gateway.call('prompt.submit', payload),
        ),
      );
      await _refreshCanonicalPending(chat);
    } catch (error) {
      chat._runtime.reportError(
        'Submission recovery is not confirmed. Reconnect to check the original receipt: $error',
      );
    } finally {
      _submissionRecoveries.remove(chat);
      _changed();
    }
  }

  final _canonicalRecoveries = <ProfileChat>{};
  Future<void> _recoverCanonicalSnapshot(ProfileChat chat) async {
    if (!_canonicalRecoveries.add(chat)) return;
    try {
      final resource = _owned(chat);
      final read = _captureResume(resource, chat);
      final result = await resource.gateway.resume(chat.key.sessionId);
      if (!read.current()) return;
      _hydrate(chat, result);
      await refreshHistory(chat);
    } catch (error) {
      chat._runtime.reportError(
        'Conversation updates were interrupted. Reconnect to reload: $error',
      );
    } finally {
      _canonicalRecoveries.remove(chat);
      _changed();
    }
  }

  Future<bool> _serverQueueControl(
    ProfileChat chat,
    ComposerQueueId id,
    String action,
  ) async {
    final row = chat.composer.serverAdmission(id);
    if (row == null) return false;
    if (chat.readOnlyReason != null ||
        action == 'prompt.cancel' &&
            !chat.composer.queueActions(id).canDelete) {
      throw StateError(
        'This admission can no longer be changed. Refresh the conversation.',
      );
    }
    final gateway = _commandOwner(chat).gateway;
    await chat.composer.serverQueueAction(() async {
      final response = await gateway
          .call(row.unknown ? 'prompt.resolve_unknown' : action, {
            'session_id': chat.runtime.runtimeId,
            'admission_id': row.id,
            if (row.unknown) 'execution_generation': row.generation,
          });
      if (action == 'prompt.steer_queued' && response['status'] == 'started') {
        _appendAcceptedSteer(chat, row.text);
      }
      await _refreshCanonicalPending(chat);
    });
    return true;
  }

  Future<void> queueScreenMessage(ProfileChat chat, String text) async {
    _commandOwner(chat);
    await chat.composer.enqueueExternal(text);
    unawaited(_drainQueuedPrompts(chat));
  }

  Future<void> queuePrompt(ProfileChat chat, String rawText) =>
      _enqueuePrompt(chat, rawText);

  /// Resolve prose references through stock Hermes; never execute built-ins
  /// mentioned inside a message. The submission ticket retains the exact draft.
  Future<String?> _expandInlineSkills(
    ProfileChat chat,
    String text, {
    required Set<String> excluding,
  }) async {
    if (!SlashSkillReference.hasInlineToken(text)) return null;
    final resource = _commandOwner(chat);
    final runtime = chat.runtime.runtimeId;
    void requireCaptured() {
      if (!identical(_commandOwner(chat), resource) ||
          chat.runtime.runtimeId != runtime) {
        throw StateError('Chat reconnected while loading skills.');
      }
    }

    final catalog = await commandCatalog(chat);
    requireCaptured();
    final references = catalog.skillReferences(text).where((r) => r.start > 0);
    final names = references
        .map((r) => r.text)
        .where((name) => !excluding.contains(name))
        .toSet();
    if (names.isEmpty) return null;
    final messages = <String>[];
    for (final name in names) {
      final result = await resource.gateway.call('command.dispatch', {
        'session_id': runtime,
        'name': name.substring(1),
        'arg': text,
      });
      requireCaptured();
      final message = result['message'];
      if (result['type'] != 'skill' || message is! String || message.isEmpty) {
        throw StateError('Could not load $name. Your message is kept.');
      }
      messages.add(message);
    }
    return messages.join('\n\n');
  }

  Future<void> _enqueuePrompt(
    ProfileChat chat,
    String rawText, {
    bool fromSend = false,
  }) async {
    _commandOwner(chat);
    if (chat._replacingExpiredRuntime) {
      throw StateError('Another queued message is still being saved.');
    }
    try {
      await chat.composer.enqueue(rawText, fromSend: fromSend);
    } finally {
      await _drainQueuedPrompts(chat);
    }
  }

  Future<void> beginQueuedPromptEdit(
    ProfileChat chat,
    ComposerQueueId prompt,
  ) async {
    _commandOwner(chat);
    await chat.composer.beginEdit(prompt);
  }

  void updateQueuedPromptEdit(
    ProfileChat chat,
    String text, {
    ComposerReference? reference,
  }) {
    _commandOwner(chat);
    chat.composer.editQueuedText(text, reference: reference);
  }

  Future<void> cancelQueuedPromptEdit(ProfileChat chat) async {
    _commandOwner(chat);
    await chat.composer.cancelEdit();
    await _drainQueuedPrompts(chat);
  }

  Future<void> saveQueuedPromptEdit(ProfileChat chat) async {
    _commandOwner(chat);
    final editing = chat.composer.observation.editing;
    final row = editing == null ? null : chat.composer.serverAdmission(editing);
    if (row != null) {
      final text = chat.composer.observation.editText.trim();
      await chat.composer.serverQueueAction(() async {
        final prepared = await _prepareReferences(
          chat,
          text,
          selected: chat.composer.observation.references,
        );
        final submission = const Uuid().v4();
        final voiceContext = _prepareVoiceReplacement(chat, row.id, submission);
        final receipt = CanonicalAdmission.fromJson(
          await _commandOwner(chat).gateway.call('prompt.replace_queued', {
            'session_id': chat.runtime.runtimeId,
            'admission_id': row.id,
            'submission_id': submission,
            'text': prepared,
            if (voiceContext != null) ...{
              'surface': 'voice-live',
              'voice_context': voiceContext,
            },
          }),
        );
        _observeVoiceAdmission(chat, receipt);
        await _refreshCanonicalPending(chat);
      });
      await chat.composer.cancelEdit();
    } else {
      await chat.composer.saveEdit();
      await _drainQueuedPrompts(chat);
    }
  }

  Future<bool> steerQueuedPromptEdit(ProfileChat chat) async {
    _commandOwner(chat);
    final editing = chat.composer.observation.editing;
    if (editing != null && chat.composer.serverAdmission(editing) != null) {
      if (!chat.composer.queueActions(editing).canSteer) return false;
      return _serverQueueControl(chat, editing, 'prompt.steer_queued');
    }
    final accepted = await chat.composer.steerEdit(
      (text, references) => _steerRuntime(chat, text, selected: references),
    );
    await _drainQueuedPrompts(chat);
    return accepted;
  }

  Future<bool> steerQueuedPrompt(ProfileChat chat, ComposerQueueId id) async {
    _commandOwner(chat);
    if (chat.composer.serverAdmission(id) != null) {
      if (!chat.composer.queueActions(id).canSteer) return false;
      return _serverQueueControl(chat, id, 'prompt.steer_queued');
    }
    final accepted = await chat.composer.steerQueued(
      id,
      (text, references) => _steerRuntime(chat, text, selected: references),
    );
    await _drainQueuedPrompts(chat);
    return accepted;
  }

  Future<void> removeQueuedPrompt(
    ProfileChat chat,
    ComposerQueueId prompt,
  ) async {
    _commandOwner(chat);
    if (await _serverQueueControl(chat, prompt, 'prompt.cancel')) return;
    await chat.composer.removeQueued(prompt);
    await _drainQueuedPrompts(chat);
  }

  Future<void> resumeQueue(ProfileChat chat) async {
    final resource = _commandOwner(chat);
    if (chat._replacingExpiredRuntime) return;
    await chat.composer.resume(() async {
      final read = _captureResume(resource, chat);
      final response = await resource.gateway.resume(chat._key.sessionId);
      if (!read.owned()) return false;
      final applied = read.current();
      if (applied) _hydrate(chat, response);
      final continuation = _captureResume(resource, chat, startRead: false);
      await refreshHistory(chat);
      if (!continuation.current()) return false;
      if (applied) chat._runtime.resetCompleted();
      return true;
    });
    await _drainQueuedPrompts(chat);
  }

  Future<void> _drainQueuedPrompts(ProfileChat chat) {
    final resource = _resources[chat._key.workspace];
    if (_closed ||
        resource == null ||
        !identical(resource._chats[chat._key.sessionId], chat) ||
        resource.blocksSession(chat._key.sessionId) ||
        _deletedDrafts.blocks(
          chat._key.workspace.profileName,
          chat._key.sessionId,
        ) ||
        chat._replacingExpiredRuntime) {
      return Future.value();
    }
    return chat.composer.drain(
      (prompt) =>
          _sendPrompt(chat, preserveComposer: true, queuedPrompt: prompt),
    );
  }

  void _requireNativePromptAuthority(
    ProfileGateway gateway,
    String runtime,
    int? generation,
  ) {
    final current = gateway.canonical.session(runtime);
    if (generation == null ||
        current?.generation != generation ||
        gateway.canonical.needsSnapshot(runtime)) {
      throw StateError(
        'Refresh the conversation to review this request before answering.',
      );
    }
  }

  void _receiveNativePrompt(ProfileChat chat, Map<String, dynamic> prompt) {
    final state = _owned(
      chat,
    ).gateway.canonical.session(chat.runtime.runtimeId);
    if (state == null || prompt['execution_generation'] != state.generation) {
      return;
    }
    if (!chat._runtime.receiveNativePrompt(prompt)) return;
    if (prompt['kind'] == 'approval') {
      final request = chat.runtime.approvals
          .where(
            (row) =>
                row.requestId == prompt['prompt_id'] &&
                row.nativeGeneration == state.generation,
          )
          .firstOrNull;
      if (request != null) _notifyApproval(chat, request);
    } else {
      _notify(
        chat,
        ChatNotificationContent.input(
          chat.runtime.pendingQuestion?.question ?? '',
        ),
      );
    }
  }

  void _receiveApproval(
    ProfileChat chat,
    Map<String, dynamic> request, {
    bool notify = true,
  }) {
    final added = chat._runtime.receiveApproval(request);
    if (added && notify) {
      final issued = chat.runtime.approvals
          .where((a) => a.requestId == request['request_id'])
          .firstOrNull;
      if (issued != null) _notifyApproval(chat, issued);
    }
  }

  void _notifyApproval(ProfileChat chat, ChatApproval request) => _notify(
    chat,
    ChatNotificationContent.input(request.request.description),
    eventId: request.eventId,
  );

  Future<void> _refreshApprovals(
    ProfileChat chat, {
    bool notifyNew = true,
  }) async {
    final capture = chat._runtime.captureApprovalRead();
    final runtime = capture.runtimeId;
    final previousIds = chat.runtime.approvals.map((r) => r.requestId).toSet();
    try {
      final gateway = _owned(chat).gateway;
      final authority = gateway.canonical.session(runtime);
      if (authority == null || gateway.canonical.needsSnapshot(runtime)) return;
      final result = await gateway.call('approval.pending', {
        'session_id': runtime,
      });
      final current = gateway.canonical.session(runtime);
      if (_closed ||
          current?.generation != authority.generation ||
          current?.authorityEpoch != authority.authorityEpoch ||
          gateway.canonical.needsSnapshot(runtime) ||
          result['approvals'] is! List ||
          !chat._runtime.reconcileNativeApprovals(
            capture,
            ProfileGateway.records(result['approvals']),
            authority.generation,
          )) {
        return;
      }
      final issued = chat.runtime.approvals;
      for (final request in issued) {
        if (notifyNew && !previousIds.contains(request.requestId)) {
          _notifyApproval(chat, request);
        }
      }
      _changed();
      for (final request in issued) {
        if (_closed || runtime != chat.runtime.runtimeId) return;
        if (request.nativeGeneration == null) continue;
        await gateway.call('approval.received', {
          'session_id': runtime,
          'request_id': request.requestId,
        });
      }
    } catch (_) {
      // Failure preserves requests; reconnect reads, never repeats a decision.
    }
  }

  /// Load the current request for a notification action without opening a chat.
  Future<ProfileChat?> loadNotificationApproval(ProfileSessionKey key) =>
      _retainWorkspaceOperation(() async {
        if (!owns(key) || _closed) return null;
        final owner = _resource(key.workspace.profileName);
        if (owner.blocksSession(key.sessionId)) return null;
        final existing = owner._chats[key.sessionId];
        if (existing != null && !existing.runtime.offline) {
          if (existing.runtime.approval == null) {
            await _refreshApprovals(existing, notifyNew: false);
          }
          return existing;
        }
        final read = existing == null ? null : _captureResume(owner, existing);
        await owner.gateway.connect();
        final resumed = await owner.gateway.resume(key.sessionId);
        final title = await _pendingChatTitle(owner, key.sessionId);
        if (_closed || owner.blocksSession(key.sessionId)) {
          return null;
        }
        if (owner._chats[key.sessionId] case final concurrent?
            when !identical(concurrent, existing)) {
          return concurrent;
        }
        if (read != null && !read.owned()) return null;
        if (read != null && !read.current()) return existing;
        if (owner.gateway.resumeDurableId(resumed) != key.sessionId) {
          return null;
        }
        final chat =
            existing ??
            _createChatRecord(
              key: key,
              runtimeId: resumed['session_id'] as String,
              title: title,
            );
        chat._runtime.recovered();
        owner._chats[key.sessionId] = chat;
        _hydrate(chat, resumed);
        await _refreshApprovals(chat, notifyNew: false);
        await _journal();
        _changed();
        return chat;
      });

  /// An explicit notification tap owns one bounded recovery attempt. The choice
  /// is never queued for replay, and approval rechecks its exact request after
  /// recovery (which may have discovered a resolved or replaced request).
  Future<void> approveNotification(
    ProfileChat chat,
    String choice, {
    required String requestId,
    required String command,
  }) async {
    final runtime = chat.runtime.runtimeId;
    final resource = _commandOwner(chat);
    try {
      if (resource._recovering ||
          resource._reconnectError != null ||
          chat.runtime.offline ||
          chat.runtime.reconnecting) {
        await reconnect(
          chat._key.workspace,
        ).timeout(const Duration(seconds: 15));
      }
      if (_closed ||
          resource._recovering ||
          resource._reconnectError != null ||
          chat.runtime.runtimeId != runtime ||
          chat.runtime.opening ||
          chat.runtime.offline ||
          chat.runtime.reconnecting) {
        throw StateError('Reconnect to review this approval.');
      }
      if (choice != 'deny' &&
          chat.runtime.approval != null &&
          chat.runtime.approval!.request.command.trim() != command) {
        throw StateError('Command changed. Review the current request.');
      }
      await approve(chat, choice, requestId: requestId);
    } catch (_) {
      if (!_closed && chat.runtime.approval?.requestId == requestId) {
        chat._runtime.reportDecisionError(
          requestId,
          'Decision not confirmed · review or retry',
        );
        _changed();
      }
      rethrow;
    }
  }

  Future<void> approve(
    ProfileChat chat,
    String choice, {
    required String requestId,
  }) async {
    final gateway = _commandOwner(chat).gateway;
    final request = chat.runtime.approval;
    final capture = chat._runtime.beginApprovalAnswer(requestId, choice);
    _changed();
    var accepted = false;
    String? decisionError;
    try {
      _commandOwner(chat);
      final generation = request!.nativeGeneration;
      if (request.serverRequestId == null) {
        _requireNativePromptAuthority(gateway, capture.runtimeId, generation);
      }
      final response = request.serverRequestId != null
          ? await gateway.call('request.answer', {
              'id': request.serverRequestId,
              'result': {'choice': choice},
            })
          : await gateway.call('approval.respond', {
              'session_id': capture.runtimeId,
              'choice': choice,
              'prompt_id': requestId,
              'execution_generation': generation,
            });
      if (request.serverRequestId == null &&
          response['prompt_id'] == requestId &&
          response['status'] == 'already_resolved') {
        chat._runtime.settleNativePrompt('approval', requestId, generation!);
        await _refreshApprovals(chat);
        return;
      }
      accepted = request.serverRequestId != null
          ? response['status'] == 'ok'
          : response['prompt_id'] == requestId &&
                response['status'] == 'resolved';
      if (!accepted) throw StateError('This approval is no longer pending.');
      chat._runtime.finishApprovalAnswer(capture, requestId, accepted: true);
      await _refreshApprovals(chat);
      final next = chat.runtime.approval;
      if (next != null) {
        chat.reading.revealNotification(
          NotificationFocus('approval', next.requestId),
        );
      }
    } catch (_) {
      decisionError = 'Decision not confirmed · review or retry';
      unawaited(_refreshApprovals(chat));
      rethrow;
    } finally {
      chat._runtime.finishApprovalAnswer(
        capture,
        requestId,
        accepted: accepted,
        error: decisionError,
      );
      _changed();
    }
  }

  Future<void> skipClarification(
    ProfileChat chat,
    ChatQuestions expected,
  ) async {
    if (chat._answeringQuestion) return;
    final resource = _commandOwner(chat);
    final question = chat.runtime.pendingQuestion;
    final capture = chat._runtime.beginQuestionAnswer(expected);
    if (capture == null || question == null) return;
    chat._answeringQuestion = true;
    _changed();
    try {
      if (expected.nativeGeneration != null || question.questionId == null) {
        await _clarify(chat, '', expectedRequest: expected);
      } else {
        final result = await resource.gateway.call('request.answer', {
          'id': question.requestId,
          'result': <String, dynamic>{},
        });
        if (result['status'] == 'expired') {
          await _expireClarification(
            chat,
            resource,
            question.requestId,
            capture,
          );
          return;
        }
        if (capture.runtimeId == chat.runtime.runtimeId &&
            chat.runtime.pendingQuestion?.requestId == question.requestId) {
          chat._runtime.cancelQuestion(question.requestId);
        }
      }
    } finally {
      chat._answeringQuestion = false;
      _changed();
    }
  }

  /// Locks the reviewed set sequentially: the final lock completes the waiter.
  /// A partial failure leaves confirmed locks in runtime and unsent form drafts.
  Future<void> clarifySet(
    ProfileChat chat,
    Map<String, String?> answers, {
    required ChatQuestions expectedRequest,
  }) async {
    if (chat._answeringQuestion) return;
    final runtime = chat.runtime.runtimeId;
    final requestId = expectedRequest.pending?.requestId;
    if (requestId == null ||
        chat.runtime.questions?.pending?.requestId != requestId) {
      throw StateError(
        'This clarification has changed. Review the current request.',
      );
    }
    chat._answeringQuestion = true;
    _changed();
    try {
      while (chat.runtime.runtimeId == runtime) {
        final current = chat.runtime.questions;
        final pending = current?.pending;
        if (current == null ||
            pending == null ||
            pending.requestId != requestId) {
          return;
        }
        final id = pending.questionId ?? pending.requestId;
        if (!answers.containsKey(id)) return;
        if (!await _clarify(chat, answers[id], expectedRequest: current)) {
          return;
        }
      }
    } finally {
      chat._answeringQuestion = false;
      _changed();
    }
  }

  Future<void> clarify(
    ProfileChat chat,
    String answer, {
    ChatQuestions? expectedRequest,
  }) async {
    if (chat._answeringQuestion) return;
    chat._answeringQuestion = true;
    _changed();
    try {
      await _clarify(chat, answer, expectedRequest: expectedRequest);
    } finally {
      chat._answeringQuestion = false;
      _changed();
    }
  }

  bool canAnswerWithComposer(ProfileChat chat) {
    final work = chat.composer.observation;
    return chat.runtime.pendingQuestion != null &&
        !chat.answeringQuestion &&
        !chat.runtime.offline &&
        !chat.runtime.reconnecting &&
        !switching &&
        !work.saving &&
        !work.sending &&
        !work.preparing &&
        work.editing == null &&
        work.attachments.isEmpty &&
        work.references.isEmpty &&
        work.text.trim().isNotEmpty &&
        !work.text.trimLeft().startsWith('/');
  }

  Future<void> answerWithComposer(ProfileChat chat) async {
    _commandOwner(chat);
    if (!canAnswerWithComposer(chat)) return;
    final work = chat.composer.observation;
    final question = chat.runtime.questions!;
    chat._answeringQuestion = true;
    _changed();
    try {
      if (await _clarify(chat, work.text.trim(), expectedRequest: question)) {
        await chat.composer.finishCommand(work.revision);
      }
    } finally {
      chat._answeringQuestion = false;
      _changed();
    }
  }

  Future<void> _expireClarification(
    ProfileChat chat,
    ProfileWorkspaceData resource,
    String requestId,
    execution.ChatRuntimeAnswer capture,
  ) async {
    if (capture.runtimeId != chat.runtime.runtimeId ||
        chat.runtime.pendingQuestion?.requestId != requestId) {
      return;
    }
    chat._runtime.closeQuestion(requestId);
    _changed();
    await reconnect(resource.scope);
    chat._runtime.reportQuestionExpiry(capture);
  }

  Future<bool> _clarify(
    ProfileChat chat,
    String? answer, {
    ChatQuestions? expectedRequest,
  }) async {
    final resource = _commandOwner(chat);
    final nativeGeneration = chat.runtime.questions?.nativeGeneration;
    final question = chat.runtime.pendingQuestion;
    final capture = chat._runtime.beginQuestionAnswer(expectedRequest);
    if (capture == null || question == null) return false;
    if (nativeGeneration != null) {
      _requireNativePromptAuthority(
        resource.gateway,
        capture.runtimeId,
        nativeGeneration,
      );
      final result = await resource.gateway.call('clarify.respond', {
        'session_id': capture.runtimeId,
        'execution_generation': nativeGeneration,
        'prompt_id': question.requestId,
        'answer': answer ?? '',
      });
      if (result['prompt_id'] != question.requestId ||
          !{'resolved', 'already_resolved'}.contains(result['status'])) {
        throw StateError('The clarification response was not confirmed.');
      }
      if (capture.runtimeId != chat.runtime.runtimeId) return false;
      if (result['status'] == 'already_resolved') {
        chat._runtime.settleNativePrompt(
          'clarify',
          question.requestId,
          nativeGeneration,
        );
        _changed();
        return false;
      }
      chat._runtime.finishQuestionAnswer(
        capture,
        answer: answer ?? '',
        remaining: null,
      );
      _changed();
      return true;
    }
    final batch = question.questionId != null;
    _commandOwner(chat);
    final result = await resource.gateway.call(
      batch ? 'clarify.lock' : 'request.answer',
      batch
          ? {
              'request_id': question.requestId,
              'answer': answer,
              'question_id': question.questionId,
            }
          : {
              'id': question.requestId,
              'result': {'answer': answer ?? ''},
            },
    );
    if (result['status'] == 'expired') {
      // This receipt closes the whole request, even if another surface has
      // advanced its batch. It cannot close a different request or runtime.
      await _expireClarification(chat, resource, question.requestId, capture);
    } else {
      if (!capture.current) return false;
      chat._runtime.finishQuestionAnswer(
        capture,
        answer: answer ?? '',
        remaining: result['remaining'] is List
            ? (result['remaining'] as List).whereType<String>().toList()
            : null,
      );
    }
    _changed();
    return result['status'] != 'expired';
  }

  Future<void> respondSensitivePrompt(
    ProfileChat chat,
    String value, {
    required GatewaySensitivePromptRequest expectedRequest,
  }) async {
    final resource = _commandOwner(chat);
    final capture = chat._runtime.beginSecureAnswer(expectedRequest);
    final responseValue = expectedRequest.normalizeResponseValue(value);
    _changed();
    var accepted = false;
    try {
      _commandOwner(chat);
      await resource.gateway.respondToRequest(expectedRequest.requestId, {
        'value': responseValue,
      });
      accepted = true;
    } finally {
      chat._runtime.finishSecureAnswer(capture, accepted: accepted);
      _changed();
    }
  }

  void _applyTodoSnapshot(
    ProfileChat chat,
    dynamic value, {
    bool live = false,
  }) {
    final snapshot = GatewayTodoSnapshot.parse(value);
    if (snapshot == null) return;
    chat._taskState.observe(
      snapshot,
      liveTurn: live && chat.runtime.executionActive
          ? chat._runtime.turnRevision
          : null,
    );
  }

  void _upsertSubagent(
    ProfileChat chat,
    String eventType,
    Map<String, dynamic> data,
  ) {
    final update = GatewaySubagentActivity.fromGatewayEvent(eventType, data);
    if (update == null) return;
    final next = List<GatewaySubagentActivity>.from(chat._subagents);
    final index = next.indexWhere((item) => item.id == update.id);
    if (index < 0) {
      next.add(update);
    } else {
      next[index] = next[index].merge(update);
    }
    chat._subagents = next;
    if (update.isTerminal) {
      chat._subagentCompletionTurns.putIfAbsent(
        update.id,
        () => chat._runtime.turnRevision,
      );
    }
    chat._unconfirmedSubagentIds.remove(update.id);
    chat._subagentsRevision++;
    chat._subagentsError = null;
  }

  void _event(ProfileWorkspaceData resource, StreamEvent event) {
    if (_closed) return;
    if (event.type == 'sessions.changed') {
      if (onAttention != null) unawaited(_groupNotifications.refresh());
      _invalidateProjectMembership(resource);
      unawaited(_scheduleNotificationReconciliation(resource));
      return;
    }
    final chat = resource._chats.values
        .where((c) => c.runtime.runtimeId == event.sessionId)
        .firstOrNull;
    if (chat == null || resource.blocksSession(chat._key.sessionId)) return;
    if (!resource.gateway.canonical.event(event)) {
      if (resource.gateway.canonical.needsSnapshot(chat.runtime.runtimeId)) {
        unawaited(_recoverCanonicalSnapshot(chat));
      }
      return;
    }
    // Only facts a resume snapshot can replace invalidate its read. Independent
    // usage/control/review observations must not hold execution in recovery.
    if (event.data['turn_id'] is String) {
      chat.reading.observeReplyAdmission(
        event.envelope['admission_id'],
        turn: event.data['turn_id'],
      );
    }
    final compactingBefore = chat.runtime.compacting;
    chat._runtime.observeEvent(event.type, event.data);
    final activityBefore = chat.runtime.mainActivity;
    final statusBefore = chat.runtime.execution;
    final completionEvent =
        CompletionDiagnostics.enabled &&
        (event.type == 'message.complete' || event.type == 'turn.end');
    final completionWasBusy =
        completionEvent && chat.runtime.blocksTurnAdmission;
    final completionStarted = CompletionDiagnostics.enabled && completionEvent
        ? CompletionDiagnostics.start()
        : 0;
    switch (event.type) {
      case 'connection.request':
        _observeConnectionOperation(chat, event.data);
      case 'connection.update':
        _observeConnectionOperation(chat, event.data, update: true);
      case 'session.updated':
        if (event.data['status'] == 'confirmation_required') {
          chat._runtime.reportError(
            'The next-turn model needs confirmation. Open Models to review the pending choice.',
          );
        }
        if (event.data['status'] == 'refused') {
          chat._pendingIntelligence = null;
          chat._runtime.reportError(
            'The next-turn model choice could not be applied: ${event.data['reason'] ?? 'choose another model'}.',
          );
        }
        _hydrateIntelligence(chat, {
          'info': {
            ...event.data,
            if (event.data.containsKey('effort'))
              'reasoning_effort': event.data['effort'],
          },
        });
        unawaited(_observeModelControls(chat));
      case 'session.title':
        if (event.data['session_id'] == chat._key.sessionId) {
          _hydrateTitle(chat, event.data['title']);
        }
      case 'session.info':
        _observeCanonicalPending(chat);
        _observeReferenceWorkspace(chat, event.data);
        _hydrateIntelligence(chat, {'info': event.data});
        if (event.data.containsKey('side_tasks')) {
          _hydrateSideTasks(chat, event.data['side_tasks']);
        }
        if (event.data.containsKey('prompts')) {
          final generation = _owned(
            chat,
          ).gateway.canonical.session(chat.runtime.runtimeId)?.generation;
          if (generation != null) {
            chat._runtime.reconcileNativePrompts(
              event.data['prompts'],
              generation,
            );
          }
        }
        if (event.data.containsKey('open_requests')) {
          chat._runtime.reconcileOpenRequests(event.data['open_requests']);
          chat._runtime.observeExecutionSnapshot(event.data);
        }
        if (event.data['usage'] is Map) {
          _updateContext(chat, event.data['usage'] as Map);
        }
        // Cold resume can answer before the agent exists. Its ready event may
        // still have no measured usage; fetch the server's history estimate.
        if (event.data['lazy'] != true) {
          unawaited(refreshContext(chat));
        }
        if (!chat._sessionControlReadAttempted) {
          unawaited(refreshSessionControl(chat));
        }
      case 'session.control.update':
        final snapshot = SessionControlSnapshot.parse(event.data['control']);
        if (snapshot != null) {
          chat._sessionControl = snapshot;
          chat._sessionControlEventRevision++;
          chat._sessionControlReadAttempted = true;
          chat._sessionControlError = null;
        }
      case 'session.usage':
        _updateContext(chat, {
          if (event.data['usage'] is Map)
            ...Map<String, dynamic>.from(event.data['usage'] as Map),
          ...event.data,
        });
      case 'message.start':
        final admissionId = event.envelope['admission_id'];
        final pending = resource.gateway.canonical
            .session(chat.runtime.runtimeId)
            ?.pending
            .where((row) => row.id == admissionId && row.queued)
            .firstOrNull;
        if (pending != null && pending.text.isNotEmpty) {
          chat.reading.appendSubmittedPrompt(
            inputId: pending.inputId,
            text: pending.text,
            displayKind: event.data['display_kind'] is String
                ? event.data['display_kind'] as String
                : null,
            displayMetadata: event.data['display_text'] is String
                ? {'display_text': event.data['display_text']}
                : null,
          );
        }
        applyChatTranscriptEvent(
          runtime: chat._runtime,
          reading: chat.reading,
          type: event.type,
          data: event.data,
        );
      case 'message.delta':
      case 'message.interim':
      case 'tool.generating':
      case 'tool.start':
      case 'tool.progress':
      case 'tool.complete':
        if (event.type == 'tool.complete' &&
            const {
              'terminal',
              'process',
              'process_manage',
            }.contains(event.data['name'])) {
          _processToolSettled(chat);
        }
        applyChatTranscriptEvent(
          runtime: chat._runtime,
          reading: chat.reading,
          type: event.type,
          data: event.data,
        );
      case 'todo.updated':
        _applyTodoSnapshot(chat, event.data, live: true);
      case 'subagent.spawn_requested':
      case 'subagent.start':
      case 'subagent.thinking':
      case 'subagent.tool':
      case 'subagent.progress':
      case 'subagent.complete':
        _upsertSubagent(chat, event.type, event.data);
      case 'reasoning.delta':
      case 'reasoning.available':
        applyChatTranscriptEvent(
          runtime: chat._runtime,
          reading: chat.reading,
          type: event.type,
          data: event.data,
        );
      case 'review.summary':
        final sequence = event.envelope['seq'];
        final notice = event.data['text'] is String
            ? GatewayNotice.fromGatewayEvent(event.type, event.data)
            : null;
        final identity = '${chat.runtime.runtimeId}:$sequence';
        if (notice != null &&
            sequence is int &&
            sequence > 0 &&
            !chat._reviewNotices.any(
              (existing) => existing.identity == identity,
            )) {
          chat._reviewNotices.add((notice: notice, identity: identity));
          chat.reading.appendReviewNotice(
            identity: identity,
            text: 'review:${notice.text}',
            timestamp: event.data['timestamp'] is num
                ? event.data['timestamp'] as num
                : null,
          );
          if (chat._reviewNotices.length > _maxReviewNotices) {
            final removed = chat._reviewNotices.removeAt(0);
            chat.reading.retireReviewNotice(removed.identity);
          }
        }
      case 'btw.complete':
        _completeTaskDelivery(
          chat,
          SideQuestionDeliveryKind.sideQuestion,
          event.data,
          skipBlankResult: true,
        );
      case 'background.complete':
        _completeTaskDelivery(
          chat,
          SideQuestionDeliveryKind.backgroundTask,
          event.data,
        );
      case 'approval.request':
      case 'clarify.request':
        _receiveNativePrompt(chat, event.data);
      case 'approval.settled':
      case 'clarify.settled':
        final promptId = event.data['prompt_id'];
        final generation = event.data['execution_generation'];
        if (promptId is String && generation is int) {
          chat._runtime.settleNativePrompt(
            event.type.split('.').first,
            promptId,
            generation,
          );
        }
      case 'approval':
        _receiveApproval(chat, event.data);
        unawaited(_refreshApprovals(chat));
      case 'clarify':
        chat._runtime.receiveQuestions(event.data);
        _notify(
          chat,
          ChatNotificationContent.input(
            chat.runtime.pendingQuestion?.question ?? '',
          ),
          eventId: _notificationEventId(event.data),
        );
      case 'request.cancel':
        chat._runtime.cancelRequest(event.data);
      case 'sudo':
      case 'secret':
      case 'vault.unlock_prompt':
      case 'vault.save_login':
      case 'vault.code':
        final request = GatewaySensitivePromptRequest.fromEventData(
          kind: switch (event.type) {
            'sudo' => GatewaySensitivePromptKind.sudo,
            'secret' => GatewaySensitivePromptKind.secret,
            'vault.unlock_prompt' => GatewaySensitivePromptKind.vaultUnlock,
            'vault.save_login' => GatewaySensitivePromptKind.vaultSaveLogin,
            _ => GatewaySensitivePromptKind.vaultCode,
          },
          data: event.data,
        );
        if (request != null) {
          chat._runtime.receiveSecure(request);
          _notify(
            chat,
            ChatNotificationContent.secureInput,
            eventId: _notificationEventId(event.data),
          );
        }
      case 'message.complete':
      case 'turn.end':
        chat.reading.observeVoiceCompletion(event.data);
        final completionText = chat.reading.completionText(event.data);
        for (final voice
            in _liveVoiceChats[chat] ??
                const <_WorkspaceLiveVoiceConversation>{}) {
          voice.observeCompletion(
            event.envelope['admission_id'],
            completionText,
          );
        }
        if (chat.runtime.blocksTurnAdmission) {
          unawaited(
            _settle(resource, chat, event.data).catchError((Object e) {
              chat._runtime.reportError(e.toString());
              _changed();
            }),
          );
        }
      case 'error':
      case 'turn.error':
        chat.reading.retireReply();
        chat._runtime.failTurn(
          event.data['message']?.toString() ?? 'Turn failed',
        );
        _notify(
          chat,
          ChatNotificationContent.failed,
          eventId: _notificationEventId(event.data),
        );
        unawaited(_journal().catchError((Object _) {}));
    }
    if (event.type == 'message.delta' || event.type == 'reasoning.delta') {
      _streamChanged(
        chat,
        immediate:
            chat.runtime.compacting != compactingBefore ||
            chat.runtime.mainActivity != activityBefore ||
            chat.runtime.execution != statusBefore,
      );
    } else {
      _changed(browserChat: chat._key);
    }
    if (CompletionDiagnostics.enabled && completionEvent) {
      CompletionDiagnostics.finish(
        event.type == 'message.complete'
            ? 'controller.message_complete_sync'
            : 'controller.turn_end_sync',
        completionStarted,
        values: {'wasBusy': completionWasBusy ? 1 : 0},
      );
    }
  }

  Future<void> _settle(
    ProfileWorkspaceData resource,
    ProfileChat chat,
    Map<String, dynamic> completion,
  ) async {
    _pendingCompletions++;
    final privateWorker = chat.source == 'bot_room';
    if (privateWorker) _pendingPrivateCompletions++;
    try {
      await _settleTurn(resource, chat, completion);
    } finally {
      _pendingCompletions--;
      if (privateWorker) _pendingPrivateCompletions--;
      _changed(browserChat: chat._key);
    }
  }

  Future<void> _settleTurn(
    ProfileWorkspaceData resource,
    ProfileChat chat,
    Map<String, dynamic> completion,
  ) async {
    final handoffStarted = CompletionDiagnostics.enabled
        ? CompletionDiagnostics.start()
        : 0;
    final turnGeneration = chat._runtime.turnRevision;
    bool isCurrentTurn() => chat._runtime.turnRevision == turnGeneration;
    final failed = completion['status'] == 'error';
    final cancelled = completion['status'] == 'interrupted';
    final turnFailure = TurnFailure.fromCompletion(completion);
    final failure = failed ? turnFailure?.message ?? 'Turn failed' : null;
    chat._runtime.completeTurn(
      failed: failed,
      cancelled: cancelled,
      error: failure,
      failure: turnFailure,
    );
    if ((failed || cancelled) && chat.composer.observation.queue.isNotEmpty) {
      chat.composer.recordRuntimeFailure();
    }
    final finalText = chat.reading.completionText(completion);
    final excerptStarted = CompletionDiagnostics.enabled
        ? CompletionDiagnostics.start()
        : 0;
    final notificationContent = failed
        ? turnFailure == null
              ? ChatNotificationContent.failed
              : ChatNotificationContent.failure(turnFailure)
        : cancelled
        ? ChatNotificationContent.stopped
        : ChatNotificationContent.reply(finalText);
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.finish(
        'controller.notification_content_sync',
        excerptStarted,
        values: {'reply': !failed && !cancelled ? 1 : 0},
      );
    }
    final notification = _notification(
      chat,
      notificationContent,
      eventId: _notificationEventId(completion),
      focus: NotificationFocus(
        failed || cancelled || finalText.trim().isEmpty ? 'status' : 'answer',
        _notificationEventId(completion) ??
            '${chat.runtime.runtimeId}:${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    if (finalText.isNotEmpty) {
      chat.reading.appendAssistant(
        finalText,
        turnGeneration: chat._runtime.turnRevision,
        reasoning: completion['reasoning'] is String
            ? completion['reasoning'] as String
            : '',
        persistedTurn: completion['persisted_turn'],
        responsePreviewed: completion['response_previewed'] == true,
        responseTransformed: completion['response_transformed'] == true,
        responseReused:
            !failed && !cancelled && completion['response_reused'] == true,
      );
    }
    chat.reading.retireReply();
    chat.reading.updateStreaming('');
    // The received result is authoritative before optional history/list/project
    // enrichment. Publish it now so a held read cannot delay another chat's cue.
    if (!failed &&
        !cancelled &&
        finalText.trim().isNotEmpty &&
        SessionVisibility.chats.includes(chat.source) &&
        chat.reading.messages.isNotEmpty &&
        _recentUnreadAnswer([chat.reading.messages.last], null) == true) {
      // The first answer may have no saved-message observation yet. Refine the
      // existing scoped row cache from this received fact before enrichment.
      final before =
          _recentSessionRows[chat.key] ??
          resource._sessions
              .where((row) => row['id'] == chat.key.sessionId)
              .firstOrNull;
      _recentSessionRows[chat.key] = {
        ...?before,
        'id': chat.key.sessionId,
        'unread': true,
      };
    }
    if (failed ||
        cancelled ||
        chat.composer.observation.queue.isEmpty ||
        chat.composer.observation.paused) {
      _deliverNotification(chat, notification);
    }
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.finish(
        'controller.completion_handoff_sync',
        handoffStarted,
        values: {'rows': chat.reading.messages.length},
      );
    }
    final historyStarted = CompletionDiagnostics.enabled
        ? CompletionDiagnostics.start()
        : 0;
    try {
      await refreshHistory(chat);
      if (CompletionDiagnostics.enabled) {
        CompletionDiagnostics.finish(
          'controller.completion_history_wall',
          historyStarted,
        );
      }
      if (!isCurrentTurn()) return;
      if (chat.reading.historyError != null) {
        throw StateError('History refresh failed');
      }
      chat._runtime.finishActivity();
      if (!switching) await _refreshSessions(resource);
      if (!isCurrentTurn()) return;
      try {
        resource._projects = _readonlyWorkspaceRows(
          await resource.gateway.projects(),
        );
        if (!isCurrentTurn()) return;
        final selectedId = resource._selectedProject?['id'];
        if (selectedId != null) {
          resource._selectedProject = _readonlyOptionalWorkspaceRow(
            resource._projects
                    .where((project) => project['id'] == selectedId)
                    .firstOrNull ??
                resource._selectedProject,
          );
        }
        resource._projectsError = null;
      } catch (_) {
        resource._projectsError =
            'Projects could not be refreshed. Retry to reload.';
      }
      final project = resource._selectedProject;
      if (project != null) await _loadProject(resource, project);
      if (!isCurrentTurn()) return;
    } catch (_) {
      if (!isCurrentTurn()) return;
      chat._runtime.reportError(
        failure ??
            'Turn finished. History refresh failed; reconnect to reload.',
      );
    }
    if ((failed || cancelled) && chat.composer.observation.queue.isNotEmpty) {
      await chat.composer.saveWork();
    }
    await _journal();
    if (!isCurrentTurn()) return;
    if (!failed && !cancelled) {
      unawaited(_drainQueuedPrompts(chat));
    }
    _changed();
  }

  String? _notificationEventId(Map<String, dynamic> data) {
    final value = data['mobile_push_event_id'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  ProfileNotification _notification(
    ProfileChat chat,
    ChatNotificationContent content, {
    String? eventId,
    NotificationFocus? focus,
  }) => ProfileNotification(
    key: chat._key,
    title: chat._title,
    connectionLabel: connection.label,
    content: content,
    eventId: eventId,
    focus: focus,
  );

  void _notifyRecoveredResult(ProfileChat chat) {
    if (chat.runtime.execution == ChatExecution.failed) {
      _notify(chat, ChatNotificationContent.failed);
      return;
    }
    if (chat.runtime.execution == ChatExecution.cancelled) {
      _notify(chat, ChatNotificationContent.stopped);
      return;
    }
    if (chat.reading.historyError != null) return;
    final answer = chat.reading.messages.reversed
        .takeWhile((row) => row['role'] != 'user')
        .where(
          (row) =>
              row['role'] == 'assistant' &&
              !isHiddenAnswerMessage(row) &&
              answerMessageText(row).trim().isNotEmpty,
        )
        .firstOrNull;
    if (answer == null) {
      if (notificationResultFor?.call(chat._key)?.kind == 'answer') return;
      _notify(chat, ChatNotificationContent.updated);
      return;
    }
    final id = answer['id'];
    _notify(
      chat,
      ChatNotificationContent.reply(answerMessageText(answer)),
      focus: NotificationFocus(
        'answer',
        id is int
            ? '${chat.runtime.runtimeId}:$id'
            : '${chat.runtime.runtimeId}:${DateTime.now().microsecondsSinceEpoch}',
        messageId: id is int ? id : null,
      ),
    );
  }

  void _notify(
    ProfileChat chat,
    ChatNotificationContent content, {
    String? eventId,
    NotificationFocus? focus,
  }) {
    // Hosted discussion workers are private implementation sessions. Their
    // answers and approvals belong to the room, never a UUID-titled chat alert.
    if (chat.source == 'bot_room') return;
    if (content.category == ChatNotificationCategory.inputNeeded) {
      _publishNotificationInputs(chat, alert: true);
    }
    final target =
        focus ??
        NotificationFocus(
          'status',
          eventId ??
              '${chat.runtime.runtimeId}:${DateTime.now().microsecondsSinceEpoch}',
        );
    _deliverNotification(
      chat,
      _notification(chat, content, eventId: eventId, focus: target),
    );
  }

  void _deliverNotification(
    ProfileChat chat,
    ProfileNotification notification,
  ) {
    // Live completion reaches this boundary directly, without _notify. Keep
    // private workers silent across both live and recovered delivery paths.
    if (chat.source == 'bot_room' ||
        (!notification.content.needsAttention &&
            notification.focus?.kind != 'side' &&
            notification.focus?.kind != 'background' &&
            _isBotExchangeReply(chat))) {
      return;
    }
    if (notification.focus != null &&
        notification.content.category != ChatNotificationCategory.inputNeeded) {
      chat.reading.recordNotificationResult(notification.focus);
    }
    if (visible &&
        _current?.chat == chat &&
        !notification.content.needsAttention) {
      // Suppress the new alert, but keep an already-visible notice current.
      if (onNotificationInputs == null) return;
      notification = ProfileNotification(
        key: notification.key,
        title: notification.title,
        connectionLabel: notification.connectionLabel,
        content: notification.content,
        eventId: notification.eventId,
        focus: notification.focus,
        alert: false,
      );
    }
    final callback = onAttention;
    if (callback != null) {
      _pendingNotifications++;
      _changed();
      unawaited(
        Future<void>.sync(
          () => callback(notification),
        ).catchError((Object _) {}).whenComplete(() {
          _pendingNotifications--;
          _changed();
        }),
      );
    }
  }

  Future<void> _scheduleNotificationReconciliation(
    ProfileWorkspaceData resource,
  ) {
    if (_closed || onAttention == null) return Future<void>.value();
    if (_notificationReconciliation != null) {
      _notificationReconcileAgain = true;
      return _notificationReconciliation!;
    }
    _notificationReconciliation =
        (() async {
          do {
            _notificationReconcileAgain = false;
            await _reconcileNotificationActivity(resource);
          } while (_notificationReconcileAgain && !_closed);
        })().whenComplete(() {
          _notificationReconciliation = null;
        });
    return _notificationReconciliation!;
  }

  Future<void> _reconcileNotificationActivity(
    ProfileWorkspaceData source,
  ) async {
    if (_closed || onAttention == null) return;
    final cachedActivity = _liveActivity;
    final turnGenerations = {
      for (final resource in _resources.values)
        for (final chat in resource._chats.values)
          chat: chat._runtime.turnRevision,
    };
    try {
      final profiles = await source.gateway.discover();
      unawaited(_refreshDetachedWork(source, discovery: profiles));
      if (_closed) return;
      final response = await source.gateway.call('session.active_list');
      if (response['sessions'] is! List) {
        throw const FormatException('Missing active sessions');
      }
      final activeRows = ProfileGateway.records(response['sessions']);
      if (activeRows.length != (response['sessions'] as List).length) {
        throw const FormatException('Invalid active sessions');
      }
      final liveIdentities = <String, String>{};
      for (final row in activeRows) {
        final runtimeId = row['id'];
        final sessionId = row['session_key'];
        final status = row['status'];
        final lastActive = row['last_active'];
        final sideTasks = row['side_tasks_running'];
        if (runtimeId is! String ||
            runtimeId.isEmpty ||
            liveIdentities.containsKey(runtimeId) ||
            sessionId is! String ||
            sessionId.isEmpty ||
            status is! String ||
            (lastActive != null && lastActive is! num) ||
            (sideTasks != null && (sideTasks is! int || sideTasks < 0))) {
          throw const FormatException('Invalid active session');
        }
        liveIdentities[runtimeId] = sessionId;
      }
      if (_closed) return;
      // The stock list is complete and excludes finalized runtimes. Retiring
      // an absent watch does not claim a completed answer or clear a notice.
      // Validate the whole list first; failed/partial reads establish nothing.
      _notificationSnapshot?.removeWhere(
        (runtime, entry) => liveIdentities[runtime] != entry.chat.key.sessionId,
      );
      _backgroundChats = {
        for (final entry in _backgroundChats.entries)
          if (liveIdentities[entry.key] == entry.value.sessionId)
            entry.key: entry.value,
      };
      _uncertainNotificationRuntimes.retainAll(_backgroundChats.keys);

      final rows = <Map<String, dynamic>>[];
      final workingRuntimes = <String>{};
      for (final row in activeRows) {
        final runtimeId = row['id'] as String;
        final sessionId = row['session_key'] as String;
        final status = row['status'] as String;
        final sideTasks = row['side_tasks_running'] as int? ?? 0;
        final working = status == 'working' || sideTasks > 0;
        if (working) {
          workingRuntimes.add(runtimeId);
        }
        final loaded = _loadedNotificationChat(runtimeId, sessionId);
        if (loaded != null) {
          // An idle chat can be omitted when the socket reconnects from the
          // chat list. A later desktop turn therefore arrives first through
          // the global working snapshot, not through message.start.
          final remoteWorking = status == 'working';
          final localInputs = jsonEncode(
            _notificationInputs(loaded).map((input) => input.toJson()).toList(),
          );
          // Desktop can resolve input without sending request.cancel. A global
          // non-waiting snapshot is a reason to read the current request state,
          // not permission to discard a locally pending request on its own.
          final inputStateChanged =
              loaded.runtime.needsInput && (status == 'idle' || remoteWorking);
          final missedCompletion =
              loaded.runtime.execution == ChatExecution.running &&
              status == 'idle';
          if (!loaded.runtime.commandRunning &&
              !loaded.composer.observation.sending &&
              loaded._runtime.turnRevision == turnGenerations[loaded] &&
              ((!loaded.runtime.blocksTurnAdmission && remoteWorking) ||
                  inputStateChanged ||
                  missedCompletion)) {
            final generation = loaded._runtime.turnRevision;
            final previousStatus = loaded.runtime.execution;
            final owner = _resources[loaded._key.workspace]!;
            final read = _captureResume(owner, loaded);
            final resumed = await owner.gateway.resume(sessionId);
            if (_closed) return;
            // A live start, new input, answer or navigation can overtake it.
            if (read.current() &&
                loaded.runtime.runtimeId == runtimeId &&
                loaded._runtime.turnRevision == generation &&
                loaded.runtime.execution == previousStatus &&
                !loaded.runtime.commandRunning &&
                !loaded.composer.observation.sending &&
                localInputs ==
                    jsonEncode(
                      _notificationInputs(
                        loaded,
                      ).map((input) => input.toJson()).toList(),
                    )) {
              _hydrate(loaded, resumed);
              loaded._runtime.recovered();
              final continuation = _captureResume(
                owner,
                loaded,
                startRead: false,
              );
              await _journal();
              if (!continuation.current()) continue;
              if (missedCompletion && !loaded.runtime.blocksTurnAdmission) {
                await refreshHistory(loaded);
                if (!continuation.current()) continue;
                if (loaded.reading.historyError == null) {
                  loaded.reading.updateStreaming('');
                }
                _notifyRecoveredResult(loaded);
                await _drainQueuedPrompts(loaded);
              }
            }
          }
          continue;
        }
        final tracked = _notificationSnapshot?[runtimeId];
        final relevant =
            status == 'waiting' ||
            working ||
            status == 'idle' &&
                tracked != null &&
                tracked.chat._key.sessionId == sessionId;
        if (!relevant) continue;
        rows.add(row);
      }

      final sessionIds = rows
          .map((row) => row['session_key'] as String)
          .toSet();
      final ownership = await Future.wait(
        profiles.profiles.map((profile) async {
          final resource = _resource(profile.name);
          final matches = <String, Map<String, dynamic>>{};
          for (final sessionId in sessionIds) {
            final metadata = await resource.gateway.sessionMetadata(sessionId);
            if (metadata != null) matches[sessionId] = metadata;
          }
          return (resource: resource, matches: matches);
        }),
      );
      if (_closed) return;

      // This already-fetched snapshot also supersedes the list's earlier
      // activity read. Otherwise a resolved question can stay Needs input even
      // after the loaded chat has cleared it. Only update known identities;
      // missing/unknown rows are not evidence of completion, and a newer full
      // activity refresh must win over this in-flight reconciliation.
      if (identical(_liveActivity, cachedActivity)) {
        final reported = {
          for (final row in ProfileGateway.records(response['sessions']))
            (row['id'], row['session_key']): row,
        };
        _liveActivity = List.unmodifiable([
          for (final item in cachedActivity)
            ..._reconciledActivity(
              item,
              reported[(item.runtimeId, item.sessionId)],
            ),
        ]);
      }

      final next = <String, _NotificationSession>{};
      for (final row in rows) {
        final runtimeId = row['id'] as String;
        final sessionId = row['session_key'] as String;
        ProfileChat? chat;
        final savedOwners = ownership
            .where((owner) => owner.matches.containsKey(sessionId))
            .toList();
        if (savedOwners.length == 1) {
          final owner = savedOwners.single;
          final metadata = owner.matches[sessionId]!;
          final rawTitle = owner.matches[sessionId]?['title'];
          final title = rawTitle is String ? rawTitle.trim() : '';
          chat = _createChatRecord(
            key: ProfileSessionKey(owner.resource.scope, sessionId),
            runtimeId: runtimeId,
            title: title.isEmpty ? 'Hermes session' : title,
            source: metadata['source'] is String
                ? metadata['source'] as String
                : '',
          );
        }
        if (chat == null) continue;
        if (chat.source == 'bot_room') continue;
        final status = row['status'] as String;
        final sideTasks = row['side_tasks_running'] as int? ?? 0;
        final activity = status == 'waiting'
            ? _NotificationActivity.waiting
            : status == 'starting' || status == 'working' || sideTasks > 0
            ? _NotificationActivity.running
            : status == 'idle'
            ? _NotificationActivity.idle
            : null;
        if (activity == null) continue;
        next[runtimeId] = _NotificationSession(chat, activity);
      }

      final previous = _notificationSnapshot;
      // Retain verified unfinished identities until a corroborated observation
      // settles them. Ownership ambiguity and unknown/initializing states are
      // uncertainty, not completion. Absent runtimes were retired above.
      _notificationSnapshot = {...?previous};
      _backgroundChats = {..._backgroundChats};
      _uncertainNotificationRuntimes.addAll(_backgroundChats.keys);
      for (final entry in next.entries) {
        final before = previous?[entry.key];
        final after = entry.value;
        if (before != null && before.chat._key != after.chat._key) continue;
        if (after.activity == _NotificationActivity.idle) continue;
        _notificationSnapshot![entry.key] = after;
        _uncertainNotificationRuntimes.remove(entry.key);
        if (workingRuntimes.contains(entry.key)) {
          _backgroundChats[entry.key] = after.chat._key;
        } else {
          _backgroundChats.remove(entry.key);
        }
      }
      if (previous == null) return;
      for (final entry in next.entries) {
        final before = previous[entry.key];
        final after = entry.value;
        if (before != null && before.chat._key != after.chat._key) continue;
        if (_hasLoadedNotificationChat(
          after.chat.runtime.runtimeId,
          after.chat._key.sessionId,
        )) {
          continue;
        }
        if (after.activity == _NotificationActivity.waiting &&
            before?.activity != _NotificationActivity.waiting) {
          await _loadNotificationInput(after.chat);
          if (_closed) return;
        } else if (after.activity == _NotificationActivity.idle &&
            before != null &&
            before.activity != _NotificationActivity.idle) {
          final owner = _resources[after.chat._key.workspace]!;
          try {
            final history = await owner.gateway.history(
              after.chat._key.sessionId,
              runtimeId: after.chat.runtime.runtimeId,
            );
            if (_closed ||
                _hasLoadedNotificationChat(
                  after.chat.runtime.runtimeId,
                  after.chat._key.sessionId,
                )) {
              continue;
            }
            after.chat.reading.installSavedHistory(
              answerHistoryRows(history.rows),
            );
          } catch (_) {
            // Keep this exact work pending for the next existing recovery or
            // activity observation; do not replace a useful reply with a guess.
            continue;
          }
          if (!_closed) {
            _notifyRecoveredResult(after.chat);
            _notificationSnapshot?.remove(entry.key);
            _backgroundChats.remove(entry.key);
            _uncertainNotificationRuntimes.remove(entry.key);
          }
        }
      }
    } catch (_) {
      // A failed read cannot settle previously verified work. Preserve its
      // transition history; only a genuinely cold connection needs a baseline.
      _uncertainNotificationRuntimes.addAll(_backgroundChats.keys);
    } finally {
      _changed();
    }
  }

  /// Adopt only the live request state; opening a conversation and loading its
  /// transcript remain separate user actions. Register before awaiting resume
  /// so a newer live request can overtake the snapshot safely.
  Future<void> _loadNotificationInput(ProfileChat candidate) async {
    final owner = _resources[candidate._key.workspace]!;
    final session = candidate._key.sessionId;
    final runtime = candidate.runtime.runtimeId;
    if (owner.blocksSession(session)) return;
    final existing = owner._chats[session];
    if (existing != null &&
        (existing._key != candidate._key ||
            !existing.runtime.offline ||
            existing.runtime.blocksTurnAdmission ||
            existing.runtime.opening ||
            _current?.chat == existing)) {
      return;
    }
    // Reading snapshots restore durable IDs, not current runtime IDs. Reuse the
    // cached object so its transcript and any navigation/draft references survive.
    final chat = existing ?? candidate;
    final previousRuntime = chat.runtime.runtimeId;
    final previousRecovery = chat.runtime.recovery;
    final previousLiveSessionConfirmed = chat.runtime.liveSessionConfirmed;
    owner._chats[session] = chat;
    // Bind the verified live runtime before resume so an overtaking event owns
    // live state on this same object. A failed unchanged read rolls both back.
    chat._runtime.bindProvisional(runtime);
    _pendingNotifications++;
    final generation = chat._runtime.turnRevision;
    final resumeGeneration = chat._runtime.resumeRevision;
    final status = chat.runtime.execution;
    final read = _captureResume(owner, chat);
    final runtimeRead = chat._runtime.captureRead(startRead: false);
    bool unchanged() =>
        read.current() &&
        identical(owner._chats[session], chat) &&
        chat.runtime.runtimeId == runtime &&
        chat._runtime.turnRevision == generation &&
        chat._runtime.resumeRevision == resumeGeneration &&
        !chat.runtime.opening &&
        chat.runtime.execution == status &&
        _notificationInputs(chat).isEmpty;
    void rollback() {
      if (existing == null) {
        _cancelImagePreparation(chat);
        owner._chats.remove(session);
        chat._runtime.dispose();
        chat.reading.dispose();
      } else {
        chat._runtime.rollbackProvisional(
          runtimeRead,
          runtimeId: previousRuntime,
          recovery: previousRecovery,
          liveSessionConfirmed: previousLiveSessionConfirmed,
        );
      }
      _notificationSnapshot?.remove(runtime);
    }

    try {
      final resumed = await owner.gateway.resume(session);
      if (_closed || owner.blocksSession(session)) return;
      if (!unchanged()) return;
      if (resumed['session_id'] != runtime ||
          owner.gateway.resumeDurableId(resumed) != session) {
        rollback();
        return;
      }
      _hydrate(chat, resumed);
      chat._runtime.recovered();
      if (_notificationInputs(chat).isEmpty) {
        // Resolution during the read does not justify deleting saved reading
        // state. Only discard an idle placeholder created solely by this read.
        if (existing == null && !chat.runtime.blocksTurnAdmission) {
          _cancelImagePreparation(chat);
          owner._chats.remove(session);
          chat._runtime.dispose();
          chat.reading.dispose();
        }
        return;
      }
      // This snapshot is an observed new request, not a reconnect baseline.
      // Publish before yielding: hydration also starts approval.pending, whose
      // completion calls _changed and would otherwise consume the input's
      // fingerprint quietly before this notification can alert.
      _notify(chat, ChatNotificationContent.input(''));
      await _journal();
    } catch (_) {
      // Failed reads roll back only our provisional runtime binding. A newer
      // event or navigation owns its state and must never be undone here.
      if (unchanged()) rollback();
      return;
    } finally {
      _pendingNotifications--;
    }
  }

  Iterable<ProfileLiveActivity> _reconciledActivity(
    ProfileLiveActivity item,
    Map<String, dynamic>? row,
  ) sync* {
    if (row == null ||
        !{'waiting', 'starting', 'working', 'idle'}.contains(row['status'])) {
      yield item;
      return;
    }
    final sideTasks = row['side_tasks_running'] as int? ?? 0;
    if (row['status'] == 'idle' && sideTasks == 0) return;
    yield ProfileLiveActivity(
      workspace: item.workspace,
      runtimeId: item.runtimeId,
      sessionId: item.sessionId,
      title: item.title,
      source: item.source,
      lastActive: (row['last_active'] as num?)?.toDouble() ?? item.lastActive,
      state: row['status'] == 'waiting'
          ? ProfileLiveActivityState.needsInput
          : ProfileLiveActivityState.running,
      sideTasksRunning: sideTasks,
    );
  }

  bool _hasLoadedNotificationChat(String runtimeId, String sessionId) =>
      _loadedNotificationChat(runtimeId, sessionId) != null;

  ProfileChat? _loadedNotificationChat(String runtimeId, String sessionId) =>
      _resources.values
          .expand((resource) => resource._chats.values)
          .where(
            (chat) =>
                chat.runtime.runtimeId == runtimeId &&
                chat._key.sessionId == sessionId,
          )
          .firstOrNull;

  void _scheduleReconnect(ProfileWorkspaceData resource) {
    if (_closed || resource._retry != null || resource._reconnecting) {
      return;
    }
    resource._recovering = true;
    connectionStatus.waitForRecovery(resource.scope.profileName);
    final delay = _recoveryDelay(resource._reconnectAttempt);
    logConnectionDiagnostic(
      'workspace.recovery_scheduled',
      details: {
        'connection': connection.id,
        'profile': resource.scope.profileName,
        'attempt': resource._reconnectAttempt + 1,
        'delay_ms': delay.inMilliseconds,
      },
    );
    // Cap the delay, not the number of attempts: the network can return while
    // the user stays on this screen without another focus/connectivity event.
    resource._reconnectAttempt++;
    resource._retry = Timer(delay, () {
      resource._retry = null;
      unawaited(_reconnect(resource));
    });
  }

  Future<void> reconnect(WorkspaceScope scope) async {
    final resource = _resources[scope];
    if (resource == null || _closed) return;
    _invalidateProjectMembership(resource);
    // A user retry or app resume doesn't wait for the next scheduled attempt.
    resource._retry?.cancel();
    resource._retry = null;
    resource._reconnectAttempt = 0;
    resource._reconnectError = null;
    await _reconnect(resource);
  }

  Future<void> _reconnect(ProfileWorkspaceData resource) {
    // A notification tap must await recovery already started by another caller.
    if (resource._reconnectFuture case final pending?) return pending;
    final completion = Completer<void>();
    resource._reconnectFuture = completion.future;
    unawaited(() async {
      try {
        do {
          resource._restartReconnect = false;
          await _performReconnect(resource);
        } while (!_closed && resource._restartReconnect);
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      } finally {
        resource._reconnectFuture = null;
      }
    }());
    return completion.future;
  }

  Future<void> _performReconnect(ProfileWorkspaceData resource) async {
    if (_closed) return;
    resource._reconnecting = true;
    resource._recovering = true;
    logConnectionDiagnostic(
      'workspace.recovery_started',
      details: {
        'connection': connection.id,
        'profile': resource.scope.profileName,
        'attempt': resource._reconnectAttempt,
      },
    );
    connectionStatus.beginRecovery(resource.scope.profileName);
    _changed();
    var retry = false;
    final resumedChats = <ProfileChat>[];
    try {
      await resource.gateway.connect();
      if (_closed || resource._restartReconnect) return;
      for (final chat in resource._chats.values.toList()) {
        if (resource.blocksSession(chat._key.sessionId)) continue;
        if (!chat.runtime.blocksTurnAdmission &&
            chat != resource.chat &&
            chat.composer.observation.queue.isEmpty) {
          continue;
        }
        final wasBusy = chat.runtime.blocksTurnAdmission;
        final read = _captureResume(resource, chat);
        Map<String, dynamic>? result;
        try {
          result = await resource.gateway.resume(chat._key.sessionId);
        } on JsonRpcError catch (error) {
          if (!read.owned() || !read.current()) continue;
          if (_isDefinitivelyExpiredDraft(chat, error)) {
            await _replaceExpiredDraftRuntime(resource, chat);
          } else if (_isMissingSessionResume(error) &&
              chat.composer.observation.queue.isNotEmpty) {
            chat._runtime.installOfflineReading();
            chat._runtime.completeTurn(
              failed: true,
              cancelled: false,
              error: null,
            );
            chat.composer.recordRuntimeFailure();
            chat._runtime.reportError(
              'This conversation is no longer available. Your unsent messages are kept.',
            );
            await chat.composer.saveWork();
            continue;
          } else {
            rethrow;
          }
        } catch (_) {
          if (!read.current()) continue;
          rethrow;
        }
        if (_closed || resource._restartReconnect) return;
        if (!read.owned()) continue;
        final applied = result != null && read.current();
        if (applied) _hydrate(chat, result);
        final continuation = _captureResume(resource, chat, startRead: false);
        try {
          await refreshHistory(chat, propagateFailure: true);
        } catch (_) {
          if (!continuation.current()) continue;
          rethrow;
        }
        if (_closed || resource._restartReconnect) return;
        if (!continuation.current()) continue;
        if (!chat.runtime.blocksTurnAdmission) chat.reading.updateStreaming('');
        chat._runtime.recovered();
        if (applied && wasBusy && !chat.runtime.blocksTurnAdmission) {
          _notifyRecoveredResult(chat);
        }
        if (applied) resumedChats.add(chat);
      }
      await _journal();
      await _refreshSessions(resource);
      if (_closed || resource._restartReconnect) return;
      logConnectionDiagnostic(
        'workspace.recovered',
        details: {
          'connection': connection.id,
          'profile': resource.scope.profileName,
          'attempt': resource._reconnectAttempt,
        },
      );
      resource._reconnectAttempt = 0;
      resource._reconnectError = null;
      resource._recovering = false;
      resource._offlineSnapshot = false;
      connectionStatus.endRecovery(resource.scope.profileName);
      for (final chat in resumedChats) {
        await _drainQueuedPrompts(chat);
      }
      if (_failedSwitchProfile == resource.scope.profileName) {
        if (_error == _failedSwitchError) _error = null;
        _failedSwitchProfile = null;
        _failedSwitchError = null;
      }
      // Notification reconciliation can scan every profile and continue while
      // sessions change. A restored chat socket must not stay orange during it.
      await _scheduleNotificationReconciliation(resource);
    } catch (failure, stack) {
      if (_closed || resource._restartReconnect) return;
      retry = isTemporaryWorkspaceFailure(failure);
      logConnectionDiagnostic(
        'workspace.recovery_failed',
        details: {
          'connection': connection.id,
          'profile': resource.scope.profileName,
          'attempt': resource._reconnectAttempt,
          ...workspaceFailureDiagnostic(failure),
        },
        error: failure,
        stackTrace: stack,
      );
      if (retry &&
          !connectionStatus.liveAvailable(resource.scope.profileName)) {
        try {
          await resource.gateway.discover();
        } catch (_) {
          /* Observed by the shared connection state. */
        }
      }
      resource._recovering = retry;
      resource._reconnectError = retry
          ? null
          : workspaceFailureMessage(failure);
      if (!retry) {
        connectionStatus.failRecovery(
          resource.scope.profileName,
          resource._reconnectError!,
        );
      }
    } finally {
      resource._reconnecting = false;
      _changed();
      // Idle conversations and the session list also need recovery. A failed
      // connection must not depend on whether a prompt happens to be running.
      if (!resource._restartReconnect &&
          (retry ||
              resource._reconnectError == null &&
                  resource._chats.values.any((c) => c.runtime.reconnecting))) {
        _scheduleReconnect(resource);
      }
    }
  }

  void _observeConnectionOperation(
    ProfileChat chat,
    Object? value, {
    bool update = false,
    bool snapshot = false,
  }) {
    if (value == null && snapshot) {
      chat._connectionOperation = null;
      chat._connectionOperationAction = null;
      return;
    }
    if (value is! Map) return;
    final previous = chat._connectionOperation;
    if (update) {
      if (previous == null ||
          previous.settled ||
          value['op_id'] != previous.id) {
        return;
      }
      chat._connectionOperation = previous.applyStatus(
        Map<String, dynamic>.from(value),
      );
      return;
    }
    final next = HostedConnectionOperation.fromJson(
      Map<String, dynamic>.from(value),
    );
    if (previous != null &&
        previous.id == next.id &&
        previous.sequence >= next.sequence) {
      return;
    }
    if (previous?.id != next.id) chat._connectionOperationAction = null;
    chat._connectionOperation = next;
  }

  bool canRefreshConnectionOperation(
    ProfileChat chat,
    HostedConnectionOperation expected,
  ) {
    final resource = _resources[chat._key.workspace];
    return !_closed &&
        !switching &&
        resource != null &&
        identical(resource._chats[chat._key.sessionId], chat) &&
        !resource.blocksSession(chat._key.sessionId) &&
        !_recoveringStoredDrafts.contains(chat._key) &&
        !_deletedDrafts.blocks(
          chat._key.workspace.profileName,
          chat._key.sessionId,
        ) &&
        identical(chat.connectionOperation, expected) &&
        !expected.settled &&
        !chat.connectionOperationWorking &&
        !chat.runtime.opening &&
        !chat.runtime.offline &&
        !chat.runtime.reconnecting;
  }

  bool canContinueConnectionOperation(
    ProfileChat chat,
    HostedConnectionOperation expected,
  ) =>
      chat.readOnlyReason == null &&
      canRefreshConnectionOperation(chat, expected);

  Future<void> continueConnectionOperation(
    ProfileChat chat,
    HostedConnectionOperation expected,
  ) => _connectionOperationRequest(
    chat,
    expected,
    answer: const {'settled_by': 'continue'},
  );

  Future<void> refreshConnectionOperation(
    ProfileChat chat,
    HostedConnectionOperation expected,
  ) => _connectionOperationRequest(chat, expected);

  Future<void> respondToConnectionTarget(
    ProfileChat chat,
    HostedConnectionOperation expected,
    HostedConnectionTarget target, {
    bool skip = false,
    Map<String, String> credentials = const {},
  }) async {
    if (!expected.targets.contains(target) ||
        (skip
            ? !target.canSkip
            : !const {
                HostedConnectionStep.enable,
                HostedConnectionStep.install,
                HostedConnectionStep.retry,
              }.contains(target.step))) {
      throw StateError('This connector action is no longer available.');
    }
    if (!skip && target.kind == 'connector') {
      await _connectionOperationRequest(chat, expected, retryTarget: target);
      return;
    }
    final env = {
      for (final field in target.fields)
        if (credentials[field.name]?.isNotEmpty == true)
          field.name: credentials[field.name]!,
    };
    if (!skip && !target.hasRequiredCredentials(env)) {
      throw StateError('Enter the required connector credentials.');
    }
    await _connectionOperationRequest(
      chat,
      expected,
      answer: {
        'targets': [
          {
            'name': target.name,
            'status': skip ? 'skipped' : 'approved',
            if (!skip && env.isNotEmpty) 'env': env,
          },
        ],
      },
    );
  }

  Future<void> _connectionOperationRequest(
    ProfileChat chat,
    HostedConnectionOperation expected, {
    Map<String, dynamic>? answer,
    HostedConnectionTarget? retryTarget,
  }) async {
    final resource = _commandOwner(chat);
    if (!(answer != null || retryTarget != null
        ? canContinueConnectionOperation(chat, expected)
        : canRefreshConnectionOperation(chat, expected))) {
      throw StateError(
        'This connection request changed. Refresh the conversation.',
      );
    }
    final key = chat._key;
    final runtime = chat.runtime.runtimeId;
    final action = Object();
    final params = <String, dynamic>{
      'owner': {'type': 'session', 'session_id': runtime},
      'op_id': expected.id,
    };
    void requireCurrent() {
      if (_closed ||
          chat._key != key ||
          !identical(_resources[key.workspace], resource) ||
          !identical(resource._chats[key.sessionId], chat) ||
          chat.runtime.runtimeId != runtime ||
          chat.connectionOperation?.id != expected.id ||
          chat.runtime.offline ||
          chat.runtime.reconnecting ||
          !identical(chat._connectionOperationAction, action)) {
        throw StateError('The connection request is no longer current.');
      }
      _commandOwner(chat);
    }

    chat._connectionOperationAction = action;
    _changed();
    try {
      requireCurrent();
      if (retryTarget != null) {
        // Stock retries the named target on the session's current operation.
        final status = await resource.gateway.call('connectors.connect', {
          'owner': params['owner'],
          'connectors': [retryTarget.name],
          'reconnect': true,
          if (retryTarget.alias != null)
            'alias': retryTarget.alias
          else if (retryTarget.connectionId != null)
            'connection_id': retryTarget.connectionId,
        });
        requireCurrent();
        if (status['op_id'] != expected.id) {
          throw const FormatException(
            'Connection retry belongs to another request.',
          );
        }
        _observeConnectionOperation(chat, status, update: true);
        return;
      }
      if (answer != null) {
        final receipt = await resource.gateway.call('connection.respond', {
          ...params,
          'result': answer,
        });
        requireCurrent();
        if (receipt['status'] != 'ok' || receipt['settled'] is! bool) {
          throw const FormatException(
            'Connection response was not acknowledged.',
          );
        }
        if (receipt['settled'] == true) {
          // Stock closes the operation before replying; it can no longer be read.
          if (answer['settled_by'] == 'continue' ||
              chat.connectionOperation?.settled != true) {
            chat._connectionOperation = null;
          }
          return;
        }
      }
      Map<String, dynamic> status;
      try {
        status = await resource.gateway.call(
          'connectors.operation.status',
          params,
        );
      } on JsonRpcError catch (error) {
        if (error.method != 'connectors.operation.status' ||
            error.reason != 'UNKNOWN_OPERATION') {
          rethrow;
        }
        requireCurrent();
        final read = _captureResume(resource, chat);
        final snapshot = await resource.gateway.resume(key.sessionId);
        requireCurrent();
        if (!read.current() || snapshot['session_id'] != runtime) {
          throw StateError(
            'The conversation changed while checking this request.',
          );
        }
        _observeCanonicalPending(chat);
        _observeConnectionOperation(
          chat,
          snapshot['pending_connection'],
          snapshot: true,
        );
        return;
      }
      requireCurrent();
      if (status['op_id'] != expected.id) {
        throw const FormatException(
          'Connection status belongs to another request.',
        );
      }
      _observeConnectionOperation(chat, status, update: true);
    } finally {
      if (identical(chat._connectionOperationAction, action)) {
        chat._connectionOperationAction = null;
      }
      _changed();
    }
  }

  void _hydrate(ProfileChat chat, Map<String, dynamic> result) {
    chat._attachmentRefused = false;
    _observeConnectionOperation(
      chat,
      result['pending_connection'],
      snapshot: true,
    );
    _observeReferenceWorkspace(
      chat,
      result['info'] as Map? ?? const {},
      replace: true,
    );
    final source = (result['info'] as Map?)?['source'];
    if (source is String && source.isNotEmpty) chat._source = source;
    final runtime = result['session_id'] as String;
    if (chat.runtime.runtimeId != runtime) {
      chat._connectionOperationAction = null;
      chat._intelligenceRevision++;
      chat._context = null;
      chat._contextGeneration++;
      chat._contextCompressions = null;
      chat._contextLoading = false;
      chat._contextError = null;
      chat._runtime.finishActivity();
      chat._taskState = GatewayTodoState();
      chat._subagents = [];
      chat._subagentCompletionTurns.clear();
      chat._unconfirmedSubagentIds.clear();
      chat._subagentsRevision++;
      chat._subagentsLoading = false;
      chat._subagentsError = null;
      chat._subagentsLoadGeneration++;
      chat._processes = [];
      chat._processCompletionTurns.clear();
      chat._processesLoading = false;
      chat._processesError = null;
      chat._dismissedProcessIds.clear();
      chat._stoppingProcessIds.clear();
      chat._processesReadGeneration++;
      chat._sessionControl = null;
      chat._sessionControlLoading = false;
      chat._sessionControlWorking = false;
      chat._sessionControlError = null;
      chat._sessionControlNotice = null;
      chat._sessionControlGeneration++;
      chat._sessionControlEventRevision++;
      chat._sessionControlReadAttempted = false;
      chat._sideQuestionDeliveries.clear();
    }
    chat._runtime.installResume(result);
    // Publish notifications only after this complete snapshot has been installed.
    _observeCanonicalPending(chat, notify: false);
    unawaited(_reconcileCanonicalSubmissions(chat));
    final usage = (result['info'] as Map?)?['usage'];
    if (usage is Map) _updateContext(chat, usage);
    chat._notificationInputsQuiet = true;
    if (result['open_requests'] is List &&
        _notificationInputsFor?.call(chat.key).isNotEmpty == true) {
      _publishNotificationInputs(chat, alert: false, confirmedSnapshot: true);
    }
    _hydrateIntelligence(chat, result);
    chat._fastMode = null;
    unawaited(_observeModelControls(chat));
    _applyTodoSnapshot(chat, result['todo_state']);
    final inflight = result['inflight'] as Map?;
    chat.reading.applyReplySnapshot(inflight?['assistant']?.toString());
    unawaited(_refreshApprovals(chat, notifyNew: false));
    if (result.containsKey('side_tasks')) {
      _hydrateSideTasks(chat, result['side_tasks']);
    }
    if (chat.composer.observation.submissionUncertain) {
      chat._runtime.reportError(
        'Delivery is uncertain. Check the server history before sending this draft again.',
      );
    } else if (chat.composer.observation.queue.any(
      (prompt) => prompt.submissionUncertain,
    )) {
      chat._runtime.reportError(
        'Delivery of a queued message is uncertain. Check history, then edit or remove it before resuming.',
      );
    }
  }

  void _hydrateSideTasks(ProfileChat chat, Object? snapshot) {
    chat._sideQuestionDeliveries
      ..clear()
      ..addAll(SideQuestionDelivery.parseSnapshot(snapshot));
  }

  Future<void> _journal() {
    try {
      // Notification actions may write before initialize. Import unresolved
      // owners before the first snapshot, never again after they settle.
      _seedPendingOwners();
    } catch (failure, stack) {
      return Future.error(failure, stack);
    }
    final snapshot = {
      ..._unrestoredPending,
      ...activity
          .where((c) => c.runtime.blocksTurnAdmission)
          .map((c) => c._key),
    }.map((key) => jsonEncode(key.toJson())).toList();
    final write = _journalQueue.then((_) async {
      if (!await preferences.setStringList(_journalKey, snapshot)) {
        throw StateError('Could not save pending chat owners');
      }
    });
    _journalQueue = write.catchError((Object _) {});
    return write;
  }

  Future<String> _pendingChatTitle(
    ProfileWorkspaceData resource,
    String sessionId,
  ) async {
    final loaded = <Map<String, dynamic>>[
      ...resource.visibleSessions,
      ...resource._sessions,
    ].where((row) => row['id'] == sessionId);
    for (final row in loaded) {
      final title = row['title'];
      if (title is String && title.trim().isNotEmpty) return title.trim();
    }
    try {
      final metadata = await resource.gateway.sessionMetadata(sessionId);
      if (metadata != null) {
        final title = metadata['title'];
        if (title is String && title.trim().isNotEmpty) return title.trim();
      }
    } catch (_) {
      // Metadata failure must not prevent recovering the running turn.
      // Activity refresh can resolve the title when the profile is reachable.
    }
    final shortId = sessionId.length <= 8
        ? sessionId
        : sessionId.substring(0, 8);
    return 'Hermes session · $shortId';
  }

  void _seedPendingOwners() {
    if (_pendingOwnersSeeded) return;
    final restored = <ProfileSessionKey>{};
    try {
      for (final raw in preferences.getStringList(_journalKey) ?? <String>[]) {
        final key = ProfileSessionKey.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (!owns(key)) continue;
        restored.add(key);
      }
    } catch (_) {
      _error =
          'Saved pending chat owners could not be read. Local work is kept.';
      throw const FormatException('Could not read saved pending chat owners');
    }
    _unrestoredPending.addAll(restored);
    _pendingOwnersSeeded = true;
  }

  Future<void> _restorePending() async {
    _seedPendingOwners();
    // Keep every unresolved owner in subsequent journal snapshots, even if its
    // profile is unavailable while another profile starts or settles a turn.
    for (final key in _unrestoredPending.toList()) {
      try {
        final resource = _resource(key.workspace.profileName);
        if (resource.blocksSession(key.sessionId)) continue;
        final existing = resource._chats[key.sessionId];
        if (existing != null && !existing.runtime.offline) {
          _unrestoredPending.remove(key);
          continue;
        }
        final read = existing == null
            ? null
            : _captureResume(resource, existing);
        await resource.gateway.connect();
        final title = await _pendingChatTitle(resource, key.sessionId);
        if (_closed || resource.blocksSession(key.sessionId)) {
          continue;
        }
        final result = await resource.gateway.resume(key.sessionId);
        if (_closed ||
            !identical(_resources[key.workspace], resource) ||
            resource.blocksSession(key.sessionId)) {
          continue;
        }
        final concurrent = resource._chats[key.sessionId];
        if (!identical(concurrent, existing)) {
          if (concurrent != null && !concurrent.runtime.offline) {
            _unrestoredPending.remove(key);
          }
          continue;
        }
        if (read != null && !read.current()) continue;
        final chat =
            existing ??
            _createChatRecord(
              key: key,
              runtimeId: result['session_id'] as String,
              title: title,
            );
        resource._chats[key.sessionId] = chat;
        chat._runtime.beginRecovery();
        _hydrate(chat, result);
        final continuation = _captureResume(resource, chat, startRead: false);
        await _restoreDraft(chat);
        if (!continuation.current()) continue;
        await refreshHistory(chat);
        if (!continuation.current()) continue;
        chat._runtime.recovered();
        await _drainQueuedPrompts(chat);
        _unrestoredPending.remove(key);
        if (!chat.runtime.blocksTurnAdmission) {
          _notifyRecoveredResult(chat);
        }
      } catch (_) {
        _error =
            'Some pending chats could not be restored. No prompts were resent.';
      }
    }
    await _journal();
    _changed();
  }

  @override
  void dispose() {
    _groupNotifications.removeListener(_changed);
    _groupNotifications.dispose();
    groupObservations.dispose();
    appPreferences.state.removeListener(_visibilityChanged);
    _profileSelection.removeListener(_selectionChanged);
    _closed = true;
    _processWatchTimer?.cancel();
    _processWatchTarget = null;
    _processWatchRead = null;
    _activeReadingWindow = null;
    for (final resource in _resources.values) {
      for (final chat in resource._chats.values) {
        chat.composer.dispose();
        chat._runtime.dispose();
        chat.reading.dispose();
      }
    }
    attachments.cancelImagePreparations();
    _streamPresentationTimer?.cancel();
    _composerChanges.dispose();
    _retentionChanges.dispose();
    _browserChanges.dispose();
    _browserMutations.dispose();
    _deletedDraftCleanupPresentation.dispose();
    _hostResources?.dispose();
    _healthSession?.dispose();
    _notificationRetry?.cancel();
    unawaited(_saveReadingSnapshot());
    connectionStatus.dispose();
    _initializationRetry?.cancel();
    for (final resource in _resources.values) {
      resource._retry?.cancel();
      resource.gateway.close();
    }
    _gatewayConnection.close();
    super.dispose();
  }
}

/// Captured read access, retained only by its Find route or adopted reader window.
final class _WorkspaceChatReading implements ChatReadingSource {
  _WorkspaceChatReading(this.controller, this.resource, this.chat, this.request)
    : key = chat._key,
      historyGeneration = chat.reading.historyGeneration,
      sessionId = chat.reading.historySessionId ?? chat._key.sessionId;

  final ProfileWorkspaceController controller;
  final ProfileWorkspaceData resource;
  final ProfileChat chat;
  final ProfileSessionKey key;
  final int historyGeneration;
  final String sessionId;
  final int request;

  bool get _ownsHistory =>
      !controller._closed &&
      identical(controller._resources[key.workspace], resource) &&
      identical(resource._chats[key.sessionId], chat) &&
      chat._key == key &&
      chat.reading.historyGeneration == historyGeneration &&
      (chat.reading.historySessionId ?? chat._key.sessionId) == sessionId &&
      !resource.blocksSession(key.sessionId);

  bool get _sameHistory =>
      _ownsHistory && identical(controller.current?.chat, chat);

  @override
  bool get current =>
      _sameHistory && controller._readingRequestGeneration == request;

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);

  @override
  Future<ProfileHistoryPage> load(int offset) async {
    if (!current) {
      throw StateError('The captured chat changed');
    }
    final page = await chat.reading.savedPage(sessionId, offset: offset);
    if (!current) {
      throw StateError('The captured chat changed');
    }
    if (page.sessionId != sessionId) {
      throw const FormatException(
        'The server returned a different chat history.',
      );
    }
    return page;
  }

  @override
  bool show(ProfileHistoryPage page, int rowId) {
    if (!current ||
        page.sessionId != sessionId ||
        !page.rows.any((row) => row['id'] == rowId)) {
      return false;
    }
    controller._activeReadingWindow = _ChatReadingWindow(this, page, rowId);
    controller._changed();
    return current;
  }
}

final class _ChatReadingWindow {
  _ChatReadingWindow(this.source, this.page, int rowId)
    : focus = ChatReadingFocus(offset: page.offset, rowId: rowId);
  final _WorkspaceChatReading source;
  final ProfileHistoryPage page;
  final ChatReadingFocus focus;
}

// Stock workspace indexes contain JSON rows; observers receive detached values.
List<Map<String, dynamic>> _readonlyWorkspaceRows(
  Iterable<Map<String, dynamic>> rows,
) => List.unmodifiable(rows.map(_readonlyWorkspaceRow));
Map<String, dynamic>? _readonlyOptionalWorkspaceRow(
  Map<String, dynamic>? row,
) => row == null ? null : _readonlyWorkspaceRow(row);
Map<String, dynamic> _readonlyWorkspaceRow(Map<String, dynamic> row) =>
    row is _WorkspaceRow ? row : _WorkspaceRow(row);

final class _WorkspaceRow extends UnmodifiableMapView<String, dynamic> {
  _WorkspaceRow(Map<String, dynamic> row)
    : super(
        Map.unmodifiable({
          for (final entry in row.entries)
            entry.key: _readonlyWorkspaceValue(entry.value),
        }),
      );
}

Object? _readonlyWorkspaceValue(Object? value) => switch (value) {
  Map value => Map<String, dynamic>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _readonlyWorkspaceValue(entry.value),
  }),
  List value => List<dynamic>.unmodifiable(value.map(_readonlyWorkspaceValue)),
  _ => value,
};
