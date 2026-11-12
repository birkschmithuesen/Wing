import 'chat_list_status.dart';
import 'hermes_profile.dart';
import 'profile_session_key.dart';

enum ChatGrouping {
  project('Project'),
  updated('Updated'),
  status('Status'),
  profile('Profile');

  const ChatGrouping(this.label);
  final String label;
}

enum ChatOrdering {
  updated('Updated'),
  created('Created'),
  status('Status'),
  tokens('Tokens'),
  cost('Cost');

  const ChatOrdering(this.label);
  final String label;
}

enum ChatDetail {
  updated('Updated'),
  tokens('Tokens'),
  cost('Cost'),
  profile('Profile');

  const ChatDetail(this.label);
  final String label;
}

num _chatUpdated(Map<String, dynamic> row) =>
    (row['last_active'] ?? row['started_at']) is num
    ? (row['last_active'] ?? row['started_at']) as num
    : 0;
num _chatTokens(Map<String, dynamic> row) =>
    ((row['input_tokens'] as num?) ?? 0) +
    ((row['output_tokens'] as num?) ?? 0);
num _chatCost(Map<String, dynamic> row) =>
    (row['actual_cost_usd'] as num?) ??
    (row['estimated_cost_usd'] as num?) ??
    0;
String compactTokens(num value) => value >= 1000000
    ? '${(value / 1000000).toStringAsFixed(1)}M'
    : value >= 1000
    ? '${(value / 1000).toStringAsFixed(1)}k'
    : '$value';

/// Dates are already interpreted in the phone's timezone. Compare their
/// calendar components, so a 23- or 25-hour DST day still counts as one day.
String chatDateBucket(DateTime date, {required DateTime now}) {
  final days = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime.utc(date.year, date.month, date.day)).inDays;
  return days <= 0
      ? 'Today'
      : days == 1
      ? 'Yesterday'
      : days < 7
      ? 'Previous 7 days'
      : 'Older';
}

/// A folder discovered on the captured Hermes host.
class ProjectFolderSuggestion {
  final String path;
  final String label;

  const ProjectFolderSuggestion({required this.path, required this.label});
}

/// User-entered project details, submitted together to the captured profile.
typedef ProjectDraft = ({
  String name,
  String path,
  String color,
  String icon,
  bool replaceFolder,
});

/// Detached project facts. Wire maps never cross into browser views.
final class BrowserProject {
  const BrowserProject({
    required this.id,
    required this.name,
    this.directory = '',
    this.color = '',
    this.icon = '',
    this.isHome = false,
  });
  factory BrowserProject.fromWire(Map<String, dynamic> wire) {
    final primary = wire['primary_path'] ?? wire['path'];
    var directory = primary is String ? primary.trim() : '';
    if (directory.isEmpty) {
      for (final repo in wire['repos'] as List? ?? const []) {
        if (repo is Map &&
            repo['path'] is String &&
            (repo['path'] as String).trim().isNotEmpty) {
          directory = (repo['path'] as String).trim();
          break;
        }
      }
    }
    return BrowserProject(
      id: wire['id'] as String,
      name: wire['name']?.toString() ?? '',
      directory: directory,
      color: wire['color']?.toString() ?? '',
      icon: wire['icon']?.toString() ?? '',
      isHome: wire['isNoProject'] == true,
    );
  }
  final String id, name, directory, color, icon;
  final bool isHome;
  @override
  bool operator ==(Object other) =>
      other is BrowserProject &&
      id == other.id &&
      name == other.name &&
      directory == other.directory &&
      color == other.color &&
      icon == other.icon &&
      isHome == other.isHome;
  @override
  int get hashCode => Object.hash(id, name, directory, color, icon, isHome);
}

