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
}
