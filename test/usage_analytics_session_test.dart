import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/usage_analytics.dart';
import 'package:wing/core/services/usage_analytics.dart';
import 'package:wing/core/services/usage_analytics_session.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/server_connection_status.dart';

import 'support/administration_fixture.dart';

Future<void> _until(UsageAnalyticsSession owner, bool Function() ready) async {
  if (ready()) return;
  final reached = Completer<void>();
  void observe() {
    if (ready() && !reached.isCompleted) reached.complete();
  }

  owner.addListener(observe);
  try {
    await reached.future;
  } finally {
    owner.removeListener(observe);
  }
}

void main() {
  test(
    'stale cached values stay available, failed refresh retains their timestamp',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      var now = DateTime.utc(2026, 10, 15, 1);
      Map<String, dynamic> payload(int cost) => {
        'models': [
          {
            'model': 'example',
            'provider': 'example',
            'estimated_cost': cost,
            'input_tokens': cost * 100,
            'cache_read_tokens': 0,
            'output_tokens': 0,
          },
        ],
        'daily': [],
      };
      fixture.override = (_, _, _, _) async => payload(3);
      final first = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, [
          'personal',
        ], now: () => now),
      );
      await first.load();
      final originalTime = first.state.updatedAt;
      first.dispose();
      now = now.add(const Duration(minutes: 5));
      final held = Completer<Map<String, dynamic>>();
      fixture.override = (_, _, _, _) => held.future;
      final next = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, [
          'personal',
        ], now: () => now),
      );
      addTearDown(next.dispose);
      expect(next.state.data!.models!.costs.total, 3);
      expect(next.state.updatedAt, originalTime);
      final before = fixture.requests.length;
      final loading = next.load();
      expect(next.state.data!.models!.costs.total, 3);
      expect(next.state.loading, isTrue);
      expect(fixture.requests.skip(before), hasLength(3));
      held.complete(payload(7));
      await loading;
      expect(next.state.data!.models!.costs.total, 7);
      expect(next.state.updatedAt, now);
      final successfulTime = next.state.updatedAt;
      now = now.add(const Duration(minutes: 1));
      fixture.override = (_, _, _, _) async =>
          throw const FormatException('Unavailable');
      await next.refresh();
      expect(next.state.data!.models!.costs.total, 7);
      expect(next.state.updatedAt, successfulTime);
      expect(next.state.data!.modelsError, isNotNull);
      expect(next.state.yearError, isNotNull);
    },
  );

  test(
    'All and single profiles share facts and cached All includes a refreshed profile',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      var workCost = 7;
      fixture.override = (_, path, query, _) async => path == 'analytics/models'
          ? {
              'models': [
                {
                  'model': 'example',
                  'provider': 'example',
                  'estimated_cost': query['profile'] == 'work' ? workCost : 3,
                  'input_tokens': 100,
                  'cache_read_tokens': 0,
                  'output_tokens': 10,
                },
              ],
            }
          : {'daily': []};
      UsageAnalyticsSession all() => UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, [
          'personal',
          'work',
        ]),
      );
      final first = all();
      await first.load();
      first.dispose();
      final before = fixture.requests.length;
      final single = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['work']),
      );
      addTearDown(single.dispose);
      expect(single.state.data!.models!.costs.total, 7);
      await single.load();
      expect(fixture.requests, hasLength(before));
      workCost = 17;
      await single.refresh();
      expect(fixture.requests.skip(before), hasLength(3));
      final next = all();
      addTearDown(next.dispose);
      expect(next.state.data!.models!.costs.total, 20);
      final refreshedCount = fixture.requests.length;
      await next.load();
      expect(next.state.data!.models!.costs.total, 20);
      expect(fixture.requests, hasLength(refreshedCount));
    },
  );

  test(
    'tokens publish before held shared prices and catalog reads are absent',
    () async {
      final fixture = AdministrationFixture()..pricingGate = Completer();
      addTearDown(fixture.server.close);
      fixture.override = (_, path, _, _) async {
        if (path == 'model/options') {
          throw StateError('Catalog must not be read');
        }
        return path == 'analytics/models'
            ? {
                'models': [
                  {
                    'model': 'gpt-6-astra',
                    'provider': 'openai-codex',
                    'input_tokens': 1000000,
                    'cache_read_tokens': 0,
                    'output_tokens': 0,
                  },
                ],
              }
            : {'daily': []};
      };
      final owner = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, [
          'personal',
          'work',
        ]),
      );
      addTearDown(owner.dispose);
      final loading = owner.load();
      await _until(owner, () => owner.state.data?.pricingLoading == true);
      expect(owner.state.data!.models!.tokens.total, 2000000);
      expect(owner.state.data!.models!.costs.total, isNull);
      expect(owner.state.data!.pricingLoading, isTrue);
      expect(fixture.pricingRefreshes, [false]);
      fixture.pricingGate!.complete(subscriptionApiPrices(input: 20));
      await loading;
      expect(owner.state.data!.models!.costs.total, 40);
      expect(owner.state.data!.pricingLoading, isFalse);
      expect(fixture.requests, hasLength(6));
      expect(
        fixture.requests.every((read) => read.$2.startsWith('analytics/')),
        isTrue,
      );
    },
  );

  test(
    'overlapping visits share held requests and one disposed observer does not cancel the other',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      final held = Completer<Map<String, dynamic>>();
      fixture.override = (_, _, _, _) => held.future;
      final first = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      final firstLoad = first.load();
      final next = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      addTearDown(next.dispose);
      final nextLoad = next.load();
      expect(fixture.requests, hasLength(3));
      first.dispose();
      held.complete({
        'models': [
          {
            'model': 'example',
            'provider': 'example',
            'estimated_cost': 7,
            'input_tokens': 100,
            'cache_read_tokens': 0,
            'output_tokens': 10,
          },
        ],
        'daily': [],
      });
      await Future.wait([firstLoad, nextLoad]);
      expect(next.state.data!.models!.costs.total, 7);
      expect(next.state.loading, isFalse);
      expect(first.state.data, isNull);
      expect(fixture.requests, hasLength(3));
    },
  );

  test(
    'connection retirement fences held prices and new authority starts with an empty cache',
    () async {
      final fixture = AdministrationFixture()..pricingGate = Completer();
      fixture.override = (_, path, _, _) async => path == 'analytics/models'
          ? {
              'models': [
                {
                  'model': 'gpt-6-astra',
                  'provider': 'openai-codex',
                  'input_tokens': 1000000,
                  'cache_read_tokens': 0,
                  'output_tokens': 0,
                },
              ],
            }
          : {'daily': []};
      final owner = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      final loading = owner.load();
      await _until(owner, () => owner.state.data?.pricingLoading == true);
      expect(fixture.pricingRefreshes, [false]);
      owner.dispose();
      fixture.server.close();
      fixture.pricingGate!.complete(subscriptionApiPrices());
      await loading;
      final other = AdministrationFixture(fixture.id);
      addTearDown(other.server.close);
      final replacement = UsageAnalyticsSession(
        UsageAnalyticsReader(other.server.usageAnalytics, ['personal']),
      );
      addTearDown(replacement.dispose);
      expect(replacement.state.data, isNull);
      expect(replacement.state.year, isNull);
    },
  );

  test(
    'cached analytics survives a disposed visit without another read',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      fixture.override = (_, path, _, _) async => path == 'analytics/models'
          ? {
              'models': [
                {
                  'model': 'example',
                  'provider': 'example',
                  'estimated_cost': 3,
                  'input_tokens': 100,
                  'cache_read_tokens': 0,
                  'output_tokens': 10,
                },
              ],
            }
          : {'daily': []};
      final first = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      await first.load();
      first.dispose();
      final before = fixture.requests.length;
      final next = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      addTearDown(next.dispose);
      expect(next.state.data?.models?.tokens.total, 110);
      expect(next.state.year, isNotNull);
      await next.load();
      expect(fixture.requests, hasLength(before));
    },
  );

  test(
    'model totals publish while daily and year reads are still held',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      final held = Completer<Map<String, dynamic>>();
      addTearDown(() {
        if (!held.isCompleted) held.complete({'daily': []});
      });
      fixture.override = (_, path, _, _) async => path == 'analytics/models'
          ? {
              'models': [
                {
                  'model': 'example',
                  'provider': 'example',
                  'estimated_cost': 3,
                  'input_tokens': 100,
                  'cache_read_tokens': 0,
                  'output_tokens': 10,
                },
              ],
            }
          : held.future;
      final owner = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      addTearDown(owner.dispose);
      final loading = owner.load();
      await _until(owner, () => owner.state.data?.models != null);
      expect(owner.state.data?.models?.tokens.total, 110);
      expect(owner.state.data?.daily, isNull);
      expect(owner.state.loading, isTrue);
      expect(fixture.requests.first.$3['days'], '7');
      held.complete({'daily': []});
      await loading;
    },
  );

  for (final retire in [false, true]) {
    test(
      'All bounds concurrent reads to ten and ${retire ? "retires queued reads" : "drains the queue"}',
      () async {
        final fixture = AdministrationFixture();
        addTearDown(fixture.server.close);
        final held = Completer<void>();
        var active = 0;
        var peak = 0;
        fixture.override = (_, path, _, _) async {
          active++;
          if (active > peak) peak = active;
          try {
            await held.future;
            return path == 'analytics/models' ? {'models': []} : {'daily': []};
          } finally {
            active--;
          }
        };
        final owner = UsageAnalyticsSession(
          UsageAnalyticsReader(fixture.server.usageAnalytics, [
            for (var i = 0; i < 12; i++) 'profile-$i',
          ]),
        );
        addTearDown(owner.dispose);
        final loading = owner.load();
        expect(owner.state.loading, isTrue);
        expect(fixture.requests, hasLength(10));
        expect(
          fixture.requests.map((r) => r.$3['profile']).toSet().length,
          greaterThan(1),
        );
        if (retire) owner.dispose();
        held.complete();
        await loading;
        expect(peak, 10);
        expect(active, 0);
        expect(fixture.requests, hasLength(retire ? 10 : 36));
        if (retire) {
          expect(owner.state.data, isNull);
        } else {
          expect(owner.state.loading, isFalse);
          expect(owner.state.data!.models!.tokens.total, 0);
          expect(owner.state.year!.days, isEmpty);
          expect(owner.state.data!.needsRecovery, isFalse);
        }
      },
    );
  }

  test(
    'Refresh reloads all unavailable analytics sections through real HTTP',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Uri>[];
      var unavailable = true;
      final subscription = server.listen((request) async {
        requests.add(request.uri);
        request.response.headers.contentType = ContentType.json;
        if (unavailable) {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write(jsonEncode({'detail': 'Unavailable'}));
        } else {
          request.response.write(
            jsonEncode({
              if (request.uri.path == '/api/analytics/models')
                'models': [
                  {
                    'model': 'example',
                    'provider': 'example',
                    'estimated_cost': 2,
                    'input_tokens': 100,
                    'cache_read_tokens': 0,
                    'output_tokens': 10,
                  },
                ]
              else
                'daily': [
                  {
                    'day': '2026-10-09',
                    'input_tokens': 100,
                    'cache_read_tokens': 0,
                    'output_tokens': 10,
                  },
                ],
            }),
          );
        }
        await request.response.close();
      });
      final status = ServerConnectionStatus('Test');
      final repository = AdministrationRepository.forConnection(
        ConnectionAccess(
          connection: SavedConnection(
            id: 'analytics-recovery',
            label: 'Test',
            host: '127.0.0.1',
            port: server.port,
            dashboardPortOverride: server.port,
            dashboardProxied: true,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        'analytics-recovery-http',
        connectionStatus: status,
      );
      final owner = UsageAnalyticsSession(
        UsageAnalyticsReader(repository.usageAnalytics, ['default']),
      );
      addTearDown(() async {
        owner.dispose();
        repository.close();
        status.dispose();
        await server.close(force: true);
        await subscription.cancel();
      });
      await owner.load();
      expect(owner.state.data!.models, isNull);
      expect(owner.state.data!.daily, isNull);
      expect(owner.state.data!.modelsError, 'Could not load model totals.');
      expect(owner.state.data!.dailyError, 'Could not load daily usage.');
      expect(owner.state.year, isNull);
      expect(owner.state.yearError, isNotNull);
      expect(owner.state.loading, isFalse);
      final failedCount = requests.length;
      unavailable = false;
      await owner.refresh();
      expect(owner.state.data!.models!.tokens.total, 110);
      expect(owner.state.data!.daily!.reportedDates, {'2026-10-09'});
      expect(owner.state.year!.reportedDates, {'2026-10-09'});
      expect(owner.state.data!.modelsError, isNull);
      expect(owner.state.data!.dailyError, isNull);
      expect(owner.state.yearError, isNull);
      expect(owner.state.loading, isFalse);
      expect(requests.skip(failedCount), hasLength(3));
      final retainedModels = owner.state.data!.models;
      final retainedDaily = owner.state.data!.daily;
      final retainedYear = owner.state.year;
      unavailable = true;
      await owner.refresh();
      expect(owner.state.data!.models, same(retainedModels));
      expect(owner.state.data!.daily, same(retainedDaily));
      expect(owner.state.year, same(retainedYear));
      expect(owner.state.data!.modelsError, isNotNull);
      expect(owner.state.data!.dailyError, isNotNull);
      expect(owner.state.yearError, contains('Showing retained activity'));
      expect(owner.state.loading, isFalse);
      unavailable = false;
      await owner.refresh();
      expect(owner.state.data!.modelsError, isNull);
      expect(owner.state.data!.dailyError, isNull);
      expect(owner.state.yearError, isNull);
      expect(
        requests.every((uri) => uri.queryParameters['profile'] == 'default'),
        isTrue,
      );
    },
  );

  for (final (name, ages, expected) in [
    (
      '30, 90 and 365 day totals remain distinct through real HTTP',
      [10, 60, 180],
      [(30, 1000, 1), (90, 7000, 2), (365, 25000, 3)],
    ),
    (
      'recent-only history has equal totals across correctly requested ranges',
      [10],
      [(30, 1000, 1), (90, 1000, 1), (365, 1000, 1)],
    ),
  ]) {
    test(name, () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Uri>[];
      final now = DateTime.utc(2026, 10, 7, 12);
      final records = [
        for (final age in ages)
          (date: now.subtract(Duration(days: age)), tokens: age * 100),
      ];
      final subscription = server.listen((request) async {
        requests.add(request.uri);
        final days = int.parse(request.uri.queryParameters['days'] ?? '30');
        final selected = records.where(
          (record) => record.date.isAfter(now.subtract(Duration(days: days))),
        );
        final tokens = selected.fold(0, (sum, record) => sum + record.tokens);
        Map<String, dynamic> counts(int tokens) => {
          'input_tokens': tokens,
          'cache_read_tokens': 0,
          'output_tokens': 0,
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'period_days': days,
            if (request.uri.path == '/api/analytics/models')
              'models': [
                {
                  'model': 'example',
                  'provider': 'example',
                  'estimated_cost': tokens / 1000,
                  ...counts(tokens),
                },
              ]
            else
              'daily': [
                for (final record in selected)
                  {
                    'day': record.date.toIso8601String().substring(0, 10),
                    ...counts(record.tokens),
                  },
              ],
          }),
        );
        await request.response.close();
      });
      final status = ServerConnectionStatus('Test');
      final repository = AdministrationRepository.forConnection(
        ConnectionAccess(
          connection: SavedConnection(
            id: 'analytics',
            label: 'Test',
            host: '127.0.0.1',
            port: server.port,
            dashboardPortOverride: server.port,
            dashboardProxied: true,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        'analytics-http',
        connectionStatus: status,
      );
      final owner = UsageAnalyticsSession(
        UsageAnalyticsReader(repository.usageAnalytics, [
          'butler',
        ], now: () => now),
      );
      addTearDown(() async {
        owner.dispose();
        repository.close();
        status.dispose();
        await server.close(force: true);
        await subscription.cancel();
      });
      await owner.load();
      for (final (days, tokens, dates) in expected) {
        await owner.selectPeriod(days);
        expect(owner.state.data!.models!.tokens.total, tokens);
        expect(owner.state.data!.models!.costs.total, tokens / 1000);
        expect(owner.state.data!.daily!.reportedDates, hasLength(dates));
      }
      expect(
        requests.every((uri) => uri.queryParameters['profile'] == 'butler'),
        isTrue,
      );
      expect(
        requests
            .where((uri) => uri.path == '/api/analytics/models')
            .map((uri) => uri.queryParameters['days']),
        ['7', '30', '90', '365'],
      );
      final count = requests.length;
      await owner.selectPeriod(30);
      expect(owner.state.data!.models!.tokens.total, 1000);
      expect(requests, hasLength(count));
    });
  }

  test(
    'held previous period cannot replace the currently selected period',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      final held = Completer<Map<String, dynamic>>();
      final issued = Completer<void>();
      fixture.override = (_, path, query, _) async {
        if (path == 'analytics/usage') return {'daily': []};
        if (query['days'] == '7') {
          issued.complete();
          return held.future;
        }
        return {
          'models': [
            {'model': 'Current', 'provider': 'example', 'estimated_cost': 3},
          ],
        };
      };
      final owner = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      addTearDown(owner.dispose);
      final loading = owner.load();
      await issued.future;
      await owner.selectPeriod(30);
      final current = owner.state.data!;
      held.complete({'models': []});
      await loading;
      expect(owner.state.days, 30);
      expect(owner.state.data, same(current));
      expect(owner.state.data!.models!.rows.single.model, 'Current');
      await owner.selectPeriod(7);
      expect(owner.state.data!.models!.rows, isEmpty);
      expect(fixture.requests.where((r) => r.$3['days'] == '7'), hasLength(2));
      expect(
        fixture.requests.every((r) => r.$3['profile'] == 'personal'),
        isTrue,
      );
    },
  );

  test(
    'retired owner publishes no held result and starts no reentrant read',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      final held = Completer<Map<String, dynamic>>();
      fixture.override = (_, _, _, _) => held.future;
      final owner = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      var publications = 0;
      owner.addListener(() => publications++);
      final loading = owner.load();
      final published = publications;
      owner.dispose();
      held.complete({'models': [], 'daily': []});
      await loading;
      await owner.refresh();
      expect(publications, published);
      expect(owner.state.data, isNull);
      final before = fixture.requests.length;
      final reentrant = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      reentrant.addListener(reentrant.dispose);
      await reentrant.load();
      expect(fixture.requests.length, before);
    },
  );

  test('Refresh revalidates shared API rates without catalog reads', () async {
    final fixture = AdministrationFixture();
    addTearDown(fixture.server.close);
    final catalog = subscriptionModelOptions();
    fixture.override = (_, path, _, _) async => path == 'model/options'
        ? catalog
        : path == 'analytics/usage'
        ? {'daily': []}
        : {
            'models': [
              {
                'provider': 'openai-codex',
                'model': 'gpt-6-astra',
                'input_tokens': 1000000,
                'cache_read_tokens': 0,
                'output_tokens': 0,
              },
            ],
          };
    final owner = UsageAnalyticsSession(
      UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
    );
    addTearDown(owner.dispose);
    await owner.load();
    expect(owner.state.data!.models!.costs.total, 10);
    fixture.apiPrices = subscriptionApiPrices(input: 20);
    await owner.refresh();
    expect(owner.state.data!.models!.costs.total, 20);
    expect(fixture.pricingRefreshes.last, isTrue);
    expect(fixture.requests.where((r) => r.$2 == 'model/options'), isEmpty);
  });

  test(
    'retirement cannot start a catalog read after held usage settles',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      final held = Completer<Map<String, dynamic>>();
      fixture.override = (_, path, _, _) => path == 'analytics/models'
          ? held.future
          : Future.value({'daily': []});
      final owner = UsageAnalyticsSession(
        UsageAnalyticsReader(fixture.server.usageAnalytics, ['personal']),
      );
      final pending = owner.load();
      owner.dispose();
      held.complete({
        'models': [
          {'provider': 'openai-codex', 'model': 'gpt-6-astra'},
        ],
      });
      await pending;
      expect(fixture.requests.where((r) => r.$2 == 'model/options'), isEmpty);
    },
  );

  test(
    'issued usage facts detach producer data and reject consumer mutation',
    () {
      final raw = <String, dynamic>{
        'model': 'Original',
        'provider': 'example',
        'estimated_cost': 2,
        'input_tokens': 10,
        'cache_read_tokens': 2,
        'output_tokens': 3,
      };
      final models = UsageModels.fromJson({
        'models': [raw],
      }, null);
      raw['model'] = 'Changed';
      raw['input_tokens'] = 999;
      expect(models.rows.single.model, 'Original');
      expect(models.tokens.total, 15);
      expect(() => models.rows.clear(), throwsUnsupportedError);
      expect(() => models.groups.clear(), throwsUnsupportedError);
      expect(() => models.groups.single.rows.clear(), throwsUnsupportedError);
      expect(
        () => models.rows.single.tokenCounts.clear(),
        throwsUnsupportedError,
      );
      expect(() => models.tokens.values.clear(), throwsUnsupportedError);
      final daily = UsageDaily.fromJson({
        'daily': [
          {'day': '2026-10-05', ...raw},
        ],
      }, period: 7);
      expect(() => daily.days.clear(), throwsUnsupportedError);
      expect(
        () => daily.days.single.tokens.values.clear(),
        throwsUnsupportedError,
      );
    },
  );
}
