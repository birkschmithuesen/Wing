import 'dart:convert';

enum GatewaySensitivePromptKind {
  sudo,
  secret,
  vaultUnlock,
  vaultSaveLogin,
  vaultCode,
}

/// A request-ID keyed sensitive prompt emitted by Hermes.
///
/// Values entered by the user are intentionally not part of this model so they
/// cannot be retained alongside chat or connection state.
class GatewaySensitivePromptRequest {
  final GatewaySensitivePromptKind kind;
  final String requestId;
  final String title;
  final String description;
  final String fieldLabel;

  const GatewaySensitivePromptRequest({
    required this.kind,
    required this.requestId,
    required this.title,
    required this.description,
    required this.fieldLabel,
  });

  /// Validate transient input without retaining secret response values.
  bool canRespond({required String value, required String password}) =>
      switch (kind) {
        GatewaySensitivePromptKind.vaultSaveLogin =>
          value.trim().isNotEmpty && password.isNotEmpty,
        GatewaySensitivePromptKind.vaultCode => normalizeResponseValue(
          value,
        ).isNotEmpty,
        _ => value.isNotEmpty,
      };

  /// The stock server-response value. Password and ordinary secret bytes are exact.
  String responseValue({required String value, required String password}) =>
      switch (kind) {
        GatewaySensitivePromptKind.vaultSaveLogin => jsonEncode({
          'identifier': value.trim(),
          'password': password,
        }),
        GatewaySensitivePromptKind.vaultCode => normalizeResponseValue(value),
        _ => value,
      };

  String normalizeResponseValue(String value) =>
      kind == GatewaySensitivePromptKind.vaultCode
      ? value.replaceAll(RegExp(r'[\s-]'), '')
      : value;

  static GatewaySensitivePromptKind? kindForMethod(String? method) =>
      switch (method) {
        'sudo' => GatewaySensitivePromptKind.sudo,
        'secret' => GatewaySensitivePromptKind.secret,
        'vault.unlock_prompt' => GatewaySensitivePromptKind.vaultUnlock,
        'vault.save_login' => GatewaySensitivePromptKind.vaultSaveLogin,
        'vault.code' => GatewaySensitivePromptKind.vaultCode,
        _ => null,
      };

  /// Parses an entry in the server's open_requests snapshot. Only display
  /// metadata is retained; secret response values never belong in this model.
  static GatewaySensitivePromptRequest? fromServerRequest(Object? value) {
    if (value is! Map) return null;
    final method = value['method'];
    final kind = method is String ? kindForMethod(method) : null;
    final id = value['id'];
    final params = value['params'];
    if (kind == null || id is! String || id.trim().isEmpty || params is! Map) {
      return null;
    }
    if (params.keys.any((key) => key is! String)) return null;
    final optional = switch (kind) {
      GatewaySensitivePromptKind.sudo => const <String>{},
      GatewaySensitivePromptKind.secret => const {
        'prompt',
        'env_var',
        'metadata',
      },
      GatewaySensitivePromptKind.vaultUnlock => const {
        'backend',
        'display_name',
      },
      GatewaySensitivePromptKind.vaultSaveLogin => const {'origin', 'site'},
      GatewaySensitivePromptKind.vaultCode => const {'site', 'hint'},
    };
    if (params.keys.any(
      (key) => key != 'session_id' && !optional.contains(key),
    )) {
      return null;
    }
    for (final key in optional) {
      if (key == 'metadata') continue;
      if (params.containsKey(key) && !_validSnapshotString(params[key])) {
        return null;
      }
    }
    return fromEventData(
      kind: kind,
      data: {...Map<String, dynamic>.from(params), 'request_id': id},
    );
  }

  static bool _validSnapshotString(Object? value) {
    if (value is! String) return false;
    return value.length <= 512 && value.trim() == value;
  }

  static GatewaySensitivePromptRequest? fromEventData({
    required GatewaySensitivePromptKind kind,
    required Map<String, dynamic> data,
  }) {
    final requestId = data['request_id']?.toString().trim() ?? '';
    if (requestId.isEmpty) return null;

    String metadata(String key) => data[key]?.toString().trim() ?? '';
    switch (kind) {
      case GatewaySensitivePromptKind.sudo:
        return GatewaySensitivePromptRequest(
          kind: kind,
          requestId: requestId,
          title: 'Administrator password needed',
          description:
              'Hermes needs a sudo password for the pending terminal command.',
          fieldLabel: 'Sudo password',
        );
      case GatewaySensitivePromptKind.secret:
        final envVar = metadata('env_var');
        final prompt = metadata('prompt');
        return GatewaySensitivePromptRequest(
          kind: kind,
          requestId: requestId,
          title: envVar.isEmpty ? 'Secret needed' : envVar,
          description: prompt.isEmpty
              ? 'Hermes needs a secret for the pending skill.'
              : prompt,
          fieldLabel: envVar.isEmpty ? 'Secret value' : envVar,
        );
      case GatewaySensitivePromptKind.vaultUnlock:
        final backend = metadata('backend');
        final displayName = metadata('display_name');
        final unlockOwner = displayName.isNotEmpty
            ? displayName
            : backend.isNotEmpty
            ? backend
            : 'password manager';
        return GatewaySensitivePromptRequest(
          kind: kind,
          requestId: requestId,
          title: 'Unlock $unlockOwner',
          description: 'Enter the master password for $unlockOwner.',
          fieldLabel: 'Master password',
        );
      case GatewaySensitivePromptKind.vaultSaveLogin:
        final origin = metadata('origin');
        final siteMetadata = metadata('site');
        final saveSite = siteMetadata.isNotEmpty ? siteMetadata : origin;
        final saveTarget = saveSite.isEmpty ? 'this site' : saveSite;
        return GatewaySensitivePromptRequest(
          kind: kind,
          requestId: requestId,
          title: 'Save login for $saveTarget',
          description: origin.isEmpty
              ? 'Save this login in the encrypted vault.'
              : 'Save a login for $origin in the encrypted vault.',
          fieldLabel: 'Identifier',
        );
      case GatewaySensitivePromptKind.vaultCode:
        final codeSite = metadata('site');
        final hint = metadata('hint');
        final codeTarget = codeSite.isEmpty ? 'this site' : codeSite;
        return GatewaySensitivePromptRequest(
          kind: kind,
          requestId: requestId,
          title: 'Enter code for $codeTarget',
          description: hint.isEmpty
              ? 'Enter the one-time code for $codeTarget.'
              : hint,
          fieldLabel: 'One-time code',
        );
    }
  }
}
