import 'dart:async';
import 'dart:convert';
import '../models/operational_error.dart';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';

import '../models/bots.dart';
import '../models/profile_colors.dart';
import '../models/hermes_profile.dart';
import '../models/profile_session_key.dart';
import 'bots_repository.dart';
import 'group_observations.dart';
import 'bots_preferences.dart';
import 'bot_screen_session.dart';
import 'bot_group_read_state.dart';
import 'bot_group_session.dart';
import 'recent_conversation_snapshots.dart';

part 'bot_avatar_cache.dart';

typedef BotsSources =
    Future<List<BotsRepository>> Function(bool Function() canUse);

/// Owns the cross-instance roster and mutation lifetime, independent of the
/// currently selected chat profile. Failed refreshes retain usable observations.
class BotsSession extends ChangeNotifier implements BotGroupAppearanceSource {
  BotsSession(
    this._sources, {
    Future<BotsPreferences> Function()? loadPreferences,
    this.onGroupRead,
    this.beforeGroupSend,
    this.afterGroupSend,
    this.onIdentityChanged,
    this.onOperationalError,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _loadPreferences = loadPreferences ?? BotsPreferences.load;
  final DateTime Function() _now;
  final groupReads = BotGroupReadState();
  final BotsSources _sources;
  final Future<void> Function(BotGroup, int)? onGroupRead;
  final Future<void> Function(BotGroup, String)? beforeGroupSend;
  final Future<void> Function(BotGroup, BotGroupSendOutcome)? afterGroupSend;
  final void Function(WorkspaceScope, BotRecord?)? onIdentityChanged;
  final OperationalErrorReporter? onOperationalError;
  final Future<BotsPreferences> Function() _loadPreferences;
  BotsPreferences? _preferences;
  Set<String> _groupPins = const {};
  List<BotsRepository>? _repositories;
  final _bots = <String, List<BotRecord>>{};
  final _groups = <String, List<BotGroup>>{};
  final _groupPresenceAvailable = <String>{};
  final _ready = <String>{};
  List<String> _errors = const [];
  String? _operationError;
  bool _closed = false, _loading = false, _busy = false, _visible = false;
  bool _emptySourcesObserved = false;
  int _readGeneration = 0;
  Timer? _poll;
  int _refreshes = 0, _explicitRefreshes = 0;
  final _recentsReaders = <Object>{};
  RecentGroupMessages? _groupMessages;
  RecentGroupMessages? get groupMessages => _groupMessages;

  final _observationSources = <GroupObservations>{};
  final _seenGroupObservations = <String, GroupMessageObservation>{};
  final _groupObservationDemand = <String>{};
  final _groupObservationReads = <String, Future<void>>{};

  void _groupObservationsChanged() {
    if (_closed) return;
    for (final source in _repositories ?? <BotsRepository>[]) {
      final snapshots = source.groupObservations.values.toList();
      final keys = snapshots.map((value) => value.room.key).toSet();
      for (final entry in _seenGroupObservations.entries.toList()) {
        if (entry.value.room.scope == source.scope &&
            !keys.contains(entry.key)) {
          _seenGroupObservations.remove(entry.key);
          _groups[source.scope.connectionIdentity] = List.unmodifiable(
            (_groups[source.scope.connectionIdentity] ?? <BotGroup>[]).where(
              (room) => room.key != entry.key,
            ),
          );
          _groupObservationDemand.remove(entry.key);
          notifyListeners();
        }
      }
      for (final observation in snapshots) {
        final key = observation.room.key;
        if (identical(_seenGroupObservations[key], observation)) continue;
        _seenGroupObservations[key] = observation;
        final previous = groupForKey(key);
        final projected = observation.project(previous ?? observation.room);
        if (previous == null) {
          _groups[source.scope.connectionIdentity] = List.unmodifiable([
            ...?_groups[source.scope.connectionIdentity],
            projected,
          ]);
          notifyListeners();
        } else {
          _publishRoom(previous, projected);
        }
        if (projected.observationComplete) {
          _groupObservationDemand.remove(key);
        } else {
          _groupObservationDemand.add(key);
        }
      }
    }
    _drainGroupObservationDemand();
  }

  void _drainGroupObservationDemand() {
    if (_closed || _busy) return;
    for (final key in _groupObservationDemand.toList()) {
      _groupObservationReads.putIfAbsent(
        key,
        () => _refreshGroupObservation(key).whenComplete(() {
          _groupObservationReads.remove(key);
          if (!_busy && _groupObservationDemand.contains(key)) {
            _drainGroupObservationDemand();
          }
        }),
      );
    }
  }

  Future<void> _refreshGroupObservation(String key) async {
    final generation = _readGeneration;
    await Future.wait([?_stateJobs[key]?.pending, ?_previewJobs[key]?.pending]);
    if (_closed || generation != _readGeneration || _busy) return;
    final room = groupForKey(key);
    final source = _repositories
        ?.where((source) => source.scope == room?.scope)
        .firstOrNull;
    if (room == null || source == null) {
      _groupObservationDemand.remove(key);
      return;
    }
    if (!_groupObservationDemand.remove(key)) return;
    final serving = _seenGroupObservations[key];
    // Only missing facts need a read. Complete log observations already carry
    // freshness/excerpt/answer, and never manufacture cached transcript coverage.
    for (final job in [_stateJobs[key], _previewJobs[key]]) {
      job?.success = null;
      job?.failed = null;
    }
    source.retain();
    try {
      await _refreshRoom(source, room, generation);
    } finally {
      source.release();
      final latest = _seenGroupObservations[key];
      final stillBound =
          _repositories?.any(
            (bound) =>
                identical(bound.groupObservations, source.groupObservations),
          ) ??
          false;
      if (stillBound &&
          latest != null &&
          serving != null &&
          latest.latestSequence <= serving.latestSequence) {
        _groupObservationDemand.remove(key);
      }
    }
  }

  void attachGroupMessages(RecentGroupMessages messages) {
    if (_closed ||
        (_groupMessages != null && !identical(_groupMessages, messages))) {
      throw StateError('Group messages already have a workspace cache owner');
    }
    _groupMessages = messages;
  }

  void detachGroupMessages(RecentGroupMessages messages) {
    if (identical(_groupMessages, messages)) _groupMessages = null;
  }

  final _unconfirmedCreates = <String>{};
  Future<List<BotsRepository>>? _appearanceSources;
  DateTime? _sourcesFailedAt;
  final _identities = <WorkspaceScope, BotRecord>{};
  final _appearanceKeys = <ProfileSessionKey, WorkspaceScope>{};
  final _readErrors = <Object, String>{};
  final _rosterJobs = <WorkspaceScope, _BotsReadJob>{};
  final _statusJobs = <WorkspaceScope, _BotsReadJob>{};
  final _readinessJobs = <WorkspaceScope, _BotsReadJob>{};
  final _catalogJobs = <WorkspaceScope, _BotsReadJob>{};
  final _stateJobs = <String, _BotsReadJob>{};
  final _previewJobs = <String, _BotsReadJob>{};
  final _roomStates = <String, BotGroupState>{};
  final _avatars = _BotAvatarCache();
  final _avatarPending = <WorkspaceScope, (int, Future<void>)>{};
  int _avatarReads = 0, _appearanceGeneration = 0;
  Completer<void>? _avatarAvailable;
  bool _avatarWakeQueued = false;
  static const _metadataAge = Duration(minutes: 5);
  Duration get _statusAge => Duration(seconds: _visible ? 10 : 30);
  bool get _avatarActive =>
      _visible ||
      _recentsReaders.isNotEmpty ||
      _avatars.borrowers.any((borrower) => borrower._demand.isNotEmpty);
  int get appearanceEpoch => _appearanceGeneration;
  int avatarContentVersion(WorkspaceScope scope) =>
      _avatars.entries[scope]?.version ?? 0;
  @visibleForTesting
  int get warmAvatarCount => _avatars.warm
      .where((scope) => _avatars.entries[scope]?.bytes != null)
      .length;
  @visibleForTesting
  int get warmAvatarBytes => _avatars.warm.fold(
    0,
    (sum, scope) => sum + (_avatars.entries[scope]?.bytes?.lengthInBytes ?? 0),
  );
  @visibleForTesting
  int get retainedAvatarCount =>
      _avatars.entries.values.where((entry) => entry.bytes != null).length;

  BotAvatarBorrower createAvatarBorrower() {
    final borrower = _BotAvatarBorrower(this);
    if (!_closed) _avatars.borrowers.add(borrower);
    return borrower;
  }

  void setSelectedAvatar(WorkspaceScope? scope) {
    if (_closed || _avatars.selected == scope) return;
    _avatars.selected = scope;
    _avatars.selectWarm();
    _wakeAvatars();
  }

  void setRecentsVisible(Object reader, bool visible) {
    if (_closed) return;
    if (visible) {
      _recentsReaders.add(reader);
    } else {
      _recentsReaders.remove(reader);
    }
    if (visible) _wakeAvatars();
  }

  /// Exact editor retirement makes its roster and asset due without fencing
  /// unrelated image reads. A generic refresh invalidates metadata only.
  void invalidateAppearances([WorkspaceScope? scope]) {
    if (_closed) return;
    for (final item in _rosterJobs.entries.toList()) {
      if (scope == null ||
          (item.key.connectionIdentity == scope.connectionIdentity &&
              item.key.connectionId == scope.connectionId)) {
        if (scope == null) {
          item.value.success = null;
        } else {
          _rosterJobs.remove(item.key);
          _readErrors.remove(item.value);
        }
      }
    }
    if (scope != null) _avatars.due(scope);
    _appearanceGeneration++;
    notifyListeners();
    _wakeAvatars();
  }

  BotRecord? cachedAppearance(ProfileSessionKey key) {
    final scope = _appearanceKeys[key];
    return scope == null ? null : _identities[scope];
  }

  /// Current metadata for an already captured profile identity. Conversation
  /// admission remains with cachedAppearance's exact root/tip index.
  BotRecord? cachedProfileAppearance(WorkspaceScope scope) =>
      _identities[scope];

  @override
  BotGroupAppearance appearanceForGroup(BotGroup group) =>
      BotGroupAppearance.forGroup(group, _identities.values);

  bool _sameMetadata(BotRecord a, BotRecord b) =>
      a.title == b.title &&
      a.shape == b.shape &&
      a.color == b.color &&
      a.revision == b.revision &&
      a.hasAvatar == b.hasAvatar &&
      a.chat == b.chat &&
      a.resolvedChat == b.resolvedChat &&
      a.canonicalLastActive == b.canonicalLastActive &&
      a.lastActive == b.lastActive &&
      a.workerLastActive == b.workerLastActive &&
      a.preview == b.preview &&
      a.presence == b.presence &&
      a.pinned == b.pinned &&
      a.hidden == b.hidden &&
      jsonEncode(a.metadata) == jsonEncode(b.metadata);

  BotRecord _cacheIdentity(BotRecord bot) {
    final old = _identities[bot.scope];
    if (old != null && _sameMetadata(old, bot)) bot = old;
    _identities[bot.scope] = bot;
    _appearanceKeys.removeWhere((_, scope) => scope == bot.scope);
    for (final key in [bot.chat, bot.resolvedChat]) {
      if (key != null) _appearanceKeys[key] = bot.scope;
    }
    _avatars.observe(bot);
    if (!identical(old, bot)) onIdentityChanged?.call(bot.scope, bot);
    return bot;
  }

  void _publishRoster(BotsRepository source, List<BotRecord> roster) {
    final scopes = roster.map((bot) => bot.scope).toSet();
    for (final scope in _identities.keys.toList()) {
      if (scope.connectionId == source.scope.connectionId &&
          scope.connectionIdentity == source.scope.connectionIdentity &&
          !scopes.contains(scope)) {
        _identities.remove(scope);
        onIdentityChanged?.call(scope, null);
        _avatars.forget(scope);
        _appearanceKeys.removeWhere((_, value) => value == scope);
      }
    }
    final previous = {
      for (final bot in _bots[source.scope.connectionIdentity] ?? <BotRecord>[])
        bot.scope: bot.presence,
    };
    _bots[source.scope.connectionIdentity] = List.unmodifiable(
      roster.map((bot) {
        final identity = _cacheIdentity(bot);
        // Metadata can publish before the independent status proof finishes.
        // Only that proof's outcome replaces an accepted presence observation.
        final presence = previous[bot.scope] ?? identity.presence;
        return presence == identity.presence
            ? identity
            : identity.withPresence(presence);
      }),
    );
    _appearanceGeneration++;
    _avatars.selectWarm();
    _publishAvatarChange();
    notifyListeners();
    _wakeAvatars();
  }

  _BotsReadJob _job<K>(
    Map<K, _BotsReadJob> jobs,
    K key,
    String error, {
    String? incident,
    bool Function()? canReport,
    bool Function()? hasReadableData,
  }) => jobs.putIfAbsent(key, () {
    final job = _BotsReadJob();
    job.onOutcome = (validated) {
      if (_closed || !identical(jobs[key], job)) return;
      final observing =
          _refreshes > 0 || _visible || _recentsReaders.isNotEmpty;
      final passiveWithReadableData =
          incident != null &&
          _explicitRefreshes == 0 &&
          hasReadableData?.call() == true;
      if (validated || passiveWithReadableData) {
        _readErrors.remove(job);
      } else if (observing) {
        _readErrors[job] = error;
      }
      if (incident != null &&
          key is WorkspaceScope &&
          canReport?.call() == true &&
          (validated || observing)) {
        onOperationalError?.call(
          OperationalErrorObservation(
            connectionIdentity: key.connectionIdentity,
            profileName: key.profileName,
            operation: '$incident:${key.profileName}',
            title: 'Bot updates unavailable',
            error: validated ? null : error,
          ),
        );
      }
      notifyListeners();
    };
    return job;
  });

  void _publishAvatarChange() {
    for (final borrower in _avatars.borrowers.toList()) {
      borrower.changed();
    }
  }

  Future<List<BotsRepository>> _loadSources(bool Function() current) async {
    if (_sourcesFailedAt != null &&
        _now().difference(_sourcesFailedAt!) < const Duration(seconds: 30)) {
      throw StateError('Saved instances are temporarily unavailable');
    }
    final pending = _appearanceSources ??= _sources(current);
    try {
      final sources = await pending;
      _sourcesFailedAt = null;
      return sources;
    } catch (_) {
      _sourcesFailedAt = _now();
      rethrow;
    } finally {
      if (identical(_appearanceSources, pending)) _appearanceSources = null;
    }
  }

  /// Explicit editor reload bypasses successful freshness, while sharing an
  /// admitted pending read and preserving the asset's failure cooldown/fences.
  Future<Uint8List?> reloadAvatar(WorkspaceScope scope) async {
    if (_closed) return null;
    final entry = _avatars.entries[scope];
    if (entry == null) return null;
    entry.due = true;
    await _readAvatar(scope);
    return _avatars.entries[scope]?.bytes;
  }

  Future<List<BotRecord>> _appearanceRoster(
    BotsRepository source, {
    Duration maxAge = _metadataAge,
  }) async {
    final generation = _readGeneration;
    final job = _job(
      _rosterJobs,
      source.scope,
      '${source.instance}: bots could not refresh.',
      incident: 'bot-roster',
      hasReadableData: () => _bots.containsKey(source.scope.connectionIdentity),
      canReport: () => _sourceCurrent(source, generation),
    );
    await job.run(_now, maxAge, () async {
      final roster = await source.bots();
      if (!_sourceCurrent(source, generation) ||
          !identical(_rosterJobs[source.scope], job)) {
        return false;
      }
      _publishRoster(source, roster);
      return true;
    });
    final rows = _bots[source.scope.connectionIdentity];
    if (rows == null) throw StateError('Bot identities unavailable');
    return rows;
  }

  bool _sourceCurrent(BotsRepository source, int generation) =>
      !_closed &&
      generation == _readGeneration &&
      (_repositories?.any((row) => row.scope == source.scope) ?? false);

  void _wakeAvatars() {
    if (_closed || _avatarWakeQueued || !_avatarActive) return;
    _avatarWakeQueued = true;
    scheduleMicrotask(() async {
      _avatarWakeQueued = false;
      if (_closed || !_avatarActive) return;
      final demands = _avatars.borrowers
          .expand((borrower) => borrower._demand)
          .toSet();
      final missing = demands
          .where((scope) => !_identities.containsKey(scope))
          .toSet();
      if (missing.isNotEmpty) {
        await identitiesForProfiles(
          missing,
          canRead: () => !_closed && _avatarActive,
        );
      }
      if (_closed) return;
      for (final scope in {..._avatars.warm, ...demands}) {
        if (_avatars.shouldRead(scope, _now())) {
          unawaited(_readAvatar(scope));
        }
      }
    });
  }

  Future<void> _readAvatar(WorkspaceScope scope) {
    final entry = _avatars.entries[scope];
    if (entry == null) return Future.value();
    final generation = entry.generation;
    final pending = _avatarPending[scope];
    if (pending != null && pending.$1 == generation) return pending.$2;
    final completion = Completer<void>();
    _avatarPending[scope] = (generation, completion.future);
    bool current() =>
        !_closed &&
        identical(_avatars.entries[scope], entry) &&
        generation == entry.generation &&
        _avatars.admitted(scope) &&
        _avatarActive &&
        _avatars.imageMode(entry.bot!);
    unawaited(() async {
      try {
        while (_avatarReads >= 3 && current()) {
          await (_avatarAvailable ??= Completer<void>()).future;
        }
        if (!current() || !_avatars.shouldRead(scope, _now())) return;
        final source = _repositories
            ?.where(
              (source) =>
                  source.scope.connectionId == scope.connectionId &&
                  source.scope.connectionIdentity == scope.connectionIdentity,
            )
            .firstOrNull;
        if (source == null) return;
        source.retain();
        _avatarReads++;
        try {
          final outcome = await source.readAvatar(entry.bot!);
          if (!current()) return;
          final hadBytes = entry.bytes != null;
          final changed = _avatars.accept(scope, outcome, _now());
          if (changed || hadBytes != (entry.bytes != null)) {
            for (final borrower in _avatars.borrowers.toList()) {
              borrower.changed();
            }
            notifyListeners();
          }
        } finally {
          source.release();
          _avatarReads--;
          final available = _avatarAvailable;
          _avatarAvailable = null;
          available?.complete();
        }
      } finally {
        if (_avatarPending[scope]?.$2 == completion.future) {
          _avatarPending.remove(scope);
        }
        completion.complete();
        if (!_closed && entry.generation != generation) _wakeAvatars();
      }
    }());
    return completion.future;
  }

  void acceptAppearance(
    BotRecord bot, {
    Uint8List? image,
    bool assetSaved = false,
  }) {
    if (_closed) return;
    for (final jobs in [_rosterJobs, _statusJobs]) {
      for (final scope
          in jobs.keys
              .where(
                (scope) =>
                    scope.connectionId == bot.scope.connectionId &&
                    scope.connectionIdentity == bot.scope.connectionIdentity,
              )
              .toList()) {
        _readErrors.remove(jobs.remove(scope));
      }
    }
    _replaceBot(bot);
    if (assetSaved) {
      _avatars.due(bot.scope);
      _avatars.accept(
        bot.scope,
        image == null
            ? const BotAvatarRead.missing()
            : BotAvatarRead.usable(image),
        _now(),
      );
      // Acknowledged content is immediate; next eligible wake validates stock.
      _avatars.entries[bot.scope]!.due = true;
    }
    _publishAvatarChange();
    _appearanceGeneration++;
    notifyListeners();
  }

  BotsSnapshot get state => BotsSnapshot(
    botsAvailable: _bots.isNotEmpty || _emptySourcesObserved,
    groupsAvailable: _groups.isNotEmpty || _emptySourcesObserved,
    bots: _rosterWithGroupActivity(),
    groups: _groups.values
        .expand((rows) => rows)
        .map((room) => room.withPinned(_groupPins.contains(room.key))),
    loading: _loading,
    busy: _busy,
    errors: [..._errors, ..._readErrors.values, ?_operationError],
    groupHosts: _ready,
    seatableProfiles: {
      for (final r in _repositories ?? <BotsRepository>[])
        r.scope.connectionIdentity: r.seatableProfiles,
    },
    instances: (_repositories ?? <BotsRepository>[]).map(
      (r) => BotInstance(r.scope.connectionIdentity, r.instance),
    ),
  );

  Iterable<BotRecord> _rosterWithGroupActivity() sync* {
    for (final bot in _bots.values.expand((rows) => rows)) {
      final groupActive =
          _groupPresenceAvailable.contains(bot.scope.connectionIdentity) &&
          (_groups[bot.scope.connectionIdentity] ?? const <BotGroup>[]).any(
            (group) =>
                group.scope.connectionId == bot.scope.connectionId &&
                group.activeMemberProfiles.contains(bot.profile.name),
          );
      yield groupActive &&
              (bot.presence == BotPresence.idle ||
                  bot.presence == BotPresence.unknown)
          ? bot.withPresence(BotPresence.groupWorking)
          : bot;
    }
  }

  void _retainRepositories(List<BotsRepository> sources) {
    for (final source in sources) {
      source.retain();
    }
    final previous = _repositories ?? <BotsRepository>[];
    for (final old in previous) {
      if (sources.any((source) => source.scope == old.scope)) continue;
      for (final jobs in [
        _rosterJobs,
        _statusJobs,
        _readinessJobs,
        _catalogJobs,
      ]) {
        final retired = jobs.remove(old.scope);
        if (retired != null) _readErrors.remove(retired);
      }
      for (final room
          in _groups[old.scope.connectionIdentity] ?? <BotGroup>[]) {
        _readErrors.remove(_stateJobs.remove(room.key));
        _readErrors.remove(_previewJobs.remove(room.key));
        _roomStates.remove(room.key);
      }
    }
    final nextObservations = sources
        .map((source) => source.groupObservations)
        .toSet();
    for (final old in _observationSources.difference(nextObservations)) {
      old.removeListener(_groupObservationsChanged);
      _groupObservationDemand.removeWhere(
        (key) => _seenGroupObservations[key]?.room.scope == old.scope,
      );
      _seenGroupObservations.removeWhere(
        (_, value) => value.room.scope == old.scope,
      );
    }
    for (final added in nextObservations.difference(_observationSources)) {
      added.addListener(_groupObservationsChanged);
    }
    _observationSources
      ..clear()
      ..addAll(nextObservations);
    _repositories = List.unmodifiable(sources);
    _groupObservationsChanged();
    for (final source in previous) {
      source.release();
    }
  }

  BotsRepository repository(String identity) {
    if (_closed) throw StateError('Bots screen closed');
    final repository = _repositories
        ?.where((r) => r.scope.connectionIdentity == identity)
        .firstOrNull;
    if (repository == null) throw StateError('Instance is unavailable');
    return repository;
  }

  /// Immutable room facts before roster-only pin decoration.
  List<BotGroup> get observedGroups =>
      List.unmodifiable(_groups.values.expand((groups) => groups));

  /// Exact immutable room observation, independent of roster pin presentation.
  BotGroup? groupForKey(String key) => _groups.values
      .expand((groups) => groups)
      .where((group) => group.key == key)
      .firstOrNull;

  /// Borrow canonical identity for live and passive room visits. References
  /// observe the same owner without starting roster or avatar reads.
  BotGroupSession openGroup(BotGroup group) {
    final preferences = _preferences;
    if (preferences == null) {
      throw StateError('Device preferences are unavailable');
    }
    final session = BotGroupSession(
      repository(group.scope.connectionIdentity),
      group,
      groupMessages: _groupMessages,
      appearances: this,
      reads: groupReads,
      preferences: preferences,
      onRead: onGroupRead,
      beforeSend: beforeGroupSend,
      afterSend: afterGroupSend,
      onOperationalError: onOperationalError,
    );
    session.addListener(() {
      if (_closed) return;
      final current = groupForKey(group.key);
      if (current != null) session.retainRecentMessages(current);
    });
    return session;
  }

  /// Screen identity is the profile, independent of its canonical conversation.
  /// Resolve actual roster metadata from the captured instance; opening a screen
  /// never creates a canonical chat or selects a different workspace.
  Future<BotScreenSession?> openScreen(
    WorkspaceScope scope, {
    required bool Function() canUse,
  }) async {
    bool current() => !_closed && canUse();
    if (!current()) return null;
    final sources = await _sources(current);
    if (!current()) return null;
    final source = sources
        .where(
          (source) =>
              source.scope.connectionId == scope.connectionId &&
              source.scope.connectionIdentity == scope.connectionIdentity,
        )
        .firstOrNull;
    if (source == null) throw StateError('Screen instance is unavailable');
    source.retain();
    try {
      final roster = await source.bots();
      if (!current()) return null;
      final bot = roster.where((bot) => bot.scope == scope).firstOrNull;
      if (bot == null) throw StateError('Screen profile is unavailable');
      return BotScreenSession(
        source,
        bot,
        onOperationalError: onOperationalError,
      );
    } finally {
      source.release();
    }
  }

  void setVisible(bool visible) {
    if (_closed || _visible == visible) return;
    _visible = visible;
    _poll?.cancel();
    _poll = null;
    if (visible) {
      unawaited(refresh(explicit: false));
      _poll = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(refresh(explicit: false)),
      );
    }
  }

  /// One passive read for the displayed conversation, independent of roster
  /// polling. Exact stock root/tip identity admits appearance; lookup failure
  /// leaves the conversation available with its ordinary title.
  Future<BotRecord?> botForConversation(ProfileSessionKey key) async {
    return (await appearancesForConversations([
      key,
    ], canRead: () => !_closed))[key];
  }

  /// Resolve a delivered sender by the stock @handle within its receiving
  /// instance. Display names alone carry no identity or asset-read authority.
  Future<BotRecord?> appearanceForSender(
    WorkspaceScope scope,
    String handle,
  ) async {
    final identities = await identitiesForProfiles([
      scope,
    ], canRead: () => !_closed);
    // Ensure the instance roster was observed; sender handles are exact stock
    // profile handles and never match display names.
    if (_closed || identities.isEmpty && _repositories == null) return null;
    final matches = _identities.values.where(
      (bot) =>
          bot.scope.connectionId == scope.connectionId &&
          bot.scope.connectionIdentity == scope.connectionIdentity &&
          (bot.profile.name == 'default' ? 'hermes' : bot.profile.name) ==
              handle,
    );
    return matches.length == 1 ? matches.single : null;
  }

  Future<Map<ProfileSessionKey, BotRecord>> appearancesForConversations(
    Iterable<ProfileSessionKey> conversations, {
    required bool Function() canRead,
  }) => _appearancesFor(
    conversations.toSet(),
    (key) => key.workspace,
    (bot, key) => bot.describesConversation(key),
    canRead: canRead,
  );

  Future<Map<WorkspaceScope, BotRecord>> appearancesForProfiles(
    Iterable<WorkspaceScope> profiles, {
    required bool Function() canRead,
  }) => identitiesForProfiles(profiles, canRead: canRead);

  Future<Map<WorkspaceScope, BotRecord>> identitiesForProfiles(
    Iterable<WorkspaceScope> profiles, {
    required bool Function() canRead,
  }) => _appearancesFor(
    profiles.toSet(),
    (scope) => scope,
    (bot, scope) => bot.scope == scope,
    canRead: canRead,
  );

  Future<Map<K, BotRecord>> _appearancesFor<K>(
    Set<K> keys,
    WorkspaceScope Function(K) workspace,
    bool Function(BotRecord, K) matches, {
    required bool Function() canRead,
  }) async {
    bool current() => !_closed && canRead();
    if (!current() || keys.isEmpty) return const {};
    try {
      final sources = await _loadSources(current);
      if (!current()) return const {};
      // Source discovery may change after an earlier empty catalog or a saved
      // connection edit. Admit its current owners before publishing their rows.
      _retainRepositories(sources);
      for (final source in sources) {
        if (!keys.any(
          (key) =>
              source.scope.connectionId == workspace(key).connectionId &&
              source.scope.connectionIdentity ==
                  workspace(key).connectionIdentity,
        )) {
          continue;
        }
        source.retain();
        try {
          await _appearanceRoster(source);
        } catch (_) {
          /* Retain usable identities. */
        } finally {
          source.release();
        }
        if (!current()) return const {};
      }
    } catch (_) {
      _appearanceSources = null;
    }
    if (!current()) return const {};
    return Map.unmodifiable({
      for (final key in keys)
        for (final bot in _identities.values)
          if (matches(bot, key)) key: bot,
    });
  }

  /// Join eligible shared image reads without widening the cache's admission
  /// or bypassing freshness, failure cooldowns and physical read limits.
  Future<void> prepareRecentsAvatars({required bool Function() canRead}) async {
    if (_closed || !_avatarActive || !canRead()) return;
    final scopes = {
      ..._avatars.warm,
      for (final borrower in _avatars.borrowers) ...borrower._demand,
    };
    await Future.wait([
      for (final scope in scopes)
        if (_avatars.shouldRead(scope, _now())) _readAvatar(scope),
    ]);
  }

  Future<void> refresh({
    bool explicit = true,
    bool retryFailures = false,
  }) async {
    if (_closed || _busy) return;
    if (retryFailures) {
      for (final jobs in [
        _rosterJobs,
        _statusJobs,
        _readinessJobs,
        _catalogJobs,
        _stateJobs,
        _previewJobs,
      ]) {
        for (final job in jobs.values) {
          if (job.failed == null) continue;
          job.failed = null;
          job.success = null;
        }
      }
    }
    final generation = _readGeneration;
    bool current() => !_closed && generation == _readGeneration;
    _refreshes++;
    if (explicit) _explicitRefreshes++;
    _loading = true;
    notifyListeners();
    try {
      await groupReads.load();
      _preferences ??= await _loadPreferences();
      if (!current()) return;
      _groupPins = _preferences!.pins;
      final sources = await _loadSources(current);
      if (!current()) return;
      _retainRepositories(sources);
      final identities = sources
          .map((source) => source.scope.connectionIdentity)
          .toSet();
      _bots.removeWhere((identity, _) => !identities.contains(identity));
      _groups.removeWhere((identity, _) => !identities.contains(identity));
      _ready.removeWhere((identity) => !identities.contains(identity));
      for (final scope in _identities.keys.toList()) {
        if (!sources.any(
          (source) =>
              source.scope.connectionIdentity == scope.connectionIdentity &&
              source.scope.connectionId == scope.connectionId,
        )) {
          _identities.remove(scope);
          _avatars.forget(scope);
          _appearanceKeys.removeWhere((_, value) => value == scope);
        }
      }
      _emptySourcesObserved = sources.isEmpty;
      _errors = const [];
      _publishAvatarChange();
      await Future.wait(
        sources.map((source) async {
          source.retain();
          try {
            await Future.wait([
              _readStatus(source, generation),
              _readReadiness(source, generation),
              _readGroups(source, generation),
            ]);
          } finally {
            source.release();
          }
        }),
      );
      _wakeAvatars();
    } catch (_) {
      if (current()) {
        _appearanceSources = null;
        _errors = ['Saved instances could not be loaded.'];
        _groupPresenceAvailable.clear();
        for (final entry in _groups.entries.toList()) {
          _groups[entry.key] = List.unmodifiable(
            entry.value.map(
              (room) =>
                  BotGroupState(room: room, roomAvailable: false).applyTo(room),
            ),
          );
        }
      }
    } finally {
      _refreshes--;
      if (explicit) _explicitRefreshes--;
      if (!_closed) {
        _loading = _refreshes > 0;
        notifyListeners();
      }
    }
  }

  Future<void> _readStatus(BotsRepository source, int generation) {
    final job = _job(
      _statusJobs,
      source.scope,
      '${source.instance}: bot activity is unavailable.',
      incident: 'bot-presence',
      hasReadableData: () => _bots.containsKey(source.scope.connectionIdentity),
      canReport: () =>
          _sourceCurrent(source, generation) &&
          _rosterJobs[source.scope]?.failed == null,
    );
    return job.run(_now, _statusAge, () async {
      await _appearanceRoster(source, maxAge: _statusAge);
      if (!_sourceCurrent(source, generation) ||
          !identical(_statusJobs[source.scope], job)) {
        return false;
      }
      final rosterJob = _rosterJobs[source.scope]!;
      if (rosterJob.failed != null) {
        final previous = _bots[source.scope.connectionIdentity];
        if (previous != null) {
          _bots[source.scope.connectionIdentity] = List.unmodifiable(
            previous.map((bot) => bot.withPresence(BotPresence.unknown)),
          );
        }
        notifyListeners();
        return false;
      }
      final roster = _bots[source.scope.connectionIdentity]!;
      final observation = await source.presence(roster);
      if (!_sourceCurrent(source, generation) ||
          !identical(_statusJobs[source.scope], job)) {
        return false;
      }
      _bots[source.scope.connectionIdentity] = List.unmodifiable(
        roster.map(
          (bot) => bot.withPresence(
            observation.values[bot.id] ?? BotPresence.unknown,
          ),
        ),
      );
      notifyListeners();
      return observation.validated;
    });
  }

  Future<void> _readReadiness(BotsRepository source, int generation) {
    final job = _job(
      _readinessJobs,
      source.scope,
      '${source.instance}: group driver is unavailable.',
      incident: 'group-driver',
      hasReadableData: () =>
          _groups.containsKey(source.scope.connectionIdentity),
      canReport: () => _sourceCurrent(source, generation),
    );
    return job.run(_now, _statusAge, () async {
      try {
        final ready = await source.groupsReady();
        if (!_sourceCurrent(source, generation) ||
            !identical(_readinessJobs[source.scope], job)) {
          return false;
        }
        if (ready) {
          _ready.add(source.scope.connectionIdentity);
        } else {
          _ready.remove(source.scope.connectionIdentity);
        }
        notifyListeners();
        return true;
      } catch (_) {
        if (_sourceCurrent(source, generation)) {
          _ready.remove(source.scope.connectionIdentity);
          notifyListeners();
        }
        return false;
      }
    });
  }

  Future<void> _readGroups(BotsRepository source, int generation) async {
    final identity = source.scope.connectionIdentity;
    final existingRooms = List<BotGroup>.of(_groups[identity] ?? []);
    final knownReads = Future.wait([
      for (final room in existingRooms) _refreshRoom(source, room, generation),
    ]);
    final catalog = _job(
      _catalogJobs,
      source.scope,
      '${source.instance}: groups could not refresh.',
      incident: 'group-roster',
      hasReadableData: () =>
          _groups.containsKey(source.scope.connectionIdentity),
      canReport: () => _sourceCurrent(source, generation),
    );
    await catalog.run(_now, _metadataAge, () async {
      final startingStates = Map<String, BotGroupState>.of(_roomStates);
      final startingMessages = {
        for (final value in source.groupObservations.values)
          value.room.id: value,
      };
      final rooms = await source.groupCatalog();
      if (!_sourceCurrent(source, generation) ||
          !identical(_catalogJobs[source.scope], catalog)) {
        return false;
      }
      final discoveredDuringRead = source.groupObservations.values
          .where(
            (value) =>
                (startingMessages[value.room.id] == null ||
                    value.latestSequence >
                        startingMessages[value.room.id]!.latestSequence) &&
                !rooms.any((room) => room.id == value.room.id),
          )
          .map((value) => value.project(value.room))
          .toList();
      final catalogRooms = [...rooms, ...discoveredDuringRead];
      final old = {
        for (final room in _groups[identity] ?? <BotGroup>[]) room.key: room,
      };
      _groups[identity] = List.unmodifiable(
        catalogRooms.map((room) {
          final previous = old[room.key];
          // Catalog establishes membership/metadata, never newer runtime/messages.
          if (previous == null) return room;
          final result = previous.withCatalogObservation(
            room,
            retainIdentity: !identical(
              startingStates[room.key],
              _roomStates[room.key],
            ),
          );
          _groupMessages?.rebind(previous, result);
          return result;
        }),
      );
      final keys = catalogRooms.map((room) => room.key).toSet();
      source.groupObservations.retainRooms(
        catalogRooms.map((room) => room.id).toSet(),
      );
      for (final key in old.keys.where((key) => !keys.contains(key))) {
        _stateJobs.remove(key);
        _previewJobs.remove(key);
        _roomStates.remove(key);
      }
      _groupPresenceAvailable.add(identity);
      notifyListeners();
      return true;
    });
    if (!_sourceCurrent(source, generation)) return;
    await Future.wait([
      knownReads,
      for (final room in List<BotGroup>.of(_groups[identity] ?? []))
        _refreshRoom(source, room, generation),
    ]);
  }

  Future<void> _refreshRoom(
    BotsRepository source,
    BotGroup room,
    int generation,
  ) async {
    bool current() =>
        _sourceCurrent(source, generation) && groupForKey(room.key) != null;
    final stateJob = _job(
      _stateJobs,
      room.key,
      '${source.instance}: group status is unavailable.',
    );
    final stateRead = stateJob.run(_now, _statusAge, () async {
      final observed = await source.groupState(groupForKey(room.key) ?? room);
      if (!current() || !identical(_stateJobs[room.key], stateJob)) {
        return false;
      }
      _roomStates[room.key] = observed;
      final previous = groupForKey(room.key)!;
      final updated = observed.applyTo(previous);
      _publishRoom(previous, updated);
      return observed.roomAvailable && observed.runtimeAvailable;
    });
    final previewJob = _job(
      _previewJobs,
      room.key,
      '${source.instance}: group messages could not refresh.',
    );
    final previewRead = previewJob.run(
      _now,
      const Duration(seconds: 30),
      () async {
        await stateRead;
        if (!current()) return false;
        final starting = groupForKey(room.key)!;
        bool admitted() =>
            current() && identical(_previewJobs[room.key], previewJob);
        final observed = await source.groupPreview(
          starting,
          state: _roomStates[room.key],
          groupMessages: _groupMessages,
          canPublish: admitted,
        );
        if (!admitted()) return false;
        final previous = groupForKey(room.key)!;
        final merged = previous.withMessageObservation(observed);
        final updated =
            source.groupObservations.forRoom(room.id)?.project(merged) ??
            merged;
        _groupMessages?.rebind(observed, updated);
        _publishRoom(previous, updated);
        return observed.observationComplete;
      },
    );
    await Future.wait([stateRead, previewRead]);
  }

  void _publishRoom(BotGroup previous, BotGroup room) {
    final identity = room.scope.connectionIdentity;
    if (room.runtimeAvailable) _groupPresenceAvailable.add(identity);
    _groups[identity] = List.unmodifiable(
      (_groups[identity] ?? []).map((old) => old.key == room.key ? room : old),
    );
    if (previous.messageCoverageSequence == room.messageCoverageSequence &&
        previous.lastMessageSequence == room.lastMessageSequence &&
        previous.lastAnswerSequence == room.lastAnswerSequence) {
      _groupMessages?.rebind(previous, room);
    }
    notifyListeners();
  }

  Future<T?> _mutate<T>(
    Future<T> Function(bool Function(), void Function()) run, {
    required bool Function() canUse,
    String? botSource,
    String? groupSource,
    String? roomKey,
  }) async {
    if (_closed || _busy || !canUse()) return null;
    void retireSource(
      Map<WorkspaceScope, _BotsReadJob> jobs,
      String? identity,
    ) {
      if (identity == null) return;
      for (final scope
          in jobs.keys
              .where((scope) => scope.connectionIdentity == identity)
              .toList()) {
        _readErrors.remove(jobs.remove(scope));
      }
    }

    retireSource(_rosterJobs, botSource ?? groupSource);
    retireSource(_statusJobs, botSource);
    retireSource(_catalogJobs, groupSource);
    if (roomKey != null) {
      _readErrors.remove(_stateJobs.remove(roomKey));
      _readErrors.remove(_previewJobs.remove(roomKey));
      _roomStates.remove(roomKey);
    }
    _loading = false;
    _busy = true;
    _operationError = null;
    var dispatched = false;
    final retained = List<BotsRepository>.of(_repositories ?? []);
    for (final source in retained) {
      source.retain();
    }
    notifyListeners();
    try {
      final value = await run(
        () => !_closed && canUse(),
        () => dispatched = true,
      );
      if (_closed || !canUse()) return null;
      return value;
    } catch (error) {
      if (!_closed) {
        _operationError =
            error is BotMetadataConflict ||
                error is BotGroupEditConflict ||
                error is BotGroupCreateRefused
            ? error.toString()
            : dispatched
            ? 'The change could not be confirmed. Check the result before trying again.'
            : 'The change was not sent. Check the instance and try again.';
      }
      return null;
    } finally {
      for (final source in retained) {
        source.release();
      }
      if (!_closed) {
        _busy = false;
        _drainGroupObservationDemand();
        notifyListeners();
        unawaited(refresh());
      }
    }
  }

  /// Open the exact captured profile's continuing chat without visiting Bots.
  Future<ProfileSessionKey?> openProfile(
    WorkspaceScope scope, {
    required bool Function() canUse,
  }) async {
    bool current() => !_closed && canUse();
    if (!current()) return null;
    // Explicit open/retry intent must not inherit passive appearance cooldowns.
    _sourcesFailedAt = null;
    for (final entry in _rosterJobs.entries) {
      if (entry.key.connectionId == scope.connectionId &&
          entry.key.connectionIdentity == scope.connectionIdentity) {
        entry.value.failed = null;
      }
    }
    final identities = await identitiesForProfiles([scope], canRead: current);
    if (!current()) return null;
    final bot = identities[scope];
    if (bot == null) throw StateError('Bot profile is unavailable');
    final key = await open(bot, canUse: current);
    if (key == null && current()) {
      throw StateError(_operationError ?? 'Bot chat could not be opened');
    }
    return key;
  }

  Future<ProfileSessionKey?> open(
    BotRecord bot, {
    required bool Function() canUse,
  }) => _mutate(
    (active, sent) async {
      final verified = await repository(
        bot.scope.connectionIdentity,
      ).openChat(bot, active, sent);
      if (active()) {
        _replaceBot(verified);
        _appearanceGeneration++;
        notifyListeners();
      }
      return verified.chat!;
    },
    canUse: canUse,
    botSource: bot.scope.connectionIdentity,
  );
  Future<bool> setPinned(
    BotRecord bot, {
    required bool Function() canUse,
  }) async =>
      await _mutate(
        (active, sent) async {
          final updated = await repository(
            bot.scope.connectionIdentity,
          ).metadata(bot, {'pinned': !bot.pinned}, active, sent);
          if (active()) _replaceBot(updated);
          return true;
        },
        canUse: canUse,
        botSource: bot.scope.connectionIdentity,
      ) ==
      true;
  Future<bool> setHidden(
    BotRecord bot, {
    required bool Function() canUse,
  }) async =>
      await _mutate(
        (active, sent) async {
          final updated = await repository(
            bot.scope.connectionIdentity,
          ).metadata(bot, {'hidden': !bot.hidden}, active, sent);
          if (active()) _replaceBot(updated);
          return true;
        },
        canUse: canUse,
        botSource: bot.scope.connectionIdentity,
      ) ==
      true;
  void _replaceBot(BotRecord bot) {
    bot = _cacheIdentity(bot);
    _avatars.selectWarm();
    final rows = _bots[bot.scope.connectionIdentity];
    if (rows != null) {
      _bots[bot.scope.connectionIdentity] = List.unmodifiable(
        rows.map((row) => row.id == bot.id ? bot : row),
      );
    }
  }

  Future<bool> setGroupPinned(
    BotGroup group, {
    required bool Function() canUse,
  }) async =>
      await _mutate((active, sent) async {
        final preferences = _preferences;
        if (preferences == null) {
          throw StateError('Device preferences are unavailable');
        }
        final pins = {..._groupPins};
        if (group.pinned) {
          pins.remove(group.key);
        } else {
          pins.add(group.key);
        }
        if (!active()) return false;
        await preferences.writePins(pins);
        if (active()) _groupPins = Set.unmodifiable(pins);
        return true;
      }, canUse: canUse) ==
      true;

  String? groupPicturePrompt(String identity, String roomId) =>
      _preferences?.picturePrompt(identity, roomId);

  Future<void> rememberGroupPicturePrompt(
    String identity,
    String roomId,
    String prompt,
  ) async {
    final preferences = _preferences;
    if (preferences == null) {
      throw StateError('Device preferences are unavailable');
    }
    await preferences.writePicturePrompt(identity, roomId, prompt);
  }

  Future<bool> createBot(
    String identity,
    String name, {
    BotRecord? clone,
    required bool Function() canUse,
  }) async {
    final target = '$identity/$name';
    if (_unconfirmedCreates.contains(target)) {
      _errors = [
        'Creation of $name is unconfirmed. Refresh and inspect the roster before creating another bot.',
      ];
      notifyListeners();
      return false;
    }
    return await _mutate(
          (active, sent) async {
            if (clone != null && clone.scope.connectionIdentity != identity) {
              throw StateError('Clone belongs to another instance');
            }
            final source = repository(identity);
            final existing = await source.bots();
            if (existing.any((bot) => bot.profile.name == name)) {
              throw StateError('That profile name already exists');
            }
            await source.create(name, clone?.profile.name, active, () {
              _unconfirmedCreates.add(target);
              sent();
            });
            _unconfirmedCreates.remove(target);
            return true;
          },
          canUse: canUse,
          botSource: identity,
        ) ==
        true;
  }

  Future<bool> createGroup(
    String identity,
    String roomId,
    String name,
    List<BotRecord> members, {
    required bool Function() canUse,
    Uint8List? picture,
    required ProfileColorChoice iconColor,
  }) async =>
      await _mutate(
        (active, sent) async {
          if (!_ready.contains(identity)) {
            throw StateError('Group driver is unavailable');
          }
          final source = repository(identity);
          await source.createGroup(roomId, name, members, active, sent);
          if (!active()) return false;
          await source.saveGroupIcon(
            roomId,
            0,
            iconColor,
            picture,
            active,
            sent,
          );
          return true;
        },
        canUse: canUse,
        groupSource: identity,
      ) ==
      true;
  Future<bool> editGroup(
    BotGroup group,
    String name,
    ProfileColorChoice color,
    Uint8List? picture,
    String renameEvent, {
    required bool Function() canUse,
  }) async =>
      await _mutate(
        (active, sent) async {
          final revision = group.iconRevision;
          if (revision == null) {
            throw StateError(
              'Group picture is unavailable. Refresh Bots and reopen Edit group.',
            );
          }
          final source = repository(group.scope.connectionIdentity);
          await source.checkGroupEdit(group, name);
          if (!active()) return false;
          final confirmedRevision = await source.saveGroupIcon(
            group.id,
            revision,
            color,
            picture,
            active,
            sent,
          );
          if (!active()) return false;
          if (name != group.name) {
            await source.groupAction(
              group,
              'rename',
              renameEvent,
              active,
              sent,
              name: name,
            );
          }
          if (!active()) return false;
          final identity = group.scope.connectionIdentity;
          _groups[identity] = (_groups[identity] ?? const <BotGroup>[])
              .map(
                (room) => room.key == group.key
                    ? room.withDetails(
                        name: name,
                        color: color,
                        picture: picture,
                        revision: confirmedRevision,
                      )
                    : room,
              )
              .toList();
          return true;
        },
        canUse: canUse,
        groupSource: group.scope.connectionIdentity,
        roomKey: group.key,
      ) ==
      true;
  Future<Uint8List> generateGroupPicture(
    String identity,
    String prompt, {
    required bool Function() canUse,
  }) async {
    final source = repository(identity);
    source.retain();
    try {
      return await source.generateGroupPicture(prompt, canUse, () {});
    } finally {
      source.release();
    }
  }

  String newRoomId() => const Uuid().v4();
  Future<bool> groupAction(
    BotGroup group,
    String action, {
    String? name,
    required bool Function() canUse,
  }) async =>
      await _mutate(
        (active, sent) async {
          await repository(group.scope.connectionIdentity).groupAction(
            group,
            action,
            const Uuid().v4(),
            active,
            sent,
            name: name,
          );
          return true;
        },
        canUse: canUse,
        groupSource: group.scope.connectionIdentity,
        roomKey: group.key,
      ) ==
      true;

  @override
  void dispose() {
    _closed = true;
    for (final source in _observationSources) {
      source.removeListener(_groupObservationsChanged);
    }
    _observationSources.clear();
    _seenGroupObservations.clear();
    _groupObservationDemand.clear();
    groupReads.dispose();
    for (final borrower in _avatars.borrowers.toList()) {
      borrower.dispose();
    }
    _avatars.entries.clear();
    _identities.clear();
    _appearanceKeys.clear();
    _avatarAvailable?.complete();
    _avatarAvailable = null;
    _readGeneration++;
    _poll?.cancel();
    for (final source in _repositories ?? <BotsRepository>[]) {
      source.release();
    }
    super.dispose();
  }
}
