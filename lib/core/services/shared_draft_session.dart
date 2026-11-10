import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/shared_draft.dart';
import '../models/profile_session_key.dart';
import '../models/composer_work.dart';
import 'android_share_intent_service.dart';
import 'attachment_draft_service.dart';
import 'connection_manager.dart';
import 'profile_workspace_controller.dart';
import 'workspace_entry_session.dart';
import 'ws_client.dart';
import 'bots_session.dart';
import 'bot_group_session.dart';
import '../models/bots.dart';

/// Issued for one exact intake item and one Home lifetime. The route borrows it.
class SharedDraftOffer {
  SharedDraftOffer._(
    this._owner,
    this._native,
    this.connections,
    this.preferredConnection,
  ) : _payload = AndroidSharePayload(
        id: _native.id,
        text: _native.text,
        files: List.unmodifiable(_native.files),
        target: _native.target == null
            ? null
            : Map.unmodifiable(_native.target!),
      );
  final SharedDraftSession _owner;
  final AndroidSharePayload _native;
  final List<SavedConnection> connections;
  final SavedConnection? preferredConnection;
  WorkspaceEntryPlan? _entry;
  ProfileWorkspaceController? _controller;
  ProfileWorkspaceData? _resource;
  final AndroidSharePayload _payload;
  Object _profileSelection = Object();
  ProfileChat? _initial, _created, _recoveryTarget, _stagedChat;
  BotsSession? _bots;
  List<BotGroup> _groups = const [];
  BotGroup? _stagedGroup;
  BotGroupSession? _groupDraft;
  ({ProfileSessionKey key, ComposerSavedWork draft})? _recovery;
  String? _notice, _error;
  SharedDraftReviewState? _lastReview;
  String _destination = SharedDraftSession._newChat;
  bool _working = false, _recoveryApplied = false, _staged = false;
  bool _retainWorkspace = false;
}

class SharedDraftNavigation {
  SharedDraftNavigation._(this.entry, this.returnToHome, this.group);
  final BotGroup? group;
  final WorkspaceEntryPlan entry;
  final bool returnToHome;
}

/// One intake/review workflow; existing entry, controller/composer and native
/// queue remain borrowed authorities. This owns no draft persistence or queue.
class SharedDraftSession extends ChangeNotifier {
  SharedDraftSession({
    required ConnectionManager connectionManager,
    required WorkspaceEntrySession entrySession,
    required AndroidShareIntentService? shareIntents,
    this.createBotsSession,
  }) : _manager = connectionManager,
       _entry = entrySession,
       _shares = shareIntents {
    _shares?.pendingShare.addListener(_intakeChanged);
    _shares?.intakeError.addListener(_intakeError);
  }
  static const _newChat = '__new_chat__', _recoverDraft = '__recover_draft__';
  final BotsSession Function()? createBotsSession;
  final ConnectionManager _manager;
  final WorkspaceEntrySession _entry;
  final AndroidShareIntentService? _shares;
  SharedDraftOffer? _active;
  AndroidSharePayload? _lastAutomatic;
  SharedDraftNotice? _notice;
  bool _closed = false, _ready = false, _discarding = false;
  String? _deferredId;
  int _notificationDepth = 0;

  SharedDraftState get state => SharedDraftState(
    hasPending: _shares?.pendingShare.value != null,
    reviewing: _active != null,
    discarding: _discarding,
    canReview:
        !_closed &&
        _active == null &&
        !_discarding &&
        _manager.getConnections().isNotEmpty,
  );
  void start({
    required Future<void>? startupReady,
    required String? deferredShareId,
  }) {
    _deferredId = deferredShareId;
    _intakeError();
    if (startupReady == null) {
      _ready = true;
      _changed();
    } else {
      unawaited(_awaitStartup(startupReady));
    }
  }

  Future<void> _awaitStartup(Future<void> ready) async {
    try {
      await ready;
      if (!_closed) {
        _ready = true;
        _changed();
      }
    } catch (_) {
      if (!_closed) {
        _notice = const SharedDraftNotice(
          'The shared draft could not be opened. It is still available to review.',
          error: true,
        );
        _changed();
      }
    }
  }

  void deferAutoReview(String id) => _deferredId = id;
  void _intakeChanged() => _changed();
  void _intakeError() {
    final message = _shares?.intakeError.value;
    if (_closed || message == null) return;
    _notice = SharedDraftNotice(message, error: true);
    _shares!.clearIntakeError();
    _changed();
  }

  SharedDraftNotice? takeNotice() {
    if (_closed) return null;
    final value = _notice;
    _notice = null;
    return value;
  }

