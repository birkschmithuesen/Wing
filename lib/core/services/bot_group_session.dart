import 'dart:async';
import '../models/operational_error.dart';
import '../models/attachment_draft.dart';
import '../models/composer_work.dart';
import 'attachment_draft_service.dart';
import 'android_share_intent_service.dart';
import 'remote_files_client.dart';
import '../models/transcript_position.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/bots.dart';
import '../models/transcript_reader.dart';
import '../models/transcript_message.dart';
import 'bots_repository.dart';
import 'bots_preferences.dart';
import '../models/hermes_question.dart';
import 'bot_group_read_state.dart';
import '../models/composer_reference.dart';
import '../models/recent_conversation.dart';
import 'hermes_voice.dart';
import 'recent_conversation_snapshots.dart';
import 'ws_client.dart';

/// Canonical member appearance observations, shared by live and passive views.
abstract interface class BotGroupAppearanceSource implements Listenable {
  BotGroupAppearance appearanceForGroup(BotGroup group);
}

typedef BotGroupSendOutcome = ({
  String eventId,
  bool dispatched,
  int? sequence,
});

/// Exact group visit and text revision captured before microphone admission.
final class BotGroupVoiceDraft {
  const BotGroupVoiceDraft._(this._owner, this._revision, this.text);
  final Object _owner;
  final int _revision;
  final String text;
}

/// The stock gateway drives group discussion, including while Wing is away.
/// This owner replays its log and retains one immutable idempotent send attempt.
class BotGroupSession extends ChangeNotifier {
  BotGroupSession(
    this.repository,
    BotGroup group, {
    required this.appearances,
    required this.reads,
    required this.groupMessages,
    required this.preferences,
    this.onRead,
    this.beforeSend,
    this.afterSend,
    this.onOperationalError,
    AttachmentDraftService? attachmentService,
  }) : _group = group,
       _attachmentService = attachmentService ?? AttachmentDraftService() {
    repository.retain();
    _appearance = appearances.appearanceForGroup(group);
    appearances.addListener(_appearanceChanged);
    _draftWriteRevision = preferences.messageDraftRevision(
      group.scope.connectionIdentity,
      group.id,
    );
    try {
      final saved = preferences.messageDraft(
        group.scope.connectionIdentity,
        group.id,
      );
      if (saved != null) {
        _draft = saved.text;
        _reply = saved.reply;
        _references = retainComposerReferences(_draft, saved.references);
        _attachments = List.of(saved.attachments);
        if (saved.pendingEventId case final eventId?) {
          if (saved.pendingWireText == null || saved.pendingText == null) {
            throw const FormatException('Incomplete pending group message');
          }
          _pending = (eventId, saved.pendingText!);
          _pendingWireText = saved.pendingWireText;
          _pendingAttachments = List.unmodifiable(_attachments);
        }
      }
    } catch (_) {
      _draftError = 'The saved group draft could not be read on this device.';
    }
    // Discovery already obtained this exact room's bounded message tail.
    // It is passive reading, never runtime/action authority or a log cursor.
    final cache = groupMessages;
    if (cache != null) {
      // Sparse logs can cover fewer than ten messages without covering history.
      // Borrow the largest covered tail; completeness never grants authority.
      for (var limit = RecentGroupMessages.messageLimit; limit > 0; limit--) {
        final tail = cache.borrow(group, limit: limit);
        if (tail == null) continue;
        _historyAvailable = true;
        for (final event in tail) {
          _events[event.sequence] = event;
        }
        break;
      }
    }
  }
  final BotGroupAppearanceSource appearances;
  final OperationalErrorReporter? onOperationalError;
  final BotsPreferences preferences;
  late BotGroupAppearance _appearance;
  void _appearanceChanged() {
    if (_closed) return;
    final next = appearances.appearanceForGroup(group);
    if (_appearance == next) return;
    _appearance = next;
    notifyListeners();
  }

  final BotGroupReadState reads;
  final Future<void> Function(BotGroup, int)? onRead;
  final Future<void> Function(BotGroup, String)? beforeSend;
  final Future<void> Function(BotGroup, BotGroupSendOutcome)? afterSend;
  final RecentGroupMessages? groupMessages;
  Future<void> acknowledgeVisibleMessages(int sequence) async {
    if (_closed ||
        !_visible ||
        _capturing ||
        !events.any((e) => e.isMessage && e.sequence == sequence)) {
      return;
    }
    try {
      await reads.acknowledge(group, sequence);
      await onRead?.call(group, sequence);
    } catch (_) {
      /* Keep unread until the device receipt can be saved. */
    }
  }

  late final reading = BotGroupTranscriptReading._(this);

  final BotsRepository repository;
  BotGroup _group;
  BotGroup get group => _group;
  void updateDetails(BotGroup next) {
    if (_closed ||
        next.scope != group.scope ||
        next.id != group.id ||
        next.members.length != group.members.length ||
        next.members.any(
          (m) => !group.members.any(
            (old) =>
                old.id == m.id &&
                old.profile == m.profile &&
                old.handle == m.handle,
          ),
        )) {
      return;
    }
    _group = next;
    _appearance = appearances.appearanceForGroup(next);
    notifyListeners();
  }

