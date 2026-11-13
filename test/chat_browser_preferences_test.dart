import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_browser_preferences.dart';
import 'package:wing/core/models/chat_list_status.dart';
import 'package:wing/core/models/chat_list_view.dart';

void main() {
  test('current six-field schema round trips retained filter identities', () {
    final source = ChatBrowserPreferences(
      grouping: ChatGrouping.status,
      ordering: ChatOrdering.tokens,
      show: [ChatDetail.profile, ChatDetail.cost],
      statuses: [ChatListStatus.working],
      profiles: ['removed-profile'],
      projects: ['removed-profile/retained-project'],
    );
    final restored = ChatBrowserPreferencesCodec.decode(
      jsonEncode(source.toJson()),
    );
    expect(restored, source);
    expect(restored.hashCode, source.hashCode);
    expect(source.toJson().keys.toSet(), {
      'grouping',
      'ordering',
      'show',
      'status',
      'profile',
      'project',
    });
    expect(
      ChatBrowserPreferencesCodec.storageKey('connection'),
      'chat_list_target_connection',
    );
    expect(() => restored.profiles.add('new'), throwsUnsupportedError);
    expect(() => restored.show.clear(), throwsUnsupportedError);
  });

  test('present malformed fields reject the whole observation', () {
    final valid = ChatBrowserPreferences.fresh().toJson();
    final malformed = <Map<String, Object>>[
      {...valid, 'grouping': 'unknown'},
      {...valid, 'ordering': 7},
      {
        ...valid,
        'show': ['updated', 'updated'],
      },
      {
        ...valid,
        'status': ['unknown'],
      },
      {
        ...valid,
        'profile': ['not a canonical name'],
      },
      {
        ...valid,
        'project': ['missing-profile-prefix'],
      },
      {...valid, 'legacy': true},
      {...valid}..remove('show'),
    ];
    for (final row in malformed) {
      expect(
        () => ChatBrowserPreferencesCodec.decode(jsonEncode(row)),
        throwsFormatException,
        reason: '$row',
      );
    }
    for (final raw in <Object?>[null, 7, 'null', '[]', '{']) {
      expect(
        () => ChatBrowserPreferencesCodec.decode(raw),
        throwsFormatException,
      );
    }
  });

  test('choices compose without mutating earlier observations', () {
    final fresh = ChatBrowserPreferences.fresh();
    final selected = fresh
        .apply(
          BrowserPreferenceIntent.toggle(BrowserFilter.profile, 'personal'),
        )
        .apply(BrowserPreferenceIntent.toggle(BrowserFilter.profile, 'work'))
        .apply(BrowserPreferenceIntent.toggle(BrowserFilter.status, 'working'))
        .apply(
          BrowserPreferenceIntent.toggle(BrowserFilter.project, 'work/home'),
        )
        .apply(const BrowserPreferenceIntent.detail(ChatDetail.cost));
    expect(fresh.statuses, isEmpty);
    expect(fresh.profiles, isEmpty);
    expect(fresh.projects, isEmpty);
    expect(selected.profiles, {'personal', 'work'});
    expect(selected.statuses, {ChatListStatus.working});
    expect(selected.projects, {'work/home'});
    expect(selected.show, {ChatDetail.updated, ChatDetail.cost});
    final exclusive = selected.apply(
      BrowserPreferenceIntent.exclusiveProfile('work'),
    );
    expect(exclusive.profiles, isEmpty);
    expect(exclusive.statuses, selected.statuses);
    final cleared = exclusive.apply(
      const BrowserPreferenceIntent.clearFilters(),
    );
    expect(cleared.statuses, isEmpty);
    expect(cleared.profiles, isEmpty);
    expect(cleared.projects, isEmpty);
    expect(selected.apply(const BrowserPreferenceIntent.reset()), fresh);
  });

  test('filter order does not change semantic equality', () {
    ChatBrowserPreferences value(Iterable<String> profiles) =>
        ChatBrowserPreferences(
          grouping: ChatGrouping.project,
          ordering: ChatOrdering.updated,
          show: const [ChatDetail.updated],
          statuses: const [],
          profiles: profiles,
          projects: const [],
        );
    expect(value(['personal', 'work']), value(['work', 'personal']));
    expect(
      value(['personal', 'work']).hashCode,
      value(['work', 'personal']).hashCode,
    );
  });
}
