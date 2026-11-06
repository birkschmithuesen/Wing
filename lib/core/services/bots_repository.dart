import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../models/bots.dart';
import '../models/profile_colors.dart';
import '../models/hermes_profile.dart';
import '../models/profile_session_key.dart';
import 'administration_repository.dart';
import 'attachment_image_preflight.dart';
import 'bot_display_client.dart';
import 'profile_gateway.dart';
import 'connection_diagnostics.dart';
import 'workspace_connection_failure.dart';
import 'hermes_voice.dart';
import '../models/bot_display.dart';
import 'recent_conversation_snapshots.dart';
import 'server_connection_status.dart';
import 'group_observations.dart';
import 'ws_client.dart';

typedef BotsRead =
    Future<Map<String, dynamic>> Function(
      String profile,
      String method,
      Map<String, dynamic> params,
    );
typedef BotsCommand =
    Future<Map<String, dynamic>> Function(
      String profile,
      String method,
      Map<String, dynamic> params,
      bool Function() canDispatch,
      void Function() onDispatched,
    );

typedef BotsOwnership =
    Future<Set<String>> Function(String profile, Iterable<String> sessions);

typedef BotsSavedHistory =
    Future<ProfileHistoryPage> Function(
      String profile,
      String session,
      int offset,
    );

final class BotPresenceObservation {
  BotPresenceObservation(
    Map<String, BotPresence> values, {
    required this.validated,
  }) : values = Map.unmodifiable(values);
  final Map<String, BotPresence> values;
  final bool validated;
}

/// Stock Hermes wire adapter. It never selects a workspace or owns an editor.
class BotsRepository {
  BotsRepository({
    required this.scope,
    required this.instance,
    required this.groupObservations,
    required this._read,
    required this._command,
    required this._ownership,
    required this._savedHistory,
    this.server,
    this.displayConnect,
    void Function()? retain,
    void Function()? release,
    DateTime Function()? now,
  }) : _retain = retain ?? _noop,
       _release = release ?? _noop,
       _now = now ?? DateTime.now;

  factory BotsRepository.forServer(
    AdministrationRepository server, {
    required GroupObservations groupObservations,
    bool Function()? isCurrent,
  }) => BotsRepository(
    scope: WorkspaceScope(
      connectionId: server.connectionId,
      connectionIdentity: server.connectionIdentity,
      profileName: 'default',
    ),
    instance: server.connectionLabel,
    groupObservations: groupObservations,
    server: server,
    displayConnect: server.displayConnect,
    retain: server.retain,
    release: server.release,
    savedHistory: (profile, session, offset) async {
      server.retain();
      try {
        final gateway = server.gateway(profile);
        await gateway.requireProfile();
        return await gateway.history(
          session,
          offset: offset,
          limit: 20,
          inlineImages: false,
        );
      } finally {
        server.release();
      }
    },
    read: (profile, method, params) async {
      server.retain();
      try {
        final gateway = server.gateway(profile);
        await gateway.connect();
        return await gateway.call(method, params);
      } finally {
        server.release();
      }
    },
    command: (profile, method, params, canDispatch, onDispatched) async {
      server.retain();
      try {
        return await server
            .gateway(profile)
            .botCommand(
              method,
              params,
              canDispatch: () => canDispatch() && (isCurrent?.call() ?? true),
              onDispatched: onDispatched,
            );
      } finally {
        server.release();
      }
    },
    ownership: (profile, sessions) async {
      server.retain();
      try {
        final found = <String>{};
        for (final id in sessions) {
          // Search resolves compression ancestors to their current tip. Only
          // exact profile-owned metadata can establish this live key's owner.
          final row = await server.gateway(profile).sessionMetadata(id);
          if (row != null) found.add(id);
        }
        return found;
      } finally {
        server.release();
      }
    },
  );
  static void _noop() {}
  final WorkspaceScope scope;
  final String instance;
  final GroupObservations groupObservations;
  final AdministrationRepository? server;
  ServerConnectionStatus? get connectionStatus =>
      server?.gateway(scope.profileName).connectionStatus;
  final Future<BotDisplayClient> Function(String ticket)? displayConnect;
  final BotsRead _read;
  final BotsCommand _command;
  final BotsOwnership _ownership;
  final BotsSavedHistory _savedHistory;
  final void Function() _retain, _release;
  final DateTime Function() _now;
  void retain() => _retain();
  void release() => _release();
  void _owns(BotRecord bot) {
    if (bot.scope.connectionIdentity != scope.connectionIdentity ||
        bot.scope.connectionId != scope.connectionId) {
      throw StateError('Bot belongs to another instance');
    }
  }

  WorkspaceScope _profileScope(String name) => WorkspaceScope(
    connectionId: scope.connectionId,
    connectionIdentity: scope.connectionIdentity,
    profileName: name,
  );

  // Only concurrent readers share this wire response. Completed roster models
  // retain bot-namespace metadata; group artwork stays with the catalog owner.
  Future<List<Map<String, dynamic>>>? _pendingProfiles;

  Future<List<Map<String, dynamic>>> _profileRows({
    bool joinPending = false,
  }) async {
    // Only catalog work joins a roster read. An explicit roster reread after a
    // mutation must never join an older, still-pending response.
    final pending = joinPending && _pendingProfiles != null
        ? _pendingProfiles!
        : _pendingProfiles = () async {
            final result = await _read('default', 'profiles.list', {
              'include_sessions': true,
            });
            if (result['bot_mode_protocol'] != true ||
                result['install_id'] is! String) {
              throw const FormatException('Invalid Bots roster');
            }
            return _rows(result['profiles']);
          }();
    try {
      return await pending;
    } finally {
      if (identical(_pendingProfiles, pending)) _pendingProfiles = null;
    }
  }

