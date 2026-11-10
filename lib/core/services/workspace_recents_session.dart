import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/profile_session_key.dart';
import '../models/recent_conversation.dart';
import 'bots_session.dart';
import 'profile_workspace_controller.dart';
import 'recent_conversation_snapshots.dart';
import 'server_connection_status.dart';
import 'workspace_recents_cache.dart';

/// Workspace-owned Recents catalog shared by the list and conversation sources.
/// Reads return cached immutable observations. Visible borrowers share refreshes.
class WorkspaceRecentsSession extends ChangeNotifier
    implements WorkspaceRecentsCache {
  WorkspaceRecentsSession(
    this.controller,
    this.bots, {
    required this._foreground,
  }) {
    bots.attachGroupMessages(groupMessages);
    controller.addListener(_changed);
    controller.connectionStatus.addListener(_changed);
    bots.addListener(_changed);
    bots.groupReads.addListener(_changed);
    _publish();
  }
  final ProfileWorkspaceController controller;
  @override
  Object get workspaceOwner => controller;
  @override
  final BotsSession bots;
  @override
  bool get current => !_closed;
  @override
  final snapshots = RecentConversationSnapshots();
  final groupMessages = RecentGroupMessages();
  final _readingRevisions = Expando<Object>();
  @override
  Object readingRevision(List<Map<String, dynamic>> messages) =>
      _readingRevisions[messages] ??= Object();
  bool _closed = false, _publicationPending = false;
  final _visible = <Object>{};
  bool _foreground;
  bool get _active => _foreground && _visible.isNotEmpty;
  Future<void>? _refreshing;
  bool _initialLoadSettled = false;
  Future<void>? _preparingAppearances;
  DateTime? _lastRefresh;
  static const refreshInterval = Duration(seconds: 30);
  List<WorkspaceRecentItem> _items = const [];
  List<Object?> _facts = const [];
  RecentConversationCatalog _catalog = RecentConversationCatalog(
    entries: const [],
    error: null,
  );
  @override
  RecentConversationCatalog get catalog => _catalog;
  ({
    bool initialLoading,
    bool chatsLoading,
    bool chatsLoaded,
    bool botsLoading,
    bool groupsAvailable,
    bool connectionInterrupted,
  })
  _loadingFacts = (
    initialLoading: false,
    chatsLoading: false,
    chatsLoaded: false,
    botsLoading: false,
    groupsAvailable: false,
    connectionInterrupted: false,
  );
  bool get contentAvailable =>
      _items.isNotEmpty ||
      (_loadingFacts.chatsLoaded &&
          _loadingFacts.groupsAvailable &&
          !_loadingFacts.connectionInterrupted);
  bool get contentLoading =>
      _loadingFacts.initialLoading ||
      (!contentAvailable &&
          (_loadingFacts.chatsLoading || _loadingFacts.botsLoading));
  int _appearanceEpoch = -1;
  int _appearanceGeneration = 0;
  Set<ProfileSessionKey> _keys = {};
  final _colorProfiles = <String>{};
  Timer? _poll;

  /// Route borrowers can remain mounted after Android stops delivering frames.
  /// Their last rendered visibility must not keep catalog/appearance I/O alive.
  void setForeground(bool foreground) {
    if (_closed || _foreground == foreground) return;
    _foreground = foreground;
    for (final reader in _visible) {
      bots.setRecentsVisible(reader, foreground);
    }
    _syncPolling();
    if (foreground) _changed();
  }

  @override
  void setVisible(Object reader, bool visible) {
    if (_closed) return;
    bots.setRecentsVisible(reader, visible && _foreground);
    final wasActive = _active;
    if (visible) {
      _visible.add(reader);
    } else {
      _visible.remove(reader);
    }
    if (wasActive != _active) _syncPolling();
  }

  void _syncPolling() {
    if (_active) {
      if (_poll != null) return;
      // Borrowers can attach during route composition. Publish/read only after
      // the caller returns, and recheck whether any reader still needs data.
      scheduleMicrotask(() {
        if (_closed || !_active) return;
        _changed();
        unawaited(refresh());
      });
      _poll = Timer.periodic(
        refreshInterval,
        (_) => unawaited(refresh(force: true)),
      );
    } else {
      _poll?.cancel();
      _poll = null;
      ++_appearanceGeneration;
      _appearanceEpoch = -1;
    }
  }

  List<WorkspaceRecentItem> items() => _items;

  @override
  Future<void> refresh({bool force = false}) {
    if (_closed) return Future.value();
    if (_refreshing case final pending?) return pending;
    if (!force &&
        _lastRefresh != null &&
        DateTime.now().difference(_lastRefresh!) < refreshInterval) {
      return Future.value();
    }
    final completion = Completer<void>();
    _refreshing = completion.future;
    _lastRefresh = DateTime.now();
    _changed();
    unawaited(() async {
      try {
        await Future.wait([controller.refreshRecents(), bots.refresh()]);
        // Metadata and admitted image reads can outlive the catalog reads.
        // Join the current decoration generation before settling initial entry.
        while (!_closed && _foreground) {
          final preparation = prepareAppearances();
          await preparation;
          if (identical(preparation, _preparingAppearances)) break;
        }
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      } finally {
        _refreshing = null;
        _initialLoadSettled = true;
        if (!_closed) _publish();
      }
    }());
    return completion.future;
  }

  void _publish() {
    if (_closed || !_foreground) return;
    final items = workspaceRecentItems(controller, bots);
    final facts = <Object?>[
      for (final item in items)
        (
          item.chat?.key,
          item.chat?.title,
          item.chat?.source,
          item.lastMessage,
          item.messagePreview,
          item.unread,
          item.chat?.activity != null,
          item.chat?.state,
          item.chat?.sideTasksRunning,
          item.chat?.project,
          item.bot,
          item.bot == null ? null : bots.avatarContentVersion(item.bot!.scope),
          item.group,
          item.group == null
              ? null
              : jsonEncode([
                  for (final member
                      in bots.appearanceForGroup(item.group!).byHandle.entries)
                    [member.key, bots.avatarContentVersion(member.value.scope)],
                ]),
          item.group == null ? null : bots.appearanceForGroup(item.group!),
        ),
    ];
    final connectionInterrupted =
        controller.connectionStatus.transportAvailability ==
        ConnectionAvailability.unavailable;
    // Connection incidents belong to Alerts, including the conversation switcher.
    final error =
        connectionInterrupted ||
            controller.recentsProfileErrors.isEmpty && bots.state.errors.isEmpty
        ? null
        : 'Some recent conversations could not be loaded.';
    final loadingFacts = (
      initialLoading: !_initialLoadSettled && _refreshing != null,
      chatsLoading: controller.recentsLoading,
      chatsLoaded: controller.recentsLoaded,
      botsLoading: bots.state.loading,
      groupsAvailable: bots.state.groupsAvailable,
      connectionInterrupted: connectionInterrupted,
    );
    final catalogChanged =
        !listEquals(facts, _facts) || error != _catalog.error;
    if (catalogChanged) {
      _items = items;
      _facts = facts;
      _catalog = RecentConversationCatalog(
        entries: items.map((item) => item.conversation),
        error: error,
      );
    }
    if (catalogChanged || loadingFacts != _loadingFacts) {
      _loadingFacts = loadingFacts;
      notifyListeners();
    }
  }

  void _changed() {
    if (_closed || !_foreground) return;
    if (!_publicationPending) {
      _publicationPending = true;
      scheduleMicrotask(() {
        _publicationPending = false;
        _publish();
      });
    }
    if (!_active) return;
    prepareAppearances();
  }

  /// A mounted identity list can request decoration without starting polling.
  Future<void> prepareAppearances() {
    if (_closed || !_foreground) return Future.value();
    final keys = controller.recentChats().map((c) => c.key).toSet();
    for (final name in keys.map((key) => key.workspace.profileName)) {
      if (_colorProfiles.add(name)) {
        controller.appPreferences.observeProfileColor(
          controller.connectionIdentity,
          name,
        );
      }
    }
    if (!setEquals(keys, _keys) || _appearanceEpoch != bots.appearanceEpoch) {
      _keys = keys;
      _appearanceEpoch = bots.appearanceEpoch;
      final generation = ++_appearanceGeneration;
      _preparingAppearances = bots
          .appearancesForConversations(
            keys,
            canRead: () =>
                !_closed && _foreground && generation == _appearanceGeneration,
          )
          .then((value) async {
            if (_closed ||
                !_foreground ||
                generation != _appearanceGeneration) {
              return;
            }
            _changed();
            await bots.prepareRecentsAvatars(
              canRead: () =>
                  !_closed &&
                  _foreground &&
                  generation == _appearanceGeneration,
            );
          });
    }
    return _preparingAppearances ??= Future.value();
  }

  @override
  void dispose() {
    _closed = true;
    for (final reader in _visible) {
      bots.setRecentsVisible(reader, false);
    }
    _visible.clear();
    _items = const [];
    _facts = const [];
    _keys = {};
    _colorProfiles.clear();
    _catalog = RecentConversationCatalog(entries: const [], error: null);
    snapshots.dispose();
    bots.detachGroupMessages(groupMessages);
    groupMessages.dispose();
    _poll?.cancel();
    controller.removeListener(_changed);
    controller.connectionStatus.removeListener(_changed);
    bots.removeListener(_changed);
    bots.groupReads.removeListener(_changed);
    super.dispose();
  }
}
