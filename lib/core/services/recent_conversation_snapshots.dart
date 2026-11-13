import '../models/recent_conversation.dart';
import '../models/bots.dart';
import 'package:flutter/foundation.dart';

/// A disposable raster resource supplied by the rendering adapter.
abstract interface class RecentConversationSnapshot {
  int get byteSize;
  void dispose();
}

/// Decoded discovery messages retained by the same workspace catalog owner.
/// A caller can borrow only the exact immutable room observation with coverage.
final class RecentGroupMessages {
  static const roomLimit = 10;
  static const messageLimit = 10;
  static const byteLimit = 1024 * 1024;
  final _entries =
      <
        String,
        ({
          BotGroup group,
          List<BotGroupEvent> messages,
          bool complete,
          int bytes,
        })
      >{};
  bool _closed = false;
  int get retainedBytes =>
      _entries.values.fold(0, (size, entry) => size + entry.bytes);
  int get length => _entries.length;

  void record(
    BotGroup group,
    Iterable<BotGroupEvent> messages, {
    required bool complete,
  }) {
    if (_closed || !group.observationComplete) return;
    final all = messages.where((event) => event.isTranscriptEntry).toList();
    final retained = all.skip((all.length - messageLimit).clamp(0, all.length));
    final tail = List<BotGroupEvent>.unmodifiable(retained);
    if (tail.isEmpty && !complete) return;
    final bytes = tail.fold<int>(
      0,
      (size, event) =>
          size +
          128 +
          2 *
              (event.text.length +
                  event.actor.length +
                  event.actorId.length +
                  event.actorName.length),
    );
    if (bytes > byteLimit) return;
    _entries.remove(group.key);
    _entries[group.key] = (
      group: group,
      messages: tail,
      complete: complete && all.length <= messageLimit,
      bytes: bytes,
    );
    while (_entries.length > roomLimit || retainedBytes > byteLimit) {
      _entries.remove(_entries.keys.first);
    }
  }

  List<BotGroupEvent>? borrow(BotGroup group, {required int limit}) {
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    final entry = _entries[group.key];
    if (entry == null ||
        !identical(entry.group, group) ||
        (entry.messages.length < limit && !entry.complete)) {
      return null;
    }
    _entries.remove(group.key);
    _entries[group.key] = entry;
    return List.unmodifiable(
      entry.messages.skip(
        (entry.messages.length - limit).clamp(0, entry.messages.length),
      ),
    );
  }

  /// Metadata/runtime replacements may reuse only unchanged message coverage.
  void rebind(BotGroup previous, BotGroup updated) {
    final entry = _entries[previous.key];
    if (entry == null ||
        !identical(entry.group, previous) ||
        previous.key != updated.key ||
        previous.messageCoverageSequence != updated.messageCoverageSequence ||
        previous.lastMessageSequence != updated.lastMessageSequence ||
        previous.lastAnswerSequence != updated.lastAnswerSequence) {
      return;
    }
    _entries[updated.key] = (
      group: updated,
      messages: entry.messages,
      complete: entry.complete,
      bytes: entry.bytes,
    );
  }

  void dispose() {
    _closed = true;
    _entries.clear();
  }
}

/// Workspace-owned screenshot retention. Rendering stays with the caller;
/// all list/chat/group borrowers share this budget and resource lifetime.
final class RecentConversationSnapshots extends ChangeNotifier {
  RecentConversationSnapshots({this.byteLimit = 32 * 1024 * 1024});

  final int byteLimit;
  final _entries =
      <
        RecentConversationKey,
        ({
          RecentConversationSnapshot snapshot,
          bool live,
          Object revision,
          Object environment,
        })
      >{};
  int _bytes = 0, _reserved = 0;
  bool _closed = false;
  Set<RecentConversationKey> _neighborhood = {};

  int get retainedBytes => _bytes;
  int get reservedBytes => _reserved;
  List<RecentConversationKey> keysFor(Object environment) => [
    for (final entry in _entries.entries)
      if (entry.value.environment == environment) entry.key,
  ];

  RecentConversationSnapshot? snapshotFor(
    RecentConversationKey key, {
    required Object environment,
  }) {
    final entry = _entries[key];
    return entry?.environment == environment ? entry?.snapshot : null;
  }

  bool isLive(RecentConversationKey key, {required Object environment}) =>
      _entries[key]?.environment == environment && _entries[key]!.live;
  Object? revisionFor(
    RecentConversationKey key, {
    required Object environment,
  }) => _entries[key]?.environment == environment
      ? _entries[key]?.revision
      : null;

  void reserve(int bytes) {
    if (bytes < 0) throw ArgumentError.value(bytes, 'bytes');
    _reserved += bytes;
    if (_evictToFit(0) && !_closed) notifyListeners();
  }

  void release(int bytes) {
    if (bytes < 0 || bytes > _reserved) {
      throw ArgumentError.value(bytes, 'bytes');
    }
    _reserved -= bytes;
  }

  void record(
    RecentConversationKey key,
    RecentConversationSnapshot snapshot, {
    required bool live,
    required Object revision,
    required Object environment,
  }) {
    final bytes = snapshot.byteSize;
    if (_closed || bytes + _reserved > byteLimit) {
      snapshot.dispose();
      return;
    }
    _remove(key);
    _evictToFit(bytes);
    _entries[key] = (
      snapshot: snapshot,
      live: live,
      revision: revision,
      environment: environment,
    );
    _bytes += bytes;
    notifyListeners();
  }

  void retain(Set<RecentConversationKey> keys) {
    _neighborhood = Set.of(keys);
    for (final key in keys) {
      final entry = _entries.remove(key);
      if (entry != null) _entries[key] = entry;
    }
  }

  bool _evictToFit(int bytes) {
    var changed = false;
    while (_bytes + _reserved + bytes > byteLimit && _entries.isNotEmpty) {
      final victim = _entries.keys.firstWhere(
        (key) => !_neighborhood.contains(key),
        orElse: () => _entries.keys.first,
      );
      changed = _remove(victim) || changed;
    }
    return changed;
  }

  void invalidate(RecentConversationKey key) {
    if (_remove(key) && !_closed) notifyListeners();
  }

  bool _remove(RecentConversationKey key) {
    final entry = _entries.remove(key);
    if (entry == null) return false;
    _bytes -= entry.snapshot.byteSize;
    entry.snapshot.dispose();
    return true;
  }

  void clear() {
    _neighborhood = {};
    for (final key in _entries.keys.toList()) {
      _remove(key);
    }
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    clear();
    super.dispose();
  }
}
