// Named transport seams keep request functions injectable.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import '../models/session_visibility.dart';
import '../models/hermes_profile.dart';
import '../models/answer_versions.dart';
import 'connection_manager.dart';
import 'profiles_repository.dart';
import 'ws_client.dart';
import 'server_connection_status.dart';
import 'workspace_connection_failure.dart';
import 'wing_session_source.dart';

typedef ScopedGet =
    Future<Map<String, dynamic>> Function(
      String endpoint,
      Map<String, String> query,
    );
typedef ScopedRpc =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

typedef ScopedPatch =
    Future<Map<String, dynamic>> Function(
      String endpoint,
      Map<String, dynamic> body,
    );

typedef ScopedPost = ScopedPatch;
typedef ScopedDelete =
    Future<void> Function(String endpoint, Map<String, String> query);

/// The REST page may include extra pinned rows outside its offset window.
class ProfileSessionPage {
  final List<Map<String, dynamic>> rows;
  final int offset;
  final int limit;
  final int total;
  const ProfileSessionPage({
    required this.rows,
    required this.offset,
    required this.limit,
    required this.total,
  });
  int? get nextOffset => offset + limit < total ? offset + limit : null;
}

class ProfileHistoryPage {
  final String sessionId;
  final List<Map<String, dynamic>> rows;
  final int offset;
  final int limit;
  final bool isComplete;
  const ProfileHistoryPage(
    this.sessionId,
    this.rows,
    this.offset,
    this.limit, {
    this.isComplete = false,
  });
  int? get nextOffset =>
      !isComplete && rows.length == limit ? offset + rows.length : null;
}

class ProjectFolderSuggestion {
  final String path;
  final String label;

  const ProjectFolderSuggestion({required this.path, required this.label});
}

DashboardClient _dashboardFor(SavedConnection connection) => DashboardClient(
  host: connection.host,
  port: connection.dashboardPort,
  useHttps: connection.useHttps,
  pathPrefix: connection.dashboardPrefix ?? '',
  proxied: connection.dashboardProxied,
  username: connection.dashboardUsername,
  password: connection.dashboardPassword,
  dashboardOAuth: connection.dashboardOAuth,
  requiresOAuth: connection.isCloud,
  gatewayHeaders: connection.gatewayHeaders,
);

/// Authentication and HTTP pooling belong to one saved connection, not to each
/// profile or short-lived project reader. Gateways still own separate sockets.
class ProfileGatewayConnection {
  ProfileGatewayConnection(this.connection);
  final SavedConnection connection;
  late final DashboardClient _dashboard = _dashboardFor(connection);
  bool _closed = false;

