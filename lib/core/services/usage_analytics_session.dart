import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/usage_analytics.dart';
import 'usage_analytics.dart';
import 'workspace_connection_failure.dart';

/// Immutable observation of a captured profile set's analytics.
class UsageAnalyticsState {
  const UsageAnalyticsState({
    required this.days,
    required this.data,
    required this.periodLoading,
    required this.year,
    required this.yearLoading,
    required this.yearError,
    required this.yearRetryable,
    required this.yearLoadedAt,
  });

  final int days;
  final UsageAnalyticsResult? data;
  final bool periodLoading;
  final UsageDaily? year;
  final bool yearLoading;
  final String? yearError;
  final bool yearRetryable;
  final DateTime? yearLoadedAt;

  DateTime? get updatedAt {
    final dates = [data?.loadedAt, yearLoadedAt].whereType<DateTime>();
    return dates.isEmpty ? null : dates.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  bool get loading => periodLoading || yearLoading;
  bool get needsRecovery =>
      yearRetryable && !yearLoading ||
      data?.needsRecovery == true && !periodLoading;
}

/// Period admission, retained partial results and recovery have one writer.
/// The existing reader owns stock I/O and shared year-read deduplication.
class UsageAnalyticsSession extends ChangeNotifier {
  UsageAnalyticsSession(UsageAnalyticsReader reader) : _reader = reader {
    for (final days in usagePeriods) {
      if (reader.cached(days) case final data?) _periods[days] = data;
    }
    _year = reader.cachedYear;
    _yearLoadedAt = reader.yearLoadedAt;
    _yearError = reader.yearError;
    _yearRetryable = reader.yearRetryable;
  }

  final UsageAnalyticsReader _reader;
  final _periods = <int, UsageAnalyticsResult>{};
  final _pending = <int, Future<void>>{};
  Future<void>? _yearPending;
  int _days = 7;
  UsageDaily? _year;
  DateTime? _yearLoadedAt;
  bool _yearLoading = false;
  bool _yearRetryable = false;
  String? _yearError;
  bool _closed = false;
  int _publicationDepth = 0;

  UsageAnalyticsState get state => UsageAnalyticsState(
    days: _days,
    data: _periods[_days],
    periodLoading: _pending.containsKey(_days),
    year: _year,
    yearLoading: _yearLoading,
    yearError: _yearError,
    yearRetryable: _yearRetryable,
    yearLoadedAt: _yearLoadedAt,
  );

  Future<void> load() => Future.wait([_loadPeriod(), _loadYear()]);

  Future<void> refresh() =>
      Future.wait([_loadPeriod(refresh: true), _loadYear(refresh: true)]);

  Future<void> selectPeriod(int days) async {
    if (_closed) return;
    if (!usagePeriods.contains(days)) throw ArgumentError.value(days, 'days');
    _days = days;
    _publish();
    if (_closed) return;
    await _loadPeriod(failedOnly: _periods[days]?.needsRecovery == true);
  }

  Future<void> recover() => Future.wait([
    if (_yearRetryable && !_yearLoading) _loadYear(),
    if (_periods[_days]?.needsRecovery == true && !_pending.containsKey(_days))
      _loadPeriod(failedOnly: true),
  ]);

  Future<void> _loadYear({bool refresh = false}) {
    if (_closed) return Future.value();
    if (_yearPending case final pending?) return pending;
    final settled = Completer<void>();
    _yearPending = settled.future;
    unawaited(
      _readYear(
        refresh: refresh,
      ).then(settled.complete, onError: settled.completeError),
    );
    return settled.future;
  }

  Future<void> _readYear({required bool refresh}) async {
    _yearLoading = true;
    _publish();
    if (_closed) return;
    try {
      final year = await _reader.loadYear(refresh: refresh);
      if (_closed) return;
      _year = year;
      _yearLoadedAt = _reader.yearLoadedAt;
      _yearError = null;
      _yearRetryable = false;
    } catch (error) {
      if (_closed) return;
      _yearRetryable = isTemporaryWorkspaceFailure(error);
      _yearError = _year == null
          ? 'Could not load the activity year. Use Refresh to retry.'
          : 'Could not refresh the activity year. Showing retained activity; use Refresh to retry.';
    } finally {
      _yearPending = null;
      if (!_closed) {
        _yearLoading = false;
        _publish();
      }
    }
  }

  Future<void> _loadPeriod({bool failedOnly = false, bool refresh = false}) {
    final days = _days;
    if (_closed) return Future.value();
    if (_pending[days] case final pending?) return pending;
    final settled = Completer<void>();
    _pending[days] = settled.future;
    unawaited(
      _readPeriod(
        days,
        failedOnly: failedOnly,
        refresh: refresh,
      ).then(settled.complete, onError: settled.completeError),
    );
    return settled.future;
  }

  Future<void> _readPeriod(
    int days, {
    required bool failedOnly,
    required bool refresh,
  }) async {
    _publish();
    if (_closed) return;
    final result = await _reader.load(
      days,
      retry: failedOnly ? _periods[days] : null,
      refresh: refresh,
      canRead: () => !_closed,
      onChanged: (progress) {
        if (_closed) return;
        _periods[days] = progress.retaining(_periods[days]);
        _publish();
      },
    );
    if (_closed) return;
    _pending.remove(days);
    _periods[days] = result.retaining(_periods[days]);
    _publish();
  }

  void _publish() {
    if (_closed) return;
    _publicationDepth++;
    try {
      notifyListeners();
    } finally {
      _publicationDepth--;
      if (_closed && _publicationDepth == 0) super.dispose();
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _reader.close();
    if (_publicationDepth == 0) super.dispose();
  }
}
