import 'provider_access.dart';
import 'provider_inventory.dart';

class ProviderRecoveryFailure implements Exception {
  const ProviderRecoveryFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Explicit adapters to stock Hermes' credential authorities, not provider-name
/// guesses. The catalog and the credential pool use different identifiers.
class ProviderRenewal {
  const ProviderRenewal(
    this.pool,
    this.sources, {
    this.shared = false,
    this.poolLabel,
  });
  final String pool;
  final Set<String> sources;
  final bool shared;
  final String? poolLabel;

  bool accepts(ProviderCredential entry) =>
      entry.type == 'oauth' &&
      (poolLabel != null
          ? entry.label == poolLabel
          : sources.contains(entry.source));

  static ProviderRenewal? forAccess(ProviderAccess access) {
    // Codex's current catalog hardcodes has_refresh_token=false even though
    // its auth-store reader requires a refresh token. Use its known authority.
    if (!access.hasCredential ||
        (!access.canRefresh && access.id != 'openai-codex') ||
        access.state == ProviderAccessState.unknown) {
      return null;
    }
    final source = access.status['source'];
    if ({'openai-codex', 'xai-oauth'}.contains(access.id) &&
        source is String &&
        source.startsWith('pool:') &&
        source.length > 5) {
      return ProviderRenewal(
        access.id,
        const {},
        poolLabel: source.substring(5),
      );
    }
    return switch (access.id) {
      'claude-code' when access.status['source'] == 'claude_code_cli' =>
        const ProviderRenewal('anthropic', {'claude_code'}, shared: true),
      'anthropic' when access.status['source'] == 'hermes_pkce' =>
        const ProviderRenewal('anthropic', {'hermes_pkce'}),
      'nous'
          when access.status['source'] == 'nous_portal' &&
              access.status['free_tier'] != true =>
        const ProviderRenewal('nous', {'device_code'}),
      'openai-codex' when access.status['source'] == 'hermes-auth-store' =>
        const ProviderRenewal('openai-codex', {'device_code'}),
      'xai-oauth' when access.status['source'] == 'hermes-auth-store' =>
        const ProviderRenewal('xai-oauth', {'device_code'}),
      _ => null,
    };
  }
}

class ProviderCredential {
  const ProviderCredential(this.id, this.label, this.type, this.source);
  final String id;
  final String label;
  final String type;
  final String source;

  bool sameIdentity(ProviderCredential other) =>
      id == other.id &&
      label == other.label &&
      type == other.type &&
      source == other.source;

  /// Current upstream's complete, non-ANSI `auth list` output. Labels can
  /// contain spaces. Ambiguous fields, duplicate IDs and incomplete output
  /// cannot be used to authorize a credential mutation.
  static List<ProviderCredential> parseList(String provider, String output) {
    const failure = ProviderRecoveryFailure(
      'Wing could not identify the saved credentials. Use sign-in options instead.',
    );
    if (output.length > 50000 ||
        RegExp(r'[\x00-\x09\x0b-\x1f\x7f]').hasMatch(output)) {
      throw failure;
    }
    // Current Hermes appends this notice for Anthropic/Codex when the user
    // disables adoption of external CLI logins. It is not a credential row.
    const externalLoginNotice =
        'External CLI logins (Codex CLI, Claude Code) are not adopted: '
        'auth.adopt_external_logins is false. '
        'Hermes uses only its own logins; run `hermes auth add <provider>` to add one.';
    var listing = output.trimRight();
    if ({'anthropic', 'openai-codex'}.contains(provider) &&
        (listing == externalLoginNotice ||
            listing.endsWith('\n$externalLoginNotice'))) {
      listing = listing
          .substring(0, listing.length - externalLoginNotice.length)
          .trimRight();
    }
    if (listing.isEmpty) return [];
    final lines = listing.split('\n');
    final header = RegExp(
      '^${RegExp.escape(provider)} \\((\\d+) credentials\\):\$',
    ).firstMatch(lines.first);
    if (header == null || lines.length != int.parse(header[1]!) + 1) {
      throw failure;
    }
    final entries = <ProviderCredential>[];
    final ids = <String>{};
    final columns = RegExp(
      r'\s+(oauth|api_key)\s+id=([a-f0-9]{6}) priority=(\d+) (\S+)(?=\s|$)',
    );
    for (var i = 1; i < lines.length; i++) {
      final row = RegExp(r'^  #(\d+)  (.*)$').firstMatch(lines[i]);
      if (row == null || int.parse(row[1]!) != i) throw failure;
      final matches = columns.allMatches(row[2]!).toList();
      if (matches.length != 1) throw failure;
      final match = matches.single;
      final id = match[2]!;
      if (!ids.add(id)) throw failure;
      entries.add(
        ProviderCredential(
          id,
          row[2]!.substring(0, match.start).trim(),
          match[1]!,
          match[4]!,
        ),
      );
    }
    return entries;
  }
}

/// Deletion is a shared-file operation. This adapter never interprets an
/// arbitrary server-supplied shell command as authority to delete a path.
class ProviderCredentialFile {
  const ProviderCredentialFile({
    required this.path,
    required this.size,
    required this.modified,
  });
  final String path;
  final num size;
  final num modified;
  bool sameFile(ProviderCredentialFile other) =>
      path == other.path && size == other.size && modified == other.modified;

