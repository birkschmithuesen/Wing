/// Authoritative membership only; a listed connector is not proof it connects.
final class ConnectorInventoryObservation {
  ConnectorInventoryObservation._(this.connectors, this.checkedAt);
  final Map<String, ProfileConnector> connectors;
  final DateTime checkedAt;
  Map<String, bool> get enabled => Map.unmodifiable({
    for (final entry in connectors.entries) entry.key: entry.value.enabled,
  });

  factory ConnectorInventoryObservation.decode(
    Map<String, dynamic> response,
    DateTime checkedAt,
  ) => ConnectorInventoryObservation._(
    Map.unmodifiable({
      for (final row in ProfileConnector.decodeList(response)) row.name: row,
    }),
    checkedAt,
  );

  /// Null means this inventory cannot retire targets from that observation.
  List<String>? remainingFailures(List<String> names, DateTime? observedAt) =>
      names.isEmpty || observedAt == null || checkedAt.isBefore(observedAt)
      ? null
      : List.unmodifiable(names.where((name) => enabled[name] == true));
}

enum ConnectorRuntimeStatus {
  connected('Connected'),
  disabled('Disabled'),
  connecting('Connecting'),
  failed('Connection failed'),
  lazy('Ready on first use'),
  configured('Configured; runtime not observed');

  const ConnectorRuntimeStatus(this.label);
  final String label;
}

/// Cached process state is not an explicit connection test or a durable health
/// ledger. A configured-only row does not prove the connector is offline.
final class ConnectorRuntime {
  const ConnectorRuntime({
    required this.name,
    required this.status,
    required this.tools,
    required this.needsAuth,
    required this.plugin,
  });
  final String name;
  final ConnectorRuntimeStatus status;
  final int tools;
  final bool needsAuth;
  final String? plugin;
  bool get needsAttention =>
      needsAuth || status == ConnectorRuntimeStatus.failed;
  bool get recovered =>
      !needsAuth &&
      {
        ConnectorRuntimeStatus.connected,
        ConnectorRuntimeStatus.lazy,
        ConnectorRuntimeStatus.disabled,
      }.contains(status);
  String get label => needsAuth ? 'Sign in again' : status.label;
}

final class ConnectorRuntimeObservation {
  ConnectorRuntimeObservation._(
    this.rows,
    this.serverCheckedAt,
    this.receivedAt,
  );
  final Map<String, ConnectorRuntime> rows;
  final DateTime serverCheckedAt, receivedAt;

  factory ConnectorRuntimeObservation.decode(
    Map<String, dynamic> response,
    DateTime receivedAt,
  ) {
    final raw = response['servers'], at = response['checked_at'];
    if (raw is! List || at is! int || at < 0) {
      throw const FormatException('Invalid cached connector status');
    }
    final rows = <String, ConnectorRuntime>{};
    for (final row in raw) {
      if (row is! Map ||
          row['name'] is! String ||
          (row['name'] as String).isEmpty ||
          row['transport'] is! String ||
          row['tools'] is! int ||
          (row['tools'] as int) < 0 ||
          row['connected'] is! bool ||
          row['disabled'] is! bool ||
          row['needs_auth'] is! bool ||
          !{'config', 'plugin'}.contains(row['source']) ||
          row['source'] == 'plugin' &&
              (row['plugin'] is! String || (row['plugin'] as String).isEmpty) ||
          row['source'] == 'config' && row['plugin'] != null ||
          rows.containsKey(row['name'])) {
        throw const FormatException('Invalid cached connector row');
      }
      final status = ConnectorRuntimeStatus.values
          .where((status) => status.name == row['status'])
          .firstOrNull;
      if (status == null ||
          row['connected'] != (status == ConnectorRuntimeStatus.connected) ||
          row['disabled'] != (status == ConnectorRuntimeStatus.disabled)) {
        throw const FormatException('Invalid cached connector state');
      }
      final name = row['name'] as String;
      rows[name] = ConnectorRuntime(
        name: name,
        status: status,
        tools: row['tools'] as int,
        needsAuth: row['needs_auth'] as bool,
        plugin: row['plugin'] as String?,
      );
    }
    return ConnectorRuntimeObservation._(
      Map.unmodifiable(rows),
      DateTime.fromMillisecondsSinceEpoch(at),
      receivedAt,
    );
  }

  Map<String, ConnectorRuntime> issuesFor(
    Iterable<ProfileConnector> connectors,
  ) => Map.unmodifiable({
    for (final connector in connectors)
      if (connector.enabled)
        if (forConnector(connector) case final runtime?
            when runtime.needsAttention)
          connector.name: runtime,
  });

