/// Hosted application accounts and full operation snapshots from stock Hermes.
/// Names identify catalog entries; connection IDs identify individual accounts.
final class HostedConnector {
  const HostedConnector(this.slug, this.name, this.description, this.category);
  final String slug, name, description, category;
  static List<HostedConnector> decode(Map<String, dynamic> response) =>
      List.unmodifiable(
        _rows(response, 'connectors').map(
          (row) => HostedConnector(
            _text(row, 'slug'),
            _text(row, 'name'),
            _text(row, 'description'),
            _text(row, 'category'),
          ),
        ),
      );
  bool matches(String query) => '$name $description $category $slug'
      .toLowerCase()
      .contains(query.toLowerCase());
}

final class HostedConnectorAccount {
  const HostedConnectorAccount({
    required this.id,
    required this.connector,
    required this.label,
    required this.alias,
    required this.status,
    required this.statusReason,
    required this.active,
    required this.disabled,
  });
  final String id, connector, label, status;
  final String? alias, statusReason;
  final bool active, disabled;
  String get title => alias?.isNotEmpty == true
      ? alias!
      : label.isEmpty
      ? 'Unnamed account'
      : label;
  String get statusLabel => disabled
      ? 'Replaced account'
      : active
      ? 'Connected'
      : switch (status) {
          'pending' => 'Authorization pending',
          'expired' => 'Authorization expired',
          'revoked' => 'Access revoked',
          'failed' => 'Connection failed',
          _ => 'Not connected',
        };
  static HostedConnectorAccount fromJson(Map row) => HostedConnectorAccount(
    id: _text(row, 'connection_id'),
    connector: _text(row, 'connector'),
    label: _text(row, 'label'),
    alias: _optionalText(row, 'alias'),
    status: _text(row, 'status'),
    statusReason: _optionalText(row, 'status_reason'),
    active: _boolean(row, 'active'),
    disabled: _boolean(row, 'disabled'),
  );
  static List<HostedConnectorAccount> decode(Map<String, dynamic> response) =>
      List.unmodifiable(_rows(response, 'accounts').map(fromJson));
}

/// Scrubbed display facts supplied by Hermes, never executable configuration.
final class HostedConnectionLaunch {
  HostedConnectionLaunch({
    required this.kind,
    required this.target,
    required Iterable<String> environmentNames,
    this.cwd,
  }) : environmentNames = List.unmodifiable(environmentNames);
  final String kind, target;
  final List<String> environmentNames;
  final String? cwd;
  String get label => kind == 'stdio' ? 'Runs on server' : 'Connects to';

  static HostedConnectionLaunch? parse(Object? value) {
    if (value == null) return null;
    if (value is! Map ||
        !{'remote', 'stdio'}.contains(value['kind']) ||
        value['target'] is! String ||
        (value['target'] as String).isEmpty ||
        (value['env'] != null &&
            (value['env'] is! List ||
                (value['env'] as List).any((name) => name is! String)))) {
      throw const FormatException('Invalid connector launch facts');
    }
    return HostedConnectionLaunch(
      kind: value['kind'] as String,
      target: value['target'] as String,
      environmentNames: (value['env'] as List?)?.cast<String>() ?? const [],
      cwd: _optionalText(value, 'cwd'),
    );
  }
}