  static bool supports(ProviderAccess access) =>
      access.hasCredential &&
      access.state != ProviderAccessState.unknown &&
      access.id == 'claude-code' &&
      access.status['source'] == 'claude_code_cli';

  static String directory(String path) {
    if (!(path.startsWith('/') || path.startsWith('~/')) ||
        !path.endsWith('/.credentials.json') ||
        RegExp(r'[\x00-\x1f\x7f\\]').hasMatch(path) ||
        path.split('/').any((part) => part == '..' || part == '.')) {
      throw const ProviderRecoveryFailure(
        'Enter the full Claude Code credential file path ending in /.credentials.json.',
      );
    }
    return path.substring(0, path.lastIndexOf('/'));
  }

  static ProviderCredentialFile fromListing(Map<String, dynamic> listing) {
    final rows = listing['entries'];
    if (rows is! List) {
      throw const ProviderRecoveryFailure(
        'The server did not return file details.',
      );
    }
    final matches = rows
        .whereType<Map>()
        .where((row) => row['name'] == '.credentials.json')
        .toList();
    if (matches.length != 1) {
      throw const ProviderRecoveryFailure(
        'The credential file was not found at this location.',
      );
    }
    final row = matches.single;
    final path = row['path'];
    if (row['is_directory'] != false ||
        path is! String ||
        !path.startsWith('/') ||
        !path.endsWith('/.credentials.json') ||
        row['size'] is! num ||
        row['mtime'] is! num) {
      throw const ProviderRecoveryFailure(
        'This location could not be verified as a credential file.',
      );
    }
    return ProviderCredentialFile(
      path: path,
      size: row['size'] as num,
      modified: row['mtime'] as num,
    );
  }
}

/// Readonly facts for the account route. Wire maps and credential previews stay
/// private to ProviderRecovery; these values confer no mutation authority.
class ProviderRecoveryObservation {
  ProviderRecoveryObservation(ProviderAccess access)
    : name = access.name,
      reportedName = access.row['name']?.toString(),
      statusLabel = providerInventoryStatus(access),
      detail = access.detail,
      sourceLabel = access.status['source_label']?.toString() ?? 'Not reported',
      state = access.state,
      checkedAt = access.checkedAt,
      expiresAt = access.expiresAt,
      external = access.external,
      hasCredential = access.hasCredential,
      canRefresh = access.canRefresh,
      canRenew = ProviderRenewal.forAccess(access) != null,
      managesKeys = access.status['source'] == 'env_var',
      canRemove =
          access.row['disconnectable'] == true &&
          access.hasCredential &&
          access.state != ProviderAccessState.unknown,
      canReviewFile = ProviderCredentialFile.supports(access),
      signIn = access.row['flow'] == 'device_code'
          ? ProviderSignInTarget.fromAccess(access)
          : null,
      signInLabel = access.row['flow'] == 'device_code'
          ? access.signInLabel
          : 'Sign-in options';
  final String name, statusLabel, detail, sourceLabel, signInLabel;
  final String? reportedName;
  final ProviderAccessState state;
  final DateTime checkedAt;
  final DateTime? expiresAt;
  final bool external, hasCredential, canRefresh, canRenew, managesKeys;
  final bool canRemove, canReviewFile;
  final ProviderSignInTarget? signIn;
  bool get expired => state == ProviderAccessState.expired;
  bool get hasRemovalInstructions => external && !managesKeys;
  String get expiryPrefix => expired ? 'Expired' : 'Expires';
}

class ProviderRecoveryInstructions {
  const ProviderRecoveryInstructions({
    required this.scope,
    required this.name,
    required this.description,
    required this.removal,
    required this.claude,
    this.command,
    this.hint,
  });
  final String scope, name, description;
  final bool removal, claude;
  final String? command, hint;
}

class ProviderRecoveryState {
  const ProviderRecoveryState({
    required this.inspectingFile,
    this.observation,
    this.busy = false,
    this.renewing = false,
    this.error,
    this.message,
    this.filePath = '~/.claude/.credentials.json',
    this.fileConfirmed = false,
    this.file,
    this.deleted = false,
  });
  final ProviderRecoveryObservation? observation;
  final bool busy, renewing, inspectingFile, fileConfirmed, deleted;
  final String? error, message;
  final String filePath;
  final ProviderCredentialFile? file;
  bool get canInspectFile => !busy && fileConfirmed && !deleted;
  bool get canDeleteFile => canInspectFile && file != null;
}
