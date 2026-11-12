import 'package:flutter/foundation.dart';

import '../models/answer_versions.dart';
import '../models/chat_reading.dart';
import '../models/transcript_notice.dart';
import 'profile_gateway.dart';

/// Captured saved-history access. It grants no live execution authority.
/// The workspace adapter owns scope validation and nearby-page installation.
abstract interface class ChatReadingSource implements Listenable {
  bool get current;
  Future<ProfileHistoryPage> load(int offset);
  bool show(ProfileHistoryPage page, int rowId);
}

/// The sole writer of a Find route's loaded pages, search and retry state.
/// Disposing it revokes publication and selection; it does not close its source.
final class ChatReadingSession extends ChangeNotifier {
  ChatReadingSession(this._source) {
    _source.addListener(_sourceChanged);
  }

  final ChatReadingSource _source;
  final _history = <_ReadingRow>[];
  String _query = '';
  int? _nextOffset = 0;
  int? _retryOffset;
  bool _loading = false;
  String? _error;
  bool _disposed = false;
  bool _retired = false;
  int _generation = 0;
  int _notificationDepth = 0;

  ChatReadingObservation get observation {
    return ChatReadingObservation(
      matches: _matches.map((entry) => entry.match),
      query: _query.trim(),
      hasLoadedMessages: _history.isNotEmpty,
      loading: _loading,
      hasMore: _nextOffset != null,
      error: _error,
      retired: !_current,
    );
  }

  Iterable<_ReadingRow> get _matches {
    final query = _query.trim().toLowerCase();
    return query.isEmpty
        ? const []
        : _history.reversed.where(
            (entry) => entry.match.text.toLowerCase().contains(query),
          );
  }

  void search(String query) {
    if (_disposed) {
      return;
    }
    _query = query;
    _emit();
  }

  Future<void> start() => _load(0);

  Future<void> loadOlder() async {
    final offset = _nextOffset;
    if (offset != null && _error == null) {
      await _load(offset);
    }
  }

  Future<void> retry() => _load(_retryOffset ?? 0);

  bool select(ChatReadingMatch match) {
    if (!_current || !match.canSelect) {
      return false;
    }
    final entry = _matches
        .where((entry) => identical(entry.match, match))
        .firstOrNull;
    if (entry == null || entry.id is! int) {
      return false;
    }
    return _source.show(entry.page, entry.id as int);
  }

  bool _owns(int generation) => !_disposed && generation == _generation;
  bool get _current => !_disposed && !_retired && _source.current;

  void _sourceChanged() {
    if (_disposed || _retired || _source.current) {
      return;
    }
    _retired = true;
    _emit();
  }

  Future<void> _load(int offset) async {
    if (_disposed || _loading) {
      return;
    }
    if (!_current) {
      _error = 'This chat changed. Close Find and open it again.';
      _emit();
      return;
    }
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _retryOffset = null;
    _emit();
    try {
      if (!_owns(generation) || !_current) {
        return;
      }
      final supplied = await _source.load(offset);
      if (!_owns(generation)) {
        return;
      }
      if (!_current) {
        _error = 'This chat changed. Close Find and open it again.';
        return;
      }
      // Capture the supplied values once. The transport/fixture must not be able
      // to mutate an issued match or the page later installed into the reader.
      final page = ProfileHistoryPage(
        supplied.sessionId,
        List.unmodifiable(supplied.rows.map(_freezeRow)),
        supplied.offset,
        supplied.limit,
        isComplete: supplied.isComplete,
      );
      if (offset == 0) {
        _history.clear();
      }
      final ids = _history.map((entry) => entry.id).toSet();
      final rows = [
        for (final row in page.rows)
          if (ids.add(row['id'])) _ReadingRow(page, row),
      ];
      if (offset == 0) {
        _history.addAll(rows);
      } else {
        _history.insertAll(0, rows);
      }
      _nextOffset = page.nextOffset;
    } catch (_) {
      if (_owns(generation)) {
        _retryOffset = offset;
        _error = !_current
            ? 'This chat changed. Close Find and open it again.'
            : _history.isEmpty
            ? "Couldn't search this chat. Check the Hermes connection, then try again."
            : "Couldn't load older messages. Your current results are still here. Check the Hermes connection, then try again.";
      }
    } finally {
      if (_owns(generation)) {
        _loading = false;
        _emit();
      }
    }
  }

  void _emit() {
    if (_disposed) {
      return;
    }
    ++_notificationDepth;
    try {
      notifyListeners();
    } finally {
      --_notificationDepth;
      if (_disposed && _notificationDepth == 0) {
        super.dispose();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    ++_generation;
    _source.removeListener(_sourceChanged);
    _history.clear();
    if (_notificationDepth == 0) {
      super.dispose();
    }
  }
}

final class _ReadingRow {
  _ReadingRow(this.page, Map<String, dynamic> row)
    : id = row['id'],
      match = ChatReadingMatch(
        text: _searchText(row),
        role: transcriptUserDelivery(row)?.kind == 'agent_message'
            ? transcriptUserDelivery(row)!.sender!
            : transcriptNoticeKind(row) != null
            ? 'system'
            : answerMessageDisplayRole(row) ?? 'message',
        canSelect: row['id'] is int,
      );

  final ProfileHistoryPage page;
  final Object? id;
  final ChatReadingMatch match;
}

String _searchText(Map<String, dynamic> row) {
  if (isHiddenAnswerMessage(row)) {
    return '';
  }
  final notice = transcriptNoticeText(row);
  if (notice != null) {
    return [notice, ?transcriptNoticeResult(row)].join('\n\n');
  }
  if (row['role'] == 'user') {
    return answerMessageDisplayText(row);
  }
  final content = row['content'] ?? row['text'] ?? row['message'];
  return content is String ? content : content?.toString() ?? '';
}

Map<String, dynamic> _freezeRow(Map<String, dynamic> row) =>
    Map<String, dynamic>.unmodifiable({
      for (final entry in row.entries) entry.key: _freezeValue(entry.value),
    });

Object? _freezeValue(Object? value) => switch (value) {
  Map value => Map.unmodifiable({
    for (final entry in value.entries) entry.key: _freezeValue(entry.value),
  }),
  List value => List.unmodifiable(value.map(_freezeValue)),
  _ => value,
};