final class HostedConnectionTarget {
  const HostedConnectionTarget({
    required this.name,
    required this.kind,
    required this.state,
    required this.detail,
    required this.alias,
    required this.connectUrl,
    this.launch,
  });
  final String name, kind, state;
  final String? detail, alias;
  final Uri? connectUrl;
  final HostedConnectionLaunch? launch;
  bool get connected => state == 'connected';
  bool get needsAuthorization =>
      {'connector', 'mcp'}.contains(kind) &&
      !connected &&
      connectUrl != null &&
      !{'failed', 'expired', 'skipped'}.contains(state);
  String get statusLabel => switch (state) {
    'connected' => 'Connected',
    'pending' => 'Waiting for connection',
    'initiated' => 'Authorization pending',
    'failed' => 'Connection failed',
    'expired' => 'Authorization expired',
    'skipped' => 'Skipped',
    'not_connected' => 'Not connected',
    _ => state,
  };
  static HostedConnectionTarget fromJson(Map row) {
    final url = _optionalText(row, 'connect_url');
    final uri = url == null ? null : Uri.tryParse(url);
    return HostedConnectionTarget(
      name: _text(row, 'name'),
      kind: _text(row, 'kind'),
      state: _text(row, 'state'),
      detail: _optionalText(row, 'detail'),
      alias: _optionalText(row, 'alias'),
      launch: HostedConnectionLaunch.parse(row['launch']),
      connectUrl:
          uri != null &&
              {'http', 'https'}.contains(uri.scheme) &&
              uri.host.isNotEmpty
          ? uri
          : null,
    );
  }
}

final class HostedConnectionOperation {
  HostedConnectionOperation({
    required this.id,
    required this.sequence,
    required this.settled,
    required this.deadline,
    required Iterable<HostedConnectionTarget> targets,
    required Iterable<String> suggested,
    required this.isDirectory,
    this.toolCallId,
  }) : targets = List.unmodifiable(targets),
       suggested = List.unmodifiable(suggested);
  final String id;
  final int sequence;
  final bool settled;
  final DateTime deadline;
  final List<HostedConnectionTarget> targets;
  final List<String> suggested;
  final String? toolCallId;
  final bool isDirectory;

  /// Status events deliberately omit the original tool and directory metadata.
  /// Only this operation's newer full status can replace its observed targets.
  HostedConnectionOperation applyStatus(Map<String, dynamic> row) {
    if (settled || row['op_id'] != id) return this;
    final next = HostedConnectionOperation.fromJson(row);
    if (next.sequence <= sequence) return this;
    return HostedConnectionOperation(
      id: id,
      sequence: next.sequence,
      settled: next.settled,
      deadline: next.deadline,
      targets: next.targets,
      suggested: suggested,
      isDirectory: isDirectory,
      toolCallId: toolCallId,
    );
  }

  static HostedConnectionOperation fromJson(Map row) {
    final seq = row['seq'], deadline = row['deadline_at'];
    if (seq is! int || seq < 0 || deadline is! num || !deadline.isFinite) {
      throw const FormatException('Invalid connector operation identity');
    }
    final display = row['display'];
    final suggested = display is Map ? display['suggested'] : const <String>[];
    if (suggested is! List || suggested.any((value) => value is! String)) {
      throw const FormatException('Invalid connector suggestions');
    }
    return HostedConnectionOperation(
      id: _text(row, 'op_id'),
      sequence: seq,
      settled: row['settled'] == true,
      deadline: DateTime.fromMillisecondsSinceEpoch((deadline * 1000).round()),
      targets: _rows(row, 'targets').map(HostedConnectionTarget.fromJson),
      suggested: suggested.cast<String>(),
      isDirectory: display is Map,
      toolCallId: _optionalText(row, 'tool_call_id'),
    );
  }
}

List<Map> _rows(Map response, String key) {
  final rows = response[key];
  if (rows is! List || rows.any((row) => row is! Map)) {
    throw FormatException('Invalid hosted connector $key');
  }
  return rows.cast<Map>();
}

String _text(Map row, String key) {
  final value = row[key];
  if (value is! String) throw FormatException('Invalid connector $key');
  return value;
}

String? _optionalText(Map row, String key) =>
    row[key] == null ? null : _text(row, key);
bool _boolean(Map row, String key) {
  final value = row[key];
  if (value is! bool) throw FormatException('Invalid connector $key');
  return value;
}

bool validHostedAccountAlias(String value) =>
    RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$').hasMatch(value);
