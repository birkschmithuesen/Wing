part of 'app_preferences.dart';

/// Restart choices borrow the app owner's FIFO; navigation has no storage queue.
class _ProfileSelectionPreferences {
  _ProfileSelectionPreferences(this.owner);
  final AppPreferences owner;
  final _entries = <String, _ProfileSelectionEntry>{};

  _ProfileSelectionEntry _entry(String identity) {
    ProfileSelectionCodec.storageKey(identity);
    final entry = _entries.putIfAbsent(identity, _ProfileSelectionEntry.new);
    if (entry.pending == 0 && !entry.unverified && !owner._reloadFailed) {
      _read(identity, entry);
    }
    return entry;
  }

  void _read(String identity, _ProfileSelectionEntry entry) {
    final key = ProfileSelectionCodec.storageKey(identity);
    final present = owner._preferences.containsKey(key);
    final name = ProfileSelectionCodec.canonicalName(
      owner._preferences.get(key),
    );
    entry.invalid = present && name == null;
    entry.absent = !present;
    if (!entry.invalid) {
      if (entry.confirmedName != name) entry.unavailable = false;
      entry.confirmedName = name;
    }
  }

  ProfileSelectionFact _fact(_ProfileSelectionEntry entry) {
    final unverified = entry.unverified || owner._reloadFailed;
    final validity = unverified
        ? ProfileSelectionValidity.unverified
        : entry.invalid
        ? ProfileSelectionValidity.invalid
        : entry.unavailable
        ? ProfileSelectionValidity.unavailable
        : entry.absent
        ? ProfileSelectionValidity.absent
        : ProfileSelectionValidity.valid;
    return ProfileSelectionFact(
      validity: validity,
      confirmedName: entry.confirmedName,
      requestedName: entry.requestedName,
      busy: entry.pending > 0,
      error: switch (validity) {
        ProfileSelectionValidity.invalid =>
          'The saved profile selection is invalid. Choose a profile to repair it.',
        ProfileSelectionValidity.unavailable =>
          'The saved profile is unavailable. Choose an available profile.',
        ProfileSelectionValidity.unverified =>
          'Reload settings to verify the saved profile selection.',
        _ =>
          entry.failed
              ? 'Could not save the restart profile. Choose the profile to retry.'
              : null,
      },
    );
  }

  ValueListenable<ProfileSelectionFact> channel(String identity) {
    final entry = _entry(identity);
    return entry.channel ??= _ProfileSelectionChannel(_fact(entry));
  }

  String initial(String identity, Iterable<String> names, String preferred) {
    final available = names.toSet();
    if (available.isEmpty ||
        !available.contains(preferred) ||
        available.any((name) => !HermesProfile.isCanonicalName(name))) {
      throw ArgumentError(
        'Initial selection requires a valid fresh profile roster',
      );
    }
    final entry = _entry(identity);
    entry.unavailable =
        entry.confirmedName != null && !available.contains(entry.confirmedName);
    publish();
    final observed = _fact(entry);
    if (observed.validity == ProfileSelectionValidity.absent) return preferred;
    if (observed.validity == ProfileSelectionValidity.valid) {
      return observed.confirmedName!;
    }
    throw ProfileSelectionRepairRequired(observed.error!);
  }

  void observeAll() {
    for (final identity in _entries.keys.toList()) {
      final entry = _entries[identity]!;
      // A fresh reload is ordered behind admitted writes, so these are settled.
      if (!entry.unverified && !owner._reloadFailed) {
        _read(identity, entry);
      }
    }
  }

  void freshlyReloaded() {
    for (final entry in _entries.values) {
      if (entry.unverified) entry.failed = false;
      entry.unverified = false;
    }
  }

  void publish() {
    if (owner._closed) return;
    for (final entry in _entries.values.toList()) {
      entry.channel?.publish(_fact(entry));
    }
  }