  List<ComposerReference> _references = const [];
  List<ComposerReference> get composerReferences => _references;

  MentionCompletion completeMentions(MentionQuery query) => MentionCompletion(
    query: query,
    items: [
      for (final member in group.members)
        if (member.handle.contains(query.agentSearch.toLowerCase()) ||
            member.name.toLowerCase().contains(query.agentSearch.toLowerCase()))
          MentionCandidate(
            label: member.name,
            detail: _memberToken(member),
            appearance: appearance(member.profile),
            reference: ComposerReference(
              kind: ComposerReferenceKind.agent,
              token: _memberToken(member),
              target: member.id,
            ),
          ),
      if ('everyone'.contains(query.agentSearch.toLowerCase()))
        const MentionCandidate(
          label: 'Everyone',
          detail: 'All room members',
          isCollective: true,
          reference: ComposerReference(
            kind: ComposerReferenceKind.agent,
            token: '@everyone',
            target: 'everyone',
          ),
        ),
    ],
  );

  String _memberToken(BotGroupMember member) {
    final base = composerAgentToken(member.name);
    final duplicate =
        group.members
            .where(
              (other) =>
                  composerAgentToken(other.name).toLowerCase() ==
                  base.toLowerCase(),
            )
            .length >
        1;
    return composerAgentToken(
      member.name,
      target: member.id,
      claimed: _references,
      qualifier:
          base.toLowerCase() == '@everyone' ||
              duplicate ||
              _references.any(
                (ref) => ref.token == base && ref.target != member.id,
              )
          ? member.handle
          : null,
    );
  }

  String _canonicalText(String text, List<ComposerReference> references) {
    var wire = text;
    for (final span in composerReferenceSpans(
      text,
      selected: references,
    ).reversed) {
      final ref = span.reference;
      final token = ref.target == 'everyone' && ref.token == '@everyone'
          ? '@everyone'
          : '@${group.members.singleWhere((member) => member.id == ref.target).handle}';
      // Stock room routing includes dots and colons in handles. Keep authored
      // punctuation outside the canonical handle in the scalar wire payload.
      final separator = span.end < text.length && '.:'.contains(text[span.end])
          ? ' '
          : '';
      wire = wire.replaceRange(span.start, span.end, '$token$separator');
    }
    return wire;
  }

  Future<void> editMentions(String text, {ComposerReference? selected}) {
    if (_closed || (text == _draft && selected == null)) return Future.value();
    if (text != _draft) {
      _draft = text;
      _draftRevision++;
    }
    _references = retainComposerReferences(text, [..._references, ?selected]);
    return _saveDraft();
  }

  BotGroupReply? _reply;
  BotGroupReply? get reply => _reply;
  bool get canChooseReply =>
      !_closed && !_sending && !_acting && _pending == null;
  bool canReplyTo(BotGroupEvent event) =>
      canChooseReply &&
      event.isMessage &&
      event.text.trim().isNotEmpty &&
      identical(_events[event.sequence], event);

