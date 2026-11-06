import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'hermes_profile.dart';
import 'profile_session_key.dart';
import 'profile_colors.dart';

enum BotPresence { idle, working, groupWorking, needsInput, unknown }

const botShapes = [
  'circle',
  'blob',
  'squircle',
  'pill',
  'triangle',
  'hexagon',
  'cloud',
  'drop',
];

/// A roster observation belongs to an exact instance and canonical profile.
@immutable
class BotRecord {
  BotRecord({
    required this.scope,
    required this.instance,
    required this.profile,
    required this.title,
    required this.shape,
    required this.color,
    required this.pinned,
    required this.hidden,
    required this.hasAvatar,
    required this.revision,
    required Map<String, Object?> metadata,
    this.chat,
    this.resolvedChat,
    this.workerLastActive,
    this.lastActive,
    this.canonicalLastActive,
    this.preview = '',
    this.presence = BotPresence.unknown,
  }) : metadata = Map.unmodifiable(metadata);

  final WorkspaceScope scope;
  final String instance, title, shape, color, preview;
  final HermesProfile profile;
  final bool pinned, hidden, hasAvatar;
  final int revision;
  // Opaque, recursively frozen stock metadata. Only the repository merges it.
  final Map<String, Object?> metadata;

  /// Only an explicit stock choice admits procedural motion. The displayed
  /// shape can be a client default, so it is not sufficient by itself.
  bool get hasExplicitClassicShape =>
      metadata['imageKind'] == 'shape' &&
      metadata['shape'] == shape &&
      botShapes.contains(shape);
  final ProfileSessionKey? chat;
  final ProfileSessionKey? resolvedChat;

  /// Profile-owned background work reported by stock profiles.list.
  final DateTime? workerLastActive;

  /// Newest stock conversation or worker activity for this profile.
  final DateTime? lastActive;

  /// Canonical activity only; worker/ordinary activity never ranks warm images.
  final DateTime? canonicalLastActive;

  static int compareForRoster(BotRecord a, BotRecord b) {
    final activity = switch ((a.lastActive, b.lastActive)) {
      (final DateTime left, final DateTime right) => right.compareTo(left),
      (null, final DateTime _) => 1,
      (final DateTime _, null) => -1,
      (null, null) => 0,
    };
    if (activity != 0) return activity;
    final pin = (b.pinned ? 1 : 0).compareTo(a.pinned ? 1 : 0);
    if (pin != 0) return pin;
    final title = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return title != 0 ? title : a.id.compareTo(b.id);
  }

  bool describesConversation(ProfileSessionKey key) =>
      key == chat || key == resolvedChat;
  final BotPresence presence;
  String get id => '${scope.connectionIdentity}/${profile.name}';

  BotRecord withPresence(BotPresence value) => BotRecord(
    scope: scope,
    instance: instance,
    profile: profile,
    title: title,
    shape: shape,
    color: color,
    pinned: pinned,
    hidden: hidden,
    hasAvatar: hasAvatar,
    revision: revision,
    metadata: metadata,
    chat: chat,
    resolvedChat: resolvedChat,
    workerLastActive: workerLastActive,
    lastActive: lastActive,
    canonicalLastActive: canonicalLastActive,
    preview: preview,
    presence: value,
  );

  BotRecord withAvatarHint(bool value) => BotRecord(
    scope: scope,
    instance: instance,
    profile: profile,
    title: title,
    shape: shape,
    color: color,
    pinned: pinned,
    hidden: hidden,
    hasAvatar: value,
    revision: revision,
    metadata: metadata,
    chat: chat,
    resolvedChat: resolvedChat,
    workerLastActive: workerLastActive,
    lastActive: lastActive,
    canonicalLastActive: canonicalLastActive,
    preview: preview,
    presence: presence,
  );

