import 'package:flutter/foundation.dart';
import '../models/retained_memory.dart';
import 'administration_repository.dart';
import 'workspace_connection_failure.dart';

/// Immutable reading facts. No editing, deletion or runtime authority exists.
class RetainedMemoryReading<T> {
  const RetainedMemoryReading._({
    required this.value,
    required this.loading,
    required this.error,
    required this.checkedAt,
    required this.canRecover,
  });
  final T? value;
  final bool loading, canRecover;
  final String? error;
  final DateTime? checkedAt;
}

abstract class _MemoryReadSession<T> extends ChangeNotifier {
  _MemoryReadSession(this.profile) {
    profile.server.retain();
  }
  final ProfileAdministration profile;
  T? _value;
  bool _loading = true, _retryable = false, _disposed = false;
  String? _error;
  DateTime? _checkedAt;
  int _generation = 0;
  RetainedMemoryReading<T> get reading => RetainedMemoryReading._(
    value: _value,
    loading: _loading,
    error: _error,
    checkedAt: _checkedAt,
    canRecover: !_disposed && !_loading && _retryable,
  );
  String get _endpoint;
  Map<String, String> get _query;
  T _decode(Map<String, dynamic> data);
  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (_disposed) {
      return;
    }
    final generation = ++_generation;
    _loading = true;
    _retryable = false;
    _error = null;
    // A dispatched read drains its captured lease after the route retires.
    profile.server.retain();
    try {
      _changed();
      if (_disposed || generation != _generation) {
        return;
      }
      final decoded = _decode(await profile.read(_endpoint, _query));
      if (_disposed || generation != _generation) {
        return;
      }
      _value = decoded;
      _checkedAt = DateTime.now();
    } catch (failure) {
      if (_disposed || generation != _generation) {
        return;
      }
      _error = failure is FormatException
          ? 'The server returned an invalid response.'
          : administrationError(failure);
      _retryable = isTemporaryWorkspaceFailure(failure);
    } finally {
      profile.server.release();
      if (!_disposed && generation == _generation) {
        _loading = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    profile.server.release();
    super.dispose();
  }
}

class RetainedMemoryCatalogSession
    extends _MemoryReadSession<RetainedMemoryGraph> {
  RetainedMemoryCatalogSession(super.profile);
  String _search = '';
  String get search => _search;
  List<RetainedMemoryCard> get cards => List.unmodifiable(
    reading.value?.cards.where((c) => c.matches(_search)) ?? const [],
  );
  void searchFor(String value) {
    if (_disposed) {
      return;
    }
    _search = value;
    _changed();
  }

  @override
  String get _endpoint => 'learning/graph';
  @override
  Map<String, String> get _query => const {};
  @override
  RetainedMemoryGraph _decode(Map<String, dynamic> data) =>
      RetainedMemoryGraph.fromResponse(data);
}

class RetainedMemoryDetailSession
    extends _MemoryReadSession<RetainedMemoryDetail> {
  RetainedMemoryDetailSession(super.profile, this.identity);
  final RetainedMemoryIdentity identity;
  @override
  String get _endpoint => 'learning/node';
  @override
  Map<String, String> get _query => {'id': identity.value};
  @override
  RetainedMemoryDetail _decode(Map<String, dynamic> data) =>
      RetainedMemoryDetail.fromResponse(identity, data);
}
