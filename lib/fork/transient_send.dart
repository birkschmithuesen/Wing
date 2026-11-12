/// Chats whose last queued prompt failed transiently before it was
/// submitted. Upstream pauses such a queue until the user taps Resume; in
/// hands-free conversation no Resume is reachable, so the fork resumes these
/// queues once on the next reconnect (spec Q6). Uncertain deliveries stay
/// upstream's (idempotent replay).
abstract final class TransientSend {
  static final Expando<bool> _marked = Expando<bool>('transientSend');

  static void mark(Object chat) => _marked[chat] = true;

  /// True once per mark.
  static bool take(Object chat) {
    final marked = _marked[chat] == true;
    _marked[chat] = null;
    return marked;
  }

  static final Expando<bool> _held = Expando<bool>('transientSendHold');

  /// While held, follow-ups of [chat] are not drained during a running turn.
  static void hold(Object chat) => _held[chat] = true;

  static bool holding(Object chat) => _held[chat] == true;

  static void release(Object chat) => _held[chat] = null;
}
