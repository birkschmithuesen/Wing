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

  /// True once nothing is playing and nothing is waiting.
  bool get isEmpty => !_running && _pending.isEmpty;

  /// Runs [speak] now if the queue is idle, otherwise appends it behind
  /// whatever is already speaking or queued. [onSettled] fires with this
  /// entry's own result, but only when it is the last one left once it
  /// finishes — an entry a newer one overtook settles silently.
  void add(Future<bool> Function() speak, void Function(bool finished) onSettled) {
    _pending.add(_Entry(speak, onSettled));
    if (!_running) _drain();
  }

  /// Drops every entry still waiting; whatever is currently speaking keeps
  /// running until its own `speak` future resolves.
  void clear() => _pending.clear();

  void _drain() {
    if (_pending.isEmpty) {
      _running = false;
      return;
    }
    _running = true;
    final entry = _pending.removeFirst();
    unawaited(
      entry.speak().then((finished) {
        if (_pending.isEmpty) entry.onSettled(finished);
        _drain();
      }),
    );
  }
}

class _Entry {
  _Entry(this.speak, this.onSettled);
  final Future<bool> Function() speak;
  final void Function(bool finished) onSettled;
}
