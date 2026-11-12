import 'dart:convert';

import 'chat_list_status.dart';
import 'chat_list_view.dart';
import 'hermes_profile.dart';

enum BrowserFilter { status, profile, project }

enum BrowserPreferenceOperation {
  grouping,
  ordering,
  detail,
  toggleFilter,
  clearFilter,
  exclusiveProfile,
  clearFilters,
  reset,
}

enum BrowserPreferencesValidity { valid, invalid, unverified }

enum BrowserPreferencesSaveOutcome {
  saved,
  unchanged,
  failedRestored,
  failedUnverified,
  blocked,
  retired,
}

/// Immutable current view intent. Missing storage alone declares these defaults.
class ChatBrowserPreferences {
  ChatBrowserPreferences({
    required this.grouping,
    required this.ordering,
    required Iterable<ChatDetail> show,
    required Iterable<ChatListStatus> statuses,
    required Iterable<String> profiles,
    required Iterable<String> projects,
  }) : show = Set.unmodifiable(show),
       statuses = Set.unmodifiable(statuses),
       profiles = Set.unmodifiable(profiles),
       projects = Set.unmodifiable(projects) {
    if (this.profiles.any((name) => !HermesProfile.isCanonicalName(name)) ||
        this.projects.any((key) => !validProjectKey(key))) {
      throw const FormatException('Invalid browser filter identity');
    }
  }

  factory ChatBrowserPreferences.fresh() => ChatBrowserPreferences(
    grouping: ChatGrouping.project,
    ordering: ChatOrdering.updated,
    show: const [ChatDetail.updated],
    statuses: const [],
    profiles: const [],
    projects: const [],
  );

  final ChatGrouping grouping;
  final ChatOrdering ordering;
  final Set<ChatDetail> show;
  final Set<ChatListStatus> statuses;
  final Set<String> profiles;
  final Set<String> projects;

  static bool validProjectKey(String key) {
    final slash = key.indexOf('/');
    return slash > 0 &&
        slash < key.length - 1 &&
        HermesProfile.isCanonicalName(key.substring(0, slash));
  }

  Set<String> filter(BrowserFilter filter) => switch (filter) {
    BrowserFilter.status => Set.unmodifiable(
      statuses.map((status) => status.name),
    ),
    BrowserFilter.profile => profiles,
    BrowserFilter.project => projects,
  };

  ChatBrowserPreferences apply(BrowserPreferenceIntent intent) {
    if (intent.operation == BrowserPreferenceOperation.reset) {
      return ChatBrowserPreferences.fresh();
    }
    var grouping = this.grouping;
    var ordering = this.ordering;
    final show = Set<ChatDetail>.of(this.show);
    final statuses = Set<ChatListStatus>.of(this.statuses);
    final profiles = Set<String>.of(this.profiles);
    final projects = Set<String>.of(this.projects);
    void toggle<T>(Set<T> values, T value) {
      if (!values.remove(value)) {
        values.add(value);
      }
    }

    switch (intent.operation) {
      case BrowserPreferenceOperation.grouping:
        grouping = intent.value as ChatGrouping;
      case BrowserPreferenceOperation.ordering:
        ordering = intent.value as ChatOrdering;
      case BrowserPreferenceOperation.detail:
        toggle(show, intent.value as ChatDetail);
      case BrowserPreferenceOperation.toggleFilter:
        final id = intent.value as String;
        switch (intent.filter!) {
          case BrowserFilter.status:
            toggle(statuses, ChatListStatus.values.byName(id));
          case BrowserFilter.profile:
            toggle(profiles, id);
          case BrowserFilter.project:
            toggle(projects, id);
        }
      case BrowserPreferenceOperation.clearFilter:
        switch (intent.filter!) {
          case BrowserFilter.status:
            statuses.clear();
          case BrowserFilter.profile:
            profiles.clear();
          case BrowserFilter.project:
            projects.clear();
        }
      case BrowserPreferenceOperation.exclusiveProfile:
        final id = intent.value as String;
        final selected = profiles.contains(id);
        profiles.clear();
        if (!selected) {
          profiles.add(id);
        }
      case BrowserPreferenceOperation.clearFilters:
        statuses.clear();
        profiles.clear();
        projects.clear();
      case BrowserPreferenceOperation.reset:
        break;
    }
    return ChatBrowserPreferences(
      grouping: grouping,
      ordering: ordering,
      show: show,
      statuses: statuses,
      profiles: profiles,
      projects: projects,
    );
  }

  Map<String, Object> toJson() => {
    'grouping': grouping.name,
    'ordering': ordering.name,
    'show': show.map((detail) => detail.name).toList(),
    'status': statuses.map((status) => status.name).toList(),
    'profile': profiles.toList(),
    'project': projects.toList(),
  };

