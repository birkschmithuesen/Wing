/// Device-network loss as reported by the platform; while lost, the server is
/// shown offline at once.
class NetworkGate {
  NetworkGate(this._changed);

  final void Function() _changed;

  /// The device's own network, reported by the OS (not a server probe). This
  /// overrides an in-flight recovery: a reconnect attempt can look promising
  /// while the radio is still down, and the stock backoff budget (up to 31 s
  /// over 5 attempts) is far slower than the OS's own loss notice.
  bool _available = true;
  bool get available => _available;

  /// The OS reports the device has no network at all (e.g. airplane mode).
  /// Deliberately not cleared by `accessAvailable`: a reconnect attempt can
  /// succeed against a transport the OS itself has not vouched for (a stale
  /// socket, a route the radio state doesn't actually govern), which is the
  /// exact failure this guards against. Only an explicit [restored] call, from
  /// the same OS notice, lifts it.
  void lost() {
    _available = false;
    _changed();
  }

  void restored() {
    _available = true;
    _changed();
  }
}
