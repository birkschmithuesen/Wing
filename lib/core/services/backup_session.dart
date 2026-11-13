import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/config_backup_operation.dart';
import 'config_backup.dart';
import 'config_backup_io.dart';
import 'config_backup_service.dart';

/// Opaque admission to the export choice sheet. A different session, canceled
/// attempt or already completed attempt cannot use this identity.
class BackupExportAttempt {
  BackupExportAttempt._();
}

/// The selected file remains private to the session, never in passive UI state.
class BackupImportOffer {
  BackupImportOffer._();
}

class BackupSessionState {
  const BackupSessionState({
    required this.busy,
    required this.notice,
    required this.error,
    required this.restoreResult,
  });

  final bool busy;
  final String? notice;
  final String? error;
  final ConfigImportResult? restoreResult;
}

/// One bounded local backup workflow. Configuration commits stay in their
/// durable owners; routes receive only passive outcomes and opaque choices.
class BackupSession {
  BackupSession({required this._configuration, required this._io});

  final ConfigBackupService _configuration;
  final ConfigBackupIo _io;
  final _presentation = ValueNotifier<BackupSessionState>(
    const BackupSessionState(
      busy: false,
      notice: null,
      error: null,
      restoreResult: null,
    ),
  );
  Object? _active;
  Object? _executing;
  String? _importContents;
  bool _closed = false;
  bool _publishing = false;

  ValueListenable<BackupSessionState> get presentation => _presentation;

  bool _owns(Object attempt) => !_closed && identical(_active, attempt);

  void _publish({
    String? notice,
    String? error,
    ConfigImportResult? restoreResult,
  }) {
    if (_closed) return;
    _publishing = true;
    try {
      _presentation.value = BackupSessionState(
        busy: _active != null,
        notice: notice,
        error: error,
        restoreResult: restoreResult,
      );
    } finally {
      _publishing = false;
    }
  }

  BackupExportAttempt? beginExport() {
    if (_closed || _active != null) return null;
    final attempt = BackupExportAttempt._();
    _active = attempt;
    _publish();
    return _owns(attempt) ? attempt : null;
  }

  Future<BackupImportOffer?> prepareImport() async {
    if (_closed || _active != null) return null;
    final offer = BackupImportOffer._();
    _active = offer;
    _publish();
    if (!_owns(offer)) return null;
    _executing = offer;
    try {
      final contents = await _io.pickBackupFile();
      if (!_owns(offer)) return null;
      if (contents == null) {
        _finish(offer);
        return null;
      }
      ConfigBackupLimits.checkText(contents);
      _importContents = contents;
      return offer;
    } catch (error) {
      _finish(
        offer,
        error: _safeError(error, 'The backup could not be opened.'),
      );
      return null;
    } finally {
      if (identical(_executing, offer)) _executing = null;
    }
  }

  bool cancel(Object attempt) {
    if (!_owns(attempt) || identical(_executing, attempt)) return false;
    _active = null;
    _importContents = null;
    _publish();
    return true;
  }

  Future<String?> export(
    BackupExportAttempt attempt,
    BackupExportIntent intent,
  ) async {
    if (!_owns(attempt) || _executing != null) return null;
    _executing = attempt;
    try {
      final version = await _io.appVersion();
      if (!_owns(attempt)) return null;
      final backup = await _configuration.export(appVersion: version);
      if (!_owns(attempt)) return null;
      final contents = await ConfigBackupCodec.encode(
        backup,
        passphrase: intent.passphrase,
      );
      if (!_owns(attempt)) return null;
      final destination = await _io.deliverExport(
        contents,
        canDispatch: () => _owns(attempt),
      );
      if (!_owns(attempt)) return null;
      _finish(
        attempt,
        notice: destination == null ? null : 'Backup exported — $destination',
      );
      return destination;
    } catch (error) {
      _finish(
        attempt,
        error: _safeError(error, 'The backup could not be exported.'),
      );
      return null;
    } finally {
      if (identical(_executing, attempt)) _executing = null;
    }
  }

  Future<ConfigImportResult?> restore(
    BackupImportOffer offer,
    BackupImportIntent intent,
  ) async {
    if (!_owns(offer) || _executing != null || _importContents == null) {
      return null;
    }
    _executing = offer;
    final contents = _importContents!;
    _importContents = null;
    try {
      final backup = await ConfigBackupCodec.decode(
        contents,
        passphrase: intent.passphrase,
      );
      if (!_owns(offer)) return null;
      final result = await _configuration.import(
        backup,
        mode: intent.mode,
        canCommit: () => _owns(offer),
      );
      // An admitted durable transaction settles after close, but a closed
      // route receives no new publication or success callback.
      if (!_owns(offer)) return null;
      _finish(
        offer,
        notice: result.complete ? result.summary : null,
        error: result.complete ? null : result.summary,
        restoreResult: result,
      );
      return result;
    } catch (error) {
      _finish(
        offer,
        error: _safeError(error, 'The backup could not be restored.'),
      );
      return null;
    } finally {
      if (identical(_executing, offer)) _executing = null;
    }
  }

  void _finish(
    Object attempt, {
    String? notice,
    String? error,
    ConfigImportResult? restoreResult,
  }) {
    if (!_owns(attempt)) return;
    _active = null;
    if (identical(_executing, attempt)) _executing = null;
    _importContents = null;
    _publish(notice: notice, error: error, restoreResult: restoreResult);
  }

  String _safeError(Object error, String fallback) => switch (error) {
    ConfigBackupException() => error.message,
    BackupChoiceException() => error.message,
    _ => fallback,
  };

  void close() {
    if (_closed) return;
    _closed = true;
    _active = null;
    _importContents = null;
    // A callback may close the route while notification is in progress.
    if (_publishing) {
      scheduleMicrotask(_presentation.dispose);
    } else {
      _presentation.dispose();
    }
  }
}