  Future<List<BotRecord>> bots() async {
    final rows = await _profileRows();
    return List.unmodifiable(
      rows.map((row) {
        final profile = HermesProfile.fromJson(row);
        final allMeta = row['ui_meta'] == null
            ? <String, dynamic>{}
            : _map(row['ui_meta']);
        final meta = allMeta['hermes-bots'] == null
            ? <String, dynamic>{}
            : _map(allMeta['hermes-bots']);
        final revisions = row['ui_meta_revisions'] == null
            ? <String, dynamic>{}
            : _map(row['ui_meta_revisions']);
        final revision = revisions['hermes-bots'] ?? 0;
        if (revision is! int || revision < 0) {
          throw const FormatException('Invalid bot revision');
        }
        final canonical = row['canonical_session'] == null
            ? null
            : _map(row['canonical_session']);
        final profileScope = _profileScope(profile.name);
        final hash = profile.name.codeUnits.fold(
          0,
          (int hash, unit) => (hash * 31 + unit) & 0xffffffff,
        );
        const defaultShapes = [
          'circle',
          'squircle',
          'pill',
          'triangle',
          'hexagon',
          'cloud',
          'drop',
        ];
        final primaryDefault =
            profile.name == 'default' && meta['custom'] != true;
        return BotRecord(
          scope: profileScope,
          instance: instance,
          profile: profile,
          title: _text(meta['title']).trim().isEmpty
              ? profile.label
              : _text(meta['title']).trim(),
          shape: primaryDefault
              ? 'squircle'
              : _text(meta['shape']).isEmpty
              ? defaultShapes[hash % defaultShapes.length]
              : _text(meta['shape']),
          color: primaryDefault ? '#8b5cf6' : _text(meta['color']),
          pinned: meta['pinned'] == true,
          hidden: meta['hidden'] == true,
          hasAvatar: row['has_avatar'] == true,
          revision: revision,
          metadata: {
            for (final entry in meta.entries) entry.key: _freeze(entry.value),
          },
          chat: canonical == null
              ? null
              : ProfileSessionKey(profileScope, _requiredText(canonical['id'])),
          resolvedChat: canonical == null || canonical['resolved_id'] == null
              ? null
              : ProfileSessionKey(
                  profileScope,
                  _requiredText(canonical['resolved_id']),
                ),
          canonicalLastActive: _sessionLastActive(canonical),
          preview: canonical == null ? '' : _text(canonical['preview']),
          workerLastActive: _workerLastActive(row['worker_session']),
          lastActive:
              [
                _sessionLastActive(canonical),
                _sessionLastActive(row['last_session']),
                _workerLastActive(row['worker_session']),
              ].whereType<DateTime>().fold<DateTime?>(
                null,
                (latest, value) =>
                    latest == null || value.isAfter(latest) ? value : latest,
              ),
        );
      }),
    );
  }

  Future<BotPresenceObservation> presence(List<BotRecord> roster) async {
    for (final bot in roster) {
      _owns(bot);
    }
    final now = _now();
    final unavailable = {
      for (final bot in roster)
        bot.id: _workerIsActive(bot, now)
            ? BotPresence.working
            : BotPresence.unknown,
    };
    try {
      // Stock active_list is process-wide and carries no profile owner.
      // Prove unique ownership in every profile's hidden-inclusive store first.
      final live = _rows(
        (await _read('default', 'session.active_list', {}))['sessions'],
      );
      final keys = <String>{};
      for (final row in live) {
        keys.add(_requiredText(row['session_key']));
        _requiredText(row['id']);
        _requiredText(row['status']);
      }
      final owners = <String, Set<String>>{};
      for (final bot in roster) {
        owners[bot.id] = await _ownership(bot.profile.name, keys);
      }
      return BotPresenceObservation({
        for (final bot in roster) bot.id: _presenceFor(bot, live, owners, now),
      }, validated: true);
    } catch (_) {
      return BotPresenceObservation(unavailable, validated: false);
    }
  }

  BotPresence _presenceFor(
    BotRecord bot,
    List<Map<String, dynamic>> live,
    Map<String, Set<String>> owners,
    DateTime now,
  ) {
    final keys = owners[bot.id]!;
    if (keys.any(
      (key) => owners.values.where((ids) => ids.contains(key)).length != 1,
    )) {
      return BotPresence.unknown;
    }
    final matching = live.where((row) => keys.contains(row['session_key']));
    return matching.any((r) => r['status'] == 'waiting')
        ? BotPresence.needsInput
        : matching.any(
                (r) => r['status'] == 'working' || r['status'] == 'starting',
              ) ||
              _workerIsActive(bot, now)
        ? BotPresence.working
        : BotPresence.idle;
  }

  // Stock workers heartbeat at least every 60 s. Match the desktop's 150 s
  // window so one delayed heartbeat does not park a working bot's avatar.
  bool _workerIsActive(BotRecord bot, DateTime now) {
    final lastActive = bot.workerLastActive;
    if (lastActive == null) return false;
    final age = now.difference(lastActive);
    return age >= Duration.zero && age < const Duration(seconds: 150);
  }

