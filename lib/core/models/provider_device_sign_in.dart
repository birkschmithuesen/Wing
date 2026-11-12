enum ProviderDeviceStatus {
  pending,
  approved,
  denied,
  expired,
  error,
  cancelled,
}

/// Current stock's attempt identity and display fields, bound to a captured route.
/// Poll responses must name this exact session before changing its state.
class ProviderDeviceSession {
  ProviderDeviceSession._(
    this.id,
    this.userCode,
    this.verificationUrl,
    this.pollInterval,
    this.deadline,
  );
  final String id, userCode;
  final Uri verificationUrl;
  final Duration pollInterval;
  final DateTime deadline;
  static const maximumLifetime = Duration(minutes: 15);

  /// Extracts only the canonical returned identity for cleanup. This cannot
  /// establish display validity, approval, or permission to replay a start.
  static String? returnedIdentity(Map<String, dynamic> data) {
    final value = data['session_id'];
    return value is String && value.isNotEmpty && value == value.trim()
        ? value
        : null;
  }

  factory ProviderDeviceSession.fromStart(
    Map<String, dynamic> data,
    DateTime now,
  ) {
    final id = returnedIdentity(data), code = data['user_code'];
    final url = data['verification_url'],
        expires = data['expires_in'],
        interval = data['poll_interval'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (data['flow'] != 'device_code' ||
        id == null ||
        code is! String ||
        code.isEmpty ||
        uri == null ||
        uri.host.isEmpty ||
        !{'http', 'https'}.contains(uri.scheme) ||
        expires is! int ||
        expires <= 0 ||
        interval is! int ||
        interval <= 0) {
      throw const FormatException('Unsupported sign-in session');
    }
    return ProviderDeviceSession._(
      id,
      code,
      uri,
      Duration(seconds: interval.clamp(3, 60)),
      now.add(Duration(seconds: expires.clamp(1, maximumLifetime.inSeconds))),
    );
  }
  ProviderDeviceStatus statusFromPoll(Map<String, dynamic> data) {
    if (data['session_id'] != id || data['status'] is! String) {
      throw const FormatException(
        'Sign-in session identity or status mismatch',
      );
    }
    return switch (data['status']) {
      'pending' => ProviderDeviceStatus.pending,
      'approved' => ProviderDeviceStatus.approved,
      'denied' => ProviderDeviceStatus.denied,
      'expired' => ProviderDeviceStatus.expired,
      'error' => ProviderDeviceStatus.error,
      'cancelled' => ProviderDeviceStatus.cancelled,
      _ => throw const FormatException('Unsupported sign-in status'),
    };
  }
}
