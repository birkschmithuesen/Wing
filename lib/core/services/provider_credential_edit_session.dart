import 'package:flutter/foundation.dart';
import '../models/provider_inventory.dart';
import 'administration_repository.dart';

enum ProviderCredentialOutcome {
  saved,
  removed,
  failed,
  uncertain,
  retired,
  blocked,
}

/// The entered secret exists only in this route's draft and the captured request.
/// Env observations are whitelisted metadata; no reveal/read-secret operation is
/// available. Stock cannot compare a credential version atomically.
class ProviderCredentialEditSession extends ChangeNotifier {
  ProviderCredentialEditSession(
    this.profile, {
    required this.key,
    required bool isSet,
  }) : _baselineIsSet = isSet {
    if (key.isEmpty) {
      throw ArgumentError.value(key);
    }
    profile.server.retain();
  }

  bool get busy => _busy;
  bool get reviewRequired => _reviewRequired;
  String? get error => _error;
  final ProfileAdministration profile;
  final String key;
  bool _baselineIsSet;
  String _draft = '';
  bool _busy = false, _reviewRequired = false, _disposed = false;
  String? _error;
  int _generation = 0;
  String get draft => _draft;
  bool get dirty => _draft.isNotEmpty;
  bool get isSet => _baselineIsSet;
  bool get canSave =>
      !_disposed && !_busy && !_reviewRequired && _draft.trim().isNotEmpty;
  bool get canRemove => !_disposed && !_busy && !_reviewRequired && isSet;
  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  bool _owns(int generation) => !_disposed && generation == _generation;
  void setDraft(String value) {
    if (_disposed || _busy) {
      return;
    }
    _draft = value;
    if (!_reviewRequired) {
      _error = null;
    }
    _changed();
  }

  Future<ProviderEnvironmentField> _observe() async {
    final fields = ProviderEnvironmentField.fromResponse(
      await profile.read('env'),
    );
    final field = fields.where((field) => field.key == key).firstOrNull;
    if (field == null || !field.editable) {
      throw const AdministrationFailure(
        'This key belongs to another settings owner. Your draft is kept.',
      );
    }
    return field;
  }

  Future<ProviderCredentialOutcome> save({required bool remove}) async {
    if (remove ? !canRemove : !canSave) {
      return ProviderCredentialOutcome.blocked;
    }
    final generation = ++_generation;
    final value = _draft.trim();
    var dispatchActive = true, dispatched = false, rejected = false;
    bool active() => dispatchActive && _owns(generation);
    _busy = true;
    _error = null;
    _changed();
    profile.server.retain();
    try {
      final latest = await _observe();
      if (!active()) {
        return ProviderCredentialOutcome.retired;
      }
      if (latest.isSet != _baselineIsSet) {
        _reviewRequired = true;
        throw const AdministrationFailure(
          'The stored key state changed. Refresh and review before saving. Your draft is kept.',
        );
      }
      await profile.requireProfile();
      if (!active()) {
        return ProviderCredentialOutcome.retired;
      }
      final result = await profile.server.ownedMutation(
        remove ? 'DELETE' : 'PUT',
        'env',
        {'profile': profile.name},
        {'key': key, 'profile': profile.name, if (!remove) 'value': value},
        active,
        () => dispatched = true,
      );
      rejected = result['ok'] == false;
      if (result['ok'] != true || result['key'] != key) {
        throw const AdministrationFailure(
          'Credential change was not confirmed.',
        );
      }
      final saved = await _observe();
      if (saved.isSet == remove) {
        throw const AdministrationFailure(
          'Credential state could not be confirmed.',
        );
      }
      if (!_owns(generation)) {
        return ProviderCredentialOutcome.retired;
      }
      _baselineIsSet = saved.isSet;
      _draft = '';
      _reviewRequired = false;
      return remove
          ? ProviderCredentialOutcome.removed
          : ProviderCredentialOutcome.saved;
    } catch (failure) {
      if (!_owns(generation)) {
        return ProviderCredentialOutcome.retired;
      }
      if (dispatched && !rejected) {
        _reviewRequired = true;
        _error =
            'Credential change not confirmed. Your draft is kept. Refresh and review before trying again.';
        return ProviderCredentialOutcome.uncertain;
      }
      _error = administrationError(failure, writing: true);
      return ProviderCredentialOutcome.failed;
    } finally {
      dispatchActive = false;
      profile.server.release();
      if (_owns(generation)) {
        _busy = false;
        _changed();
      }
    }
  }

  /// A metadata review cannot establish the submitted secret's exact value.
  /// It permits a later explicit action; it never automatically resends a key.
  Future<void> review() async {
    if (_disposed || _busy || !_reviewRequired) {
      return;
    }
    final generation = ++_generation;
    _busy = true;
    _changed();
    try {
      final latest = await _observe();
      if (!_owns(generation)) {
        return;
      }
      _baselineIsSet = latest.isSet;
      _reviewRequired = false;
      _error = null;
    } catch (failure) {
      if (_owns(generation)) {
        _error = administrationError(failure);
      }
    } finally {
      if (_owns(generation)) {
        _busy = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    _draft = '';
    profile.server.release();
    super.dispose();
  }
}
