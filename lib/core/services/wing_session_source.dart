/// Which session `source` Wing reports to the Hermes gateway.
///
/// Stock Hermes knows Wing only as `desktop`, the same as the Mac app. A
/// gateway that handles Wing's own source lists it in `gateway.ready`
/// (`payload.session_sources`); only then does Wing send `wing`, so an
/// unmodified gateway sees exactly the traffic it always saw.
library;

const String wingSessionSource = 'wing';
const String desktopSessionSource = 'desktop';

/// Whether this `gateway.ready` frame advertises the `wing` session source.
/// Any other shape fails closed to today's `desktop` behaviour.
bool gatewayAdvertisesWingSource(Map<String, dynamic> readyFrame) {
  final params = readyFrame['params'];
  if (params is! Map) return false;
  final payload = params['payload'];
  if (payload is! Map) return false;
  final sources = payload['session_sources'];
  return sources is List && sources.contains(wingSessionSource);
}
