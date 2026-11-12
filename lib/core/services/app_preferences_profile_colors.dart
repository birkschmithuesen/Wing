part of 'app_preferences.dart';

/// This namespace borrows its owner's storage FIFO and has its own observation
/// channel. Colour-only work never publishes general app settings.
class _ProfileColorPreferences {
  _ProfileColorPreferences(this.owner);

  final AppPreferences owner;
  final _entries = <(String, String), _ProfileColorEntry>{};
  final _channels = <String, _ProfileColorChannel>{};

  String _key(String identity, String name) =>
      'profile_color_v1_${sha256.convert(utf8.encode(identity))}_$name';

  ValueListenable<ProfileColorsState> channel(String identity) =>
      _channels.putIfAbsent(
        identity,
        () => _ProfileColorChannel(ProfileColorsState(const {})),
      );

  void observe(String identity, String name) {
    if (identity.isEmpty || name.isEmpty) {
      throw ArgumentError(
        'A profile colour needs an exact connection and name',
      );
    }
    channel(identity);
    final target = (identity, name);
    final entry = _entries.putIfAbsent(target, _ProfileColorEntry.new);
    // A plugin write mutates its cache before acknowledgement. Rebinding a
    // consumer must never promote that optimistic value to a confirmed fact.
    if (entry.pending > 0 || entry.unverified || owner._reloadFailed) return;
    _readSettled(identity, name, entry);
  }

  void _readSettled(String identity, String name, _ProfileColorEntry entry) {
    if (entry.unverified || owner._reloadFailed) return;
    final key = _key(identity, name);
    final raw = owner._preferences.get(key);
    final choice = !owner._preferences.containsKey(key)
        ? ProfileColorChoice.automatic
        : raw is int
        ? ProfileColorChoice.values
              .where((choice) => choice.slot != null && choice.slot == raw)
              .firstOrNull
        : null;
    entry.invalid = choice == null;
    if (choice != null) entry.confirmed = choice;
  }

  void observeAll() {
    for (final (identity, name) in _entries.keys.toList()) {
      observe(identity, name);
    }
  }

  ProfileColorFact _fact(_ProfileColorEntry entry) {
    final unverified = entry.unverified || owner._reloadFailed;
    return ProfileColorFact(
      displayChoice: entry.confirmed,
      selected: entry.invalid || unverified ? null : entry.confirmed,
      busy: entry.pending > 0,
      notice: unverified
          ? 'Reload settings to verify this profile color.'
          : entry.invalid
          ? 'The saved color is invalid. Choose a color to repair it.'
          : null,
      error: owner._reloadFailed
          ? 'Could not reload settings. Please retry.'
          : switch (entry.failure) {
              AppPreferenceStorageFailure.saveFailed =>
                'Could not save the profile color.',
              AppPreferenceStorageFailure.restorationUnconfirmed =>
                'Could not verify the profile color. Reload settings.',
              null => null,
            },
      canChoose: !owner._closed && !unverified && entry.pending == 0,
      reloadVisible: unverified || owner._reloadRequests > 0,
      reloading: owner._reloadRequests > 0,
      reload: unverified && !owner._closed && owner._reloadRequests == 0
          ? _reload
          : null,
    );
  }

  Future<bool> _reload() async {
    try {
      await owner.reload();
      return true;
    } catch (_) {
      return false;
    }
  }

  void publish() {
    if (owner._closed) return;
    for (final channel in _channels.entries.toList()) {
      channel.value.publish(
        ProfileColorsState({
          for (final entry in _entries.entries)
            if (entry.key.$1 == channel.key) entry.key.$2: _fact(entry.value),
        }),
      );
    }
  }

  void freshlyReloaded() {
    for (final entry in _entries.values) {
      entry.unverified = false;
      if (entry.failure == AppPreferenceStorageFailure.restorationUnconfirmed) {
        entry.failure = null;
      }
    }
  }

  Future<void> choose(
    String identity,
    String name,
    ProfileColorChoice choice, {
    required bool Function() canWrite,
  }) {
    if (owner._closed || !canWrite()) return Future.value();
    observe(identity, name);
    final entry = _entries[(identity, name)]!;
    entry.pending++;
    entry.failure = null;
    // Reserve FIFO position before notifying reentrant listeners.
    final result = owner
        ._ordered(() async {
          if (owner._closed || !canWrite()) return;
          if (owner._reloadFailed || entry.unverified) {
            throw StateError('Reload settings before saving the profile color');
          }
          final key = _key(identity, name);
          final raw = owner._preferences.get(key);
          final previous = raw is List<String> ? List<String>.of(raw) : raw;
          final previouslyPresent = owner._preferences.containsKey(key);
          if (previous == choice.slot &&
              (choice.slot != null || !owner._preferences.containsKey(key))) {
            _readSettled(identity, name, entry);
            return;
          }
          try {
            if (!await owner._writeRaw(key, choice.slot)) {
              throw StateError('Storage did not confirm the profile color');
            }
          } catch (_) {
            var restored = false;
            try {
              restored = await owner._writeRaw(key, previous);
              if (previous == null && previouslyPresent) restored = false;
            } catch (_) {}
            entry.unverified = !restored;
            entry.failure = restored
                ? AppPreferenceStorageFailure.saveFailed
                : AppPreferenceStorageFailure.restorationUnconfirmed;
            _readSettled(identity, name, entry);
            throw StateError('The profile color could not be saved');
          }
          entry.unverified = false;
          entry.failure = null;
          _readSettled(identity, name, entry);
        })
        .whenComplete(() {
          entry.pending--;
          publish();
        });
    publish();
    return result;
  }

  void dispose() {
    for (final channel in _channels.values) {
      channel.dispose();
    }
  }
}

class _ProfileColorEntry {
  ProfileColorChoice? confirmed;
  bool invalid = false;
  bool unverified = false;
  int pending = 0;
  AppPreferenceStorageFailure? failure;
}

/// A listener can close the app owner during publication. Revoke immediately,
/// then dispose notifier storage once the current dispatch has returned.
class _ProfileColorChannel extends ValueNotifier<ProfileColorsState> {
  _ProfileColorChannel(super.value);
  bool _closed = false;
  int _dispatchDepth = 0;

  void publish(ProfileColorsState state) {
    if (_closed || mapEquals(value.profiles, state.profiles)) return;
    _dispatchDepth++;
    try {
      value = state;
    } finally {
      _dispatchDepth--;
      if (_closed && _dispatchDepth == 0) super.dispose();
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    if (_dispatchDepth == 0) super.dispose();
  }
}
