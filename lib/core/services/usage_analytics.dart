import 'dart:async';
import 'dart:collection';

import '../models/models_dev_prices.dart';
import '../models/hermes_profile.dart';
import '../models/usage_analytics.dart';
import 'models_dev_pricing.dart';
import 'workspace_connection_failure.dart';

/// Independent complete sections of one captured profile set. Pricing can
/// finish after token counts; a missing profile never becomes a smaller total.
class UsageAnalyticsResult {
  final UsageModels? models;
  final UsageDaily? daily;
  final String? modelsError;
  final String? dailyError;
  final DateTime loadedAt;
  final bool modelsRetryable;
  final bool dailyRetryable;
  final bool pricingLoading;
  bool get needsRecovery => modelsRetryable || dailyRetryable;
  const UsageAnalyticsResult({
    this.models,
    this.daily,
    this.modelsError,
    this.dailyError,
    required this.loadedAt,
    this.modelsRetryable = false,
    this.dailyRetryable = false,
    this.pricingLoading = false,
  });

  UsageAnalyticsResult retaining(UsageAnalyticsResult? previous) =>
      UsageAnalyticsResult(
        models: models ?? previous?.models,
        daily: daily ?? previous?.daily,
        modelsError: modelsError,
        dailyError: dailyError,
        modelsRetryable: modelsRetryable,
        dailyRetryable: dailyRetryable,
        pricingLoading: pricingLoading,
        loadedAt:
            previous != null &&
                (models == null && previous.models != null ||
                    daily == null && previous.daily != null)
            ? _oldest([loadedAt, previous.loadedAt])
            : loadedAt,
      );
}

DateTime _oldest(Iterable<DateTime> dates) =>
    dates.reduce((a, b) => a.isBefore(b) ? a : b);

typedef _YearObservation = ({UsageDaily data, DateTime loadedAt});

/// Scoped stock reads supplied by the captured administration connection.
typedef UsageAnalyticsRead =
    Future<Map<String, dynamic>> Function(
      String profile,
      String endpoint,
      Map<String, String> query,
    );

/// The captured connection owns cache, shared requests, pricing and admission.
/// Views own only their subscriptions. Nothing loads until Analytics is opened.
class UsageAnalyticsRepository {
  UsageAnalyticsRepository({
    required UsageAnalyticsRead read,
    required ApiPricingRead apiPricing,
  })
    // Public named I/O seam is shared with the picker, without catalog reads.
    // ignore: prefer_initializing_formals
    : _read = read,
       // ignore: prefer_initializing_formals
       _apiPricing = apiPricing;

  static const freshness = Duration(minutes: 5);
  final UsageAnalyticsRead _read;
  final ApiPricingRead _apiPricing;
  final _pool = _UsageReadPool(10);
  final _models = <(String, int), _UsageCache<UsageModels>>{};
  final _daily = <(String, int), _UsageCache<UsageDaily>>{};
  final _periods = <(String, int), UsageAnalyticsResult>{};
  final _years = <String, _YearObservation>{};
  ModelsDevPrices? _prices;
  Future<ModelsDevPrices>? _pendingPrices;
  bool _closed = false;

  _UsageCache<UsageModels> _model(String name, int days) =>
      _models.putIfAbsent((name, days), _UsageCache.new);
  _UsageCache<UsageDaily> _day(String name, int days) =>
      _daily.putIfAbsent((name, days), _UsageCache.new);

  Future<ModelsDevPrices> _readPrices({required bool refresh}) {
    return _pendingPrices ??= (() async {
      try {
        final prices = await _apiPricing(refresh: refresh);
        if (_closed) throw const _UsageReadRetired();
        return _prices = prices;
      } catch (error) {
        if (_closed) rethrow;
        return _prices = ModelsDevPrices(
          _prices?.models ?? {},
          unavailable: true,
        );
      } finally {
        _pendingPrices = null;
      }
    })();
  }

  /// Called only when the captured administration connection retires.
  void close() {
    _closed = true;
    _pool.close();
    _models.clear();
    _daily.clear();
    _periods.clear();
    _years.clear();
    _prices = null;
  }
}

