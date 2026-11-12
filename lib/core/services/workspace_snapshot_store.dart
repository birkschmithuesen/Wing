import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reading_snapshot_message.dart';

/// Bounded reading snapshots, partitioned by the verified credential identity.
/// Runtime state, approvals, credentials and pending writes are never restored
/// from this store. Hermes remains authoritative on every reconnection.
class WorkspaceSnapshotStore {
  final SharedPreferences preferences;
  final String identity;
  Future<void>? _writeTail;

  WorkspaceSnapshotStore(this.preferences, this.identity);

  String get _key => 'workspace_reading_v1_$identity';

  String _toolDurationsKey(String profile, String sessionId) =>
      'workspace_tool_durations_v1_${identity}_${base64Url.encode(utf8.encode(jsonEncode([profile, sessionId])))}';

  /// Small timing records survive transcript and recent-chat cache pruning.
  /// They contain no result text, input, runtime state or execution authority.
  List<Map<String, dynamic>> readToolDurations(
    String profile,
    String sessionId,
  ) {
    final encoded = preferences.getString(
      _toolDurationsKey(profile, sessionId),
    );
    if (encoded == null) return const [];
    try {
      final rows = jsonDecode(encoded);
      if (rows is! List) return const [];
      return [
        for (final row in rows.whereType<Map>()) Map<String, dynamic>.from(row),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> writeToolDurations(
    String profile,
    String sessionId,
    List<Map<String, dynamic>> rows,
  ) => _enqueue(() async {
    final encoded = _isSmallSnapshot(rows)
        ? jsonEncode(rows)
        : await compute(_encodeToolDurations, rows);
    if (!await preferences.setString(
      _toolDurationsKey(profile, sessionId),
      encoded,
    )) {
      throw StateError('Tool timings could not be stored.');
    }
  });

  Future<void> deleteToolDurations(String profile, String sessionId) =>
      _enqueue(() async {
        if (!await preferences.remove(_toolDurationsKey(profile, sessionId))) {
          throw StateError('Tool timings could not be removed.');
        }
      });

  Map<String, dynamic> read() {
    try {
      final snapshot = Map<String, dynamic>.from(
        jsonDecode(preferences.getString(_key) ?? '{}') as Map,
      );
      for (final profile
          in (snapshot['profiles'] as List? ?? []).whereType<Map>()) {
        for (final chat in (profile['chats'] as List? ?? []).whereType<Map>()) {
          for (final message
              in (chat['messages'] as List? ?? []).whereType<Map>()) {
            if (message['submitted_attachments'] is List) {
              message['submitted_attachments'] = readingSnapshotAttachments(
                message['submitted_attachments'],
              );
            }
          }
        }
      }
      return snapshot;
    } catch (_) {
      return {};
    }
  }

  Future<void> write(Map<String, dynamic> snapshot) {
    Future<void> save() async {
      // Spawning an isolate costs more than encoding a small snapshot. Bound
      // this cheap size walk too, so large histories never serialize on the UI
      // isolate. Strings are measured without visiting their characters.
      final encoded = _isSmallSnapshot(snapshot)
          ? _encodeSnapshot(snapshot)
          : await compute(_encodeSnapshot, snapshot);
      await preferences.setString(_key, encoded);
    }

    return _enqueue(save);
  }

  Future<void> _enqueue(Future<void> Function() save) {
    // A newer snapshot or timing index cannot overtake an older encode.
    final writing = _writeTail == null
        ? save()
        : _writeTail!.then((_) => save());
    _writeTail = writing.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return writing;
  }
}

String _encodeToolDurations(List<Map<String, dynamic>> rows) =>
    jsonEncode(rows);

bool _isSmallSnapshot(Object? value) {
  var budget = 32 * 1024;
  bool visit(Object? value) {
    budget -= 16;
    if (budget < 0) return false;
    if (value is String) {
      budget -= value.length * 3;
    } else if (value is List) {
      for (final child in value) {
        if (!visit(child)) return false;
      }
    } else if (value is Map) {
      for (final entry in value.entries) {
        if (!visit(entry.key) || !visit(entry.value)) return false;
      }
    }
    return budget >= 0;
  }

  return visit(value);
}

String _encodeSnapshot(Map<String, dynamic> snapshot) {
  // Apply the per-message limit at the encoding boundary, after large inputs
  // have moved to the worker. Copy the containers so the small synchronous path
  // also leaves the caller's history untouched.
  snapshot = {
    ...snapshot,
    if (snapshot['profiles'] is List)
      'profiles': [
        for (final profile in snapshot['profiles'] as List)
          if (profile is Map && profile['chats'] is List)
            {
              ...profile,
              'chats': [
                for (final chat in profile['chats'] as List)
                  if (chat is Map && chat['messages'] is List)
                    {
                      ...chat,
                      'messages': [
                        for (final row in chat['messages'] as List)
                          if (row is Map)
                            if (projectReadingSnapshotMessage(row)
                                case final projected
                                when jsonEncode(projected).length < 32768)
                              projected,
                      ],
                    }
                  else
                    chat,
              ],
            }
          else
            profile,
      ],
  };
  const byteLimit = 2 * 1024 * 1024;
  final encoded = jsonEncode(snapshot);
  var bytes = utf8.encode(encoded).length;
  if (bytes <= byteLimit) return encoded;

  // Work on a private copy only when pruning is needed. Measure each candidate
  // once, then remeasure only the list being shortened. Encoding inside a sort
  // comparator repeatedly walked the entire history on every pruning pass.
  final bounded = jsonDecode(encoded) as Map<String, dynamic>;
  final profiles = bounded['profiles'] as List? ?? [];
  final lists = <_SnapshotRows>[
    for (final profile in profiles.whereType<Map>()) ...[
      for (final chat in (profile['chats'] as List? ?? []).whereType<Map>())
        if (chat['messages'] is List && (chat['messages'] as List).isNotEmpty)
          _SnapshotRows(chat['messages'] as List),
      if (profile['sessions'] is List &&
          (profile['sessions'] as List).isNotEmpty)
        _SnapshotRows(profile['sessions'] as List),
      if (profile['projects'] is List &&
          (profile['projects'] as List).isNotEmpty)
        _SnapshotRows(profile['projects'] as List),
    ],
  ];
  while (bytes > byteLimit) {
    lists.sort((a, b) => b.characters.compareTo(a.characters));
    if (lists.isNotEmpty) {
      final candidate = lists.first;
      final previousBytes = candidate.bytes;
      candidate.rows.removeRange(0, (candidate.rows.length / 2).ceil());
      candidate.measure();
      bytes -= previousBytes - candidate.bytes;
      if (candidate.rows.isEmpty) lists.removeAt(0);
    } else {
      if (profiles.isNotEmpty) {
        profiles.removeLast();
      } else {
        bounded.clear();
      }
      bytes = utf8.encode(jsonEncode(bounded)).length;
    }
  }
  return jsonEncode(bounded);
}

class _SnapshotRows {
  final List rows;
  late int characters;
  late int bytes;

  _SnapshotRows(this.rows) {
    measure();
  }

  void measure() {
    final encoded = jsonEncode(rows);
    characters = encoded.length;
    bytes = utf8.encode(encoded).length;
  }
}