final class ChatListEntry {
  const ChatListEntry({
    required this.scope,
    required this.id,
    required this.status,
    this.title = '',
    this.preview = '',
    this.snippet,
    this.source,
    this.cwd,
    this.pinned = false,
    this.archived = false,
    this.unread = false,
    this.hidden = false,
    this.isBotChat = false,
    this.startedAt = 0,
    this.updatedAt = 0,
    this.tokens = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cost = 0,
    this.messageCount,
    this.project,
    this.runtimeLabel,
  });
  factory ChatListEntry.fromWire({
    required WorkspaceScope scope,
    required Map<String, dynamic> row,
    required ChatListStatus status,
    BrowserProject? project,
    String? runtimeLabel,
    bool isBotChat = false,
  }) => ChatListEntry(
    scope: scope,
    id: row['id'] as String,
    status: status,
    title: row['title']?.toString() ?? '',
    preview: row['preview']?.toString() ?? '',
    snippet: row['snippet']?.toString(),
    source: row['source'] as String?,
    cwd: row['cwd'] as String?,
    pinned: row['pinned'] == true,
    archived: row['archived'] == true,
    unread: row['unread'] == true,
    hidden: row['hidden'] == true || row['hidden'] == 1,
    isBotChat: isBotChat,
    startedAt: (row['started_at'] as num?) ?? 0,
    updatedAt: _chatUpdated(row),
    tokens: _chatTokens(row),
    inputTokens: (row['input_tokens'] as num?) ?? 0,
    outputTokens: (row['output_tokens'] as num?) ?? 0,
    cost: _chatCost(row),
    messageCount: row['message_count'] as int?,
    project: project,
    runtimeLabel: runtimeLabel,
  );
  final WorkspaceScope scope;
  final String id, title, preview;
  final String? snippet, source, cwd, runtimeLabel;
  final bool pinned, archived, unread, hidden, isBotChat;
  final num startedAt, updatedAt, tokens, inputTokens, outputTokens, cost;
  final int? messageCount;
  final ChatListStatus status;
  final BrowserProject? project;
  String get profile => scope.profileName;
  String get key => '${scope.storageNamespace}/$id';
  String get projectKey => '$profile/${project?.id ?? 'home'}';
  ProfileSessionKey get sessionKey => ProfileSessionKey(scope, id);
  ChatListEntry withRuntime(ChatListStatus status, String? runtimeLabel) =>
      ChatListEntry(
        scope: scope,
        id: id,
        status: status,
        title: title,
        preview: preview,
        snippet: snippet,
        source: source,
        cwd: cwd,
        pinned: pinned,
        archived: archived,
        unread: unread,
        hidden: hidden,
        isBotChat: isBotChat,
        startedAt: startedAt,
        updatedAt: updatedAt,
        tokens: tokens,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cost: cost,
        messageCount: messageCount,
        project: project,
        runtimeLabel: runtimeLabel,
      );
  @override
  bool operator ==(Object other) =>
      other is ChatListEntry &&
      scope == other.scope &&
      id == other.id &&
      title == other.title &&
      preview == other.preview &&
      snippet == other.snippet &&
      source == other.source &&
      cwd == other.cwd &&
      pinned == other.pinned &&
      archived == other.archived &&
      unread == other.unread &&
      hidden == other.hidden &&
      isBotChat == other.isBotChat &&
      startedAt == other.startedAt &&
      updatedAt == other.updatedAt &&
      tokens == other.tokens &&
      inputTokens == other.inputTokens &&
      outputTokens == other.outputTokens &&
      cost == other.cost &&
      messageCount == other.messageCount &&
      status == other.status &&
      project == other.project &&
      runtimeLabel == other.runtimeLabel;
  @override
  int get hashCode => Object.hashAll([
    scope,
    id,
    title,
    preview,
    snippet,
    source,
    cwd,
    pinned,
    archived,
    unread,
    hidden,
    isBotChat,
    startedAt,
    updatedAt,
    tokens,
    inputTokens,
    outputTokens,
    cost,
    messageCount,
    status,
    project,
    runtimeLabel,
  ]);
}

final class ChatListGroup {
  ChatListGroup(
    this.key,
    this.label,
    Iterable<ChatListEntry> entries, {
    this.project,
    this.scope,
  }) : entries = List.unmodifiable(entries);
  final String key, label;
  final List<ChatListEntry> entries;
  final BrowserProject? project;
  final WorkspaceScope? scope;
  num get tokens => entries.fold<num>(0, (n, e) => n + e.tokens);
}

/// Keeps presentation positions stable while the entries themselves stay live.
/// Reset only at an explicit ordering boundary, not on controller notifications.
class ChatListArrangement {
  final _entryOrder = <ProfileSessionKey>{};
  final _buckets = <ProfileSessionKey, String>{};
  final _headings = <String, ChatListGroup>{};
  ChatGrouping? _grouping;
  ChatOrdering? _ordering;
  bool _initialized = false;

  void reset() {
    _entryOrder.clear();
    _buckets.clear();
    _headings.clear();
    _initialized = false;
  }

  List<ChatListGroup> apply(
    List<ChatListEntry> entries,
    ChatGrouping grouping,
    ChatOrdering ordering, {
    List<ChatListGroup> emptyGroups = const [],
    DateTime? now,
  }) {
    if (_grouping != grouping || _ordering != ordering) reset();
    _grouping = grouping;
    _ordering = ordering;
    final today = now ?? DateTime.now();
    if (!_initialized) {
      for (final group in groupChats(entries, grouping, ordering, now: today)) {
        _headings[group.key] = group;
        for (final entry in group.entries) {
          _entryOrder.add(entry.sessionKey);
          if (group.key != 'pinned') _buckets[entry.sessionKey] = group.key;
        }
      }
      _initialized = true;
    }

    final live = {for (final entry in entries) entry.sessionKey: entry};
    final placement = <ProfileSessionKey, String>{};
    for (final entry in entries) {
      final key = entry.sessionKey;
      _entryOrder.add(key);
      if (entry.pinned) {
        _headings['pinned'] = ChatListGroup('pinned', 'Pinned chats', []);
        placement[key] = 'pinned';
      } else if ((grouping == ChatGrouping.status ||
              grouping == ChatGrouping.updated) &&
          _buckets.containsKey(key)) {
        placement[key] = _buckets[key]!;
      } else {
        final group = _chatGroup(entry, grouping, today);
        _headings[group.key] = group;
        placement[key] = _buckets[key] = group.key;
      }
    }
    final result = <String, ChatListGroup>{};
    final members = <String, List<ChatListEntry>>{};
    ChatListGroup groupFor(String key) => result.putIfAbsent(key, () {
      final heading = _headings[key]!;
      return ChatListGroup(
        key,
        heading.label,
        [],
        project: heading.project,
        scope: heading.scope,
      );
    });
    for (final group in emptyGroups) {
      _headings[group.key] = group;
      groupFor(group.key);
    }
    // Reconcile membership by walking the established order. Live updates
    // never sort, even when status/date filters alter the visible subset.
    for (final key in _entryOrder) {
      final entry = live[key];
      if (entry != null) {
        final group = groupFor(placement[key]!);
        (members[group.key] ??= []).add(entry);
      }
    }
    return [
      if (result['pinned'] case final group?)
        ChatListGroup(
          group.key,
          group.label,
          members[group.key] ?? [],
          project: group.project,
          scope: group.scope,
        ),
      for (final key in _headings.keys)
        if (key != 'pinned' && result.containsKey(key))
          ChatListGroup(
            key,
            result[key]!.label,
            members[key] ?? [],
            project: result[key]!.project,
            scope: result[key]!.scope,
          ),
    ];
  }
}

