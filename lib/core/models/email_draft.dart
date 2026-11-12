import 'dart:convert';

/// An immutable plugin artifact; a historical card never resolves to latest.
final class EmailDraftReference {
  const EmailDraftReference(this.id, this.version);
  final String id;
  final int version;

  static EmailDraftReference? parse(String source) {
    try {
      final data = jsonDecode(source);
      if (data is! Map<String, dynamic> || data.length != 2) return null;
      final id = data['id'], version = data['version'];
      if (id is! String ||
          !RegExp(r'^d_[0-9a-f]{32}$').hasMatch(id) ||
          version is! int ||
          version < 1 ||
          version > 10000) {
        return null;
      }
      return EmailDraftReference(id, version);
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is EmailDraftReference &&
      id == other.id &&
      version == other.version;
  @override
  int get hashCode => Object.hash(id, version);
}

final class EmailDraft {
  EmailDraft._(
    this.reference,
    this.to,
    this.cc,
    this.bcc,
    this.subject,
    this.body,
  );
  final EmailDraftReference reference;
  final List<String> to, cc, bcc;
  final String subject, body;

  factory EmailDraft.fromJson(
    EmailDraftReference reference,
    Map<String, dynamic> data,
  ) {
    if (data['id'] != reference.id || data['version'] != reference.version) {
      throw const FormatException('Email draft version mismatch');
    }
    final fields = data['fields'];
    if (fields is! Map<String, dynamic> ||
        fields['subject'] is! String ||
        fields['body'] is! String) {
      throw const FormatException('Invalid email draft');
    }
    List<String> addresses(String key) {
      final values = fields[key];
      if (values is! List || values.any((value) => value is! String)) {
        throw const FormatException('Invalid email recipients');
      }
      return List<String>.unmodifiable(values);
    }

    return EmailDraft._(
      reference,
      addresses('to'),
      addresses('cc'),
      addresses('bcc'),
      fields['subject'] as String,
      fields['body'] as String,
    );
  }

  /// Encode components separately: queryParameters would encode spaces as '+'.
  String get mailto {
    final query = {
      if (cc.isNotEmpty) 'cc': cc.join(','),
      if (bcc.isNotEmpty) 'bcc': bcc.join(','),
      'subject': subject,
      'body': body,
    };
    return 'mailto:${to.map((address) => Uri.encodeComponent(address).replaceAll('%40', '@')).join(',')}?${query.entries.map((entry) => '${entry.key}=${Uri.encodeComponent(entry.value)}').join('&')}';
  }
}
