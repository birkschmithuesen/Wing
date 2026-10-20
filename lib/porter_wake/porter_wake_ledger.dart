import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Guards against a second notification for the same notice id (contract §6.8).
/// Shared by the app engine and the headless push engine through preferences.
class PorterNoticeLedger {
  PorterNoticeLedger(this._prefs);

  static const key = 'porter_wake_seen_notices';
  static const _limit = 32;
  final SharedPreferences _prefs;
  Future<void> _writes = Future.value();

  Future<bool> claim(String noticeId) {
    final result = Completer<bool>();
    _writes = _writes.then((_) async {
      await _prefs.reload();
      final ids = _prefs.getStringList(key) ?? <String>[];
      if (ids.contains(noticeId)) return result.complete(false);
      final next = [...ids, noticeId];
      if (next.length > _limit) next.removeRange(0, next.length - _limit);
      await _prefs.setStringList(key, next);
      result.complete(true);
    }).catchError((Object error) {
      if (!result.isCompleted) result.completeError(error);
    });
    return result.future;
  }

  Future<void> release(String noticeId) {
    _writes = _writes.then((_) async {
      await _prefs.reload();
      final ids = _prefs.getStringList(key) ?? <String>[];
      await _prefs.setStringList(key, ids.where((id) => id != noticeId).toList());
    });
    return _writes;
  }
}
