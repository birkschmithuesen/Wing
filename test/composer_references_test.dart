import 'package:wing/core/models/server_reference.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/composer_reference.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/services/composer_reference_preparation.dart';
import 'package:wing/core/services/composer_reference_repository.dart';

class ReferenceHost {
  final files = <String, String>{
    '/work/note.md': 'original @file:/unread.md\nnext',
  };
  final reads = <String>[];
  List<String> profiles = ['hermes', 'butler'];
  String? readTarget;
  Completer<void>? hold;
  Completer<void>? readStarted;

  Future<Map<String, dynamic>> read(
    String endpoint,
    Map<String, String> query,
  ) async {
    reads.add('$endpoint:${query['path'] ?? ''}');
    if (endpoint == 'profiles') {
      return {
        'profiles': [
          for (final name in profiles)
            {'name': name, 'display_name': name.toUpperCase()},
        ],
      };
    }
    final path = query['path'] ?? '/work';
    final c = ServerReferencePath.pathContext;
    if (endpoint == 'files') {
      return {
        'path': path,
        'parent': c.dirname(path),
        'entries': [
          if (path == '/')
            {
              'name': 'work',
              'path': '/work',
              'is_directory': true,
              'size': null,
            },
          for (final file in files.entries)
            if (c.dirname(file.key) == path)
              {
                'name': c.basename(file.key),
                'path': file.key,
                'is_directory': false,
                'size': utf8.encode(file.value).length,
                'mime_type': 'text/markdown',
              },
        ],
      };
    }
    if (endpoint == 'files/read') {
      readStarted?.complete();
      await hold?.future;
      final content = files[path]!;
      return {
        'path': readTarget ?? path,
        'name': c.basename(path),
        'size': utf8.encode(content).length,
        'mime_type': 'text/markdown',
        'data_url':
            'data:text/markdown;base64,${base64.encode(utf8.encode(content))}',
      };
    }
    throw StateError(endpoint);
  }

  ComposerReferencePreparation preparation({String? shellOutput}) =>
      ComposerReferencePreparation(
        ComposerReferenceRepository(
          read: read,
          call: (method, params) async => {
            'code': 0,
            'stderr': '',
            'stdout':
                shellOutput ?? 'WING_BEGIN\n123 20\n/work/note.md\nWING_END\n',
          },
        ),
      );
}