  static String describeIssues(Iterable<ConnectorRuntime> issues) {
    final values = issues.toList();
    final auth = values.where((row) => row.needsAuth).length;
    final failed = values.length - auth;
    return [
      if (auth > 0) '$auth ${auth == 1 ? 'needs' : 'need'} sign-in',
      if (failed > 0)
        '$failed runtime ${failed == 1 ? 'connection failed' : 'connections failed'}',
    ].join(' · ');
  }

  ConnectorRuntime? forConnector(ProfileConnector? connector) {
    if (connector == null) return null;
    final row = rows[connector.name];
    return row?.plugin == connector.plugin ? row : null;
  }
}

/// Current-stock connector observations. Credentials/configuration never escape.
final class ProfileConnector {
  const ProfileConnector({
    required this.name,
    required this.transport,
    required this.authentication,
    required this.enabled,
    required this.plugin,
  });
  final String name, transport;
  final String? authentication, plugin;
  final bool enabled;
  bool get canConfigure => plugin == null;
  bool get canSignIn =>
      canConfigure && authentication == 'oauth' && transport == 'http';

  static ProfileConnector decode(Map row) {
    final name = row['name'], transport = row['transport'], auth = row['auth'];
    final enabled = row['enabled'],
        source = row['source'],
        plugin = row['plugin'];
    if (!row.keys.toSet().containsAll({
          'name',
          'transport',
          'auth',
          'enabled',
          'source',
          'plugin',
        }) ||
        name is! String ||
        name.isEmpty ||
        transport is! String ||
        !{'http', 'stdio', 'unknown'}.contains(transport) ||
        auth != null && auth is! String ||
        enabled is! bool ||
        !{'config', 'plugin'}.contains(source) ||
        source == 'plugin' && (plugin is! String || plugin.isEmpty) ||
        source == 'config' && plugin != null) {
      throw const FormatException('Invalid connector observation');
    }
    return ProfileConnector(
      name: name,
      transport: transport,
      authentication: auth as String?,
      enabled: enabled,
      plugin: plugin as String?,
    );
  }

  static List<ProfileConnector> decodeList(Map<String, dynamic> response) {
    final rows = response['servers'];
    if (rows is! List) throw const FormatException('Invalid connector list');
    final names = <String>{};
    return List.unmodifiable([
      for (final row in rows)
        if (row is Map)
          _unique(decode(row), names)
        else
          throw const FormatException('Invalid connector row'),
    ]);
  }

  static ProfileConnector _unique(ProfileConnector row, Set<String> names) {
    if (!names.add(row.name)) {
      throw const FormatException('Duplicate connector identity');
    }
    return row;
  }
}

final class ConnectorTool {
  const ConnectorTool(this.name, this.description);
  final String name, description;
}

final class ConnectorProbe {
  ConnectorProbe({
    required Iterable<ConnectorTool> tools,
    required this.failure,
  }) : tools = List.unmodifiable(tools);
  final List<ConnectorTool> tools;
  final String? failure;
  bool get connected => failure == null;
  static ConnectorProbe decode(
    Map<String, dynamic> result,
    String Function(Object?) failureText,
  ) {
    if (result['ok'] is! bool ||
        result['tools'] is! List ||
        result['ok'] == false &&
            (result['error'] is! String ||
                (result['tools'] as List).isNotEmpty)) {
      throw const FormatException('Invalid connector test result');
    }
    final tools = <ConnectorTool>[];
    final names = <String>{};
    for (final row in result['tools'] as List) {
      if (row is! Map ||
          row['name'] is! String ||
          (row['name'] as String).isEmpty ||
          row['description'] is! String ||
          !names.add(row['name'] as String)) {
        throw const FormatException('Invalid connector tool');
      }
      tools.add(
        ConnectorTool(row['name'] as String, row['description'] as String),
      );
    }
    return ConnectorProbe(
      tools: tools,
      failure: result['ok'] == true ? null : failureText(result['error']),
    );
  }
}

enum ConnectorFailureScope { read, command }

enum ConnectorPhase { idle, reading, confirming, saving, testing, reconnecting }

final class ProfileConnectorsState {
  ProfileConnectorsState({
    required Iterable<ProfileConnector> connectors,
    required this.checked,
    required this.verified,
    required this.phase,
    required this.probe,
    required this.reviewRequired,
    required this.error,
    required this.notice,
    required this.failureScope,
    required this.runtime,
    required this.runtimeError,
  }) : connectors = List.unmodifiable(connectors);
  final List<ProfileConnector> connectors;
  final bool checked, verified, reviewRequired;
  final ConnectorPhase phase;
  final ConnectorProbe? probe;
  final String? error, notice;
  final ConnectorFailureScope? failureScope;
  final ConnectorRuntimeObservation? runtime;
  final String? runtimeError;
  bool get busy => phase != ConnectorPhase.idle;
  bool get canMutate => !busy && verified && !reviewRequired;
}
