import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bots.dart';

/// Device read receipts for exact authenticated instance/room message sequences.
/// Runtime/log cursors and non-message events never acknowledge an answer.
class BotGroupReadState extends ChangeNotifier {
  BotGroupReadState();
  SharedPreferences? _preferences;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  final _read = <String, int>{};
  bool _closed = false;
  static const _key = 'bots_group_read_sequences';

  /// Notification delivery borrows the same durable viewport receipt.
  static int savedSequence(SharedPreferences preferences, String groupKey) {
    final saved = preferences.getString(_key);
    if (saved == null) return 0;
    final value = (jsonDecode(saved) as Map<String, dynamic>)[groupKey];
    if (value == null) return 0;
    if (value is! int || value < 0) {
      throw const FormatException('Invalid group read receipt');
    }
    return value;
  }

  int sequence(BotGroup group) => _read[group.key] ?? 0;
  bool unread(BotGroup group) => group.lastAnswerSequence > sequence(group);
  Future<void> load() {
    if (_preferences != null || _closed) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    if (_closed) return;
    final saved = preferences.getString(_key);
    if (saved != null) {
      final values = jsonDecode(saved) as Map<String, dynamic>;
      for (final entry in values.entries) {
        if (entry.value is int && entry.value >= 0) {
          _read[entry.key] = entry.value as int;
        }
      }
    }
    _preferences = preferences;
    notifyListeners();
  }

  Future<void> acknowledge(BotGroup group, int sequence) {
    final result = _writes.catchError((Object _) {}).then((_) async {
      await load();
      if (_closed || sequence <= this.sequence(group)) return;
      final next = {..._read, group.key: sequence};
      if (!await _preferences!.setString(_key, jsonEncode(next))) {
        throw StateError('Group read receipt could not be saved');
      }
      if (_closed) return;
      _read.addAll(next);
      notifyListeners();
    });
    _writes = result;
    return result;
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
