import 'package:flutter/foundation.dart';

import '../models/provider_inventory.dart';
import '../models/provider_access.dart';
import '../models/provider_recovery.dart';
import 'administration_repository.dart';
import 'connection_manager.dart';

class ProviderRecovery extends ChangeNotifier {
  ProviderRecovery(this._profile, {required this.providerId})
    : _fileBefore = null {
    _profile.server.retain();
  }
  ProviderRecovery.forFileReview(this._profile, ProviderAccess before)
    : providerId = before.id,
      _access = ProviderAccess(
        _freezeProviderRow(before.row),
        now: before.checkedAt,
      ),
      _fileBefore = ProviderAccess(
        _freezeProviderRow(before.row),
        now: before.checkedAt,
      ) {
    _profile.server.retain();
  }
  final ProfileAdministration _profile;
  final String providerId;
  String get scopeLabel => _profile.label;
  String get connectionLabel => _profile.server.connectionLabel;
  ProviderAccess? _access;
  final ProviderAccess? _fileBefore;
  bool _busy = false,
      _renewing = false,
      _inspectingFile = false,
      _disposed = false;
  bool _admitted = false, _released = false, _notifierDisposed = false;
  int _pending = 0, _notificationDepth = 0;
  String? _error, _message;
  String _filePath = '~/.claude/.credentials.json';
  bool _fileConfirmed = false, _deleted = false;
  ProviderCredentialFile? _file;

  ProviderRecoveryState get state => ProviderRecoveryState(
    observation: _access == null ? null : ProviderRecoveryObservation(_access!),
    busy: _busy,
    renewing: _renewing,
    inspectingFile: _inspectingFile,
    error: _error,
    message: _message,
    filePath: _filePath,
    fileConfirmed: _fileConfirmed,
    file: _file,
    deleted: _deleted,
  );

