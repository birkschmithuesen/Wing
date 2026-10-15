import 'dart:async';
import 'dart:collection';

/// Serializes replies that are read aloud automatically: a newer reply waits
/// behind whatever is already playing or queued instead of cutting it off
/// (spec 2026-10-15 — queue, don't interrupt).
///
/// Explicit user actions (microphone tap, stop, manual read-aloud, barge-in)
/// stay outside this queue; they call the player directly and then [clear]
/// whatever was still waiting.
class SpeechQueue {
  final _pending = Queue<_Entry>();
  bool _running = false;

  /// True once nothing is playing and nothing is waiting. A caller deciding
  /// whether to reopen the microphone should wait for this, not just for its
  /// own entry to settle — an entry queued behind it still has to speak.
  bool get isEmpty => !_running && _pending.isEmpty;

  /// Runs [speak] now if the queue is idle, otherwise appends it behind
  /// whatever is already speaking or queued; arrival order is speaking
  /// order. [onSettled] always fires with this entry's own result, right
  /// after [isEmpty] reflects whatever runs next (so a caller checking
  /// [isEmpty] from inside [onSettled] sees the true state, not a stale one).
  void add(Future<bool> Function() speak, void Function(bool finished) onSettled) {
    _pending.add(_Entry(speak, onSettled));
    if (!_running) _startNext();
  }

  /// Drops every entry still waiting; whatever is currently speaking keeps
  /// running until its own `speak` future resolves.
  void clear() => _pending.clear();

  void _startNext() {
    final entry = _pending.removeFirst();
    _running = true;
    unawaited(entry.speak().then((finished) => _settle(entry, finished)));
  }

  void _settle(_Entry entry, bool finished) {
    if (_pending.isEmpty) {
      _running = false;
    } else {
      _startNext();
    }
    entry.onSettled(finished);
  }
}

class _Entry {
  _Entry(this.speak, this.onSettled);
  final Future<bool> Function() speak;
  final void Function(bool finished) onSettled;
}