  DateTime? _workerLastActive(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['source'] is! String ||
        (value['source'] as String).isEmpty) {
      return null;
    }
    return _sessionLastActive(value);
  }

  DateTime? _sessionLastActive(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty) {
      return null;
    }
    final timestamp = value['last_active'];
    if (timestamp is! num || !timestamp.isFinite || timestamp <= 0) return null;
    final milliseconds = timestamp * 1000;
    if (!milliseconds.isFinite || milliseconds > 8640000000000000) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds.round(),
      isUtc: true,
    );
  }

  /// Stock asset absence is distinct from an unavailable/invalid response.
  Future<BotAvatarRead> readAvatar(BotRecord bot) async {
    _owns(bot);
    try {
      final result = await _read(bot.profile.name, 'profiles.get_asset', {
        'name': bot.profile.name,
        'asset': 'avatar',
      });
      if (result['found'] == false) return const BotAvatarRead.missing();
      if (result['found'] != true) return const BotAvatarRead.unavailable();
      final bytes = _image(result['data'], maxBytes: 2000000);
      return BotAvatarRead.usable(bytes);
    } catch (_) {
      return const BotAvatarRead.unavailable();
    }
  }

  Future<BotRecord> metadata(
    BotRecord bot,
    Map<String, Object?> patch,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    _owns(bot);
    final result = await _command(
      bot.profile.name,
      'profiles.configure',
      {
        'name': bot.profile.name,
        'ui_meta': {
          'hermes-bots': {...bot.metadata, ...patch},
        },
        'ui_meta_expected_revisions': {'hermes-bots': bot.revision},
      },
      canDispatch,
      onDispatched,
    );
    final applied = _map(result['applied']);
    if (applied['ui_meta_conflicts'] != null) throw const BotMetadataConflict();
    if (applied['ui_meta'] != true) {
      throw StateError('Bot appearance was not saved');
    }
    final revisions = _map(applied['ui_meta_revisions']);
    final revision = revisions['hermes-bots'];
    if (revision is! int || revision <= bot.revision) {
      throw const FormatException('Invalid saved metadata revision');
    }
    return bot.withMetadata(
      metadata: {...bot.metadata, ...patch},
      revision: revision,
      title: patch['title'] as String?,
      shape: patch['shape'] as String?,
      color: patch['color'] as String?,
      pinned: patch['pinned'] as bool?,
      hidden: patch['hidden'] as bool?,
    );
  }

  Future<void> avatar(
    BotRecord bot,
    Uint8List? image,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    _owns(bot);
    if (image != null) {
      if (image.length > 2000000) {
        throw StateError('Choose an image smaller than 2 MB');
      }
      inspectAttachmentImage(image);
    }
    final result = await _command(
      bot.profile.name,
      'profiles.set_asset',
      {
        'name': bot.profile.name,
        'asset': 'avatar',
        if (image == null) 'clear': true else 'data': base64Encode(image),
      },
      canDispatch,
      onDispatched,
    );
    if (result['ok'] != true) throw StateError('Avatar was not saved');
  }

  Future<Uint8List> generateAvatar(
    BotRecord bot,
    String prompt,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    _owns(bot);
    return _generateImage(
      bot.profile.name,
      prompt,
      'bot_avatar',
      'Image generation did not complete',
      2000000,
      canDispatch,
      onDispatched,
    );
  }

  Future<Uint8List> generateGroupPicture(
    String prompt,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) => _generateImage(
    'default',
    prompt,
    'group_picture',
    'Room picture generation did not complete',
    maxRoomPictureInputBytes,
    canDispatch,
    onDispatched,
  );

  Future<Uint8List> _generateImage(
    String profile,
    String prompt,
    String operation,
    String failureMessage,
    int maxBytes,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    final elapsed = Stopwatch()..start();
    var stage = 'request', failure = 'request_failed';
    Map<String, dynamic>? result;
    try {
      result = await _command(
        profile,
        'image.generate',
        {'prompt': prompt, 'aspect_ratio': 'square', 'max_bytes': maxBytes},
        canDispatch,
        onDispatched,
      );
      stage = 'provider';
      failure = result['available'] == false
          ? 'provider_unavailable'
          : 'generation_failed';
      if (result['success'] != true) throw StateError(failureMessage);
      stage = 'transfer';
      failure = 'image_data_missing';
      final data = result['image_data'];
      if (data is String && data.trim().isNotEmpty) {
        stage = 'decode';
        failure = 'invalid_image_data';
      }
      return _image(data, maxBytes: maxBytes);
    } catch (error, stack) {
      logConnectionDiagnostic(
        'bots.image_generation_failed',
        details: {
          'connection': scope.connectionId,
          'profile': profile,
          'operation': operation,
          'stage': stage,
          'failure': failure,
          'elapsed_ms': elapsed.elapsedMilliseconds,
          if (result?['available'] is bool) 'available': result!['available'],
          if (result?['success'] is bool) 'success': result!['success'],
          if (result != null) ...{
            'image_data_present': result['image_data'] is String,
            'image_reference_present': result['image'] is String,
          },
          ...workspaceFailureDiagnostic(error),
        },
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<BotRecord> openChat(
    BotRecord bot,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    _owns(bot);
    // Re-resolve server-owned identity; a menu observation may have aged.
    final current = (await bots())
        .where((row) => row.profile.name == bot.profile.name)
        .firstOrNull;
    if (current == null) throw StateError('Bot no longer exists');
    if (current.chat != null) return current;
    try {
      final created = await _command(
        bot.profile.name,
        'session.create',
        {
          'title': 'Bot Chat',
          'hidden': true,
          'follow_profile_config': true,
          'source': 'gui',
        },
        canDispatch,
        onDispatched,
      );
      // Canonical titled creation commits the title and hidden flag atomically.
      _requiredText(created['session_id']);
    } catch (error) {
      // A concurrent desktop creation or lost acknowledgement may have won.
      final resolved = (await bots())
          .where((row) => row.profile.name == bot.profile.name)
          .firstOrNull;
      if (resolved?.chat != null) return resolved!;
      rethrow;
    }
    final resolved = (await bots())
        .where((row) => row.profile.name == bot.profile.name)
        .firstOrNull;
    if (resolved?.chat == null) {
      throw StateError(
        'Bot Chat was not confirmed. Refresh before trying again.',
      );
    }
    return resolved!;
  }

  Future<void> create(
    String name,
    String? clone,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    if (!HermesProfile.isCanonicalName(name)) {
      throw ArgumentError(
        'Use lowercase letters, numbers, hyphens or underscores (up to 64 characters).',
      );
    }
    final result = await _command(
      'default',
      'profiles.create',
      {
        'name': name,
        'clone_from': ?clone,
        'clone_all': clone != null,
        'clone_channels': false,
        'mirror_credentials': clone == null,
      },
      canDispatch,
      onDispatched,
    );
    if (result['ok'] != true) {
      throw StateError('Bot creation was not confirmed');
    }
  }

  Set<String> _groupMethods = const {};
  Future<bool> groupsReady() async {
    final capabilities = await _read('default', 'groups.capabilities', {});
    final driver = capabilities['driver'];
    final methods = capabilities['methods'];
    _groupMethods =
        methods is List && methods.every((method) => method is String)
        ? Set.unmodifiable(methods.cast<String>())
        : const {};
    if (driver is! bool) {
      throw const FormatException('Invalid group driver readiness');
    }
    return driver;
  }

  // Stock profiles.configure caps each incoming ui_meta document at 65,536
  // Python JSON characters. 45 KB leaves room for base64 and the ASCII envelope.
  static const groupPictureMaxBytes = 45000;
  static const _groupIconPrefix = 'wing-group-icon:';
  static bool _sameGroupIcon(Object? value, Map<String, Object> expected) =>
      value is Map &&
      value['version'] == 1 &&
      value['color'] == expected['color'] &&
      value['data'] == expected['data'];

  Future<Map<String, dynamic>?> _groupIconProfile() async {
    final result = await _read('default', 'profiles.list', {
      'include_sessions': false,
    });
    return _rows(
      result['profiles'],
    ).where((row) => row['name'] == 'default').firstOrNull;
  }

  /// Persist a hosted room's palette color and optional picture on Hermes.
  /// The initial is rendered from its current name. Each room has its own CAS
  /// key so other rooms are not rewritten. A retry confirms an already saved
  /// icon without another upload. Nothing is persisted on the device.
  Future<int> saveGroupIcon(
    String roomId,
    int expectedRevision,
    ProfileColorChoice color,
    Uint8List? picture,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    if ((picture?.length ?? 0) > groupPictureMaxBytes ||
        roomId.length > 128 ||
        color.slot == null) {
      throw ArgumentError('Room picture exceeds the backend upload limit');
    }
    if (picture != null) inspectAttachmentImage(picture);
    if (!canDispatch()) throw StateError('Room save is no longer active');
    final key = '$_groupIconPrefix$roomId';
    final value = <String, Object>{
      'version': 1,
      'color': color.slot!,
      if (picture != null) 'data': base64Encode(picture),
    };
    final row = await _groupIconProfile();
    if (!canDispatch()) throw StateError('Room save is no longer active');
    if (row == null) throw StateError('Hermes default profile is unavailable');
    final meta = row['ui_meta'] == null
        ? <String, dynamic>{}
        : _map(row['ui_meta']);
    final revisions = _map(row['ui_meta_revisions']);
    final revision = revisions[key] ?? 0;
    if (revision is! int || revision < 0) {
      throw const FormatException('Invalid room picture revision');
    }
    if (_sameGroupIcon(meta[key], value)) return revision;
    if (revision != expectedRevision) {
      throw const BotGroupEditConflict(
        'Group picture changed on Hermes. Reopen Edit group to review it.',
      );
    }
    final result = await _command(
      'default',
      'profiles.configure',
      {
        'name': 'default',
        'ui_meta': {key: value},
        'ui_meta_expected_revisions': {key: revision},
      },
      canDispatch,
      onDispatched,
    );
    final applied = _map(result['applied']);
    if (applied['ui_meta_conflicts'] != null) {
      throw StateError('Room picture changed on Hermes. Retry to confirm it.');
    }
    if (applied['ui_meta'] != true ||
        _map(applied['ui_meta_revisions'])[key] != revision + 1) {
      throw StateError('Room picture was not saved to Hermes');
    }
    if (!canDispatch()) throw StateError('Room save is no longer active');
    final saved = await _groupIconProfile();
    if (saved == null ||
        _map(saved['ui_meta_revisions'])[key] != revision + 1 ||
        !_sameGroupIcon(_map(saved['ui_meta'])[key], value)) {
      throw StateError('Room picture could not be confirmed on Hermes');
    }
    return revision + 1;
  }

  /// Shared stock room discovery for group routes and room-delivery pickers.
  static Future<List<BotGroup>> readRoomCatalog({
    required BotsRead read,
    required WorkspaceScope scope,
    required String instance,
  }) async {
    final groups = <BotGroup>[];
    var offset = 0;
    do {
      final result = await read('default', 'groups.list', {
        'limit': 100,
        'offset': offset,
      });
      groups.addAll(
        _rows(result['rooms']).map((row) => decodeGroup(scope, instance, row)),
      );
      final next = result['next_offset'];
      if (next == null) break;
      if (next is! int || next <= offset) {
        throw const FormatException('Invalid group cursor');
      }
      offset = next;
    } while (true);
    return List.unmodifiable(groups);
  }

  /// Catalog discovery carries identities and pictures, never runtime or logs.
  Future<List<BotGroup>> groupCatalog() async {
    final profiles = await _profileRows(joinPending: true);
    final groups = await readRoomCatalog(
      read: _read,
      scope: scope,
      instance: instance,
    );
    if (groups.isEmpty) return List.unmodifiable(groups);
    try {
      final row = profiles.where((row) => row['name'] == 'default').firstOrNull;
      if (row == null) return List.unmodifiable(groups);
      final meta = _map(row['ui_meta']);
      final revisions = _map(row['ui_meta_revisions']);
      BotGroup decorate(BotGroup room) {
        try {
          final key = '$_groupIconPrefix${room.id}';
          final revision = revisions[key] ?? 0;
          if (revision is! int || revision < 0) return room;
          final value = meta[key];
          if (value == null) return room.withIcon(revision: revision);
          final picture = _map(value);
          final data = picture['data'];
          final slot = picture['color'];
          if (picture['version'] != 1 ||
              slot is! int ||
              slot < 0 ||
              slot >= 12 ||
              (data != null && (data is! String || data.length > 60000))) {
            return room;
          }
          return room.withIcon(
            picture: data == null ? null : _image(data, maxBytes: 2000000),
            color: ProfileColorChoice.values[slot + 1],
            revision: revision,
          );
        } catch (_) {
          // Invalid decoration cannot prevent access to the hosted room.
          return room;
        }
      }

      return List.unmodifiable(groups.map(decorate));
    } catch (_) {
      // The next roster refresh re-reads server pictures; no disk cache exists.
      return List.unmodifiable(groups);
    }
  }

  /// An unavailable driver never fabricates idle or positive member admission.
  Future<BotGroupState> groupState(BotGroup group) async {
    _ownsGroup(group);
    try {
      final result = await _read('default', 'groups.state', {
        'room_id': group.id,
      });
      final decoded = decodeGroupState(scope, instance, group.id, result);
      if (decoded.room == null) {
        return BotGroupState(room: group, roomAvailable: false);
      }
      final runtime = decoded.runtime;
      return BotGroupState(
        room: decoded.room!,
        roomAvailable: true,
        latestSequence: decoded.latestSequence,
        runtimeAvailable: runtime != null,
        working: runtime?.working ?? false,
        memberActivity: runtime?.memberActivity ?? const [],
        blocked:
            runtime != null && (runtime.blocked || runtime.actions.isNotEmpty),
      );
    } catch (_) {
      return BotGroupState(room: group, roomAvailable: false);
    }
  }

  /// Capture message facts independently, reusing an admitted room observation.
  Future<BotGroup> groupPreview(
    BotGroup group, {
    BotGroupState? state,
    required RecentGroupMessages? groupMessages,
    required bool Function() canPublish,
  }) async {
    _ownsGroup(group);
    final observed = state ?? await groupState(group);
    final current = observed.applyTo(group);
    final latest = observed.latestSequence;
    BotGroup unavailable() => BotGroup(
      scope: current.scope,
      instance: current.instance,
      id: current.id,
      name: current.name,
      members: current.members,
      observationComplete: false,
      runtimeAvailable: current.runtimeAvailable,
      latestSequence: current.latestSequence,
      messageCoverageSequence: current.messageCoverageSequence,
      preview: current.preview,
      working: current.working,
      blocked: current.blocked,
      activeMemberProfiles: current.activeMemberProfiles,
      lastMessageAt: current.lastMessageAt,
      lastMessageSequence: current.lastMessageSequence,
      lastAnswerSequence: current.lastAnswerSequence,
      pinned: current.pinned,
      picture: current.picture,
      iconColor: current.iconColor,
      iconRevision: current.iconRevision,
    );
    if (!observed.roomAvailable || latest == null || !canPublish()) {
      return unavailable();
    }
    if (group.observationComplete && group.messageCoverageSequence == latest) {
      return current;
    }
    final recentMessages = <BotGroupEvent>[];
    BotGroupEvent? message, answer;
    var end = latest;
    final observation = groupObservations.beginRead(current);
    try {
      // Scan backwards until both newest message and bot reply are established.
      while (end > 0 && (message == null || answer == null)) {
        final start = (end - 100).clamp(0, end);
        final events = await _readGroupLogWindow(
          current,
          start: start,
          end: end,
          canRead: canPublish,
          observation: observation,
        );
        recentMessages.insertAll(0, events.where((e) => e.isTranscriptEntry));
        for (final event
            in events.where((e) => e.isMessage).toList().reversed) {
          message ??= event;
          if (event.kind == 'message.member' && event.text.trim().isNotEmpty) {
            answer ??= event;
          }
        }
        end = start;
      }
      final updated = BotGroup(
        scope: current.scope,
        instance: current.instance,
        id: current.id,
        name: current.name,
        members: current.members,
        observationComplete: true,
        runtimeAvailable: current.runtimeAvailable,
        latestSequence: latest,
        messageCoverageSequence: latest,
        preview: message?.text ?? '',
        working: current.working,
        blocked: current.blocked,
        activeMemberProfiles: current.activeMemberProfiles,
        lastMessageAt: message?.timestamp,
        lastMessageSequence: message?.sequence ?? 0,
        lastAnswerSequence: answer?.sequence ?? 0,
        pinned: current.pinned,
        picture: current.picture,
        iconColor: current.iconColor,
        iconRevision: current.iconRevision,
      );
      if (!canPublish()) return unavailable();
      groupMessages?.record(updated, recentMessages, complete: end == 0);
      return updated;
    } catch (_) {
      return unavailable();
    } finally {
      if (canPublish()) observation.publish();
    }
  }

  BotGroup _group(Map<String, dynamic> row) =>
      decodeGroup(scope, instance, row);

  static BotGroup decodeGroup(
    WorkspaceScope scope,
    String instance,
    Map<String, dynamic> row,
  ) => BotGroup(
    scope: scope,
    instance: instance,
    id: _requiredText(row['room_id']),
    name: _requiredText(row['name']),
    observationComplete: false,
    members: _rows(row['members']).map(
      (m) => BotGroupMember(
        id: _requiredText(m['member_id']),
        profile: _requiredText(m['profile']),
        handle: _requiredText(m['handle']),
        name: _text(m['display_name']).isEmpty
            ? _requiredText(m['profile'])
            : _text(m['display_name']),
      ),
    ),
  );
  void _ownsGroup(BotGroup group) {
    if (group.scope != scope) {
      throw StateError('Group belongs to another instance');
    }
  }

  /// Groups belong to the instance's default profile, like their stock RPCs.
  RemoteVoice voiceForGroup(BotGroup group) {
    _ownsGroup(group);
    final connection = server;
    if (connection == null) {
      throw StateError('This group has no speech connection. Reopen it.');
    }
    var closed = false;
    return HermesVoice(
      profile: 'default',
      closeClient: () => closed = true,
      request: (endpoint, body) async {
        connection.retain();
        try {
          if (closed) throw StateError('Recording canceled.');
          final result = await connection
              .ownedMutation(
                'POST',
                Uri.parse(endpoint).path,
                const {'profile': 'default'},
                body,
                () => !closed,
                () {},
              )
              .timeout(const Duration(minutes: 3));
          if (closed) throw StateError('Recording canceled.');
          return result;
        } on AdministrationFailure catch (failure) {
          throw StateError(failure.message);
        } finally {
          connection.release();
        }
      },
    );
  }

  /// Exact stock worker identity. Discovery never creates or resumes a runtime.
  Future<String?> groupMemberSession(
    BotGroup group,
    BotGroupMember member,
  ) async {
    _ownsGroup(group);
    if (!group.members.any(
      (candidate) =>
          candidate.id == member.id && candidate.profile == member.profile,
    )) {
      throw StateError('Bot does not belong to this group');
    }
    final title = 'Group: ${group.id}';
    final result = await _read(member.profile, 'session.list', {
      'title': title,
      'include_hidden': true,
    });
    final rows = _rows(result['sessions']);
    if (rows.isEmpty) return null;
    if (rows.length != 1 ||
        rows.single['title'] != title ||
        rows.single['source'] != 'bot_room') {
      throw const FormatException('Invalid group worker identity');
    }
    _requiredText(rows.single['id']);
    return _requiredText(rows.single['resolved_id']);
  }

  Future<ProfileHistoryPage> groupMemberHistory(
    BotGroup group,
    BotGroupMember member,
    String session,
    int offset,
  ) async {
    _ownsGroup(group);
    if (!group.members.any(
          (candidate) =>
              candidate.id == member.id && candidate.profile == member.profile,
        ) ||
        session.isEmpty ||
        offset < 0) {
      throw ArgumentError('Invalid group history owner');
    }
    final page = await _savedHistory(member.profile, session, offset);
    if (page.sessionId != session || page.offset != offset) {
      throw const FormatException(
        'Group worker history changed. Refresh to read it.',
      );
    }
    return page;
  }

  /// Mount only the stock read-only child subscription; never prompt an agent.
  Future<Map<String, dynamic>> watchSubagent(
    BotGroup group,
    BotGroupMember member,
    String child,
  ) {
    _ownsGroup(group);
    if (child.isEmpty ||
        !group.members.any(
          (candidate) =>
              candidate.id == member.id && candidate.profile == member.profile,
        )) {
      throw ArgumentError('Invalid subagent observation');
    }
    return _read(member.profile, 'session.resume', {
      'session_id': child,
      'display_projection': true,
    });
  }

  /// Passive reads and canonical subscriptions only; never controls the worker.
  Future<Map<String, dynamic>> groupMemberObservation(
    BotGroup group,
    BotGroupMember member,
    String method,
    Map<String, dynamic> params,
  ) {
    _ownsGroup(group);
    if (!group.members.any(
          (candidate) =>
              candidate.id == member.id && candidate.profile == member.profile,
        ) ||
        !const {
          'session.active_list',
          'session.resume',
          'session.events.since',
        }.contains(method)) {
      throw ArgumentError('Invalid worker observation');
    }
    return _read(member.profile, method, params);
  }

  Future<BotGroupPage> groupLog(BotGroup group, {int since = 0}) async {
    _ownsGroup(group);
    final result = await _read('default', 'groups.log', {
      'room_id': group.id,
      'since_seq': since,
      'limit': 100,
    });
    return decodeGroupLog(group.id, result, since: since);
  }

  static BotGroupPage decodeGroupLog(
    String roomId,
    Map<String, dynamic> result, {
    required int since,
  }) {
    final cursor = result['cursor'];
    if (cursor is! int ||
        cursor < since ||
        result['has_more'] is! bool ||
        (result['has_more'] == true && cursor == since)) {
      throw const FormatException('Invalid group log cursor');
    }
    final authority = _map(result['authority']);
    _requiredText(authority['gateway_id']);
    final epoch = authority['epoch'];
    final latest = result['latest_seq'];
    if (epoch is! int || epoch < 1 || latest is! int || latest < cursor) {
      throw const FormatException('Invalid group log authority');
    }
    var previous = since;
    return BotGroupPage(
      _rows(result['events']).map((row) {
        final seq = row['seq'];
        if (row['room_id'] != roomId ||
            seq is! int ||
            seq <= previous ||
            seq > cursor) {
          throw const FormatException('Invalid group event owner');
        }
        previous = seq;
        final actor = _map(row['actor']);
        final payload = _map(row['payload']);
        final kind = _requiredText(row['kind']);
        if ((kind == 'message.member' || kind == 'message.user') &&
            payload['text'] is! String) {
          throw const FormatException('Invalid group message text');
        }
        if (kind == 'turn.settled' && payload['passed'] is! bool) {
          throw const FormatException('Invalid group turn pass status');
        }
        final passedMemberId =
            kind == 'turn.settled' && payload['passed'] == true
            ? _requiredText(payload['member_id'])
            : null;
        final created = row['created_at'];
        if (created is! num ||
            !created.isFinite ||
            created.abs() > 8640000000000) {
          throw const FormatException('Invalid group event time');
        }
        return BotGroupEvent(
          sequence: seq,
          eventId: _requiredText(row['event_id']),
          kind: kind,
          actor: _text(actor['profile']).isEmpty
              ? _text(actor['kind'])
              : _text(actor['profile']),
          actorId: _requiredText(actor['id']),
          actorName: _text(actor['display_name']),
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            (created * 1000).round(),
          ),
          text: _text(payload['text']),
          threadId: _text(payload['thread_id']),
          discussionEventId: _text(payload['discussion_event_id']),
          activityStatus: _text(payload['status']),
          cancelId: _text(payload['cancel_id']),
          continueGrant: payload['grant'] is int ? payload['grant'] as int : 0,
          passedMemberId: passedMemberId,
          attachments: List.unmodifiable([
            for (final item in _rows(payload['attachments'] ?? const []))
              BotGroupAttachment.fromJson(item),
          ]),
        );
      }),
      cursor,
      result['has_more'] as bool,
      latestSequence: latest,
      gatewayId: _requiredText(authority['gateway_id']),
      epoch: epoch,
    );
  }

  /// Cover one captured sequence window, including byte-shortened stock pages.
  /// New arrivals beyond its end belong to a later observation.
  Future<List<BotGroupEvent>> groupLogWindow(
    BotGroup group, {
    required int start,
    required int end,
    required bool Function() canRead,
  }) async {
    final observation = groupObservations.beginRead(group);
    try {
      return await _readGroupLogWindow(
        group,
        start: start,
        end: end,
        canRead: canRead,
        observation: observation,
      );
    } finally {
      if (canRead()) observation.publish();
    }
  }

  Future<List<BotGroupEvent>> _readGroupLogWindow(
    BotGroup group, {
    required int start,
    required int end,
    required bool Function() canRead,
    required GroupObservationRead observation,
  }) async {
    _ownsGroup(group);
    if (start < 0 || end <= start || end - start > 100) {
      throw ArgumentError('Invalid group log window');
    }
    final events = <BotGroupEvent>[];
    var cursor = start;
    while (cursor < end) {
      if (!canRead()) throw StateError('Group read retired');
      final page = await groupLog(group, since: cursor);
      if (!canRead()) throw StateError('Group read retired');
      if (page.cursor <= cursor || (!page.hasMore && page.cursor < end)) {
        throw const FormatException('Group log window is incomplete');
      }
      final covered = page.cursor < end ? page.cursor : end;
      observation.add(
        BotGroupPage(
          page.events.where((event) => event.sequence <= covered),
          covered,
          false,
          latestSequence: page.latestSequence,
          gatewayId: page.gatewayId,
          epoch: page.epoch,
        ),
        since: cursor,
      );
      events.addAll(page.events.where((event) => event.sequence <= end));
      cursor = page.cursor;
    }
    return List.unmodifiable(events);
  }

  Future<void> createGroup(
    String id,
    String name,
    List<BotRecord> members,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    if (members.length < 2 || members.length > 6 || name.trim().isEmpty) {
      throw ArgumentError('Choose 2–6 bots and name the group.');
    }
    for (final bot in members) {
      _owns(bot);
    }
    final result = await _command(
      'default',
      'groups.create',
      {
        'room_id': id,
        'name': name.trim(),
        'members': [
          for (final bot in members)
            {
              'member_id': bot.profile.name,
              'profile': bot.profile.name,
              'handle': 'bot_${bot.profile.name}',
              'display_name': bot.title,
              'target': {'kind': 'local', 'profile': bot.profile.name},
            },
        ],
      },
      canDispatch,
      onDispatched,
    );
    if (_map(result['room'])['room_id'] != id) {
      throw const FormatException('Group creation identity mismatch');
    }
  }

  /// Stock hashes the immutable client retry key into its user-event namespace.
  static String groupUserEventId(String event) =>
      'user:${sha256.convert(utf8.encode(event))}';

  Future<int> sendGroup(
    BotGroup group,
    String event,
    String text,
    bool Function() canDispatch,
    void Function() onDispatched, {
    List<BotGroupAttachment> attachments = const [],
  }) async {
    _ownsGroup(group);
    final Map<String, dynamic> result;
    try {
      result = await _command(
        'default',
        'groups.send',
        {
          'room_id': group.id,
          'event_id': event,
          'payload': {
            'text': text,
            'thread_id': event,
            if (attachments.isNotEmpty)
              'attachments': attachments.map((item) => item.toJson()).toList(),
          },
        },
        canDispatch,
        onDispatched,
      );
    } on JsonRpcError catch (error) {
      if (error.method == 'groups.send' && error.data['admitted'] == false) {
        throw BotGroupSendRefused(error.message);
      }
      rethrow;
    }
    if (result['accepted'] != true || result['client_event_id'] != event) {
      throw StateError('Group message was not confirmed');
    }
    final saved = _map(result['event']);
    final sequence = saved['seq'];
    if (saved['room_id'] != group.id ||
        saved['event_id'] != groupUserEventId(event) ||
        saved['kind'] != 'message.user' ||
        sequence is! int ||
        sequence < 1) {
      throw const FormatException('Invalid group send receipt');
    }
    return sequence;
  }

  Future<BotGroupAttachment> uploadGroupAttachment(
    BotGroup group, {
    required String uploadId,
    required String name,
    required String mime,
    required String kind,
    required String dataBase64,
    required bool Function() canDispatch,
  }) async {
    _ownsGroup(group);
    final result = await _command(
      'default',
      'groups.attachment.upload',
      {
        'room_id': group.id,
        'upload_id': uploadId,
        'name': name,
        'mime': mime,
        'kind': kind,
        'data_base64': dataBase64,
      },
      canDispatch,
      () {},
    );
    return BotGroupAttachment.fromJson(result);
  }

  Future<Uint8List> downloadGroupAttachment(
    BotGroup group,
    String eventId,
    BotGroupAttachment attachment,
  ) async {
    _ownsGroup(group);
    final result = await _read('default', 'groups.attachment.download', {
      'room_id': group.id,
      'event_id': eventId,
      'attachment_id': attachment.id,
    });
    final returned = BotGroupAttachment.fromJson(result);
    if (returned.id != attachment.id ||
        returned.size != attachment.size ||
        returned.name != attachment.name ||
        returned.mime != attachment.mime ||
        result['event_id'] != eventId ||
        result['data_base64'] is! String) {
      throw const FormatException('Group attachment identity mismatch');
    }
    final bytes = base64Decode(result['data_base64'] as String);
    if (bytes.length != attachment.size) {
      throw const FormatException('Incomplete group attachment');
    }
    return bytes;
  }

  Future<({BotGroupRuntime runtime, int sequence})> groupRuntime(
    BotGroup group,
  ) async {
    _ownsGroup(group);
    await groupsReady();
    final result = await _read('default', 'groups.state', {
      'room_id': group.id,
    });
    final decoded = decodeGroupState(
      scope,
      instance,
      group.id,
      result,
      methods: _groupMethods,
    );
    final runtime = decoded.runtime;
    if (runtime == null) {
      throw const FormatException('Group runtime unavailable');
    }
    return (runtime: runtime, sequence: decoded.latestSequence);
  }

  static ({BotGroup? room, int latestSequence, BotGroupRuntime? runtime})
  decodeGroupState(
    WorkspaceScope scope,
    String instance,
    String roomId,
    Map<String, dynamic> result, {
    Set<String> methods = const {},
  }) {
    final row = _map(result['room']);
    if (row['room_id'] != roomId) {
      throw const FormatException('Wrong group state owner');
    }
    if (row['disbanded_at'] != null) {
      final value = row['disbanded_at'];
      if (value is! num || !value.isFinite) {
        throw const FormatException('Invalid group disband receipt');
      }
      return (room: null, latestSequence: 0, runtime: null);
    }
    final room = decodeGroup(scope, instance, row);
    final latest = row['latest_seq'];
    if (latest is! int || latest < 0) {
      throw const FormatException('Invalid group sequence');
    }
    BotGroupRuntime? runtime;
    try {
      runtime = _decodeGroupRuntime(result, methods);
    } on FormatException {
      /* Room facts remain usable. */
    }
    return (room: room, latestSequence: latest, runtime: runtime);
  }

  static BotGroupRuntime _decodeGroupRuntime(
    Map<String, dynamic> result,
    Set<String> methods,
  ) {
    final status = _map(result['driver_status']);
    if (status['working'] is! bool || status['blocked'] is! bool) {
      throw const FormatException('Invalid group runtime status');
    }
    final actions = <BotGroupAction>[];
    for (final action in _rows(status['pending_actions'])) {
      final kind = _requiredText(action['kind']);
      if (kind == 'retry' || kind == 'discard') {
        final generation = action['execution_generation'];
        if (generation is! int || generation < 1) {
          throw const FormatException('Invalid group retry attempt');
        }
        actions.add(
          BotGroupAction(
            kind: kind,
            task: _requiredText(action['task_id']),
            member: _requiredText(action['member_id']),
            generation: generation,
          ),
        );
      } else if (kind == 'approval') {
        final approval = _map(action['approval']);
        final generation = action['execution_generation'];
        final choices = approval['choices'];
        if (generation is! int ||
            generation < 1 ||
            choices is! List ||
            choices.any((c) => c != 'once' && c != 'deny')) {
          throw const FormatException('Invalid group approval');
        }
        actions.add(
          BotGroupAction(
            kind: kind,
            task: _requiredText(action['task_id']),
            member: _requiredText(action['member_id']),
            request: _requiredText(action['request_id']),
            generation: generation,
            command: _text(approval['command']),
            description: _text(approval['description']),
            choices: choices.cast<String>(),
          ),
        );
      }
    }
    return BotGroupRuntime(
      working: status['working'] == true,
      blocked: status['blocked'] == true,
      actions: actions,
      methods: methods,
      context: result['context'] is Map
          ? _decodeGroupContext(_map(result['context']))
          : null,
      routingModes: [
        for (final mode
            in status['routing_modes'] is List
                ? status['routing_modes'] as List
                : const [])
          if (mode is String &&
              const {'everyone', 'lead', 'auto'}.contains(mode))
            mode,
      ],
      maxRounds: status['max_rounds'] is int
          ? status['max_rounds'] as int
          : null,
      maxContinues: status['max_continues'] is int
          ? status['max_continues'] as int
          : null,
      lastError: status['last_error'] is String
          ? status['last_error'] as String
          : null,
      memberActivity: [
        for (final activity in _rows(status['member_activity'] ?? const []))
          if (const {
            'queued',
            'running',
            'stopping',
          }.contains(activity['status']))
            BotGroupMemberActivity(
              memberId: _requiredText(activity['member_id']),
              status: _requiredText(activity['status']),
              tool: activity['tool'] is String
                  ? activity['tool'] as String
                  : null,
              startedAt: _groupTime(activity['started_at']),
              progressAt: _groupTime(activity['progress_at']),
              threadId: _text(activity['thread_id']),
              roundIndex: activity['round_index'] is int
                  ? activity['round_index'] as int
                  : null,
            )
          else
            throw const FormatException('Invalid group member activity'),
      ],
    );
  }

  static DateTime? _groupTime(Object? value) =>
      value is num && value.isFinite && value.abs() < 8640000000000
      ? DateTime.fromMillisecondsSinceEpoch((value * 1000).round())
      : null;

  static BotGroupContext _decodeGroupContext(Map<String, dynamic> value) {
    if (value['purpose'] is! String ||
        value['notes'] is! String ||
        value['lead_member_id'] is! String ||
        !const {'everyone', 'lead', 'auto'}.contains(value['routing'])) {
      throw const FormatException('Invalid shared group settings');
    }
    return BotGroupContext(
      purpose: value['purpose'] as String,
      notes: value['notes'] as String,
      routing: value['routing'] as String,
      leadMemberId: value['lead_member_id'] as String,
    );
  }

  Future<BotGroupContext> saveGroupContext(
    BotGroup group,
    BotGroupContext value,
    String event,
    bool Function() canDispatch,
  ) async {
    _ownsGroup(group);
    final result = await _command(
      'default',
      'groups.context',
      {'room_id': group.id, 'event_id': event, ...value.toJson()},
      canDispatch,
      () {},
    );
    final receipt = _map(result['event']);
    if (receipt['room_id'] != group.id ||
        receipt['event_id'] != event ||
        receipt['kind'] != 'room.context_set') {
      throw const FormatException('Group settings were not confirmed');
    }
    return _decodeGroupContext(_map(result['context']));
  }

  Future<void> continueGroup(
    BotGroup group,
    String discussionEventId,
    bool Function() canDispatch,
  ) async {
    _ownsGroup(group);
    final result = await _command(
      'default',
      'groups.continue',
      {'room_id': group.id, 'discussion_event_id': discussionEventId},
      canDispatch,
      () {},
    );
    final event = _map(result['event']);
    if (result['continued'] != true ||
        event['room_id'] != group.id ||
        event['kind'] != 'room.continued' ||
        _map(event['payload'])['discussion_event_id'] != discussionEventId) {
      throw const FormatException('Continue was not confirmed');
    }
  }

  Future<List<BotGroupMember>> groupMembers(BotGroup group) async {
    _ownsGroup(group);
    final result = await _read('default', 'groups.state', {
      'room_id': group.id,
    });
    final current = _group(_map(result['room']));
    if (current.id != group.id) {
      throw const FormatException('Wrong group member owner');
    }
    return current.members;
  }

  Future<void> resolveGroup(
    BotGroup group,
    BotGroupAction action,
    String? choice,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    _ownsGroup(group);
    if (action.kind == 'retry' || action.kind == 'discard') {
      if (action.member.isEmpty ||
          action.task.isEmpty ||
          action.generation < 1) {
        throw ArgumentError('Invalid group retry attempt');
      }
      final result = await _command(
        'default',
        'groups.${action.kind}',
        {
          'room_id': group.id,
          'task_id': action.task,
          'member_id': action.member,
          'execution_generation': action.generation,
        },
        canDispatch,
        onDispatched,
      );
      final task = _map(result['task']);
      if (result[action.kind == 'retry' ? 'retried' : 'discarded'] != true ||
          task['room_id'] != group.id ||
          task['task_id'] != action.task) {
        throw const FormatException('Group retry was not confirmed');
      }
    } else if (action.kind == 'approval') {
      if (!action.choices.contains(choice)) {
        throw ArgumentError('Unavailable group approval choice');
      }
      final result = await _command(
        'default',
        'groups.approve',
        {
          'room_id': group.id,
          'task_id': action.task,
          'member_id': action.member,
          'request_id': action.request,
          'execution_generation': action.generation,
          'choice': choice,
        },
        canDispatch,
        onDispatched,
      );
      if (result['approved'] != true) {
        throw StateError('Approval was not confirmed');
      }
    } else {
      throw ArgumentError('Unknown group action');
    }
  }

  Future<void> checkGroupEdit(BotGroup group, String name) async {
    _ownsGroup(group);
    final result = await _read('default', 'groups.state', {
      'room_id': group.id,
    });
    final current = _group(_map(result['room']));
    if (current.id != group.id ||
        (current.name != group.name && current.name != name) ||
        current.members.length != group.members.length ||
        current.members.any(
          (m) => !group.members.any(
            (old) =>
                old.id == m.id &&
                old.profile == m.profile &&
                old.handle == m.handle,
          ),
        )) {
      throw const BotGroupEditConflict(
        'Group changed on Hermes. Refresh Bots and reopen Edit group.',
      );
    }
  }

  Future<void> groupAction(
    BotGroup group,
    String action,
    String event,
    bool Function() canDispatch,
    void Function() onDispatched, {
    String? name,
  }) async {
    _ownsGroup(group);
    if (!{'rename', 'stop', 'disband'}.contains(action)) {
      throw ArgumentError('Unknown group action');
    }
    final result = await _command(
      'default',
      'groups.$action',
      {
        'room_id': group.id,
        if (action == 'rename') ...{
          'name': name,
          'event_id': event,
        } else
          'cancel_id': event,
      },
      canDispatch,
      onDispatched,
    );
    if (action == 'stop' &&
        (result['cancelled'] is! int || (result['cancelled'] as int) < 0)) {
      throw StateError('Group stop could not be confirmed');
    }
    if (action == 'rename' &&
        (_map(result['room'])['room_id'] != group.id ||
            _map(result['room'])['name'] != name)) {
      throw StateError(
        'Group rename could not be confirmed. Retry to confirm it.',
      );
    }
  }

  Future<BotDisplayStatus> displayStatus(BotRecord bot) async {
    _owns(bot);
    return BotDisplayStatus.parse(
      await _read(bot.profile.name, 'display.status', {}),
    );
  }

  Future<({String ticket, String viewer, BotDisplayStatus status})>
  observeDisplay(BotRecord bot, String? viewer) async {
    _owns(bot);
    final value = await _read(bot.profile.name, 'display.observe', {
      'viewer_id': ?viewer,
    });
    if (value['ticket'] is! String ||
        (value['ticket'] as String).isEmpty ||
        value['viewer_id'] is! String ||
        (value['viewer_id'] as String).isEmpty ||
        value['path'] != '/api/display/ws') {
      throw const FormatException('Invalid screen observation');
    }
    return (
      ticket: value['ticket'] as String,
      viewer: value['viewer_id'] as String,
      status: BotDisplayStatus.parse(value),
    );
  }

  Future<BotDisplayClient> connectDisplay(String ticket) {
    final connect = displayConnect;
    if (connect == null) throw StateError('Screen transport unavailable');
    return connect(ticket);
  }

  Future<BotDisplayLease> displayControl(
    BotRecord bot,
    String? viewer, {
    required bool acquire,
    required bool force,
    required bool Function() canDispatch,
    required void Function() onDispatched,
  }) async {
    _owns(bot);
    if (acquire && (viewer == null || force)) {
      throw ArgumentError('Invalid takeover');
    }
    final result = await _command(
      bot.profile.name,
      acquire ? 'display.lease.acquire' : 'display.lease.release',
      {
        if (!force && viewer != null) 'viewer_id': viewer,
        if (force) 'force': true,
      },
      canDispatch,
      onDispatched,
    );
    return BotDisplayLease.parse(result['lease']);
  }

  Future<void> screenPower(
    BotRecord bot,
    bool start,
    bool Function() canDispatch,
    void Function() onDispatched,
  ) async {
    _owns(bot);
    await _command(
      bot.profile.name,
      start ? 'display.start' : 'display.stop',
      {},
      canDispatch,
      onDispatched,
    );
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid stock response object');
    }
    return Map<String, dynamic>.from(value);
  }

  static List<Map<String, dynamic>> _rows(Object? value) {
    if (value is! List) {
      throw const FormatException('Invalid stock response list');
    }
    return value.map(_map).toList();
  }

  static String _text(Object? value) {
    if (value == null) return '';
    if (value is! String) {
      throw const FormatException('Invalid stock response text');
    }
    return value;
  }

  static String _requiredText(Object? value) {
    final text = _text(value);
    if (text.isEmpty) {
      throw const FormatException('Missing stock response identity');
    }
    return text;
  }

  static Object? _freeze(Object? value) => switch (value) {
    Map map => Map<String, Object?>.unmodifiable({
      for (final entry in map.entries)
        _requiredText(entry.key): _freeze(entry.value),
    }),
    List list => List<Object?>.unmodifiable(list.map(_freeze)),
    null || String() || bool() || num() => value,
    _ => throw const FormatException('Invalid bot metadata'),
  };
  static Uint8List _image(Object? value, {required int maxBytes}) {
    final text = _requiredText(value);
    // Bound the base64 allocation, including a short data-URL media header.
    if (text.length > ((maxBytes + 2) ~/ 3) * 4 + 128) {
      throw const FormatException('Image exceeds its input limit');
    }
    final data = text.startsWith('data:')
        ? text.substring(text.indexOf(',') + 1)
        : text;
    final bytes = base64Decode(data);
    if (bytes.length > maxBytes) {
      throw const FormatException('Image exceeds its input limit');
    }
    inspectAttachmentImage(bytes);
    return bytes;
  }
}

enum BotAvatarReadKind { usable, missing, unavailable }

final class BotAvatarRead {
  BotAvatarRead.usable(Uint8List value)
    : kind = BotAvatarReadKind.usable,
      bytes = value.asUnmodifiableView();
  const BotAvatarRead.missing()
    : kind = BotAvatarReadKind.missing,
      bytes = null;
  const BotAvatarRead.unavailable()
    : kind = BotAvatarReadKind.unavailable,
      bytes = null;
  final BotAvatarReadKind kind;
  final Uint8List? bytes;
}
