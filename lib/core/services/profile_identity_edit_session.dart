import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/profile_identity_edit.dart';
import 'administration_repository.dart';

enum ProfileIdentitySaveOutcome { confirmed, partial, blocked, failed, retired }

class ProfileIdentityFieldState {
  const ProfileIdentityFieldState({
    required this.text,
    required this.enabled,
    required this.dirty,
    required this.issue,
    required this.conflicted,
    required this.serverText,
  });
  final String text;
  final bool enabled, dirty, conflicted;
  final String? issue, serverText;
}

class ProfileIdentityEditState {
  const ProfileIdentityEditState({
    required this.description,
    required this.soul,
    required this.scopeLabel,
    required this.connectionLabel,
    required this.loading,
    required this.saving,
    required this.hasObservation,
    required this.canSave,
    required this.dirtyCount,
    required this.error,
    required this.notice,
  });
  final ProfileIdentityFieldState description, soul;
  final String scopeLabel, connectionLabel;
  final bool loading, saving, hasObservation, canSave;
  final int dirtyCount;
  final String? error, notice;
}

class ProfileIdentityCloseDecision {
  const ProfileIdentityCloseDecision({
    required this.canClose,
    required this.needsDiscardConfirmation,
    required this.result,
  });
  final bool canClose, needsDiscardConfirmation, result;
}

/// One route owns drafts and opening observations. The borrowed repository owns
/// admitted HTTP work and its operation lease; disposal only revokes dispatch
/// and publication authority. Neither read retry nor conflict review replays PUT.
class ProfileIdentityEditSession extends ChangeNotifier {
  ProfileIdentityEditSession(this._profile) {
    _profile.server.retain();
    unawaited(load());
  }
  final ProfileAdministration _profile;
  final _baseline = <ProfileIdentityField, String>{};
  final _texts = <ProfileIdentityField, String>{};
  final _issues = <ProfileIdentityField, String>{};
  final _validation = <ProfileIdentityField, String>{};
  final _conflicts = <ProfileIdentityField, String>{};
  final _uncertain = <ProfileIdentityField>{};
  bool _disposed = false, _loading = true, _saving = false;
  bool _needsRefresh = false;
  int _generation = 0, _notificationDepth = 0;
  String? _error, _notice;

