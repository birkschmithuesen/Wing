import 'ws_client.dart';

/// Refusal classification for the Hermes gateway's canonical session
/// contract (spec docs/superpowers/specs/2026-11-13-wing-create-surface-design.md
/// §4.3, hermes-agent branch wt/t_35b15524). A refusal is `error.code == 4001`
/// with `error.data.reason` always present, except [isFinalGatewayRefusal]'s
/// profile_unavailable case which uses code 4064.
///
/// FINAL: retrying the exact same frame can never succeed; the caller must
/// stop (and, for a profile identity, remember that this gateway refuses it).
///
/// Known FINAL reasons for 4001 (non-exhaustive; documentation only). The
/// contract guarantees every 4001 refusal is either RETRYABLE or FINAL, so
/// [isFinalGatewayRefusal] treats any 4001 that isn't RETRYABLE as FINAL,
/// rather than trusting this allowlist alone.
const finalGatewayRefusalReasons = {
  'profile_mismatch',
  'not_found',
  'invalid_params',
  'permission_denied',
  'unsupported_projection',
  'runtime_retired',
};

bool isFinalGatewayRefusal(Object error) {
  if (error is! JsonRpcError) return false;
  if (error.code == 4064) return error.reason == 'profile_unavailable';
  return error.code == 4001 && !isRetryableGatewayRefusal(error);
}

/// RETRYABLE: the same frame may succeed later with the existing backoff.
bool isRetryableGatewayRefusal(Object error) {
  if (error is! JsonRpcError) return false;
  if (error.code == 4001) return error.reason == 'runtime_draining';
  if (error.code == 5001) return error.reason == 'storage_unavailable';
  return false;
}
