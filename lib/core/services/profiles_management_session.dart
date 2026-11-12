import 'package:flutter/foundation.dart';

import '../models/hermes_profile.dart';
import '../models/profiles_management.dart';
import 'administration_repository.dart';

enum _Operation { create, clone, rename, delete }

/// An unforgeable, route-owned command. A refreshed roster never rebases it.
class ProfilesManagementIntent {
  ProfilesManagementIntent._(this._operation, this._opening, this._revision)
    : _name = _operation == _Operation.rename
          ? (_opening!.name == 'default' ? _opening.label : _opening.name)
          : '';
  final _Operation _operation;
  final HermesProfile? _opening;
  final int _revision;
  String _name;
}

/// Owns one roster and one captured profile-management attempt. Stock profiles
/// have no incarnation/revision token: preflight cannot make a later write atomic.
class ProfilesManagementSession extends ChangeNotifier {
  ProfilesManagementSession({
    required this._server,
    required this._openProfile,
  }) {
    _server.retain();
  }
  final AdministrationRepository _server;
  final Future<bool> Function(String canonicalName) _openProfile;
  List<HermesProfile> _profiles = const [];
  ProfilesManagementIntent? _intent;
  ProfilesManagementOutcome? _outcome;
  final _settlements = <String, ProfilesManagementOutcome>{};
  String? _error;
  bool _disposed = false, _loading = false, _submitting = false;
  bool _opening = false, _hasRoster = false, _uncertain = false;
  int _revision = 0, _readRevision = 0, _notifications = 0;

  bool get _occupied => _intent != null || _submitting || _opening;
  bool _owns(int revision) => !_disposed && revision == _revision;
  bool _has(ProfilesManagementIntent intent) =>
      _owns(intent._revision) && identical(_intent, intent);

  ProfilesManagementIntent? get pendingIntent => _intent;

  ProfilesManagementState get state {
    final available = !_disposed && _hasRoster && !_occupied;
    return ProfilesManagementState(
      hasObservation: _hasRoster,
      scope: _server.connectionLabel,
      rows: [
        for (final profile in _profiles)
          ProfilesManagementRow(
            name: profile.name,
            title: profile.label,
            subtitle: profile.description ?? profile.name,
            canClone: available,
            canRename: available,
            canDelete: available && profile.name != 'default',
          ),
      ],
      loading: _loading,
      busy: _submitting || _opening,
      canCreate: available,
      canOpen: available,
      canRefresh: !_disposed && !_submitting && !_opening,
      settlements: _settlements.values.toList(),
      draft: _intent == null ? null : _draft(_intent!),
      error:
          _error ??
          (_intent != null && _outcome?.sequence == _intent!._revision
              ? _outcome?.message
              : null),
      outcome: _outcome,
    );
  }

  void _publish() {
    if (_disposed) return;
    _notifications++;
    try {
      notifyListeners();
    } finally {
      _notifications--;
      // A listener may retire the route while ChangeNotifier is publishing.
      if (_disposed && _notifications == 0) super.dispose();
    }
  }

  Future<void> reload() async {
    if (_disposed || _submitting || _opening) return;
    await _readRoster();
  }

  Future<bool?> _readRoster({int? command}) async {
    if (_disposed || command != null && !_owns(command)) return null;
    final read = ++_readRevision;
    _loading = true;
    _publish();
    try {
      final discovery = await _server.discover();
      if (_disposed || read != _readRevision) return null;
      _profiles = List.of(discovery.profiles)
        ..sort(HermesProfile.compareForDisplay);
      _hasRoster = true;
      _error = null;
      return true;
    } catch (_) {
      if (!_disposed && read == _readRevision) {
        _error =
            'The profile list could not be refreshed. Check the connection and retry.';
      }
      return !_disposed && read == _readRevision ? false : null;
    } finally {
      if (!_disposed && read == _readRevision) {
        _loading = false;
        _publish();
      }
    }
  }

  HermesProfile? _named(String name) =>
      _profiles.where((profile) => profile.name == name).firstOrNull;

  ProfilesManagementIntent? beginCreate() => _begin(_Operation.create);
  ProfilesManagementIntent? beginClone(String name) =>
      _begin(_Operation.clone, _named(name));
  ProfilesManagementIntent? beginRename(String name) =>
      _begin(_Operation.rename, _named(name));
  ProfilesManagementIntent? beginDelete(String name) =>
      _begin(_Operation.delete, _named(name));

  ProfilesManagementIntent? _begin(
    _Operation operation, [
    HermesProfile? profile,
  ]) {
    if (_disposed || !_hasRoster || _occupied) return null;
    if (operation != _Operation.create && profile == null) return null;
    if (operation == _Operation.delete && profile!.name == 'default') {
      return null;
    }
    _readRevision++;
    _loading = false;
    final intent = ProfilesManagementIntent._(operation, profile, ++_revision);
    _intent = intent;
    _error = null;
    _uncertain = false;
    _publish();
    return intent;
  }