void main() {
  test(
    'other stock/plugin directives pause only when mixed with actual references',
    () async {
      final host = ReferenceHost();
      Future<String> prepare(String text) => host.preparation().prepare(
        text,
        selected: const [],
        cwd: null,
        contextLimit: 32768,
        requireCurrent: () {},
      );
      await expectLater(
        prepare('Read @file:/work/note.md with @plugin:value'),
        throwsFormatException,
      );
      await expectLater(
        prepare('Read @file:/work/note.md with @url:https://example.org'),
        throwsFormatException,
      );
      expect(await prepare('@plugin:value'), '@plugin:value');
      final literal = await prepare(
        'Read @file:/work/note.md; example `@url:https://example.org`',
      );
      expect(
        PreparedComposerMessage.parse(literal)!.message,
        contains('`@url:'),
      );
    },
  );
  test('folder summaries keep each child beneath its actual parent', () async {
    final host = ReferenceHost()..files.clear();
    host.files['/work/alpha/one.md'] = 'one';
    host.files['/work/beta/two.md'] = 'two';
    final wire = await host
        .preparation(
          shellOutput:
              'WING_BEGIN\n123 40\n/work/alpha/one.md\n/work/beta/two.md\nWING_END\n',
        )
        .prepare(
          '@folder:/work',
          selected: const [],
          cwd: null,
          contextLimit: 32768,
          requireCurrent: () {},
        );
    final tree = PreparedComposerMessage.parse(wire)!.context;
    expect(
      tree,
      contains('- alpha/\n  - one.md (1 lines)\n- beta/\n  - two.md (1 lines)'),
    );
  });
  test(
    'saved native phone images remain extractable beside freshly prepared files',
    () async {
      final host = ReferenceHost();
      const text = 'Read @file:/work/note.md\n@image:/cache/phone.png';
      final wire = await host.preparation().prepare(
        text,
        selected: const [],
        cwd: null,
        contextLimit: 32768,
        requireCurrent: () {},
      );
      final prepared = PreparedComposerMessage.parse(wire)!;
      expect(prepared.displayMessage, text);
      expect(wire, endsWith('\n@image:/cache/phone.png'));
      expect(
        wire.split(PreparedComposerMessage.footer).first,
        isNot(contains('@image:')),
      );
      expect(prepared.context, contains('original'));
    },
  );
  test(
    'literal file examples never cause stock expansion or content reads',
    () async {
      final host = ReferenceHost();
      const authored = 'Example `@file:/work/note.md`';
      final wire = await host.preparation().prepare(
        authored,
        selected: const [],
        cwd: null,
        contextLimit: null,
        requireCurrent: () {},
      );
      expect(PreparedComposerMessage.parse(wire)!.message, authored);
      expect(wire, isNot(contains('@file:')));
      expect(host.reads.where((r) => r.startsWith('files')), isEmpty);
    },
  );

  test(
    'managed root folder admission does not require access to its parent',
    () async {
      final host = ReferenceHost();
      final repository = ComposerReferenceRepository(
        read: (endpoint, query) {
          if (query['path'] == '/') throw StateError('Outside managed root');
          return host.read(endpoint, query);
        },
        call: (method, params) async => {},
      );
      expect(
        (await repository.files.entry('/work', folder: true)).path,
        '/work',
      );
    },
  );

  test('failed host listing preserves independent agent discovery', () async {
    final host = ReferenceHost();
    final preparation = ComposerReferencePreparation(
      ComposerReferenceRepository(
        read: (endpoint, query) {
          if (endpoint == 'files') throw StateError('Host files unavailable');
          return host.read(endpoint, query);
        },
        call: (method, params) async => {},
      ),
    );
    final result = await preparation.complete(
      MentionQuery.at('@', 1)!,
      cwd: null,
      currentAgent: 'hermes',
      requireCurrent: () {},
    );
    expect(result.items, hasLength(2));
    expect(
      result.items.firstWhere((i) => i.reference.target == 'hermes').detail,
      contains('Current agent'),
    );
    expect(result.warning, isNotNull);
  });

  test(
    'absolute folder completion normalizes the trailing browse separator',
    () async {
      final host = ReferenceHost();
      final preparation = ComposerReferencePreparation(
        ComposerReferenceRepository(
          read: (endpoint, query) {
            if (endpoint == 'files') {
              ServerReferencePath.admit(query['path']!);
              expect(query['path'], '/work');
            }
            return host.read(endpoint, query);
          },
          call: (method, params) async => {},
        ),
      );
      const text = '@folder:/work/';
      final result = await preparation.complete(
        MentionQuery.at(text, text.length)!,
        cwd: null,
        requireCurrent: () {},
      );
      expect(result.directory, '/work');
      expect(host.reads, ['files:/work']);
    },
  );
  test(
    'readable names retain canonical identity through punctuation and dispatch',
    () async {
      final host = ReferenceHost();
      const ref = ComposerReference(
        kind: ComposerReferenceKind.agent,
        token: '@HERMES',
        target: 'hermes',
      );
      const text = 'Please ask (@HERMES), then report.';
      expect(retainComposerReferences(text, [ref]).single.target, 'hermes');
      final wire = await host.preparation().prepare(
        text,
        selected: [ref],
        cwd: null,
        contextLimit: null,
        requireCurrent: () {},
      );
      final prepared = PreparedComposerMessage.parse(wire)!;
      expect(prepared.message, text);
      expect(prepared.references.single.target, 'hermes');
      expect(prepared.context, contains('canonical profile hermes'));
      final query = MentionQuery.at('@her', 4)!;
      final completion = await host.preparation().complete(
        query,
        cwd: null,
        selected: const [
          ComposerReference(
            kind: ComposerReferenceKind.agent,
            token: '@HERMES',
            target: 'butler',
          ),
        ],
        requireCurrent: () {},
      );
      expect(completion.items.first.reference.token, '@`HERMES (hermes)`');
    },
  );

  test(
    'display names with spaces and quotes remain editable selected references',
    () {
      for (final name in ['Client Work', 'Dr. Foo', '大家', 'Foo ` " bar']) {
        final token = composerAgentToken(name);
        final ref = ComposerReference(
          kind: ComposerReferenceKind.agent,
          token: token,
          target: 'canonical_foo',
        );
        const next = ComposerReference(
          kind: ComposerReferenceKind.agent,
          token: '@Other',
          target: 'other',
        );
        final text = 'Ask ($token), then @Other please.';
        expect(
          retainComposerReferences(text, [ref, next]).map((ref) => ref.target),
          ['canonical_foo', 'other'],
        );
        expect(
          composerReferenceSpans(
            text,
            selected: [ref, next],
          ).first.reference.token,
          token,
        );
        expect(retainComposerReferences('Ask somebody else', [ref]), isEmpty);
      }
      expect(composerAgentToken('Foo'), '@Foo');
      expect(composerAgentToken('Client Work'), '@`Client Work`');
    },
  );

  test('punctuation delimits mention names like slash skills', () {
    const separators = [
      ' ',
      '\n',
      ',',
      '.',
      '!',
      '?',
      ';',
      ':',
      '(',
      ')',
      '[',
      ']',
      '{',
      '}',
      '<',
      '>',
      '"',
      "'",
      '“',
      '”',
      '‘',
      '’',
      '…',
      '—',
      '，',
      '。',
      '+',
      '=',
      r'$',
      '😀',
    ];
    for (final separator in separators) {
      final query = 'Use$separator@her';
      expect(MentionQuery.at(query, query.length)!.term, 'her', reason: query);
      const reference = ComposerReference(
        kind: ComposerReferenceKind.agent,
        token: '@hermes',
        target: 'hermes',
      );
      final text = '$query$separator continuing';
      final edit = MentionQuery.at(text, query.length)!.insert(reference);
      expect(edit.text.endsWith('$separator continuing'), isTrue);
      expect(edit.text.startsWith('Use$separator@hermes'), isTrue);
      final completed = 'Use$separator@hermes$separator';
      expect(
        MentionQuery.at(completed, completed.length),
        isNull,
        reason: completed,
      );
      final spans = composerReferenceSpans(completed, agentNames: ['hermes']);
      expect(spans.single.reference.token, '@hermes', reason: completed);
      expect(
        completed.substring(spans.single.start, spans.single.end),
        '@hermes',
      );
    }
    for (final name in ['hermes-more', 'hermes_more']) {
      expect(MentionQuery.at('@$name', name.length + 1)!.term, name);
      expect(composerReferenceSpans('@$name', agentNames: ['hermes']), isEmpty);
    }
    for (final literal in [
      'name@hermes',
      'é@hermes',
      'name_@hermes',
      'name-@hermes',
      '/@hermes',
      r'\@hermes',
      'https://example.org/@hermes',
      '@hermes/path',
      r'@hermes\path',
      '@hermes:plugin',
    ]) {
      expect(MentionQuery.at(literal, literal.length), isNull, reason: literal);
      expect(
        composerReferenceSpans(literal, agentNames: ['hermes']),
        isEmpty,
        reason: literal,
      );
    }
  });

  test('cursor-relative insertion preserves Unicode prefix and suffix', () {
    const text = '😃 discuss @her with care';
    final query = MentionQuery.at(text, text.indexOf(' with'))!;
    const ref = ComposerReference(
      kind: ComposerReferenceKind.agent,
      token: '@hermes',
      target: 'hermes',
    );
    final selected = query.insert(ref);
    expect(selected.text, '😃 discuss @hermes with care');
    expect(selected.cursor, '😃 discuss @hermes '.length);
    expect(MentionQuery.at('name@host.test', 14), isNull);
    expect(MentionQuery.at('```\n@he', 7), isNull);
    expect(MentionQuery.at('use `@he', 8), isNull);
    expect(MentionQuery.at('@he', 3, collapsed: false), isNull);
    expect(MentionQuery.at('(@he', 4)!.term, 'he');
    const partial = '@file:`/work/design note';
    expect(
      MentionQuery.at(partial, partial.length)!.term,
      'file:`/work/design note',
    );
    const inserted = '@file:`/work/design note.md` ';
    expect(MentionQuery.at(inserted, inserted.length), isNull);
  });

  test('quoted paths and line ranges retain their exact targets', () {
    final refs = composerReferenceSpans(
      'Read @file:`/work/design note.md`:2-3.',
    );
    expect(refs.single.reference.target, '/work/design note.md');
    expect(refs.single.firstLine, 2);
    expect(refs.single.lastLine, 3);
    expect(
      composerPathToken(ComposerReferenceKind.file, '/work/a:12'),
      '@file:`/work/a:12`',
    );
    expect(composerReferenceSpans('literal `@file:/work/a`'), isEmpty);
  });

  test(
    'prepared history preserves authored text and existing phone images',
    () {
      final prepared = PreparedComposerMessage(
        message: 'Read @file:/work/note.md',
        context: 'source @file:/unread.md ^[[200~ 😃\n',
      );
      final wire = prepared.wireText;
      expect(wire, isNot(contains('@file:')));
      expect(PreparedComposerMessage.parse(wire)!.context, prepared.context);
      final images = PreparedComposerMessage(
        message: 'Read a text file',
        context: '/private/photo.png https://example.org/secret.jpg',
      );
      expect(images.wireText, isNot(contains('.png')));
      expect(images.wireText, isNot(contains('.jpg')));
      expect(
        PreparedComposerMessage.parse(images.wireText)!.context,
        images.context,
      );
      final saved = {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '$wire\n@image:/cache/photo.png'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,AA=='},
          },
        ],
      };
      expect(
        answerMessageDisplayText(saved),
        '${prepared.message}\n@image:/cache/photo.png',
      );
      expect(
        answerMessageDisplayText({
          'role': 'user',
          'display_kind': 'steer',
          'display_content': wire,
        }),
        prepared.message,
      );
      expect(
        answerMessageDisplayText({'role': 'assistant', 'content': wire}),
        wire,
      );
    },
  );

  test(
    'dispatch reads current content once and preserves incidental directives',
    () async {
      final host = ReferenceHost();
      host.files['/work/note.md'] = 'changed @file:/unread.md';
      final wire = await host.preparation().prepare(
        'Read @file:/work/note.md',
        selected: const [],
        cwd: '/work',
        contextLimit: 10000,
        requireCurrent: () {},
      );
      final prepared = PreparedComposerMessage.parse(wire)!;
      expect(prepared.context, contains('changed @file:/unread.md'));
      expect(host.reads.where((r) => r.startsWith('files/read:')), [
        'files/read:/work/note.md',
      ]);
      expect(prepared.references.single.target, '/work/note.md');
    },
  );

  test('selected absolute targets survive workspace changes', () async {
    final host = ReferenceHost();
    const ref = ComposerReference(
      kind: ComposerReferenceKind.file,
      token: '@file:/work/note.md',
      target: '/work/note.md',
    );
    final wire = await host.preparation().prepare(
      ref.token,
      selected: [ref],
      cwd: '/another-workspace',
      contextLimit: 10000,
      requireCurrent: () {},
    );
    expect(
      PreparedComposerMessage.parse(wire)!.context,
      contains(host.files[ref.target]!),
    );
  });

  test('renamed or deleted selected agent fails before sending', () async {
    final host = ReferenceHost()..profiles = ['butler'];
    const ref = ComposerReference(
      kind: ComposerReferenceKind.agent,
      token: '@hermes',
      target: 'hermes',
    );
    await expectLater(
      host.preparation().prepare(
        'Ask @hermes',
        selected: [ref],
        cwd: null,
        contextLimit: null,
        requireCurrent: () {},
      ),
      throwsFormatException,
    );
    expect(host.reads, ['profiles:']);
  });

  for (final scenario in [
    (
      name: 'missing file',
      path: '/work/missing.md',
      limit: 10000,
      target: null,
    ),
    (name: 'budget overflow', path: '/work/note.md', limit: 10, target: null),
    (
      name: 'canonical retargeting',
      path: '/work/note.md',
      limit: 10000,
      target: '/work/other.md',
    ),
  ]) {
    test('${scenario.name} rejects whole preparation', () async {
      final host = ReferenceHost()..readTarget = scenario.target;
      await expectLater(
        host.preparation().prepare(
          '@file:${scenario.path}',
          selected: const [],
          cwd: '/work',
          contextLimit: scenario.limit,
          requireCurrent: () {},
        ),
        throwsFormatException,
      );
    });
  }

  test('credential alias is rejected before a byte read', () async {
    final host = ReferenceHost()..readTarget = '/work/.env';
    await expectLater(
      host.preparation().prepare(
        '@file:/work/.env',
        selected: const [],
        cwd: '/work',
        contextLimit: 10000,
        requireCurrent: () {},
      ),
      throwsFormatException,
    );
    expect(host.reads.any((r) => r.startsWith('files/read:')), isFalse);
  });

  test('retired preparation cannot publish held file bytes', () async {
    final host = ReferenceHost()
      ..hold = Completer<void>()
      ..readStarted = Completer<void>();
    var current = true;
    final operation = host.preparation().prepare(
      '@file:/work/note.md',
      selected: const [],
      cwd: '/work',
      contextLimit: 10000,
      requireCurrent: () {
        if (!current) throw StateError('retired');
      },
    );
    await host.readStarted!.future;
    current = false;
    host.hold!.complete();
    await expectLater(operation, throwsStateError);
  });

  test(
    'folder context includes ignore-aware paths and metadata without all contents',
    () async {
      final host = ReferenceHost();
      host.files['/work/ignored.md'] = 'ignore me';
      final wire = await host.preparation().prepare(
        '@folder:/work',
        selected: const [],
        cwd: '/work',
        contextLimit: 10000,
        requireCurrent: () {},
      );
      final context = PreparedComposerMessage.parse(wire)!.context;
      expect(context, contains('note.md (2 lines)'));
      expect(context, isNot(contains('ignored.md')));
      expect(context, isNot(contains('original @file:')));
    },
  );

  test('stock stdout tail cannot masquerade as a complete listing', () async {
    final host = ReferenceHost();
    await expectLater(
      host
          .preparation(shellOutput: '/work/note.md\nWING_END\n')
          .prepare(
            '@folder:/work',
            selected: const [],
            cwd: '/work',
            contextLimit: 10000,
            requireCurrent: () {},
          ),
      throwsFormatException,
    );
  });

  test('changed folder pages pause instead of mixing snapshots', () async {
    final host = ReferenceHost();
    var calls = 0;
    final repository = ComposerReferenceRepository(
      read: host.read,
      call: (method, params) async {
        calls++;
        return {
          'code': 0,
          'stderr': '',
          'stdout': calls == 1
              ? 'WING_BEGIN\n123 200\n${List.generate(8, (i) => '/work/file$i.md').join('\n')}\nWING_END\n'
              : 'WING_BEGIN\n456 200\n/work/changed.md\nWING_END\n',
        };
      },
    );
    await expectLater(
      repository.ignoredFilePaths('/work', '/work', requireCurrent: () {}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          'Folder changed while reading. Retry.',
        ),
      ),
    );
    expect(calls, 2);
    expect(host.reads, isEmpty);
  });
}
