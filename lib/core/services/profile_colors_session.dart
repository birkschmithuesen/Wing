import 'package:flutter/foundation.dart';

import '../models/profile_colors.dart';
import 'app_preferences.dart';

/// The route owns admission and membership; the shared preferences owner owns
/// confirmed facts and the lifetime of already admitted storage operations.
class ProfileColorsSession {
  ProfileColorsSession({
    required AppPreferences preferences,
    required String connectionIdentity,
  }) : _preferences = preferences,
       _identity = connectionIdentity,
       state = preferences.profileColorsFor(connectionIdentity);

  final AppPreferences _preferences;
  final String _identity;
  final ValueListenable<ProfileColorsState> state;
  Set<String> _profiles = const {};
  final _pickers = <ProfileColorPicker>{};
  bool _closed = false;

  void updateProfiles(Iterable<String> names) {
    if (_closed) return;
    _profiles = Set.of(names);
    for (final picker in _pickers.toList()) {
      if (!_profiles.contains(picker._name)) picker.dispose();
    }
    for (final name in _profiles) {
      if (_closed) return;
      if (!_preferences.observeProfileColor(_identity, name)) {
        dispose();
        return;
      }
      if (_closed) return;
    }
  }

  ProfileColorPicker? beginChoice(String name) {
    if (_closed ||
        !_profiles.contains(name) ||
        state.value.profiles[name]?.busy != false) {
      return null;
    }
    final picker = ProfileColorPicker._(this, name);
    _pickers.add(picker);
    return picker;
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final picker in _pickers.toList()) {
      picker.dispose();
    }
  }
}

class ProfileColorPicker {
  ProfileColorPicker._(this._session, this._name);
  final ProfileColorsSession _session;
  final String _name;
  bool _closed = false;
  bool _submitted = false;

  ValueListenable<ProfileColorsState> get state => _session.state;
  ProfileColorFact get fact => state.value.profiles[_name]!;

  bool get _admitted =>
      !_closed && !_session._closed && _session._profiles.contains(_name);

  /// A retired picker is silent. Already admitted failures remain available to
  /// other consumers through the owner, without publishing to the old route.
  Future<String?> choose(ProfileColorChoice choice) async {
    if (!_admitted || _submitted) return null;
    _submitted = true;
    try {
      await _session._preferences.setProfileColor(
        _session._identity,
        _name,
        choice,
        canWrite: () => _admitted,
      );
      return null;
    } catch (_) {
      return _admitted ? fact.error ?? fact.notice : null;
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _session._pickers.remove(this);
  }
}