/// A visit captures canonical profile names and observes connection-owned reads.
class UsageAnalyticsReader {
  UsageAnalyticsReader(
    this._repository,
    Iterable<String> names, {
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    _names = names.toList()..sort();
    if (_names.isEmpty) throw ArgumentError('Analytics needs a profile.');
    if (_names.any((name) => !HermesProfile.isCanonicalName(name))) {
      throw ArgumentError('Analytics needs canonical profile names.');
    }
    if (_names.toSet().length != _names.length) {
      throw ArgumentError('Analytics profiles must be distinct.');
    }
  }

  final DateTime Function() now;
  late final List<String> _names;
  final UsageAnalyticsRepository _repository;
  String get _scope => _names.join('\u0000');
  bool _closed = false;
  bool get _active => !_closed && !_repository._closed;

  String? _errors(Iterable<(String, Object?)> errors, String message) {
    final failed = errors.where((entry) => entry.$2 != null).toList();
    if (failed.isEmpty) return null;
    return failed
        .map((entry) => _names.length == 1 ? message : '${entry.$1}: $message')
        .join('\n');
  }

  UsageAnalyticsResult? cached(int days) {
    final saved = _repository._periods[(_scope, days)];
    final modelEntries = [
      for (final name in _names) _repository._model(name, days),
    ];
    final dailyEntries = [
      for (final name in _names) _repository._day(name, days),
    ];
    final hasModels = modelEntries.every((entry) => entry.value != null);
    final hasDaily = dailyEntries.every((entry) => entry.value != null);
    final modelsHealthy =
        hasModels && modelEntries.every((entry) => entry.error == null);
    final dailyHealthy =
        hasDaily && dailyEntries.every((entry) => entry.error == null);
    final models = modelsHealthy || hasModels && saved?.models == null
        ? _sumModels(modelEntries.map((entry) => entry.value!))
        : saved?.models;
    final daily = dailyHealthy || hasDaily && saved?.daily == null
        ? _sumDaily(dailyEntries.map((entry) => entry.value!))
        : saved?.daily;
    if (models == null && daily == null) return saved;
    final totals = models?.withPrices(_repository._prices);
    final pricingLoading =
        _repository._pendingPrices != null &&
        totals?.costs.hasSubscription == true;
    final priceError = pricingLoading
        ? null
        : _priceError(totals, _repository._prices);
    return UsageAnalyticsResult(
      models: totals,
      daily: daily,
      modelsError:
          _errors([
            for (var i = 0; i < _names.length; i++)
              (_names[i], modelEntries[i].error),
          ], 'Could not load model totals.') ??
          priceError,
      dailyError: _errors([
        for (var i = 0; i < _names.length; i++)
          (_names[i], dailyEntries[i].error),
      ], 'Could not load daily usage.'),
      modelsRetryable:
          priceError != null || modelEntries.any((entry) => entry.retryable),
      dailyRetryable: dailyEntries.any((entry) => entry.retryable),
      pricingLoading: pricingLoading,
      loadedAt: _oldest([
        if (modelsHealthy) ...modelEntries.map((entry) => entry.loadedAt!),
        if (dailyHealthy) ...dailyEntries.map((entry) => entry.loadedAt!),
        if (!modelsHealthy && models != null || !dailyHealthy && daily != null)
          saved?.loadedAt ??
              _oldest([
                ...modelEntries
                    .map((entry) => entry.loadedAt)
                    .whereType<DateTime>(),
                ...dailyEntries
                    .map((entry) => entry.loadedAt)
                    .whereType<DateTime>(),
              ]),
      ]),
    );
  }

  UsageDaily? get cachedYear => _cachedYear?.data;
  DateTime? get yearLoadedAt => _cachedYear?.loadedAt;
  bool get yearRetryable =>
      _names.any((name) => _repository._day(name, 365).retryable);
  String? get yearError => _errors(
    [for (final name in _names) (name, _repository._day(name, 365).error)],
    'Could not refresh the activity year. Showing retained activity; use Refresh to retry.',
  );

  _YearObservation? get _cachedYear {
    final saved = _repository._years[_scope];
    final entries = [for (final name in _names) _repository._day(name, 365)];
    if (saved != null && entries.any((entry) => entry.error != null)) {
      return saved;
    }
    if (entries.any((entry) => entry.value == null)) return saved;
    return (
      data: _sumDaily(entries.map((entry) => entry.value!)),
      loadedAt: _oldest(entries.map((entry) => entry.loadedAt!)),
    );
  }

  Future<UsageDaily> _readDaily(
    String name,
    int days, {
    required bool refresh,
    required bool Function() active,
    bool background = false,
  }) => _repository
      ._day(name, days)
      .read(
        repository: _repository,
        now: now,
        active: active,
        refresh: refresh,
        background: background,
        read: () async => UsageDaily.fromJson(
          await _repository._read(name, 'analytics/usage', {'days': '$days'}),
          period: days,
        ),
      );

  Future<UsageDaily> loadYear({bool refresh = false}) async {
    final saved = _cachedYear;
    if (!refresh &&
        saved != null &&
        _names.every((name) {
          final entry = _repository._day(name, 365);
          return entry._pending == null &&
              entry.error == null &&
              entry.fresh(now().toUtc());
        })) {
      return saved.data;
    }
    final years = await Future.wait([
      for (final name in _names)
        _readDaily(
          name,
          365,
          refresh: refresh,
          active: () => _active,
          background: true,
        ),
    ]);
    if (_repository._closed) throw const _UsageReadRetired();
    final observation = (
      data: _sumDaily(years),
      loadedAt: _oldest([
        for (final name in _names) _repository._day(name, 365).loadedAt!,
      ]),
    );
    if (!_repository._closed) _repository._years[_scope] = observation;
    return observation.data;
  }

  Future<UsageAnalyticsResult> load(
    int days, {
    UsageAnalyticsResult? retry,
    bool refresh = false,
    bool Function()? canRead,
    void Function(UsageAnalyticsResult)? onChanged,
  }) async {
    if (!usagePeriods.contains(days)) throw ArgumentError.value(days, 'days');
    final before = cached(days);
    final entries = [
      for (final name in _names) ...[
        _repository._model(name, days),
        _repository._day(name, days),
      ],
    ];
    if (!refresh &&
        before != null &&
        before.modelsError == null &&
        before.dailyError == null &&
        !before.pricingLoading &&
        entries.every(
          (entry) => entry._pending == null && entry.fresh(now().toUtc()),
        )) {
      return before;
    }
    final loadedAt = now().toUtc();
    final modelRows = List<UsageModels?>.filled(_names.length, null);
    final dailyRows = List<UsageDaily?>.filled(_names.length, null);
    final modelErrors = List<Object?>.filled(_names.length, null);
    final dailyErrors = List<Object?>.filled(_names.length, null);
    final modelDates = List<DateTime?>.filled(_names.length, null);
    final dailyDates = List<DateTime?>.filled(_names.length, null);
    var modelsDone = 0, dailyDone = 0;
    var pricingLoading = false;
    ModelsDevPrices? prices = _repository._prices;
    Future<void>? priceRead;
    bool active() => _active && canRead?.call() != false;
    UsageAnalyticsResult observation() {
      final models =
          modelsDone == _names.length && modelRows.every((row) => row != null)
          ? _sumModels(modelRows.whereType<UsageModels>()).withPrices(prices)
          : null;
      final daily =
          dailyDone == _names.length && dailyRows.every((row) => row != null)
          ? _sumDaily(dailyRows.whereType<UsageDaily>())
          : null;
      final modelsError = modelsDone == _names.length
          ? _errors([
                  for (var i = 0; i < _names.length; i++)
                    (_names[i], modelErrors[i]),
                ], 'Could not load model totals.') ??
                (pricingLoading ? null : _priceError(models, prices))
          : before?.modelsError;
      final dailyError = dailyDone == _names.length
          ? _errors([
              for (var i = 0; i < _names.length; i++)
                (_names[i], dailyErrors[i]),
            ], 'Could not load daily usage.')
          : before?.dailyError;
      return UsageAnalyticsResult(
        models: models,
        daily: daily,
        modelsError: modelsError,
        dailyError: dailyError,
        modelsRetryable:
            modelErrors.whereType<Object>().any(isTemporaryWorkspaceFailure) ||
            !pricingLoading && _priceError(models, prices) != null,
        dailyRetryable: dailyErrors.whereType<Object>().any(
          isTemporaryWorkspaceFailure,
        ),
        pricingLoading: pricingLoading,
        loadedAt: models != null || daily != null
            ? _oldest([
                if (models != null) ...modelDates.whereType<DateTime>(),
                if (daily != null) ...dailyDates.whereType<DateTime>(),
              ])
            : loadedAt,
      ).retaining(before);
    }

    void publish() {
      final result = observation();
      if (active()) {
        _repository._periods[(_scope, days)] = result;
      }
      if (active()) onChanged?.call(result);
    }

    void loadPrices() {
      if (priceRead != null || !active()) return;
      pricingLoading = true;
      priceRead = (() async {
        try {
          prices = await _repository._readPrices(refresh: refresh);
        } on _UsageReadRetired {
          // Connection retirement discards publication and cached observations.
        } finally {
          pricingLoading = false;
          if (modelsDone == _names.length) publish();
        }
      })();
    }

    await Future.wait([
      for (var i = 0; i < _names.length; i++)
        (() async {
          final entry = _repository._model(_names[i], days);
          try {
            modelRows[i] = await entry.read(
              repository: _repository,
              now: now,
              active: active,
              refresh: refresh && (retry == null || entry.retryable),
              read: () async => UsageModels.fromJson(
                await _repository._read(_names[i], 'analytics/models', {
                  'days': '$days',
                }),
                null,
              ),
            );
            modelDates[i] = entry.loadedAt;
            if (modelRows[i]!.costs.hasSubscription) loadPrices();
          } catch (error) {
            modelErrors[i] = error;
          }
          modelsDone++;
          if (modelsDone == _names.length) publish();
        })(),
      for (var i = 0; i < _names.length; i++)
        (() async {
          final entry = _repository._day(_names[i], days);
          try {
            dailyRows[i] = await _readDaily(
              _names[i],
              days,
              refresh: refresh && (retry == null || entry.retryable),
              active: active,
            );
            dailyDates[i] = entry.loadedAt;
          } catch (error) {
            dailyErrors[i] = error;
          }
          dailyDone++;
          if (dailyDone == _names.length) publish();
        })(),
    ]);
    await priceRead;
    return observation();
  }

  String? _priceError(UsageModels? models, ModelsDevPrices? prices) {
    if (models?.costs.hasSubscription != true) return null;
    if (prices != null && !prices.unavailable) return null;
    return prices?.models.isNotEmpty == true
        ? 'Could not refresh API prices. Subscription estimates use cached rates.'
        : 'Could not load API prices. Subscription estimates are unavailable.';
  }

  UsageModels _sumModels(Iterable<UsageModels> rows) =>
      rows.length == 1 ? rows.single : UsageModels.sum(rows);
  UsageDaily _sumDaily(Iterable<UsageDaily> rows) =>
      rows.length == 1 ? rows.single : UsageDaily.sum(rows);

  /// Release this observer; another visit can still share the admitted read.
  void close() => _closed = true;
}

class _UsageReadRetired implements Exception {
  const _UsageReadRetired();
}

class _UsageCache<T> {
  T? value;
  DateTime? loadedAt;
  Object? error;
  Future<T>? _pending;
  final _interests = <Object, bool Function()>{};
  bool get retryable => error != null && isTemporaryWorkspaceFailure(error!);
  bool fresh(DateTime now) =>
      loadedAt != null &&
      !now.isBefore(loadedAt!) &&
      now.difference(loadedAt!) < UsageAnalyticsRepository.freshness;

