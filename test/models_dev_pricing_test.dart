import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/models_dev_prices.dart';
import 'package:wing/core/services/models_dev_pricing.dart';

Map<String, dynamic> registry({double input = 2}) => {
  'openai': {
    'models': {
      'example': {
        'cost': {
          'input': input,
          'output': 10,
          'cache_read': 0.175,
          'context_over_200k': {'input': 100},
          'tiers': [
            {'input': 100},
          ],
        },
      },
      'retired': {
        'cost': {'input': 4, 'output': 20, 'cache_read': 0.4},
      },
    },
  },
  'openai-codex': {
    'models': {
      'example': {
        'cost': {'input': 0, 'output': 0},
      },
    },
  },
  'openrouter': {
    'models': {
      'example': {
        'cost': {'input': 999, 'output': 999},
      },
    },
  },
};

void main() {
  test(
    'decodes direct API rates exactly and shares them with both catalog policies',
    () {
      final api = ModelsDevPrices.fromJson(registry());
      final catalog = ModelCatalog.fromOptions({
        'providers': [
          {
            'slug': 'openai-codex',
            'name': 'Subscription',
            'models': ['example'],
          },
          {
            'slug': 'openai-api',
            'name': 'API',
            'models': ['example'],
          },
          {
            'slug': 'openrouter',
            'name': 'Reseller',
            'models': ['example'],
            'pricing': {
              'example': {'input': r'$9.00', 'free': false},
            },
          },
        ],
      }, apiPrices: api);
      final subscription = catalog.choice('openai-codex', 'example')!.prices!;
      expect(subscription.inputUsdPerMillion, 2);
      expect(subscription.cacheUsdPerMillion, 0.175);
      expect(subscription.apiEquivalent, isTrue);
      expect(subscription.free, isFalse);
      expect(catalog.apiPrices.models['retired']!.inputUsdPerMillion, 4);
      expect(
        catalog.choice('openai-api', 'example')!.prices,
        same(subscription),
      );
      expect(catalog.choice('openrouter', 'example')!.prices!.input, r'$9.00');
      for (final id in ['example-pro', 'example-900k', 'openai/example']) {
        expect(catalog.apiPrices.models[id], isNull);
      }
      expect(() => api.models.clear(), throwsUnsupportedError);
    },
  );

  test(
    'does not repair missing/invalid fields or choose subscription/reseller zeroes',
    () {
      for (final invalid in [
        -1,
        '2',
        double.nan,
        double.infinity,
        null,
        true,
      ]) {
        final data = jsonDecode(jsonEncode(registry())) as Map;
        (data['openai']['models']['example']
            as Map)['cost'] = <String, dynamic>{
          'input': invalid,
          'output': 10,
          'cache_read': 0.175,
        };
        final api = ModelsDevPrices.fromJson(data);
        expect(api.models['example'], isNull);
        expect(api.models['retired'], isNotNull);
      }
      final data = jsonDecode(jsonEncode(registry())) as Map;
      (data['openai']['models']['example']['cost'] as Map).remove('cache_read');
      expect(
        ModelsDevPrices.fromJson(data).models['example']!.cacheUsdPerMillion,
        isNull,
      );
      data.remove('openai');
      expect(() => ModelsDevPrices.fromJson(data), throwsFormatException);
    },
  );

  test(
    'one anonymous download is shared, persisted compactly and reused for six hours',
    () async {
      var time = DateTime.utc(2026, 10, 9);
      String? cache;
      final held = Completer<http.Response>();
      final requests = <http.Request>[];
      final owner = ModelsDevPricing(
        client: () => MockClient((request) {
          requests.add(request);
          return held.future;
        }),
        readCache: () async => cache,
        writeCache: (value) async => cache = value,
        now: () => time,
      );
      final first = owner.load();
      final second = owner.load();
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(1));
      expect(requests.single.url.toString(), 'https://models.dev/api.json');
      expect(requests.single.headers, {'Accept': 'application/json'});
      held.complete(
        http.Response(
          jsonEncode(registry()),
          200,
          headers: {'etag': 'revision-one'},
        ),
      );
      expect((await first).models['example']!.cacheUsdPerMillion, 0.175);
      expect(await second, same(await first));
      time = time.add(const Duration(hours: 5));
      expect(await owner.load(), same(await first));
      expect(requests, hasLength(1));
      final saved = jsonDecode(cache!) as Map;
      expect(saved['prices'].keys, ['openai']);
      expect(cache, isNot(contains('tiers')));
      expect(cache, isNot(contains('openrouter')));
    },
  );

  test(
    'restart reads the cache, expiry conditionally revalidates and refresh bypasses TTL',
    () async {
      var time = DateTime.utc(2026, 10, 9);
      String? cache;
      var calls = 0;
      final owner = ModelsDevPricing(
        client: () => MockClient((request) async {
          calls++;
          if (calls == 1) {
            return http.Response(
              jsonEncode(registry()),
              200,
              headers: {'etag': 'v1'},
            );
          }
          expect(request.headers['If-None-Match'], 'v1');
          return http.Response('', 304);
        }),
        readCache: () async => cache,
        writeCache: (value) async => cache = value,
        now: () => time,
      );
      await owner.load();
      final restarted = ModelsDevPricing(
        client: () => MockClient((request) async {
          calls++;
          expect(request.headers['If-None-Match'], 'v1');
          return http.Response('', 304);
        }),
        readCache: () async => cache,
        writeCache: (value) async => cache = value,
        now: () => time,
      );
      expect((await restarted.load()).unavailable, isFalse);
      expect(calls, 1);
      time = time.add(ModelsDevPricing.freshness);
      expect((await restarted.load()).models['retired'], isNotNull);
      expect(calls, 2);
      await restarted.load(refresh: true);
      expect(calls, 3);
      await restarted.load();
      expect(calls, 3);
    },
  );

  test(
    'offline/malformed downloads retain last rates with uncertainty and permit recovery',
    () async {
      var time = DateTime.utc(2026, 10, 9);
      var mode = 0;
      var calls = 0;
      String? cache;
      final owner = ModelsDevPricing(
        client: () => MockClient((_) async {
          calls++;
          if (mode == 1) throw http.ClientException('offline');
          if (mode == 2) return http.Response('{bad', 200);
          return http.Response(
            jsonEncode(registry(input: mode == 3 ? 5 : 2)),
            200,
          );
        }),
        readCache: () async => cache,
        writeCache: (value) async => cache = value,
        now: () => time,
      );
      await owner.load();
      final saved = cache;
      time = time.add(ModelsDevPricing.freshness);
      mode = 1;
      final offline = await owner.load();
      expect(offline.unavailable, isTrue);
      expect(offline.models['example']!.inputUsdPerMillion, 2);
      expect(cache, saved);
      await owner.load();
      expect(calls, 2);
      mode = 2;
      expect((await owner.load(refresh: true)).unavailable, isTrue);
      expect(cache, saved);
      mode = 3;
      final recovered = await owner.load(refresh: true);
      expect(recovered.unavailable, isFalse);
      expect(recovered.models['example']!.inputUsdPerMillion, 5);
      expect(cache, isNot(saved));
    },
  );

  test(
    'explicit refresh during cache admission still makes a live read',
    () async {
      final time = DateTime.utc(2026, 10, 9);
      final held = Completer<String?>();
      var downloads = 0;
      final owner = ModelsDevPricing(
        client: () => MockClient((_) async {
          downloads++;
          return http.Response(jsonEncode(registry(input: 5)), 200);
        }),
        readCache: () => held.future,
        writeCache: (_) async {},
        now: () => time,
      );
      final ordinary = owner.load();
      final refreshed = owner.load(refresh: true);
      held.complete(
        jsonEncode({
          'schema': 1,
          'checked_at': time.toIso8601String(),
          'prices': registry(),
        }),
      );
      expect((await ordinary).models['example']!.inputUsdPerMillion, 2);
      expect((await refreshed).models['example']!.inputUsdPerMillion, 5);
      expect(downloads, 1);
    },
  );

  test(
    'failed refresh stays qualified even when the previous cache was fresh',
    () async {
      var fail = false;
      var calls = 0;
      final owner = ModelsDevPricing(
        client: () => MockClient((_) async {
          calls++;
          if (fail) throw http.ClientException('offline');
          return http.Response(jsonEncode(registry()), 200);
        }),
        readCache: () async => null,
        writeCache: (_) async {},
      );
      expect((await owner.load()).unavailable, isFalse);
      fail = true;
      expect((await owner.load(refresh: true)).unavailable, isTrue);
      expect((await owner.load()).unavailable, isTrue);
      expect(calls, 2);
      fail = false;
      expect((await owner.load(refresh: true)).unavailable, isFalse);
    },
  );

  test(
    'bad device cache is replaced; cache-write failure keeps live rates',
    () async {
      final owner = ModelsDevPricing(
        client: () =>
            MockClient((_) async => http.Response(jsonEncode(registry()), 200)),
        readCache: () async => 'broken',
        writeCache: (_) async => throw StateError('disk'),
      );
      final prices = await owner.load();
      expect(prices.unavailable, isFalse);
      expect(prices.models['example']!.inputUsdPerMillion, 2);
    },
  );

  test(
    'initial failure reports unavailable without inventing any rates',
    () async {
      final owner = ModelsDevPricing(
        client: () =>
            MockClient((_) async => http.Response('unavailable', 503)),
        readCache: () async => null,
        writeCache: (_) async {},
      );
      final prices = await owner.load();
      expect(prices.unavailable, isTrue);
      expect(prices.models, isEmpty);
    },
  );
}