  void updateName(ProfilesManagementIntent intent, String value) {
    if (!_has(intent) || _submitting || _uncertain) return;
    intent._name = value.trim();
    _error = null;
    _publish();
  }

  void cancel(ProfilesManagementIntent intent) {
    if (!_has(intent) || _submitting || _uncertain) return;
    _intent = null;
    _revision++;
    _error = null;
    _publish();
  }

  String? _validation(ProfilesManagementIntent intent) {
    if (intent._operation == _Operation.delete) return null;
    final name = intent._name;
    if (name.isEmpty) return 'Enter a profile name.';
    if (intent._operation == _Operation.rename &&
        intent._opening!.name == 'default') {
      return null;
    }
    if (_settlements.containsKey(name)) {
      return 'Identity cleanup is still pending for that name. Follow the server guidance first.';
    }
    if (!HermesProfile.isCanonicalName(name) || name == 'current') {
      return 'Use lowercase letters, numbers, hyphens or underscores (up to 64 characters).';
    }
    return null;
  }

  ProfilesManagementDraft _draft(ProfilesManagementIntent intent) {
    final profile = intent._opening;
    final display = profile?.name == 'default';
    final renaming = intent._operation == _Operation.rename;
    final deleting = intent._operation == _Operation.delete;
    final validation = _validation(intent);
    return ProfilesManagementDraft(
      title: switch (intent._operation) {
        _Operation.create => 'Create profile',
        _Operation.clone => 'Clone ${profile!.name}',
        _Operation.rename => 'Rename ${profile!.label}',
        _Operation.delete => 'Delete ${profile!.label}',
      },
      initialName: intent._name,
      help: display
          ? 'Display name. The default identity stays unchanged.'
          : 'Lowercase letters, numbers, hyphens or underscores.',
      needsName: !deleting,
      canContinue: !_submitting && !_uncertain && validation == null,
      canSubmit: !_submitting && !_uncertain && validation == null,
      canCancel: !_submitting && !_uncertain,
      needsConfirmation: renaming || deleting,
      confirmationTitle: '${deleting ? 'Delete' : 'Rename'} ${profile?.label}?',
      confirmationDetail: deleting
          ? 'This removes the profile and its retained data. A running profile gateway may be stopped.'
          : display
          ? 'Only the display name changes. The default profile keeps its identity.'
          : 'A running profile gateway may be stopped. Open editors will keep their original target.',
      confirmationAction: deleting ? 'Delete profile' : 'Rename',
      validationError: validation,
    );
  }

  Future<void> _preflight(ProfilesManagementIntent intent) async {
    final fresh = await _server.discover();
    if (!_has(intent)) throw const _Retired();
    final opening = intent._opening;
    if (opening != null) {
      final present = fresh.named(opening.name);
      if (present == null) {
        throw const _Conflict(
          'The source profile is no longer present. Cancel and review the list.',
        );
      }
      if (intent._operation == _Operation.rename &&
          opening.name == 'default' &&
          present.displayName != opening.displayName) {
        throw const _Conflict(
          'The display name changed elsewhere. Cancel and review before renaming.',
        );
      }
    }
    if (intent._operation != _Operation.delete &&
        !(intent._operation == _Operation.rename &&
            opening?.name == 'default') &&
        fresh.named(intent._name) != null &&
        !(intent._operation == _Operation.rename &&
            intent._name == opening!.name)) {
      throw const _Conflict(
        'That profile name is already in use. Choose another name.',
      );
    }
  }

