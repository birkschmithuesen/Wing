import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/model_catalog_details.dart';
import 'package:wing/core/models/models_dev_prices.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/usage_cost.dart';

void main() {
  ModelCatalog catalog(Map<String, dynamic> rates) => ModelCatalog.fromOptions(
    {
      'providers': [
        {
          'slug': 'openai-codex',
          'name': 'Subscription',
          'models': ['example'],
        },
      ],
    },
    apiPrices: ModelsDevPrices.fromJson({
      'openai': {
        'models': {
          'example': {'cost': rates},
        },
      },
    }),
  );
  final prices = catalog({'input': 2, 'cache_read': 0.25, 'output': 10});
  Map<String, dynamic> usage() => {
    'model': 'example',
    'provider': 'openai-codex',
    'input_tokens': 1000000,
    'cache_read_tokens': 2000000,
    'output_tokens': 100000,
    'reasoning_tokens': 75000,
    'estimated_cost': 0,
  };

  test(
    'prices disjoint buckets without subtracting cache or adding reasoning',
    () {
      final input = usage();
      final cost = ModelUsageCost.fromUsage(input, prices.apiPrices);
      expect(cost.inputCost, 2);
      expect(cost.cachedInputCost, 0.5);
      expect(cost.outputCost, 1);
      expect(cost.amount, 3.5);
      expect(cost.unavailable, isNull);
      expect(input['estimated_cost'], 0);
    },
  );

  test('uses provider identity, never zero cost or an OpenAI model name', () {
    for (final provider in [
      'openai',
      'openai-api',
      'openrouter',
      'local',
      null,
    ]) {
      for (final reported in [0, 19.5]) {
        final cost = ModelUsageCost.fromUsage(
          usage()..addAll({'provider': provider, 'estimated_cost': reported}),
          prices.apiPrices,
        );
        expect(cost.isApiEquivalent, isFalse);
        expect(cost.amount, reported);
      }
    }
    expect(
      ModelUsageCost.fromUsage(
        usage()..['estimated_cost'] = 99,
        prices.apiPrices,
      ).amount,
      3.5,
    );
  });

  test(
    'unknown IDs never inherit another model price or the included zero',
    () {
      for (final id in [
        'unknown',
        'example-pro',
        'example-900k',
        'openai/example',
      ]) {
        final cost = ModelUsageCost.fromUsage(
          usage()..['model'] = id,
          prices.apiPrices,
        );
        expect(cost.amount, isNull);
        expect(cost.unavailable, UsageCostUnavailable.price);
      }
    },
  );

  test('requires all three valid counters, with explicit zero accepted', () {
    for (final key in ['input_tokens', 'cache_read_tokens', 'output_tokens']) {
      for (final invalid in [
        null,
        -1,
        0.5,
        '100',
        true,
        double.nan,
        double.infinity,
        1e100,
      ]) {
        final cost = ModelUsageCost.fromUsage(
          usage()..[key] = invalid,
          prices.apiPrices,
        );
        expect(cost.amount, isNull, reason: '$key=$invalid');
        expect(cost.unavailable, UsageCostUnavailable.tokens);
      }
    }
    final zero = ModelUsageCost.fromUsage(
      usage()..addAll({
        'input_tokens': 0,
        'cache_read_tokens': 0,
        'output_tokens': 0,
      }),
      prices.apiPrices,
    );
    expect(zero.amount, 0);
    expect(zero.unavailable, isNull);
  });

  test('mixed subtotals and partial coverage count each supplied row once', () {
    final summary = UsageCostSummary([
      ModelUsageCost.fromUsage(usage(), prices.apiPrices),
      ModelUsageCost.fromUsage(
        usage(),
        prices.apiPrices,
      ), // separate auxiliary row
      ModelUsageCost.fromUsage({
        'provider': 'openai',
        'estimated_cost': 2,
      }, prices.apiPrices),
      ModelUsageCost.fromUsage(
        usage()..['model'] = 'unknown',
        prices.apiPrices,
      ),
    ]);
    expect(summary.isMixed, isTrue);
    expect(summary.isPartial, isTrue);
    expect(summary.pricedCount, 3);
    expect(summary.apiEquivalent, 7);
    expect(summary.reported, 2);
    expect(summary.total, 9);
    final unknown = UsageCostSummary([
      ModelUsageCost.fromUsage(
        usage()..['model'] = 'unknown',
        prices.apiPrices,
      ),
    ]);
    expect(unknown.total, isNull);
    expect(unknown.apiEquivalent, isNull);
    expect(UsageCostSummary([]).total, isNull);
  });

  test('small positive costs remain visibly different from zero', () {
    expect(formatUsageUsd(0), 'USD 0.00');
    expect(formatUsageUsd(0.000001), '< USD 0.01');
    expect(formatUsageUsd(0.00999), '< USD 0.01');
    expect(formatUsageUsd(0.01), 'USD 0.01');
    for (final invalid in [null, -1.0, double.nan, double.infinity]) {
      expect(formatUsageUsd(invalid), 'Unavailable');
    }
  });

  test(
    'stock price labels decode strictly without inventing missing rates',
    () {
      for (final (label, expected) in [
        (r'$2.50', 2.5),
        (r'$0.00', 0.0),
        (r'$0.00025', 0.00025),
        ('free', 0.0),
        ('?', null),
        ('', null),
        (null, null),
        ('2.5', null),
        (r'$-1.00', null),
        (r'$NaN', null),
        (r'$Infinity', null),
        (r'$1,000', null),
      ]) {
        final observation = ModelPrices.fromJson({
          'input': label,
          'free': false,
        });
        expect(observation.inputUsdPerMillion, expected, reason: '$label');
      }
      final missingCache = catalog({'input': 0, 'output': 0});
      expect(
        ModelUsageCost.fromUsage(usage(), missingCache.apiPrices).unavailable,
        UsageCostUnavailable.price,
      );
      final free = catalog({'input': 0, 'output': 0, 'cache_read': 0});
      expect(ModelUsageCost.fromUsage(usage(), free.apiPrices).amount, 0);
    },
  );

  test(
    'historical usage retains exact API rates outside the picker choices',
    () {
      final historical = ModelCatalog.fromOptions({
        'providers': [],
      }, apiPrices: prices.apiPrices);
      expect(historical.choices, isEmpty);
      expect(
        ModelUsageCost.fromUsage(usage(), historical.apiPrices).amount,
        3.5,
      );
    },
  );

  test(
    'included Codex zero and reseller rates cannot become API estimates',
    () {
      final wrongSources = ModelCatalog.fromOptions({
        'providers': [
          {
            'slug': 'openai-codex',
            'name': 'Subscription',
            'models': ['example'],
            'pricing': {
              'example': {
                'input': 'free',
                'output': 'free',
                'cache': 'free',
                'free': true,
              },
            },
          },
          {
            'slug': 'openrouter',
            'name': 'API',
            'models': ['example'],
            'pricing': {
              'example': {
                'input': r'$2.00',
                'output': r'$10.00',
                'cache': r'$0.25',
                'free': false,
              },
            },
          },
        ],
      });
      expect(
        ModelUsageCost.fromUsage(usage(), wrongSources.apiPrices).unavailable,
        UsageCostUnavailable.price,
      );
      expect(wrongSources.choice('openai-codex', 'example')!.prices, isNull);
      expect(
        wrongSources.choice('openrouter', 'example')!.prices!.input,
        r'$2.00',
      );
    },
  );
}