  void _changed() {
    if (_disposed) {
      return;
    }
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      _finishDisposal();
      if (_disposed && _notificationDepth == 0 && !_notifierDisposed) {
        _notifierDisposed = true;
        super.dispose();
      }
    }
  }

  void _markDispatched() {
    if (_pending > 0) {
      _admitted = true;
    }
  }

  void _ensureAuthority() {
    if (_disposed && !_admitted) {
      throw const _RecoveryRetired();
    }
  }

  void _finishDisposal() {
    if (!_disposed) {
      return;
    }
    if (_pending == 0 && !_released) {
      _released = true;
      _profile.server.release();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _finishDisposal();
    if (_notificationDepth == 0 && !_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }

  /// Dialog work and held authentication can be revoked. After actual dispatch of an exact
  /// physical mutation, its captured connection lease drains receipt + readback even if
  /// the route closes. Completion then publishes nothing to the retired route.
  Future<void> _run(
    Future<void> Function() operation, {
    bool renewing = false,
    bool checking = false,
    bool invalidateFile = false,
    bool inspectingFile = false,
  }) async {
    if (_disposed || _busy) {
      return;
    }
    _pending++;
    _busy = true;
    _renewing = renewing;
    _inspectingFile = inspectingFile;
    _error = null;
    _message = null;
    if (invalidateFile) {
      _file = null;
    }
    _changed();
    try {
      _ensureAuthority();
      await operation();
    } on _RecoveryRetired {
      // A closed route never admits a new mutation after its dialog completes.
    } catch (failure) {
      if (!_disposed) {
        _error = checking
            ? 'Status could not be checked. ${_access == null ? 'Try again.' : 'The last observation is shown.'}'
            : providerRecoveryError(failure);
      }
    } finally {
      _admitted = false;
      _busy = false;
      _renewing = false;
      _inspectingFile = false;
      _pending--;
      _changed();
      _finishDisposal();
    }
  }

  Future<void> refresh() => _run(() async {
    final observed = await observe(providerId);
    _ensureAuthority();
    _access = observed;
  }, checking: true);

  Future<void> renewAccess({
    required Future<ProviderCredential?> Function(List<ProviderCredential>)
    choose,
    required Future<bool> Function(String) confirmShared,
  }) => _run(() async {
    final before = _access;
    if (before == null || ProviderRenewal.forAccess(before) == null) {
      return;
    }
    final entries = await candidates(before);
    _ensureAuthority();
    if (entries.isEmpty) {
      throw const ProviderRecoveryFailure(
        'No matching renewable credential was found for this profile. Use sign-in options instead.',
      );
    }
    _renewing = false;
    _changed();
    _ensureAuthority();
    final selected = entries.length == 1
        ? entries.single
        : await choose(List.unmodifiable(entries));
    _ensureAuthority();
    if (selected == null) {
      return;
    }
    if (!entries.any((entry) => entry.sameIdentity(selected))) {
      throw const ProviderRecoveryFailure(
        'The selected credential changed. Check status before renewing.',
      );
    }
    if (ProviderRenewal.forAccess(before)!.shared &&
        !await confirmShared(
          'This renews the Claude Code sign-in on ${_profile.server.connectionLabel}. Other profiles and Claude Code using this sign-in also receive the renewed credentials.',
        )) {
      return;
    }
    _ensureAuthority();
    _renewing = true;
    _changed();
    final after = await renew(before, selected);
    if (_disposed) {
      return;
    }
    _access = after;
    _message = after.state == ProviderAccessState.connected
        ? 'Renewal completed. Credentials are detected; model access has not been tested.'
        : 'Renewal finished, but access is not confirmed. ${after.state == ProviderAccessState.expired ? 'The token is still expired. Sign in again.' : 'Check status or use sign-in options.'}';
  }, renewing: true);

  Future<void> removeAccess({
    required Future<bool> Function(String) confirm,
  }) => _run(() async {
    final before = _access;
    if (before == null || !ProviderRecoveryObservation(before).canRemove) {
      return;
    }
    if (!await confirm(
      'Remove the Hermes-managed ${before.name} credentials from ${_profile.name} on ${_profile.server.connectionLabel}? This clears this provider’s saved sign-ins for the profile and may stop chats using them. Your provider account is not deleted.',
    )) {
      return;
    }
    _ensureAuthority();
    final after = await remove(before);
    if (_disposed) {
      return;
    }
    _access = after;
    _message = after.hasCredential
        ? 'Saved sign-in removed. Another credential source is still detected.'
        : 'Saved sign-in removed.';
  });

  ProviderRecoveryInstructions instructions({bool removal = false}) {
    final access = _access;
    if (access == null) {
      throw StateError('Provider observation is unavailable');
    }
    final claude = access.id == 'claude-code';
    final rawCommand =
        access.row[removal ? 'disconnect_command' : 'cli_command'];
    final rawHint = access.row['disconnect_hint'];
    return ProviderRecoveryInstructions(
      scope: _profile.label,
      name: access.name,
      removal: removal,
      claude: claude,
      description: removal
          ? 'These credentials are managed outside Hermes. Remove the sign-in using the provider’s tool on ${_profile.server.connectionLabel}.'
          : claude
          ? 'Open Claude Code on ${_profile.server.connectionLabel} and use /login. Then return to Wing and check status.'
          : 'Complete sign-in using the provider’s tool on ${_profile.server.connectionLabel}, then return to Wing and check status.',
      command: rawCommand is String && rawCommand.isNotEmpty
          ? rawCommand
          : null,
      hint: removal && rawHint is String ? rawHint : null,
    );
  }

  Future<void> openSignIn({
    required Future<void> Function(ProviderSignInTarget) deviceSignIn,
    required Future<void> Function(ProviderRecoveryInstructions) externalSignIn,
  }) async {
    if (_disposed || _busy || _access == null) {
      return;
    }
    final target = ProviderRecoveryObservation(_access!).signIn;
    if (target != null) {
      await deviceSignIn(target);
    } else {
      await externalSignIn(instructions());
    }
    if (!_disposed) {
      await refresh();
    }
  }

  Future<void> visit(Future<void> Function() route) async {
    if (_disposed || _busy) {
      return;
    }
    await route();
    if (!_disposed) {
      await refresh();
    }
  }

  ProviderRecovery createFileReview() {
    _ensureAuthority();
    final before = _access;
    if (before == null || !ProviderCredentialFile.supports(before)) {
      throw const ProviderRecoveryFailure(
        'The sign-in changed. Check status and review the file again.',
      );
    }
    return ProviderRecovery.forFileReview(_profile, before);
  }

  void changeFilePath(String value) {
    if (_disposed || _busy) {
      return;
    }
    _filePath = value;
    _file = null;
    _fileConfirmed = false;
    _changed();
  }

  void confirmFileLocation(bool value) {
    if (_disposed || _busy) {
      return;
    }
    _fileConfirmed = value;
    _changed();
  }

  Future<void> checkFile() {
    if (_fileBefore == null || !state.canInspectFile) {
      return Future.value();
    }
    return _run(
      () async {
        final file = await inspectFile(_filePath);
        _ensureAuthority();
        _file = file;
      },
      invalidateFile: true,
      inspectingFile: true,
    );
  }

  Future<void> deleteReviewedFile({
    required Future<bool> Function(String) confirm,
  }) {
    final before = _fileBefore, file = _file;
    if (before == null || file == null || !state.canDeleteFile) {
      return Future.value();
    }
    return _run(() async {
      if (!await confirm(
        'Delete ${file.path} on ${_profile.server.connectionLabel}? Other profiles and Claude Code using this file will lose the saved sign-in. This does not revoke the account or copies already in use.',
      )) {
        return;
      }
      _ensureAuthority();
      try {
        final after = await deleteFile(before, file);
        if (_disposed) {
          return;
        }
        _deleted = true;
        _message = after.hasCredential
            ? 'The file was deleted. Another credential source is still detected.'
            : 'The file was deleted. No Claude Code credentials are detected.';
      } catch (_) {
        if (!_disposed) {
          _file = null;
        }
        rethrow;
      }
    });
  }

  Future<ProviderAccess> observe(String id) async {
    _ensureAuthority();
    if (id != providerId) {
      throw ArgumentError('Unexpected provider identity');
    }
    final data = await _profile.read('providers/oauth');
    final rows = administrationRows(
      data['providers'],
    ).where((row) => row['id'] == id).toList();
    if (rows.length != 1) {
      throw const ProviderRecoveryFailure(
        'This provider is no longer available.',
      );
    }
    ProviderAccess.validateIdentity(rows.single);
    return ProviderAccess(_freezeProviderRow(rows.single));
  }

  Future<String> _command(String command, {bool confirm = false}) async {
    _ensureAuthority();
    await _profile.requireProfile();
    _ensureAuthority();
    final run = _profile.server.providerCommand;
    if (run == null) {
      throw const ProviderRecoveryFailure(
        'Credential renewal is unavailable on this connection.',
      );
    }
    return run(
      _profile.name,
      command,
      confirm: confirm,
      canDispatch: () => !_disposed,
      onDispatched: _markDispatched,
    );
  }

  Future<List<ProviderCredential>> candidates(ProviderAccess access) async {
    final renewal = ProviderRenewal.forAccess(access);
    if (renewal == null) {
      throw const ProviderRecoveryFailure(
        'This credential does not support renewal here. Use sign-in options.',
      );
    }
    final output = await _command('auth list ${renewal.pool}');
    final entries = ProviderCredential.parseList(renewal.pool, output);
    final candidates = entries.where(renewal.accepts).toList();
    // The CLI also accepts labels/indices: don't submit an ID that could
    // become another target if its original entry disappears between calls.
    return candidates
        .where(
          (e) =>
              !entries.any(
                (other) =>
                    other.id != e.id && other.label.toLowerCase() == e.id,
              ) &&
              !(int.tryParse(e.id) != null &&
                  int.parse(e.id) <= entries.length),
        )
        .toList();
  }

  Future<ProviderAccess> renew(
    ProviderAccess before,
    ProviderCredential selected,
  ) async {
    final latest = await observe(before.id);
    final renewal = ProviderRenewal.forAccess(latest);
    if (renewal == null || !sameSource(before, latest)) {
      throw const ProviderRecoveryFailure(
        'The credential source changed. Check status before renewing.',
      );
    }
    final entries = await candidates(latest);
    if (!entries.any((entry) => entry.sameIdentity(selected))) {
      throw const ProviderRecoveryFailure(
        'The selected credential changed. Check status before renewing.',
      );
    }
    await _command(
      'auth refresh ${renewal.pool} ${selected.id}',
      confirm: true,
    );
    try {
      return await observe(before.id);
    } catch (_) {
      throw const ProviderRecoveryFailure(
        'Hermes completed the renewal command, but status could not be checked. Check status before retrying.',
      );
    }
  }

  Future<ProviderAccess> remove(ProviderAccess before) async {
    final latest = await observe(before.id);
    if (!sameSource(before, latest) ||
        !latest.hasCredential ||
        latest.state == ProviderAccessState.unknown ||
        latest.row['disconnectable'] != true) {
      throw const ProviderRecoveryFailure(
        'The credential source changed. Check status before removing it.',
      );
    }
    _ensureAuthority();
    await _profile.requireProfile();
    _ensureAuthority();
    final result = await _profile.server.ownedMutation(
      'DELETE',
      'providers/oauth/${Uri.encodeComponent(before.id)}',
      {'profile': _profile.name},
      {'profile': _profile.name},
      () => !_disposed,
      _markDispatched,
    );
    if (result['ok'] != true) {
      throw const ProviderRecoveryFailure(
        'Credential removal was not confirmed. Check status before retrying.',
      );
    }
    try {
      return await observe(before.id);
    } catch (_) {
      throw const ProviderRecoveryFailure(
        'Saved credentials were removed, but status could not be checked.',
      );
    }
  }

  Future<ProviderCredentialFile> inspectFile(String path) async {
    _ensureAuthority();
    final directory = ProviderCredentialFile.directory(path.trim());
    try {
      final listing = await _profile.server.read('files', {'path': directory});
      return ProviderCredentialFile.fromListing(listing);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 403) {
        throw const ProviderRecoveryFailure(
          'Hermes does not allow access to this location. Remove the credentials using Claude Code on the server.',
        );
      }
      if (error.statusCode == 404) {
        throw const ProviderRecoveryFailure(
          'The credential location was not found on the server.',
        );
      }
      rethrow;
    }
  }

  Future<ProviderAccess> deleteFile(
    ProviderAccess before,
    ProviderCredentialFile file,
  ) async {
    final latest = await observe(before.id);
    if (!ProviderCredentialFile.supports(latest) ||
        !sameSource(before, latest)) {
      throw const ProviderRecoveryFailure(
        'The sign-in changed. Check status and review the file again.',
      );
    }
    final current = await inspectFile(file.path);
    if (!file.sameFile(current)) {
      throw const ProviderRecoveryFailure(
        'The credential file changed. Review it again before deleting.',
      );
    }
    try {
      _ensureAuthority();
      final result = await _profile.server.ownedMutation(
        'DELETE',
        'files',
        const {},
        {'path': file.path, 'recursive': false},
        () => !_disposed,
        _markDispatched,
      );
      if (result['ok'] != true) {
        throw const ProviderRecoveryFailure(
          'File deletion was not confirmed. Check status before retrying.',
        );
      }
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 403) {
        throw const ProviderRecoveryFailure(
          'Hermes does not allow deletion at this location. Remove the credentials on the server.',
        );
      }
      rethrow;
    }
    try {
      return await observe(before.id);
    } catch (_) {
      throw const ProviderRecoveryFailure(
        'The credential file was deleted, but status could not be checked.',
      );
    }
  }

  static bool sameSource(ProviderAccess a, ProviderAccess b) =>
      a.id == b.id &&
      a.status['source'] == b.status['source'] &&
      a.status['source_label'] == b.status['source_label'] &&
      a.status['token_preview'] == b.status['token_preview'] &&
      a.status['expires_at'] == b.status['expires_at'];
}

String providerRecoveryError(Object error) => error is ProviderRecoveryFailure
    ? error.message
    : administrationError(error, writing: true);

class _RecoveryRetired implements Exception {
  const _RecoveryRetired();
}

Map<String, dynamic> _freezeProviderRow(Map<String, dynamic> row) {
  Object? freeze(Object? value) {
    if (value is Map) {
      return Map.unmodifiable({
        for (final e in value.entries) e.key: freeze(e.value),
      });
    }
    if (value is List) {
      return List.unmodifiable(value.map(freeze));
    }
    return value;
  }

  return Map.unmodifiable({
    for (final e in row.entries) e.key: freeze(e.value),
  });
}