  Future<T> read({
    required UsageAnalyticsRepository repository,
    required Future<T> Function() read,
    required bool Function() active,
    required DateTime Function() now,
    required bool refresh,
    bool background = false,
  }) async {
    if (!active()) throw const _UsageReadRetired();
    final saved = value;
    if (_pending == null &&
        !refresh &&
        saved != null &&
        error == null &&
        fresh(now().toUtc())) {
      return saved;
    }
    final interest = Object();
    _interests[interest] = active;
    _pending ??= (() async {
      try {
        final result = await repository._pool.run(
          read,
          active: () =>
              !repository._closed &&
              _interests.values.any((interested) => interested()),
          background: background,
        );
        if (repository._closed) throw const _UsageReadRetired();
        value = result;
        loadedAt = now().toUtc();
        error = null;
        return result;
      } catch (failure) {
        if (failure is! _UsageReadRetired && !repository._closed) {
          error = failure;
        }
        rethrow;
      } finally {
        _pending = null;
      }
    })();
    try {
      return await _pending!;
    } finally {
      _interests.remove(interest);
    }
  }
}

class _UsageReadPool {
  _UsageReadPool(this.limit);
  final int limit;
  final _waiting = Queue<Completer<void>>();
  final _background = Queue<Completer<void>>();
  int _active = 0;
  bool _closed = false;

  Future<T> run<T>(
    Future<T> Function() read, {
    required bool Function() active,
    bool background = false,
  }) async {
    if (_closed) throw const _UsageReadRetired();
    if (_active >= limit) {
      final ready = Completer<void>();
      (background ? _background : _waiting).add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      if (_closed || !active()) throw const _UsageReadRetired();
      return await read();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else if (_background.isNotEmpty) {
        _background.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  void close() => _closed = true;
}