  ProfileSelectionAdmission admit(String identity, String name) {
    if (!HermesProfile.isCanonicalName(name)) {
      throw ArgumentError('The restart profile must have a canonical name');
    }
    final entry = _entry(identity);
    final behind = entry.pending > 0;
    entry.pending++;
    entry.requestedName = name;
    entry.failed = false;
    final result = owner
        ._ordered(() => _save(identity, name, entry))
        .then(
          (settlement) => settlement,
          onError: (Object _, StackTrace _) {
            entry.unverified = true;
            entry.failed = true;
            return ProfileSelectionSettlement(
              name,
              ProfileSelectionSaveOutcome.failedUnverified,
            );
          },
        );
    final settled = result.then((settlement) {
      entry.pending--;
      if (entry.pending == 0) entry.requestedName = null;
      publish();
      return settlement;
    });
    // Reserve both FIFO and exact-identity receipt before reentrant observers.
    entry.latest = settled;
    publish();
    return ProfileSelectionAdmission(
      queuedBehindSelection: behind,
      settled: settled,
    );
  }

  Future<ProfileSelectionSettlement> _save(
    String identity,
    String name,
    _ProfileSelectionEntry entry,
  ) async {
    if (owner._closed) {
      return ProfileSelectionSettlement(
        name,
        ProfileSelectionSaveOutcome.retired,
      );
    }
    if (owner._reloadFailed || entry.unverified) {
      return ProfileSelectionSettlement(
        name,
        ProfileSelectionSaveOutcome.failedUnverified,
      );
    }
    final key = ProfileSelectionCodec.storageKey(identity);
    final raw = owner._preferences.get(key);
    final previous = raw is List<String> ? List<String>.of(raw) : raw;
    final present = owner._preferences.containsKey(key);
    if (present && previous == name) {
      entry.unavailable = false;
      _read(identity, entry);
      return ProfileSelectionSettlement(
        name,
        ProfileSelectionSaveOutcome.unchanged,
      );
    }
    try {
      if (!await owner._writeRaw(key, name)) {
        throw StateError('Storage did not confirm the restart profile');
      }
    } catch (_) {
      var restored = false;
      try {
        restored = await owner._writeRaw(key, previous);
        if (previous == null && present) restored = false;
      } catch (_) {}
      entry.failed = true;
      entry.unverified = !restored;
      if (restored) _read(identity, entry);
      return ProfileSelectionSettlement(
        name,
        restored
            ? ProfileSelectionSaveOutcome.failedRestored
            : ProfileSelectionSaveOutcome.failedUnverified,
      );
    }
    entry.unavailable = false;
    entry.failed = false;
    _read(identity, entry);
    return ProfileSelectionSettlement(name, ProfileSelectionSaveOutcome.saved);
  }

  Future<ProfileSelectionSettlement> settle(String identity) async {
    final entry = _entry(identity);
    while (true) {
      final latest = entry.latest;
      if (latest == null) {
        throw StateError('No profile selection has been admitted');
      }
      final result = await latest;
      // An observer can admit another choice during settlement publication.
      if (identical(latest, entry.latest) && entry.pending == 0) return result;
    }
  }

  void dispose() {
    for (final entry in _entries.values) {
      entry.channel?.dispose();
    }
  }
}

class _ProfileSelectionEntry {
  String? confirmedName;
  String? requestedName;
  bool absent = true;
  bool invalid = false;
  bool unavailable = false;
  bool unverified = false;
  bool failed = false;
  int pending = 0;
  Future<ProfileSelectionSettlement>? latest;
  _ProfileSelectionChannel? channel;
}

class _ProfileSelectionChannel extends ValueNotifier<ProfileSelectionFact> {
  _ProfileSelectionChannel(super.value);
  bool _closed = false;
  int _depth = 0;
  void publish(ProfileSelectionFact fact) {
    if (_closed || value == fact) return;
    _depth++;
    try {
      value = fact;
    } finally {
      _depth--;
      if (_closed && _depth == 0) super.dispose();
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    if (_depth == 0) super.dispose();
  }
}
