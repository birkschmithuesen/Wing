import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/server_files_repository.dart';

void main() {
  test('default directory uses the profile terminal cwd endpoint', () async {
    final files = ServerFilesRepository(
      read: (endpoint, query) async {
        expect(endpoint, 'fs/default-cwd');
        expect(query, isEmpty);
        return {'cwd': '/workspace/team', 'branch': null};
      },
      write: null,
    );
    expect(await files.defaultDirectory(), '/workspace/team');
  });

  for (final cwd in [null, 42, '', 'relative', '/work/../other']) {
    test('default directory rejects invalid cwd $cwd', () async {
      final files = ServerFilesRepository(
        read: (_, _) async => {'cwd': cwd},
        write: null,
      );
      await expectLater(files.defaultDirectory(), throwsFormatException);
    });
  }

  test(
    'directory keeps canonical folders and omits broken or secret links',
    () async {
      final files = ServerFilesRepository(
        read: (endpoint, query) async {
          expect(endpoint, 'files');
          expect(query, {'path': '/work'});
          return {
            'path': '/work',
            'parent': '/',
            'entries': [
              {
                'name': 'project',
                'path': '/work/project',
                'is_directory': true,
              },
              {
                'name': 'broken',
                'path': '/work/broken',
                'is_directory': true,
                'broken_link': true,
              },
              {'name': 'secret', 'path': '/root/.ssh', 'is_directory': true},
              {'name': 'alias', 'path': '/work/../other', 'is_directory': true},
            ],
          };
        },
        write: null,
      );
      final listing = await files.directory('/work');
      expect(listing.path, '/work');
      expect(listing.parent, '/');
      expect(listing.entries.map((entry) => entry.path), ['/work/project']);
    },
  );

  test('read-only shared files cannot create directories', () async {
    final files = ServerFilesRepository(read: (_, _) async => {}, write: null);
    await expectLater(
      files.createDirectory('/work/new', canDispatch: () => true),
      throwsStateError,
    );
  });

  test('mkdir returns only the confirmed canonical directory', () async {
    var writes = 0;
    final files = ServerFilesRepository(
      read: (_, _) async => {},
      write: (endpoint, body, canDispatch) async {
        expect(endpoint, 'files/mkdir');
        expect(body, {'path': '/work/new'});
        expect(canDispatch(), isTrue);
        writes++;
        return {
          'ok': true,
          'path': '/resolved/new',
          'entry': {'path': '/resolved/new', 'is_directory': true},
        };
      },
    );
    expect(
      await files.createDirectory('/work/new', canDispatch: () => true),
      '/resolved/new',
    );
    expect(writes, 1);
  });

  for (final acknowledgement in <Map<String, dynamic>>[
    {'ok': false},
    {'path': ''},
    {'entry': null},
    {
      'entry': {'path': '/different', 'is_directory': true},
    },
    {
      'entry': {'path': '/work/new', 'is_directory': false},
    },
    {
      'path': '/work/../new',
      'entry': {'path': '/work/../new', 'is_directory': true},
    },
    {
      'path': '/root/.ssh/new',
      'entry': {'path': '/root/.ssh/new', 'is_directory': true},
    },
  ]) {
    test(
      'mkdir rejects unconfirmed or inadmissible acknowledgement $acknowledgement',
      () async {
        final files = ServerFilesRepository(
          read: (_, _) async => {},
          write: (_, _, _) async => {
            'ok': true,
            'path': '/work/new',
            'entry': {'path': '/work/new', 'is_directory': true},
            ...acknowledgement,
          },
        );
        await expectLater(
          files.createDirectory('/work/new', canDispatch: () => true),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
      },
    );
  }

  test(
    'mkdir passes its current admission to the physical write and keeps unsent failure',
    () async {
      var active = true;
      final retired = DashboardRequestNotSentException(StateError('Retired'));
      final files = ServerFilesRepository(
        read: (_, _) async => {},
        write: (_, _, canDispatch) async {
          active = false;
          expect(canDispatch(), isFalse);
          throw retired;
        },
      );
      await expectLater(
        files.createDirectory('/work/new', canDispatch: () => active),
        throwsA(same(retired)),
      );
    },
  );

  test('mkdir rejects credential paths before transport', () async {
    var writes = 0;
    final files = ServerFilesRepository(
      read: (_, _) async => {},
      write: (_, _, _) async {
        writes++;
        return {};
      },
    );
    await expectLater(
      files.createDirectory('/root/.ssh/new', canDispatch: () => true),
      throwsFormatException,
    );
    expect(writes, 0);
  });

  test('shared bytes retain size and canonical read admission', () async {
    var reads = 0;
    var target = '/work/note.md';
    final files = ServerFilesRepository(
      read: (endpoint, query) async {
        reads++;
        if (endpoint == 'files') {
          return {
            'path': '/work',
            'parent': '/',
            'entries': [
              {
                'name': 'note.md',
                'path': '/work/note.md',
                'is_directory': false,
                'size': 4,
                'mime_type': 'text/markdown',
              },
            ],
          };
        }
        expect(endpoint, 'files/read');
        expect(query, {'path': '/work/note.md'});
        return {
          'path': target,
          'size': 4,
          'data_url':
              'data:text/markdown;base64,${base64.encode(utf8.encode('note'))}',
        };
      },
      write: null,
    );
    final entry = await files.entry('/work/note.md');
    await expectLater(files.bytes(entry, maxBytes: 3), throwsFormatException);
    expect(reads, 1);
    expect(utf8.decode(await files.bytes(entry, maxBytes: 4)), 'note');
    target = '/work/replaced.md';
    await expectLater(files.bytes(entry, maxBytes: 4), throwsFormatException);
  });
}