  ProfileGateway create(WorkspaceScope scope) {
    if (_closed) throw StateError('Connection is closed');
    return ProfileGateway._forDashboard(
      connection,
      scope,
      _dashboard,
      ownsDashboard: false,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _dashboard.close();
  }
}

/// The stock modern Hermes contract. All profile-owned traffic passes through
/// this immutable scope. There is no unscoped or experimental-recovery fallback.
class ProfileGateway {
  final WorkspaceScope scope;
  final ScopedGet _getRequest;
  final ScopedRpc _rpcRequest;
  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      return await _rpcRequest(method, params);
    } catch (failure) {
      if (isTemporaryWorkspaceFailure(failure)) {
        disconnect();
        _liveChanged(false);
        onConnectionChanged?.call(false);
      }
      rethrow;
    }
  }

  final ScopedPatch? _patch;
  final ScopedPost? _post;
  final ScopedPost? _put;
  final ScopedDelete? _delete;
  final Future<void> Function() _connect;
  final void Function() _close;
  final void Function() disconnect;
  final Future<ProfileDiscovery> Function() _discover;
  ServerConnectionStatus? connectionStatus;
  // Administration RPC sockets do not carry chat updates and are not recovered
  // by the workspace. Their lifetime must not determine live chat availability.
  bool reportsLiveChat = true;

  /// Set from `gateway.ready` on every socket open (true and false, so a
  /// reconnect to an older gateway resets it).
  bool wingSourceAdvertised = false;

  /// The session `source` this gateway accepts from Wing.
  String get sessionSource =>
      wingSourceAdvertised ? wingSessionSource : desktopSessionSource;
  void _liveChanged(bool connected) {
    if (reportsLiveChat) {
      connectionStatus?.liveChanged(scope.profileName, connected);
    }
  }

  Future<Map<String, dynamic>> _get(
    String endpoint,
    Map<String, String> query,
  ) => connectionStatus == null
      ? _getRequest(endpoint, query)
      : connectionStatus!.observeAccess(() => _getRequest(endpoint, query));
  Future<ProfileDiscovery> discover() => connectionStatus == null
      ? _discover()
      : connectionStatus!.observeAccess(_discover);
  StreamCallback? onEvent;
  ConnectionCallback? onConnectionChanged;

  ProfileGateway({
    required this.scope,
    required ScopedGet get,
    required ScopedRpc rpc,
    ScopedPatch? patch,
    ScopedPost? post,
    ScopedPost? put,
    ScopedDelete? delete,
    required Future<ProfileDiscovery> Function() discover,
    Future<void> Function()? connect,
    void Function()? close,
    void Function()? disconnect,
  }) : _getRequest = get,
       _discover = discover,
       _rpcRequest = rpc,
       _patch = patch,
       _post = post,
       _put = put,
       _delete = delete,
       _connect = connect ?? _nothing,
       _close = close ?? _noop,
       disconnect = disconnect ?? _noop;

  static Future<void> _nothing() async {}
  static void _noop() {}

  factory ProfileGateway.forConnection(
    SavedConnection connection,
    WorkspaceScope scope,
  ) {
    if (scope.connectionId != connection.id) {
      throw ArgumentError('Connection does not own this workspace');
    }
    return ProfileGateway._forDashboard(
      connection,
      scope,
      _dashboardFor(connection),
      ownsDashboard: true,
    );
  }

  factory ProfileGateway._forDashboard(
    SavedConnection connection,
    WorkspaceScope scope,
    DashboardClient dashboard, {
    required bool ownsDashboard,
  }) {
    if (scope.connectionId != connection.id) {
      throw ArgumentError('Connection does not own this workspace');
    }
    WsClient? socket;
    WsClient? openingSocket;
    var closed = false;
    var connected = false;
    Future<void>? connecting;
    late final ProfileGateway gateway;
    Future<void> open() async {
      final credentials =
          await (gateway.connectionStatus?.observeAccess(
                () => dashboard.gatewayCredentials().timeout(
                  const Duration(seconds: 20),
                ),
              ) ??
              dashboard.gatewayCredentials().timeout(
                const Duration(seconds: 20),
              ));
      if (closed) throw StateError('Gateway is closed');
      final candidate = WsClient(
        connection.desktopGatewayUrl ?? dashboard.baseUrl,
        token: credentials.token,
        ticket: credentials.ticket,
        gatewayHeaders: connection.gatewayHeaders,
      );
      openingSocket = candidate;
      candidate.onStreamEvent = (event) => gateway.onEvent?.call(event);
      candidate.onConnectionChanged = (value) {
        if (!identical(socket, candidate) &&
            !identical(openingSocket, candidate)) {
          return;
        }
        connected = value;
        if (!value && !closed && identical(socket, candidate)) {
          gateway._liveChanged(false);
        }
        gateway.onConnectionChanged?.call(value);
      };
      try {
        await candidate.connect();
        final ready = await candidate.waitForGatewayReady();
        if (closed) throw StateError('Gateway is closed');
        gateway.wingSourceAdvertised = gatewayAdvertisesWingSource(ready);
        socket = candidate;
      } catch (_) {
        candidate.close();
        rethrow;
      } finally {
        if (identical(openingSocket, candidate)) openingSocket = null;
      }
    }

    gateway = ProfileGateway(
      scope: scope,
      get: (endpoint, query) => dashboard
          .apiGet(endpoint, queryParameters: query)
          .timeout(const Duration(seconds: 20)),
      patch: (endpoint, body) => dashboard
          .apiPatch(endpoint, body: body)
          .timeout(const Duration(seconds: 20)),
      post: (endpoint, body) => dashboard
          .apiPost(endpoint, body: body)
          .timeout(const Duration(seconds: 30)),
      put: (endpoint, body) => dashboard
          .apiPut(endpoint, body: body)
          .timeout(const Duration(seconds: 30)),
      delete: (endpoint, query) => dashboard
          .apiDelete(
            Uri.parse(endpoint).replace(queryParameters: query).toString(),
          )
          .timeout(const Duration(seconds: 20)),
      rpc: (method, params) async {
        final current = socket;
        if (current == null) {
          throw JsonRpcError(
            method,
            'Connection unavailable',
            reason: 'connection_closed',
          );
        }
        final envelope = await current.send(
          method,
          params,
          timeout: method == 'mcp.servers.oauth.start'
              ? const Duration(seconds: 45)
              : const {
                  'command.dispatch',
                  'slash.exec',
                  'session.compress',
                }.contains(method)
              ? const Duration(minutes: 11)
              : const Duration(seconds: 30),
        );
        final error = envelope['error'];
        if (error is Map) {
          throw JsonRpcError.fromGateway(
            method,
            error,
            fallbackMessage: 'Gateway request failed',
          );
        }
        final result = envelope['result'];
        if (result is! Map) throw const FormatException('Missing RPC result');
        return Map<String, dynamic>.from(result);
      },
      discover: () => ProfilesRepository(
        dashboard.apiGet,
      ).discover().timeout(const Duration(seconds: 20)),
      connect: () =>
          connecting ??
          (connected && socket != null
              ? Future<void>.value()
              : connecting = (() async {
                  socket?.close();
                  socket = null;
                  try {
                    await open();
                  } finally {
                    connecting = null;
                  }
                })()),
      disconnect: () {
        final previous = socket;
        socket = null;
        connected = false;
        previous?.close();
      },
      close: () {
        closed = true;
        openingSocket?.close();
        socket?.close();
        if (ownsDashboard) dashboard.close();
      },
    );
    return gateway;
  }

  Future<void> connect() async {
    try {
      await _connect();
      _liveChanged(true);
    } catch (_) {
      _liveChanged(false);
      rethrow;
    }
  }

  void close() {
    _close();
    if (reportsLiveChat) connectionStatus?.forgetLive(scope.profileName);
  }

  /// Revalidate immediately before writes. Stock servers can still have a
  /// deletion-after-validation race; client validation cannot fix that race.
  Future<void> requireProfile() async {
    if ((await discover()).named(scope.profileName) == null) {
      throw StateError('Profile ${scope.profileName} is no longer available');
    }
  }

  Future<Map<String, dynamic>> read(
    String endpoint, [
    Map<String, String> query = const {},
  ]) => _get(endpoint, {...query, 'profile': scope.profileName});

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => _rpc(method, {...params, 'profile': scope.profileName});

  /// Reload is process-wide. Its stock schema forbids a profile parameter;
  /// this gateway provides the connection, not the operation's scope.
  Future<Map<String, dynamic>> reloadMcp({bool confirm = false}) =>
      _rpc('reload.mcp', {if (confirm) 'confirm': true});

  /// Completion derives profile/workspace from the session. Its stock schema
  /// forbids the explicit profile parameter added by [call].
  Future<Map<String, dynamic>> completeSlash({
    required String sessionId,
    required String text,
  }) => _rpc('complete.slash', {'session_id': sessionId, 'text': text});

  Future<Map<String, dynamic>> post(
    String endpoint, [
    Map<String, dynamic> body = const {},
  ]) {
    final send = _post;
    if (send == null) throw StateError('Dashboard writes are unavailable');
    final uri = Uri.parse(endpoint);
    return send(
      uri
          .replace(
            queryParameters: {
              ...uri.queryParameters,
              'profile': scope.profileName,
            },
          )
          .toString(),
      body,
    );
  }

  Future<void> deleteResource(String endpoint) {
    final send = _delete;
    if (send == null) throw StateError('Dashboard writes are unavailable');
    return send(endpoint, {'profile': scope.profileName});
  }

  Future<Map<String, dynamic>> put(String endpoint, Map<String, dynamic> body) {
    final send = _put;
    if (send == null) throw StateError('Dashboard writes are unavailable');
    final uri = Uri.parse(endpoint);
    return send(
      uri
          .replace(
            queryParameters: {
              ...uri.queryParameters,
              'profile': scope.profileName,
            },
          )
          .toString(),
      body,
    );
  }

  static const sessionPageSize = 50;
  static const projectSessionScanLimit = 5000;

  Future<ProfileSessionPage> sessions({
    SessionVisibility visibility = SessionVisibility.chats,
    int offset = 0,
    int limit = sessionPageSize,
    bool archivedOnly = false,
    bool includeArchived = false,
  }) async {
    if (offset < 0 || limit < 1 || limit > 100) {
      throw ArgumentError('Invalid session page');
    }
    final result = await read('sessions', {
      'limit': '$limit',
      'offset': '$offset',
      'order': 'recent',
      ...visibility.queryParameters,
      if (archivedOnly)
        'archived': 'only'
      else if (includeArchived)
        'archived': 'include',
    });
    if (result['offset'] != offset ||
        result['limit'] != limit ||
        result['total'] is! int ||
        (result['total'] as int) < 0) {
      throw const FormatException('Invalid session pagination metadata');
    }
    final rows = records(result['sessions']);
    for (final row in rows) {
      if (row['profile'] != scope.profileName ||
          row['id'] is! String ||
          (row['id'] as String).isEmpty) {
        throw const FormatException(
          'Session response has a different profile owner',
        );
      }
    }
    return ProfileSessionPage(
      rows: rows,
      offset: offset,
      limit: limit,
      total: result['total'] as int,
    );
  }

  Future<List<Map<String, dynamic>>> projects() async {
    final rows = records(
      (await call('projects.tree', {'preview_limit': 0}))['projects'],
    );
    final projects = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (row['isNoProject'] == true) continue;
      if (row['id'] is! String ||
          row['label'] is! String ||
          row['lastActive'] is! num) {
        throw const FormatException('Invalid project overview');
      }
      projects.add({...row, 'name': row['label'], 'primary_path': row['path']});
    }
    projects.sort(
      (a, b) => (b['lastActive'] as num).compareTo(a['lastActive'] as num),
    );
    return projects;
  }

  Future<List<Map<String, dynamic>>> projectSessions(String projectId) async {
    await requireProfile();
    final result = await call('projects.project_sessions', {
      'project_id': projectId,
      'session_limit': projectSessionScanLimit,
    });
    final project = result['project'];
    if (project is! Map || project['id'] != projectId) {
      throw StateError('Project is no longer available');
    }
    final rows = <String, Map<String, dynamic>>{};
    for (final repo in records(project['repos'])) {
      for (final group in records(repo['groups'])) {
        for (final session in records(group['sessions'])) {
          if (session['profile'] != scope.profileName ||
              session['id'] is! String) {
            throw const FormatException('Invalid project session owner');
          }
          rows[session['id'] as String] = session;
        }
      }
    }
    return rows.values.toList();
  }

  Future<Map<String, dynamic>> createSession({
    String? cwd,
    String? title,
  }) async {
    await requireProfile();
    return _ownedSession(
      await call('session.create', {
        'source': sessionSource,
        'close_on_disconnect': false,
        'cwd': ?cwd,
        'title': ?title,
      }),
    );
  }

  Future<Map<String, dynamic>> resume(String durableId) async {
    await requireProfile();
    return _ownedSession(
      await call('session.resume', {
        'session_id': durableId,
        'omit_messages': true,
        'source': ?(wingSourceAdvertised ? wingSessionSource : null),
      }),
    );
  }

  Future<Map<String, dynamic>> branch(String runtimeId, int count) async {
    if (count <= 0) throw ArgumentError.value(count, 'count');
    await requireProfile();
    return _ownedSession(
      await call('session.branch', {'session_id': runtimeId, 'count': count}),
    );
  }

  /// The persisted transcript that session.branch copies, including archived
  /// turns and hidden notices. RPC history is a different, active projection.
  /// Resolve [throughRowId] before writing, then verify the child through the
  /// same REST representation instead of its projected RPC response.
  Future<List<Map<String, dynamic>>> branchHistory(
    String durableId, {
    int? throughRowId,
  }) async {
    var offset = 0;
    final messages = <Map<String, dynamic>>[];
    while (true) {
      final result =
          await read('sessions/${Uri.encodeComponent(durableId)}/messages', {
            'limit': '500',
            'offset': '$offset',
            'order': 'oldest',
            'include_compacted': 'true',
          });
      if (result['session_id'] != durableId) {
        throw StateError(
          'History changed. Reload the conversation before branching.',
        );
      }
      final rows = records(result['messages']);
      for (final row in rows) {
        if (isBranchMessage(row)) messages.add(row);
        if (throughRowId != null && row['id'] == throughRowId) {
          if (row['role'] != 'assistant' || !isBranchMessage(row)) break;
          return messages;
        }
      }
      if (rows.length < 500) break;
      offset += rows.length;
    }
    if (throughRowId == null) return messages;
    throw StateError(
      'The selected answer is no longer saved. Reload before branching.',
    );
  }

  Future<List<Map<String, dynamic>>> fullHistory(String runtimeId) async =>
      records(
        (await call('session.history', {'session_id': runtimeId}))['messages'],
      );

  Map<String, dynamic> _ownedSession(Map<String, dynamic> result) {
    final info = result['info'];
    // Stock Hermes omits profile_name from a live session's lazy info while
    // its agent is uninitialized. The request is already profile-scoped.
    // Reject any explicit conflicting owner, including in a lazy response.
    if (info is! Map ||
        (info.containsKey('profile_name')
            ? info['profile_name'] != scope.profileName
            : info['lazy'] != true)) {
      throw const FormatException(
        'Session response has a different profile owner',
      );
    }
    if (result['session_id'] is! String ||
        (result['session_id'] as String).isEmpty) {
      throw const FormatException('Session response has no runtime identity');
    }
    return result;
  }

  static const historyPageSize = 50;
  Future<ProfileHistoryPage> history(
    String id, {
    int offset = 0,
    int limit = historyPageSize,
    String? runtimeId,
  }) async {
    if (id.isEmpty || offset < 0 || limit < 1 || limit > 500) {
      throw ArgumentError('Invalid history page');
    }
    final Map<String, dynamic> result;
    try {
      result = await read('sessions/${Uri.encodeComponent(id)}/messages', {
        'limit': '$limit',
        'offset': '$offset',
        'order': 'latest',
        'include_compacted': 'true',
      });
    } on DashboardHttpException catch (error) {
      if (error.statusCode != 404 ||
          offset != 0 ||
          runtimeId == null ||
          runtimeId.isEmpty) {
        rethrow;
      }
      // A live session can precede its database row. Read its actual history;
      // a missing durable row alone does not establish an empty transcript.
      return ProfileHistoryPage(
        id,
        await fullHistory(runtimeId),
        0,
        limit,
        isComplete: true,
      );
    }
    final pagination = result['pagination'];
    final rows = records(result['messages']);
    final resolved = result['session_id'];
    if (resolved is! String ||
        resolved.isEmpty ||
        pagination is! Map ||
        pagination['limit'] != limit ||
        pagination['offset'] != offset ||
        pagination['order'] != 'latest' ||
        pagination['returned'] != rows.length ||
        rows.length > limit ||
        rows.any((row) => row['id'] is! int)) {
      throw const FormatException('Invalid history page');
    }
    return ProfileHistoryPage(resolved, rows, offset, limit);
  }

  /// Stock search is profile-bound but does not stamp owners in its response.
  /// Keep results in this client's scope; reject any contradictory owner field.
  Future<List<Map<String, dynamic>>> search(
    String query, {
    SessionVisibility visibility = SessionVisibility.chats,
  }) async {
    if (query.trim().isEmpty) return [];
    await requireProfile();
    final rows = records(
      (await read('sessions/search', {
        'q': query.trim(),
        ...visibility.queryParameters,
        'limit': '100',
      }))['results'],
    );
    for (final row in rows) {
      if (row['session_id'] is! String ||
          (row['session_id'] as String).isEmpty ||
          (row.containsKey('profile') && row['profile'] != scope.profileName)) {
        throw const FormatException('Invalid search result owner');
      }
    }
    return rows
        .map(
          (row) => <String, dynamic>{
            ...row,
            'id': row['session_id'],
            'profile': scope.profileName,
          },
        )
        .toList();
  }

  Future<Map<String, dynamic>> createProject(String name, String path) async {
    await requireProfile();
    final result = await call('projects.create', {
      'name': name,
      'folders': [path],
      'primary_path': path,
    });
    if (result['project'] is! Map) {
      throw const FormatException('Missing project');
    }
    return Map<String, dynamic>.from(result['project']);
  }

  /// Asks the selected Hermes host to scan its configured repository roots.
  Future<List<ProjectFolderSuggestion>> discoverProjectFolders() async {
    await requireProfile();
    final result = await call('projects.discover_repos', {'scan': true});
    final repos = result['repos'];
    if (repos is! List) {
      throw const FormatException('Missing discovered repositories');
    }

    final suggestions = <String, ProjectFolderSuggestion>{};
    for (final repo in repos) {
      if (repo is! Map || repo['root'] is! String || repo['label'] is! String) {
        throw const FormatException('Invalid discovered repository');
      }
      final path = (repo['root'] as String).trim();
      final label = (repo['label'] as String).trim();
      if (path.isEmpty || label.isEmpty) {
        throw const FormatException('Invalid discovered repository');
      }
      suggestions.putIfAbsent(
        path,
        () => ProjectFolderSuggestion(path: path, label: label),
      );
    }
    return List.unmodifiable(suggestions.values);
  }

  Future<Map<String, dynamic>> updateProject(
    String id, {
    String? name,
    String? color,
    String? icon,
  }) async {
    final projectId = id.trim();
    final projectName = name?.trim();
    if (projectId.isEmpty || projectName != null && projectName.isEmpty) {
      throw ArgumentError('A project id and non-empty name are required');
    }
    final changes = <String, dynamic>{
      if (name != null) 'name': projectName,
      if (color != null) 'color': color.trim(),
      if (icon != null) 'icon': icon.trim(),
    };
    if (changes.isEmpty) throw ArgumentError('No project changes supplied');
    await requireProfile();
    final result = await call('projects.update', {'id': projectId, ...changes});
    final project = result['project'];
    if (project is! Map || project['id'] != projectId) {
      throw const FormatException('Project update not acknowledged');
    }
    return Map<String, dynamic>.from(project);
  }

  Future<void> deleteProject(String id) async {
    final projectId = id.trim();
    if (projectId.isEmpty) throw ArgumentError('Missing project');
    await requireProfile();
    final result = await call('projects.delete', {'id': projectId});
    final projects = result['projects'];
    final activeId = result['active_id'];
    if (projects is! List ||
        projects.any((project) => project is! Map) ||
        projects.any((project) => (project as Map)['id'] == projectId) ||
        activeId != null && activeId is! String ||
        activeId == projectId) {
      throw const FormatException('Project delete not acknowledged');
    }
  }

  Future<Map<String, dynamic>> updateSession(
    String id,
    Map<String, dynamic> changes,
  ) async {
    if (id.isEmpty ||
        changes.isEmpty ||
        changes.keys.any(
          (key) => !{'title', 'pinned', 'archived', 'unread'}.contains(key),
        )) {
      throw ArgumentError('Invalid session update');
    }
    await requireProfile();
    final patch = _patch;
    if (patch == null) {
      throw StateError('Session mutation transport unavailable');
    }
    final result = await patch('sessions/${Uri.encodeComponent(id)}', {
      ...changes,
      'profile': scope.profileName,
    });
    if (result['ok'] != true) {
      throw const FormatException('Session update not acknowledged');
    }
    return result;
  }

  /// Same operation as Desktop: moves the stored workspace, not a local tag.
  Future<Map<String, dynamic>> moveSession(String id, String cwd) async {
    if (id.isEmpty || cwd.trim().isEmpty) {
      throw ArgumentError('A chat and project folder are required');
    }
    await requireProfile();
    // Stock workspace.move finds live agents by durable ID without checking
    // profile ownership. Resolve the owner and reject colliding live sessions.
    final live = records((await call('session.active_list'))['sessions']);
    if (live.any((row) => row['session_key'] == id)) {
      final session = await resume(id);
      final storedId = session['stored_session_id'] ?? session['session_key'];
      if (storedId != id ||
          session.containsKey('session_key') && session['session_key'] != id) {
        throw const FormatException('Session response has a different chat');
      }
      final matching = records(
        (await call('session.active_list'))['sessions'],
      ).where((row) => row['session_key'] == id).toList();
      if (matching.length != 1 ||
          matching.single['id'] != session['session_id']) {
        throw StateError(
          'Hermes could not verify this chat\'s project owner. '
          'Refresh and try moving again.',
        );
      }
      if (matching.single['status'] != 'idle') {
        throw StateError(
          'This chat is working or waiting for input on Hermes. '
          'Stop it or let it finish before moving.',
        );
      }
    }
    final result = await call('session.workspace.move', {
      'session_key': id,
      'cwd': cwd,
    });
    if (result['cwd'] is! String ||
        (result['cwd'] as String).trim().isEmpty ||
        (result['branch'] != null && result['branch'] is! String) ||
        (result['git_repo_root'] != null &&
            result['git_repo_root'] is! String)) {
      throw const FormatException('Invalid workspace move response');
    }
    return {
      'cwd': result['cwd'],
      'git_branch': result['branch'],
      'git_repo_root': result['git_repo_root'],
    };
  }

  /// Desktop uses the primary folder, then the first repository folder.
  static String projectDirectory(Map<String, dynamic> project) {
    final primary = (project['primary_path'] ?? project['path'])?.toString();
    if (primary != null && primary.trim().isNotEmpty) return primary.trim();
    for (final repo in (project['repos'] as List? ?? const [])) {
      if (repo is Map && repo['path'] is String) {
        final path = (repo['path'] as String).trim();
        if (path.isNotEmpty) return path;
      }
    }
    return '';
  }

  Future<void> deleteSession(String id) async {
    if (id.isEmpty) throw ArgumentError('Missing session');
    await requireProfile();
    final remove = _delete;
    if (remove == null) {
      throw StateError('Session mutation transport unavailable');
    }
    final live = records((await call('session.active_list'))['sessions']);
    if (live.any((row) => row['session_key'] == id)) {
      // The live list has no profile owner. Resolve through scoped resume before
      // closing anything: the same durable ID can exist in another profile.
      final session = await resume(id);
      // Fresh resumes expose stored_session_id; reusing an open runtime exposes
      // session_key instead. If both are present they must agree.
      final storedId = session['stored_session_id'] ?? session['session_key'];
      if (storedId != id ||
          session.containsKey('session_key') && session['session_key'] != id) {
        throw const FormatException('Session response has a different chat');
      }
      final runtimeId = session['session_id'] as String;
      final current = records((await call('session.active_list'))['sessions'])
          .where((row) => row['id'] == runtimeId && row['session_key'] == id)
          .toList();
      if (current.length != 1 || current.single['status'] != 'idle') {
        throw StateError(
          'This chat is working or waiting for input on Hermes. '
          'Stop it or let it finish before deleting.',
        );
      }
      // Finalize the runtime before removing its stored history, so a later
      // agent flush cannot write into a deleted session.
      final result = await call('session.close', {'session_id': runtimeId});
      if (result['closed'] != true) {
        throw StateError(
          'Hermes could not close this chat. Try deleting again.',
        );
      }
    }
    await remove('sessions/${Uri.encodeComponent(id)}', {
      'profile': scope.profileName,
    });
  }

  static List<Map<String, dynamic>> records(Object? value) {
    if (value is! List || value.any((row) => row is! Map)) {
      throw const FormatException('Expected a list of records');
    }
    return value.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }
}
