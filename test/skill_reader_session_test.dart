import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/presentation/skill_document.dart';
import 'package:wing/core/models/skill_reader.dart';
import 'package:wing/core/services/skill_reader_session.dart';

Map<String, dynamic> directory(String root, String name, bool folder) => {
  'entries': [
    {'name': name, 'path': '$root/$name', 'isDirectory': folder},
  ],
};
void main() {
  const document = SkillReaderTarget(
    name: 'review',
    sourcePath: '/skills/review/SKILL.md',
  );
  test(
    'exact counters and analytics remain distinct, unknown is not zero, API reads are shared',
    () async {
      final calls = <String, int>{};
      final repository = SkillReaderRepository((endpoint, query) async {
        final key = '$endpoint:${query['profile']}:${query['path']}';
        calls.update(key, (n) => n + 1, ifAbsent: () => 1);
        return switch (endpoint) {
          'profiles' => {
            'profiles': [
              {'name': 'one', 'path': '/one'},
              {'name': 'two', 'path': '/two'},
            ],
          },
          'skills' => {
            'data': [
              {'name': 'review', 'category': 'productivity'},
            ],
          },
          'fs/list' => switch (query['path']) {
            '/one' => directory('/one', 'skills', true),
            '/one/skills' => directory('/one/skills', '.usage.json', false),
            _ => {'entries': []},
          },
          'fs/read-text' => {
            'binary': false,
            'truncated': false,
            'text': jsonEncode({
              'review': {
                'use_count': 7,
                'patch_count': 3,
                'last_patched_at': '2026-10-08T19:04:53Z',
              },
              'review-extra': {'use_count': 999, 'patch_count': 999},
            }),
          },
          'analytics/usage' => {
            'skills': {
              'top_skills': query['profile'] == 'one'
                  ? [
                      {
                        'skill': 'review',
                        'view_count': 11,
                        'manage_count': 20,
                        'total_count': 31,
                      },
                    ]
                  : [],
            },
          },
          _ => throw StateError(endpoint),
        };
      });
      final first = await repository.load(document, 'one');
      expect(first.category, 'productivity');
      expect(first.uses, 7);
      expect(first.patches, 3);
      expect(first.readRequests, 11);
      expect(first.lastPatched, DateTime.utc(2026, 10, 8, 19, 4, 53));
      expect(first.activity.length, 1);
      expect(first.discoveredProfiles, 2);
      await repository.load(
        const SkillReaderTarget(name: 'review-extra'),
        'one',
      );
      expect(calls['fs/read-text:one:/one/skills/.usage.json'], 1);
      expect(calls['analytics/usage:one:null'], 1);
      expect(calls['profiles:null:null'], 1);
    },
  );
  test('truncated telemetry and missing analytics are unknown', () async {
    final repository = SkillReaderRepository(
      (endpoint, query) async => switch (endpoint) {
        'profiles' => {
          'profiles': [
            {'name': 'one', 'path': '/one'},
          ],
        },
        'skills' => {'data': []},
        'fs/list' =>
          query['path'] == '/one'
              ? directory('/one', 'skills', true)
              : query['path'] == '/one/skills'
              ? directory('/one/skills', '.usage.json', false)
              : {'entries': []},
        'fs/read-text' => {
          'binary': false,
          'truncated': true,
          'text': '{"review":{"use_count":100,"patch_count":5}}',
        },
        'analytics/usage' => {
          'skills': {'top_skills': []},
        },
        _ => {},
      },
    );
    final result = await repository.load(document, 'one');
    expect(result.uses, isNull);
    expect(result.patches, isNull);
    expect(result.readRequests, isNull);
  });
  test(
    'closing a viewer fences late publication and releases its lease once',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      var leases = 0, notifications = 0;
      final repository = SkillReaderRepository(
        (endpoint, query) async => endpoint == 'profiles'
            ? pending.future
            : {'data': [], 'entries': []},
      );
      final session = SkillReaderSession(
        repository: repository,
        document: document,
        profile: 'one',
        retain: () => leases++,
        release: () => leases--,
      );
      session.addListener(() => notifications++);
      final loading = session.load();
      session.dispose();
      pending.complete({'profiles': []});
      await loading;
      expect(leases, 0);
      expect(notifications, 0);
      expect(session.observation, isNull);
    },
  );
  test(
    'reference listing identity is validated; text receipt retains truncation',
    () async {
      final repository = SkillReaderRepository(
        (endpoint, query) async => switch (endpoint) {
          'profiles' => {'profiles': []},
          'skills' => {'data': []},
          'fs/list' =>
            query['path'] == '/skills/review'
                ? directory('/skills/review', 'references', true)
                : {
                    'entries': [
                      {
                        'name': 'notes.md',
                        'path': '/skills/review/references/notes.md',
                        'isDirectory': false,
                      },
                      {
                        'name': 'spoof.md',
                        'path': '/outside/spoof.md',
                        'isDirectory': false,
                      },
                    ],
                  },
          'fs/read-text' => {
            'path': query['path'],
            'text': '# Notes',
            'binary': false,
            'truncated': true,
          },
          _ => {},
        },
      );
      final result = await repository.load(document, 'one');
      expect(result.references.single.name, 'notes.md');
      final content = await repository.reference(
        result.references.single,
        'one',
      );
      expect(content.markdown, true);
      expect(content.truncated, true);
      expect(content.content, '# Notes');
    },
  );
  test('stock plugin envelope is metadata, not rendered prose or a heading', () {
    const name = 'mattpocock-skills:writing-for-agents';
    const body = '# Writing for agents\n\n## Purpose\nRead **carefully**.\n';
    const declaration =
        '---\nname: writing-for-agents\ndescription: Writing documents for agents.\nversion: 1.0\nauthor: A\nmetadata:\n  hermes:\n    tags: [writing, agents]\n---\n';
    for (final banner in [
      "[Bundle context: This skill is part of the 'mattpocock-skills' plugin.]\n\n",
      "[Bundle context: This skill is part of the 'mattpocock-skills' plugin.\nSibling skills: code-review, diagnosing-bugs.\nUse qualified form to invoke siblings (e.g. mattpocock-skills:code-review).]\n\n",
    ]) {
      final received = '$banner$declaration$body';
      final skill = SkillDocument.fromReceived(name: name, content: received);
      expect(skill.formattedContent, body);
      expect(
        skill.formattedText,
        'Writing for agents\n\nPurpose\n\nRead carefully.',
      );
      expect(skill.description, 'Writing documents for agents.');
      expect(skill.tags, ['writing', 'agents']);
      expect(skill.metadata, [
        (label: 'Version', value: '1.0'),
        (label: 'Author', value: 'A'),
      ]);
      expect(skill.name, name);
      expect(skill.rawContent, received);
    }
  });
  test('ordinary introductions and mismatched plugin banners remain exact', () {
    for (final content in [
      '[Bundle context: explain this phrase to the reader.]\n\n# Instructions',
      "[Bundle context: This skill is part of the 'another-plugin' plugin.]\n\n# Instructions",
      'Introduction.\n\nA real heading\n---\n\nKeep it.',
    ]) {
      final skill = SkillDocument.fromReceived(
        name: 'mattpocock-skills:writing-for-agents',
        content: content,
      );
      expect(skill.formattedContent, content);
      expect(skill.rawContent, content);
    }
  });
  test('formatted copy contains document text, raw copy retains declaration', () {
    final skill = SkillDocument.fromReceived(
      name: 'review',
      content:
          '---\nversion: 1.0\nauthor: A\nlicense: MIT\n---\n# Review\n\nRead **original** [evidence](https://example.com). A & B < C.\n\n- First\n- Second\n',
    );
    expect(skill.metadata, [
      (label: 'Version', value: '1.0'),
      (label: 'Author', value: 'A'),
    ]);
    expect(skill.formattedText, contains('Read original evidence.'));
    expect(skill.formattedText, isNot(contains('**')));
    expect(skill.formattedText, contains('A & B < C.'));
    expect(skill.rawContent, contains('license: MIT'));
  });
}
