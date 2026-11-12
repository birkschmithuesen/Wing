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

enum HostedConnectionStep { signIn, enable, install, retry, working }

final class HostedConnectionField {
  const HostedConnectionField({
    required this.name,
    required this.required,
    required this.secret,
    required this.defaultValue,
    this.prompt,
  });

  final String name, defaultValue;
  final bool required, secret;
  final String? prompt;

  factory HostedConnectionField.fromJson(Map row) => HostedConnectionField(
    name: _text(row, 'name'),
    required: _boolean(row, 'required'),
    secret: _boolean(row, 'secret'),
    defaultValue: _text(row, 'default'),
    prompt: _optionalText(row, 'prompt'),
  );
}

final class HostedConnectionTarget {
  HostedConnectionTarget({
    required this.name,
    required this.kind,
    required this.action,
    required this.state,
    required this.detail,
    required this.alias,
    required this.connectUrl,
    this.connectionId,
    this.instructions,
    this.discoveryError,
    this.launch,
    Iterable<HostedConnectionField> fields = const [],
  }) : fields = List.unmodifiable(fields);

  final String name, kind, action, state;
  final String? detail, alias, connectionId, instructions, discoveryError;
  final Uri? connectUrl;
  final HostedConnectionLaunch? launch;
  final List<HostedConnectionField> fields;
  bool get connected => state == 'connected';
  bool get canSkip => switch (kind) {
    'connector' => const {
      'pending',
      'initiated',
      'failed',
      'expired',
    }.contains(state),
    'mcp' => const {'pending', 'initiated', 'failed'}.contains(state),
    _ => false,
  };

  HostedConnectionStep? get step => switch ((kind, state)) {
    ('connector', 'failed' || 'expired') ||
    ('mcp', 'failed' || 'expired') => HostedConnectionStep.retry,
    ('mcp', 'pending') when action == 'enable' => HostedConnectionStep.enable,
    ('mcp', 'pending') when action == 'install' => HostedConnectionStep.install,
    ('mcp', 'initiated') || ('connector', 'pending' || 'initiated')
        when connectUrl != null =>
      HostedConnectionStep.signIn,
    ('mcp', 'initiated') => HostedConnectionStep.working,
    _ => null,
  };
  bool get needsAuthorization => step == HostedConnectionStep.signIn;
  bool hasRequiredCredentials(Map<String, String> values) => fields.every(
    (field) => !field.required || values[field.name]?.isNotEmpty == true,
  );
  String get title => alias == null ? name : '$name · $alias';
  String get statusLabel => switch (step) {
    HostedConnectionStep.enable => 'Approval required to enable',
    HostedConnectionStep.install => 'Approval required to install',
    HostedConnectionStep.signIn => 'Browser sign-in ready',
    HostedConnectionStep.working => switch (action) {
      'enable' => 'Enabling…',
      'install' => 'Installing…',
      _ => 'Preparing browser sign-in…',
    },
    _ => switch (state) {
      'connected' when discoveryError?.isNotEmpty == true =>
        'Connected · tools unavailable',
      'connected' when kind == 'mcp' && action == 'enable' => 'Enabled',
      'connected' when kind == 'mcp' && action == 'install' => 'Installed',
      'connected' => 'Connected',
      'pending' => 'Waiting for connection',
      'initiated' => 'Authorization pending',
      'failed' => 'Connection failed',
      'expired' => 'Authorization expired',
      'skipped' => 'Skipped',
      'not_connected' => 'Not connected',
      _ => state,
    },
  };
  static HostedConnectionTarget fromJson(Map row) {
    final url = _optionalText(row, 'connect_url');
    final uri = url == null ? null : Uri.tryParse(url);
    return HostedConnectionTarget(
      name: _text(row, 'name'),
      kind: _text(row, 'kind'),
      action: _text(row, 'action'),
      state: _text(row, 'state'),
      detail: _optionalText(row, 'detail'),
      alias: _optionalText(row, 'alias'),
      connectionId: _optionalText(row, 'connection_id'),
      instructions: _optionalText(row, 'instructions'),
      discoveryError: _optionalText(row, 'discovery_error'),
      launch: HostedConnectionLaunch.parse(row['launch']),
      fields: row['required_env'] == null
          ? const []
          : _rows(row, 'required_env').map(HostedConnectionField.fromJson),
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
