import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/deleted_draft_cleanup.dart';

class _CleanupState {
  final receipts = <(String, String), DeletedDraftCleanupReceipt>{};
  final sizes = <(String, String), int>{};
  Future<void>? writing;
}

/// Durable receipts only; no transport or browser/composer mutation policy.
/// A per-preferences/host writer serializes instances sharing the same records.
class DeletedDraftCleanupStore {
  DeletedDraftCleanupStore(
    this._preferences, {
    required this.connectionId,
    required this.connectionIdentity,
  }) {
    if (connectionId.isEmpty || connectionIdentity.isEmpty) {
      throw ArgumentError('Verified cleanup owner identity is required');
    }
    final hosts = _states[_preferences] ??= {};
    _state = hosts.putIfAbsent(_prefix, _load);
  }

  static final _states = Expando<Map<String, _CleanupState>>();
  static const maximumReceipts = 1024;
  static const maximumBytes = 1024 * 1024;
  static const maximumRecordBytes = 256 * 1024;
  final SharedPreferences _preferences;
  final String connectionId;
  final String connectionIdentity;
  late final _CleanupState _state;
  String _component(String value) => base64Url.encode(utf8.encode(value));
  String get _prefix =>
      'deleted_draft_cleanup_v1.${_component(connectionId)}.${_component(connectionIdentity)}.';
  String _key(String profile, String session) =>
      '$_prefix${_component(profile)}.${_component(session)}';

  List<DeletedDraftCleanupReceipt> get receipts =>
      List.unmodifiable(_state.receipts.values);
  DeletedDraftCleanupReceipt? receipt(String profile, String session) =>
      _state.receipts[(profile, session)];
  bool blocks(String profile, String session) =>
      receipt(profile, session) != null;