  void _changed() {
    if (_closed) return;
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      if (--_notificationDepth == 0 && _closed) super.dispose();
    }
  }

  bool _owns(SharedDraftOffer offer) =>
      !_closed && identical(offer._owner, this) && identical(_active, offer);
  void _require(SharedDraftOffer offer) {
    if (!_owns(offer)) {
      throw StateError('This shared draft review is no longer open.');
    }
  }

  void _requireIntake(SharedDraftOffer offer) {
    _require(offer);
    if (!identical(_shares?.pendingShare.value, offer._native)) {
      throw StateError(
        'The incoming shared content has changed. Review it again.',
      );
    }
  }

  SharedDraftOffer? claim({
    required bool explicit,
    required bool presentationBlocked,
  }) {
    final payload = _shares?.pendingShare.value;
    if (_closed ||
        !_ready ||
        _entry.state.opening ||
        presentationBlocked ||
        payload == null ||
        !state.canReview ||
        (!explicit &&
            (payload.id == _deferredId ||
                identical(payload, _lastAutomatic)))) {
      return null;
    }
    _lastAutomatic = payload;
    final offer = SharedDraftOffer._(
      this,
      payload,
      List.unmodifiable(_manager.getConnections()),
      _entry.sharedConnection(payload.target?['connection']),
    );
    _active = offer;
    _entry.suppressStartupRestore();
    _changed();
    return _owns(offer) ? offer : null;
  }

  void _controllerChanged() => _changed();
  Future<bool> prepare(
    SharedDraftOffer offer,
    SavedConnection connection, {
    required ProfileSessionKey? reviewDestination,
  }) async {
    _requireIntake(offer);
    if (offer._entry != null || offer._working) {
      throw StateError('Wait for this shared draft to open.');
    }
    offer._working = true;
    _changed();
    try {
      _requireIntake(offer);
      final entry = await _entry.prepare(connection);
      _requireIntake(offer);
      if (entry == null || !_entry.isCurrent(entry)) {
        throw StateError('The shared draft connection is no longer available.');
      }
      offer._entry = entry;
      final controller = offer._controller = entry.controller;
      controller.addListener(_controllerChanged);
      if (controller.discovery == null) await controller.initialize();
      _requireEntry(offer);
      final bots = offer._bots = createBotsSession?.call();
      if (bots != null) {
        await bots.refresh();
        _requireEntry(offer);
        offer._groups = bots.state.groups
            .where(
              (group) =>
                  group.scope.connectionId == controller.connection.id &&
                  group.scope.connectionIdentity ==
                      controller.connectionIdentity,
            )
            .toList();
      }
      ProfileSessionKey? verified;
      final target = offer._payload.target;
      if (target != null && !target.containsKey('room')) {
        try {
          final key = ProfileSessionKey.fromJson(target);
          if (controller.owns(key) &&
              controller.discovery?.named(key.workspace.profileName) != null) {
            verified = key;
            final destination = await controller.prepareSharedDraftTarget(key);
            _requireEntry(offer);
            final opened = destination?.chat;
            if (opened != null && identical(controller.current?.chat, opened)) {
              offer._initial = opened;
              offer._retainWorkspace = destination!.retainWorkspace;
            }
          }
        } catch (error) {
          _requireEntry(offer);
          if (error is JsonRpcError &&
              error.method == 'session.resume' &&
              error.reason == 'not_found' &&
              verified != null &&
              controller.current?.chats.containsKey(verified.sessionId) ==
                  false) {
            final draft = await controller.savedDraft(verified);
            _requireEntry(offer);
            if (draft != null) offer._recovery = (key: verified, draft: draft);
          }
        }
      }
      final profile = controller.current?.scope.profileName;
      if (profile == null) {
        throw StateError('No profile is available for this shared draft.');
      }
      if (offer._initial == null) {
        await controller.navigateProfile(profile);
        _requireEntry(offer);
      }
      offer._resource = controller.current;
      if (target?['room'] case final roomId?) {
        final group = offer._groups
            .where(
              (group) =>
                  group.id == roomId &&
                  group.scope.connectionIdentity ==
                      target!['connection_identity'] &&
                  group.scope.connectionId == target['connection'],
            )
            .firstOrNull;
        if (group != null) {
          offer._destination = _groupDestination(group);
          await _stageGroup(offer, group);
          return false;
        }
      }
      if (offer._initial != null && reviewDestination == null) {
        await _stage(offer, offer._initial!);
        return false;
      }
      if (reviewDestination != null &&
          controller.owns(reviewDestination) &&
          reviewDestination.workspace == offer._resource?.scope) {
        final initial = offer._resource?.chats[reviewDestination.sessionId];
        if (initial != null && initial.key == reviewDestination) {
          offer._initial = initial;
        }
      }
      offer._notice = target == null
          ? null
          : 'The original chat could not be reopened. Choose a destination below.';
      offer._destination =
          offer._initial?.key.sessionId ??
          (offer._recovery?.key.workspace == offer._resource?.scope
              ? _recoverDraft
              : _newChat);
      return true;
    } catch (_) {
      if (_owns(offer)) {
        _notice = SharedDraftNotice(
          offer._staged
              ? 'Content was added to the draft, but opening it could not be completed. Review the destination before adding this content again.'
              : 'The shared draft could not be opened. It is still available to review.',
          error: true,
        );
      }
      rethrow;
    } finally {
      if (_owns(offer)) {
        offer._working = false;
        _changed();
      }
    }
  }

  void _requireEntry(SharedDraftOffer offer) {
    _requireIntake(offer);
    if (offer._entry == null || !_entry.isCurrent(offer._entry!)) {
      throw StateError('The selected connection is no longer open.');
    }
  }

  ProfileWorkspaceData _requireReview(SharedDraftOffer offer) {
    _requireEntry(offer);
    final resource = offer._resource;
    if (resource == null || !identical(offer._controller?.current, resource)) {
      throw StateError('The selected profile is no longer open.');
    }
    return resource;
  }

  ProfileWorkspaceData? _reviewForCommand(SharedDraftOffer offer) {
    try {
      return _requireReview(offer);
    } catch (error) {
      if (_owns(offer)) {
        offer._error = _message(error);
        _changed();
      }
      return null;
    }
  }

  SharedDraftReviewState review(SharedDraftOffer offer) {
    if (!identical(offer._owner, this)) {
      throw StateError('This shared draft belongs to another owner.');
    }
    if (!_owns(offer)) {
      // A departing route may render after its commands have retired.
      final retained = offer._lastReview;
      if (retained == null) {
        throw StateError('This shared draft review has not been prepared.');
      }
      return retained;
    }
    final resource = offer._resource!;
    final controller = offer._controller!;
    final profile = resource.scope.profileName;
    final rows = controller.current == resource
        ? resource.sessions
        : const <Map<String, dynamic>>[];
    final initial = offer._initial;
    final recovery = offer._recovery;
    final choices = <SharedDraftDestination>[
      for (final group in offer._groups)
        SharedDraftDestination(
          profileSelection: offer._profileSelection,
          id: _groupDestination(group),
          presentationId: 'share-destination-group-${group.id}',
          label: 'Group · ${group.name}',
        ),
      if (recovery?.key.workspace.profileName == profile)
        SharedDraftDestination(
          profileSelection: offer._profileSelection,
          id: _recoverDraft,
          presentationId: 'share-destination-recover',
          label: 'New chat with recovered draft',
        ),
      SharedDraftDestination(
        profileSelection: offer._profileSelection,
        id: _newChat,
        presentationId: 'share-destination-new',
        label: offer._created == null ? 'New chat' : 'New chat (ready)',
      ),
      for (final row in rows)
        if (row['id'] is String)
          SharedDraftDestination(
            profileSelection: offer._profileSelection,
            id: row['id'] as String,
            presentationId: 'share-destination-${row['id']}',
            label:
                row['title'] is String &&
                    (row['title'] as String).trim().isNotEmpty
                ? row['title'] as String
                : 'Untitled chat',
          ),
      if (initial != null &&
          initial.key.workspace == resource.scope &&
          !rows.any((r) => r['id'] == initial.key.sessionId))
        SharedDraftDestination(
          profileSelection: offer._profileSelection,
          id: initial.key.sessionId,
          presentationId: 'share-destination-${initial.key.sessionId}',
          label: initial.title,
        ),
    ];
    return offer._lastReview = SharedDraftReviewState(
      text: offer._payload.text,
      files: offer._payload.files.map(
        (f) => SharedDraftFile(
          name: f.name,
          byteLength: f.byteLength,
          isImage: f.isImage,
        ),
      ),
      connectionLabel: controller.connection.label,
      profileName: profile,
      profiles: (controller.discovery?.profiles ?? const []).map(
        (p) => SharedDraftProfile(name: p.name, label: p.label),
      ),
      destination: offer._destination,
      destinations: choices,
      recovery: recovery == null
          ? null
          : SharedDraftRecovery(
              profileName: recovery.key.workspace.profileName,
              text: recovery.draft.text,
              attachmentCount: recovery.draft.attachments.length,
              queuedCount: recovery.draft.queuedPrompts.length,
            ),
      destinationNotice: offer._notice,
      working: offer._working,
      canLoadMore: resource.nextSessionOffset != null,
      loadingMore: resource.sessionsLoadingMore,
      loadMoreLabel: resource.sessionsPageError == null
          ? 'Load more chats'
          : 'Retry more chats',
      addLabel: offer._destination == _recoverDraft
          ? 'Recover draft and add content'
          : 'Add to draft',
      pageError: offer._error == resource.sessionsPageError
          ? resource.sessionsPageError
          : null,
      error: offer._error == resource.sessionsPageError ? null : offer._error,
    );
  }

  void chooseDestination(
    SharedDraftOffer offer,
    SharedDraftDestination destination,
  ) {
    if (_reviewForCommand(offer) == null) return;
    final id = destination.id;
    if (offer._working ||
        !identical(destination.profileSelection, offer._profileSelection) ||
        !review(offer).destinations.any((d) => d.id == id)) {
      return;
    }
    if (offer._destination != id) offer._created = null;
    offer._destination = id;
    offer._error = null;
    _changed();
  }

  Future<void> chooseProfile(SharedDraftOffer offer, String? name) async {
    final resource = _reviewForCommand(offer);
    if (resource == null) return;
    final controller = offer._controller!;
    if (name == null || name == resource.scope.profileName || offer._working) {
      return;
    }
    offer._working = true;
    offer._error = null;
    _changed();
    try {
      _requireReview(offer);
      await controller.navigateProfile(name);
      _requireEntry(offer);
      if (controller.current?.scope.profileName != name) {
        throw StateError('That profile could not be opened.');
      }
      offer._resource = controller.current;
      offer._profileSelection = Object();
      offer._destination = _newChat;
      offer._initial = null;
      offer._created = null;
    } catch (error) {
      if (_owns(offer)) offer._error = _message(error);
    } finally {
      if (_owns(offer)) {
        offer._working = false;
        _changed();
      }
    }
  }

  Future<void> loadMore(SharedDraftOffer offer) async {
    final resource = _reviewForCommand(offer);
    if (resource == null) return;
    final controller = offer._controller!;
    if (offer._working) return;
    offer._working = true;
    offer._error = null;
    _changed();
    try {
      _requireReview(offer);
      if (resource.selectedProject != null) {
        await controller.selectProject(null);
        _requireReview(offer);
      }
      await controller.loadMoreSessions();
      _requireReview(offer);
      offer._error = resource.sessionsPageError;
    } catch (error) {
      if (_owns(offer)) offer._error = _message(error);
    } finally {
      if (_owns(offer)) {
        offer._working = false;
        _changed();
      }
    }
  }

  Future<bool> add(SharedDraftOffer offer) async {
    final resource = _reviewForCommand(offer);
    if (resource == null) return false;
    final controller = offer._controller!;
    if (offer._working || offer._staged) return false;
    final destination = offer._destination, scope = resource.scope;
    offer._working = true;
    offer._error = null;
    _changed();
    try {
      _requireReview(offer);
      final selectedGroup = offer._groups
          .where((group) => _groupDestination(group) == destination)
          .firstOrNull;
      if (selectedGroup != null) {
        await _stageGroup(offer, selectedGroup);
        return _canNavigate(offer);
      }
      final ProfileChat chat;
      if (destination == _recoverDraft) {
        final recovery = offer._recovery;
        if (recovery == null || recovery.key.workspace != scope) {
          throw StateError(
            'Return to the original profile to recover this draft.',
          );
        }
        if (resource.selectedProject != null) {
          await controller.selectProject(null);
          _requireReview(offer);
        }
        chat =
            offer._recoveryTarget ??
            await controller.createChat(
              owner: scope,
              canDispatch: () {
                try {
                  return identical(_requireReview(offer), resource);
                } catch (_) {
                  return false;
                }
              },
            );
        _requireReview(offer);
        offer._recoveryTarget = chat;
        if (!offer._recoveryApplied) {
          await controller.recoverDraft(recovery.key, chat);
          _requireReview(offer);
          offer._recoveryApplied = true;
        }
      } else if (destination == _newChat) {
        if (offer._created == null && resource.selectedProject != null) {
          await controller.selectProject(null);
          _requireReview(offer);
        }
        chat =
            offer._created ??
            await controller.createChat(
              owner: scope,
              canDispatch: () {
                try {
                  return identical(_requireReview(offer), resource);
                } catch (_) {
                  return false;
                }
              },
            );
        _requireReview(offer);
        offer._created = chat;
      } else {
        await controller.openSession(ProfileSessionKey(scope, destination));
        _requireReview(offer);
        final opened = resource.chats[destination];
        if (resource.selectedSession != destination || opened == null) {
          throw StateError('The selected chat could not be opened.');
        }
        chat = opened;
      }
      await _stage(offer, chat);
      return _canNavigate(offer);
    } catch (error) {
      if (_owns(offer)) offer._error = _message(error);
      return false;
    } finally {
      if (_owns(offer)) {
        offer._working = false;
        _changed();
      }
    }
  }

  static String _groupDestination(BotGroup group) => 'group:${group.key}';

  Future<void> _stageGroup(SharedDraftOffer offer, BotGroup group) async {
    _requireReview(offer);
    if (offer._groupDraft?.group.key != group.key) {
      offer._groupDraft?.dispose();
      offer._groupDraft = offer._bots!.openGroup(group);
    }
    final draft = offer._groupDraft!;
    if (draft.pendingText != null) {
      throw StateError(
        'Open this group and confirm its pending message first.',
      );
    }
    if (!await draft.stageSharedContent(offer._payload)) {
      throw StateError(
        draft.error ?? 'Shared content could not be added to the group.',
      );
    }
    _requireReview(offer);
    offer._staged = true;
    offer._stagedGroup = group;
    final cleared = await _shares!.acknowledgeShare(offer._native);
    if (_owns(offer) && !cleared) {
      _notice = const SharedDraftNotice(
        'Content was added to the group draft, but the incoming share could not be cleared. Discard it from Home to avoid adding it twice.',
        error: true,
      );
    }
  }

  Future<void> _stage(SharedDraftOffer offer, ProfileChat chat) async {
    _requireReview(offer);
    await offer._controller!.stageSharedDraft(chat, offer._payload);
    // Already admitted composer writes settle; close revokes any later native ACK.
    _requireReview(offer);
    offer._staged = true;
    offer._stagedChat = chat;
    final cleared = await _shares!.acknowledgeShare(offer._native);
    if (!_owns(offer)) return;
    if (!cleared) {
      _notice = const SharedDraftNotice(
        'Content was added to the draft, but the incoming share could not be cleared. Discard it from Home to avoid adding it twice.',
        error: true,
      );
    }
    if (!_canNavigate(offer)) {
      throw StateError(
        'Content was added to the draft, but the selected chat changed. Open the destination chat to review it.',
      );
    }
  }

  bool _canNavigate(SharedDraftOffer offer) {
    final chat = offer._stagedChat;
    final resource = offer._resource;
    if (offer._stagedGroup != null) {
      return _owns(offer) &&
          offer._staged &&
          offer._entry != null &&
          _entry.isCurrent(offer._entry!);
    }
    return _owns(offer) &&
        offer._staged &&
        chat != null &&
        resource != null &&
        offer._entry != null &&
        _entry.isCurrent(offer._entry!) &&
        identical(offer._controller?.current, resource) &&
        resource.selectedSession == chat.key.sessionId &&
        identical(resource.chats[chat.key.sessionId], chat) &&
        identical(resource.chat, chat);
  }

  SharedDraftNavigation? navigation(SharedDraftOffer offer) =>
      _canNavigate(offer) &&
          !(offer._retainWorkspace && offer._controller!.hasMountedRoutes)
      ? SharedDraftNavigation._(
          offer._entry!,
          offer._payload.target != null,
          offer._stagedGroup,
        )
      : null;
  void finish(SharedDraftOffer offer) {
    if (!_owns(offer)) return;
    offer._controller?.removeListener(_controllerChanged);
    offer._groupDraft?.dispose();
    offer._bots?.dispose();
    _active = null;
    _changed();
  }

  Future<void> discard() async {
    final payload = _shares?.pendingShare.value;
    if (_closed || _active != null || _discarding || payload == null) return;
    _discarding = true;
    _changed();
    if (_closed) return;
    try {
      final cleared = await _shares!.acknowledgeShare(payload);
      if (!_closed && !cleared) {
        _notice = const SharedDraftNotice(
          'The shared content could not be discarded. Please try again.',
          error: true,
        );
      }
    } finally {
      if (!_closed) {
        _discarding = false;
        _changed();
      }
    }
  }

  String _message(Object error) => error is StateError
      ? error.message.toString()
      : error is AttachmentDraftException
      ? error.message
      : 'The shared content could not be added. Try again.';
  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _active?._controller?.removeListener(_controllerChanged);
    _active?._groupDraft?.dispose();
    _active?._bots?.dispose();
    _shares?.pendingShare.removeListener(_intakeChanged);
    _shares?.intakeError.removeListener(_intakeError);
    if (_notificationDepth == 0) super.dispose();
  }
}
