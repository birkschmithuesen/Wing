// Shared monotonic origin for live receipts and their visible elapsed counters.
// Reading this clock never starts, completes or otherwise changes a tool call.
final _toolActivityClock = Stopwatch()..start();

Duration toolActivityNow() => _toolActivityClock.elapsed;
