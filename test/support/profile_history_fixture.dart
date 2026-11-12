import 'profile_paging_fixture.dart';

class ProfileHistoryFixture extends ProfilePagingFixture {
  int messageCount = 620;
  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    ...super.sessions(profile),
    {
      'id': 'beyond-list',
      'title': '$profile archive match',
      'profile': profile,
      'archived': true,
      'hidden': false,
      'last_active': now - 86400,
    },
  ];
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    for (var i = 1; i <= messageCount; i++)
      {
        'id': i,
        'role': i.isEven ? 'assistant' : 'user',
        'content': '$profile message $i',
        'display_content': '$profile message $i',
      },
  ];
  @override
  List<Map<String, dynamic>> searchRows(String profile, String query) => [
    {
      'session_id': 'beyond-list',
      'title': '$profile archive match',
      'snippet': '$query in an old message',
      'archived': true,
    },
  ];
}
