import 'package:wing/core/services/administration_repository.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/models_dev_prices.dart';
import 'package:wing/core/models/model_catalog_details.dart';
import 'package:wing/core/services/profile_model_catalog.dart';

Map<String, dynamic> payload(String model) => {
  'providers': [
    {
      'slug': 'openai-codex',
      'name': 'OpenAI subscription',
      'models': [model],
    },
  ],
};

void main() {
  test('plan allowances preserve exhausted gauges and exact model routes', () {
    final catalog = ModelCatalog.fromOptions({
      'providers': [
        {
          'slug': 'nous',
          'name': 'Nous',
          'models': ['large', 'free'],
          'usage_levels': {'large': 'top_tier', 'free': 'free'},
          'plan_usage': {
            'kind': 'usage_window',
            'plan': 'Plus',
            'featured_model_ids': ['free'],
            'credits_pay': false,
            'gauges': [
              {
                'label': 'day',
                'left_fraction': 0,
                'scope': 'all',
                'resets_at_ms': 1793203200000,
              },
              {'label': 'top_tier', 'left_fraction': 0.25, 'scope': 'top_tier'},
            ],
          },
        },
        {
          'slug': 'other',
          'name': 'Other',
          'models': ['large'],
        },
      ],
    });
    final plan = catalog.provider('nous')!.planUsage!;
    expect(plan.gauges.first.leftFraction, 0);
    expect(plan.gauges.first.resetsAt!.millisecondsSinceEpoch, 1793203200000);
    expect(plan.creditsPay, isFalse);
    expect(catalog.choice('nous', 'large')!.allowanceLabel, 'Large');
    expect(catalog.choice('nous', 'free')!.recommended, isTrue);
    expect(catalog.choices.map((choice) => choice.model), [
      'free',
      'large',
      'large',
    ]);
    expect(catalog.choice('nous', 'free')!.allowanceGauges, isEmpty);
    expect(catalog.choice('nous', 'large')!.allowanceGauges, hasLength(2));
    expect(
      catalog.choice('nous', 'large')!.planLimitLabel,
      'Allowance used up',
    );
    expect(catalog.choice('nous', 'free')!.planLimitLabel, isNull);
    expect(catalog.choice('other', 'large')!.allowanceLabel, isNull);
    expect(catalog.choice('other', 'large')!.recommended, isFalse);
  });
  test('plan parsing rejects unknown kinds and invalid reset timestamps', () {
    expect(PlanUsage.parse({'kind': 'unknown'}), isNull);
    final plan = PlanUsage.parse({
      'kind': 'usage_window',
      'gauges': [
        {
          'label': 'day',
          'scope': 'all',
          'left_fraction': 0,
          'resets_at_ms': 9223372036854775807,
        },
      ],
    })!;
    expect(plan.gauges.single.resetsAt, isNull);
    expect(
      CurrentPlanGauge.parse({
        'id': 'day',
        'label': 'Daily',
        'used_bp': 8500,
      })!.usedPercent,
      85,
    );
    expect(
      CurrentPlanGauge.parse({
        'id': 'day',
        'label': 'Daily',
        'used_bp': double.nan,
      }),
      isNull,
    );
    expect(
      CurrentPlanGauge.parse({
        'id': 'day',
        'label': 'Daily',
        'used_bp': 9999,
      })!.usedLabel,
      '99% used',
    );
    expect(
      CurrentPlanGauge.parse({
        'id': 'day',
        'label': 'Daily',
        'used_bp': 1,
      })!.usedLabel,
      '<1% used',
    );
  });
  final scope = WorkspaceScope(
    connectionId: 'one',
    connectionIdentity: 'identity',
    profileName: 'work',
  );
  test('closing during public rate enrichment fences publication', () async {
    final held = Completer<ModelsDevPrices>();
    final pricingEntered = Completer<void>();
    final owner = ProfileModelCatalog(
      scope: scope,
      read: ({required refresh, required explicitOnly}) async =>
          payload('example'),
      apiPricing: ({refresh = false}) {
        pricingEntered.complete();
        return held.future;
      },
    );
    final pending = expectLater(owner.load(), throwsStateError);
    await pricingEntered.future;
    owner.close();
    held.complete(ModelsDevPrices({}));
    await pending;
    expect(owner.snapshot, isNull);
  });

  test(
    'refresh supersedes old rate enrichment as well as backend reads',
    () async {
      final held = <Completer<ModelsDevPrices>>[];
      final entered = [Completer<void>(), Completer<void>()];
      final owner = ProfileModelCatalog(
        scope: scope,
        read: ({required refresh, required explicitOnly}) async =>
            payload('example'),
        apiPricing: ({refresh = false}) {
          final next = Completer<ModelsDevPrices>();
          held.add(next);
          entered[held.length - 1].complete();
          return next.future;
        },
      );
      final old = expectLater(owner.load(), throwsStateError);
      await entered[0].future;
      final fresh = owner.load(refresh: true);
      await entered[1].future;
      final rates = ModelsDevPrices.fromJson({
        'openai': {
          'models': {
            'example': {
              'cost': {'input': 2, 'output': 10, 'cache_read': 0.2},
            },
          },
        },
      });
      held[1].complete(rates);
      expect((await fresh).apiPrices.models['example']!.inputUsdPerMillion, 2);
      held[0].complete(ModelsDevPrices({}));
      await old;
      expect(owner.snapshot!.apiPrices, same(rates));
      owner.close();
    },
  );
  test(
    'administration consumers share only their captured profile owner and cannot reopen it after close',
    () async {
      final queries = <Map<String, String>>[];
      final repository = AdministrationRepository(
        connectionId: 'one',
        connectionIdentity: 'identity',
        connectionLabel: 'Test',
        request: (method, endpoint, query, body) async {
          expect(endpoint, 'model/options');
          queries.add(Map.of(query));
          return payload('gpt-6-astra');
        },
        settingsWrite: (_, _, _, _) async =>
            throw StateError('Unexpected write'),
        ownedMutation: (_, _, _, _, _, _) async =>
            throw StateError('Unexpected mutation'),
        gateway: (_) => throw StateError('No socket needed'),
      );
      final work = repository.profile('work').modelCatalog;
      expect(identical(work, repository.profile('work').modelCatalog), isTrue);
      expect(
        identical(work, repository.profile('personal').modelCatalog),
        isFalse,
      );
      await work.load(explicitOnly: true, refresh: true);
      expect(queries.single, {
        'profile': 'work',
        'explicit_only': '1',
        'refresh': '1',
      });
      repository.close();
      await expectLater(work.load(), throwsStateError);
      expect(() => repository.profile('work').modelCatalog, throwsStateError);
      expect(queries, hasLength(1));
    },
  );
  test(
    'concurrent consumers share reads; refresh supersedes held results',
    () async {
      final requests = <Completer<Map<String, dynamic>>>[];
      final refreshes = <bool>[];
      final owner = ProfileModelCatalog(
        scope: scope,
        read: ({required refresh, required explicitOnly}) {
          refreshes.add(refresh);
          final request = Completer<Map<String, dynamic>>();
          requests.add(request);
          return request.future;
        },
      );
      final first = owner.load();
      expect(identical(first, owner.load()), isTrue);
      final old = expectLater(first, throwsStateError);
      final refreshed = owner.load(refresh: true);
      requests[1].complete(payload('gpt-6-astra'));
      await refreshed;
      requests[0].complete(payload('gpt-5.6-sol'));
      await old;
      expect(owner.snapshot!.choices.single.model, 'gpt-6-astra');
      expect(refreshes, [false, true]);
      expect(owner.scope, scope);
      owner.close();
    },
  );
  test(
    'explicit and chat policies never share pending reads or snapshots',
    () async {
      final held = <bool, Completer<Map<String, dynamic>>>{};
      final owner = ProfileModelCatalog(
        scope: scope,
        read: ({required refresh, required explicitOnly}) =>
            (held[explicitOnly] = Completer<Map<String, dynamic>>()).future,
      );
      final chat = owner.load();
      final explicit = owner.load(explicitOnly: true);
      held[true]!.complete(payload('gpt-5.6-sol'));
      expect((await explicit).choices.single.model, 'gpt-5.6-sol');
      expect(owner.snapshot, isNull);
      held[false]!.complete(payload('gpt-6-astra'));
      await chat;
      expect(owner.snapshot!.choices.single.model, 'gpt-6-astra');
      owner.close();
    },
  );
  test(
    'a synchronous transport failure does not poison the next load',
    () async {
      var calls = 0;
      final owner = ProfileModelCatalog(
        scope: scope,
        read: ({required refresh, required explicitOnly}) {
          if (++calls == 1) throw StateError('Closed request');
          return Future.value(payload('gpt-6-astra'));
        },
      );
      await expectLater(owner.load(), throwsStateError);
      expect((await owner.load()).choices.single.model, 'gpt-6-astra');
      expect(calls, 2);
      owner.close();
    },
  );
  test(
    'failed reads retain last snapshot; close fences pending completion',
    () async {
      var fail = false;
      final held = Completer<Map<String, dynamic>>();
      var hold = false;
      final owner = ProfileModelCatalog(
        scope: scope,
        read: ({required refresh, required explicitOnly}) async {
          if (hold) return held.future;
          if (fail) throw StateError('offline');
          return payload('gpt-6-astra');
        },
      );
      await owner.load();
      fail = true;
      await expectLater(owner.load(), throwsStateError);
      expect(owner.snapshot!.choices.single.model, 'gpt-6-astra');
      hold = true;
      final pending = expectLater(owner.load(), throwsStateError);
      owner.close();
      held.complete(payload('gpt-5.6-sol'));
      await pending;
      expect(owner.snapshot, isNull);
      await expectLater(owner.load(), throwsStateError);
    },
  );
  test(
    'pool quotas remain per account; optional and malformed fields stay absent',
    () {
      final catalog = ModelCatalog.fromOptions({
        'providers': [
          {
            'slug': 'openai-codex',
            'name': 'Subscription',
            'models': ['gpt-6-astra'],
            'usage': {
              'accounts': [
                {
                  'id': 'a',
                  'label': 'Personal',
                  'state': 'ready',
                  'windows': [
                    {
                      'label': '5h',
                      'used_percent': 12.5,
                      'scope': 'account',
                      'resets_at': '2026-10-07T15:00:00Z',
                    },
                  ],
                },
                {
                  'id': 'b',
                  'label': 'Work',
                  'state': 'limited',
                  'windows': [
                    {'label': 'Week', 'used_percent': 100, 'scope': 'account'},
                  ],
                  'resets_at': '2026-10-08T15:00:00Z',
                },
                {'id': 'c', 'label': '', 'state': 'unavailable', 'windows': []},
              ],
            },
            'pricing': {
              'gpt-6-astra': {'input': r'$5.00', 'output': null, 'free': false},
            },
          },
        ],
      });
      final usage = catalog.provider('openai-codex')!.usage!;
      expect(usage.windows, isEmpty);
      expect(usage.accounts, hasLength(3));
      expect(usage.accounts.first.windows.single.usedPercent, 12.5);
      expect(usage.accounts[1].state, AccountUsageState.limited);
      expect(usage.accounts[1].resetsAt, DateTime.utc(2026, 10, 8, 15));
      expect(usage.accounts.last.windows, isEmpty);
      expect(catalog.choices.single.controls, isNull);
      expect(catalog.choices.single.prices, isNull);
      expect(() => usage.accounts.clear(), throwsUnsupportedError);
    },
  );
}