ChatListGroup _chatGroup(
  ChatListEntry entry,
  ChatGrouping grouping,
  DateTime today,
) {
  String dateBucket() {
    final date = DateTime.fromMillisecondsSinceEpoch(
      (entry.updatedAt * 1000).round(),
    );
    return chatDateBucket(date, now: today);
  }

  final (key, label) = switch (grouping) {
    ChatGrouping.project => (
      entry.projectKey,
      entry.project?.name ?? '< ${entry.profile} >',
    ),
    ChatGrouping.profile => (entry.profile, entry.profile),
    ChatGrouping.status => (entry.status.name, entry.status.label),
    ChatGrouping.updated => (dateBucket(), dateBucket()),
  };
  return ChatListGroup(
    key,
    label,
    [],
    project: grouping == ChatGrouping.project ? entry.project : null,
    scope: entry.scope,
  );
}

List<ChatListGroup> groupChats(
  List<ChatListEntry> entries,
  ChatGrouping grouping,
  ChatOrdering ordering, {
  DateTime? now,
}) {
  final today = now ?? DateTime.now();

  int compare(ChatListEntry a, ChatListEntry b) {
    final result = switch (ordering) {
      ChatOrdering.updated => b.updatedAt.compareTo(a.updatedAt),
      ChatOrdering.created => b.startedAt.compareTo(a.startedAt),
      ChatOrdering.status => a.status.index.compareTo(b.status.index),
      ChatOrdering.tokens => b.tokens.compareTo(a.tokens),
      ChatOrdering.cost => b.cost.compareTo(a.cost),
    };
    if (result != 0) return result;
    final recent = b.updatedAt.compareTo(a.updatedAt);
    return recent != 0 ? recent : a.key.compareTo(b.key);
  }

  final sorted = [...entries]..sort(compare);
  final groups = <String, ChatListGroup>{};
  final members = <String, List<ChatListEntry>>{};
  final pinned = sorted.where((e) => e.pinned).toList();
  for (final e in sorted.where((e) => !e.pinned)) {
    final group = _chatGroup(e, grouping, today);
    groups.putIfAbsent(group.key, () => group);
    (members[group.key] ??= []).add(e);
  }

  final result = [
    for (final group in groups.values)
      ChatListGroup(
        group.key,
        group.label,
        members[group.key]!,
        project: group.project,
        scope: group.scope,
      ),
  ];
  if (grouping == ChatGrouping.status) {
    result.sort(
      (a, b) => ChatListStatus.values
          .byName(a.key)
          .index
          .compareTo(ChatListStatus.values.byName(b.key).index),
    );
  } else if (grouping == ChatGrouping.updated) {
    const buckets = ['Today', 'Yesterday', 'Previous 7 days', 'Older'];
    result.sort(
      (a, b) => buckets.indexOf(a.key).compareTo(buckets.indexOf(b.key)),
    );
  } else if (grouping == ChatGrouping.profile) {
    result.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
  }
  return [
    if (pinned.isNotEmpty) ChatListGroup('pinned', 'Pinned chats', pinned),
    ...result,
  ];
}

final class BrowserProfileRead {
  BrowserProfileRead({
    required this.error,
    required this.complete,
    required Iterable<String> searchMatches,
  }) : searchMatches = Set.unmodifiable(searchMatches);
  final String? error;
  final bool complete;
  final Set<String> searchMatches;
}

final class BrowserReadState {
  BrowserReadState({
    required this.available,
    required this.archived,
    required this.loading,
    required this.searching,
    required this.searchLimited,
    required this.searchError,
    required Map<String, BrowserProfileRead> profiles,
  }) : profiles = Map.unmodifiable(profiles);
  final bool archived, loading, searching, searchLimited;
  final bool available;
  final String? searchError;
  final Map<String, BrowserProfileRead> profiles;
}
