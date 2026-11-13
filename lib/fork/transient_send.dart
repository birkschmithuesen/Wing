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

  /// True while [chat] is marked and not yet resumed.
  static bool marked(Object chat) => _marked[chat] == true;

  static final Expando<bool> _held = Expando<bool>('transientSendHold');
  static final Expando<bool> _spent = Expando<bool>('transientSendSpent');

  /// The held chat's one admission was made (a drain submit or the replay of
  /// its uncertain head); follow-ups wait for that turn.
  static void spend(Object chat) => _spent[chat] = true;

  static bool spent(Object chat) => _spent[chat] == true;

  /// While held, follow-ups of [chat] are not drained during a running turn.
  static void hold(Object chat) => _held[chat] = true;

  static bool holding(Object chat) => _held[chat] == true;

  static void release(Object chat) {
    _held[chat] = null;
    _spent[chat] = null;
  }
}
