/// Authoritative membership only; a listed connector is not proof it connects.
final class ConnectorInventoryObservation {
  ConnectorInventoryObservation._(this.enabled, this.checkedAt);
  final Map<String, bool> enabled;
  final DateTime checkedAt;

  factory ConnectorInventoryObservation.decode(
    Map<String, dynamic> response,
    DateTime checkedAt,
  ) {
    final rows = response['servers'];
    if (rows is! List) throw const FormatException('Invalid connector list');
    final enabled = <String, bool>{};
    for (final row in rows) {
      if (row is! Map ||
          row['name'] is! String ||
          (row['name'] as String).isEmpty ||
          row['enabled'] is! bool ||
          enabled.containsKey(row['name'])) {
        throw const FormatException('Invalid connector membership');
      }
      enabled[row['name'] as String] = row['enabled'] as bool;
    }
    return ConnectorInventoryObservation._(
      Map.unmodifiable(enabled),
      checkedAt,
    );
  }

  /// Null means this inventory cannot retire targets from that observation.
  List<String>? remainingFailures(List<String> names, DateTime? observedAt) =>
      names.isEmpty || observedAt == null || checkedAt.isBefore(observedAt)
      ? null
      : List.unmodifiable(names.where((name) => enabled[name] == true));
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
  }) : connectors = List.unmodifiable(connectors);
  final List<ProfileConnector> connectors;
  final bool checked, verified, reviewRequired;
  final ConnectorPhase phase;
  final ConnectorProbe? probe;
  final String? error, notice;
  final ConnectorFailureScope? failureScope;
  bool get busy => phase != ConnectorPhase.idle;
  bool get canMutate => !busy && verified && !reviewRequired;
}
