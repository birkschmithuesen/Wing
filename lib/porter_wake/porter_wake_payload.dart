import 'dart:convert';

/// The content-free push of the porter wake gate. Only [noticeId] is used, and
/// only in the notice URL.
class PorterWakePayload {
  const PorterWakePayload(this.noticeId);

  final String noticeId;

  static final _noticeId = RegExp(r'^n-[0-9a-f]{12}$');

  /// Null for anything that is not a v1 `porter_wake` push. Never throws.
  static PorterWakePayload? parse(List<int> bytes) {
    final Object? data;
    try {
      data = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (data is! Map || data['type'] != 'porter_wake' || data['v'] != 1) {
      return null;
    }
    final id = data['notice_id'];
    if (id is! String || !_noticeId.hasMatch(id)) return null;
    return PorterWakePayload(id);
  }
}