  BotRecord withMetadata({
    required Map<String, Object?> metadata,
    required int revision,
    String? title,
    String? shape,
    String? color,
    bool? pinned,
    bool? hidden,
  }) => BotRecord(
    scope: scope,
    instance: instance,
    profile: profile,
    title: title ?? this.title,
    shape: shape ?? this.shape,
    color: color ?? this.color,
    pinned: pinned ?? this.pinned,
    hidden: hidden ?? this.hidden,
    hasAvatar: hasAvatar,
    revision: revision,
    metadata: metadata,
    chat: chat,
    resolvedChat: resolvedChat,
    workerLastActive: workerLastActive,
    lastActive: lastActive,
    canonicalLastActive: canonicalLastActive,
    preview: preview,
    presence: presence,
  );
}

@immutable
class BotGroupMember {
  const BotGroupMember({
    required this.id,
    required this.profile,
    required this.handle,
    required this.name,
  });
  final String id, profile, handle, name;
}

@immutable
/// Immutable member display observations borrowed from the canonical owner.
final class BotGroupAppearance {
  const BotGroupAppearance.empty() : byHandle = const {};
  BotGroupAppearance._(Map<String, BotRecord> appearances)
    : byHandle = Map.unmodifiable(appearances);

  factory BotGroupAppearance.forGroup(
    BotGroup group,
    Iterable<BotRecord> bots,
  ) {
    final appearances = <String, BotRecord>{};
    for (final member in group.members) {
      final matches = bots.where(
        (bot) =>
            bot.scope.connectionId == group.scope.connectionId &&
            bot.scope.connectionIdentity == group.scope.connectionIdentity &&
            bot.profile.name == member.profile,
      );
      if (matches.length == 1) appearances[member.handle] = matches.single;
    }
    return BotGroupAppearance._(appearances);
  }