  Future<ProfilesManagementOutcome?> submit(
    ProfilesManagementIntent intent,
  ) async {
    if (!_has(intent) ||
        _submitting ||
        _uncertain ||
        _validation(intent) != null) {
      return null;
    }
    _server.retain();
    _submitting = true;
    _error = null;
    _readRevision++;
    _loading = false;
    final revision = intent._revision;
    var dispatchActive = true, dispatched = false;
    bool canDispatch() => dispatchActive && _has(intent);
    try {
      _publish();
      await _preflight(intent);
      if (!canDispatch()) throw const _Retired();
      final operation = intent._operation;
      final source = intent._opening?.name;
      final method = switch (operation) {
        _Operation.create || _Operation.clone => 'POST',
        _Operation.rename => 'PATCH',
        _Operation.delete => 'DELETE',
      };
      final endpoint = source == null || operation == _Operation.clone
          ? 'profiles'
          : 'profiles/${Uri.encodeComponent(source)}';
      final body = switch (operation) {
        _Operation.create || _Operation.clone => <String, dynamic>{
          'name': intent._name,
          if (operation == _Operation.clone) 'clone_from': source!,
          'clone_all': false,
          'clone_channels': false,
        },
        _Operation.rename => <String, dynamic>{'new_name': intent._name},
        _Operation.delete => <String, dynamic>{},
      };
      final response = await _server.ownedMutation(
        method,
        endpoint,
        const {},
        body,
        canDispatch,
        () => dispatched = true,
      );
      final outcome = _acknowledge(intent, response);
      if (!_has(intent)) return outcome;
      _outcome = outcome;
      if (outcome.kind ==
          ProfilesManagementOutcomeKind.deletedSettlementPending) {
        _settlements[outcome.target] = outcome;
      }
      _intent = null;
      _submitting = false;
      _publish();
      final refreshed = await _readRoster(command: revision);
      if (_owns(revision) && refreshed == false) {
        _outcome = outcome.refreshFailed;
        _publish();
      }
      return outcome;
    } catch (failure) {
      final outcome = ProfilesManagementOutcome(
        sequence: revision,
        kind: dispatched
            ? ProfilesManagementOutcomeKind.uncertain
            : failure is _Conflict
            ? ProfilesManagementOutcomeKind.rejected
            : ProfilesManagementOutcomeKind.notSent,
        target: intent._operation == _Operation.delete
            ? intent._opening!.name
            : intent._name,
        message: failure is _Conflict
            ? failure.message
            : dispatched
            ? 'The change could not be confirmed. Refresh the list before deciding what to do next.'
            : 'The change was not sent. Your profile name is kept. Try again.',
      );
      if (_has(intent)) {
        _uncertain = dispatched;
        _outcome = outcome;
        _error = outcome.message;
      }
      return outcome;
    } finally {
      dispatchActive = false;
      _server.release();
      if (_owns(revision)) {
        _submitting = false;
        _publish();
      }
    }
  }

  ProfilesManagementOutcome _acknowledge(
    ProfilesManagementIntent intent,
    Map<String, dynamic> result,
  ) {
    if (result['ok'] != true ||
        result['path'] is! String ||
        (result['path'] as String).isEmpty) {
      throw const FormatException('Invalid profile acknowledgement');
    }
    final operation = intent._operation;
    final deleting = operation == _Operation.delete;
    final display =
        operation == _Operation.rename && intent._opening!.name == 'default';
    final target = deleting
        ? intent._opening!.name
        : display
        ? 'default'
        : intent._name;
    if (!deleting && result['name'] != target ||
        display && result['display_name'] != intent._name) {
      throw const FormatException('Profile acknowledgement target mismatch');
    }
    if (deleting && result.containsKey('settlement_pending')) {
      if (result['settlement_pending'] != true ||
          result['identity_settled'] != false ||
          result['retry_command'] is! String ||
          (result['retry_command'] as String).trim().isEmpty) {
        throw const FormatException(
          'Invalid pending profile identity settlement',
        );
      }
      return ProfilesManagementOutcome(
        sequence: intent._revision,
        kind: ProfilesManagementOutcomeKind.deletedSettlementPending,
        target: target,
        message:
            'Profile deleted, but identity cleanup is pending. Follow the server guidance before using its identity again.',
        manualGuidance: result['retry_command'] as String,
      );
    }
    if (deleting &&
        (result.containsKey('identity_settled') ||
            result.containsKey('retry_command'))) {
      throw const FormatException(
        'Unexpected profile identity settlement fields',
      );
    }
    return ProfilesManagementOutcome(
      sequence: intent._revision,
      kind: ProfilesManagementOutcomeKind.confirmed,
      target: target,
      message: switch (operation) {
        _Operation.create =>
          'Profile created. Open it to configure access and defaults.',
        _Operation.clone =>
          'Profile cloned. Check inherited access and defaults before using it.',
        _Operation.rename => 'Profile renamed.',
        _Operation.delete => 'Profile deleted.',
      },
    );
  }

  Future<bool> open(String name) async {
    if (_disposed || !_hasRoster || _occupied || _named(name) == null) {
      return false;
    }
    final revision = ++_revision;
    _readRevision++;
    _loading = false;
    _opening = true;
    _publish();
    try {
      final fresh = await _server.discover();
      if (!_owns(revision)) return false;
      if (fresh.named(name) == null) {
        throw const _Conflict(
          'The profile is no longer present. Refresh the list.',
        );
      }
      final opened = await _openProfile(name);
      return _owns(revision) && opened;
    } catch (failure) {
      if (_owns(revision)) {
        _error = failure is _Conflict
            ? failure.message
            : 'The profile could not be opened. Check the connection and retry.';
      }
      return false;
    } finally {
      if (_owns(revision)) {
        _opening = false;
        _publish();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    _readRevision++;
    _server.release();
    // Revocation and resource release are immediate. Notifier storage waits
    // only for an already-active notification stack to unwind.
    if (_notifications == 0) super.dispose();
  }
}

class _Conflict implements Exception {
  const _Conflict(this.message);
  final String message;
}

class _Retired implements Exception {
  const _Retired();
}
