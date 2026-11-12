import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/git_review.dart';
import 'package:wing/core/services/git_review_session.dart';
import 'support/git_review_fixture.dart';

void main() {
  test('all and staged comparisons use exact stock read-only routes', () async {
    final fixture = GitReviewFixture();
    final session = GitReviewSession(
      server: fixture.server,
      resolveWorkspace: () async => '/work/phone app',
    );
    addTearDown(session.dispose);
    await session.refresh();
    expect(session.files, hasLength(2));
    await session.open(session.files.first);
    expect(fixture.requests.last.$2, 'git/file-diff');
    expect(fixture.requests.last.$3, {
      'path': '/work/phone app',
      'file': 'lib/phone.dart',
    });
    await session.open(
      session.files.first,
      comparison: GitReviewComparison.staged,
    );
    expect(fixture.requests.last.$2, 'git/review/diff');
    expect(fixture.requests.last.$3['staged'], 'true');
    final before = fixture.requests.length;
    await session.open(
      session.files.last,
      comparison: GitReviewComparison.staged,
    );
    expect(fixture.requests.length, before);
    expect(
      fixture.requests.every((read) => read.$1 == 'GET' && read.$4 == null),
      true,
    );
  });

  test(
    'repeated pending selection coalesces while another comparison supersedes it',
    () async {
      final fixture = GitReviewFixture();
      final session = GitReviewSession(
        server: fixture.server,
        resolveWorkspace: () async => '/work/wing',
      );
      addTearDown(session.dispose);
      await session.refresh();
      fixture.diffGate = Completer<void>();
      final first = session.open(session.files.first);
      await Future<void>.delayed(Duration.zero);
      await session.open(session.files.first);
      expect(
        fixture.requests.where((call) => call.$2 == 'git/file-diff'),
        hasLength(1),
      );
      final staged = session.open(
        session.files.first,
        comparison: GitReviewComparison.staged,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        fixture.requests.where((call) => call.$2 == 'git/review/diff'),
        hasLength(1),
      );
      fixture.diffGate!.complete();
      await Future.wait([first, staged]);
      expect(session.comparison, GitReviewComparison.staged);
      expect(session.diff, isNotNull);
      expect(session.loading, false);
    },
  );

  test('changed line references distinguish old and new line numbers', () {
    final diff = GitReviewDiff(GitReviewFixture.sourceDiff);
    final removed = diff.lines.singleWhere((line) => line.removed);
    final added = diff.lines.where((line) => line.added).toList();
    expect(removed.oldLine, 8);
    expect(
      removed.reference('lib/phone.dart', GitReviewComparison.staged),
      contains('old version; staged'),
    );
    expect(added.map((line) => line.newLine), [8, 9]);
    expect(
      diff.lines
          .singleWhere((line) => line.hunk)
          .reference('lib/phone.dart', GitReviewComparison.all),
      contains('@@ -8,2 +8,3 @@'),
    );
    expect(
      diff.lines
          .where((line) => line.text.startsWith('+++'))
          .single
          .canReference,
      false,
    );
  });

  test(
    'leaving a held diff retires publication and workspace changes prevent reads',
    () async {
      final fixture = GitReviewFixture();
      var path = '/work/one';
      final session = GitReviewSession(
        server: fixture.server,
        resolveWorkspace: () async => path,
      );
      addTearDown(session.dispose);
      await session.refresh();
      fixture.diffGate = Completer<void>();
      final opening = session.open(session.files.first);
      await Future<void>.delayed(Duration.zero);
      expect(session.loading, true);
      session.showFiles();
      fixture.diffGate!.complete();
      await opening;
      expect(session.selected, null);
      expect(session.diff, null);
      path = '/work/two';
      final count = fixture.requests.length;
      await session.open(session.files.first);
      expect(fixture.requests.length, count);
      expect(session.error, isNotNull);
    },
  );

  test('unsupported workspace never dispatches host Git reads', () async {
    final fixture = GitReviewFixture();
    final session = GitReviewSession(
      server: fixture.server,
      resolveWorkspace: () async =>
          throw StateError('Git review requires a local terminal workspace.'),
    );
    addTearDown(session.dispose);
    await session.refresh();
    expect(session.error, contains('local terminal'));
    expect(fixture.requests, isEmpty);
  });
}
