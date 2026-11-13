import 'package:path/path.dart' as paths;

final class ServerReferenceEntry {
  const ServerReferenceEntry({
    required this.name,
    required this.path,
    required this.directory,
    required this.size,
    required this.mime,
  });
  final String name;
  final String path;
  final bool directory;
  final int? size;
  final String? mime;
}

final class ServerReferenceDirectory {
  ServerReferenceDirectory(
    this.path,
    this.parent,
    Iterable<ServerReferenceEntry> entries,
  ) : entries = List.unmodifiable(entries);
  final String path;
  final String? parent;
  final List<ServerReferenceEntry> entries;
}

/// Canonical host namespace and credential admission; no I/O.
final class ServerReferencePath {
  static final pathContext = paths.Context(style: paths.Style.posix);

  static void admit(String path) {
    if (!path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains(RegExp(r'[\x00-\x1f\\]')) ||
        pathContext.normalize(path) != path) {
      throw const FormatException('A canonical server path is required.');
    }
    final parts = pathContext.split(path).map((s) => s.toLowerCase()).toList();
    const dirs = {
      '.ssh',
      '.aws',
      '.gnupg',
      '.kube',
      '.docker',
      '.azure',
      'mcp-tokens',
      'browser-profile',
    };
    const files = {
      '.env',
      '.env.local',
      '.env.development',
      '.env.production',
      '.env.test',
      '.env.staging',
      '.envrc',
      'auth.json',
      'auth.lock',
      '.anthropic_oauth.json',
      'webhook_subscriptions.json',
      'google_oauth.json',
      'bws_cache.json',
      'bws_cache.enc.json',
      '.netrc',
      '.pgpass',
      '.npmrc',
      '.pypirc',
      '.bashrc',
      '.zshrc',
      '.profile',
      '.bash_profile',
      '.zprofile',
      '.git-credentials',
    };
    if (parts.any(dirs.contains) ||
        files.contains(parts.last) ||
        path.contains('/.config/gh/') ||
        path.endsWith('/.config/gh') ||
        path.contains('/.config/gcloud/') ||
        path.endsWith('/.config/gcloud') ||
        path.contains('/skills/.hub/') ||
        path.endsWith('/skills/.hub')) {
      throw const FormatException(
        'Credential and internal paths cannot be referenced.',
      );
    }
  }
}