  _CleanupState _load() {
    final state = _CleanupState();
    var total = 0;
    for (final key in _preferences.getKeys().where(
      (key) => key.startsWith(_prefix),
    )) {
      final encoded = _preferences.get(key);
      if (encoded is! String) {
        throw const FormatException('Invalid cleanup receipt storage');
      }
      final size = utf8.encode(encoded).length;
      if (size > maximumRecordBytes ||
          (total += size) > maximumBytes ||
          state.receipts.length >= maximumReceipts) {
        throw const FormatException(
          'Cleanup receipt storage exceeds its admission bounds',
        );
      }
      final record = jsonDecode(encoded);
      if (record is! Map ||
          record['schema'] != 1 ||
          record['connection_id'] != connectionId ||
          record['connection_identity'] != connectionIdentity ||
          record.keys.toSet().difference(const {
            'schema',
            'connection_id',
            'connection_identity',
            'profile',
            'session',
            'phase',
            'files',
          }).isNotEmpty ||
          record['profile'] is! String ||
          record['session'] is! String ||
          record['phase'] is! String ||
          record['files'] is! List ||
          !DeletedDraftCleanupPhase.values.any(
            (phase) => phase.name == record['phase'],
          )) {
        throw const FormatException('Invalid cleanup receipt');
      }
      final files = <DeletedDraftFile>[];
      for (final value in record['files'] as List) {
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Invalid cleanup file collection');
        }
        files.add(DeletedDraftFile.fromJson(value));
      }
      final receipt = DeletedDraftCleanupReceipt(
        profile: record['profile'] as String,
        session: record['session'] as String,
        phase: DeletedDraftCleanupPhase.values.singleWhere(
          (phase) => phase.name == record['phase'],
        ),
        files: files,
      );
      if (_key(receipt.profile, receipt.session) != key) {
        throw const FormatException('Cleanup receipt identity mismatch');
      }
      final identity = (receipt.profile, receipt.session);
      state.receipts[identity] = receipt;
      state.sizes[identity] = size;
    }
    return state;
  }

  Future<DeletedDraftCleanupReceipt> prepare({
    required String profile,
    required String session,
    required Iterable<DeletedDraftFile> files,
  }) {
    // Capture before queueing; mutable draft changes never rewrite this intent.
    final prepared = DeletedDraftCleanupReceipt(
      profile: profile,
      session: session,
      phase: DeletedDraftCleanupPhase.prepared,
      files: files,
    );
    return _ordered(() async {
      final existing = receipt(profile, session);
      if (existing != null) return existing;
      await _commit(prepared);
      return prepared;
    });
  }

  Future<DeletedDraftCleanupReceipt> acknowledge({
    required String profile,
    required String session,
    required Iterable<DeletedDraftFile> files,
  }) {
    final additions = List<DeletedDraftFile>.unmodifiable(files);
    return _ordered(() async {
      final previous = receipt(profile, session);
      if (previous == null) throw StateError('Deletion was not prepared');
      if (previous.phase == DeletedDraftCleanupPhase.completed) return previous;
      final acknowledged = previous.acknowledged(additions);
      await _commit(acknowledged);
      return acknowledged;
    });
  }

  Future<void> complete(String profile, String session) => _ordered(() async {
    final previous = receipt(profile, session);
    if (previous == null || !previous.confirmed) {
      throw StateError('Deletion is not confirmed; local work was kept');
    }
    if (previous.phase == DeletedDraftCleanupPhase.completed) return;
    await _commit(previous.completed());
  });

  /// Explicitly keep a freshly verified existing chat. The exact captured
  /// prepared receipt must still own the decision; confirmed tombstones never
  /// enter this path. Failed persistence retains quarantine and local work.
  Future<void> retirePrepared(DeletedDraftCleanupReceipt expected) => _ordered(
    () async {
      if (expected.confirmed ||
          !identical(receipt(expected.profile, expected.session), expected)) {
        throw StateError('Deletion state changed. Local work was kept.');
      }
      final key = _key(expected.profile, expected.session);
      final previous = _preferences.getString(key);
      if (previous == null) {
        throw StateError('Deletion recovery state is unavailable');
      }
      try {
        if (!await _preferences.remove(key)) {
          throw StateError('Could not save the choice to keep this chat');
        }
      } catch (_) {
        // SharedPreferences changes its cache before platform acknowledgement.
        // The durable prepared record and authoritative receipt must survive
        // a failed retirement. Do not unblock on either I/O outcome.
        try {
          await _preferences.setString(key, previous);
        } catch (_) {}
        rethrow;
      }
      final identity = (expected.profile, expected.session);
      _state.receipts.remove(identity);
      _state.sizes.remove(identity);
    },
  );

  Future<T> _ordered<T>(Future<T> Function() action) {
    final old = _state.writing;
    final operation = old == null
        ? Future<T>.sync(action)
        : old.then((_) => action());
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _state.writing = settled;
    unawaited(
      settled.then((_) {
        if (identical(_state.writing, settled)) _state.writing = null;
      }),
    );
    return operation;
  }

  Future<void> _commit(DeletedDraftCleanupReceipt receipt) async {
    final identity = (receipt.profile, receipt.session);
    final encoded = jsonEncode({
      'schema': 1,
      'connection_id': connectionId,
      'connection_identity': connectionIdentity,
      'profile': receipt.profile,
      'session': receipt.session,
      'phase': receipt.phase.name,
      'files': receipt.files.map((file) => file.toJson()).toList(),
    });
    final size = utf8.encode(encoded).length;
    final total =
        _state.sizes.values.fold(0, (sum, size) => sum + size) -
        (_state.sizes[identity] ?? 0) +
        size;
    if (size > maximumRecordBytes ||
        total > maximumBytes ||
        !_state.receipts.containsKey(identity) &&
            _state.receipts.length >= maximumReceipts) {
      throw StateError(
        'Local cleanup receipt storage is full. Local work was kept.',
      );
    }
    final key = _key(receipt.profile, receipt.session);
    final previous = _preferences.getString(key);
    try {
      if (!await _preferences.setString(key, encoded)) {
        throw StateError('Could not save deletion cleanup state');
      }
    } catch (_) {
      // Preferences changes its cache before platform acknowledgement. Restore
      // this key's previous cache value; a second I/O failure cannot erase the
      // confirmed in-memory receipt or hide the original write failure.
      try {
        if (previous == null) {
          await _preferences.remove(key);
        } else {
          await _preferences.setString(key, previous);
        }
      } catch (_) {}
      rethrow;
    }
    _state.receipts[identity] = receipt;
    _state.sizes[identity] = size;
  }
}
