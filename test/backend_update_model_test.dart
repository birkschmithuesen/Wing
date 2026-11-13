import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/backend_update.dart';

void main() {
  test('only a valid finished receipt establishes a terminal outcome', () {
    for (final outcome in [
      'running',
      'success',
      'partial',
      'failed',
      'refused',
      'unknown',
    ]) {
      for (final finished in [null, '2026-11-13T05:00:00Z']) {
        final receipt = BackendUpdateReceipt.fromJson({
          'action_id': 'accepted-action',
          'outcome': outcome,
          'finished_at': finished,
        });
        expect(receipt, isNotNull);
        expect(receipt!.actionId, 'accepted-action');
        expect(receipt.pid, isNull);
        expect(
          receipt.terminal,
          finished != null &&
              ['success', 'partial', 'failed', 'refused'].contains(outcome),
        );
      }
    }
    for (final finished in ['', 'invalid', 42]) {
      expect(
        BackendUpdateReceipt.fromJson({
          'action_id': 'accepted-action',
          'outcome': 'success',
          'finished_at': finished,
        }),
        isNull,
      );
    }
  });

  test('invalid counts cannot grant update eligibility', () {
    for (final count in [null, -2, '2', 2.5, double.nan, true]) {
      final check = BackendUpdateCheck.fromJson({
        'behind': count,
        'can_apply': true,
        'update_available': true,
      });
      expect(check.failed, isTrue);
      expect(check.canStart, isFalse);
      expect(check.behind, isNull);
    }
  });
  test('unknown release count and failed check are distinct stock results', () {
    final release = BackendUpdateCheck.fromJson({
      'behind': -1,
      'can_apply': true,
      'update_available': true,
      'rollback_to': ' 0.21.6 ',
      'message': ' This moves back to stable. ',
    });
    expect(release.behind, isNull);
    expect(release.failed, isFalse);
    expect(release.canStart, isTrue);
    expect(release.rollbackTo, '0.21.6');
    expect(release.message, 'This moves back to stable.');
    expect(
      BackendUpdateCheck.fromJson({'can_apply': true, 'behind': null}).failed,
      isTrue,
    );
    expect(
      BackendUpdateCheck.fromJson({'can_apply': false, 'behind': null}).failed,
      isFalse,
    );
  });
  test('parses stock commit summaries and epoch seconds in server order', () {
    final check = BackendUpdateCheck.fromJson({
      'commits': [
        {
          'summary': ' Latest change ',
          'sha': 'abc1234',
          'author': 'Ada',
          'at': 1789646400,
        },
        {'summary': 'Earlier change', 'at': 1789560000},
      ],
    });
    expect(check.commits.map((c) => c.summary), [
      'Latest change',
      'Earlier change',
    ]);
    expect(check.commits.first.sha, 'abc1234');
    expect(check.commits.first.author, 'Ada');
    expect(check.commits.first.date?.millisecondsSinceEpoch, 1789646400000);
    expect(() => check.commits.clear(), throwsUnsupportedError);
  });

  test(
    'unusable changelog rows cannot break independent update eligibility',
    () {
      for (final rows in [
        null,
        'not a list',
        [
          null,
          42,
          {'summary': ''},
          {'summary': true},
        ],
      ]) {
        final check = BackendUpdateCheck.fromJson({
          'current_version': '1.2.3',
          'update_available': true,
          'can_apply': true,
          'behind': -1,
          'commits': rows,
        });
        expect(check.canStart, isTrue);
        expect(check.currentVersion, '1.2.3');
        expect(check.commits, isEmpty);
      }
    },
  );

  test(
    'unknown timestamps and metadata remain absent without losing summaries',
    () {
      for (final at in [
        null,
        0,
        -1,
        'yesterday',
        double.infinity,
        999999999999999999,
      ]) {
        final commit = BackendUpdateCommit.fromJson({
          'summary': 'A change',
          'at': at,
          'sha': [],
          'author': false,
        });
        expect(commit?.summary, 'A change');
        expect(commit?.date, isNull);
        expect(commit?.sha, isNull);
        expect(commit?.author, isNull);
      }
    },
  );
}
