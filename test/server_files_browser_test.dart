import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/server_files_browser.dart';
import 'package:wing/core/services/server_files_repository.dart';

Map<String, dynamic> listing(String path, {String? parent}) => {
  'path': path,
  'parent': parent,
  'entries': const [],
};

void main() {
  test(
    'latest navigation wins and obsolete completion cannot clear progress',
    () async {
      final first = Completer<Map<String, dynamic>>(),
          second = Completer<Map<String, dynamic>>();
      final browser = ServerFilesBrowser(
        files: ServerFilesRepository(
          read: (_, query) =>
              query['path'] == '/first' ? first.future : second.future,
          write: null,
        ),
        isCurrent: () => true,
      );
      addTearDown(browser.dispose);
      final a = browser.open('/first');
      final b = browser.open('/second');
      first.complete(listing('/first'));
      await a;
      expect(browser.busy, isTrue);
      expect(browser.directory, isNull);
      second.complete(listing('/second'));
      await b;
      expect(browser.directory!.path, '/second');
      expect(browser.busy, isFalse);
    },
  );

  test('retired visit suppresses late directory results', () async {
    final gate = Completer<Map<String, dynamic>>();
    var current = true;
    final browser = ServerFilesBrowser(
      files: ServerFilesRepository(read: (_, _) => gate.future, write: null),
      isCurrent: () => current,
    );
    addTearDown(browser.dispose);
    final read = browser.open();
    current = false;
    gate.complete(listing('/srv'));
    await read;
    expect(browser.directory, isNull);
    expect(browser.canSelect, isFalse);
    expect(browser.busy, isFalse);
  });

  test(
    'failed navigation retains confirmed directory and retry targets failed path',
    () async {
      final paths = <String?>[];
      var failing = true;
      final browser = ServerFilesBrowser(
        files: ServerFilesRepository(
          read: (_, query) async {
            final path = query['path'];
            paths.add(path);
            if (path == '/srv/child' && failing) throw StateError('denied');
            return listing(path ?? '/srv');
          },
          write: null,
        ),
        isCurrent: () => true,
      );
      addTearDown(browser.dispose);
      await browser.open();
      await browser.open('/srv/child');
      expect(browser.directory!.path, '/srv');
      expect(browser.error, isNotNull);
      expect(browser.canSelect, isTrue);
      failing = false;
      await browser.retry();
      expect(paths, [null, '/srv/child', '/srv/child']);
      expect(browser.error, isNull);
      expect(browser.directory!.path, '/srv/child');
    },
  );

  test(
    'creation uses confirmed path and one write; traversal is refused',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      final writes = <String>[];
      final browser = ServerFilesBrowser(
        files: ServerFilesRepository(
          read: (_, query) async => listing(query['path'] ?? '/srv'),
          write: (_, body, active) {
            expect(active(), isTrue);
            writes.add(body['path'] as String);
            return gate.future;
          },
        ),
        isCurrent: () => true,
      );
      addTearDown(browser.dispose);
      await browser.open();
      expect(await browser.createFolder('../outside'), isFalse);
      expect(writes, isEmpty);
      final creating = browser.createFolder('new');
      expect(browser.creating, isTrue);
      expect(browser.canSelect, isFalse);
      expect(await browser.createFolder('duplicate'), isFalse);
      await browser.open('/other');
      expect(browser.directory!.path, '/srv');
      gate.complete({
        'ok': true,
        'path': '/srv/resolved',
        'entry': {'path': '/srv/resolved', 'is_directory': true},
      });
      expect(await creating, isTrue);
      expect(writes, ['/srv/new']);
      expect(browser.directory!.path, '/srv/resolved');
      expect(browser.canSelect, isTrue);
    },
  );

  test(
    'disposing during a write revokes dispatch and ignores late acknowledgement',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      late bool Function() dispatch;
      final browser = ServerFilesBrowser(
        files: ServerFilesRepository(
          read: (_, query) async => listing('/srv'),
          write: (_, body, active) {
            dispatch = active;
            return gate.future;
          },
        ),
        isCurrent: () => true,
      );
      await browser.open();
      final creation = browser.createFolder('new');
      browser.dispose();
      expect(dispatch(), isFalse);
      gate.complete({
        'ok': true,
        'path': '/srv/new',
        'entry': {'path': '/srv/new', 'is_directory': true},
      });
      expect(await creation, isFalse);
    },
  );
}
