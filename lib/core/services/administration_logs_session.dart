import 'package:flutter/foundation.dart';

import '../models/administration_logs.dart';
import 'administration_repository.dart';
import 'workspace_connection_failure.dart';

/// One connection-owned Logs route. New queries supersede earlier observations;
/// an already admitted read retains the connection until it settles.
class AdministrationLogsSession extends ChangeNotifier {
  AdministrationLogsSession(AdministrationRepository server)
    : _server = server {
    _server.retain();
  }
  final AdministrationRepository _server;
  String get scopeLabel => _server.connectionLabel;
  AdministrationLogsState _state = const AdministrationLogsState(
    query: AdministrationLogsQuery(
      file: AdministrationLogFile.agent,
      level: AdministrationLogLevel.all,
      search: '',
    ),
    snapshot: null,
    loading: true,
    error: null,
    retryable: false,
  );
  AdministrationLogsState get state => _state;
  int _generation = 0;
  bool _disposed = false;
  int _notificationDepth = 0;

  Future<void> refresh() => _read(_state.query);
  Future<void> selectFile(AdministrationLogFile file) => _read(
    AdministrationLogsQuery(
      file: file,
      level: _state.query.level,
      search: _state.query.search,
    ),
  );
  Future<void> selectLevel(AdministrationLogLevel level) => _read(
    AdministrationLogsQuery(
      file: _state.query.file,
      level: level,
      search: _state.query.search,
    ),
  );
  Future<void> search(String text) => _read(
    AdministrationLogsQuery(
      file: _state.query.file,
      level: _state.query.level,
      search: text,
    ),
  );

  void _publish(AdministrationLogsState state) {
    if (_disposed) return;
    _state = state;
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  Future<void> _read(AdministrationLogsQuery query) async {
    if (_disposed) return;
    final generation = ++_generation;
    _server.retain();
    bool active() => !_disposed && generation == _generation;
    try {
      _publish(
        AdministrationLogsState(
          query: query,
          snapshot: null,
          loading: true,
          error: null,
          retryable: false,
        ),
      );
      if (!active()) return;
      final response = await _server.read('logs', query.parameters);
      if (!active()) return;
      final snapshot = AdministrationLogSnapshot.decode(response, query);
      _publish(
        AdministrationLogsState(
          query: query,
          snapshot: snapshot,
          loading: false,
          error: null,
          retryable: false,
        ),
      );
    } catch (error) {
      if (!active()) return;
      _publish(
        AdministrationLogsState(
          query: query,
          snapshot: null,
          loading: false,
          error: error is FormatException
              ? 'The server returned an invalid response.'
              : administrationError(error),
          retryable: isTemporaryWorkspaceFailure(error),
        ),
      );
    } finally {
      _server.release();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    try {
      _server.release();
    } finally {
      if (_notificationDepth == 0) super.dispose();
    }
  }
}
