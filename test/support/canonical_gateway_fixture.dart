/// Fixed authority metadata for isolated stock-contract fixtures. These values
/// are observations; tests varying fences or replay ordering supply their own.
const canonicalSnapshotFields = <String, dynamic>{
  'revision': 0,
  'execution_generation': 0,
  'authority_epoch': 1,
  'replay_epoch': 'fixture-epoch',
  'last_sequence': 0,
  'subscription_id': 'fixture-subscription',
  'pending': <Map<String, dynamic>>[],
};

Map<String, dynamic> canonicalReceipt(
  Map<String, dynamic> params, {
  required String admissionId,
  int sequence = 1,
  String? status,
}) => {
  'admission_id': admissionId,
  'input_id': params['submission_id'],
  'ref': {
    'profile_id': '/fixture/${params['profile']}',
    'session_id': params['session_id'],
  },
  'sequence': sequence,
  'status': status ?? (params['queued'] == true ? 'queued' : 'started'),
  'outcome': null,
  'authority_epoch': 1,
  'execution_generation': 0,
  'text': params['text'],
  'controls': params['attachments'] == null ? ['steer', 'replace'] : <String>[],
};
