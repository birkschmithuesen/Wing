import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/usage_analytics.dart';
import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/models_dev_prices.dart';
import 'package:wing/core/services/usage_analytics.dart';
import 'support/administration_fixture.dart';

void main() {
  test('profile capture rejects invalid sets before any read', () {
    final fixture = AdministrationFixture();
    addTearDown(fixture.server.close);
    for (final names in <List<String>>[
      [],
      ['default', 'default'],
      ['../other'],
      ['default\u0000work'],
      ['Default'],
    ]) {
      expect(
        () => UsageAnalyticsReader(fixture.server.usageAnalytics, names),
        throwsArgumentError,
      );
    }
    expect(fixture.requests, isEmpty);
    expect(fixture.pricingRefreshes, isEmpty);
  });

  final now = DateTime.utc(2026, 9, 18, 12);
  final row = <String, dynamic>{
    'model': 'gpt-6-astra',
    'provider': 'openai-codex',
    'input_tokens': 250000,
    'cache_read_tokens': 1000000,
    'output_tokens': 30000,
    'reasoning_tokens': 20000,
    'estimated_cost': 0,
  };

  test(
    'All sums profile valuations, models and server dates without losing unknowns',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      fixture.override = withSubscriptionModelOptions((
        _,
        path,
        query,
        _,
      ) async {
        final name = query['profile'];
        if (path == 'analytics/models') {
          return {
            'models': [
              if (name == 'work') row,
              if (name == 'default')
                {...row, 'provider': 'openai', 'estimated_cost': 2},
            ],
          };
        }
        return {
          'daily': [
            if (name == 'default')
              {
                'day': '2026-09-16',
                'input_tokens': 10,
                'cache_read_tokens': 2,
                'output_tokens': 3,
              },
            if (name != 'empty')
              {
                'day': '2026-09-18',
                'input_tokens': 20,
                'cache_read_tokens': 0,
                'output_tokens': name == 'work' ? null : 5,
              },
          ],
        };
      });
      final reader = UsageAnalyticsReader(fixture.server.usageAnalytics, [
        for (final name in ['default', 'work', 'empty']) name,
      ]);
      final data = await reader.load(7);
      expect(data.models!.tokens.total, 2560000);
      expect(data.models!.costs.total, 7);
      expect(data.models!.costs.reported, 2);
      expect(data.models!.costs.apiEquivalent, 5);
      expect(data.models!.groups, hasLength(1));
      expect(data.models!.groups.single.rows, hasLength(2));
      expect(data.daily!.reportedDates, {'2026-09-16', '2026-09-18'});
      expect(data.daily!.days.map((day) => day.tokens.values), [
        [10, 2, 3],
        [0, 0, 0],
        [40, 0, null],
      ]);
      expect(data.daily!.calendarDays.first.isPlaceholder, isTrue);
      expect(data.modelsError, isNull);
      expect(data.dailyError, isNull);
    },
  );

  test(
    'All never reports a smaller total when a profile fails and retries only failed sections',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      var failed = true;
      fixture.override = (_, path, query, _) async {
        if (failed &&
            query['profile'] == 'work' &&
            path == 'analytics/models') {
          throw TimeoutException('Offline');
        }
        if (path == 'analytics/models') {
          return {
            'models': [
              {...row, 'provider': 'openai', 'estimated_cost': 2},
            ],
          };
        }
        return {
          'daily': [
            {
              'day': '2026-09-18',
              'input_tokens': 20,
              'cache_read_tokens': 0,
              'output_tokens': 5,
            },
          ],
        };
      };
      final reader = UsageAnalyticsReader(fixture.server.usageAnalytics, [
        'default',
        'work',
      ]);
      final partial = await reader.load(7);
      expect(partial.models, isNull);
      expect(partial.modelsError, contains('work:'));
      expect(partial.modelsRetryable, isTrue);
      expect(partial.daily!.days.single.tokens.total, 50);
      final before = fixture.requests.length;
      failed = false;
      final recovered = await reader.load(7, retry: partial);
      expect(recovered.models!.costs.total, 4);
      expect(recovered.models!.tokens.total, 2560000);
      expect(recovered.modelsError, isNull);
      expect(recovered.needsRecovery, isFalse);
      expect(fixture.requests.skip(before), hasLength(1));
      expect(fixture.requests.last.$2, 'analytics/models');
      expect(fixture.requests.last.$3['profile'], 'work');
    },
  );

  test(
    'All shares year reads per profile and retries only unavailable years',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      var failed = true;
      fixture.override = (_, path, query, _) async {
        if (path == 'analytics/models') return {'models': []};
        if (failed && query['profile'] == 'work') {
          throw TimeoutException('Offline');
        }
        return {
          'daily': [
            {
              'day': '2026-09-18',
              'input_tokens': 20,
              'cache_read_tokens': 0,
              'output_tokens': 5,
            },
          ],
        };
      };
      final reader = UsageAnalyticsReader(fixture.server.usageAnalytics, [
        'default',
        'work',
      ]);
      final year = reader.loadYear();
      final full = reader.load(365);
      await expectLater(year, throwsA(isA<TimeoutException>()));
      expect((await full).daily, isNull);
      // The shared year future includes the repository's three transport tries.
      expect(fixture.requests, hasLength(6));
      final before = fixture.requests.length;
      failed = false;
      expect((await reader.loadYear()).days.single.tokens.total, 50);
      expect(fixture.requests.skip(before), hasLength(1));
      expect(fixture.requests.last.$3['profile'], 'work');
    },
  );

  final prices = ModelCatalog.fromOptions(
    subscriptionModelOptions(),
    apiPrices: subscriptionApiPrices(),
  );
  test(
    'subscription valuation shares direct API rates with the picker',
    () async {
      final fixture = AdministrationFixture()
        ..apiPrices = subscriptionApiPrices(input: 20);
      addTearDown(fixture.server.close);
      fixture.override = withSubscriptionModelOptions(
        (_, path, _, _) async => path == 'analytics/usage'
            ? {'daily': []}
            : {
                'models': [row],
              },
      );
      final profile = fixture.server.profile('personal');
      final picker = await profile.modelCatalog.load();
      expect(
        picker
            .choice('openai-codex', 'gpt-6-astra')!
            .prices!
            .inputUsdPerMillion,
        20,
      );
      final result = await UsageAnalyticsReader(profile.server.usageAnalytics, [
        profile.name,
      ]).load(7);
      expect(result.models!.costs.total, 7.5);
    },
  );
  test('missing registry rates preserve tokens and reported costs', () async {
    final fixture = AdministrationFixture()..apiPrices = ModelsDevPrices({});
    addTearDown(fixture.server.close);
    fixture.override = (_, path, _, _) async {
      if (path == 'model/options') {
        return {
          'providers': [
            {
              'slug': 'openai-codex',
              'name': 'Subscription',
              'models': ['gpt-6-astra'],
            },
          ],
        };
      }
      if (path == 'analytics/usage') return {'daily': []};
      return {
        'models': [
          row,
          {...row, 'provider': 'openai', 'estimated_cost': 7},
        ],
      };
    };
    final result = await UsageAnalyticsReader(fixture.server.usageAnalytics, [
      'personal',
    ]).load(7);
    expect(result.models!.tokens.total, 2560000);
    expect(result.models!.costs.apiEquivalent, isNull);
    expect(result.models!.costs.reported, 7);
    expect(result.models!.costs.isPartial, isTrue);
    expect(result.modelsError, isNull);
  });

  test(
    'rate download failure keeps tokens, cached estimates and explicit retry state',
    () async {
      final fixture = AdministrationFixture()
        ..apiPrices = ModelsDevPrices(
          subscriptionApiPrices().models,
          unavailable: true,
        );
      addTearDown(fixture.server.close);
      fixture.override = withSubscriptionModelOptions(
        (_, path, _, _) async => path == 'analytics/usage'
            ? {'daily': []}
            : {
                'models': [row],
              },
      );
      final reader = UsageAnalyticsReader(fixture.server.usageAnalytics, [
        'personal',
      ]);
      final stale = await reader.load(7);
      expect(stale.models!.costs.total, 5);
      expect(stale.models!.tokens.total, 1280000);
      expect(stale.modelsError, contains('cached rates'));
      expect(stale.modelsRetryable, isTrue);
      fixture.apiPrices = subscriptionApiPrices(input: 20);
      final recovered = await reader.load(7, retry: stale, refresh: true);
      expect(recovered.models!.costs.total, 7.5);
      expect(recovered.modelsError, isNull);
      expect(recovered.modelsRetryable, isFalse);
      expect(recovered.daily, same(stale.daily));
    },
  );

  test('initial public price failure never hides successful usage', () async {
    final fixture = AdministrationFixture()
      ..apiPrices = ModelsDevPrices({}, unavailable: true);
    addTearDown(fixture.server.close);
    fixture.override = withSubscriptionModelOptions(
      (_, path, _, _) async => path == 'analytics/usage'
          ? {'daily': []}
          : {
              'models': [row],
            },
    );
    final data = await UsageAnalyticsReader(fixture.server.usageAnalytics, [
      'personal',
    ]).load(7);
    expect(data.models!.tokens.total, 1280000);
    expect(data.models!.costs.total, isNull);
    expect(data.modelsError, contains('unavailable'));
    expect(data.modelsRetryable, isTrue);
  });

  test(
    'pricing failure retries only the shared rates, retaining usage',
    () async {
      final fixture = AdministrationFixture()..failPricing = true;
      addTearDown(fixture.server.close);
      fixture.override = (_, path, _, _) async => path == 'analytics/usage'
          ? {'daily': []}
          : {
              'models': [row],
            };
      final reader = UsageAnalyticsReader(fixture.server.usageAnalytics, [
        'client-work',
      ]);
      final partial = await reader.load(7);
      expect(partial.models!.tokens.total, 1280000);
      expect(partial.models!.costs.total, isNull);
      expect(partial.modelsRetryable, isTrue);
      fixture.failPricing = false;
      fixture.requests.clear();
      final complete = await reader.load(7, retry: partial);
      expect(complete.models!.costs.total, 5);
      expect(complete.modelsError, isNull);
      expect(complete.daily, same(partial.daily));
      expect(fixture.requests, isEmpty);
      expect(fixture.pricingRefreshes, [false, false]);
    },
  );

  test('analytics prices directly while the picker catalog is held', () async {
    final fixture = AdministrationFixture();
    addTearDown(fixture.server.close);
    final held = Completer<Map<String, dynamic>>();
    fixture.override = (_, path, _, _) async => path == 'model/options'
        ? held.future
        : path == 'analytics/usage'
        ? {'daily': []}
        : {
            'models': [row],
          };
    final profile = fixture.server.profile('personal');
    final picker = profile.modelCatalog.load();
    final reader = UsageAnalyticsReader(profile.server.usageAnalytics, [
      profile.name,
    ]);
    final data = await reader.load(7);
    expect(data.models!.costs.total, 5);
    expect(
      fixture.requests.where((request) => request.$2 == 'model/options'),
      hasLength(1),
    );
    held.complete(subscriptionModelOptions());
    await picker;
    final before = fixture.requests.length;
    fixture.apiPrices = subscriptionApiPrices(input: 20);
    final refreshed = await reader.load(7, refresh: true);
    expect(refreshed.models!.costs.total, 7.5);
    expect(fixture.requests.skip(before).map((request) => request.$2).toSet(), {
      'analytics/models',
      'analytics/usage',
    });
    expect(fixture.pricingRefreshes.last, isTrue);
  });

  test(
    'failed yearly cache is evicted and only failed aggregate is retried',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      var fail = true;
      fixture.override = (_, path, _, _) async {
        if (path == 'analytics/models') return {'models': []};
        if (fail) throw TimeoutException('Offline');
        return {'daily': []};
      };
      final reader = UsageAnalyticsReader(fixture.server.usageAnalytics, [
        'personal',
      ]);
      final partial = await reader.load(365);
      expect(partial.models, isNotNull);
      expect(partial.dailyRetryable, isTrue);
      fail = false;
      fixture.requests.clear();
      final complete = await reader.load(365, retry: partial);
      expect(complete.models, same(partial.models));
      expect(complete.daily, isNotNull);
      expect(complete.needsRecovery, isFalse);
      expect(fixture.requests.map((r) => r.$2), ['analytics/usage']);
      expect(await reader.loadYear(), same(complete.daily));
      expect(fixture.requests.length, 1);
    },
  );

  test(
    'returned server dates and unknown counts survive without inferred boundaries',
    () {
      final data = UsageDaily.fromJson({
        'daily': [
          {'day': '2026-09-17', ...row},
          {'day': '2026-09-18', 'input_tokens': 3, 'output_tokens': 2},
        ],
      }, period: 1);
      expect(data.days.map((d) => d.id), ['2026-09-17', '2026-09-18']);
      expect(data.days.first.tokens.total, 1280000);
      expect(data.days.last.tokens.total, isNull);
    },
  );
  test('empty daily analytics remains empty', () {
    final empty = UsageDaily.fromJson({'daily': []}, period: 365);
    expect(empty.days, isEmpty);
    expect(empty.calendarDays, isEmpty);
  });
  test('missing daily analytics is rejected', () {
    expect(() => UsageDaily.fromJson({}, period: 7), throwsFormatException);
  });
  test('impossible calendar dates are rejected', () {
    expect(
      () => UsageDaily.fromJson({
        'daily': [
          {'day': '2026-02-30'},
        ],
      }, period: 7),
      throwsFormatException,
    );
  });
  for (final (name, dates) in [
    ('positive offset at UTC year end', ['2026-12-31', '2027-01-01']),
    ('negative offset partial first date', ['2025-12-30', '2025-12-31']),
    ('spring DST', ['2026-03-08', '2026-03-09']),
    ('fall DST', ['2026-11-01', '2026-11-02']),
    ('month rollover', ['2026-09-30', '2026-10-01']),
  ]) {
    test('$name preserves every returned date and its tokens', () {
      final daily = UsageDaily.fromJson({
        'daily': [
          for (final date in dates.reversed)
            {
              'day': date,
              'input_tokens': 100,
              'cache_read_tokens': 0,
              'output_tokens': 50,
            },
        ],
      }, period: 1);
      expect(daily.days.map((d) => d.id), dates);
      expect(daily.reportedDates, dates.toSet());
      expect(UsageTokens.sum(daily.days.map((d) => d.tokens)).total, 300);
      expect(daily.days.every((d) => d.date.isUtc && !d.isPlaceholder), isTrue);
      expect(daily.calendarDays.last.id, dates.last);
      expect(daily.calendarDays.first.isPlaceholder, isTrue);
      expect(daily.calendarDays.first.tokens.total, isNull);
    });
  }
  test(
    'year view preserves adjacent-year rows and marks only padding unknown',
    () {
      final daily = UsageDaily.fromJson({
        'daily': [
          {
            'day': '2025-12-31',
            'input_tokens': 0,
            'cache_read_tokens': 0,
            'output_tokens': 0,
          },
          {
            'day': '2027-01-01',
            'input_tokens': 100,
            'cache_read_tokens': 0,
            'output_tokens': 50,
          },
        ],
      }, period: 365);
      expect(daily.calendarDays.first.id, '2025-12-31');
      expect(daily.calendarDays.last.id, '2027-01-01');
      expect(daily.calendarDays.where((d) => d.isPlaceholder), isEmpty);
      expect(daily.days.first.tokens.total, 0);
      expect(daily.days[1].tokens.total, 0);
      expect(daily.reportedDates, {'2025-12-31', '2027-01-01'});
      expect(UsageTokens.sum(daily.days.map((d) => d.tokens)).total, 150);
    },
  );
  test(
    'model totals combine providers and auxiliary usage without adding reasoning',
    () {
      final data = UsageModels.fromJson({
        'models': [
          row,
          row,
          {...row, 'provider': 'openai', 'estimated_cost': 7},
        ],
      }, prices.apiPrices);
      expect(data.groups.length, 1);
      expect(data.costs.total, 17);
      expect(data.tokens.total, 3840000);
      expect(data.groups.single.model, 'gpt-6-astra');
      expect(data.groups.single.costs.total, 17);
      expect(data.groups.single.tokens.total, 3840000);
      expect(data.groups.single.rows.length, 3);
      expect(data.tokenCosts, isNull);
      expect(
        UsageModels.fromJson({
          'models': [row],
        }, prices.apiPrices).tokenCosts,
        [2.5, 1, 1.5],
      );
    },
  );
  test('missing tokens and unknown prices stay unavailable in aggregates', () {
    final data = UsageModels.fromJson({
      'models': [
        row,
        {...row, 'model': 'unknown', 'cache_read_tokens': null},
      ],
    }, prices.apiPrices);
    expect(data.tokens.total, isNull);
    expect(data.tokens.values[0], 500000);
    expect(data.costs.total, 5);
    expect(data.costs.isPartial, isTrue);
    expect(data.tokenCosts, isNull);
  });
  test('fractional, negative and infinite token counts remain unknown', () {
    expect(
      UsageTokens.fromJson({
        'input_tokens': 1.5,
        'cache_read_tokens': -1,
        'output_tokens': double.infinity,
      }).values,
      [null, null, null],
    );
  });
  test(
    'parallel bounded reads retain profile and independent successes',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      final models = Completer<Map<String, dynamic>>();
      final daily = Completer<Map<String, dynamic>>();
      fixture.override = withSubscriptionModelOptions(
        (_, path, _, _) =>
            path == 'analytics/models' ? models.future : daily.future,
      );
      final reader = UsageAnalyticsReader(fixture.server.usageAnalytics, [
        'client-work',
      ], now: () => now);
      final result = reader.load(365);
      expect(fixture.requests.map((r) => r.$2).toSet(), {
        'analytics/models',
        'analytics/usage',
      });
      expect(
        fixture.requests.every(
          (r) =>
              r.$1 == 'GET' &&
              r.$3['profile'] == 'client-work' &&
              r.$3['days'] == '365',
        ),
        isTrue,
      );
      models.complete({
        'models': [row],
      });
      daily.completeError(StateError('Offline'));
      final loaded = await result;
      expect(loaded.models!.costs.total, 5);
      expect(loaded.daily, isNull);
      expect(loaded.dailyError, isNotNull);
      expect(loaded.modelsError, isNull);
    },
  );
  test(
    'year read is shared, period boundary counts stay independent, refresh retries',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      var offline = false;
      fixture.override = (_, path, query, _) async {
        if (path == 'analytics/models') return {'models': []};
        if (offline && query['days'] == '365') throw StateError('Offline');
        return {
          'daily': [
            {
              'day': '2026-09-18',
              'input_tokens': int.parse(query['days']!),
              'cache_read_tokens': 0,
              'output_tokens': 0,
            },
          ],
        };
      };
      final reader = UsageAnalyticsReader(fixture.server.usageAnalytics, [
        'client-work',
      ], now: () => now);
      final year = reader.loadYear();
      final week = await reader.load(7);
      expect((await year).days.last.tokens.total, 365);
      expect(week.daily!.days.last.tokens.total, 7);
      expect(fixture.requests.length, 3);
      final full = await reader.load(365);
      expect(identical(full.daily, await year), isTrue);
      expect(fixture.requests.length, 4);
      await reader.load(30);
      expect(
        fixture.requests
            .where((r) => r.$2 == 'analytics/usage' && r.$3['days'] == '365')
            .length,
        1,
      );
      offline = true;
      await expectLater(reader.loadYear(refresh: true), throwsStateError);
      expect((await reader.load(7)).daily, isNotNull);
      offline = false;
      expect(
        (await reader.loadYear(refresh: true)).days.last.tokens.total,
        365,
      );
      expect(
        fixture.requests.every((r) => r.$3['profile'] == 'client-work'),
        isTrue,
      );
    },
  );
}