  bool _owns(int generation) => !_disposed && _generation == generation;
  void _emit() {
    if (_disposed) return;
    ++_notificationDepth;
    try {
      notifyListeners();
    } finally {
      --_notificationDepth;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  bool _dirty(ProfileIdentityField field) =>
      _baseline.containsKey(field) &&
      normalizeProfileIdentityText(field, _texts[field]!) != _baseline[field];
  bool _unsettled(ProfileIdentityField field) =>
      _dirty(field) || _uncertain.contains(field);
  bool _eligible(ProfileIdentityField field) =>
      _dirty(field) &&
      !_issues.containsKey(field) &&
      !_conflicts.containsKey(field) &&
      !_uncertain.contains(field) &&
      validateProfileIdentityText(field, _texts[field]!) == null;

  ProfileIdentityEditState get state {
    ProfileIdentityFieldState field(ProfileIdentityField key) =>
        ProfileIdentityFieldState(
          // Unknown text is an explicitly unavailable input, never a baseline.
          text: _texts[key] ?? '',
          enabled:
              !_disposed && !_loading && !_saving && _baseline.containsKey(key),
          dirty: _dirty(key),
          issue: _validation[key] ?? _issues[key],
          conflicted: _conflicts.containsKey(key),
          serverText: _conflicts[key],
        );
    return ProfileIdentityEditState(
      description: field(ProfileIdentityField.description),
      soul: field(ProfileIdentityField.soul),
      scopeLabel: _profile.label,
      connectionLabel: _profile.server.connectionLabel,
      loading: _loading,
      saving: _saving,
      hasObservation: _baseline.isNotEmpty,
      canSave:
          !_disposed &&
          !_loading &&
          !_saving &&
          ProfileIdentityField.values.any(_eligible),
      dirtyCount: ProfileIdentityField.values.where(_unsettled).length,
      error: _error,
      notice: _notice,
    );
  }

  Future<void> load() async {
    if (_disposed || _saving) return;
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _emit();
    try {
      final observation = await _profile.loadIdentity();
      if (!_owns(generation)) return;
      _observe(observation, reviewUncertain: true);
      if (_uncertain.isNotEmpty) {
        _error =
            'Review the checked values before saving again. Your edits are kept.';
      } else if (_baseline.isEmpty) {
        _error = 'This profile could not be loaded. Retry.';
      } else if (_issues.isNotEmpty) {
        _error = 'Some profile text could not be read. Retry to check it.';
      }
    } catch (_) {
      if (_owns(generation)) {
        _issues
          ..clear()
          ..addAll({
            for (final field in ProfileIdentityField.values)
              field: 'This field could not be checked. Retry.',
          });
        _error = 'This profile could not be loaded. Retry.';
      }
    } finally {
      if (_owns(generation)) {
        _loading = false;
        _emit();
      }
    }
  }

  void _observe(
    ProfileIdentityObservation observation, {
    required bool reviewUncertain,
  }) {
    _issues
      ..clear()
      ..addAll(observation.issues);
    for (final entry in observation.values.entries) {
      final field = entry.key;
      if (!_baseline.containsKey(field) || !_unsettled(field)) {
        if (_baseline.containsKey(field) && _baseline[field] != entry.value) {
          _needsRefresh = true;
        }
        _baseline[field] = entry.value;
        _texts[field] = entry.value;
      } else if (_uncertain.contains(field)) {
        if (!reviewUncertain) continue;
        if (entry.value ==
            normalizeProfileIdentityText(field, _texts[field]!)) {
          _baseline[field] = entry.value;
          _texts[field] = entry.value;
          _uncertain.remove(field);
          _conflicts.remove(field);
          _validation.remove(field);
          _notice = 'Current profile values checked.';
          _needsRefresh = true;
        } else {
          _conflicts[field] = entry.value;
        }
      } else if (entry.value ==
          normalizeProfileIdentityText(field, _texts[field]!)) {
        _baseline[field] = entry.value;
        _texts[field] = entry.value;
        _conflicts.remove(field);
        _validation.remove(field);
        _needsRefresh = true;
      } else if (entry.value != _baseline[field]) {
        _conflicts[field] = entry.value;
      } else {
        _conflicts.remove(field);
      }
    }
  }

  void edit(ProfileIdentityField field, String text) {
    if (_disposed || _loading || _saving || !_baseline.containsKey(field)) {
      return;
    }
    _texts[field] = text;
    final issue = validateProfileIdentityText(field, text);
    if (issue == null) {
      _validation.remove(field);
    } else {
      _validation[field] = issue;
    }
    if (_uncertain.isEmpty && _conflicts.isEmpty) _error = null;
    _notice = null;
    _emit();
  }

  void resolve(ProfileIdentityField field, {required bool useServer}) {
    if (_disposed || _saving || !_conflicts.containsKey(field)) return;
    final current = _conflicts.remove(field)!;
    if (_baseline[field] != current) _needsRefresh = true;
    _baseline[field] = current;
    _uncertain.remove(field);
    if (useServer) {
      _texts[field] = current;
      _validation.remove(field);
    }
    if (_uncertain.isEmpty && _conflicts.isEmpty) _error = null;
    _emit();
  }

  Future<ProfileIdentitySaveOutcome> save() async {
    if (_disposed) return ProfileIdentitySaveOutcome.retired;
    if (!state.canSave) return ProfileIdentitySaveOutcome.blocked;
    final intent = ProfileIdentityEditIntent(
      baseline: _baseline,
      wanted: {
        for (final field in ProfileIdentityField.values)
          if (_eligible(field)) field: _texts[field]!,
      },
    );
    final generation = ++_generation;
    final dispatched = <ProfileIdentityField>{};
    var dispatchAllowed = true;
    bool active() => dispatchAllowed && _owns(generation);
    _saving = true;
    _error = null;
    _notice = null;
    _emit();
    try {
      final result = await _profile.saveIdentity(
        intent,
        canDispatch: active,
        onDispatched: dispatched.add,
      );
      _needsRefresh =
          _needsRefresh ||
          result.fields.values.any(
            (field) =>
                field.disposition ==
                    ProfileIdentityWriteDisposition.confirmed ||
                field.disposition == ProfileIdentityWriteDisposition.converged,
          );
      if (!_owns(generation)) return ProfileIdentitySaveOutcome.retired;
      for (final field in intent.wanted.keys) {
        final outcome = result.fields[field];
        if (outcome == null) {
          _recordFailure(field, dispatched.contains(field));
          continue;
        }
        switch (outcome.disposition) {
          case ProfileIdentityWriteDisposition.confirmed:
          case ProfileIdentityWriteDisposition.converged:
            _baseline[field] = outcome.value!;
            _texts[field] = outcome.value!;
            _validation.remove(field);
            _issues.remove(field);
            _uncertain.remove(field);
          case ProfileIdentityWriteDisposition.conflict:
            _conflicts[field] = outcome.value!;
          case ProfileIdentityWriteDisposition.unavailable:
            _issues[field] = outcome.issue!;
          case ProfileIdentityWriteDisposition.uncertain:
            _uncertain.add(field);
            _validation[field] = outcome.issue!;
          case ProfileIdentityWriteDisposition.notSent:
          case ProfileIdentityWriteDisposition.rejected:
            _validation[field] = outcome.issue!;
        }
      }
      if (ProfileIdentityField.values.any(_unsettled)) {
        // Follow-up reads can refresh untouched fields, but never erase an ACK
        // or automatically resolve/replay a field whose delivery is uncertain.
        try {
          final observation = await _profile.loadIdentity();
          if (!_owns(generation)) return ProfileIdentitySaveOutcome.retired;
          _observe(observation, reviewUncertain: false);
        } catch (_) {
          // Known replacement acknowledgements stand independently of this read.
        }
      }
      final dirty = ProfileIdentityField.values.where(_unsettled).toList();
      if (dirty.isEmpty) return ProfileIdentitySaveOutcome.confirmed;
      if (_uncertain.isNotEmpty) {
        _error =
            'The save could not be confirmed. Your edits are still here; check the profile before saving again.';
      } else if (_conflicts.isNotEmpty) {
        _error =
            'This profile changed elsewhere. Review the changed fields; your edits are kept.';
      } else {
        _error = 'Some fields were not saved. Review them before trying again.';
      }
      if (result.hasConfirmedChanges) {
        _notice =
            'Saved: ${_labels(result.fields.entries.where((entry) => entry.value.disposition == ProfileIdentityWriteDisposition.confirmed).map((entry) => entry.key))}.';
        return ProfileIdentitySaveOutcome.partial;
      }
      return ProfileIdentitySaveOutcome.failed;
    } catch (_) {
      if (!_owns(generation)) return ProfileIdentitySaveOutcome.retired;
      for (final field in intent.wanted.keys) {
        _recordFailure(field, dispatched.contains(field));
      }
      _error = dispatched.isEmpty
          ? 'The save was not sent. Your edits are kept.'
          : 'The save could not be confirmed. Your edits are still here; check the profile before saving again.';
      return ProfileIdentitySaveOutcome.failed;
    } finally {
      dispatchAllowed = false;
      if (_owns(generation)) {
        _saving = false;
        _emit();
      }
    }
  }

  void _recordFailure(ProfileIdentityField field, bool dispatched) {
    if (dispatched) _uncertain.add(field);
    _validation[field] = dispatched
        ? 'This field could not be confirmed. Check the profile.'
        : 'This field was not sent. Your edit is kept.';
  }

  ProfileIdentityCloseDecision requestClose({bool discard = false}) {
    final dirty = ProfileIdentityField.values.any(_unsettled);
    final allowed = !_disposed && !_saving && (!dirty || discard);
    return ProfileIdentityCloseDecision(
      canClose: allowed,
      needsDiscardConfirmation: !_disposed && !_saving && dirty && !discard,
      result: _needsRefresh,
    );
  }

  static String _labels(Iterable<ProfileIdentityField> fields) => fields
      .map(
        (field) =>
            field == ProfileIdentityField.description ? 'description' : 'SOUL',
      )
      .join(', ');

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _profile.server.release();
    if (_notificationDepth == 0) super.dispose();
  }
}
