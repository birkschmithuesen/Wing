import 'package:http/http.dart' as http;

enum DashboardCredentialKind { cookie, token }

/// Ephemeral sign-in for one captured saved authority. Each origin and auth
/// mode has its own credential; HTTP transports still belong to their readers.
class DashboardAuthentication {
  final _credentials =
      <(String, DashboardCredentialKind), _DashboardCredential>{};

  Future<String> credential({
    required String baseUrl,
    required DashboardCredentialKind kind,
    required Future<String> Function() authenticate,
    required bool Function() isActive,
  }) async {
    final state = _credentials.putIfAbsent((
      baseUrl,
      kind,
    ), _DashboardCredential.new);
    if (state.value case final value?) return value;
    if (state.pending case final pending?) {
      try {
        return await pending.result;
      } on http.RequestAbortedException {
        // Replace only a request physically canceled by a departing reader.
        // Authentication rejection and ordinary transport failures propagate.
        if (pending.isActive() || !isActive()) rethrow;
        return credential(
          baseUrl: baseUrl,
          kind: kind,
          authenticate: authenticate,
          isActive: isActive,
        );
      }
    }
    final pending = _DashboardSignIn(authenticate(), isActive);
    state.pending = pending;
    try {
      return state.value = await pending.result;
    } finally {
      if (identical(state.pending, pending)) state.pending = null;
    }
  }

  void reject(String baseUrl, DashboardCredentialKind kind, String? rejected) {
    final state = _credentials[(baseUrl, kind)];
    // A delayed 401 must not discard a newer sign-in or its in-flight renewal.
    if (state != null && state.value == rejected) state.value = null;
  }
}

class _DashboardCredential {
  String? value;
  _DashboardSignIn? pending;
}

class _DashboardSignIn {
  _DashboardSignIn(this.result, this.isActive);
  final Future<String> result;
  final bool Function() isActive;
}
