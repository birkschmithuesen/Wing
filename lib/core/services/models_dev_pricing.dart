import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models_dev_prices.dart';

typedef ApiPricingRead = Future<ModelsDevPrices> Function({bool refresh});

/// App-wide public rate-card I/O, independent of Hermes credentials and scopes.
/// One in-flight request, six-hour freshness, conditional revalidation, and a
/// compact device cache. Failure retains rates with explicit uncertainty.
class ModelsDevPricing {
  ModelsDevPricing({
    required http.Client Function() client,
    required Future<String?> Function() readCache,
    required Future<void> Function(String value) writeCache,
    DateTime Function()? now,
  }) : // Public names keep these I/O seams injectable across libraries.
       // ignore: prefer_initializing_formals
       _client = client,
       // ignore: prefer_initializing_formals
       _readCache = readCache,
       // ignore: prefer_initializing_formals
       _writeCache = writeCache,
       _now = now ?? DateTime.now;

  static final shared = ModelsDevPricing(
    client: http.Client.new,
    readCache: () async =>
        (await SharedPreferences.getInstance()).getString(_key),
    writeCache: (value) async {
      if (!await (await SharedPreferences.getInstance()).setString(
        _key,
        value,
      )) {
        throw StateError('Could not save API price cache');
      }
    },
  );
  static const _key = 'wing-models-dev-openai-prices-v1';
  static final endpoint = Uri.parse('https://models.dev/api.json');
  static const freshness = Duration(hours: 6);
  final http.Client Function() _client;
  final Future<String?> Function() _readCache;
  final Future<void> Function(String value) _writeCache;
  final DateTime Function() _now;
  Future<ModelsDevPrices>? _pending;
  ModelsDevPrices? _snapshot;
  DateTime? _checkedAt;
  DateTime? _failedAt;
  String? _etag;
  bool _cacheRead = false;
  bool _downloadStarted = false;
  int _downloads = 0;

  Future<ModelsDevPrices> load({bool refresh = false}) {
    if (_pending case final pending?) {
      if (!refresh || _downloadStarted) return pending;
      final downloads = _downloads;
      // A cache-only read must not swallow an explicit refresh. If that read
      // itself downloads, the concurrent refresh shares its live observation.
      return pending.then(
        (prices) => _downloads != downloads ? prices : load(refresh: true),
      );
    }
    final result = _load(refresh).whenComplete(() {
      _pending = null;
      _downloadStarted = false;
    });
    _pending = result;
    return result;
  }

  bool _recent(DateTime? time, Duration age) =>
      time != null &&
      !_now().toUtc().isBefore(time) &&
      _now().toUtc().difference(time) < age;

  Future<ModelsDevPrices> _load(bool refresh) async {
    if (!_cacheRead) {
      _cacheRead = true;
      try {
        final raw = await _readCache();
        if (raw != null) {
          final data = jsonDecode(raw) as Map;
          if (data['schema'] != 1) {
            throw const FormatException('Price cache schema');
          }
          final prices = ModelsDevPrices.fromJson(data['prices'] as Map);
          final checked = DateTime.parse(data['checked_at'] as String).toUtc();
          if (!checked.isAfter(_now().toUtc())) {
            _snapshot = prices;
            _checkedAt = checked;
            _etag = data['etag'] is String ? data['etag'] as String : null;
          }
        }
      } catch (_) {
        // Corrupt/unreadable derived cache is replaced by a public download.
      }
    }
    if (!refresh && _failedAt == null && _recent(_checkedAt, freshness)) {
      return _snapshot!;
    }
    if (!refresh && _recent(_failedAt, const Duration(minutes: 1))) {
      return ModelsDevPrices(_snapshot?.models ?? {}, unavailable: true);
    }
    _downloadStarted = true;
    _downloads++;
    final client = _client();
    try {
      final response = await client
          .get(
            endpoint,
            headers: {'Accept': 'application/json', 'If-None-Match': ?_etag},
          )
          .timeout(const Duration(seconds: 12));
      ModelsDevPrices prices;
      if (response.statusCode == 304 && _snapshot != null) {
        prices = _snapshot!;
      } else {
        if (response.statusCode != 200 ||
            response.bodyBytes.length > 16000000) {
          throw const FormatException('Could not download API price catalog');
        }
        prices = ModelsDevPrices.fromJson(jsonDecode(response.body) as Map);
      }
      _snapshot = prices;
      _checkedAt = _now().toUtc();
      _failedAt = null;
      _etag =
          response.headers['etag'] ??
          (response.statusCode == 304 ? _etag : null);
      try {
        await _writeCache(
          jsonEncode({
            'schema': 1,
            'checked_at': _checkedAt!.toIso8601String(),
            'etag': _etag,
            'prices': prices.encode(),
          }),
        );
      } catch (_) {
        // Persistence failure does not discard a valid live observation.
      }
      return prices;
    } catch (_) {
      _failedAt = _now().toUtc();
      return ModelsDevPrices(_snapshot?.models ?? {}, unavailable: true);
    } finally {
      client.close();
    }
  }
}