  Future<void> replyTo(BotGroupEvent event) async {
    if (!canReplyTo(event)) return;
    final member = event.actor == 'member'
        ? group.members.where((m) => m.id == event.actorId).firstOrNull
        : null;
    _reply = BotGroupReply(
      threadId: event.threadId.isEmpty ? null : event.threadId,
      author:
          member?.name ?? (event.actorName.isEmpty ? 'You' : event.actorName),
      quote: event.text
          .split('\n')
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty),
    );
    if (member != null) {
      final token = _memberToken(member);
      if (!composerReferenceSpans(
        _draft,
        selected: _references,
      ).any((span) => span.reference.target == member.id)) {
        _draft = '$token ${_draft.trimLeft()}';
        _references = retainComposerReferences(_draft, [
          ..._references,
          ComposerReference(
            kind: ComposerReferenceKind.agent,
            token: token,
            target: member.id,
          ),
        ]);
      }
    }
    _draftRevision++;
    notifyListeners();
    await _saveDraft();
  }

  Future<void> cancelReply() async {
    if (!canChooseReply || _reply == null) return;
    _reply = null;
    _draftRevision++;
    notifyListeners();
    await _saveDraft();
  }

  final AttachmentDraftService _attachmentService;
  List<BotGroupAttachment> _attachments = [];
  List<BotGroupAttachment> get attachments => List.unmodifiable(_attachments);
  final Map<String, AttachmentDraft> _attachmentPreviews = {};
  ComposerAttachmentPreparation? _attachmentPreparation;
  ComposerAttachmentPreparation? get attachmentPreparation =>
      _attachmentPreparation;
  bool get canAddAttachments =>
      !_closed &&
      !_sending &&
      !_acting &&
      _pending == null &&
      _attachmentPreparation == null;
  AttachmentPreviewSource? attachmentPreview(BotGroupAttachment attachment) {
    final draft = _attachmentPreviews[attachment.id];
    return draft == null || !draft.isImage
        ? null
        : _attachmentService.previewSource(draft);
  }

  Future<bool> addAttachments(
    List<AndroidSharedFile> files, {
    bool atomic = false,
  }) async {
    if (!canAddAttachments) return false;
    if (files.isEmpty) return true;
    final originalIds = _attachments.map((item) => item.id).toSet();
    var success = false;
    _attachmentPreparation = ComposerAttachmentPreparation(
      imageCount: files.where((file) => file.isImage).length,
      fileCount: files.where((file) => !file.isImage).length,
    );
    _actionError = null;
    notifyListeners();
    repository.retain();
    try {
      for (final file in files) {
        if (_closed) return false;
        if (_attachments.length >= 8) {
          throw const AttachmentDraftException(
            'A group message can include up to 8 attachments.',
          );
        }
        AttachmentDraft? draft;
        var retained = false;
        try {
          draft = file.isImage
              ? await _attachmentService.prepareImage(
                  sourcePath: file.path,
                  displayName: file.name,
                  existingDrafts: const [],
                )
              : await _attachmentService.prepareGenericFile(
                  sourcePath: file.path,
                  displayName: file.name,
                  mediaType: file.mediaType,
                  existingDrafts: const [],
                );
          if (_closed) return false;
          if (draft.byteLength > 15000000 ||
              _attachments.fold<int>(0, (size, item) => size + item.size) +
                      draft.byteLength >
                  25000000) {
            throw const AttachmentDraftException(
              'Group attachments allow 15 MB per file and 25 MB per message.',
            );
          }
          final data = await _attachmentService.readDataUrl(draft);
          final attachment = await repository.uploadGroupAttachment(
            group,
            uploadId: const Uuid().v4(),
            name: draft.name,
            mime: draft.mediaType,
            kind: draft.isImage
                ? 'image'
                : draft.mediaType == 'application/pdf'
                ? 'pdf'
                : 'file',
            dataBase64: data.substring(data.indexOf(',') + 1),
            canDispatch: () => !_closed,
          );
          if (_closed) return false;
          _attachments.add(attachment);
          _attachmentPreviews[attachment.id] = draft;
          retained = true;
          _draftRevision++;
          if (!atomic && !await _saveDraft()) {
            throw StateError('Draft persistence failed');
          }
          if (!_closed) notifyListeners();
        } finally {
          if (!retained && draft != null) {
            await _attachmentService.removeCachedFile(draft);
          }
        }
      }
      success = true;
    } catch (error) {
      if (atomic && !_closed) {
        final removed = _attachments
            .where((item) => !originalIds.contains(item.id))
            .toList();
        _attachments.removeWhere((item) => !originalIds.contains(item.id));
        for (final item in removed) {
          final preview = _attachmentPreviews.remove(item.id);
          if (preview != null) {
            await _attachmentService.removeCachedFile(preview);
          }
        }
        _draftRevision++;
      }
      if (!_closed) {
        _actionError = error is AttachmentDraftException
            ? error.message
            : 'The attachment could not be added. Your draft is kept. Choose the file again.';
      }
    } finally {
      repository.release();
      if (!_closed) {
        _attachmentPreparation = null;
        notifyListeners();
      }
    }
    return success;
  }

  AndroidSharePayload? _stagedShare;

  /// The shared intake stays unacknowledged until its whole batch is durable.
  Future<bool> stageSharedContent(AndroidSharePayload payload) async {
    if (!canAddAttachments) return false;
    final alreadyStaged =
        identical(_stagedShare, payload) ||
        (payload.id != null && _stagedShare?.id == payload.id);
    if (alreadyStaged) return await _saveDraft() && !_closed;
    if (!await addAttachments(payload.files, atomic: true) || _closed) {
      return false;
    }
    _stagedShare = payload;
    final text = payload.text;
    if (text != null && text.isNotEmpty) {
      _draft = _draft.isEmpty ? text : '$_draft\n$text';
      _draftRevision++;
      _references = retainComposerReferences(_draft, _references);
    }
    final saved = await _saveDraft();
    if (!_closed) notifyListeners();
    return saved && !_closed;
  }

  Future<void> removeAttachment(BotGroupAttachment attachment) async {
    if (!canAddAttachments) return;
    _attachments.removeWhere((item) => item.id == attachment.id);
    final preview = _attachmentPreviews.remove(attachment.id);
    _draftRevision++;
    notifyListeners();
    await _saveDraft();
    if (preview != null) await _attachmentService.removeCachedFile(preview);
  }

  Future<RemoteFileDownload> downloadAttachment(String target) async {
    if (_closed) throw StateError('The group was closed.');
    for (final event in _events.values) {
      for (final attachment in event.attachments) {
        if (attachment.target(event.eventId) != target) continue;
        final bytes = await repository.downloadGroupAttachment(
          group,
          event.eventId,
          attachment,
        );
        if (_closed) throw StateError('The group was closed.');
        return RemoteFileDownload(filename: attachment.name, bytes: bytes);
      }
    }
    throw StateError(
      'This attachment is not in the group history. Refresh the group.',
    );
  }

  String _draft = '';
  String get draftText => _draft;
  String? _draftError;
  int _draftRevision = 0;
  int _draftWriteRevision = 0;

  Future<bool> _saveDraft() async {
    final revision = _draftRevision;
    try {
      final saved = preferences.writeMessageDraft(
        group.scope.connectionIdentity,
        group.id,
        _draft,
        _references,
        attachments: _attachments,
        pendingEventId: _pending?.$1,
        pendingWireText: _pendingWireText,
        pendingText: _pending?.$2,
        reply: _reply,
      );
      _draftWriteRevision = preferences.messageDraftRevision(
        group.scope.connectionIdentity,
        group.id,
      );
      await saved;
      if (!_closed && revision == _draftRevision && _draftError != null) {
        _draftError = null;
        notifyListeners();
      }
      return true;
    } catch (_) {
      if (!_closed && revision == _draftRevision) {
        _draftError =
            'Draft could not be saved on this device. Edit your message to retry.';
        notifyListeners();
      }
      return false;
    }
  }

  RecentConversationKey get voiceTarget =>
      RecentConversationKey.group(group.key);
  bool get canDictate =>
      !_closed && _visible && !_capturing && !_sending && _pending == null;

  bool admitsDictation(RecentConversationKey target) =>
      canDictate && target == voiceTarget;

  BotGroupVoiceDraft captureVoiceDraft() {
    if (!canDictate) {
      throw StateError('This group is unavailable for dictation.');
    }
    return BotGroupVoiceDraft._(this, _draftRevision, _draft);
  }

  Future<void> applyVoiceDraft(BotGroupVoiceDraft capture, String text) {
    if (!canDictate ||
        !identical(capture._owner, this) ||
        capture._revision != _draftRevision) {
      throw StateError('The group draft changed. Please dictate again.');
    }
    unawaited(editMentions(text));
    return Future.value();
  }

  RemoteVoice voiceForGroup(RecentConversationKey target) {
    if (!admitsDictation(target)) {
      throw StateError('This group is unavailable for dictation.');
    }
    return repository.voiceForGroup(group);
  }

  final _events = <int, BotGroupEvent>{};
  BotRecord? appearance(String profile) {
    final matches = group.members.where((member) => member.profile == profile);
    return matches.length == 1
        ? _appearance.byHandle[matches.single.handle]
        : null;
  }

  BotGroupRuntime? _runtime;
  int _runtimeSequence = 0;
  BotGroupRuntime? get runtime => _runtime;

  late final questionHistory = preferences.questions(
    group.scope.connectionIdentity,
    group.id,
  );
  String? approvalError(BotGroupAction action) => _approvalErrors[action.key];
  final _approvalErrors = <String, String>{};

  List<BotGroupAction> get pendingApprovals {
    final current = runtime;
    return current == null
        ? const []
        : preferences.pendingApprovals(group, current);
  }

  int _recoveryRevision = 0;
  bool _acting = false;
  bool get acting => _acting;
  bool canResolve(BotGroupAction action) =>
      !_closed &&
      !_acting &&
      !_sending &&
      runtime?.supports(action.kind == 'approval' ? 'approve' : action.kind) ==
          true &&
      runtime?.actions.any((current) => current.key == action.key) == true;
  bool get canStopGroupWork =>
      !_closed &&
      !_acting &&
      runtime?.supports('stop') == true &&
      (runtime?.working == true ||
          runtime?.blocked == true ||
          _sending ||
          runtime?.actions.any((action) => action.kind == 'retry') == true);
  final _stopCancelIds = <String>{};
  bool get awaitingStopFence => _stopCancelIds.isNotEmpty;
  BotGroupContext? _savedContext;
  BotGroupContext? get context => _savedContext ?? runtime?.context;
  bool get canEditContext =>
      !_closed &&
      !_acting &&
      runtime?.supports('context') == true &&
      context != null;
  (BotGroupContext, String)? _contextAttempt;

  Future<bool> saveContext(BotGroupContext value) async {
    if (!canEditContext) return false;
    final validation = value.validate(group, runtime!.routingModes);
    if (validation != null) {
      _actionError = validation;
      notifyListeners();
      return false;
    }
    final attempt = _contextAttempt?.$1 == value
        ? _contextAttempt!
        : (value, const Uuid().v4());
    _contextAttempt = attempt;
    _recoveryRevision++;
    _acting = true;
    _actionError = null;
    repository.retain();
    notifyListeners();
    try {
      final saved = await repository.saveGroupContext(
        group,
        value,
        attempt.$2,
        () => !_closed,
      );
      if (_closed) return false;
      // A read begun during the write cannot replace its confirmed context.
      _recoveryRevision++;
      _savedContext = saved;
      _contextAttempt = null;
      return true;
    } catch (_) {
      if (!_closed) {
        _actionError =
            'Shared settings could not be confirmed. Review your draft and retry.';
      }
      return false;
    } finally {
      repository.release();
      if (!_closed) {
        _acting = false;
        notifyListeners();
      }
    }
  }

  /// Project the same bounded-discussion eligibility as stock from durable events.
  List<BotGroupContinuation> get boundedDiscussions {
    if (_closed ||
        _cursor < _runtimeSequence ||
        _readError != null ||
        runtime == null) {
      return const [];
    }
    final ordered = events;
    final bounded = <String, BotGroupEvent>{};
    final grants = <String, int>{};
    for (final event in ordered) {
      if (event.kind == 'room.continued') {
        grants[event.discussionEventId] = event.continueGrant;
        bounded.remove(event.discussionEventId);
      } else if (event.kind == 'room.activity' &&
          event.discussionEventId.isNotEmpty) {
        if (event.activityStatus == 'bounded') {
          bounded[event.discussionEventId] = event;
        } else {
          bounded.remove(event.discussionEventId);
        }
      }
    }
    return [
      for (final entry in bounded.entries)
        if (!ordered.any(
          (event) =>
              (event.kind == 'room.stop_requested' &&
                  event.sequence >
                      (ordered
                              .where((e) => e.eventId == entry.key)
                              .firstOrNull
                              ?.sequence ??
                          entry.value.sequence)) ||
              (event.kind == 'message.user' &&
                  event.sequence > entry.value.sequence &&
                  event.threadId == entry.value.threadId),
        ))
          BotGroupContinuation(
            entry.key,
            (grants[entry.key] ?? 0) + 1,
            text:
                ordered
                    .where((event) => event.eventId == entry.key)
                    .firstOrNull
                    ?.text ??
                '',
          ),
    ];
  }

  bool canContinue(BotGroupContinuation continuation) =>
      !_closed &&
      !_acting &&
      !_sending &&
      !awaitingStopFence &&
      runtime?.supports('continue') == true &&
      runtime?.maxContinues != null &&
      continuation.grant <= runtime!.maxContinues! &&
      boundedDiscussions.any(
        (current) =>
            current.discussionEventId == continuation.discussionEventId &&
            current.grant == continuation.grant,
      );

  List<BotGroupContinuation> get continuations =>
      boundedDiscussions.where(canContinue).toList();

  Future<void> continueDiscussion(BotGroupContinuation continuation) async {
    if (!canContinue(continuation)) {
      return;
    }
    _acting = true;
    _recoveryRevision++;
    _actionError = null;
    repository.retain();
    notifyListeners();
    try {
      await repository.continueGroup(
        group,
        continuation.discussionEventId,
        () => !_closed,
      );
    } catch (_) {
      if (!_closed) {
        _actionError =
            'Continue could not be confirmed. Refresh to check this discussion.';
      }
    } finally {
      repository.release();
      if (!_closed) {
        await refresh(explicit: false);
        _acting = false;
        notifyListeners();
      }
    }
  }

  List<BotGroupEvent> get events => List.unmodifiable(
    _events.values.toList()..sort((a, b) => a.sequence.compareTo(b.sequence)),
  );
  int _cursor = 0;
  bool _closed = false, _sending = false, _visible = false;
  Completer<void>? _readCompletion;
  bool _historyAvailable = false;
  bool get loading =>
      _readCompletion != null &&
      (_runtime == null || !reading.historyAvailable);
  bool get sending => _sending;
  String? _readError, _actionError;
  bool _showReadFailure = false;
  String? get error =>
      _actionError ??
      _draftError ??
      (_showReadFailure || !_historyAvailable ? _readError : null);
  (String, String)? _pending;
  String? _pendingWireText;
  List<BotGroupAttachment> _pendingAttachments = const [];
  String? get pendingText => _pending?.$2;
  Timer? _poll;
  bool _capturing = false;
  void setCapturing(bool value) {
    _capturing = value;
  }

  void setVisible(bool visible) {
    if (_closed || _visible == visible) return;
    _visible = visible;
    _poll?.cancel();
    if (visible) {
      unawaited(refresh(explicit: false));
      _poll = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(refresh(explicit: false)),
      );
    }
  }

  BotGroup? _retainedMessagesFor;
  int? _retainedMessagesThrough;

  /// The catalog supplies its exact current projection after facts publication.
  /// Replayed messages can seed a later route; this never advances read receipts
  /// or lets a cached transcript establish the replay cursor/runtime authority.
  void retainRecentMessages(BotGroup observed) {
    if (_closed || observed.key != group.key || !observed.observationComplete) {
      return;
    }
    final coverage = observed.messageCoverageSequence;
    if (coverage == null || coverage != _cursor) return;
    final cache = groupMessages;
    if (cache == null ||
        identical(_retainedMessagesFor, observed) &&
            _retainedMessagesThrough == _cursor) {
      return;
    }
    cache.record(observed, events, complete: true);
    _retainedMessagesFor = observed;
    _retainedMessagesThrough = _cursor;
  }

  /// Passive tail read for card previews. Never acquires visibility or receipts.
  Future<List<BotGroupEvent>> readRecentMessages({
    required int limit,
    required bool Function() canRead,
  }) async {
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    if (_closed || !canRead()) throw StateError('Group preview retired');
    if (group.scope != repository.scope) {
      throw StateError('Group belongs to another instance');
    }
    final cached = groupMessages?.borrow(group, limit: limit);
    if (cached != null) return cached;
    final messages = <BotGroupEvent>[];
    var end = group.latestSequence ?? 0;
    while (end > 0 && messages.length < limit) {
      if (_closed || !canRead()) throw StateError('Group preview retired');
      final start = (end - 100).clamp(0, end);
      final events = await repository.groupLogWindow(
        group,
        start: start,
        end: end,
        canRead: () => !_closed && canRead(),
      );
      if (_closed || !canRead()) throw StateError('Group preview retired');
      messages.insertAll(0, events.where((event) => event.isTranscriptEntry));
      end = start;
    }
    return List.unmodifiable(
      messages.skip((messages.length - limit).clamp(0, messages.length)),
    );
  }

  /// Concurrent callers await the same runtime/log read through settlement.
  Future<void> refresh({bool explicit = true}) {
    if (_closed || _capturing) return Future.value();
    if (_readCompletion case final active?) {
      _showReadFailure |= explicit;
      return active.future;
    }
    _showReadFailure = explicit;
    final completion = Completer<void>();
    _readCompletion = completion;
    unawaited(_refresh(completion));
    return completion.future;
  }

  Future<void> _refresh(Completer<void> completion) async {
    final revision = _recoveryRevision;
    notifyListeners();
    try {
      final observed = await repository.groupRuntime(group);
      final nextRuntime = observed.runtime;
      if (_closed || _capturing || revision != _recoveryRevision) return;
      _runtime = nextRuntime;
      _runtimeSequence = observed.sequence;
      _savedContext = null;
      preferences.observeQuestions(group, nextRuntime, observed.sequence);
      final pendingKeys = nextRuntime.actions
          .map((action) => action.key)
          .toSet();
      final retiredErrors = _approvalErrors.entries
          .where((entry) => !pendingKeys.contains(entry.key))
          .toList();
      if (retiredErrors.any((entry) => entry.value == _actionError)) {
        _actionError = null;
      }
      _approvalErrors.removeWhere((key, _) => !pendingKeys.contains(key));
      // Approval visibility must not wait on replay or device persistence.
      notifyListeners();
      {
        try {
          await questionHistory.flush();
        } catch (_) {
          if (!_closed) {
            _actionError =
                'Approval details could not be saved on this device.';
          }
        }
      }
      final observation = repository.groupObservations.beginRead(group);
      var complete = false;
      try {
        do {
          final page = await repository.groupLog(group, since: _cursor);
          if (_closed || _capturing || revision != _recoveryRevision) return;
          if (page.hasMore && page.cursor == _cursor) {
            throw StateError('Group log did not advance');
          }
          observation.add(page, since: _cursor);
          for (final event in page.events) {
            _events[event.sequence] = event;
            if (event.kind == 'room.stop_requested') {
              _stopCancelIds.remove(event.cancelId);
            }
          }
          _cursor = page.cursor;
          if (!page.hasMore) {
            complete = true;
            break;
          }
        } while (!_closed && _visible);
      } finally {
        if (!_closed && !_capturing && revision == _recoveryRevision) {
          observation.publish();
        }
      }
      if (_pending case final pending?) {
        if (_events.values.any(
          (event) =>
              event.eventId == BotsRepository.groupUserEventId(pending.$1),
        )) {
          final ids = _pendingAttachments.map((item) => item.id).toSet();
          _attachments.removeWhere((item) => ids.contains(item.id));
          _pending = null;
          _pendingWireText = null;
          _pendingAttachments = const [];
          if (_draft.trim() == pending.$2) {
            _draft = '';
            _reply = null;
            _draftRevision++;
            _references = const [];
          }
          await _acknowledgeDraft(pending, ids);
        }
      }
      if (_closed || _capturing || revision != _recoveryRevision) return;
      _historyAvailable = true;
      _readError = null;
      if (complete) _reportReadOutcome(null);
    } catch (_) {
      if (!_closed && !_capturing && revision == _recoveryRevision) {
        _readError = 'Group updates could not refresh. Your messages are kept.';
        _reportReadOutcome(_readError);
      }
    } finally {
      _readCompletion = null;
      if (!_closed) notifyListeners();
      completion.complete();
      if (!_closed && !_capturing && revision != _recoveryRevision) {
        unawaited(refresh(explicit: false));
      }
    }
  }

  void _reportReadOutcome(String? error) => onOperationalError?.call(
    OperationalErrorObservation(
      connectionIdentity: group.scope.connectionIdentity,
      operation: 'group-updates:${group.id}',
      title: 'Group updates unavailable',
      error: error,
      profileName: group.scope.profileName,
    ),
  );

  Future<void> _acknowledgeDraft(
    (String, String) attempt,
    Set<String> attachmentIds,
  ) async {
    try {
      await preferences.acknowledgeMessageDraft(
        group.scope.connectionIdentity,
        group.id,
        attempt.$1,
        attempt.$2,
        attachmentIds,
      );
    } catch (_) {
      if (!_closed) {
        _draftError =
            'Message sent. The saved draft could not be cleared on this device.';
      }
    }
  }

  Future<bool> send(String text) async {
    if (_closed ||
        _sending ||
        _acting ||
        _attachmentPreparation != null ||
        (text.trim().isEmpty && _attachments.isEmpty)) {
      return false;
    }
    if (_pending != null && _pending!.$2 != text.trim()) {
      _actionError =
          'Retry the unconfirmed message before sending a different one.';
      notifyListeners();
      return false;
    }
    final isNew = _pending == null;
    final attempt = _pending ?? (const Uuid().v4(), text.trim());
    final draftRevision = _draftRevision;
    _pending = attempt;
    _sending = true;
    _actionError = null;
    repository.retain();
    notifyListeners();
    var dispatched = false;
    int? sequence;
    try {
      await beforeSend?.call(group, attempt.$1);
      if (isNew) {
        final references = retainComposerReferences(attempt.$2, _references);
        if (references.isNotEmpty) {
          final members = await repository.groupMembers(group);
          if (_closed) return false;
          for (final ref in references) {
            if (ref.target == 'everyone' && ref.token == '@everyone') continue;
            final captured = group.members
                .where((member) => member.id == ref.target)
                .firstOrNull;
            if (captured == null ||
                !members.any(
                  (member) =>
                      member.id == captured.id &&
                      member.handle == captured.handle &&
                      member.profile == captured.profile,
                )) {
              _pending = null;
              _pendingWireText = null;
              _actionError =
                  'A mentioned member is unavailable. Correct the mention before sending.';
              return false;
            }
          }
        }
        _pendingWireText = _canonicalText(attempt.$2, references);
        _pendingAttachments = List.unmodifiable(_attachments);
      }
      if (!await _saveDraft() || _closed) return false;
      sequence = await repository.sendGroup(
        group,
        attempt.$1,
        _pendingWireText!,
        () => !_closed,
        () {
          dispatched = true;
        },
        attachments: _pendingAttachments,
        threadId: _reply?.threadId,
      );
      final sentIds = _pendingAttachments.map((item) => item.id).toSet();
      _attachments.removeWhere((item) => sentIds.contains(item.id));
      _pendingAttachments = const [];
      for (final id in sentIds) {
        final preview = _attachmentPreviews.remove(id);
        if (preview != null) {
          unawaited(_attachmentService.removeCachedFile(preview));
        }
      }
      _pending = null;
      _pendingWireText = null;
      if (_draftRevision == draftRevision &&
          _draft.trim() == attempt.$2 &&
          preferences.messageDraftRevision(
                group.scope.connectionIdentity,
                group.id,
              ) ==
              _draftWriteRevision) {
        _draft = '';
        _reply = null;
        _draftRevision++;
        _references = const [];
        if (!_closed) notifyListeners();
      }
      await _acknowledgeDraft(attempt, sentIds);
      if (!_closed) unawaited(refresh(explicit: false));
      return !_closed;
    } catch (error) {
      if (!_closed) {
        final refused = error is BotGroupSendRefused;
        if (!dispatched || refused) {
          if (refused) dispatched = false;
          _pending = null;
          _pendingWireText = null;
          _pendingAttachments = const [];
          await _saveDraft();
        }
        _actionError = refused
            ? 'Message was refused: ${error.message} Edit your draft and send again.'
            : dispatched
            ? 'Message not confirmed. Retry sends the same message once.'
            : 'The message could not be sent. Your text is kept. Retry.';
      }
      return false;
    } finally {
      try {
        await afterSend?.call(group, (
          eventId: attempt.$1,
          dispatched: dispatched,
          sequence: sequence,
        ));
      } finally {
        repository.release();
        if (!_closed) {
          _sending = false;
          notifyListeners();
        }
      }
    }
  }

  Future<void> resolve(BotGroupAction action, {String? choice}) async {
    if (action.kind == 'retry') {
      await _retryWork(action);
      return;
    }
    if (!canResolve(action) ||
        !pendingApprovals.any((a) => a.key == action.key)) {
      return;
    }
    _recoveryRevision++;
    _acting = true;
    _actionError = null;
    _approvalErrors.remove(action.key);
    repository.retain();
    notifyListeners();
    try {
      await repository.resolveGroup(
        group,
        action,
        choice,
        () => !_closed,
        () {},
      );
      questionHistory.settle(
        action.key,
        HermesQuestionStatus.decision(choice!),
      );
      if (!_closed) notifyListeners();
      try {
        await questionHistory.flush();
      } catch (_) {
        if (!_closed) {
          _actionError =
              'Decision accepted; its details could not be saved on this device.';
        }
      }
    } catch (_) {
      if (!_closed) {
        _actionError =
            'Group action could not be confirmed. Refresh before trying again.';
        _approvalErrors[action.key] = _actionError!;
      }
    } finally {
      repository.release();
      if (!_closed) {
        _acting = false;
        notifyListeners();
        unawaited(refresh(explicit: false));
      }
    }
  }

  Future<void> _retryWork(BotGroupAction action) async {
    if (!canResolve(action)) {
      return;
    }
    _recoveryRevision++;
    _acting = true;
    _actionError = null;
    repository.retain();
    notifyListeners();
    try {
      await repository.resolveGroup(group, action, null, () => !_closed, () {});
      if (_runtime case final value? when !_closed) {
        _runtime = value.withActions(
          value.actions.where((current) => current.key != action.key),
        );
      }
    } catch (_) {
      if (!_closed) {
        _actionError =
            '${action.kind == 'discard' ? 'Discard' : 'Retry'} could not be confirmed. Refresh the group before retrying.';
      }
    } finally {
      repository.release();
      if (!_closed) {
        _acting = false;
        notifyListeners();
        unawaited(refresh(explicit: false));
      }
    }
  }

  Future<void> discard(BotGroupAction action) async {
    if (action.kind != 'discard') return;
    await _retryWork(action);
  }

  void _forgetStoppedActions() {
    _recoveryRevision++;
    if (_runtime case final value?) {
      _runtime = value.withActions(const []);
    }
  }

  Future<void> stop() async {
    if (!canStopGroupWork) return;
    _recoveryRevision++;
    _acting = true;
    _actionError = null;
    repository.retain();
    notifyListeners();
    final cancelId = const Uuid().v4();
    try {
      await repository.groupAction(group, 'stop', cancelId, () => !_closed, () {
        // An earlier timed-out request can still commit after this one. Each
        // dispatched cancellation therefore needs its own observed fence.
        _stopCancelIds.add(cancelId);
      });
      _forgetStoppedActions();
      await refresh(explicit: false);
    } catch (failure) {
      // Stock checks these refusals before entering stop_room. Other errors can
      // follow the durable fence, including errors while cancelling member work.
      final refused =
          failure is JsonRpcError &&
          failure.method == 'groups.stop' &&
          const {
            'permission_denied',
            'profile_mismatch',
            'runtime_coordination_required',
          }.contains(failure.reason);
      if (refused) _stopCancelIds.remove(cancelId);
      if (!_closed) _actionError = 'Stop could not be confirmed.';
    } finally {
      repository.release();
      if (!_closed) {
        _acting = false;
        notifyListeners();
        unawaited(refresh(explicit: false));
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _attachmentService.cancelImagePreparations();
    for (final draft in _attachmentPreviews.values) {
      unawaited(_attachmentService.removeCachedFile(draft));
    }
    appearances.removeListener(_appearanceChanged);
    _poll?.cancel();
    repository.release();
    super.dispose();
  }
}

/// Discussion input adapter. It lends reading facts to the same transcript used
/// by Bot Chats and Group history, without lending room command authority.
final class BotGroupTranscriptReading implements TranscriptReader {
  BotGroupTranscriptReading._(this._session);
  final BotGroupSession _session;
  late final _readingMemory = _session.preferences.readingPositions.group(
    _session.group.key,
  );
  @override
  Iterable<PositionedHermesQuestion> get requestActivities =>
      _session.questionHistory.activities;
  @override
  List<Map<String, dynamic>> get messages => [
    for (final event in _session.events.where(
      (event) => event.isTranscriptEntry,
    ))
      Map<String, dynamic>.unmodifiable({
        'id': event.sequence,
        'sequence': event.sequence,
        'timestamp': event.timestamp.millisecondsSinceEpoch / 1000,
        'role': event.kind == 'message.user' ? 'user' : 'assistant',
        'content': event.isPass ? 'Passed' : event.text,
        '_discussion_event': event,
      }),
  ];
  TranscriptMessage messageForRow(Map<String, dynamic> row) =>
      TranscriptMessage.discussion(
        group: _session.group,
        event: row['_discussion_event'] as BotGroupEvent,
      );
  @override
  Object messagePresentationId(Map<String, dynamic> row) =>
      ('group-message', (row['_discussion_event'] as BotGroupEvent).sequence);
  @override
  String? get historySessionId =>
      _session.loading && messages.isEmpty ? null : _session.group.id;
  @override
  int? get nextHistoryOffset => null;
  @override
  bool get historyLoading => _session.loading;
  @override
  bool get historyPaging => false;
  @override
  String? get historyError => null; // The room owner presents its operation errors.
  @override
  bool get historyUnavailable => false;
  @override
  bool get historyAvailable =>
      _session._historyAvailable ||
      _session._events.values.any((event) => event.isTranscriptEntry);
  @override
  TranscriptPosition get readingPosition => _readingMemory.position;
  @override
  String get streaming => '';
  @override
  void recordReading(TranscriptBookmark? resume, {int? readThrough}) =>
      _readingMemory.record(resume, readThrough: readThrough);
}
