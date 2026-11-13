enum AdministrationLogFile { agent, errors, gateway }

enum AdministrationLogLevel {
  all('All', null),
  debug('DEBUG', 'DEBUG'),
  info('INFO', 'INFO'),
  warning('WARNING', 'WARNING'),
  error('ERROR', 'ERROR');

  const AdministrationLogLevel(this.label, this.parameter);
  final String label;
  final String? parameter;
}

/// One submitted log query. Search text is sent exactly as submitted.
final class AdministrationLogsQuery {
  const AdministrationLogsQuery({
    required this.file,
    required this.level,
    required this.search,
  });
  final AdministrationLogFile file;
  final AdministrationLogLevel level;
  final String search;
  int get limit => 100;

  Map<String, String> get parameters => Map.unmodifiable({
    'file': file.name,
    'lines': '$limit',
    'level': ?level.parameter,
    if (search.isNotEmpty) 'search': search,
  });
}

/// Detached, validated observation of the exact submitted query.
final class AdministrationLogSnapshot {
  AdministrationLogSnapshot._(this.query, Iterable<String> lines)
    : lines = List.unmodifiable(lines);
  final AdministrationLogsQuery query;
  final List<String> lines;

  static AdministrationLogSnapshot decode(
    Map<String, dynamic> response,
    AdministrationLogsQuery query,
  ) {
    final lines = response['lines'];
    if (response['file'] != query.file.name ||
        lines is! List ||
        lines.length > query.limit ||
        lines.any((line) => line is! String)) {
      throw const FormatException('Invalid log response');
    }
    return AdministrationLogSnapshot._(query, lines.cast<String>());
  }
}

final class AdministrationLogsState {
  const AdministrationLogsState({
    required this.query,
    required this.snapshot,
    required this.loading,
    required this.error,
    required this.retryable,
  });
  final AdministrationLogsQuery query;
  final AdministrationLogSnapshot? snapshot;
  final bool loading;
  final String? error;
  final bool retryable;
  bool get canRecoverRead => !loading && retryable;
}
