part of 'app_preferences.dart';

/// Remembered entry shares the app's existing command FIFO and store.
class _WorkspaceEntryPreferences {
  _WorkspaceEntryPreferences(this.owner) {
    observe();
  }

  final AppPreferences owner;
  String? _confirmedId;
  String? _requestedId;
  bool _absent = true;
  bool _invalid = false;
  bool _unverified = false;
  bool _failed = false;
  int _pending = 0;
  Future<WorkspaceEntrySettlement>? _latest;
  _WorkspaceEntryChannel? _channel;

  void observe() {
    if (_unverified || owner._reloadFailed) {
      return;
    }
    final present = owner._preferences.containsKey(
      WorkspaceEntryCodec.storageKey,
    );
    final id = WorkspaceEntryCodec.connectionId(
      owner._preferences.get(WorkspaceEntryCodec.storageKey),
    );
    _absent = !present;
    _invalid = present && id == null;
    if (!_invalid) {
      _confirmedId = id;
    }
  }

  WorkspaceEntryFact get fact {
    final validity = _unverified || owner._reloadFailed
        ? WorkspaceEntryValidity.unverified
        : _invalid
        ? WorkspaceEntryValidity.invalid
        : _absent
        ? WorkspaceEntryValidity.absent
        : WorkspaceEntryValidity.valid;
    return WorkspaceEntryFact(
      validity: validity,
      confirmedId: _confirmedId,
      requestedId: _requestedId,
      busy: _pending > 0,
      error: switch (validity) {
        WorkspaceEntryValidity.invalid =>
          'The saved instance choice is invalid. Choose an instance to repair it.',
        WorkspaceEntryValidity.unverified =>
          'Reload settings to verify the saved instance choice.',
        _ =>
          _failed
              ? 'Could not remember this instance. Choose it to retry.'
              : null,
      },
    );
  }

  ValueListenable<WorkspaceEntryFact> get channel =>
      _channel ??= _WorkspaceEntryChannel(fact);

  void freshlyReloaded() {
    if (_unverified) {
      _failed = false;
    }
    _unverified = false;
  }

  void publish() {
    if (!owner._closed) {
      _channel?.publish(fact);
    }
  }

  WorkspaceEntryAdmission admit(String id) {
    if (WorkspaceEntryCodec.connectionId(id) == null) {
      throw ArgumentError('A saved instance ID is required');
    }
    final behind = _pending > 0;
    _pending++;
    _requestedId = id;
    _failed = false;
    final operation = owner
        ._ordered(() => _save(id))
        .then(
          (value) => value,
          onError: (Object _, StackTrace _) {
            _failed = true;
            _unverified = true;
            return WorkspaceEntrySettlement(
              id,
              WorkspaceEntrySaveOutcome.failedUnverified,
            );
          },
        );
    final settled = operation.then((value) {
      _pending--;
      if (_pending == 0) {
        _requestedId = null;
      }
      publish();
      return value;
    });
    // Reserve the FIFO and latest receipt before any synchronous observer.
    _latest = settled;
    publish();
    return WorkspaceEntryAdmission(queuedBehindEntry: behind, settled: settled);
  }

  Future<WorkspaceEntrySettlement> _save(String id) async {
    if (owner._closed) {
      return WorkspaceEntrySettlement(id, WorkspaceEntrySaveOutcome.retired);
    }
    if (_unverified || owner._reloadFailed) {
      return WorkspaceEntrySettlement(
        id,
        WorkspaceEntrySaveOutcome.failedUnverified,
      );
    }
    final raw = owner._preferences.get(WorkspaceEntryCodec.storageKey);
    final previous = raw is List<String> ? List<String>.of(raw) : raw;
    final present = owner._preferences.containsKey(
      WorkspaceEntryCodec.storageKey,
    );
    if (present && previous == id) {
      observe();
      return WorkspaceEntrySettlement(id, WorkspaceEntrySaveOutcome.unchanged);
    }
    try {
      if (!await owner._writeRaw(WorkspaceEntryCodec.storageKey, id)) {
        throw StateError('Storage did not confirm the instance choice');
      }
    } catch (_) {
      var restored = false;
      try {
        restored = await owner._writeRaw(
          WorkspaceEntryCodec.storageKey,
          previous,
        );
        if (present && previous == null) {
          restored = false;
        }
      } catch (_) {}
      _failed = true;
      _unverified = !restored;
      if (restored) {
        observe();
      }
      return WorkspaceEntrySettlement(
        id,
        restored
            ? WorkspaceEntrySaveOutcome.failedRestored
            : WorkspaceEntrySaveOutcome.failedUnverified,
      );
    }
    _failed = false;
    observe();
    return WorkspaceEntrySettlement(id, WorkspaceEntrySaveOutcome.saved);
  }

  Future<WorkspaceEntrySettlement> settle() async {
    while (true) {
      final latest = _latest;
      if (latest == null) {
        throw StateError('No instance choice has been admitted');
      }
      final result = await latest;
      if (identical(latest, _latest) && _pending == 0) {
        return result;
      }
    }
  }

  void dispose() => _channel?.dispose();
}

class _WorkspaceEntryChannel extends ValueNotifier<WorkspaceEntryFact> {
  _WorkspaceEntryChannel(super.value);
  bool _closed = false;
  int _depth = 0;

  void publish(WorkspaceEntryFact fact) {
    if (_closed || value == fact) {
      return;
    }
    _depth++;
    try {
      value = fact;
    } finally {
      _depth--;
      if (_closed && _depth == 0) {
        super.dispose();
      }
    }
  }

  @override
  void dispose() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_depth == 0) {
      super.dispose();
    }
  }
}