  final Map<String, BotRecord> byHandle;
  @override
  bool operator ==(Object other) =>
      other is BotGroupAppearance && mapEquals(byHandle, other.byHandle);
  @override
  int get hashCode => Object.hashAllUnordered(
    byHandle.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

class BotGroup {
  BotGroup({
    required this.scope,
    required this.instance,
    required this.id,
    required this.name,
    required Iterable<BotGroupMember> members,
    required this.observationComplete,
    this.runtimeAvailable = false,
    this.latestSequence,
    this.messageCoverageSequence,
    this.preview = '',
    this.working = false,
    this.blocked = false,
    Iterable<String> activeMemberProfiles = const [],
    this.lastMessageAt,
    this.lastMessageSequence = 0,
    this.lastAnswerSequence = 0,
    this.pinned = false,
    this.iconColor,
    this.iconRevision,
    Uint8List? picture,
  }) : members = List.unmodifiable(members),
       activeMemberProfiles = Set.unmodifiable(activeMemberProfiles),
       picture = picture?.asUnmodifiableView();
  final WorkspaceScope scope;
  final String instance, id, name, preview;
  final List<BotGroupMember> members;
  final bool working, blocked;

  /// Profiles with exact queued, running or stopping tasks in this observation.
  /// Retained room details never carry this positive activity into a failed read.
  final Set<String> activeMemberProfiles;

  /// Runtime availability does not establish message coverage.
  final bool runtimeAvailable;
  final int? latestSequence, messageCoverageSequence;

  /// False means the latest message observation failed; retained facts may exist.
  final bool observationComplete;
  final DateTime? lastMessageAt;
  final int lastMessageSequence, lastAnswerSequence;
  final bool pinned;
  final Uint8List? picture;
  final ProfileColorChoice? iconColor;

  /// Null means the backend icon metadata was not admitted for editing.
  final int? iconRevision;
  String get key => '${scope.connectionIdentity}/$id';
  BotGroup withDetails({
    required String name,
    required ProfileColorChoice color,
    required Uint8List? picture,
    required int revision,
  }) => BotGroup(
    scope: scope,
    instance: instance,
    id: id,
    name: name,
    members: members,
    observationComplete: observationComplete,
    runtimeAvailable: runtimeAvailable,
    latestSequence: latestSequence,
    messageCoverageSequence: messageCoverageSequence,
    preview: preview,
    working: working,
    blocked: blocked,
    activeMemberProfiles: activeMemberProfiles,
    lastMessageAt: lastMessageAt,
    lastMessageSequence: lastMessageSequence,
    lastAnswerSequence: lastAnswerSequence,
    pinned: pinned,
    picture: picture,
    iconColor: color,
    iconRevision: revision,
  );
  BotGroup withPinned(bool value) => BotGroup(
    scope: scope,
    instance: instance,
    id: id,
    name: name,
    members: members,
    observationComplete: observationComplete,
    runtimeAvailable: runtimeAvailable,
    latestSequence: latestSequence,
    messageCoverageSequence: messageCoverageSequence,
    preview: preview,
    working: working,
    blocked: blocked,
    activeMemberProfiles: activeMemberProfiles,
    lastMessageAt: lastMessageAt,
    lastMessageSequence: lastMessageSequence,
    lastAnswerSequence: lastAnswerSequence,
    pinned: value,
    picture: picture,
    iconColor: iconColor,
    iconRevision: iconRevision,
  );
  BotGroup withIcon({
    Uint8List? picture,
    ProfileColorChoice? color,
    int? revision,
  }) => BotGroup(
    scope: scope,
    instance: instance,
    id: id,
    name: name,
    members: members,
    observationComplete: observationComplete,
    runtimeAvailable: runtimeAvailable,
    latestSequence: latestSequence,
    messageCoverageSequence: messageCoverageSequence,
    preview: preview,
    working: working,
    blocked: blocked,
    activeMemberProfiles: activeMemberProfiles,
    lastMessageAt: lastMessageAt,
    lastMessageSequence: lastMessageSequence,
    lastAnswerSequence: lastAnswerSequence,
    pinned: pinned,
    picture: picture,
    iconColor: color,
    iconRevision: revision,
  );

  /// Catalog facts replace identity without invalidating runtime or messages.
  BotGroup withCatalogObservation(
    BotGroup observed, {
    bool retainIdentity = false,
  }) {
    if (key != observed.key) {
      throw ArgumentError('Wrong group catalog owner');
    }
    return BotGroup(
      scope: scope,
      instance: instance,
      id: id,
      name: retainIdentity ? name : observed.name,
      members: retainIdentity ? members : observed.members,
      observationComplete: observationComplete,
      runtimeAvailable: runtimeAvailable,
      latestSequence: latestSequence,
      messageCoverageSequence: messageCoverageSequence,
      preview: preview,
      working: working,
      blocked: blocked,
      activeMemberProfiles: activeMemberProfiles.where(
        (profile) => (retainIdentity ? members : observed.members).any(
          (member) => member.profile == profile,
        ),
      ),
      lastMessageAt: lastMessageAt,
      lastMessageSequence: lastMessageSequence,
      lastAnswerSequence: lastAnswerSequence,
      pinned: pinned,
      picture: observed.picture,
      iconColor: observed.iconColor,
      iconRevision: observed.iconRevision,
    );
  }

  /// A slower preview may publish messages without replacing newer status.
  BotGroup withMessageObservation(BotGroup observed) {
    if (key != observed.key) {
      throw ArgumentError('Wrong group message owner');
    }
    final latest = latestSequence;
    final incoming = observed.latestSequence;
    final newerMessage = observed.lastMessageSequence >= lastMessageSequence;
    final coverage = messageCoverageSequence;
    final incomingCoverage = observed.messageCoverageSequence;
    return BotGroup(
      scope: scope,
      instance: instance,
      id: id,
      name: name,
      members: members,
      observationComplete: observed.observationComplete,
      runtimeAvailable: runtimeAvailable,
      latestSequence: latest == null
          ? incoming
          : incoming == null || latest >= incoming
          ? latest
          : incoming,
      messageCoverageSequence: coverage == null
          ? incomingCoverage
          : incomingCoverage == null || coverage >= incomingCoverage
          ? coverage
          : incomingCoverage,
      preview: newerMessage ? observed.preview : preview,
      working: working,
      blocked: blocked,
      activeMemberProfiles: activeMemberProfiles,
      lastMessageAt: newerMessage ? observed.lastMessageAt : lastMessageAt,
      lastMessageSequence: newerMessage
          ? observed.lastMessageSequence
          : lastMessageSequence,
      lastAnswerSequence: observed.lastAnswerSequence > lastAnswerSequence
          ? observed.lastAnswerSequence
          : lastAnswerSequence,
      pinned: pinned,
      picture: picture,
      iconColor: iconColor,
      iconRevision: iconRevision,
    );
  }

  /// Keep confirmed messages after a failed message read, using current runtime.
  BotGroup withRetainedObservation(BotGroup previous) {
    if (key != previous.key || observationComplete) {
      throw ArgumentError(
        'Expected the same room with an unavailable observation',
      );
    }
    return BotGroup(
      scope: scope,
      instance: instance,
      id: id,
      name: name,
      members: members,
      observationComplete: false,
      runtimeAvailable: runtimeAvailable,
      latestSequence: latestSequence,
      messageCoverageSequence: previous.messageCoverageSequence,
      preview: previous.preview,
      working: working,
      blocked: blocked,
      activeMemberProfiles: activeMemberProfiles,
      lastMessageAt: previous.lastMessageAt,
      lastMessageSequence: previous.lastMessageSequence,
      lastAnswerSequence: previous.lastAnswerSequence,
      pinned: pinned,
      picture: picture,
      iconColor: iconColor,
      iconRevision: iconRevision,
    );
  }
}

/// A known room read separates room validity from optional live driver facts.
final class BotGroupState {
  BotGroupState({
    required this.room,
    required this.roomAvailable,
    this.latestSequence,
    this.runtimeAvailable = false,
    this.working = false,
    this.blocked = false,
    this.memberActivity = const [],
  });
  final List<BotGroupMemberActivity> memberActivity;
  final BotGroup room;
  final bool roomAvailable, runtimeAvailable, working, blocked;
  final int? latestSequence;
  Set<String> get activeMemberProfiles => runtimeAvailable
      ? Set.unmodifiable(
          room.members
              .where(
                (member) => memberActivity.any(
                  (activity) => activity.memberId == member.id,
                ),
              )
              .map((member) => member.profile),
        )
      : const {};

  /// Replace runtime and incidentally read identity, retaining confirmed messages.
  BotGroup applyTo(BotGroup previous) {
    if (room.key != previous.key) {
      throw ArgumentError('Wrong group state owner');
    }
    return BotGroup(
      scope: previous.scope,
      instance: previous.instance,
      id: previous.id,
      name: roomAvailable ? room.name : previous.name,
      members: roomAvailable ? room.members : previous.members,
      observationComplete: previous.observationComplete,
      runtimeAvailable: runtimeAvailable,
      latestSequence: latestSequence ?? previous.latestSequence,
      messageCoverageSequence: previous.messageCoverageSequence,
      preview: previous.preview,
      working: runtimeAvailable && working,
      blocked: runtimeAvailable && blocked,
      activeMemberProfiles: activeMemberProfiles,
      lastMessageAt: previous.lastMessageAt,
      lastMessageSequence: previous.lastMessageSequence,
      lastAnswerSequence: previous.lastAnswerSequence,
      pinned: previous.pinned,
      picture: previous.picture,
      iconColor: previous.iconColor,
      iconRevision: previous.iconRevision,
    );
  }
}

class BotGroupEditConflict implements Exception {
  const BotGroupEditConflict(this.message);
  final String message;
  @override
  String toString() => message;
}

final class BotGroupSendRefused implements Exception {
  const BotGroupSendRefused(this.message);
  final String message;
}

/// Canonical room manifest. Storage paths and upload receipts never enter Send.
@immutable
final class BotGroupAttachment {
  const BotGroupAttachment({
    required this.id,
    required this.kind,
    required this.name,
    required this.mime,
    required this.size,
  });
  final String id, kind, name, mime;
  final int size;
  bool get isImage => kind == 'image';
  Map<String, dynamic> toJson() => {
    'attachment_id': id,
    'kind': kind,
    'name': name,
    'mime': mime,
    'size': size,
  };
  factory BotGroupAttachment.fromJson(Map<String, dynamic> value) {
    final id = value['attachment_id'];
    final name = value['name'];
    final mime = value['mime'];
    final size = value['size'];
    final kind = value['kind'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        name.isEmpty ||
        name.contains(RegExp(r'[/\\\n\r]')) ||
        name == '.' ||
        name == '..' ||
        mime is! String ||
        mime.isEmpty ||
        size is! int ||
        size < 1 ||
        size > 15000000 ||
        !const {'image', 'pdf', 'file'}.contains(kind)) {
      throw const FormatException('Invalid group attachment');
    }
    return BotGroupAttachment(
      id: id,
      kind: kind as String,
      name: name,
      mime: mime,
      size: size,
    );
  }
  String target(String eventId) => Uri(
    pathSegments: ['', 'group-attachments', eventId, id, name],
  ).toString();
}

@immutable
class BotGroupEvent {
  const BotGroupEvent({
    required this.sequence,
    required this.eventId,
    required this.kind,
    required this.actor,
    required this.actorId,
    required this.actorName,
    required this.timestamp,
    required this.text,
    this.passedMemberId,
    this.attachments = const [],
    this.threadId = '',
    this.discussionEventId = '',
    this.activityStatus = '',
    this.cancelId = '',
    this.continueGrant = 0,
  });
  final int sequence;
  final String eventId, kind, actor, actorId, actorName, text;
  final DateTime timestamp;

  /// Passed turns are gateway-authored; their speaker lives in the payload.
  final String? passedMemberId;
  final List<BotGroupAttachment> attachments;
  final String threadId, discussionEventId, activityStatus, cancelId;
  final int continueGrant;
  bool get isMessage => kind == 'message.user' || kind == 'message.member';
  bool get isPass => kind == 'turn.settled' && passedMemberId != null;
  bool get isTranscriptEntry => isMessage || isPass;
  String get memberId => isPass ? passedMemberId! : actorId;
}

@immutable
class BotGroupPage {
  BotGroupPage(
    Iterable<BotGroupEvent> events,
    this.cursor,
    this.hasMore, {
    required this.latestSequence,
    required this.gatewayId,
    required this.epoch,
  }) : events = List.unmodifiable(events);
  final List<BotGroupEvent> events;
  final int cursor;
  final bool hasMore;
  final int latestSequence, epoch;
  final String gatewayId;
}

@immutable
class BotGroupAction {
  BotGroupAction({
    required this.kind,
    required this.task,
    this.member = '',
    this.request = '',
    this.generation = 0,
    this.command = '',
    this.description = '',
    Iterable<String> choices = const [],
  }) : choices = List.unmodifiable(choices);
  final String kind, task, member, request, command, description;
  final int generation;
  final List<String> choices;
  String get key => '$kind/$task/$member/$request/$generation';
}

@immutable
final class BotGroupMemberActivity {
  const BotGroupMemberActivity({
    required this.memberId,
    required this.status,
    this.tool,
    this.startedAt,
    this.progressAt,
    this.threadId = '',
    this.roundIndex,
  });
  final String memberId;
  final String status;
  final String? tool;
  final DateTime? startedAt, progressAt;
  final String threadId;
  final int? roundIndex;
}

@immutable
final class BotGroupContext {
  const BotGroupContext({
    this.purpose = '',
    this.notes = '',
    this.routing = 'everyone',
    this.leadMemberId = '',
  });
  final String purpose, notes, routing, leadMemberId;
  String? validate(BotGroup group, Iterable<String> routingModes) {
    if (purpose.runes.length > 500) {
      return 'Purpose allows up to 500 characters.';
    }
    if (utf8.encode(notes).length > 4096) {
      return 'Shared notes allow up to 4 KB of text.';
    }
    if (!routingModes.contains(routing)) {
      return 'This routing mode is unavailable.';
    }
    if (routing == 'lead' && !group.members.any((m) => m.id == leadMemberId)) {
      return 'Choose a lead from this group.';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'purpose': purpose,
    'notes': notes,
    'routing': routing,
    'lead_member_id': routing == 'lead' ? leadMemberId : '',
  };
  @override
  bool operator ==(Object other) =>
      other is BotGroupContext &&
      purpose == other.purpose &&
      notes == other.notes &&
      routing == other.routing &&
      leadMemberId == other.leadMemberId;
  @override
  int get hashCode => Object.hash(purpose, notes, routing, leadMemberId);
}

@immutable
final class BotGroupContinuation {
  const BotGroupContinuation(
    this.discussionEventId,
    this.grant, {
    this.text = '',
  });
  final String discussionEventId;
  final int grant;
  final String text;
}

@immutable
class BotGroupRuntime {
  BotGroupRuntime({
    required this.working,
    required this.blocked,
    required Iterable<BotGroupAction> actions,
    Iterable<BotGroupMemberActivity> memberActivity = const [],
    this.context,
    Iterable<String> methods = const [],
    Iterable<String> routingModes = const [],
    this.maxRounds,
    this.maxContinues,
    this.lastError,
  }) : actions = List.unmodifiable(actions),
       methods = Set.unmodifiable(methods),
       routingModes = List.unmodifiable(routingModes),
       memberActivity = List.unmodifiable(memberActivity);
  final bool working, blocked;
  final List<BotGroupAction> actions;
  final List<BotGroupMemberActivity> memberActivity;
  final BotGroupContext? context;
  final Set<String> methods;
  final List<String> routingModes;
  final int? maxRounds, maxContinues;
  final String? lastError;
  bool supports(String action) => methods.contains('groups.$action');
  BotGroupRuntime withActions(Iterable<BotGroupAction> next) => BotGroupRuntime(
    working: working,
    blocked: blocked,
    actions: next,
    memberActivity: memberActivity,
    context: context,
    methods: methods,
    routingModes: routingModes,
    maxRounds: maxRounds,
    maxContinues: maxContinues,
    lastError: lastError,
  );
}

@immutable
class BotsSnapshot {
  BotsSnapshot({
    required this.botsAvailable,
    required this.groupsAvailable,
    Iterable<BotRecord> bots = const [],
    Iterable<BotGroup> groups = const [],
    this.loading = false,
    this.busy = false,
    Iterable<String> errors = const [],
    Iterable<String> groupHosts = const [],
    Iterable<BotInstance> instances = const [],
  }) : bots = List.unmodifiable(bots),
       groups = List.unmodifiable(groups),
       errors = List.unmodifiable(errors),
       groupHosts = List.unmodifiable(groupHosts),
       instances = List.unmodifiable(instances);
  final List<BotRecord> bots;
  final List<BotGroup> groups;
  final List<String> errors, groupHosts;
  final List<BotInstance> instances;
  final bool loading, busy;
  final bool botsAvailable, groupsAvailable;
}

@immutable
class BotInstance {
  const BotInstance(this.identity, this.label);
  final String identity, label;
}

@immutable
class BotMetadataConflict implements Exception {
  const BotMetadataConflict();
  @override
  String toString() =>
      'This bot changed in another client. Reload and review your changes before saving.';
}