  @override
  bool operator ==(Object other) =>
      other is ChatBrowserPreferences &&
      grouping == other.grouping &&
      ordering == other.ordering &&
      _sameSet(show, other.show) &&
      _sameSet(statuses, other.statuses) &&
      _sameSet(profiles, other.profiles) &&
      _sameSet(projects, other.projects);
  @override
  int get hashCode => Object.hash(
    grouping,
    ordering,
    Object.hashAllUnordered(show),
    Object.hashAllUnordered(statuses),
    Object.hashAllUnordered(profiles),
    Object.hashAllUnordered(projects),
  );
  static bool _sameSet<T>(Set<T> a, Set<T> b) =>
      a.length == b.length && a.every(b.contains);
}

/// One typed command family; a UI never captures a replacement JSON snapshot.
class BrowserPreferenceIntent {
  const BrowserPreferenceIntent.grouping(ChatGrouping value)
    : this._(BrowserPreferenceOperation.grouping, value, null);
  const BrowserPreferenceIntent.ordering(ChatOrdering value)
    : this._(BrowserPreferenceOperation.ordering, value, null);
  const BrowserPreferenceIntent.detail(ChatDetail value)
    : this._(BrowserPreferenceOperation.detail, value, null);
  BrowserPreferenceIntent.toggle(BrowserFilter filter, String value)
    : operation = BrowserPreferenceOperation.toggleFilter,
      value = value,
      filter = filter {
    switch (filter) {
      case BrowserFilter.status:
        ChatListStatus.values.byName(value);
      case BrowserFilter.profile:
        if (!HermesProfile.isCanonicalName(value)) {
          throw const FormatException('Invalid profile filter');
        }
      case BrowserFilter.project:
        if (!ChatBrowserPreferences.validProjectKey(value)) {
          throw const FormatException('Invalid project filter');
        }
    }
  }
  const BrowserPreferenceIntent.clear(BrowserFilter filter)
    : this._(BrowserPreferenceOperation.clearFilter, null, filter);
  BrowserPreferenceIntent.exclusiveProfile(String value)
    : operation = BrowserPreferenceOperation.exclusiveProfile,
      value = value,
      filter = null {
    if (!HermesProfile.isCanonicalName(value)) {
      throw const FormatException('Invalid profile filter');
    }
  }
  const BrowserPreferenceIntent.clearFilters()
    : this._(BrowserPreferenceOperation.clearFilters, null, null);
  const BrowserPreferenceIntent.reset()
    : this._(BrowserPreferenceOperation.reset, null, null);
  const BrowserPreferenceIntent._(this.operation, this.value, this.filter);
  final BrowserPreferenceOperation operation;
  final Object? value;
  final BrowserFilter? filter;
}

/// Sole decoder for the current six-field JSON schema, never a legacy reader.
class ChatBrowserPreferencesCodec {
  static String storageKey(String identity) {
    if (identity.isEmpty) {
      throw ArgumentError('Connection identity is required');
    }
    return 'chat_list_target_$identity';
  }

  static ChatBrowserPreferences decode(Object? raw) {
    if (raw is! String) throw const FormatException('Browser view is not JSON');
    final value = jsonDecode(raw);
    const keys = {
      'grouping',
      'ordering',
      'show',
      'status',
      'profile',
      'project',
    };
    if (value is! Map ||
        value.length != keys.length ||
        value.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Invalid browser view schema');
    }
    List<String> strings(String key) {
      final list = value[key];
      if (list is! List ||
          list.any((item) => item is! String) ||
          list.toSet().length != list.length) {
        throw const FormatException('Invalid browser view choices');
      }
      return list.cast<String>();
    }

    try {
      return ChatBrowserPreferences(
        grouping: ChatGrouping.values.byName(value['grouping'] as String),
        ordering: ChatOrdering.values.byName(value['ordering'] as String),
        show: strings('show').map(ChatDetail.values.byName),
        statuses: strings('status').map(ChatListStatus.values.byName),
        profiles: strings('profile'),
        projects: strings('project'),
      );
    } catch (_) {
      throw const FormatException('Invalid browser view choices');
    }
  }
}

class BrowserPreferencesFact {
  const BrowserPreferencesFact({
    required this.validity,
    required this.confirmed,
    required this.display,
    required this.busy,
    required this.error,
  });
  final BrowserPreferencesValidity validity;
  final ChatBrowserPreferences? confirmed;
  final ChatBrowserPreferences? display;
  final bool busy;
  final String? error;
  bool get canChoose => validity == BrowserPreferencesValidity.valid;

  @override
  bool operator ==(Object other) =>
      other is BrowserPreferencesFact &&
      validity == other.validity &&
      confirmed == other.confirmed &&
      display == other.display &&
      busy == other.busy &&
      error == other.error;
  @override
  int get hashCode => Object.hash(validity, confirmed, display, busy, error);
}
