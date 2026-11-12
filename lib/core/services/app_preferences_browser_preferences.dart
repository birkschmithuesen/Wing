part of 'app_preferences.dart';

/// Confirmed browser views share the app FIFO, not a second persistence queue.
class _BrowserPreferences {
  _BrowserPreferences(this.owner);
  final AppPreferences owner;
  final _entries = <String, _BrowserPreferencesEntry>{};

  _BrowserPreferencesEntry _entry(String identity) {
    ChatBrowserPreferencesCodec.storageKey(identity);
    final entry = _entries.putIfAbsent(identity, _BrowserPreferencesEntry.new);
    if (entry.pending.isEmpty && !entry.unverified && !owner._reloadFailed) {
      _read(identity, entry);
    }
    return entry;
  }

  void _read(String identity, _BrowserPreferencesEntry entry) {
    final key = ChatBrowserPreferencesCodec.storageKey(identity);
    try {
      final value = owner._preferences.containsKey(key)
          ? ChatBrowserPreferencesCodec.decode(owner._preferences.get(key))
          : ChatBrowserPreferences.fresh();
      entry.confirmed = value == entry.confirmed ? entry.confirmed : value;
      entry.invalid = false;
    } catch (_) {
      entry.invalid = true;
    }
  }

  BrowserPreferencesFact _fact(_BrowserPreferencesEntry entry) {
    final validity = owner._reloadFailed || entry.unverified
        ? BrowserPreferencesValidity.unverified
        : entry.invalid
        ? BrowserPreferencesValidity.invalid
        : BrowserPreferencesValidity.valid;
    var display = validity == BrowserPreferencesValidity.valid
        ? entry.confirmed
        : null;
    if (display != null) {
      ChatBrowserPreferences pendingDisplay = display;
      for (final intent in entry.pending) {
        pendingDisplay = pendingDisplay.apply(intent);
      }
      display = pendingDisplay;
    }
    return BrowserPreferencesFact(
      validity: validity,
      confirmed: entry.confirmed,
      display: display,
      busy: entry.pending.isNotEmpty || owner._reloadRequests > 0,
      error: switch (validity) {
        BrowserPreferencesValidity.unverified =>
          'Reload settings to verify the chat view.',
        BrowserPreferencesValidity.invalid =>
          'The saved chat view is invalid. Reset it to choose filters.',
        BrowserPreferencesValidity.valid =>
          entry.failed ? 'The view could not be saved on this device.' : null,
      },
    );
  }

  ValueListenable<BrowserPreferencesFact> channel(String identity) {
    final entry = _entry(identity);
    return entry.channel ??= _BrowserPreferencesChannel(_fact(entry));
  }

  Future<BrowserPreferencesSaveOutcome> choose(
    String identity,
    BrowserPreferenceIntent intent,
  ) {
    if (owner._closed) {
      return Future.value(BrowserPreferencesSaveOutcome.retired);
    }
    final entry = _entry(identity);
    entry.pending.add(intent);
    entry.failed = false;
    final settled = owner._ordered(() async {
      try {
        return await _save(identity, entry, intent);
      } catch (_) {
        entry.unverified = true;
        entry.failed = true;
        return BrowserPreferencesSaveOutcome.failedUnverified;
      } finally {
        // Remove the applied intention before the next admitted write starts.
        entry.pending.remove(intent);
        publish();
      }
    });
    // Reserve FIFO and pending intent before synchronous observer reentrancy.
    publish();
    return settled;
  }

  Future<BrowserPreferencesSaveOutcome> _save(
    String identity,
    _BrowserPreferencesEntry entry,
    BrowserPreferenceIntent intent,
  ) async {
    if (owner._closed) return BrowserPreferencesSaveOutcome.retired;
    if (owner._reloadFailed || entry.unverified) {
      return BrowserPreferencesSaveOutcome.blocked;
    }
    _read(identity, entry);
    final resetting = intent.operation == BrowserPreferenceOperation.reset;
    if (entry.invalid && !resetting) {
      return BrowserPreferencesSaveOutcome.blocked;
    }
    final target = resetting
        ? ChatBrowserPreferences.fresh()
        : entry.confirmed!.apply(intent);
    if (!entry.invalid && target == entry.confirmed) {
      return BrowserPreferencesSaveOutcome.unchanged;
    }
    final key = ChatBrowserPreferencesCodec.storageKey(identity);
    final raw = owner._preferences.get(key);
    final previous = raw is List<String> ? List<String>.of(raw) : raw;
    try {
      if (!await owner._writeRaw(key, jsonEncode(target.toJson()))) {
        throw StateError('Browser preference write was not acknowledged');
      }
    } catch (_) {
      var restored = false;
      try {
        restored = await owner._writeRaw(key, previous);
      } catch (_) {}
      entry.failed = true;
      entry.unverified = !restored;
      if (restored) _read(identity, entry);
      return restored
          ? BrowserPreferencesSaveOutcome.failedRestored
          : BrowserPreferencesSaveOutcome.failedUnverified;
    }
    entry.failed = false;
    _read(identity, entry);
    return BrowserPreferencesSaveOutcome.saved;
  }

  void observeAll() {
    for (final item in _entries.entries) {
      if (item.value.pending.isEmpty &&
          !item.value.unverified &&
          !owner._reloadFailed) {
        _read(item.key, item.value);
      }
    }
  }

  void freshlyReloaded() {
    for (final item in _entries.entries) {
      final entry = item.value;
      if (entry.unverified) entry.failed = false;
      entry.unverified = false;
      // This fresh read is inside the shared FIFO: older writes have settled,
      // and queued intentions have not begun their physical writes yet.
      _read(item.key, entry);
    }
  }

  void publish() {
    if (owner._closed) return;
    for (final entry in _entries.values.toList()) {
      entry.channel?.publish(_fact(entry));
    }
  }

  void dispose() {
    for (final entry in _entries.values) {
      entry.channel?.dispose();
    }
  }
}

class _BrowserPreferencesEntry {
  ChatBrowserPreferences? confirmed;
  bool invalid = false;
  bool unverified = false;
  bool failed = false;
  final pending = <BrowserPreferenceIntent>[];
  _BrowserPreferencesChannel? channel;
}

class _BrowserPreferencesChannel extends ValueNotifier<BrowserPreferencesFact> {
  _BrowserPreferencesChannel(super.value);
  bool _closed = false;
  int _depth = 0;
  void publish(BrowserPreferencesFact fact) {
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
