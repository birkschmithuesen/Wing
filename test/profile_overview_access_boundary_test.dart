import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_overview_summary.dart';
import 'package:wing/core/services/profile_overview_session.dart';
import 'support/administration_fixture.dart';

void main() {
  for (final invalid in [7, null, '', '   ']) {
    test(
      'invalid provider identity $invalid retains confirmed access data before projection',
      () async {
        SharedPreferences.setMockInitialValues({});
        final fixture = AdministrationFixture('Access boundary $invalid');
        var malformed = false;
        fixture.override = (_, _, _, _) async => {
          'providers': [
            {
              'id': malformed ? invalid : 'selected',
              'status': {
                'logged_in': true,
                'source_label': 'Profile credentials',
              },
            },
          ],
        };
        final session = ProfileOverviewSession(
          fixture.server.profile('personal'),
          await SharedPreferences.getInstance(),
          refreshWorkspace: () async {},
        );
        addTearDown(session.dispose);
        await session.refresh(keys: {'access'});
        final observation = session.overviewOwner.observations['access']!;
        final confirmed = observation.data;
        final checkedAt = observation.checkedAt;
        malformed = true;
        await session.refresh(keys: {'access'});
        final latest = session.overviewOwner.observations['access']!;
        expect(latest.data, same(confirmed));
        expect(latest.checkedAt, checkedAt);
        expect(latest.error, isNotNull);
        expect(observation.data, same(confirmed));
        expect(observation.checkedAt, checkedAt);
        expect(observation.error, isNull);
        expect(observation.loading, isFalse);
        expect(() => session.summary, returnsNormally);
        expect(
          session.summary.rows[ProfileOverviewDestination.access]!.attention,
          'Refresh unavailable',
        );
      },
    );
  }
  test(
    'initial malformed access response remains unavailable without a rendering crash',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = AdministrationFixture('Initial malformed access');
      fixture.override = (_, _, _, _) async => {
        'providers': [
          {'id': 7},
        ],
      };
      final session = ProfileOverviewSession(
        fixture.server.profile('personal'),
        await SharedPreferences.getInstance(),
        refreshWorkspace: () async {},
      );
      addTearDown(session.dispose);
      await session.refresh(keys: {'access'});
      final observation = session.overviewOwner.observations['access']!;
      expect(observation.data, isNull);
      expect(observation.checkedAt, isNull);
      expect(observation.error, isNotNull);
      expect(() => session.summary, returnsNormally);
      expect(
        session.summary.rows[ProfileOverviewDestination.access]!.attention,
        'Information unavailable',
      );
    },
  );

  test(
    'valid identity retains supported sparse and unknown provider status',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = AdministrationFixture('Unknown access boundary');
      fixture.override = (_, _, _, _) async => {
        'providers': [
          {'id': 'sparse'},
          {
            'id': 'unknown',
            'status': {'logged_in': null},
          },
          {
            'id': 'reported',
            'status': {'logged_in': true},
          },
        ],
      };
      final session = ProfileOverviewSession(
        fixture.server.profile('personal'),
        await SharedPreferences.getInstance(),
        refreshWorkspace: () async {},
      );
      addTearDown(session.dispose);
      await session.refresh(keys: {'access'});
      expect(session.overviewOwner.observations['access']!.error, isNull);
      final row = session.summary.rows[ProfileOverviewDestination.access]!;
      final text = row.summary.render(
        integer: (n) => '$n',
        checkedTime: (_) => '',
        taskTime: (_) => '',
      );
      expect(text, startsWith('1 sign-in reported'));
      expect(row.attention, isNull);
    },
  );
}
